//! Privacy-projected behavioral uploads. Local behavioral JSONL remains the
//! source of truth; this module builds a separate, bounded batch containing
//! only an allowlisted metadata projection by default. Content-bearing adapter
//! fields require the explicit `content` mode and are never inferred from model
//! text, tool arguments/results, source, or hidden reasoning.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const batch_schema = "codegraff.behavior.batch.v1";
pub const event_schema = "codegraff.behavior.v1";

pub const max_events = 4096;
const max_event_bytes = 16 * 1024;
// Leave enough room below the 256 KiB wire limit for worst-case u64 turn
// counters, the batch envelope, and JSON punctuation.
const max_event_storage = 112 * 1024;
const max_turns = 128;
const max_payload_bytes = 256 * 1024;

pub const Mode = enum {
    off,
    metadata,
    content,

    pub fn privacyName(self: Mode) []const u8 {
        return switch (self) {
            .off => "off",
            .metadata => "metadata",
            .content => "content_opt_in",
        };
    }
};

pub const SendResult = enum {
    not_attempted,
    accepted,
    failed,
    deadline,
};

/// Behavioral upload follows the existing telemetry consent boundary. With
/// telemetry enabled, an unset value selects the content-free metadata mode.
/// Invalid explicit values fail closed instead of accidentally enabling upload.
pub fn resolveMode(value: ?[]const u8, telemetry_enabled: bool) Mode {
    if (!telemetry_enabled) return .off;
    const raw = value orelse return .metadata;
    if (std.ascii.eqlIgnoreCase(raw, "off") or
        std.mem.eql(u8, raw, "0") or
        std.ascii.eqlIgnoreCase(raw, "false") or
        std.ascii.eqlIgnoreCase(raw, "no")) return .off;
    // Upload-enabling values are exact lowercase literals. In particular,
    // case or whitespace variants must not turn a typo into network activity.
    if (std.mem.eql(u8, raw, "metadata")) return .metadata;
    // Content mode performs no automatic redaction. Require the exact lowercase
    // opt-in literal rather than accepting aliases or case variants.
    if (std.mem.eql(u8, raw, "content")) return .content;
    return .off;
}

/// HARNESS_CLIENT remains an unconstrained ordinary-telemetry attribute, but
/// behavioral metadata must not serialize arbitrary environment content.
/// Preserve only the stable SDK attribution labels that Codegraff defines.
fn controlledClientName(raw: []const u8) []const u8 {
    const allowed = [_][]const u8{ "harness", "sdk-ts", "sdk-py" };
    for (allowed) |name| if (std.mem.eql(u8, raw, name)) return name;
    return "harness";
}

pub const TurnMetrics = struct {
    turn: u64,
    api_calls: u64 = 0,
    api_errors: u64 = 0,
    api_subagent_calls: u64 = 0,
    api_latency_ms: u64 = 0,
    request_bytes: u64 = 0,
    response_bytes: u64 = 0,
    context_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    tool_calls: u64 = 0,
    tool_errors: u64 = 0,
    tool_subagent_calls: u64 = 0,
    tool_latency_ms: u64 = 0,
    result_bytes: u64 = 0,
    tool_shell: u64 = 0,
    tool_read: u64 = 0,
    tool_write: u64 = 0,
    tool_search: u64 = 0,
    tool_web: u64 = 0,
    tool_agent: u64 = 0,
    tool_verify: u64 = 0,
    tool_mcp: u64 = 0,
    tool_other: u64 = 0,
};

const ToolClass = enum {
    shell,
    read,
    write,
    search,
    web,
    agent,
    verify,
    mcp,
    other,
};

fn toolClass(name: []const u8) ToolClass {
    if (std.mem.eql(u8, name, "bash") or std.mem.eql(u8, name, "bash_output") or std.mem.eql(u8, name, "bash_kill")) return .shell;
    if (std.mem.eql(u8, name, "read_file")) return .read;
    if (std.mem.eql(u8, name, "edit_file") or std.mem.eql(u8, name, "write_file")) return .write;
    if (std.mem.eql(u8, name, "codedb")) return .search;
    if (std.mem.eql(u8, name, "webfetch")) return .web;
    if (std.mem.eql(u8, name, "workflow") or std.mem.eql(u8, name, "subagent") or std.mem.eql(u8, name, "ask_user") or std.mem.eql(u8, name, "todo_write") or std.mem.eql(u8, name, "todo_read")) return .agent;
    if (std.mem.eql(u8, name, "eval")) return .verify;
    if (std.mem.startsWith(u8, name, "mcp__codedbpro__")) {
        if (std.mem.indexOf(u8, name, "edit") != null or
            std.mem.indexOf(u8, name, "patch") != null or
            std.mem.indexOf(u8, name, "create") != null or
            std.mem.indexOf(u8, name, "replace") != null) return .write;
        if (std.mem.indexOf(u8, name, "lint") != null or std.mem.indexOf(u8, name, "diff") != null) return .verify;
        return .search;
    }
    if (std.mem.startsWith(u8, name, "mcp__")) return .mcp;
    return .other;
}

const max_safe_json_integer: u64 = 9_007_199_254_740_991;

fn saturatingAdd(dst: *u64, value: u64) void {
    // The collector validates counters as exactly representable JSON numbers.
    dst.* = @min(dst.* +| value, max_safe_json_integer);
}

fn nonNegative(value: i64) u64 {
    return @intCast(@max(value, 0));
}

fn isMetadataField(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "version") or
        std.mem.eql(u8, name, "unix_ms") or
        std.mem.eql(u8, name, "provider") or
        std.mem.eql(u8, name, "model") or
        std.mem.eql(u8, name, "effort") or
        std.mem.eql(u8, name, "turn") or
        std.mem.eql(u8, name, "parent_turn") or
        std.mem.eql(u8, name, "trajectory_node") or
        std.mem.eql(u8, name, "commitment_ref") or
        std.mem.eql(u8, name, "status");
}

fn assertMetadataFields(comptime T: type) void {
    // std.meta.fieldNames works on both 0.16 and 0.17-dev (std.meta.fields is
    // deprecated there); only names are needed for the allowlist check.
    inline for (comptime std.meta.fieldNames(T)) |name| {
        if (!isMetadataField(name))
            @compileError("field is not allowed in behavioral metadata: " ++ name);
    }
}

pub const Upload = struct {
    io: Io,
    gpa: Allocator,
    client: ?*std.http.Client,
    endpoint: []const u8,
    auth_key: ?[]const u8 = null,
    last_send_result: SendResult = .not_attempted,
    install_id: [32]u8,
    client_name: []const u8,
    service_version: []const u8,
    run_id: []const u8,
    mode: Mode,
    events: std.ArrayList([]u8) = .empty,
    turns: std.ArrayList(TurnMetrics) = .empty,
    event_bytes: usize = 0,
    dropped_events: u64 = 0,
    dropped_metrics: u64 = 0,
    sent: bool = false,

    pub fn active(self: *const Upload) bool {
        return self.mode != .off and self.endpoint.len > 0;
    }

    pub fn deinit(self: *Upload) void {
        for (self.events.items) |event| self.gpa.free(event);
        self.events.deinit(self.gpa);
        self.turns.deinit(self.gpa);
    }

    /// Queue one event projection. `metadata_fields` must contain only the
    /// content-free allowlist for this kind. `content_fields` is serialized
    /// only after an explicit content opt-in.
    pub fn appendEvent(
        self: *Upload,
        kind: []const u8,
        seq: u64,
        ts: f64,
        metadata_fields: anytype,
        content_fields: anytype,
    ) bool {
        comptime assertMetadataFields(@TypeOf(metadata_fields));
        if (!self.active() or self.sent) return false;
        if (self.events.items.len >= max_events) {
            self.dropped_events +|= 1;
            return false;
        }
        const event = switch (self.mode) {
            .off => return false,
            .metadata => self.allocEvent(kind, seq, ts, metadata_fields),
            .content => self.allocEvent(kind, seq, ts, content_fields),
        } orelse {
            self.dropped_events +|= 1;
            return false;
        };
        if (event.len > max_event_bytes or self.event_bytes > max_event_storage -| event.len) {
            self.gpa.free(event);
            self.dropped_events +|= 1;
            return false;
        }
        self.events.append(self.gpa, event) catch {
            self.gpa.free(event);
            self.dropped_events +|= 1;
            return false;
        };
        self.event_bytes += event.len;
        return true;
    }

    fn allocEvent(self: *Upload, kind: []const u8, seq: u64, ts: f64, fields: anytype) ?[]u8 {
        // Serialize into a fixed scratch buffer so an opted-in adapter cannot
        // trigger an unbounded allocation before the per-event limit is checked.
        var buf: [max_event_bytes + 1]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        var s: std.json.Stringify = .{ .writer = &w };
        s.beginObject() catch return null;
        s.objectField("kind") catch return null;
        s.write(kind) catch return null;
        s.objectField("seq") catch return null;
        s.write(seq) catch return null;
        s.objectField("ts") catch return null;
        s.write(ts) catch return null;
        s.objectField("run_id") catch return null;
        s.write(self.run_id) catch return null;
        s.objectField("schema") catch return null;
        s.write(event_schema) catch return null;
        inline for (comptime std.meta.fieldNames(@TypeOf(fields))) |name| {
            comptime {
                if (std.mem.eql(u8, name, "kind") or
                    std.mem.eql(u8, name, "seq") or
                    std.mem.eql(u8, name, "ts") or
                    std.mem.eql(u8, name, "run_id") or
                    std.mem.eql(u8, name, "schema"))
                {
                    @compileError("behavior upload field collides with the event envelope: " ++ name);
                }
            }
            s.objectField(name) catch return null;
            s.write(@field(fields, name)) catch return null;
        }
        s.endObject() catch return null;
        if (w.buffered().len > max_event_bytes) return null;
        return self.gpa.dupe(u8, w.buffered()) catch null;
    }

    fn metricsForTurn(self: *Upload, turn: u64) ?*TurnMetrics {
        if (!self.active() or self.sent or turn == 0) return null;
        for (self.turns.items) |*metrics| if (metrics.turn == turn) return metrics;
        if (self.turns.items.len >= max_turns) {
            self.dropped_metrics +|= 1;
            return null;
        }
        self.turns.append(self.gpa, .{ .turn = turn }) catch {
            self.dropped_metrics +|= 1;
            return null;
        };
        return &self.turns.items[self.turns.items.len - 1];
    }

    pub fn recordApi(
        self: *Upload,
        turn: u64,
        from_subagent: bool,
        ms: i64,
        req_bytes: usize,
        resp_bytes: usize,
        context_tokens: u64,
        cache_read_tokens: u64,
        is_error: bool,
    ) void {
        const metrics = self.metricsForTurn(turn) orelse return;
        saturatingAdd(&metrics.api_calls, 1);
        saturatingAdd(&metrics.api_errors, @intFromBool(is_error));
        saturatingAdd(&metrics.api_subagent_calls, @intFromBool(from_subagent));
        saturatingAdd(&metrics.api_latency_ms, nonNegative(ms));
        saturatingAdd(&metrics.request_bytes, @intCast(req_bytes));
        saturatingAdd(&metrics.response_bytes, @intCast(resp_bytes));
        saturatingAdd(&metrics.context_tokens, context_tokens);
        saturatingAdd(&metrics.cache_read_tokens, cache_read_tokens);
    }

    pub fn recordTool(
        self: *Upload,
        turn: u64,
        name: []const u8,
        from_subagent: bool,
        ms: i64,
        result_bytes: usize,
        is_error: bool,
    ) void {
        const metrics = self.metricsForTurn(turn) orelse return;
        saturatingAdd(&metrics.tool_calls, 1);
        saturatingAdd(&metrics.tool_errors, @intFromBool(is_error));
        saturatingAdd(&metrics.tool_subagent_calls, @intFromBool(from_subagent));
        saturatingAdd(&metrics.tool_latency_ms, nonNegative(ms));
        saturatingAdd(&metrics.result_bytes, @intCast(result_bytes));
        switch (toolClass(name)) {
            .shell => saturatingAdd(&metrics.tool_shell, 1),
            .read => saturatingAdd(&metrics.tool_read, 1),
            .write => saturatingAdd(&metrics.tool_write, 1),
            .search => saturatingAdd(&metrics.tool_search, 1),
            .web => saturatingAdd(&metrics.tool_web, 1),
            .agent => saturatingAdd(&metrics.tool_agent, 1),
            .verify => saturatingAdd(&metrics.tool_verify, 1),
            .mcp => saturatingAdd(&metrics.tool_mcp, 1),
            .other => saturatingAdd(&metrics.tool_other, 1),
        }
    }

    /// Build the bounded batch body. Kept separate from send() so tests can
    /// validate the exact privacy projection without touching the network.
    pub fn buildPayload(self: *Upload, complete: bool, terminal_status: []const u8) ![]u8 {
        // A fixed heap buffer makes the advertised wire cap an allocation cap
        // too. The event/turn admission limits leave deterministic headroom.
        var backing = try self.gpa.alloc(u8, max_payload_bytes + 1);
        errdefer self.gpa.free(backing);
        var writer: Io.Writer = .fixed(backing);
        const w = &writer;
        try w.writeAll("{\"schema\":");
        try writeJsonValue(w, batch_schema);
        try w.writeAll(",\"event_schema\":");
        try writeJsonValue(w, event_schema);
        try w.writeAll(",\"privacy\":");
        try writeJsonValue(w, self.mode.privacyName());
        try w.writeAll(",\"run_id\":");
        try writeJsonValue(w, self.run_id);
        try w.writeAll(",\"install_id\":");
        try writeJsonValue(w, &self.install_id);
        try w.writeAll(",\"client_name\":");
        try writeJsonValue(w, controlledClientName(self.client_name));
        try w.writeAll(",\"service_version\":");
        try writeJsonValue(w, self.service_version);
        try w.writeAll(",\"complete\":");
        try writeJsonValue(w, complete);
        try w.writeAll(",\"terminal_status\":");
        try writeJsonValue(w, terminal_status);
        try w.writeAll(",\"dropped_events\":");
        try writeJsonValue(w, self.dropped_events);
        try w.writeAll(",\"dropped_metrics\":");
        try writeJsonValue(w, self.dropped_metrics);
        try w.writeAll(",\"events\":[");
        for (self.events.items, 0..) |event, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll(event);
        }
        try w.writeAll("],\"turn_metrics\":");
        try writeJsonValue(w, self.turns.items);
        try w.writeByte('}');
        const used = w.buffered().len;
        if (used > max_payload_bytes) return error.PayloadTooLarge;
        backing = try self.gpa.realloc(backing, used);
        return backing;
    }

    /// One best-effort POST at terminal closure. The run/event primary keys on
    /// the collector make a repeated batch idempotent if retry support is added.
    pub fn send(self: *Upload, complete: bool, terminal_status: []const u8) void {
        self.sendWithDeadline(complete, terminal_status, .fromSeconds(3));
    }

    fn sendWithDeadline(self: *Upload, complete: bool, terminal_status: []const u8, deadline: Io.Duration) void {
        if (!self.active() or self.sent or self.events.items.len == 0) return;
        self.sent = true;
        self.last_send_result = .failed;
        const client = self.client orelse return;
        const payload = self.buildPayload(complete, terminal_status) catch return;
        defer self.gpa.free(payload);
        const url = (behaviorUrl(self.gpa, self.endpoint) catch return) orelse return;
        defer self.gpa.free(url);

        const Done = union(enum) { posted: bool, deadline: void };
        var done_buf: [2]Done = undefined;
        var sel: Io.Select(Done) = .init(self.io, &done_buf);
        // Arm the bound first. If concurrency is unavailable for the POST,
        // canceling this timer is bounded; the reverse order could leave a
        // successfully-started stalled POST with no deadline task.
        sel.concurrent(.deadline, uploadDeadline, .{ self.io, deadline }) catch return;
        sel.concurrent(.posted, postBatch, .{ client, url, payload, self.auth_key orelse "" }) catch {
            sel.cancelDiscard();
            return;
        };
        const first = sel.await() catch {
            sel.cancelDiscard();
            return;
        };
        // Io.Select.cancelDiscard() requests cancellation and synchronously
        // waits for every remaining task to finish. payload, url, and client
        // therefore remain live until the HTTP task has acknowledged it.
        sel.cancelDiscard();
        self.last_send_result = switch (first) {
            .posted => |accepted| if (accepted) .accepted else .failed,
            .deadline => .deadline,
        };
    }
};

fn writeJsonValue(w: *Io.Writer, value: anytype) !void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.write(value);
}

fn behaviorUrl(gpa: Allocator, endpoint: []const u8) !?[]u8 {
    // Derive from the URL path, not from its query. This preserves custom
    // collector query parameters without appending a path inside their value.
    const fragment_at = std.mem.indexOfScalar(u8, endpoint, '#') orelse endpoint.len;
    const without_fragment = endpoint[0..fragment_at];
    const query_at = std.mem.indexOfScalar(u8, without_fragment, '?') orelse without_fragment.len;
    const query = without_fragment[query_at..];
    var base = std.mem.trimEnd(u8, without_fragment[0..query_at], "/");
    if (std.mem.endsWith(u8, base, "/v1/logs")) base = base[0 .. base.len - "/v1/logs".len];
    base = std.mem.trimEnd(u8, base, "/");
    if (base.len == 0) return null;
    return try std.fmt.allocPrint(gpa, "{s}/v1/behavior{s}", .{ base, query });
}

fn postBatch(client: *std.http.Client, url: []const u8, payload: []const u8, auth_key: []const u8) bool {
    const auth_header = [_]std.http.Header{.{ .name = "x-harness-key", .value = auth_key }};
    const extra_headers: []const std.http.Header = if (auth_key.len > 0) &auth_header else &.{};
    const response = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = extra_headers,
    }) catch return false;
    const status = @intFromEnum(response.status);
    return status >= 200 and status < 300;
}

fn uploadDeadline(io: Io, deadline: Io.Duration) void {
    io.sleep(deadline, .awake) catch {};
}

fn stallBehaviorCollector(io: Io, server: *Io.net.Server, accepted: *std.atomic.Value(bool)) void {
    const stream = server.accept(io) catch return;
    defer stream.close(io);
    accepted.store(true, .release);
    // Hold the connection open without sending an HTTP response. Test cleanup
    // cancels this sleep after Upload has canceled and joined its fetch task.
    io.sleep(.fromSeconds(5), .awake) catch {};
}

fn answerBehaviorCollector(
    io: Io,
    server: *Io.net.Server,
    expected_key: []const u8,
    accept_request: bool,
    saw_key: *std.atomic.Value(bool),
) void {
    const stream = server.accept(io) catch return;
    defer stream.close(io);
    var read_buf: [16 * 1024]u8 = undefined;
    var reader = Io.net.Stream.Reader.init(stream, io, &read_buf);
    while (reader.interface.takeDelimiter('\n') catch null) |line| {
        if (std.mem.eql(u8, line, "\r") or line.len == 0) break;
        const prefix = "x-harness-key:";
        if (!std.ascii.startsWithIgnoreCase(line, prefix)) continue;
        const value = std.mem.trim(u8, line[prefix.len..], " \t\r\n");
        saw_key.store(std.mem.eql(u8, value, expected_key), .release);
    }
    const response = if (accept_request)
        "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    else
        "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    var write_buf: [256]u8 = undefined;
    var writer = Io.net.Stream.Writer.init(stream, io, &write_buf);
    writer.interface.writeAll(response) catch return;
    writer.interface.flush() catch {};
}

test "behavior upload mode follows telemetry consent and fails closed" {
    try std.testing.expectEqual(Mode.off, resolveMode(null, false));
    try std.testing.expectEqual(Mode.off, resolveMode("content", false));
    try std.testing.expectEqual(Mode.metadata, resolveMode(null, true));
    try std.testing.expectEqual(Mode.metadata, resolveMode("metadata", true));
    try std.testing.expectEqual(Mode.off, resolveMode("METADATA", true));
    try std.testing.expectEqual(Mode.off, resolveMode("metadata ", true));
    try std.testing.expectEqual(Mode.off, resolveMode("off", true));
    try std.testing.expectEqual(Mode.off, resolveMode("0", true));
    try std.testing.expectEqual(Mode.content, resolveMode("content", true));
    try std.testing.expectEqual(Mode.off, resolveMode("CONTENT", true));
    try std.testing.expectEqual(Mode.off, resolveMode("Content", true));
    try std.testing.expectEqual(Mode.off, resolveMode("content ", true));
    try std.testing.expectEqual(Mode.off, resolveMode("sanitized", true));
    try std.testing.expectEqual(Mode.off, resolveMode("full", true));
    try std.testing.expectEqual(Mode.off, resolveMode("typo", true));
}

test "behavior client attribution never serializes arbitrary HARNESS_CLIENT content" {
    const gpa = std.testing.allocator;
    var upload: Upload = .{
        .io = std.testing.io,
        .gpa = gpa,
        .client = null,
        .endpoint = "https://collector.example/v1/logs",
        .install_id = @splat('a'),
        .client_name = "HARNESS_CLIENT_PRIVATE_SENTINEL",
        .service_version = "test",
        .run_id = "0123456789abcdef",
        .mode = .metadata,
    };
    defer upload.deinit();

    const metadata_payload = try upload.buildPayload(true, "closed");
    defer gpa.free(metadata_payload);
    try std.testing.expect(std.mem.indexOf(u8, metadata_payload, "HARNESS_CLIENT_PRIVATE_SENTINEL") == null);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, metadata_payload, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("harness", parsed.value.object.get("client_name").?.string);

    upload.mode = .content;
    const content_payload = try upload.buildPayload(true, "closed");
    defer gpa.free(content_payload);
    try std.testing.expect(std.mem.indexOf(u8, content_payload, "HARNESS_CLIENT_PRIVATE_SENTINEL") == null);

    try std.testing.expectEqualStrings("sdk-ts", controlledClientName("sdk-ts"));
    try std.testing.expectEqualStrings("sdk-py", controlledClientName("sdk-py"));
}

test "upload deadline synchronously cancels and joins a stalled POST" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var address = try Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);

    var accepted: std.atomic.Value(bool) = .init(false);
    var server_group: Io.Group = .init;
    defer server_group.cancel(io);
    try server_group.concurrent(io, stallBehaviorCollector, .{ io, &server, &accepted });

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var endpoint_buf: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buf, "http://127.0.0.1:{d}", .{server.socket.address.getPort()});
    var upload: Upload = .{
        .io = io,
        .gpa = gpa,
        .client = &client,
        .endpoint = endpoint,
        .install_id = @splat('a'),
        .client_name = "harness",
        .service_version = "test",
        .run_id = "0123456789abcdef",
        .mode = .metadata,
    };
    defer upload.deinit();
    try std.testing.expect(upload.appendEvent("run_started", 1, 1.0, .{}, .{}));

    const started = Io.Timestamp.now(io, .awake).nanoseconds;
    upload.sendWithDeadline(true, "closed", .fromMilliseconds(250));
    const elapsed = Io.Timestamp.now(io, .awake).nanoseconds - started;

    try std.testing.expect(accepted.load(.acquire));
    try std.testing.expectEqual(SendResult.deadline, upload.last_send_result);
    try std.testing.expect(elapsed >= 100 * std.time.ns_per_ms);
    try std.testing.expect(elapsed < 3 * std.time.ns_per_s);
}

test "behavior POST sends the collector key and rejects non-success status" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    inline for (.{ true, false }) |accept_request| {
        var address = try Io.net.IpAddress.parseLiteral("127.0.0.1:0");
        var server = try Io.net.IpAddress.listen(&address, io, .{});
        defer server.deinit(io);
        var saw_key: std.atomic.Value(bool) = .init(false);
        var server_group: Io.Group = .init;
        defer server_group.cancel(io);
        try server_group.concurrent(io, answerBehaviorCollector, .{ io, &server, "collector-secret", accept_request, &saw_key });

        var endpoint_buf: [64]u8 = undefined;
        const endpoint = try std.fmt.bufPrint(&endpoint_buf, "http://127.0.0.1:{d}/v1/behavior", .{server.socket.address.getPort()});
        try std.testing.expectEqual(accept_request, postBatch(&client, endpoint, "{}", "collector-secret"));
        try std.testing.expect(saw_key.load(.acquire));
    }
}

test "metadata projection omits content while explicit content mode includes it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const common = .{
        .io = io,
        .gpa = gpa,
        .client = @as(?*std.http.Client, null),
        .endpoint = "https://collector.example/v1/logs",
        .install_id = @as([32]u8, @splat('a')),
        .client_name = "test",
        .service_version = "test",
        .run_id = "0123456789abcdef",
    };

    var metadata: Upload = .{
        .io = common.io,
        .gpa = common.gpa,
        .client = common.client,
        .endpoint = common.endpoint,
        .install_id = common.install_id,
        .client_name = common.client_name,
        .service_version = common.service_version,
        .run_id = common.run_id,
        .mode = .metadata,
    };
    defer metadata.deinit();
    try std.testing.expect(metadata.appendEvent(
        "turn_committed",
        1,
        1.5,
        .{ .turn = @as(u64, 1), .commitment_ref = "safe-ref" },
        .{ .turn = @as(u64, 1), .commitment_id = "private-id", .action = .{ .secret = "TOP_SECRET" }, .expect = .{ .ok = true }, .reason = "private reason" },
    ));
    const metadata_payload = try metadata.buildPayload(true, "closed");
    defer gpa.free(metadata_payload);
    try std.testing.expect(std.mem.indexOf(u8, metadata_payload, "safe-ref") != null);
    try std.testing.expect(std.mem.indexOf(u8, metadata_payload, "TOP_SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, metadata_payload, "private reason") == null);

    var content: Upload = .{
        .io = common.io,
        .gpa = common.gpa,
        .client = common.client,
        .endpoint = common.endpoint,
        .install_id = common.install_id,
        .client_name = common.client_name,
        .service_version = common.service_version,
        .run_id = common.run_id,
        .mode = .content,
    };
    defer content.deinit();
    try std.testing.expect(content.appendEvent(
        "turn_committed",
        1,
        1.5,
        .{ .turn = @as(u64, 1), .commitment_ref = "safe-ref" },
        .{ .turn = @as(u64, 1), .commitment_id = "private-id", .action = .{ .secret = "TOP_SECRET" }, .expect = .{ .ok = true }, .reason = "adapter-sanitized reason" },
    ));
    const content_payload = try content.buildPayload(true, "closed");
    defer gpa.free(content_payload);
    try std.testing.expect(std.mem.indexOf(u8, content_payload, "TOP_SECRET") != null);
    try std.testing.expect(std.mem.indexOf(u8, content_payload, "content_opt_in") != null);
}

test "turn metrics aggregate safe categories without exact MCP names" {
    const gpa = std.testing.allocator;
    var upload: Upload = .{
        .io = std.testing.io,
        .gpa = gpa,
        .client = null,
        .endpoint = "https://collector.example",
        .install_id = @splat('b'),
        .client_name = "test",
        .service_version = "test",
        .run_id = "fedcba9876543210",
        .mode = .metadata,
    };
    defer upload.deinit();
    upload.recordApi(1, false, 20, 100, 200, 300, 250, false);
    upload.recordTool(1, "bash", false, 5, 40, false);
    upload.recordTool(1, "mcp__private_server__lookup_customer", true, 7, 80, true);
    try std.testing.expectEqual(@as(usize, 1), upload.turns.items.len);
    const metrics = upload.turns.items[0];
    try std.testing.expectEqual(@as(u64, 1), metrics.api_calls);
    try std.testing.expectEqual(@as(u64, 2), metrics.tool_calls);
    try std.testing.expectEqual(@as(u64, 1), metrics.tool_shell);
    try std.testing.expectEqual(@as(u64, 1), metrics.tool_mcp);
    try std.testing.expectEqual(@as(u64, 1), metrics.tool_errors);

    _ = upload.appendEvent("run_started", 1, 1.0, .{ .version = "test", .unix_ms = @as(i64, 1) }, .{ .version = "test", .unix_ms = @as(i64, 1) });
    const payload = try upload.buildPayload(true, "closed");
    defer gpa.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "lookup_customer") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tool_mcp\":1") != null);
}

test "batch admission limits always fit the wire cap" {
    const gpa = std.testing.allocator;
    var upload: Upload = .{
        .io = std.testing.io,
        .gpa = gpa,
        .client = null,
        .endpoint = "https://collector.example",
        .install_id = @splat('d'),
        .client_name = "test",
        .service_version = "test",
        .run_id = "0123456789abcdef",
        .mode = .metadata,
    };
    defer upload.deinit();

    var turn: u64 = 1;
    while (turn <= max_turns) : (turn += 1) {
        upload.recordApi(turn, false, std.math.maxInt(i64), std.math.maxInt(usize), std.math.maxInt(usize), std.math.maxInt(u64), std.math.maxInt(u64), true);
        upload.recordTool(turn, "bash", true, std.math.maxInt(i64), std.math.maxInt(usize), true);
        inline for (comptime std.meta.fieldNames(TurnMetrics)) |name| {
            if (!std.mem.eql(u8, name, "turn")) @field(upload.turns.items[@intCast(turn - 1)], name) = max_safe_json_integer;
        }
    }
    upload.recordApi(max_turns + 1, false, 1, 1, 1, 1, 1, false);
    try std.testing.expectEqual(@as(u64, 1), upload.dropped_metrics);

    var seq: u64 = 1;
    while (seq <= max_events) : (seq += 1) {
        if (!upload.appendEvent(
            "run_started",
            seq,
            1.0,
            .{ .version = "test", .unix_ms = @as(i64, 1), .provider = "provider-padding-provider-padding-provider-padding" },
            .{ .version = "test", .unix_ms = @as(i64, 1) },
        )) break;
    }
    try std.testing.expect(upload.dropped_events > 0);
    const payload = try upload.buildPayload(true, "closed");
    defer gpa.free(payload);
    try std.testing.expect(payload.len <= max_payload_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, payload, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}

test "oversized content event is rejected before queueing" {
    const gpa = std.testing.allocator;
    var upload: Upload = .{
        .io = std.testing.io,
        .gpa = gpa,
        .client = null,
        .endpoint = "https://collector.example",
        .install_id = @splat('e'),
        .client_name = "test",
        .service_version = "test",
        .run_id = "0123456789abcdef",
        .mode = .content,
    };
    defer upload.deinit();
    var oversized: [max_event_bytes * 2]u8 = @splat('x');
    try std.testing.expect(!upload.appendEvent(
        "turn_committed",
        1,
        1.0,
        .{ .turn = @as(u64, 1), .commitment_ref = "safe" },
        .{ .turn = @as(u64, 1), .reason = oversized[0..] },
    ));
    try std.testing.expectEqual(@as(usize, 0), upload.events.items.len);
    try std.testing.expectEqual(@as(u64, 1), upload.dropped_events);
}

test "behavior endpoint derives beside OTLP logs without a fixed URL buffer" {
    const gpa = std.testing.allocator;
    const Case = struct {
        fn expect(gpa_inner: Allocator, endpoint: []const u8, expected: []const u8) !void {
            const actual = (try behaviorUrl(gpa_inner, endpoint)).?;
            defer gpa_inner.free(actual);
            try std.testing.expectEqualStrings(expected, actual);
        }
    };
    try Case.expect(gpa, "https://example.test/v1/logs", "https://example.test/v1/behavior");
    try Case.expect(gpa, "https://example.test/base/", "https://example.test/base/v1/behavior");
    try Case.expect(gpa, "https://example.test/v1/logs?token=x#ignored", "https://example.test/v1/behavior?token=x");
    try Case.expect(gpa, "https://example.test/base/?token=x", "https://example.test/base/v1/behavior?token=x");

    const long_token: [768]u8 = @splat('x');
    var endpoint_buf: [1024]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buf, "https://example.test/v1/logs?token={s}", .{long_token});
    const actual = (try behaviorUrl(gpa, endpoint)).?;
    defer gpa.free(actual);
    try std.testing.expect(actual.len > 512);
    try std.testing.expect(std.mem.startsWith(u8, actual, "https://example.test/v1/behavior?token="));
    try std.testing.expect(std.mem.endsWith(u8, actual, &long_token));
}
