//! Slash-command execution and line submit. UI-only commands live here;
//! model turns spawn a Job through turn.zig.

const std = @import("std");

const app = @import("app.zig");
const catalog = @import("catalog.zig");
const engine = @import("engine.zig");
const theme_mod = @import("theme.zig");
const turn = @import("turn.zig");
const Model = app.Model;
const Effect = app.Effect;

pub fn applyLine(self: *Model, raw: []const u8) Effect {
    const line = std.mem.trim(u8, raw, " \t\r\n");
    if (line.len == 0 and self.images.items.len == 0) return .stay;
    if (line.len > 0) rememberPrompt(self, line);
    if (line.len > 0 and line[0] == '/') return runCommand(self, line);
    if (line.len > 1 and line[0] == '!') return bang(self, std.mem.trim(u8, line[1..], " \t"));
    const prefix = self.takeImagesPrefix(self.alloc);
    const payload = if (prefix.len == 0) line else (std.fmt.allocPrint(self.alloc, "{s}{s}", .{ prefix, line }) catch line);
    if (prefix.len > 0) self.alloc.free(prefix);
    self.push(.user, payload) catch {};
    if (payload.ptr != line.ptr) self.alloc.free(payload);
    if (self.chat) {
        self.turns += 1;
        self.chars_in += line.len;
        turn.startJob(self);
        return .stay;
    }
    self.pushFmt(.system, "offline — no model wired. Use `graff` with a key, or /help.", .{}) catch {};
    return .stay;
}

fn rememberPrompt(self: *Model, line: []const u8) void {
    if (self.alloc.dupe(u8, line)) |dup| {
        self.prompt_hist.append(dup) catch self.alloc.free(dup);
    } else |_| {}
    self.hist_idx = null;
}

pub fn runCommand(self: *Model, line: []const u8) Effect {
    const sp = std.mem.indexOfScalar(u8, line, ' ');
    const cmd = if (sp) |i| line[0..i] else line;
    const arg = std.mem.trim(u8, if (sp) |i| line[i + 1 ..] else "", " \t");
    const item = catalog.lookup(cmd);
    const canon = if (item) |it| it.name else cmd;

    if (std.mem.eql(u8, canon, "/quit")) {
        self.quit_requested = true;
        return .quit;
    } else if (std.mem.eql(u8, canon, "/new")) {
        self.clearHistory();
        self.push(.system, "started a new conversation") catch {};
        self.screen = .welcome;
    } else if (std.mem.eql(u8, canon, "/home")) {
        self.screen = .welcome;
        self.focus = .prompt;
    } else if (std.mem.eql(u8, canon, "/rewind")) {
        rewind(self);
    } else if (std.mem.eql(u8, canon, "/compact")) {
        compact(self);
    } else if (std.mem.eql(u8, canon, "/help")) {
        self.openOverlay(.help);
    } else if (std.mem.eql(u8, canon, "/shortcuts")) {
        self.openOverlay(.help);
    } else if (std.mem.eql(u8, canon, "/theme")) {
        if (arg.len == 0) {
            self.openOverlay(.theme);
        } else if (theme_mod.parse(arg)) |id| {
            self.theme_id = id;
            self.theme_explicit = true;
            self.pushFmt(.system, "theme: {s}", .{id.label()}) catch {};
        } else {
            self.pushFmt(.err, "unknown theme '{s}' — night|day|tokyo|rose|oscura", .{arg}) catch {};
        }
    } else if (std.mem.eql(u8, canon, "/settings")) {
        self.openOverlay(.settings);
    } else if (std.mem.eql(u8, canon, "/model")) {
        if (arg.len == 0) {
            self.openOverlay(.model);
        } else if (engine.g_model_fn) |f| {
            if (f(engine.g_turn_ctx, self.alloc, arg)) |nm| {
                engine.g_model_name = nm;
                self.pushFmt(.system, "switched to {s}", .{nm}) catch {};
            } else self.pushFmt(.err, "couldn't switch to '{s}'", .{arg}) catch {};
        } else self.push(.system, "model switching isn't available (offline)") catch {};
    } else if (std.mem.eql(u8, canon, "/effort")) {
        if (arg.len == 0) {
            self.openOverlay(.effort);
            self.overlay_sel = @intFromEnum(self.effort);
            return .stay;
        }
        const normalized = if (std.mem.eql(u8, arg, "med")) "medium" else arg;
        self.effort = std.meta.stringToEnum(engine.Effort, normalized) orelse {
            self.push(.system, "usage: /effort low|medium|high|xhigh|max|ultra") catch {};
            return .stay;
        };
        self.pushFmt(.system, "reasoning effort: {s}", .{@tagName(self.effort)}) catch {};
    } else if (std.mem.eql(u8, canon, "/always-approve")) {
        self.mode = if (self.mode == .always_approve) .normal else .always_approve;
        self.pushFmt(.system, "mode: {s}", .{self.modeLabel()}) catch {};
    } else if (std.mem.eql(u8, canon, "/plan")) {
        self.mode = if (self.mode == .plan) .normal else .plan;
        self.pushFmt(.system, "mode: {s}", .{self.modeLabel()}) catch {};
    } else if (std.mem.eql(u8, canon, "/multiline")) {
        self.multiline = !self.multiline;
        self.pushFmt(.system, "multiline: {s}", .{onOff(self.multiline)}) catch {};
    } else if (std.mem.eql(u8, canon, "/compact-mode")) {
        self.compact_mode = !self.compact_mode;
        self.pushFmt(.system, "compact mode: {s}", .{onOff(self.compact_mode)}) catch {};
    } else if (std.mem.eql(u8, canon, "/thinking")) {
        self.thinking_show = !self.thinking_show;
        self.pushFmt(.system, "show thinking: {s}", .{onOff(self.thinking_show)}) catch {};
    } else if (std.mem.eql(u8, canon, "/fast")) {
        self.fast = !self.fast;
        self.pushFmt(.system, "fast: {s}", .{onOff(self.fast)}) catch {};
    } else if (std.mem.eql(u8, canon, "/ultracode")) {
        self.ultracode = !self.ultracode;
        self.pushFmt(.system, "ultracode: {s}", .{onOff(self.ultracode)}) catch {};
    } else if (std.mem.eql(u8, canon, "/strict")) {
        self.strict = !self.strict;
        self.pushFmt(.system, "strict: {s}", .{onOff(self.strict)}) catch {};
    } else if (std.mem.eql(u8, canon, "/goal")) {
        if (self.goal) |g| self.alloc.free(g);
        self.goal = if (arg.len > 0) (self.alloc.dupe(u8, arg) catch null) else null;
        if (self.goal) |g| self.pushFmt(.system, "goal set: {s}", .{g}) catch {} else self.push(.system, "goal cleared") catch {};
    } else if (std.mem.eql(u8, canon, "/rename")) {
        if (self.session_name) |s| self.alloc.free(s);
        self.session_name = if (arg.len > 0) (self.alloc.dupe(u8, arg) catch null) else null;
        self.pushFmt(.system, "session: {s}", .{self.session_name orelse "untitled"}) catch {};
    } else if (std.mem.eql(u8, canon, "/session-info")) {
        self.pushFmt(.system, "{s} · {s} · {d} turn(s) · ~{d} in / ~{d} out · {s}", .{ self.modeLabel(), engine.g_model_name, self.turns, self.chars_in, self.chars_out, engine.g_cwd }) catch {};
    } else if (std.mem.eql(u8, canon, "/debug")) {
        self.openOverlay(.debug);
    } else if (std.mem.eql(u8, canon, "/usage")) {
        var buf: [512]u8 = undefined;
        if (engine.g_hud_fn) |f| {
            const n = f(.usage, &buf);
            if (n > 0) self.push(.system, buf[0..n]) catch {};
        } else {
            self.push(.system, "usage unavailable (no session sink)") catch {};
        }
    } else if (std.mem.eql(u8, canon, "/context")) {
        self.pushFmt(.system, "context: {d} chars sent, {d} received this session", .{ self.chars_in, self.chars_out }) catch {};
    } else if (std.mem.eql(u8, canon, "/history")) {
        recallPrev(self);
    } else if (std.mem.eql(u8, canon, "/image")) {
        if (arg.len == 0) {
            self.push(.system, "usage: /image <path.png|jpg|gif|webp>") catch {};
        } else self.attachImage(arg);
    } else if (std.mem.eql(u8, canon, "/paste")) {
        pasteClipboard(self);
    } else if (std.mem.eql(u8, canon, "/doctor")) {
        self.pushFmt(.system, "ok · model={s} · cwd={s} · theme={s} · vim={s}", .{ engine.g_model_name, engine.g_cwd, @tagName(self.theme_id), onOff(self.vim_mode) }) catch {};
    } else if (std.mem.eql(u8, canon, "/import-claude")) {
        self.push(.system, "adopting Claude/Cursor MCP writes ~/.codegraff — run `graff mcp import` from this repo") catch {};
    } else if (std.mem.eql(u8, canon, "/jump")) {
        if (self.userTurnCount() == 0) {
            self.push(.system, "nothing to jump to yet") catch {};
        } else self.openOverlay(.jump);
    } else if (std.mem.eql(u8, canon, "/vim-mode")) {
        self.vim_mode = !self.vim_mode;
        self.pushFmt(.system, "vim scrollback: {s}", .{onOff(self.vim_mode)}) catch {};
    } else if (std.mem.eql(u8, canon, "/copy")) {
        copyLastReply(self);
    } else if (std.mem.eql(u8, canon, "/btw")) {
        if (arg.len == 0) {
            self.push(.system, "usage: /btw <aside> — queue a note without interrupting") catch {};
        } else if (self.pending != null) {
            if (self.alloc.dupe(u8, arg)) |dup| {
                self.steer_queue.append(dup) catch self.alloc.free(dup);
                self.pushFmt(.system, "↳ aside queued ({d} waiting)", .{self.steer_queue.items.len}) catch {};
            } else |_| {}
        } else {
            return applyLine(self, arg);
        }
    } else {
        self.pushFmt(.err, "unknown command: {s} — try /help", .{cmd}) catch {};
    }
    return if (self.quit_requested) .quit else .stay;
}

/// `!cmd` — run a shell line locally (grok-style bash mode). Output stays
/// out of the model history: EntryKind.system never reaches startJob.
fn bang(self: *Model, cmd: []const u8) Effect {
    if (cmd.len == 0) return .stay;
    self.pushFmt(.system, "$ {s}", .{cmd}) catch {};
    if (engine.g_bash_fn == null) {
        self.push(.err, "! needs a live session (offline)") catch {};
        return .stay;
    }
    if (engine.g_bash_fn.?(engine.g_turn_ctx, self.alloc, cmd)) |out| {
        defer self.alloc.free(out);
        self.push(.system, lastLines(out, 40)) catch {};
    } else {
        self.push(.err, "command failed to start") catch {};
    }
    return .stay;
}

/// Tail of `s` capped to `max` lines, for `!` output in the scrollback.
fn lastLines(s: []const u8, max: usize) []const u8 {
    var count: usize = 0;
    var i = s.len;
    while (i > 0) {
        i -= 1;
        if (s[i] == '\n') {
            count += 1;
            if (count == max) return s[i + 1 ..];
        }
    }
    return s;
}

fn copyLastReply(self: *Model) void {
    var i = self.history.items.len;
    const text: ?[]const u8 = while (i > 0) {
        i -= 1;
        if (self.history.items[i].kind == .assistant) break self.history.items[i].text;
    } else null;
    if (text == null) {
        self.push(.system, "nothing to copy yet") catch {};
    } else if (engine.g_copy_fn) |f| {
        self.setToast(if (f(engine.g_turn_ctx, text.?)) "copied last reply" else "copy failed");
    } else self.setToast("clipboard needs a live session");
}

pub fn rewind(self: *Model) void {
    var i = self.history.items.len;
    while (i > 0) : (i -= 1) {
        if (self.history.items[i - 1].kind == .user) break;
    }
    if (i == 0) {
        self.push(.system, "nothing to rewind") catch {};
        return;
    }
    var j = self.history.items.len;
    while (j > i - 1) : (j -= 1) self.alloc.free(self.history.items[j - 1].text);
    self.history.shrinkRetainingCapacity(i - 1);
    self.push(.system, "rewound the last turn") catch {};
}

pub fn compact(self: *Model) void {
    const keep = 6;
    const n = self.history.items.len;
    if (n <= keep) {
        self.push(.system, "nothing to compact") catch {};
        return;
    }
    const drop_to = n - keep;
    var k: usize = 0;
    while (k < drop_to) : (k += 1) self.alloc.free(self.history.items[k].text);
    std.mem.copyForwards(app.Entry, self.history.items[0..], self.history.items[drop_to..]);
    self.history.shrinkRetainingCapacity(n - drop_to);
    self.push(.system, "compacted — kept recent turns") catch {};
}

pub fn recallPrev(self: *Model) void {
    if (self.prompt_hist.items.len == 0) return;
    const next_i: usize = if (self.hist_idx) |i| (if (i == 0) 0 else i - 1) else self.prompt_hist.items.len - 1;
    self.hist_idx = next_i;
    self.input.setValue(self.prompt_hist.items[next_i]) catch {};
}

pub fn recallNext(self: *Model) void {
    const i = self.hist_idx orelse return;
    if (i + 1 >= self.prompt_hist.items.len) {
        self.hist_idx = null;
        self.input.setValue("") catch {};
        return;
    }
    self.hist_idx = i + 1;
    self.input.setValue(self.prompt_hist.items[i + 1]) catch {};
}

pub fn pasteClipboard(self: *Model) void {
    if (engine.g_paste_fn) |f| {
        var buf: [1024]u8 = undefined;
        const n = f(engine.g_turn_ctx, &buf);
        if (n > 0) {
            self.attachImage(buf[0..@intCast(n)]);
        } else if (n < 0) {
            self.setToast(buf[0..@intCast(-n)]);
        } else self.setToast("no image on the clipboard — Ctrl+V (⌘V can't be captured)");
    } else self.setToast("image paste needs a live session");
}

pub fn looksLikeImagePath(s: []const u8) bool {
    var t = std.mem.trim(u8, s, " \t\r\n\"'");
    if (std.mem.startsWith(u8, t, "file://")) t = t["file://".len..];
    const exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp" };
    var ok = false;
    for (exts) |e| {
        if (t.len >= e.len and std.ascii.eqlIgnoreCase(t[t.len - e.len ..], e)) {
            ok = true;
            break;
        }
    }
    if (!ok) return false;
    if (std.mem.indexOfAny(u8, t, " \t") != null) {
        return t[0] == '/' or t[0] == '~' or t[0] == '.';
    }
    return true;
}

fn onOff(v: bool) []const u8 {
    return if (v) "on" else "off";
}

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

test "/usage is not a char-count view" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.chars_in = 99;
    m.chars_out = 88;
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
    m.chars_in = 99;
    _ = applyLine(&m, "/cost");
    const text = m.history.items[m.history.items.len - 1].text;
    try std.testing.expect(std.mem.indexOf(u8, text, "api call(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "$0.0123") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "chars sent") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "offline") == null);
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

test "! runs through the bash callback and lands in the scrollback" {
    engine.g_bash_fn = struct {
        fn f(_: ?*anyopaque, gpa: std.mem.Allocator, cmd: []const u8) ?[]const u8 {
            return std.fmt.allocPrint(gpa, "ran: {s}", .{cmd}) catch null;
        }
    }.f;
    defer engine.g_bash_fn = null;
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    _ = applyLine(&m, "!git status");
    try std.testing.expectEqual(@as(usize, 2), m.history.items.len);
    try std.testing.expectEqualStrings("$ git status", m.history.items[0].text);
    try std.testing.expectEqualStrings("ran: git status", m.history.items[1].text);
    try std.testing.expectEqual(app.EntryKind.system, m.history.items[1].kind);
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

test "lastLines caps ! output to the tail" {
    try std.testing.expectEqualStrings("c\nd", lastLines("a\nb\nc\nd", 2));
    try std.testing.expectEqualStrings("a\nb", lastLines("a\nb", 5));
}
