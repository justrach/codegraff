//! Glue: launch the Grok-style TUI against the real agent loop.
//! Adapts TUI engine types onto `repl_glue` so we do not duplicate runTurn.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const args = @import("args.zig");
const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const billing = @import("billing.zig");
const pricing = @import("pricing.zig");
const providers = @import("providers.zig");
const process_runner = @import("process_runner.zig");
const repl = @import("repl.zig");
const repl_bash = @import("repl_bash.zig");
const repl_glue = @import("repl_glue.zig");
const tui = @import("tui");
const engine_sink = @import("engine_sink.zig");
const tui_sink = @import("tui_sink.zig");
const tui_acp = @import("tui_acp.zig");
const job_notify = @import("job_notify.zig");
const obs = @import("obs.zig");
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
    // #551: the session's conversation belongs to the engine and outlives every
    // turn, so tool_use/tool_result blocks accumulate the way mainloop's root
    // messages do instead of being rebuilt from rendered rows each turn. It is
    // created here, on the frame that owns the whole TUI session.
    var convo = repl_glue.Conversation.init(gpa);
    defer convo.deinit();
    repl_ctx.convo = &convo;
    const entries = modelEntries(arena, keys.*);
    engine_sink.hosted_frontend = true;
    defer engine_sink.hosted_frontend = false;
    obs.ensureSession();
    var acp_session: tui_acp.Session = undefined;
    acp_session.init(gpa, @as(u64, @bitCast(std.time.milliTimestamp())));
    tui_acp.attach(&acp_session);
    defer tui_acp.detach();
    acp_session.ensure();
    try tui.run(gpa, io, environ_map, .{
        .turn_ctx = &repl_ctx,
        .turn_fn = turnCb,
        .model_fn = modelCb,
        .cancel_fn = cancelCb,
        .model_name = root.provider.model,
        .model_provider = root.provider.id,
        .model_entries = entries,
        .cwd = cwd,
        .yolo = yolo,
        .hud_fn = hudCb,
        .paste_fn = pasteCb,
        .bash_fn = bashCb,
        .files_fn = filesCb,
        .copy_fn = copyCb,
        .compact_fn = compactCb,
        .history_fn = historyCb,
        .idle_wake_fn = idleWakeCb,
    });
}

/// The transcript was cut, so cut the conversation the same way: /new starts
/// over, /rewind takes back the last prompt and everything the engine did for
/// it. Compaction does NOT come through here — it rewrites the conversation
/// rather than discarding it.
fn historyCb(ctx: ?*anyopaque, op: tui.HistoryOp) void {
    const c: *repl_glue.ReplCtx = @ptrCast(@alignCast(ctx orelse return));
    const convo = c.convo orelse return;
    switch (op) {
        .reset => {
            convo.reset();
            @import("rlm_spec.zig").resetBindsSession(c.io);
        },
        .rewind => convo.rewind(),
    }
}

fn idleWakeCb(ctx: ?*anyopaque, buf: []u8) ?[]const u8 {
    const c: *repl_glue.ReplCtx = @ptrCast(@alignCast(ctx orelse return null));
    return job_notify.takeWake(c.io, buf);
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
    events: *tui.EventQueue,
) ?[]const u8 {
    // ADR 0041: the pager is an in-process ACP client. Thought / tool / text
    // arrive as session/update; meters and notices stay on tui_sink.
    return tui_acp.turn(ctx, gpa, history, params, stream, events);
}

/// The catalog the picker draws, with the provider column the TUI used to be
/// blind to. Rows for providers with no credential are KEPT — the catalog is
/// the map of what exists — and marked so the picker can dim them.
///
/// The cost class is classified HERE, on the src side, because it is a fact
/// about credentials (src/billing.zig owns the rule); the TUI is handed the
/// answer. The two enums are mapped by hand so a new class on either side is a
/// compile error rather than a badge that quietly means nothing.
pub fn modelEntries(arena: Allocator, keys: provider_mod.Keys) []const tui.ModelEntry {
    var out = std.array_list.Managed(tui.ModelEntry).init(arena);
    for (pricing.models()) |mi| {
        if (mi.name.len == 0) continue;
        out.append(.{
            .name = mi.name,
            .provider = mi.provider,
            .has_key = keys.get(mi.provider) != null,
            .cost = switch (billing.costFor(mi.provider, keys.source(mi.provider))) {
                .plan => .plan,
                .credits => .credits,
                .api => .api,
                .local => .local,
            },
        }) catch break;
    }
    return out.items;
}

/// A picker row names its provider; a typed `/model <name>` does not and is
/// routed by name, exactly as before.
fn modelCb(ctx: ?*anyopaque, gpa: Allocator, provider: []const u8, name: []const u8) ?tui.Picked {
    const picked = repl_glue.replModelPick(ctx, gpa, provider, name) orelse return null;
    obs.modelSwitch(picked.model);
    return .{ .model = picked.model, .provider = picked.provider };
}

fn compactCb(ctx: ?*anyopaque, gpa: Allocator, history: []const tui.Turn, out: *tui.CompactOut) bool {
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
    var raw: @import("repl_compact.zig").CompactOut = .{};
    const ok = @import("repl_compact.zig").replCompactCb(ctx, gpa, turns.items, &raw);
    out.note = raw.note;
    if (raw.turns.len == 0) {
        out.turns = &.{};
        return ok;
    }
    const converted = gpa.alloc(tui.Turn, raw.turns.len) catch {
        for (raw.turns) |t| gpa.free(t.text);
        gpa.free(raw.turns);
        return ok;
    };
    for (raw.turns, 0..) |t, i| {
        converted[i] = .{ .role = switch (t.role) {
            .user => .user,
            .assistant => .assistant,
        }, .text = t.text };
    }
    gpa.free(raw.turns);
    out.turns = converted;
    return ok;
}

fn cancelCb(ctx: ?*anyopaque) void {
    tui_acp.cancel();
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

/// `!cmd` bash mode — the engine's bash tool, gate and all (repl_bash.zig).
/// It used to call process_runner directly, which is how `/plan` + `!rm -rf`
/// ran the rm and how the model never learned what the user had run (#551).
fn bashCb(ctx: ?*anyopaque, gpa: Allocator, cmd: []const u8, params: tui.Params) ?[]const u8 {
    return repl_bash.replBashCb(ctx, gpa, cmd, .{
        .effort = @enumFromInt(@intFromEnum(params.effort)),
        .fast = params.fast,
        .thinking = params.thinking,
        .ultracode = params.ultracode,
        .mode = switch (params.mode) {
            .normal => .normal,
            .plan => .plan,
            .always_approve => .always_approve,
        },
        .strict = params.strict,
        .goal = params.goal,
    });
}

/// @-mention source: tracked+untracked files (gitignore honored), find fallback.
fn filesCb(ctx: ?*anyopaque, gpa: Allocator) ?[]const u8 {
    const c: *repl_glue.ReplCtx = @ptrCast(@alignCast(ctx orelse return null));
    if (builtin.os.tag == .windows) return null;
    const cmd = "(git ls-files --cached --others --exclude-standard 2>/dev/null || find . -type f -not -path '*/.*' 2>/dev/null | sed 's|^\\./||') | head -3000";
    const run_res = process_runner.runCapped(gpa, c.io, &.{ "/bin/sh", "-c", cmd }, 512 * 1024, 4 * 1024, 10_000) catch return null;
    gpa.free(run_res.stderr);
    if (run_res.stdout.len == 0) {
        gpa.free(run_res.stdout);
        return null;
    }
    return run_res.stdout;
}

fn copyCb(ctx: ?*anyopaque, text: []const u8) bool {
    const c: *repl_glue.ReplCtx = @ptrCast(@alignCast(ctx orelse return false));
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{"pbcopy"},
        .linux => &.{ "xclip", "-selection", "clipboard" },
        else => return false,
    };
    var child = std.process.spawn(c.io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    var wbuf: [4096]u8 = undefined;
    var fw = child.stdin.?.writerStreaming(c.io, &wbuf);
    fw.interface.writeAll(text) catch {};
    fw.interface.flush() catch {};
    child.stdin.?.close(c.io);
    child.stdin = null;
    const term = child.wait(c.io) catch return false;
    return term == .exited and term.exited == 0;
}

fn hudCb(kind: tui.HudKind, buf: []u8) usize {
    var w: Io.Writer = .fixed(buf);
    switch (kind) {
        .debug => obs.renderHud(&w) catch {},
        .usage => obs.renderUsage(&w) catch {},
    }
    if (kind == .debug) {
        if (tui_acp.sessionId()) |sid| w.print("  acp        {s}\n", .{sid}) catch {};
    }
    return w.buffered().len;
}

test {
    _ = tui;
    _ = tui_sink;
    _ = tui_acp;
    _ = repl_bash;
}

test "debug HUD names the in-process ACP session" {
    var s: tui_acp.Session = undefined;
    s.init(std.testing.allocator, 1);
    tui_acp.attach(&s);
    defer tui_acp.detach();
    s.ensure();
    var buf: [2048]u8 = undefined;
    const n = hudCb(.debug, &buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], s.session_id) != null);
}

test "hudCb usage/debug use the cost-tally renderer, not chars" {
    const io = std.testing.io;
    const c = &pricing.g_cost;
    c.mutex.lockUncancelable(io);
    c.usd = 0;
    c.in_tokens = 0;
    c.cache_tokens = 0;
    c.cache_write_tokens = 0;
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
    pricing.g_cost.add(io, .priced, "gpt-5.5", 1000, 200, 0, 50);
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

test "modelEntries carries the provider column the picker was blind to" {
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    _ = keys.set("codex", "tok", .login);
    _ = keys.set("openai", "sk-test", .environment);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const entries = modelEntries(arena_state.allocator(), keys);
    try std.testing.expect(entries.len > 0);
    try std.testing.expectEqual(pricing.models().len, entries.len);

    var codex: ?tui.ModelEntry = null;
    var openai: ?tui.ModelEntry = null;
    var unkeyed: ?tui.ModelEntry = null;
    for (entries) |e| {
        try std.testing.expect(e.provider.len > 0);
        if (codex == null and std.mem.eql(u8, e.provider, "codex")) codex = e;
        if (openai == null and std.mem.eql(u8, e.provider, "openai")) openai = e;
        if (unkeyed == null and std.mem.eql(u8, e.provider, "anthropic")) unkeyed = e;
    }
    // The three classes from the report: a plan seat, a metered seat, and a
    // seat with no credential that stays on the list so the user can see it.
    try std.testing.expectEqual(tui.CostClass.plan, codex.?.cost);
    try std.testing.expect(codex.?.has_key);
    try std.testing.expectEqual(tui.CostClass.api, openai.?.cost);
    try std.testing.expect(openai.?.has_key);
    try std.testing.expectEqual(tui.CostClass.api, unkeyed.?.cost);
    try std.testing.expect(!unkeyed.?.has_key);
}

test "the same model under two providers is two distinguishable entries" {
    // gpt-5.5 is served by codex, openai and codegraff. Before this the picker
    // had three rows reading "gpt-5.5" and no way to tell them apart.
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    _ = keys.set("codex", "tok", .login);
    _ = keys.set("codegraff", "cg", .login);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var seen: usize = 0;
    var costs: [8]tui.CostClass = undefined;
    for (modelEntries(arena_state.allocator(), keys)) |e| {
        if (!std.mem.eql(u8, e.name, "gpt-5.5")) continue;
        if (seen < costs.len) costs[seen] = e.cost;
        seen += 1;
    }
    try std.testing.expect(seen >= 2);
    var has_plan = false;
    var has_credits = false;
    for (costs[0..@min(seen, costs.len)]) |c| {
        if (c == .plan) has_plan = true;
        if (c == .credits) has_credits = true;
    }
    try std.testing.expect(has_plan and has_credits);
}
