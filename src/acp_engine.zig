//! In-process ACP loop: initialize / session/new / prompt / cancel.
//! No HTTP, no Agent, no `main.zig` — this is what `libgraff` and
//! `graff-core.wasm` compile (fx-shaped same-process embed).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const proto = @import("acp_protocol.zig");
const util = @import("util.zig");
const acp_auth = @import("acp_auth.zig");

pub const parseRequest = proto.parseRequest;
pub const negotiateVersion = proto.negotiateVersion;
pub const flattenPrompt = proto.flattenPrompt;
pub const writeResult = proto.writeResult;
pub const writeError = proto.writeError;
pub const writeSessionUpdate = proto.writeSessionUpdate;
pub const err_method_not_found = proto.err_method_not_found;
pub const err_internal = proto.err_internal;

/// Stamped by the CLI (`harness_version`) or the embed create() call.
pub var implementation_version: []const u8 = "0.0.0-embed";

pub var cancel_flag = std.atomic.Value(bool).init(false);
pub var on_cancel: ?*const fn () void = null;
/// CLI live ACP also watches `Agent.esc_cancel` (Esc / session/cancel).
pub var extra_cancelled: ?*const fn () bool = null;

pub const TurnFn = *const fn (ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8;
pub const SlashFn = *const fn (ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror!?[]const u8;
pub const AfterUserFn = *const fn (ctx: *anyopaque, arena: Allocator, text: []const u8) void;
pub const BindSessionFn = *const fn (ctx: *anyopaque, session_id: []const u8) void;
/// Vendor-method escape hatch: gets every request the core loop does not
/// claim; returns true when it answered (false falls through to -32601).
pub const ExtraFn = *const fn (ctx: *anyopaque, arena: Allocator, w: *Io.Writer, req: proto.Request) anyerror!bool;

pub const Dispatch = struct {
    turn: TurnFn,
    ctx: *anyopaque,
    session_id: ?[]const u8 = null,
    seed: u64 = 0,
    created: u32 = 0,
    slash: ?SlashFn = null,
    after_user: ?AfterUserFn = null,
    bind_session: ?BindSessionFn = null,
    extra: ?ExtraFn = null,
};

fn respond(w: *Io.Writer, req: proto.Request, result: anytype) !void {
    if (req.id == null) return;
    try writeResult(w, req.id, result);
}

fn respondError(w: *Io.Writer, req: proto.Request, code: i32, message: []const u8) !void {
    if (req.id == null) return;
    try writeError(w, req.id, code, message);
}

pub fn stripSgr(arena: Allocator, s: []const u8) ![]const u8 {
    var buf: std.array_list.Managed(u8) = .init(arena);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            i += 2;
            while (i < s.len and (s[i] < '@' or s[i] > '~')) i += 1;
            if (i < s.len) i += 1;
            continue;
        }
        try buf.append(s[i]);
        i += 1;
    }
    return buf.items;
}

fn promptTurn(d: *Dispatch, arena: Allocator, w: *Io.Writer, req: proto.Request) !void {
    const obj: ?std.json.ObjectMap = if (req.params) |p| (if (p == .object) p.object else null) else null;
    const sid = blk: {
        if (obj) |o| if (util.strFieldObj(o, "sessionId")) |s| break :blk s;
        break :blk d.session_id orelse "";
    };
    if (d.bind_session) |bind| bind(d.ctx, sid);
    const text = try flattenPrompt(arena, if (obj) |o| o.get("prompt") else null);
    if (d.slash) |slash| {
        if (try slash(d.ctx, arena, text)) |plain| {
            if (plain.len > 0) try writeSessionUpdate(w, sid, plain);
            return respond(w, req, .{ .stopReason = "end_turn" });
        }
    }
    if (d.after_user) |after| after(d.ctx, arena, text);
    const final = d.turn(d.ctx, arena, text) catch |err| {
        if (err == error.RunBudgetExhausted)
            return respond(w, req, .{ .stopReason = "max_turn_requests" });
        return respondError(w, req, err_internal, @errorName(err));
    };
    if (final.len > 0) try writeSessionUpdate(w, sid, final);
    const extra = if (extra_cancelled) |f| f() else false;
    const stop: []const u8 = if (cancel_flag.load(.acquire) or extra) "cancelled" else "end_turn";
    try respond(w, req, .{ .stopReason = stop });
}

pub fn handleLine(d: *Dispatch, arena: Allocator, w: *Io.Writer, line: []const u8) !void {
    const req = parseRequest(arena, line) orelse return;
    if (std.mem.eql(u8, req.method, "initialize")) return respond(w, req, .{
        .protocolVersion = negotiateVersion(req.params),
        .agentCapabilities = .{
            .loadSession = false,
            .promptCapabilities = proto.PromptCapabilities{},
        },
        .agentImplementation = proto.AgentImplementation{ .version = implementation_version },
        .authMethods = acp_auth.advertised,
    });
    if (std.mem.eql(u8, req.method, "authenticate"))
        return respondError(w, req, err_method_not_found, "terminal auth is out of band: re-spawn graff login");
    if (std.mem.eql(u8, req.method, "session/new")) {
        d.created += 1;
        d.session_id = try std.fmt.allocPrint(arena, "acp-{x}-{d}", .{ d.seed, d.created });
        try respond(w, req, .{ .sessionId = d.session_id.? });
        try proto.writeAvailableCommands(w, d.session_id.?, proto.slashCommands());
        return;
    }
    if (std.mem.eql(u8, req.method, "session/cancel")) {
        cancel_flag.store(true, .release);
        if (on_cancel) |hook| hook();
        if (req.id != null) return respond(w, req, .{});
        return;
    }
    if (std.mem.eql(u8, req.method, "session/prompt")) return promptTurn(d, arena, w, req);
    if (d.extra) |extra| if (try extra(d.ctx, arena, w, req)) return;
    if (req.id == null) return;
    try writeError(w, req.id, err_method_not_found, try std.fmt.allocPrint(arena, "method not found: {s}", .{req.method}));
}

fn echoTurn(_: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8 {
    return std.fmt.allocPrint(arena, "echo:{s}", .{text});
}

test "in-process handleLine speaks the same initialize / new / prompt envelopes" {
    implementation_version = "embed-test";
    cancel_flag.store(false, .release);
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var d: Dispatch = .{ .turn = echoTurn, .ctx = undefined, .seed = 0xabc };

    try handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":9}}");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"protocolVersion\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"name\":\"graff\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "embed-test") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"authMethods\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "graff-login") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"type\":\"terminal\"") != null);

    w = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/new\"}");
    try std.testing.expectEqualStrings("acp-abc-1", d.session_id.?);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "available_commands_update") != null);

    w = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"id\":3,\"method\":\"session/prompt\",\"params\":{\"prompt\":[{\"type\":\"text\",\"text\":\"ping\"}]}}");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"text\":\"echo:ping\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"stopReason\":\"end_turn\"") != null);
}

test "authenticate names the out-of-band terminal login" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var d: Dispatch = .{ .turn = echoTurn, .ctx = undefined };
    try handleLine(&d, state.allocator(), &w, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"authenticate\",\"params\":{\"methodId\":\"graff-login\"}}");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"code\":-32601") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "graff login") != null);
}

test "stripSgr drops CSI sequences" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expectEqualStrings("ok", try stripSgr(state.allocator(), "\x1b[2mok\x1b[0m"));
}
