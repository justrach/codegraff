//! The device→relay upload half of remote control (#722): the one HTTP call
//! shape, the coalescing event batcher, the oversized-line stub, and the
//! gateway's error text. Split out of remote_control.zig (600-line cap).
//!
//! Lines are JSON objects already, so they ride as values inside the batch
//! body and are never re-escaped. A failed upload is logged and dropped: the
//! tape on disk is complete and a viewer's next `reattach` fills the hole.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const root = @import("main.zig");
const serve = @import("serve.zig");
const events = @import("serve_events.zig");
const util = @import("util.zig");
const harness_version = root.harness_version;

/// Event lines above this go upstream as a stub; the local tape stays complete.
pub const upload_line_cap: usize = 256 * 1024;
/// Coalesce uploads: a burst of text deltas becomes one POST per window.
const flush_window_ms: i64 = 60;
const flush_bytes: usize = 32 * 1024;

/// Everything one HTTP call to the relay needs. `client` is per task: the
/// poll loop owns one, every streamed request another, so a turn's uploads
/// never queue behind a 25s poll (or vice versa).
pub const Link = struct {
    io: Io,
    base: []const u8,
    key: []const u8,
    agent_id: [16]u8,
    client: *std.http.Client,
};

pub const Reply = struct { code: u16, body: []const u8 };

pub fn post(link: Link, arena: Allocator, path: []const u8, payload: []const u8) !Reply {
    const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ link.base, path });
    var aw: Io.Writer.Allocating = .init(arena);
    const res = try link.client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .response_writer = &aw.writer,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = try std.fmt.allocPrint(arena, "Bearer {s}", .{link.key}) },
            .user_agent = .{ .override = "simple-harness/" ++ harness_version },
        },
    });
    return .{ .code = @intFromEnum(res.status), .body = aw.writer.buffered() };
}

/// The gateway's error message out of a non-2xx body, or the raw body.
pub fn errorMessage(arena: Allocator, body: []const u8) []const u8 {
    if (std.json.parseFromSliceLeaky(Value, arena, body, .{ .allocate = .alloc_always })) |v| {
        if (v == .object) if (v.object.get("error")) |e| if (e == .object)
            if (util.strFieldObj(e.object, "message")) |m| return m;
    } else |_| {}
    return body[0..@min(body.len, 200)];
}

/// Event types a viewer must see NOW rather than at the end of a window.
pub fn urgent(line: []const u8) bool {
    const t = events.stringField(line, "type") orelse return false;
    return std.mem.eql(u8, t, "tool_call") or std.mem.eql(u8, t, "ask_user") or events.terminalEvent(line);
}

/// A line too big for the relay window becomes an envelope-only stub. Only the
/// upload shrinks: the tape and a later `reattach` still carry the full line.
pub fn uploadLine(buf: []u8, line: []const u8) []const u8 {
    if (line.len <= upload_line_cap) return line;
    const seq = events.seqOf(line) orelse 0;
    const t = events.stringField(line, "type") orelse "event";
    return std.fmt.bufPrint(buf, "{{\"seq\":{d},\"type\":\"{s}\",\"truncated\":true,\"bytes\":{d}}}", .{ seq, t[0..@min(t.len, 64)], line.len }) catch line[0..0];
}

/// Batches event lines for one command into `POST …/events` bodies:
/// `{"command_id","session_id","events":[<line>,…][,"result":{status,body}]}`.
pub const Uploader = struct {
    link: Link,
    arena: Allocator,
    cmd_id: []const u8,
    sid: []const u8,
    aw: Io.Writer.Allocating,
    count: usize = 0,
    last_flush_ms: i64,

    pub fn init(link: Link, arena: Allocator, cmd_id: []const u8, sid: []const u8) Uploader {
        return .{ .link = link, .arena = arena, .cmd_id = cmd_id, .sid = sid, .aw = .init(arena), .last_flush_ms = util.unixMs(link.io) };
    }

    fn open(u: *Uploader) void {
        u.aw.writer.print("{{\"command_id\":\"{s}\",\"session_id\":\"{s}\",\"events\":[", .{ u.cmd_id, u.sid }) catch {};
    }

    pub fn push(u: *Uploader, line: []const u8) void {
        if (u.count == 0) u.open();
        if (u.count > 0) u.aw.writer.writeByte(',') catch {};
        var stub: [256]u8 = undefined;
        u.aw.writer.writeAll(uploadLine(&stub, line)) catch {};
        u.count += 1;
        const now = util.unixMs(u.link.io);
        if (u.aw.writer.buffered().len >= flush_bytes or now - u.last_flush_ms >= flush_window_ms or urgent(line)) u.flush(null);
    }

    /// One POST, retried briefly on 5xx. A failed upload is logged and
    /// dropped: the tape is complete and the viewer's next `reattach` fills it.
    fn flush(u: *Uploader, result: ?struct { status: u16, body: []const u8 }) void {
        if (u.count == 0 and result == null) return;
        if (u.count == 0) u.open();
        u.aw.writer.writeByte(']') catch {};
        if (result) |r| u.aw.writer.print(",\"result\":{{\"status\":{d},\"body\":{s}}}", .{ r.status, r.body }) catch {};
        u.aw.writer.writeByte('}') catch {};
        const path = std.fmt.allocPrint(u.arena, "/v1/remote/agents/{s}/events", .{&u.link.agent_id}) catch return;
        var attempt: usize = 0;
        while (attempt < 3) : (attempt += 1) {
            if (post(u.link, u.arena, path, u.aw.writer.buffered())) |r| {
                if (r.code >= 200 and r.code < 300) break;
                serve.serveLog(u.link.io, "remote-control: upload HTTP {d}: {s}", .{ r.code, errorMessage(u.arena, r.body) });
                if (r.code < 500) break;
            } else |err| serve.serveLog(u.link.io, "remote-control: upload failed ({t})", .{err});
            u.link.io.sleep(.fromMilliseconds(250 * @as(i64, @intCast(attempt + 1))), .awake) catch break;
        }
        u.aw = .init(u.arena);
        u.count = 0;
        u.last_flush_ms = util.unixMs(u.link.io);
    }

    pub fn finish(u: *Uploader, status: u16, body: []const u8) void {
        u.flush(.{ .status = status, .body = body });
    }
};

test "urgent: tool calls, prompts and terminals flush immediately; deltas batch" {
    try std.testing.expect(urgent("{\"seq\":1,\"type\":\"tool_call\",\"name\":\"bash\"}"));
    try std.testing.expect(urgent("{\"seq\":2,\"type\":\"ask_user\",\"call_id\":\"q\"}"));
    try std.testing.expect(urgent("{\"seq\":3,\"type\":\"turn\"}"));
    try std.testing.expect(!urgent("{\"seq\":4,\"type\":\"text\",\"text\":\"turn\"}"));
    try std.testing.expect(!urgent("{\"seq\":5,\"type\":\"reasoning\",\"text\":\"…\"}"));
}

test "uploadLine: small lines pass through, oversized ones become an envelope stub" {
    var buf: [256]u8 = undefined;
    const small = "{\"seq\":7,\"type\":\"text\",\"text\":\"hi\"}";
    try std.testing.expectEqualStrings(small, uploadLine(&buf, small));
    const big = try std.testing.allocator.alloc(u8, upload_line_cap + 100);
    defer std.testing.allocator.free(big);
    const head = "{\"seq\":9,\"type\":\"tool_result\",\"output\":\"";
    @memset(big, 'x');
    @memcpy(big[0..head.len], head);
    big[big.len - 2] = '"';
    big[big.len - 1] = '}';
    const stub = uploadLine(&buf, big);
    try std.testing.expect(std.mem.startsWith(u8, stub, "{\"seq\":9,\"type\":\"tool_result\",\"truncated\":true,\"bytes\":"));
    try std.testing.expect(events.seqOf(stub).? == 9);
}

test "Uploader.push builds one batch body with the lines as JSON values, never re-escaped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    const link: Link = .{ .io = std.testing.io, .base = "http://relay.invalid", .key = "k", .agent_id = "00ff00ff00ff00ff".*, .client = &client };
    var up = Uploader.init(link, arena, "c1", "nightly");
    up.push("{\"seq\":1,\"type\":\"text\",\"text\":\"a \\\"quoted\\\" word\"}");
    up.push("{\"seq\":2,\"type\":\"reasoning\",\"text\":\"…\"}");
    // Two deltas inside the flush window stay buffered (nothing was posted).
    try std.testing.expectEqual(@as(usize, 2), up.count);
    try std.testing.expectEqualStrings(
        "{\"command_id\":\"c1\",\"session_id\":\"nightly\",\"events\":[{\"seq\":1,\"type\":\"text\",\"text\":\"a \\\"quoted\\\" word\"},{\"seq\":2,\"type\":\"reasoning\",\"text\":\"…\"}",
        up.aw.writer.buffered(),
    );
}

test "errorMessage prefers the gateway's structured message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("device is offline", errorMessage(arena, "{\"error\":{\"message\":\"device is offline\",\"type\":\"device_offline\"}}"));
    try std.testing.expectEqualStrings("<html>", errorMessage(arena, "<html>"));
}
