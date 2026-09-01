//! dispatch.zig command-path tests.

const std = @import("std");

const app = @import("app.zig");
const dispatch = @import("dispatch.zig");
const engine = @import("engine.zig");
const Effect = app.Effect;
const Model = app.Model;
const applyLine = dispatch.applyLine;
const lastLines = dispatch.lastLines;
const looksLikeImagePath = dispatch.looksLikeImagePath;
const rewind = dispatch.rewind;

test "applyLine /quit and /new" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try std.testing.expectEqual(Effect.quit, applyLine(&m, "/quit"));
    m.quit_requested = false;
    try m.push(.user, "keep me");
    _ = applyLine(&m, "/new");
    try std.testing.expectEqual(app.Screen.welcome, m.screen);
    try std.testing.expectEqual(@as(usize, 1), m.history.items.len); // system notice
}

test "/debug opens the observability overlay" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    _ = applyLine(&m, "/debug");
    try std.testing.expectEqual(app.Overlay.debug, m.overlay);
}

test "/cache opens the same observability overlay" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    _ = applyLine(&m, "/cache");
    try std.testing.expectEqual(app.Overlay.debug, m.overlay);
}

test "/usage is not a char-count view" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    _ = applyLine(&m, "/usage");
    const text = m.history.items[m.history.items.len - 1].text;
    try std.testing.expect(std.mem.indexOf(u8, text, "chars sent") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "no session sink") != null);
}

test "rewind drops the last user turn" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "one");
    try m.push(.assistant, "two");
    rewind(&m);
    try std.testing.expectEqual(@as(usize, 1), m.history.items.len); // rewind notice
}

test "core pager commands change shipped model state" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try std.testing.expectEqual(Effect.quit, applyLine(&m, "/exit"));
    m.quit_requested = false;
    try std.testing.expectEqual(Effect.quit, applyLine(&m, "/q"));
    m.quit_requested = false;

    _ = applyLine(&m, "/help");
    try std.testing.expectEqual(app.Overlay.help, m.overlay);
    m.closeOverlay();

    try m.push(.user, "stay");
    _ = applyLine(&m, "/home");
    try std.testing.expectEqual(app.Screen.welcome, m.screen);
    try std.testing.expectEqual(app.Focus.prompt, m.focus);

    try std.testing.expectEqual(app.AgentMode.normal, m.mode);
    _ = applyLine(&m, "/plan");
    try std.testing.expectEqual(app.AgentMode.plan, m.mode);
    _ = applyLine(&m, "/plan");
    try std.testing.expectEqual(app.AgentMode.normal, m.mode);
    _ = applyLine(&m, "/always-approve");
    try std.testing.expectEqual(app.AgentMode.always_approve, m.mode);
    _ = applyLine(&m, "/yolo");
    try std.testing.expectEqual(app.AgentMode.normal, m.mode);

    _ = applyLine(&m, "/settings");
    try std.testing.expectEqual(app.Overlay.settings, m.overlay);
    m.closeOverlay();

    _ = applyLine(&m, "/model");
    try std.testing.expectEqual(app.Overlay.model, m.overlay);
    m.closeOverlay();

    _ = applyLine(&m, "/clear");
    try std.testing.expectEqual(app.Screen.welcome, m.screen);
}

test "/usage with a session HUD is the cost line, not chars" {
    engine.g_hud_fn = struct {
        fn f(kind: engine.HudKind, buf: []u8) usize {
            if (kind != .usage) return 0;
            const s = "1 api call(s) · 1200 in (200 cached) + 50 out tokens · $0.0123\n";
            const n = @min(s.len, buf.len);
            @memcpy(buf[0..n], s[0..n]);
            return n;
        }
    }.f;
    defer engine.g_hud_fn = null;
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    _ = applyLine(&m, "/cost");
    const text = m.history.items[m.history.items.len - 1].text;
    try std.testing.expect(std.mem.indexOf(u8, text, "api call(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "$0.0123") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "chars sent") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "offline") == null);
}

test "/doctor uses the session HUD, not a chrome-only status line (#321)" {
    engine.g_hud_fn = struct {
        fn f(kind: engine.HudKind, buf: []u8) usize {
            if (kind != .doctor) return 0;
            const s = "info   GOAL_STATE  no standing goal\n        no goal is set.\ninfo   JOB_STATE  no background jobs\n";
            const n = @min(s.len, buf.len);
            @memcpy(buf[0..n], s[0..n]);
            return n;
        }
    }.f;
    defer engine.g_hud_fn = null;
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    _ = applyLine(&m, "/doctor");
    const text = m.history.items[m.history.items.len - 1].text;
    try std.testing.expect(std.mem.indexOf(u8, text, "GOAL_STATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ok · model=") == null);
}

test "/doctor via Term paints GOAL_STATE, not a chrome ok line (#321)" {
    engine.g_hud_fn = struct {
        fn f(kind: engine.HudKind, buf: []u8) usize {
            if (kind != .doctor) return 0;
            const s = "info   GOAL_STATE  no standing goal\n        no goal is set.\n";
            const n = @min(s.len, buf.len);
            @memcpy(buf[0..n], s[0..n]);
            return n;
        }
    }.f;
    defer engine.g_hud_fn = null;
    var term: @import("sim.zig").Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();
    _ = term.typeText("/doctor");
    _ = term.enter();
    const vis = try term.screen();
    defer std.testing.allocator.free(vis);
    try std.testing.expect(std.mem.indexOf(u8, vis, "GOAL_STATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, vis, "ok · model=") == null);
}

test "every slash name printed in /help dispatches" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.openOverlay(.help);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try @import("chrome.zig").overlay(&m, arena.allocator(), 80);
    m.closeOverlay();

    var seen: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '/') {
            i += 1;
            continue;
        }
        var j = i + 1;
        while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '-')) j += 1;
        if (j == i + 1) {
            i += 1;
            continue;
        }
        const name = text[i..j];
        const before = m.history.items.len;
        const effect = applyLine(&m, name);
        if (std.mem.eql(u8, name, "/quit") or std.mem.eql(u8, name, "/exit") or std.mem.eql(u8, name, "/q")) {
            try std.testing.expectEqual(Effect.quit, effect);
            m.quit_requested = false;
        } else {
            try std.testing.expectEqual(Effect.stay, effect);
        }
        if (m.history.items.len > before) {
            const last = m.history.items[m.history.items.len - 1].text;
            try std.testing.expect(std.mem.indexOf(u8, last, "unknown command") == null);
        }
        seen += 1;
        i = j;
    }
    try std.testing.expect(seen >= 9);
}

test "/image attaches a path the next send carries as @[path]" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    _ = applyLine(&m, "/image /tmp/shot.png");
    try std.testing.expectEqual(@as(usize, 1), m.images.items.len);
    _ = applyLine(&m, "what is this");
    var user_text: []const u8 = "";
    for (m.history.items) |e| {
        if (e.kind == .user) user_text = e.text;
    }
    try std.testing.expect(std.mem.indexOf(u8, user_text, "@[/tmp/shot.png]") != null);
    try std.testing.expect(std.mem.indexOf(u8, user_text, "what is this") != null);
    try std.testing.expectEqual(@as(usize, 0), m.images.items.len);
}

test "looksLikeImagePath accepts file URLs and extensions" {
    try std.testing.expect(looksLikeImagePath("/tmp/a.png"));
    try std.testing.expect(looksLikeImagePath("file:///Users/me/x.JPEG"));
    try std.testing.expect(!looksLikeImagePath("hello.png is a format"));
    try std.testing.expect(!looksLikeImagePath("readme.md"));
    try std.testing.expect(looksLikeImagePath("/Users/me/My Shot.png"));
    try std.testing.expect(!looksLikeImagePath("see /tmp/a.png"));
}

test "/effort with no arg opens the effort menu" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.effort = .high;
    try std.testing.expectEqual(app.Effect.stay, applyLine(&m, "/effort"));
    try std.testing.expectEqual(app.Overlay.effort, m.overlay);
    try std.testing.expectEqual(@as(usize, @intFromEnum(engine.Effort.high)), m.overlay_sel);
    try std.testing.expectEqual(app.Effect.stay, applyLine(&m, "/effort low"));
    try std.testing.expectEqual(engine.Effort.low, m.effort);
}

test "/vim-mode toggles and /jump without turns explains" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try std.testing.expect(!m.vim_mode);
    _ = applyLine(&m, "/vim-mode");
    try std.testing.expect(m.vim_mode);
    _ = applyLine(&m, "/vim");
    try std.testing.expect(!m.vim_mode);
    _ = applyLine(&m, "/jump");
    const last = m.history.items[m.history.items.len - 1].text;
    try std.testing.expect(std.mem.indexOf(u8, last, "nothing to jump") != null);
    try m.push(.user, "hi");
    _ = applyLine(&m, "/jump");
    try std.testing.expectEqual(app.Overlay.jump, m.overlay);
}

test "/btw queues an aside while a turn is pending" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    const job = try std.testing.allocator.create(engine.Job);
    job.* = .{ .gpa = std.testing.allocator, .history = &.{}, .params = .{}, .stream = .{}, .threaded = false };
    m.pending = job;
    defer {
        m.pending = null;
        std.testing.allocator.destroy(job);
    }
    _ = applyLine(&m, "/btw remember the tests");
    try std.testing.expectEqual(@as(usize, 1), m.steer_queue.items.len);
    try std.testing.expectEqualStrings("remember the tests", m.steer_queue.items[0]);
}

var captured_op: engine.GoalOp = .none;
var captured_goal: []const u8 = "";
var publish_count: u32 = 0;

fn captureGoal(_: ?*anyopaque, state: engine.SessionState) void {
    captured_op = state.goal_op;
    captured_goal = state.goal;
    publish_count += 1;
}

test "/goal pause and clear are lifecycle verbs, not objectives (#716)" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    engine.g_state_fn = captureGoal;
    defer engine.g_state_fn = null;
    publish_count = 0;

    _ = applyLine(&m, "/goal ship it");
    try std.testing.expectEqualStrings("ship it", m.goal.?);
    try std.testing.expectEqual(engine.GoalOp.set, captured_op);
    try std.testing.expectEqualStrings("ship it", captured_goal);

    _ = applyLine(&m, "/goal pause");
    try std.testing.expectEqualStrings("ship it", m.goal.?);
    try std.testing.expectEqual(engine.GoalOp.pause, captured_op);
    const paused = m.history.items[m.history.items.len - 1].text;
    try std.testing.expect(std.mem.indexOf(u8, paused, "paused") != null);

    _ = applyLine(&m, "/goal clear");
    try std.testing.expect(m.goal == null);
    try std.testing.expectEqual(engine.GoalOp.clear, captured_op);
    try std.testing.expectEqualStrings("", captured_goal);
}

test "/goal status and bare /goal do not publish an objective (#716)" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    engine.g_state_fn = captureGoal;
    defer engine.g_state_fn = null;
    publish_count = 0;

    _ = applyLine(&m, "/goal");
    try std.testing.expectEqual(@as(u32, 0), publish_count);
    try std.testing.expect(m.goal == null);
    const bare = m.history.items[m.history.items.len - 1].text;
    try std.testing.expect(std.mem.indexOf(u8, bare, "No active goal") != null);

    _ = applyLine(&m, "/goal ship it");
    const after_set = publish_count;
    _ = applyLine(&m, "/goal status");
    try std.testing.expectEqual(after_set, publish_count);
    try std.testing.expectEqualStrings("ship it", m.goal.?);
    const status = m.history.items[m.history.items.len - 1].text;
    try std.testing.expect(std.mem.indexOf(u8, status, "ship it") != null);
}

test "lastLines caps ! output to the tail" {
    try std.testing.expectEqualStrings("c\nd", lastLines("a\nb\nc\nd", 2));
    try std.testing.expectEqualStrings("a\nb", lastLines("a\nb", 5));
}
