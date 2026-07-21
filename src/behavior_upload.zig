//! Privacy-projected behavioral uploads. Local behavioral JSONL remains the
//! source of truth; this module builds a separate, bounded batch containing
//! only an allowlisted metadata projection by default. Content-bearing adapter
//! fields require the explicit `content` mode and are never inferred from model
//! text, tool arguments/results, source, or hidden reasoning.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const http = @import("http.zig");

pub const batch_schema = "codegraff.behavior.batch.v1";
pub const event_schema = "codegraff.behavior.v1";

pub const max_events = 4096;
pub const max_event_bytes = 16 * 1024;
// Leave enough room below the 256 KiB wire limit for worst-case u64 turn
// counters, the batch envelope, and JSON punctuation.
const max_event_storage = 112 * 1024;
pub const max_turns = 128;
pub const max_payload_bytes = 256 * 1024;

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
pub fn controlledClientName(raw: []const u8) []const u8 {
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

comptime {
    // turn_metrics rows bypass assertMetadataFields, so close the same
    // privacy hole structurally: every field must stay a content-free u64
    // counter, and a string or nested payload cannot ride along unnoticed.
    for (@typeInfo(TurnMetrics).@"struct".fields) |field| {
        if (field.type != u64) @compileError("TurnMetrics fields must be content-free u64 counters: " ++ field.name);
    }
}

pub const ToolClass = enum {
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

/// Public so behavior_trace.zig's action_taken emitter (#255) can reuse the
/// same state-mutation classification instead of duplicating the tool-name
/// table.
pub fn toolClass(name: []const u8) ToolClass {
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

pub const max_safe_json_integer: u64 = 9_007_199_254_740_991;

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
        std.mem.eql(u8, name, "status") or
        // Sink-health diagnostics: whether the local JSONL opened at run start
        // and how many events it dropped before write. Counters and booleans
        // only; nothing content-bearing.
        std.mem.eql(u8, name, "local_sink") or
        std.mem.eql(u8, name, "local_dropped");
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

    pub fn sendWithDeadline(self: *Upload, complete: bool, terminal_status: []const u8, deadline: Io.Duration) void {
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

pub fn behaviorUrl(gpa: Allocator, endpoint: []const u8) !?[]u8 {
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

pub fn postBatch(client: *std.http.Client, url: []const u8, payload: []const u8, auth_key: []const u8) bool {
    // Same gate as Telemetry.postOtlp: the terminal upload can run before the
    // shared client's CA-bundle prewarm has joined (finishAndClose is
    // registered after the prewarm-join defer), and an ungated fetch then
    // races the prewarm task on the shared client (#131).
    http.waitForClientReady(client.io);
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

pub fn stallBehaviorCollector(io: Io, server: *Io.net.Server, accepted: *std.atomic.Value(bool)) void {
    const stream = server.accept(io) catch return;
    defer stream.close(io);
    accepted.store(true, .release);
    // Hold the connection open without sending an HTTP response. Test cleanup
    // cancels this sleep after Upload has canceled and joined its fetch task.
    io.sleep(.fromSeconds(5), .awake) catch {};
}

pub fn answerBehaviorCollector(
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

test {
    _ = @import("behavior_upload_tests.zig");
}
