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
pub const err_auth_required = proto.err_auth_required;

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
pub const LoadSessionFn = *const fn (ctx: *anyopaque, arena: Allocator, w: *Io.Writer, req: proto.Request) anyerror!void;
/// Optional per-turn context meter: used and window tokens for the
/// `gui_context_meter` update available to clients.
/// Null when the embed has no live agent (pure in-process loop, tests).
pub const Meter = struct { used: u64, window: u64 };
pub const MeterFn = *const fn (ctx: *anyopaque) Meter;
/// Vendor-method escape hatch: gets every request the core loop does not
/// claim; returns true when it answered (false falls through to -32601).
pub const ExtraFn = *const fn (ctx: *anyopaque, arena: Allocator, w: *Io.Writer, req: proto.Request) anyerror!bool;
pub const ConfigValue = struct { value: []const u8, name: []const u8 };
pub const ConfigOption = struct {
    id: []const u8 = "thought_level",
    name: []const u8 = "Thought Level",
    category: []const u8 = "thought_level",
    type: []const u8 = "select",
    currentValue: []const u8,
    options: []const ConfigValue,
};
pub const ConfigFn = *const fn (ctx: *anyopaque, arena: Allocator) anyerror!?ConfigOption;
pub const SetConfigFn = *const fn (ctx: *anyopaque, value: []const u8) anyerror!bool;

pub const Dispatch = struct {
    turn: TurnFn,
    ctx: *anyopaque,
    session_id: ?[]const u8 = null,
    seed: u64 = 0,
    created: u32 = 0,
    slash: ?SlashFn = null,
    after_user: ?AfterUserFn = null,
    bind_session: ?BindSessionFn = null,
    load_session: ?LoadSessionFn = null,
    /// Live CLI saves under this stable name; embeds retain generated IDs.
    durable_session_id: ?[]const u8 = null,
    meter: ?MeterFn = null,
    extra: ?ExtraFn = null,
    config: ?ConfigFn = null,
    set_config: ?SetConfigFn = null,
    error_message: ?*const fn (ctx: *anyopaque, err: anyerror) []const u8 = null,
    /// Isolated checkout after session start (`g_cwd_display`). Empty omits the field.
    cwd: []const u8 = "",
};

pub fn configOptions(d: *Dispatch, arena: Allocator) ![]const ConfigOption {
    const config = d.config orelse return &.{};
    const option = try config(d.ctx, arena) orelse return &.{};
    const items = try arena.alloc(ConfigOption, 1);
    items[0] = option;
    return items;
}

fn sameConfig(before: []const ConfigOption, after: []const ConfigOption) bool {
    if (before.len != after.len) return false;
    for (before, after) |a, b| {
        if (!std.mem.eql(u8, a.currentValue, b.currentValue) or a.options.len != b.options.len) return false;
        for (a.options, b.options) |av, bv| if (!std.mem.eql(u8, av.value, bv.value)) return false;
    }
    return true;
}

fn emitConfigChange(d: *Dispatch, arena: Allocator, w: *Io.Writer, sid: []const u8, before: []const ConfigOption) !void {
    if (d.config == null) return;
    const after = try configOptions(d, arena);
    if (sameConfig(before, after)) return;
    try proto.writeNotification(w, "session/update", .{ .sessionId = sid, .update = .{
        .sessionUpdate = "config_option_update",
        .configOptions = after,
    } });
}

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

fn turnError(d: *Dispatch, w: *Io.Writer, req: proto.Request, err: anyerror) !void {
    if (err == error.Interrupted or err == error.Canceled)
        return respond(w, req, .{ .stopReason = "cancelled" });
    if (err == error.RunBudgetExhausted)
        return respond(w, req, .{ .stopReason = "max_turn_requests" });
    return respondError(w, req, err_internal, if (d.error_message) |message| message(d.ctx, err) else @errorName(err));
}

fn promptTurn(d: *Dispatch, arena: Allocator, w: *Io.Writer, req: proto.Request) !void {
    const obj: ?std.json.ObjectMap = if (req.params) |p| (if (p == .object) p.object else null) else null;
    const sid = blk: {
        if (obj) |o| if (util.strFieldObj(o, "sessionId")) |s| break :blk s;
        break :blk d.session_id orelse "";
    };
    if (d.bind_session) |bind| bind(d.ctx, sid);
    const config_before = configOptions(d, arena) catch |err| return turnError(d, w, req, err);
    const text = try flattenPrompt(arena, if (obj) |o| o.get("prompt") else null);
    if (d.slash) |slash| {
        const reply = slash(d.ctx, arena, text) catch |err| {
            emitConfigChange(d, arena, w, sid, config_before) catch |config_err| return turnError(d, w, req, config_err);
            return turnError(d, w, req, err);
        };
        if (reply) |plain| {
            if (plain.len > 0) try writeSessionUpdate(w, sid, plain);
            emitConfigChange(d, arena, w, sid, config_before) catch |config_err| return turnError(d, w, req, config_err);
            try emitMeter(d, w, sid);
            return respond(w, req, .{ .stopReason = "end_turn" });
        }
    }
    if (d.after_user) |after| after(d.ctx, arena, text);
    const final = d.turn(d.ctx, arena, text) catch |err| {
        emitConfigChange(d, arena, w, sid, config_before) catch |config_err| return turnError(d, w, req, config_err);
        return turnError(d, w, req, err);
    };
    if (final.len > 0) try writeSessionUpdate(w, sid, final);
    emitConfigChange(d, arena, w, sid, config_before) catch |config_err| return turnError(d, w, req, config_err);
    try emitMeter(d, w, sid);
    const extra = if (extra_cancelled) |f| f() else false;
    const stop: []const u8 = if (cancel_flag.load(.acquire) or extra) "cancelled" else "end_turn";
    try respond(w, req, .{ .stopReason = stop });
}

fn emitMeter(d: *Dispatch, w: *Io.Writer, sid: []const u8) !void {
    if (d.meter) |meter| {
        // Report live occupancy independently of the model catalog.
        const m = meter(d.ctx);
        if (m.window > 0) try proto.writeNotification(w, "session/update", .{
            .sessionId = sid,
            .update = .{
                .sessionUpdate = "gui_context_meter",
                .used = m.used,
                .window = m.window,
            },
        });
    }
}

test "slash commands refresh occupancy before their terminal response" {
    const Fixture = struct {
        fn slash(_: *anyopaque, _: Allocator, _: []const u8) anyerror!?[]const u8 {
            return "compacted";
        }
        fn meter(_: *anyopaque) Meter {
            return .{ .used = 20, .window = 100 };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buffer: [2048]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    var dispatch: Dispatch = .{ .turn = echoTurn, .ctx = undefined, .slash = Fixture.slash, .meter = Fixture.meter };
    try handleLine(&dispatch, arena.allocator(), &writer, "{\"id\":1,\"method\":\"session/prompt\",\"params\":{\"prompt\":[{\"type\":\"text\",\"text\":\"/compact\"}]}}");
    const output = writer.buffered();
    const meter_pos = std.mem.indexOf(u8, output, "\"used\":20,\"window\":100") orelse return error.MissingMeter;
    const end_pos = std.mem.indexOf(u8, output, "stopReason") orelse return error.MissingResponse;
    try std.testing.expect(meter_pos < end_pos);
}

fn respondInitialize(w: *Io.Writer, req: proto.Request, can_load: bool) !void {
    return respond(w, req, .{
        .protocolVersion = negotiateVersion(req.params),
        .agentCapabilities = .{
            .loadSession = can_load,
            ._meta = .{ .@"codegraff/usage" = can_load },
            .promptCapabilities = proto.PromptCapabilities{},
        },
        .agentInfo = proto.AgentImplementation{ .version = implementation_version },
        .agentImplementation = proto.AgentImplementation{ .version = implementation_version },
        .authMethods = acp_auth.advertised,
    });
}

/// Credential-free ACP bootstrap. Initialize is byte-for-byte the full
/// engine response; every request that needs a live Agent is auth-gated.
pub fn handlePreAuthLine(arena: Allocator, w: *Io.Writer, line: []const u8) !void {
    const req = parseRequest(arena, line) orelse return;
    if (std.mem.eql(u8, req.method, "initialize")) return respondInitialize(w, req, false);
    return respondError(w, req, err_auth_required, acp_auth.required_message);
}

pub fn handleLine(d: *Dispatch, arena: Allocator, w: *Io.Writer, line: []const u8) !void {
    const req = parseRequest(arena, line) orelse return;
    if (std.mem.eql(u8, req.method, "initialize")) return respondInitialize(w, req, d.load_session != null);
    if (std.mem.eql(u8, req.method, "authenticate"))
        return respondError(w, req, err_method_not_found, "terminal auth is out of band: re-spawn graff login");
    if (std.mem.eql(u8, req.method, "session/new")) {
        if (d.load_session != null and d.session_id != null)
            return respondError(w, req, -32000, "This ACP process already owns a session");
        d.created += 1;
        d.session_id = d.durable_session_id orelse try std.fmt.allocPrint(arena, "acp-{x}-{d}", .{ d.seed, d.created });
        if (d.config != null) {
            const options = configOptions(d, arena) catch |err| return respondError(w, req, err_internal, @errorName(err));
            if (d.cwd.len > 0)
                try respond(w, req, .{ .sessionId = d.session_id.?, .cwd = d.cwd, .configOptions = options })
            else
                try respond(w, req, .{ .sessionId = d.session_id.?, .configOptions = options });
        } else if (d.cwd.len > 0)
            try respond(w, req, .{ .sessionId = d.session_id.?, .cwd = d.cwd })
        else
            try respond(w, req, .{ .sessionId = d.session_id.? });
        try proto.writeAvailableCommands(w, d.session_id.?, proto.slashCommands());
        return;
    }
    if ((d.load_session != null and (std.mem.eql(u8, req.method, "session/prompt") or std.mem.eql(u8, req.method, "session/cancel"))) or
        (d.set_config != null and std.mem.eql(u8, req.method, "session/set_config_option")))
    {
        const params = req.params orelse return respondError(w, req, -32602, "Invalid session ID");
        if (params != .object) return respondError(w, req, -32602, "Invalid session ID");
        const sid = util.strFieldObj(params.object, "sessionId") orelse return respondError(w, req, -32602, "Invalid session ID");
        if (d.session_id == null or !std.mem.eql(u8, sid, d.session_id.?))
            return respondError(w, req, -32602, "Unknown session ID");
    }
    if (std.mem.eql(u8, req.method, "session/cancel")) {
        cancel_flag.store(true, .release);
        if (on_cancel) |hook| hook();
        if (req.id != null) return respond(w, req, .{});
        return;
    }
    if (std.mem.eql(u8, req.method, "session/load")) {
        if (d.load_session) |load| return load(d.ctx, arena, w, req);
    }
    if (std.mem.eql(u8, req.method, "session/set_config_option") and d.set_config != null) {
        const params = req.params orelse return respondError(w, req, -32602, "Invalid configuration option");
        if (params != .object) return respondError(w, req, -32602, "Invalid configuration option");
        const id = util.strFieldObj(params.object, "configId") orelse return respondError(w, req, -32602, "Invalid configuration option");
        const value = util.strFieldObj(params.object, "value") orelse return respondError(w, req, -32602, "Invalid configuration value");
        if (!std.mem.eql(u8, id, "thought_level"))
            return respondError(w, req, -32602, "Invalid configuration value");
        const accepted = d.set_config.?(d.ctx, value) catch |err| return respondError(w, req, err_internal, @errorName(err));
        if (!accepted) return respondError(w, req, -32602, "Invalid configuration value");
        const options = configOptions(d, arena) catch |err| return respondError(w, req, err_internal, @errorName(err));
        return respond(w, req, .{ .configOptions = options });
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
    var buf: [16384]u8 = undefined; // session/new advertises the whole command catalog
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

test "session/new reports an isolated checkout when Dispatch.cwd is set" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var buf: [32768]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var d: Dispatch = .{ .turn = echoTurn, .ctx = undefined, .seed = 0x11, .cwd = "/repo/.graff/worktrees/session-1" };
    try handleLine(&d, state.allocator(), &w, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/new\"}");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"sessionId\":\"acp-11-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"cwd\":\"/repo/.graff/worktrees/session-1\"") != null);
}

test "in-process embed can still create a second session" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var buf: [32768]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var d: Dispatch = .{ .turn = echoTurn, .ctx = undefined, .seed = 0x22 };
    try handleLine(&d, a, &w, "{\"id\":1,\"method\":\"session/new\"}");
    try std.testing.expectEqualStrings("acp-22-1", d.session_id.?);
    w = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"id\":2,\"method\":\"session/new\"}");
    try std.testing.expectEqualStrings("acp-22-2", d.session_id.?);
}

test "ACP effort config validates sessions and values and notifies slash changes" {
    const Fixture = struct {
        level: []const u8 = "medium",
        narrow: bool = false,
        calls: usize = 0,
        fn config(ctx: *anyopaque, _: Allocator) anyerror!?ConfigOption {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const broad = &[_]ConfigValue{ .{ .value = "low", .name = "Low" }, .{ .value = "medium", .name = "Medium" }, .{ .value = "high", .name = "High" } };
            const narrow = &[_]ConfigValue{ .{ .value = "low", .name = "Low" }, .{ .value = "medium", .name = "Medium" } };
            return .{ .currentValue = self.level, .options = if (self.narrow) narrow else broad };
        }
        fn set(ctx: *anyopaque, value: []const u8) anyerror!bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            for (if (self.narrow) &[_][]const u8{ "low", "medium" } else &[_][]const u8{ "low", "medium", "high" }) |allowed| {
                if (std.mem.eql(u8, value, allowed)) {
                    self.level = allowed;
                    return true;
                }
            }
            return false;
        }
        fn slash(ctx: *anyopaque, _: Allocator, text: []const u8) anyerror!?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, text, "/effort low")) {
                self.level = "low";
                return "effort changed";
            }
            if (std.mem.eql(u8, text, "/model narrow")) {
                self.narrow = true;
                return "model changed";
            }
            return null;
        }
        fn turn(ctx: *anyopaque, _: Allocator, _: []const u8) anyerror![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return "done";
        }
    };
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var fixture: Fixture = .{};
    var d: Dispatch = .{ .turn = Fixture.turn, .ctx = &fixture, .seed = 1, .config = Fixture.config, .set_config = Fixture.set, .slash = Fixture.slash };
    var buf: [32768]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"id\":1,\"method\":\"session/set_config_option\",\"params\":{\"sessionId\":\"acp-1-1\",\"configId\":\"thought_level\",\"value\":\"high\"}}");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "Unknown session ID") != null);
    w = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"id\":2,\"method\":\"session/new\"}");
    const setup = try std.json.parseFromSliceLeaky(std.json.Value, a, std.mem.sliceTo(w.buffered(), '\n'), .{});
    const option = setup.object.get("result").?.object.get("configOptions").?.array.items[0].object;
    try std.testing.expectEqualStrings("thought_level", option.get("category").?.string);
    try std.testing.expectEqualStrings("medium", option.get("currentValue").?.string);
    try std.testing.expectEqual(@as(usize, 3), option.get("options").?.array.items.len);
    for ([_][]const u8{
        "{\"id\":3,\"method\":\"session/set_config_option\",\"params\":{\"sessionId\":\"wrong\",\"configId\":\"thought_level\",\"value\":\"high\"}}",
        "{\"id\":4,\"method\":\"session/set_config_option\",\"params\":{\"sessionId\":\"acp-1-1\",\"configId\":\"other\",\"value\":\"high\"}}",
        "{\"id\":5,\"method\":\"session/set_config_option\",\"params\":{\"sessionId\":\"acp-1-1\",\"configId\":\"thought_level\",\"value\":\"ultra\"}}",
        "{\"id\":6,\"method\":\"session/set_config_option\",\"params\":{\"sessionId\":\"acp-1-1\",\"configId\":\"thought_level\",\"value\":true}}",
    }) |request| {
        w = .fixed(&buf);
        try handleLine(&d, a, &w, request);
        try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"code\":-32602") != null);
        try std.testing.expectEqualStrings("medium", fixture.level);
    }
    w = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"id\":7,\"method\":\"session/set_config_option\",\"params\":{\"sessionId\":\"acp-1-1\",\"configId\":\"thought_level\",\"value\":\"high\"}}");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"currentValue\":\"high\"") != null);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    w = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"id\":8,\"method\":\"session/prompt\",\"params\":{\"prompt\":[{\"type\":\"text\",\"text\":\"/effort low\"}]}}");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "config_option_update") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"currentValue\":\"low\"") != null);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    w = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"id\":9,\"method\":\"session/prompt\",\"params\":{\"prompt\":[{\"type\":\"text\",\"text\":\"/model narrow\"}]}}");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "config_option_update") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"value\":\"high\"") == null);
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

test "ACP failure carries its reason without claiming completion and the next prompt still works" {
    const Fixture = struct {
        fn fail(_: *anyopaque, _: Allocator, _: []const u8) anyerror![]const u8 {
            return error.ApiError;
        }
        fn message(_: *anyopaque, _: anyerror) []const u8 {
            return "Connection closed after tool results";
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [2048]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    var dispatch: Dispatch = .{ .turn = Fixture.fail, .ctx = undefined, .error_message = Fixture.message };
    const request = "{\"id\":1,\"method\":\"session/prompt\",\"params\":{\"prompt\":[{\"type\":\"text\",\"text\":\"check\"}]}}";
    try handleLine(&dispatch, arena.allocator(), &writer, request);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Connection closed after tool results") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "stopReason") == null);
    writer = .fixed(&buf);
    dispatch.turn = echoTurn;
    try handleLine(&dispatch, arena.allocator(), &writer, request);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "end_turn") != null);
}

test "failed slash command returns an ACP error instead of killing the worker loop" {
    const Fixture = struct {
        fn slash(_: *anyopaque, _: Allocator, _: []const u8) anyerror!?[]const u8 {
            return error.ApiError;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [2048]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    var dispatch: Dispatch = .{ .turn = echoTurn, .ctx = undefined, .slash = Fixture.slash };
    try handleLine(&dispatch, arena.allocator(), &writer, "{\"id\":1,\"method\":\"session/prompt\",\"params\":{\"prompt\":[{\"type\":\"text\",\"text\":\"/compact\"}]}}");
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "ApiError") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "end_turn") == null);
}
