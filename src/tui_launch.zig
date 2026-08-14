//! Glue: launch the Grok-style TUI against the real agent loop.
//! Adapts TUI engine types onto `repl_glue` so we do not duplicate runTurn.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const args = @import("args.zig");
const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const pricing = @import("pricing.zig");
const providers = @import("providers.zig");
const repl = @import("repl.zig");
const repl_glue = @import("repl_glue.zig");
const tui = @import("tui");
const engine_sink = @import("engine_sink.zig");
const obs = @import("obs.zig");
const telemetry = @import("telemetry.zig");
const vision = @import("vision.zig");
const builtin = @import("builtin");

/// `graff tui` (and TTY `graff repl`). Bare `graff` stays the default session.
pub fn wantsTui(flags: args.Flags, json_mode: bool) bool {
    if (json_mode or flags.oneshot_prompt != null) return false;
    return flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "tui");
}

pub fn maybeRun(
    gpa: Allocator,
    io: Io,
    environ_map: anytype,
    root: *agent_mod.Agent,
    keys: *provider_mod.Keys,
    client: *std.http.Client,
    arena: Allocator,
    flags: args.Flags,
    json_mode: bool,
    cwd: []const u8,
) !bool {
    if (!wantsTui(flags, json_mode)) return false;
    run(gpa, io, environ_map, root, keys, client, arena, cwd, flags.yolo_flag) catch |err| {
        if (err == error.NotATty) {
            var buf: [256]u8 = undefined;
            var w = Io.File.stderr().writer(io, &buf);
            w.interface.writeAll("graff tui needs a real terminal (stdout is not a TTY).\n") catch {};
            w.interface.flush() catch {};
            return true;
        }
        return err;
    };
    return true;
}

pub fn run(
    gpa: Allocator,
    io: Io,
    environ_map: anytype,
    root: *agent_mod.Agent,
    keys: *provider_mod.Keys,
    client: *std.http.Client,
    arena: Allocator,
    cwd: []const u8,
    yolo: bool,
) !void {
    root.ensureStoredKeys(keys);
    providers.ensureModelQueryCatalogs(root, keys.*, "");
    try root.ensureRootTools(.anthropic);
    try root.ensureRootTools(.openai);
    try root.ensureRootTools(.responses);
    var repl_ctx = repl_glue.ReplCtx{
        .io = io,
        .client = client,
        .keys = keys.*,
        .home = root.home,
        .provider = root.provider,
        .fallback_allow = root.fallback_allow,
        .fallback_active = root.fallback_active,
        .fallback_blocked = root.fallback_blocked,
        .registry = root.registry,
        .tracer = root.tracer,
        .run_budget = root.run_budget,
        .sys_normal = root.sys_normal,
        .tools_anthropic = root.tools_anthropic,
        .tools_openai = root.tools_openai,
        .tools_responses = root.tools_responses,
    };
    var models_buf = std.array_list.Managed(u8).init(arena);
    for (pricing.models()) |mi| {
        if (mi.name.len == 0) continue;
        if (models_buf.items.len != 0) models_buf.appendSlice(", ") catch {};
        models_buf.appendSlice(mi.name) catch {};
    }
    engine_sink.hosted_frontend = true;
    defer engine_sink.hosted_frontend = false;
    obs.ensureSession();
    try tui.run(gpa, io, environ_map, .{
        .turn_ctx = &repl_ctx,
        .turn_fn = turnCb,
        .model_fn = modelCb,
        .cancel_fn = cancelCb,
        .model_name = root.provider.model,
        .models = models_buf.items,
        .cwd = cwd,
        .yolo = yolo,
        .hud_fn = hudCb,
        .paste_fn = pasteCb,
    });
}

/// Overlay the TUI preview buffer as a repl.StreamBuf so replTurnCb's
/// appendBytes publish `stream.len` as bytes arrive. Layout is identical
/// (buf + atomic len); a copy would hide the live tail until the turn ends.
fn liveStream(stream: *tui.StreamBuf) *repl.StreamBuf {
    comptime {
        if (@sizeOf(tui.StreamBuf) != @sizeOf(repl.StreamBuf) or
            @offsetOf(tui.StreamBuf, "buf") != @offsetOf(repl.StreamBuf, "buf") or
            @offsetOf(tui.StreamBuf, "len") != @offsetOf(repl.StreamBuf, "len"))
            @compileError("tui.StreamBuf and repl.StreamBuf must stay layout-identical");
    }
    return @ptrCast(stream);
}

fn turnCb(
    ctx: ?*anyopaque,
    gpa: Allocator,
    history: []const tui.Turn,
    params: tui.Params,
    stream: *tui.StreamBuf,
) ?[]const u8 {
    var turns = std.array_list.Managed(repl.Turn).init(gpa);
    defer {
        for (turns.items) |t| gpa.free(t.text);
        turns.deinit();
    }
    for (history) |t| {
        const text = gpa.dupe(u8, t.text) catch continue;
        turns.append(.{ .role = switch (t.role) {
            .user => .user,
            .assistant => .assistant,
        }, .text = text }) catch gpa.free(text);
    }
    var last_len: u32 = 0;
    if (history.len > 0 and history[history.len - 1].role == .user) {
        last_len = @intCast(@min(history[history.len - 1].text.len, std.math.maxInt(u32)));
    }
    const model = if (ctx) |p| @as(*repl_glue.ReplCtx, @ptrCast(@alignCast(p))).provider.model else "";
    obs.prompt(last_len, model);
    // Same buf AND the same atomic len — a fresh repl.StreamBuf around
    // stream.buf left job.stream.len at 0 for the whole turn, so the live
    // tail never showed hosted tool lines until finishJob copied them.
    const result = repl_glue.replTurnCb(ctx, gpa, turns.items, .{
        .effort = @enumFromInt(@intFromEnum(params.effort)),
        .fast = params.fast,
        .thinking = params.thinking,
        .ultracode = params.ultracode,
        .goal = params.goal,
    }, liveStream(stream));
    if (result != null) {
        if (telemetry.g_telem) |t| t.countTurn() else obs.turn(.completed);
    } else obs.turn(.failed);
    return result;
}

fn modelCb(ctx: ?*anyopaque, gpa: Allocator, name: []const u8) ?[]const u8 {
    const nm = repl_glue.replModelCb(ctx, gpa, name);
    if (nm) |n| obs.modelSwitch(n);
    return nm;
}

fn cancelCb(ctx: ?*anyopaque) void {
    repl_glue.replCancelCb(ctx);
}

fn pasteCb(ctx: ?*anyopaque, dest: []u8) isize {
    const c: *repl_glue.ReplCtx = @ptrCast(@alignCast(ctx orelse return pasteErr(dest, "no session")));
    if (!vision.visionCapable(c.provider)) return pasteErr(dest, vision.no_vision_message);
    if (builtin.os.tag != .macos) return pasteErr(dest, "clipboard image paste is macOS-only — use /image <path>");
    const gpa = std.heap.page_allocator;
    const grab = vision.grabClipboardImage(c.io, gpa) orelse return 0;
    const n = @min(grab.path.len, dest.len);
    @memcpy(dest[0..n], grab.path[0..n]);
    if (grab.owned) {
        gpa.free(grab.path);
    } else grab.release(c.io, gpa);
    return @intCast(n);
}

fn pasteErr(dest: []u8, msg: []const u8) isize {
    const n = @min(msg.len, dest.len);
    @memcpy(dest[0..n], msg[0..n]);
    return -@as(isize, @intCast(n));
}

fn hudCb(kind: tui.HudKind, buf: []u8) usize {
    var w: Io.Writer = .fixed(buf);
    switch (kind) {
        .debug => obs.renderHud(&w) catch {},
        .usage => obs.renderUsage(&w) catch {},
    }
    return w.buffered().len;
}

test {
    _ = tui;
}

test "hudCb usage/debug use the cost-tally renderer, not chars" {
    const io = std.testing.io;
    const c = &pricing.g_cost;
    c.mutex.lockUncancelable(io);
    c.usd = 0;
    c.in_tokens = 0;
    c.cache_tokens = 0;
    c.out_tokens = 0;
    c.api_calls = 0;
    c.sub_calls = 0;
    c.unpriced_calls = 0;
    c.mutex.unlock(io);
    defer {
        c.mutex.lockUncancelable(io);
        c.usd = 0;
        c.in_tokens = 0;
        c.cache_tokens = 0;
        c.out_tokens = 0;
        c.api_calls = 0;
        c.sub_calls = 0;
        c.unpriced_calls = 0;
        c.mutex.unlock(io);
    }
    obs.reset();
    defer obs.reset();
    obs.attach(io);
    pricing.g_cost.add(io, .priced, "gpt-5.5", 1000, 200, 50);
    obs.turn(.completed);

    var cost_buf: [256]u8 = undefined;
    var cost_w: Io.Writer = .fixed(&cost_buf);
    try pricing.CostTally.render(pricing.g_cost.snap(io), &cost_w);
    const cost = cost_w.buffered();

    var usage_buf: [512]u8 = undefined;
    const un = hudCb(.usage, &usage_buf);
    var debug_buf: [2048]u8 = undefined;
    const dn = hudCb(.debug, &debug_buf);
    try std.testing.expect(std.mem.indexOf(u8, usage_buf[0..un], cost) != null);
    try std.testing.expect(std.mem.indexOf(u8, debug_buf[0..dn], cost) != null);
    try std.testing.expect(std.mem.indexOf(u8, debug_buf[0..dn], "turns") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage_buf[0..un], "chars sent") == null);
    try std.testing.expect(std.mem.indexOf(u8, debug_buf[0..dn], "offline") == null);
}

test "wantsTui: only the tui subcommand" {
    try std.testing.expect(!wantsTui(.{}, false));
    try std.testing.expect(!wantsTui(.{ .oneshot_prompt = "hi" }, false));
    var tui_pos = std.ArrayList([]const u8).empty;
    defer tui_pos.deinit(std.testing.allocator);
    try tui_pos.append(std.testing.allocator, "tui");
    try std.testing.expect(wantsTui(.{ .positionals = tui_pos }, false));
    try std.testing.expect(!wantsTui(.{ .positionals = tui_pos }, true));
}

test "liveStream publishes len as appendBytes arrive" {
    var buf: [64]u8 = undefined;
    var tstream: tui.StreamBuf = .{ .buf = &buf };
    const rstream = liveStream(&tstream);
    try std.testing.expectEqual(@as(usize, 0), tstream.len.load(.acquire));
    rstream.appendBytes("⚙ bash\n");
    try std.testing.expectEqual(@as(usize, "⚙ bash\n".len), tstream.len.load(.acquire));
    const snap = tstream.snapshot(std.testing.allocator) orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqualStrings("⚙ bash\n", snap);
    rstream.appendBytes("✓ bash\n");
    try std.testing.expect(std.mem.endsWith(u8, tstream.buf[0..tstream.len.load(.acquire)], "✓ bash\n"));
}
