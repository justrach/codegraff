//! Slash-command execution and line submit. UI-only commands live here;
//! model turns spawn a Job through turn.zig.

const std = @import("std");

const app = @import("app.zig");
const bgop = @import("bgop.zig");
const catalog = @import("catalog.zig");
const engine = @import("engine.zig");
const peer_cmd = @import("peer_cmd.zig");
const resume_mod = @import("resume.zig");
const meters = @import("meters.zig");
const theme_mod = @import("theme.zig");
const turn = @import("turn.zig");
const Model = app.Model;
const Effect = app.Effect;

/// Shown whenever an engine call is already in flight — /compact, `!cmd` and
/// a model turn all use the one engine, so they queue behind each other.
pub const busy_note = "an engine call is still running — press Esc to cancel it";

/// A production model switch replaces ReplCtx.provider and clears its fallback
/// flags. Turns and background ops borrow that same context, so the mutation
/// waits for the existing one-engine policy even within one input batch.
/// Browsing the picker remains UI-only; callers use this at confirmation.
pub fn refuseProviderMutation(self: *Model) bool {
    if (self.pending == null and self.bg == null) return false;
    self.push(.system, busy_note) catch {};
    return true;
}

pub fn applyLine(self: *Model, raw: []const u8) Effect {
    const line = std.mem.trim(u8, raw, " \t\r\n");
    if (line.len == 0 and self.images.items.len == 0) return .stay;
    if (line.len > 0 or self.images.items.len > 0) rememberPrompt(self, line);
    if (line.len > 0 and line[0] == '/') return runCommand(self, line);
    if (line.len > 1 and line[0] == '!') return bang(self, std.mem.trim(u8, line[1..], " \t"));
    if (self.bg != null) {
        // /compact rewrites the history the next turn would send — never race
        // a turn against it.
        self.push(.system, busy_note) catch {};
        return .stay;
    }
    const prefix = self.takeImagesPrefix(self.alloc);
    const payload = if (prefix.len == 0) line else (std.fmt.allocPrint(self.alloc, "{s}{s}", .{ prefix, line }) catch line);
    if (prefix.len > 0) self.alloc.free(prefix);
    self.push(.user, payload) catch {};
    if (payload.ptr != line.ptr) self.alloc.free(payload);
    if (self.chat) {
        self.turns += 1;
        turn.startJob(self);
        return .stay;
    }
    self.pushFmt(.system, "offline — no model wired. Use `graff` with a key, or /help.", .{}) catch {};
    return .stay;
}

fn rememberPrompt(self: *Model, line: []const u8) void {
    @import("prompt_history.zig").remember(self, line);
}

pub fn runCommand(self: *Model, line: []const u8) Effect {
    const sp = std.mem.indexOfScalar(u8, line, ' ');
    const cmd = if (sp) |i| line[0..i] else line;
    const arg = std.mem.trim(u8, if (sp) |i| line[i + 1 ..] else "", " \t");
    const item = catalog.lookup(cmd);
    const canon = if (item) |it| it.name else cmd;

    // #521: history-destroying commands must not run under a live job — the
    // steer guard in promptKey only covers plain text, and the slash menu,
    // palette, and steer drain all land here.
    const destroys = std.mem.eql(u8, canon, "/new") or std.mem.eql(u8, canon, "/compact") or std.mem.eql(u8, canon, "/rewind") or std.mem.eql(u8, canon, "/resume");
    if (self.pending != null and destroys) {
        self.push(.system, "a turn is still running — press Esc to cancel it first") catch {};
        return .stay;
    }
    // Same for a background engine op: /compact is itself one of them.
    if (self.bg != null and destroys) {
        self.push(.system, busy_note) catch {};
        return .stay;
    }

    if (std.mem.eql(u8, canon, "/quit")) {
        self.quit_requested = true;
        return .quit;
    } else if (std.mem.eql(u8, canon, "/new")) {
        _ = self.newSession(); // the `destroys` guard above already refused a live call
        self.push(.system, "started a new conversation") catch {};
        self.screen = .welcome;
    } else if (std.mem.eql(u8, canon, "/resume")) {
        resume_mod.run(self, arg);
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
        } else if (refuseProviderMutation(self)) {
            return .stay;
        } else if (engine.g_model_fn) |f| {
            // A hand-typed name names no provider, so the engine routes it —
            // the picker is the surface that knows which seat was meant.
            if (f(engine.g_turn_ctx, self.alloc, "", arg)) |got| {
                self.adoptModel(got);
                self.pushFmt(.system, "switched to {s} · {s}", .{ got.model, got.provider }) catch {};
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
        publishState(self);
        self.pushFmt(.system, "ultracode: {s}", .{onOff(self.ultracode)}) catch {};
    } else if (std.mem.eql(u8, canon, "/strict")) {
        self.strict = !self.strict;
        publishState(self);
        self.pushFmt(.system, "strict: {s}", .{onOff(self.strict)}) catch {};
    } else if (std.mem.eql(u8, canon, "/goal")) {
        if (self.goal) |g| self.alloc.free(g);
        self.goal = if (arg.len > 0) (self.alloc.dupe(u8, arg) catch null) else null;
        publishState(self);
        if (self.goal) |g| self.pushFmt(.system, "goal set: {s}", .{g}) catch {} else self.push(.system, "goal cleared") catch {};
    } else if (std.mem.eql(u8, canon, "/rename")) {
        if (self.session_name) |s| self.alloc.free(s);
        self.session_name = if (arg.len > 0) (self.alloc.dupe(u8, arg) catch null) else null;
        publishState(self);
        self.pushFmt(.system, "session: {s}", .{self.session_name orelse "untitled"}) catch {};
    } else if (std.mem.eql(u8, canon, "/session-info")) {
        meters.sessionInfo(self);
    } else if (std.mem.eql(u8, canon, "/debug") or std.mem.eql(u8, canon, "/cache")) {
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
        meters.contextInfo(self);
    } else if (std.mem.eql(u8, canon, "/history")) {
        recallPrev(self);
    } else if (std.mem.eql(u8, canon, "/image")) {
        if (arg.len == 0) {
            self.push(.system, "usage: /image <path.png|jpg|gif|webp>") catch {};
        } else self.attachImage(arg);
    } else if (std.mem.eql(u8, canon, "/paste")) {
        pasteClipboard(self);
    } else if (std.mem.eql(u8, canon, "/doctor")) {
        self.pushFmt(.system, "ok · model={s} via {s} · cwd={s} · theme={s} · vim={s}", .{ engine.g_model_name, engine.g_model_provider, engine.g_cwd, @tagName(self.theme_id), onOff(self.vim_mode) }) catch {};
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
    } else if (std.mem.eql(u8, canon, "/tell") or std.mem.eql(u8, canon, "/peek")) {
        peer_cmd.run(self, canon, arg);
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

fn publishState(self: *Model) void {
    if (engine.g_state_fn) |f| f(engine.g_turn_ctx, .{
        .session_name = self.session_name orelse "",
        .goal = self.goal orelse "",
        .strict = self.strict,
        .ultracode = self.ultracode,
    });
}

/// `!cmd` — run a shell line locally (grok-style bash mode) on a background
/// thread, so a slow command no longer freezes the frame for its whole 20s
/// cap (#533). Output stays out of the model history: EntryKind.system never
/// reaches startJob.
fn bang(self: *Model, cmd: []const u8) Effect {
    if (cmd.len == 0) return .stay;
    self.pushFmt(.system, "$ {s}", .{cmd}) catch {};
    if (engine.g_bash_fn == null) {
        self.push(.err, "! needs a live session (offline)") catch {};
        return .stay;
    }
    const owned = self.alloc.dupe(u8, cmd) catch return .stay;
    if (!bgop.start(self, .bash, &.{}, owned, "running")) {
        self.alloc.free(owned);
        self.push(.system, busy_note) catch {};
    }
    return .stay;
}

/// Tail of `s` capped to `max` lines, for `!` output in the scrollback.
pub fn lastLines(s: []const u8, max: usize) []const u8 {
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
    // Same reason newSession refuses: the rewind reaches the engine's history,
    // and the rewind overlay's Enter does not go through runCommand's guard.
    if (self.pending != null or self.bg != null) {
        self.push(.system, busy_note) catch {};
        return;
    }
    var i = self.history.items.len;
    while (i > 0) : (i -= 1) {
        if (self.history.items[i - 1].kind == .user) break;
    }
    if (i == 0) {
        self.push(.system, "nothing to rewind") catch {};
        return;
    }
    var j = self.history.items.len;
    while (j > i - 1) : (j -= 1) self.freeEntry(self.history.items[j - 1]);
    self.history.shrinkRetainingCapacity(i - 1);
    // The engine holds the conversation, so taking the turn back has to reach
    // it too — otherwise the next request still carries the prompt the user
    // just withdrew (#551).
    engine.historyChanged(.rewind);
    self.push(.system, "rewound the last turn") catch {};
}

/// `/compact` — hand the history to the engine on a background thread. Running
/// it inline froze the render+input loop for the whole summarization round
/// trip, with no paint, no key handling and no way to cancel (#533).
pub fn compact(self: *Model) void {
    if (engine.g_compact_fn == null) {
        self.push(.system, "compaction needs a live session") catch {};
        return;
    }
    var turns = std.array_list.Managed(engine.Turn).init(self.alloc);
    for (self.history.items) |e| {
        const role: ?engine.Turn.Role = switch (e.kind) {
            .user => .user,
            .assistant => .assistant,
            else => null,
        };
        if (role) |r| {
            const t = self.alloc.dupe(u8, e.text) catch continue;
            turns.append(.{ .role = r, .text = t }) catch self.alloc.free(t);
        }
    }
    const owned: []engine.Turn = turns.toOwnedSlice() catch &.{};
    if (!bgop.start(self, .compact, owned, "", "compacting")) {
        for (owned) |t| self.alloc.free(t.text);
        if (owned.len > 0) self.alloc.free(owned);
        self.push(.system, busy_note) catch {};
    }
}

pub fn recallPrev(self: *Model) void {
    @import("prompt_history.zig").recallPrev(self);
}

pub fn recallNext(self: *Model) void {
    @import("prompt_history.zig").recallNext(self);
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

test {
    _ = @import("dispatch_tests.zig"); // overflow tests (600-line cap)
    _ = @import("dispatch_command_tests.zig");
}
