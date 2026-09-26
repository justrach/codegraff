//! ACP v2 (draft) wire shapes. Negotiated per process at `initialize` when
//! the client asks for protocolVersion >= 2 AND `GRAFF_ACP_V2=1`; every other
//! connection keeps the v1 shapes byte-for-byte (ADR 0206). One ACP
//! connection per process, so the negotiated state is a process global.
const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const acp_auth = @import("acp_auth.zig");

pub const version: i64 = 2;

var active = std.atomic.Value(bool).init(false);
/// Tests pin the gate; null reads `GRAFF_ACP_V2`.
pub var gate: ?bool = null;

pub fn on() bool {
    return active.load(.acquire);
}

pub fn gateOpen() bool {
    if (gate) |g| return g;
    const v = std.c.getenv("GRAFF_ACP_V2") orelse return false;
    return std.mem.eql(u8, std.mem.span(v), "1");
}

fn requested(params: ?Value) i64 {
    const p = params orelse return 1;
    if (p != .object) return 1;
    const v = p.object.get("protocolVersion") orelse return 1;
    return if (v == .integer) v.integer else 1;
}

/// The version to answer with. ACP: the requested one when supported, else
/// our latest — v2 is only "supported" behind the gate.
pub fn negotiated(params: ?Value) i64 {
    return if (gateOpen() and requested(params) >= version) version else 1;
}

/// Latch the connection's wire at `initialize` (a re-initialize may downgrade).
pub fn negotiate(params: ?Value, seed: u64) void {
    const v2 = negotiated(params) == version;
    if (v2) prefix = seed;
    kind = .none;
    active.store(v2, .release);
}

// ── message IDs ─────────────────────────────────────────────────────────
// A message is one contiguous run of agent text or thought. Switching kind or
// reporting a tool starts a new ID, so later text never appends above a tool
// row that the client already rendered. Callers hold the ACP output lock.

const Kind = enum { none, agent, thought };
var prefix: u64 = 0;
var counter = std.atomic.Value(u64).init(0);
var kind: Kind = .none;
var current: [48]u8 = undefined;
var current_len: usize = 0;

pub fn mint(buf: *[48]u8, role: []const u8) []const u8 {
    const n = counter.fetchAdd(1, .monotonic) + 1;
    return std.fmt.bufPrint(buf, "msg_{s}_{x}_{d}", .{ role, prefix, n }) catch "msg";
}

fn messageId(k: Kind) []const u8 {
    if (kind != k or current_len == 0) {
        current_len = mint(&current, @tagName(k)).len;
        kind = k;
    }
    return current[0..current_len];
}

/// A tool event or turn boundary ends the current message.
pub fn breakMessage() void {
    kind = .none;
}

pub fn writeChunk(w: *Io.Writer, sid: []const u8, thought: bool, text: []const u8) !void {
    const id = messageId(if (thought) .thought else .agent);
    try notify(w, sid, .{
        .sessionUpdate = if (thought) "agent_thought_chunk" else "agent_message_chunk",
        .messageId = id,
        .content = .{ .type = "text", .text = text },
    });
}

pub fn writeUserMessage(w: *Io.Writer, sid: []const u8, id: []const u8, prompt: ?Value, text: []const u8) !void {
    breakMessage();
    if (prompt) |p| if (p == .array) return notify(w, sid, .{ .sessionUpdate = "user_message", .messageId = id, .content = p });
    try notify(w, sid, .{ .sessionUpdate = "user_message", .messageId = id, .content = .{.{ .type = "text", .text = text }} });
}

pub fn writeRunning(w: *Io.Writer, sid: []const u8) !void {
    try notify(w, sid, .{ .sessionUpdate = "state_update", .state = "running" });
}

pub fn writeRequiresAction(w: *Io.Writer, sid: []const u8) !void {
    try notify(w, sid, .{ .sessionUpdate = "state_update", .state = "requires_action" });
}

pub fn writeIdle(w: *Io.Writer, sid: []const u8, stop: []const u8) !void {
    breakMessage();
    try notify(w, sid, .{ .sessionUpdate = "state_update", .state = "idle", .stopReason = stop });
}

/// A turn that failed after its prompt was accepted: the JSON-RPC request is
/// already answered, so the error rides the idle transition (custom `_` reason).
pub fn writeFailed(w: *Io.Writer, sid: []const u8, message: []const u8) !void {
    breakMessage();
    try notify(w, sid, .{
        .sessionUpdate = "state_update",
        .state = "idle",
        .stopReason = "_error",
        ._meta = .{ .@"graff/error" = message },
    });
}

pub fn writeUsage(w: *Io.Writer, sid: []const u8, used: u64, size: u64) !void {
    try notify(w, sid, .{ .sessionUpdate = "usage_update", .used = used, .size = size });
}

fn notify(w: *Io.Writer, sid: []const u8, update: anytype) !void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.write(.{ .jsonrpc = "2.0", .method = "session/update", .params = .{ .sessionId = sid, .update = update } });
    try w.writeByte('\n');
}

// ── initialize ──────────────────────────────────────────────────────────

pub const Info = struct {
    name: []const u8 = "graff",
    title: []const u8 = "graff",
    version: []const u8,
};

const Empty = struct {};

/// v2 `initialize` result: `info` + object-marker `capabilities` (an absent
/// capability is omitted, never `false`/`null`). Graff extensions ride `_meta`.
pub fn initializeResult(params: ?Value, can_load: bool, impl_version: []const u8) InitializeResult {
    return .{ .can_load = can_load, .terminal_auth = clientTerminalAuth(params), .info = .{ .version = impl_version } };
}

/// v2 renames the method key to `methodId`, and a `terminal` method may be
/// advertised only to a client that sent `capabilities.auth.terminal`.
const TerminalAuth = struct {
    methodId: []const u8,
    name: []const u8,
    description: []const u8,
    type: []const u8 = "terminal",
    args: []const []const u8,
};
const terminal_login = [_]TerminalAuth{.{
    .methodId = acp_auth.terminal_login.id,
    .name = acp_auth.terminal_login.name,
    .description = acp_auth.terminal_login.description,
    .args = acp_auth.terminal_login.args,
}};

fn clientTerminalAuth(params: ?Value) bool {
    const p = params orelse return false;
    if (p != .object) return false;
    const caps = p.object.get("capabilities") orelse return false;
    if (caps != .object) return false;
    const auth = caps.object.get("auth") orelse return false;
    if (auth != .object) return false;
    const terminal = auth.object.get("terminal") orelse return false;
    return terminal == .object;
}

const InitializeResult = struct {
    can_load: bool,
    terminal_auth: bool,
    info: Info,

    pub fn jsonStringify(self: @This(), s: anytype) !void {
        try s.beginObject();
        try s.objectField("protocolVersion");
        try s.write(version);
        try s.objectField("capabilities");
        try s.beginObject();
        try s.objectField("session");
        try s.beginObject();
        try s.objectField("prompt");
        try s.beginObject();
        if (self.can_load) {
            try s.objectField("image");
            try s.write(Empty{});
        }
        try s.objectField("embeddedContext");
        try s.write(Empty{});
        try s.endObject();
        try s.objectField("mcp");
        try s.write(.{ .stdio = Empty{}, .http = Empty{} });
        try s.endObject();
        try s.objectField("_meta");
        try s.write(.{ .@"codegraff/usage" = self.can_load, .@"graff/backgroundSubagents" = true });
        try s.endObject();
        try s.objectField("info");
        try s.write(self.info);
        try s.objectField("authMethods");
        try s.write(if (self.terminal_auth) terminal_login[0..] else terminal_login[0..0]);
        try s.endObject();
    }
};

pub fn resetForTest() void {
    active.store(false, .release);
    gate = null;
    kind = .none;
}

test "v2 needs both the client's request and the GRAFF_ACP_V2 gate" {
    defer resetForTest();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const two = try std.json.parseFromSliceLeaky(Value, arena.allocator(), "{\"protocolVersion\":2}", .{});
    const one = try std.json.parseFromSliceLeaky(Value, arena.allocator(), "{\"protocolVersion\":1}", .{});
    const nine = try std.json.parseFromSliceLeaky(Value, arena.allocator(), "{\"protocolVersion\":9}", .{});
    gate = false;
    try std.testing.expectEqual(@as(i64, 1), negotiated(two));
    gate = true;
    try std.testing.expectEqual(@as(i64, 2), negotiated(two));
    try std.testing.expectEqual(@as(i64, 2), negotiated(nine));
    try std.testing.expectEqual(@as(i64, 1), negotiated(one));
    try std.testing.expectEqual(@as(i64, 1), negotiated(null));
    negotiate(two, 7);
    try std.testing.expect(on());
    negotiate(one, 7);
    try std.testing.expect(!on());
}

test "message IDs change with the message kind and after a tool" {
    defer resetForTest();
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeChunk(&w, "s", false, "a");
    try writeChunk(&w, "s", false, "b");
    const first = current[0..current_len];
    var keep: [48]u8 = undefined;
    @memcpy(keep[0..first.len], first);
    try writeChunk(&w, "s", true, "think");
    try std.testing.expect(!std.mem.eql(u8, keep[0..first.len], current[0..current_len]));
    breakMessage();
    try writeChunk(&w, "s", false, "c");
    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, out, "\"messageId\":"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, keep[0..first.len]));
}

test "v2 initialize uses info and object-marker capabilities" {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.json.Stringify.value(initializeResult(null, false, "t"), .{}, &w);
    var out = w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "{\"protocolVersion\":2,\"capabilities\":{\"session\":{\"prompt\":{\"embeddedContext\":{}},\"mcp\":{\"stdio\":{},\"http\":{}}}"));
    try std.testing.expect(std.mem.indexOf(u8, out, "\"info\":{\"name\":\"graff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "agentCapabilities") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "null") == null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\"authMethods\":[]}"));
    const params = try std.json.parseFromSliceLeaky(Value, arena.allocator(), "{\"capabilities\":{\"auth\":{\"terminal\":{}}}}", .{});
    w = .fixed(&buf);
    try std.json.Stringify.value(initializeResult(params, true, "t"), .{}, &w);
    out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"image\":{}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"methodId\":\"graff-login\"") != null);
}
