//! Tests for behavior_upload.zig (600-line goal). Reached through the
//! `test { _ = ... }` hook in behavior_upload.zig, mirroring the mcp.zig
//! pattern in main.zig.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const upload_mod = @import("behavior_upload.zig");
const telemetry = @import("telemetry.zig");

const Upload = upload_mod.Upload;
const Mode = upload_mod.Mode;
const SendResult = upload_mod.SendResult;
const TurnMetrics = upload_mod.TurnMetrics;
const resolveMode = upload_mod.resolveMode;
const behaviorUrl = upload_mod.behaviorUrl;
const max_events = upload_mod.max_events;
const max_payload_bytes = upload_mod.max_payload_bytes;
const max_event_bytes = upload_mod.max_event_bytes;
const max_turns = upload_mod.max_turns;
const controlledClientName = upload_mod.controlledClientName;
const stallBehaviorCollector = upload_mod.stallBehaviorCollector;
const answerBehaviorCollector = upload_mod.answerBehaviorCollector;
const postBatch = upload_mod.postBatch;
const max_safe_json_integer = upload_mod.max_safe_json_integer;

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
    // Generous upper bound: the .deadline result and the 100ms lower bound
    // already prove the behavior; a tight wall-clock ceiling only buys CI
    // flakes on loaded runners.
    try std.testing.expect(elapsed < 30 * std.time.ns_per_s);
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
