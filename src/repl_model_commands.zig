//! `graff repl` Model — the `/`-command dispatcher and the small session
//! mutators it drives (goal text, rewind/compact history, session rename).
//! Split out of the Model struct in repl.zig (#123, 600-line goal); reached
//! through repl.zig's member aliases, so both `self.runCommand(...)` and
//! `Model.runCommand(...)` resolve here unchanged.

const std = @import("std");

const repl = @import("repl.zig");
const Model = repl.Model;

const util = @import("repl_util.zig");
const eqlAny = util.eqlAny;
const parseToggle = util.parseToggle;
const onOff = util.onOff;
const HELP_CHAT = util.HELP_CHAT;

pub fn setGoal(self: *Model, text: []const u8) void {
    if (self.goal) |g| self.alloc.free(g);
    self.goal = if (text.len > 0) (self.alloc.dupe(u8, text) catch null) else null;
}

pub fn runCommand(self: *Model, line: []const u8) void {
    const sp = std.mem.indexOfScalar(u8, line, ' ');
    const cmd = if (sp) |i| line[0..i] else line;
    const arg = std.mem.trim(u8, if (sp) |i| line[i + 1 ..] else "", " \t");

    if (eqlAny(cmd, &.{ "/q", "/quit", "/exit" })) {
        self.quit_requested = true;
    } else if (std.mem.eql(u8, cmd, "/clear")) {
        self.clearHistory();
    } else if (std.mem.eql(u8, cmd, "/new")) {
        self.clearHistory();
        self.turns = 0;
        self.chars_in = 0;
        self.chars_out = 0;
        self.push(.info, "started a new conversation") catch {};
    } else if (std.mem.eql(u8, cmd, "/rewind")) {
        self.rewind();
    } else if (std.mem.eql(u8, cmd, "/compact")) {
        self.compact();
    } else if (std.mem.eql(u8, cmd, "/help")) {
        self.push(.info, if (self.chat) HELP_CHAT else repl.HELP_CALC) catch {};
    } else if (std.mem.eql(u8, cmd, "/model")) {
        if (arg.len == 0) {
            if (repl.g_model_name.len > 0) self.pushFmt(.info, "model: {s}", .{repl.g_model_name}) catch {} else self.push(.info, "no model configured") catch {};
        } else if (repl.g_model_fn) |f| {
            if (f(repl.g_turn_ctx, self.alloc, arg)) |nm| {
                repl.g_model_name = nm;
                self.pushFmt(.info, "switched to {s}", .{nm}) catch {};
            } else self.pushFmt(.err, "couldn't switch to '{s}' — see /models (need a key/login for it)", .{arg}) catch {};
        } else self.push(.info, "model switching isn't available (offline mode)") catch {};
    } else if (std.mem.eql(u8, cmd, "/models")) {
        if (repl.g_models.len > 0) self.pushFmt(.info, "available models:\n  {s}\nswitch with /model <name>", .{repl.g_models}) catch {} else self.push(.info, "no model table (offline mode)") catch {};
    } else if (eqlAny(cmd, &.{ "/effort", "/reasoning" })) {
        const normalized = if (std.mem.eql(u8, arg, "med")) "medium" else if (std.mem.eql(u8, arg, "extra") or std.mem.eql(u8, arg, "extra-high") or std.mem.eql(u8, arg, "extra high")) "xhigh" else arg;
        self.effort = std.meta.stringToEnum(repl.Effort, normalized) orelse {
            self.push(.info, "usage: /effort low|medium|high|xhigh|max|ultra") catch {};
            return;
        };
        self.pushFmt(.info, "reasoning effort: {s}", .{@tagName(self.effort)}) catch {};
    } else if (std.mem.eql(u8, cmd, "/fast")) {
        self.fast = parseToggle(arg, self.fast);
        self.pushFmt(.info, "fast mode: {s}", .{onOff(self.fast)}) catch {};
    } else if (std.mem.eql(u8, cmd, "/thinking")) {
        self.thinking_show = parseToggle(arg, self.thinking_show);
        self.pushFmt(.info, "show thinking: {s}", .{onOff(self.thinking_show)}) catch {};
    } else if (eqlAny(cmd, &.{ "/ultracode", "/ult" })) {
        self.ultracode = parseToggle(arg, self.ultracode);
        self.pushFmt(.info, "ultracode: {s}", .{onOff(self.ultracode)}) catch {};
    } else if (std.mem.eql(u8, cmd, "/strict")) {
        self.strict = parseToggle(arg, self.strict);
        self.pushFmt(.info, "strict mode: {s}", .{onOff(self.strict)}) catch {};
    } else if (std.mem.eql(u8, cmd, "/keepcontext")) {
        self.keepcontext = parseToggle(arg, self.keepcontext);
        self.pushFmt(.info, "keep context: {s}", .{onOff(self.keepcontext)}) catch {};
    } else if (std.mem.eql(u8, cmd, "/plan")) {
        self.plan = parseToggle(arg, self.plan);
        self.pushFmt(.info, "plan mode: {s} (no tools to plan over in the chat repl)", .{onOff(self.plan)}) catch {};
    } else if (std.mem.eql(u8, cmd, "/yolo")) {
        self.yolo = parseToggle(arg, self.yolo);
        self.pushFmt(.info, "yolo: {s} (the chat repl runs no tools — nothing to skip)", .{onOff(self.yolo)}) catch {};
    } else if (std.mem.eql(u8, cmd, "/title")) {
        self.title = parseToggle(arg, self.title);
        self.pushFmt(.info, "ai title: {s}", .{onOff(self.title)}) catch {};
    } else if (std.mem.eql(u8, cmd, "/goal")) {
        self.setGoal(arg);
        if (self.goal) |g| self.pushFmt(.info, "goal set: {s} - I'll track it as a checklist", .{g}) catch {} else self.push(.info, "goal cleared") catch {};
    } else if (std.mem.eql(u8, cmd, "/rename")) {
        self.setSession(arg);
        self.pushFmt(.info, "session renamed: {s}", .{self.session_name orelse "repl"}) catch {};
    } else if (std.mem.eql(u8, cmd, "/animation")) {
        if (std.mem.eql(u8, arg, "enso")) self.anim = .enso else if (std.mem.eql(u8, arg, "dragon")) self.anim = .dragon else if (std.mem.eql(u8, arg, "braille")) self.anim = .braille else {
            self.push(.info, "usage: /animation enso|braille|dragon") catch {};
            return;
        }
        self.pushFmt(.info, "spinner: {s}", .{@tagName(self.anim)}) catch {};
    } else if (std.mem.eql(u8, cmd, "/cost")) {
        self.pushFmt(.info, "session: {d} turn(s) · ~{d} chars sent · ~{d} received", .{ self.turns, self.chars_in, self.chars_out }) catch {};
    } else if (std.mem.eql(u8, cmd, "/debug")) {
        repl.g_debug = !repl.g_debug;
        self.dump_next = repl.g_debug;
        self.pushFmt(.info, "debug: {s} — run `graff repl 2>/tmp/repl.log` to capture (raw agent stream per turn + frames → stderr)", .{onOff(repl.g_debug)}) catch {};
    } else if (std.mem.eql(u8, cmd, "/bash")) {
        self.push(.info, "running shell commands needs the agent loop — use the main `graff` session, or your shell") catch {};
    } else if (std.mem.eql(u8, cmd, "/mcp")) {
        self.push(.info, "MCP servers attach to the agent loop, not the chat repl") catch {};
    } else if (std.mem.eql(u8, cmd, "/skills")) {
        self.push(.info, "skills (codedb, zigrep, …) attach to the agent loop, not the chat repl") catch {};
    } else if (std.mem.eql(u8, cmd, "/agents")) {
        self.push(.info, "named agents are used by the agent loop, not single-shot chat") catch {};
    } else if (std.mem.eql(u8, cmd, "/hooks")) {
        self.push(.info, "hooks run around the agent loop, not the chat repl") catch {};
    } else if (std.mem.eql(u8, cmd, "/loop")) {
        self.push(.info, "`/loop` schedules repeated runs in the main session, not the chat repl") catch {};
    } else if (eqlAny(cmd, &.{ "/trace", "/trajectory" })) {
        self.push(.info, "trace/trajectory logging is a main-session feature") catch {};
    } else if (eqlAny(cmd, &.{ "/save", "/resume", "/sessions" })) {
        self.push(.info, "the chat repl is ephemeral — session save/resume/list lives in the main `graff` session") catch {};
    } else if (eqlAny(cmd, &.{ "/image", "/paste" })) {
        self.push(.info, "image/paste input isn't wired into the chat repl yet") catch {};
    } else if (std.mem.eql(u8, cmd, "/key")) {
        self.push(.info, "manage API keys with `graff key set|list` outside the repl") catch {};
    } else {
        self.pushFmt(.err, "unknown command: {s} — try /help", .{cmd}) catch {};
    }
}

/// Remove the last user turn and everything after it (its reply).
pub fn rewind(self: *Model) void {
    var i = self.history.items.len;
    while (i > 0) : (i -= 1) {
        if (self.history.items[i - 1].kind == .input) break;
    }
    if (i == 0) {
        self.push(.info, "nothing to rewind") catch {};
        return;
    }
    var j = self.history.items.len;
    while (j > i - 1) : (j -= 1) self.alloc.free(self.history.items[j - 1].text);
    self.history.shrinkRetainingCapacity(i - 1);
    self.push(.info, "rewound the last turn") catch {};
}

/// Drop older turns, keeping the welcome banner + the most recent lines.
pub fn compact(self: *Model) void {
    const keep_recent = 6;
    const n = self.history.items.len;
    if (n <= keep_recent + 1) {
        self.push(.info, "nothing to compact") catch {};
        return;
    }
    const drop_to = n - keep_recent;
    var k: usize = 1;
    while (k < drop_to) : (k += 1) self.alloc.free(self.history.items[k].text);
    std.mem.copyForwards(repl.Entry, self.history.items[1..], self.history.items[drop_to..]);
    self.history.shrinkRetainingCapacity(1 + (n - drop_to));
    self.push(.info, "compacted — kept the welcome banner + recent turns") catch {};
}

pub fn setSession(self: *Model, name: []const u8) void {
    if (self.session_name) |s| self.alloc.free(s);
    self.session_name = if (name.len > 0) (self.alloc.dupe(u8, name) catch null) else null;
}
