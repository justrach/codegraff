//! `graff repl` — an interactive chat REPL on the zigzag TUI, styled like
//! Claude Code: a bordered welcome box with the `✻` accent, conversation turns
//! (`>` you, `⏺` the model), a rounded input box pinned to the bottom, a status
//! line, and `/`-style commands mirroring the harness's interactive set.
//!
//! Spike branch: spike/zigzag-repl. Reachable as `graff repl` (subcommand of
//! the main binary) and the standalone `graff-repl` exe — both call `run()`.
//!
//! The model call runs on a background thread so the braille thinking spinner
//! animates while it works (the zigzag loop re-renders every frame). The whole
//! conversation is sent each turn (multi-turn memory). Without a model wired in
//! (standalone exe) it falls back to a pure i64 arithmetic evaluator, which
//! keeps it fully unit-testable.

const std = @import("std");
const zz = @import("zigzag");

// ---------------------------------------------------------------------------
// Arithmetic evaluator — pure, allocation-free. Offline fallback engine + the
// thing the headless tests exercise.
// ---------------------------------------------------------------------------

pub const EvalError = error{ SyntaxError, DivByZero, Overflow };

const Parser = struct {
    src: []const u8,
    pos: usize = 0,

    fn skipWs(self: *Parser) void {
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or
            self.src[self.pos] == '\t')) : (self.pos += 1)
        {}
    }
    fn peek(self: *Parser) ?u8 {
        self.skipWs();
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }
    fn expr(self: *Parser) EvalError!i64 {
        var acc = try self.term();
        while (self.peek()) |c| {
            if (c != '+' and c != '-') break;
            self.pos += 1;
            const rhs = try self.term();
            acc = if (c == '+') try std.math.add(i64, acc, rhs) else try std.math.sub(i64, acc, rhs);
        }
        return acc;
    }
    fn term(self: *Parser) EvalError!i64 {
        var acc = try self.factor();
        while (self.peek()) |c| {
            if (c != '*' and c != '/' and c != '%') break;
            self.pos += 1;
            const rhs = try self.factor();
            switch (c) {
                '*' => acc = try std.math.mul(i64, acc, rhs),
                '/' => {
                    if (rhs == 0) return error.DivByZero;
                    if (acc == std.math.minInt(i64) and rhs == -1) return error.Overflow;
                    acc = @divTrunc(acc, rhs);
                },
                else => {
                    if (rhs == 0) return error.DivByZero;
                    if (acc == std.math.minInt(i64) and rhs == -1) return error.Overflow;
                    acc = @rem(acc, rhs);
                },
            }
        }
        return acc;
    }
    fn factor(self: *Parser) EvalError!i64 {
        const c = self.peek() orelse return error.SyntaxError;
        if (c == '-') {
            self.pos += 1;
            return std.math.negate(try self.factor()) catch error.Overflow;
        }
        if (c == '+') {
            self.pos += 1;
            return self.factor();
        }
        if (c == '(') {
            self.pos += 1;
            const v = try self.expr();
            if (self.peek() != @as(?u8, ')')) return error.SyntaxError;
            self.pos += 1;
            return v;
        }
        if (!std.ascii.isDigit(c)) return error.SyntaxError;
        const start = self.pos;
        while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) : (self.pos += 1) {}
        return std.fmt.parseInt(i64, self.src[start..self.pos], 10) catch error.Overflow;
    }
};

pub fn eval(src: []const u8) EvalError!i64 {
    var p = Parser{ .src = src };
    const v = try p.expr();
    if (p.peek() != null) return error.SyntaxError;
    return v;
}

// ---------------------------------------------------------------------------
// Model hook — injected by the host (src/main.zig). The callback receives the
// whole conversation + the current thinking settings and returns a reply
// allocated with the given allocator (caller owns), or null on failure. This
// keeps repl.zig decoupled from the harness's Agent/Provider (no circular import).
// ---------------------------------------------------------------------------

pub const Effort = enum { low, medium, high };

pub const Turn = struct {
    role: Role,
    text: []const u8,
    pub const Role = enum { user, assistant };
};

pub const Params = struct {
    effort: Effort = .medium,
    fast: bool = false,
    thinking: bool = false,
    ultracode: bool = false,
    goal: []const u8 = "", // "" = none
};

pub const StreamBuf = struct {
    // Single-writer (worker thread) / single-reader (render loop), lock-free: a
    // fixed pre-allocated buffer (no realloc → stable pointer) + an atomic
    // length. The worker appends bytes then release-stores the new length; the
    // reader acquire-loads it and reads the committed prefix. Overflow drops
    // extra bytes — only the live preview is affected (the final reply uses
    // runTurn's return value).
    buf: []u8 = &.{},
    len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    pub fn appendBytes(self: *StreamBuf, bytes: []const u8) void {
        const cur = self.len.load(.monotonic);
        if (cur >= self.buf.len) return;
        const n = @min(bytes.len, self.buf.len - cur);
        @memcpy(self.buf[cur .. cur + n], bytes[0..n]);
        self.len.store(cur + n, .release);
    }
    pub fn snapshot(self: *StreamBuf, gpa: std.mem.Allocator) ?[]u8 {
        const n = self.len.load(.acquire);
        if (n == 0) return null;
        return gpa.dupe(u8, self.buf[0..n]) catch null;
    }
};

pub const TurnFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator, history: []const Turn, params: Params, stream: *StreamBuf) ?[]const u8;

var g_turn_fn: ?TurnFn = null;
var g_turn_ctx: ?*anyopaque = null;
var g_model_name: []const u8 = "";
pub const ModelFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator, name: []const u8) ?[]const u8;
var g_models: []const u8 = ""; // comma-joined model names (for /models)
var g_model_fn: ?ModelFn = null; // switch the active model by name
var g_debug: bool = false; // GRAFF_REPL_DEBUG / `/debug` → dump raw stream + frames to stderr

// ---------------------------------------------------------------------------
// Look & feel.
// ---------------------------------------------------------------------------

const accent = zz.Color.fromRgb(0xD9, 0x77, 0x57); // Claude coral

/// `/ultracode` rainbow shine — sweeps across the input border per frame.
const rainbow = [_]zz.Color{
    zz.Color.fromRgb(0xFF, 0x5C, 0x57), zz.Color.fromRgb(0xFF, 0x9F, 0x43),
    zz.Color.fromRgb(0xFE, 0xD3, 0x30), zz.Color.fromRgb(0x6B, 0xCB, 0x77),
    zz.Color.fromRgb(0x4D, 0x96, 0xFF), zz.Color.fromRgb(0xB1, 0x7A, 0xFF),
};

const braille_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const dragon_frames = [_][]const u8{ "🐉  ", "🐉 ✦", "🐉 ✧", "🐉 ✦" };

const Anim = enum { braille, dragon };

const POLL_NS: u64 = 50 * std.time.ns_per_ms;

// ---------------------------------------------------------------------------
// Background model call.
// ---------------------------------------------------------------------------

const Job = struct {
    thread: std.Thread = undefined,
    threaded: bool = true,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result: ?[]const u8 = null,
    gpa: std.mem.Allocator,
    history: []Turn, // owned snapshot
    params: Params,
    stream: StreamBuf,
};

fn jobRun(job: *Job) void {
    const reply = if (g_turn_fn) |f| f(g_turn_ctx, job.gpa, job.history, job.params, &job.stream) else null;
    job.result = reply;
    job.done.store(true, .release);
}

// ---------------------------------------------------------------------------
// Model.
// ---------------------------------------------------------------------------

const Entry = struct {
    kind: Kind,
    text: []const u8, // owned by Model.alloc
    const Kind = enum { welcome, input, result, err, info, pending, assistant };
};

const Effect = enum { stay, quit };

pub const Model = struct {
    alloc: std.mem.Allocator,
    input: zz.TextInput,
    history: std.array_list.Managed(Entry),
    pending: ?*Job = null,

    // Settings (mirror the harness thinking controls).
    chat: bool = false,
    effort: Effort = .medium,
    fast: bool = false,
    thinking_show: bool = false,
    ultracode: bool = false,
    goal: ?[]const u8 = null, // owned
    anim: Anim = .braille,
    scroll: usize = 0,
    // Mouse drag-selection → auto-copy (OSC52). Screen rows, 0-based.
    sel_anchor_row: ?usize = null,
    sel_cur_row: ?usize = null,
    view_start: usize = 0,
    view_rows: usize = 0,
    visible_text: std.array_list.Managed([]const u8) = undefined, // owned plaintext of visible rows
    dump_next: bool = false,
    quit_requested: bool = false,
    keepcontext: bool = true,
    strict: bool = false,
    yolo: bool = false,
    plan: bool = false,
    title: bool = true,
    session_name: ?[]const u8 = null,
    turns: usize = 0,
    chars_in: usize = 0,
    chars_out: usize = 0,

    pub const Tick = struct { timestamp: u64, delta: u64 };
    pub const Msg = union(enum) { key: zz.KeyEvent, tick: Tick, mouse: zz.MouseEvent };

    pub fn setup(self: *Model, alloc: std.mem.Allocator) void {
        self.* = .{
            .alloc = alloc,
            .input = zz.TextInput.init(alloc),
            .history = std.array_list.Managed(Entry).init(alloc),
            .visible_text = std.array_list.Managed([]const u8).init(alloc),
            .chat = g_turn_fn != null,
        };
        self.input.setPrompt("> ");
        self.input.setPlaceholder(if (self.chat) "Ask anything, or /help" else "Try an expression, or /help");
        self.push(.welcome, "") catch {};
    }

    pub fn init(self: *Model, ctx: *zz.Context) zz.Cmd(Msg) {
        self.setup(ctx.persistent_allocator);
        return .none;
    }

    pub fn deinit(self: *Model) void {
        if (self.pending) |job| {
            if (job.threaded) job.thread.join();
            if (job.result) |r| self.alloc.free(r);
            for (job.history) |t| self.alloc.free(t.text);
            self.alloc.free(job.history);
            if (job.stream.buf.len > 0) self.alloc.free(job.stream.buf);
            self.alloc.destroy(job);
            self.pending = null;
        }
        for (self.history.items) |e| self.alloc.free(e.text);
        self.history.deinit();
        if (self.goal) |g| self.alloc.free(g);
        if (self.session_name) |s| self.alloc.free(s);
        for (self.visible_text.items) |l| self.alloc.free(l);
        self.visible_text.deinit();
        self.input.deinit();
    }

    fn push(self: *Model, kind: Entry.Kind, text: []const u8) !void {
        const owned = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(owned);
        try self.history.append(.{ .kind = kind, .text = owned });
    }
    fn pushFmt(self: *Model, kind: Entry.Kind, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.alloc, fmt, args);
        errdefer self.alloc.free(text);
        try self.history.append(.{ .kind = kind, .text = text });
    }
    fn pushOwned(self: *Model, kind: Entry.Kind, owned: []const u8) !void {
        try self.history.append(.{ .kind = kind, .text = owned });
    }

    fn clearHistory(self: *Model) void {
        for (self.history.items) |e| self.alloc.free(e.text);
        self.history.clearRetainingCapacity();
        self.push(.welcome, "") catch {};
    }

    /// Snapshot the conversation, push the `thinking…` placeholder, and spawn
    /// the model call on a background thread (so the spinner can animate).
    fn startJob(self: *Model) void {
        var turns = std.array_list.Managed(Turn).init(self.alloc);
        for (self.history.items) |e| {
            const role: ?Turn.Role = switch (e.kind) {
                .input => .user,
                .assistant => .assistant,
                else => null,
            };
            if (role) |r| {
                const t = self.alloc.dupe(u8, e.text) catch continue;
                turns.append(.{ .role = r, .text = t }) catch {
                    self.alloc.free(t);
                    continue;
                };
            }
        }
        const job = self.alloc.create(Job) catch {
            for (turns.items) |t| self.alloc.free(t.text);
            turns.deinit();
            self.push(.err, "out of memory") catch {};
            return;
        };
        job.* = .{
            .gpa = self.alloc,
            .history = turns.toOwnedSlice() catch &.{},
            .params = .{
                .effort = self.effort,
                .fast = self.fast,
                .thinking = self.thinking_show,
                .ultracode = self.ultracode,
                .goal = self.goal orelse "",
            },
            .stream = .{ .buf = self.alloc.alloc(u8, 256 * 1024) catch &.{} },
        };
        self.push(.pending, "") catch {};
        self.pending = job;
        if (std.Thread.spawn(.{}, jobRun, .{job})) |th| {
            job.thread = th;
        } else |_| {
            job.threaded = false;
            jobRun(job); // no threads → run synchronously (spinner just won't animate)
        }
    }

    /// Collect a finished job: drop the placeholder, append the reply, free.
    fn finishJob(self: *Model) void {
        const job = self.pending orelse return;
        if (!job.done.load(.acquire)) return;
        if (job.threaded) job.thread.join();
        if (g_debug) {
            if (job.stream.snapshot(self.alloc)) |raw| {
                std.debug.print("\n[repl-debug] raw agent stream ({d} bytes):\n{s}\n", .{ raw.len, raw });
                self.alloc.free(raw);
            }
            std.debug.print("[repl-debug] final reply:\n{s}\n[repl-debug] ----- end turn -----\n", .{job.result orelse "(model call failed)"});
        }

        const n = self.history.items.len;
        if (n > 0 and self.history.items[n - 1].kind == .pending) {
            self.alloc.free(self.history.items[n - 1].text);
            self.history.shrinkRetainingCapacity(n - 1);
        }
        if (job.result) |r| {
            self.chars_out += r.len;
            if (renderMarkdown(self.alloc, r)) |rendered| {
                self.alloc.free(r);
                self.pushOwned(.assistant, rendered) catch self.alloc.free(rendered);
            } else |_| {
                self.pushOwned(.assistant, r) catch self.alloc.free(r);
            }
        } else {
            self.push(.err, "model call failed — check /model and your API key") catch {};
        }
        for (job.history) |t| self.alloc.free(t.text);
        self.alloc.free(job.history);
        if (job.stream.buf.len > 0) self.alloc.free(job.stream.buf);
        self.alloc.destroy(job);
        self.pending = null;
        self.scroll = 0; // reply landed → jump to the latest
    }

    fn setGoal(self: *Model, text: []const u8) void {
        if (self.goal) |g| self.alloc.free(g);
        self.goal = if (text.len > 0) (self.alloc.dupe(u8, text) catch null) else null;
    }

    /// Core submit logic. Returns the Effect; on a chat prompt it spawns a job
    /// (self.pending becomes non-null), which the caller turns into a poll tick.
    pub fn applyLine(self: *Model, raw: []const u8) Effect {
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (line.len == 0) return .stay;
        self.push(.input, line) catch {};

        if (line[0] == '/') {
            self.runCommand(line);
            return if (self.quit_requested) .quit else .stay;
        }

        if (self.chat) {
            self.turns += 1;
            self.chars_in += line.len;
            self.startJob();
            return .stay;
        }
        if (eval(line)) |v| {
            self.pushFmt(.result, "{d}", .{v}) catch {};
        } else |e| {
            self.pushFmt(.err, "{s}", .{@errorName(e)}) catch {};
        }
        return .stay;
    }

    fn runCommand(self: *Model, line: []const u8) void {
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
            self.push(.info, if (self.chat) HELP_CHAT else HELP_CALC) catch {};
        } else if (std.mem.eql(u8, cmd, "/model")) {
            if (arg.len == 0) {
                if (g_model_name.len > 0) self.pushFmt(.info, "model: {s}", .{g_model_name}) catch {} else self.push(.info, "no model configured") catch {};
            } else if (g_model_fn) |f| {
                if (f(g_turn_ctx, self.alloc, arg)) |nm| {
                    g_model_name = nm;
                    self.pushFmt(.info, "switched to {s}", .{nm}) catch {};
                } else self.pushFmt(.err, "couldn't switch to '{s}' — see /models (need a key/login for it)", .{arg}) catch {};
            } else self.push(.info, "model switching isn't available (offline mode)") catch {};
        } else if (std.mem.eql(u8, cmd, "/models")) {
            if (g_models.len > 0) self.pushFmt(.info, "available models:\n  {s}\nswitch with /model <name>", .{g_models}) catch {} else self.push(.info, "no model table (offline mode)") catch {};
        } else if (eqlAny(cmd, &.{ "/effort", "/reasoning" })) {
            if (std.mem.eql(u8, arg, "low")) self.effort = .low else if (std.mem.eql(u8, arg, "high")) self.effort = .high else if (std.mem.eql(u8, arg, "medium") or std.mem.eql(u8, arg, "med")) self.effort = .medium else {
                self.push(.info, "usage: /effort low|medium|high") catch {};
                return;
            }
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
            if (self.goal) |g| self.pushFmt(.info, "goal set: {s}", .{g}) catch {} else self.push(.info, "goal cleared") catch {};
        } else if (std.mem.eql(u8, cmd, "/rename")) {
            self.setSession(arg);
            self.pushFmt(.info, "session renamed: {s}", .{self.session_name orelse "repl"}) catch {};
        } else if (std.mem.eql(u8, cmd, "/animation")) {
            if (std.mem.eql(u8, arg, "dragon")) self.anim = .dragon else if (std.mem.eql(u8, arg, "braille")) self.anim = .braille else {
                self.push(.info, "usage: /animation braille|dragon") catch {};
                return;
            }
            self.pushFmt(.info, "spinner: {s}", .{@tagName(self.anim)}) catch {};
        } else if (std.mem.eql(u8, cmd, "/cost")) {
            self.pushFmt(.info, "session: {d} turn(s) · ~{d} chars sent · ~{d} received", .{ self.turns, self.chars_in, self.chars_out }) catch {};
        } else if (std.mem.eql(u8, cmd, "/debug")) {
            g_debug = !g_debug;
            self.dump_next = g_debug;
            self.pushFmt(.info, "debug: {s} — run `graff repl 2>/tmp/repl.log` to capture (raw agent stream per turn + frames → stderr)", .{onOff(g_debug)}) catch {};
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
    fn rewind(self: *Model) void {
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
    fn compact(self: *Model) void {
        const keep_recent = 6;
        const n = self.history.items.len;
        if (n <= keep_recent + 1) {
            self.push(.info, "nothing to compact") catch {};
            return;
        }
        const drop_to = n - keep_recent;
        var k: usize = 1;
        while (k < drop_to) : (k += 1) self.alloc.free(self.history.items[k].text);
        std.mem.copyForwards(Entry, self.history.items[1..], self.history.items[drop_to..]);
        self.history.shrinkRetainingCapacity(1 + (n - drop_to));
        self.push(.info, "compacted — kept the welcome banner + recent turns") catch {};
    }

    fn setSession(self: *Model, name: []const u8) void {
        if (self.session_name) |s| self.alloc.free(s);
        self.session_name = if (name.len > 0) (self.alloc.dupe(u8, name) catch null) else null;
    }

    pub fn update(self: *Model, msg: Msg, ctx: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| switch (k.key) {
                .page_up => self.scroll +|= 10,
                .page_down => self.scroll -|= 10,
                .enter => {
                    self.scroll = 0; // jump to the latest on submit
                    if (self.pending != null) return .none; // busy: ignore submits
                    const effect = self.applyLine(self.input.getValue());
                    self.input.setValue("") catch {};
                    if (effect == .quit) return .quit;
                    if (self.pending != null) return .{ .tick = POLL_NS };
                    return .none;
                },
                else => if (self.pending == null) self.input.handleKey(k),
            },
            .tick => {
                if (self.pending) |job| {
                    if (job.done.load(.acquire)) {
                        self.finishJob();
                        return .none;
                    }
                    return .{ .tick = POLL_NS };
                }
                return .none;
            },
            .mouse => |m| switch (m.event_type) {
                .press => {
                    if (m.button == .wheel_up) {
                        self.scroll +|= 3;
                    } else if (m.button == .wheel_down) {
                        self.scroll -|= 3;
                    } else if (m.button == .left) {
                        self.sel_anchor_row = m.y; // begin a drag-selection
                        self.sel_cur_row = m.y;
                    }
                },
                .drag => {
                    if (m.button == .left and self.sel_anchor_row != null) self.sel_cur_row = m.y;
                },
                .release => {
                    if (self.sel_anchor_row) |a0| {
                        self.copySelection(ctx, a0, self.sel_cur_row orelse a0);
                        self.sel_anchor_row = null;
                        self.sel_cur_row = null;
                    }
                },
                .move => {},
            },
        }
        return .none;
    }

    fn spinnerFrame(self: *const Model, now_ms: u64) []const u8 {
        return switch (self.anim) {
            .braille => braille_frames[(now_ms / 80) % braille_frames.len],
            .dragon => dragon_frames[(now_ms / 220) % dragon_frames.len],
        };
    }

    fn statusLine(self: *const Model, a: std.mem.Allocator) ![]const u8 {
        var b = std.array_list.Managed(u8).init(a);
        if (self.scroll > 0) try b.appendSlice("↑ scrolled · PgDn to bottom  ·  ");
        if (self.chat and g_model_name.len > 0) try b.appendSlice(g_model_name) else try b.appendSlice("offline · arithmetic");
        try b.appendSlice(try std.fmt.allocPrint(a, "  ·  effort:{s}", .{@tagName(self.effort)}));
        if (self.fast) try b.appendSlice("  ·  ⚡fast");
        if (self.ultracode) try b.appendSlice("  ·  ✦ultracode");
        if (self.plan) try b.appendSlice("  ·  plan");
        if (self.yolo) try b.appendSlice("  ·  yolo");
        if (self.strict) try b.appendSlice("  ·  strict");
        if (self.thinking_show) try b.appendSlice("  ·  thinking");
        if (!self.keepcontext) try b.appendSlice("  ·  no-ctx");
        if (self.goal != null) try b.appendSlice("  ·  🎯goal");
        if (self.turns > 0) try b.appendSlice(try std.fmt.allocPrint(a, "  ·  {d}t", .{self.turns}));
        try b.appendSlice("  ·  /help");
        return b.items;
    }

    /// Render at `term_width` x `term_height`; `now_ms` drives animations. Input
    /// box is pinned to the bottom; conversation fills from the top.
    pub fn render(self: *Model, gpa: std.mem.Allocator, term_width: usize, term_height: usize, now_ms: u64) ![]const u8 {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();

        const inner: u16 = @intCast(@max(@as(usize, 8), term_width) - 4);
        const border_color = if (self.ultracode) rainbow[(now_ms / 90) % rainbow.len] else zz.Color.brightBlack;
        const box = (zz.Style{}).borderAll(zz.Border.rounded)
            .borderForeground(border_color).paddingLeft(1).paddingRight(1).width(inner);

        var top = std.array_list.Managed(u8).init(a);
        for (self.history.items) |e| {
            switch (e.kind) {
                .welcome => {
                    const star = try (zz.Style{}).fg(accent).bold(true).render(a, "✻");
                    const sub = if (self.chat) "Chat with the model — ask anything." else "i64 arithmetic — + - * / %, parens, unary minus.";
                    const body = try std.fmt.allocPrint(a, "{s} Welcome to graff repl\n\n  {s}\n  /help for commands · ctrl-c to quit", .{ star, sub });
                    try top.appendSlice(try box.render(a, body));
                    try top.append('\n');
                },
                .input => {
                    const g = try (zz.Style{}).fg(.brightBlack).render(a, ">");
                    try top.appendSlice(try std.fmt.allocPrint(a, "{s} {s}\n", .{ g, e.text }));
                },
                .result => {
                    const g = try (zz.Style{}).fg(.green).bold(true).render(a, "⏺");
                    try top.appendSlice(try std.fmt.allocPrint(a, "{s} {s}\n", .{ g, e.text }));
                },
                .assistant => {
                    const g = try (zz.Style{}).fg(accent).bold(true).render(a, "⏺");
                    try top.appendSlice(try std.fmt.allocPrint(a, "{s} {s}\n", .{ g, e.text }));
                },
                .pending => {
                    const g = try (zz.Style{}).fg(accent).bold(true).render(a, self.spinnerFrame(now_ms));
                    const live = if (self.pending) |job| job.stream.snapshot(a) else null;
                    if (live) |s| {
                        // Compact live activity: the last few lines of the
                        // agent's output, control-stripped + width-truncated,
                        // so tool chatter can't flood the pane.
                        try top.appendSlice(try std.fmt.allocPrint(a, "{s} working…\n", .{g}));
                        try top.appendSlice(try tailPreview(a, stripControl(a, s), term_width, 3));
                    } else {
                        const t = try (zz.Style{}).dim(true).render(a, "thinking…");
                        try top.appendSlice(try std.fmt.allocPrint(a, "{s} {s}\n", .{ g, t }));
                    }
                },
                .err => {
                    const g = try (zz.Style{}).fg(.red).bold(true).render(a, "⏺");
                    const m = try (zz.Style{}).fg(.red).render(a, e.text);
                    try top.appendSlice(try std.fmt.allocPrint(a, "{s} {s}\n", .{ g, m }));
                },
                .info => {
                    try top.appendSlice(try (zz.Style{}).dim(true).render(a, e.text));
                    try top.append('\n');
                },
            }
        }

        var bottom = std.array_list.Managed(u8).init(a);
        try bottom.appendSlice(try box.render(a, try self.input.view(a)));
        try bottom.append('\n');
        try bottom.appendSlice(try (zz.Style{}).dim(true).render(a, try self.statusLine(a)));

        // The conversation is a scrollable viewport above the pinned input box.
        // scroll = lines scrolled up from the bottom (0 = latest). Clamped here.
        const bottom_lines = std.mem.count(u8, bottom.items, "\n") + 1;
        const view_h = if (term_height > bottom_lines) term_height - bottom_lines else 1;

        var lines = std.array_list.Managed([]const u8).init(a);
        var it = std.mem.splitScalar(u8, top.items, '\n');
        while (it.next()) |ln| try lines.append(ln);
        if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();
        const n = lines.items.len;

        var out = std.array_list.Managed(u8).init(a);
        // Reset the per-frame visible-row snapshot (Model-owned plaintext, so a
        // mouse row can be mapped back to conversation text for copy — #91).
        for (self.visible_text.items) |l| self.alloc.free(l);
        self.visible_text.clearRetainingCapacity();
        self.view_start = 0;
        self.view_rows = 0;
        if (n <= view_h) {
            self.scroll = 0;
            try out.appendSlice(top.items);
            for (0..(view_h - n)) |_| try out.append('\n');
            self.view_rows = n;
            for (lines.items[0..n]) |ln| {
                self.visible_text.append(self.alloc.dupe(u8, stripControl(a, ln)) catch continue) catch {};
            }
        } else {
            const max_scroll = n - view_h;
            if (self.scroll > max_scroll) self.scroll = max_scroll;
            const start = max_scroll - self.scroll;
            self.view_start = start;
            self.view_rows = view_h;
            for (lines.items[start .. start + view_h]) |ln| {
                try out.appendSlice(ln);
                try out.append('\n');
                self.visible_text.append(self.alloc.dupe(u8, stripControl(a, ln)) catch continue) catch {};
            }
        }
        try out.appendSlice(bottom.items);
        if (self.dump_next) {
            std.debug.print("\n[repl-debug] ===== rendered frame ({d}x{d}) =====\n{s}\n[repl-debug] ===== end frame =====\n", .{ term_width, term_height, out.items });
            self.dump_next = false;
        }
        return gpa.dupe(u8, out.items);
    }

    pub fn view(self: *Model, ctx: *const zz.Context) []const u8 {
        return self.render(ctx.allocator, ctx.width, ctx.height, ctx.elapsed / std.time.ns_per_ms) catch "repl: render error";
    }

    /// Copy the conversation lines spanned by a drag-selection (screen rows
    /// r0..r1 inclusive, 0-based) to the clipboard via OSC52. Line-granular —
    /// restores copy after mouse mode disabled native terminal selection (#91).
    fn copySelection(self: *Model, ctx: *zz.Context, r0: usize, r1: usize) void {
        if (self.view_rows == 0 or self.visible_text.items.len == 0) return;
        const lo = @min(r0, r1);
        var hi = @max(r0, r1);
        if (lo >= self.view_rows) return; // selection started below the conversation
        if (hi >= self.view_rows) hi = self.view_rows - 1;
        if (hi >= self.visible_text.items.len) hi = self.visible_text.items.len - 1;

        var buf = std.array_list.Managed(u8).init(self.alloc);
        defer buf.deinit();
        var r = lo;
        while (r <= hi) : (r += 1) {
            const ln = std.mem.trimEnd(u8, self.visible_text.items[r], " \t");
            buf.appendSlice(ln) catch return;
            if (r != hi) buf.append('\n') catch return;
        }
        const text = std.mem.trim(u8, buf.items, " \t\r\n");
        if (text.len == 0) return;
        _ = ctx.setClipboard(text) catch false;
        // render() is hash-gated and may skip its flush; push the OSC52 out now.
        if (ctx._terminal) |term| term.flush() catch {};
    }
};

const HELP_CHAT =
    \\Commands (mirrors the graff session):
    \\  /help /clear /new /quit          conversation
    \\  /rewind /compact /cost           history
    \\  /model [name] /models            model (switch / list)
    \\  /effort low|med|high  /reasoning reasoning depth
    \\  /fast /thinking /ultracode       thinking controls (toggles)
    \\  /goal <text>                     standing objective (steers replies)
    \\  /plan /strict /yolo /keepcontext /title   modes
    \\  /rename <name>  /animation braille|dragon
    \\  /bash /save /resume /sessions /trace /trajectory
    \\  /agents /skills /hooks /mcp /loop /image /paste /key
    \\
    \\Type a message and press enter to send it to the model. Toggles accept
    \\[on|off] or flip when bare. Commands needing the agent loop explain so.
;

const HELP_CALC =
    \\Commands:
    \\  /help     this help
    \\  /clear    clear the conversation
    \\  /animation braille|dragon   spinner style
    \\  /quit     exit  (also /q, ctrl-c)
    \\
    \\Offline mode (no model): evaluates i64 arithmetic — + - * / %, parens.
;

/// Render a markdown string to ANSI for display — approximates the harness's
/// streamed renderer: fenced code blocks (left bar), inline `code`, **bold**,
/// # headers, and - bullets. Temporaries live in a local arena; the result is
/// owned by `gpa`.
fn renderMarkdown(gpa: std.mem.Allocator, src: []const u8) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out = std.array_list.Managed(u8).init(a);
    var in_fence = false;
    var lines = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append('\n');
        first = false;
        const t = std.mem.trimStart(u8, line, " ");
        if (std.mem.startsWith(u8, t, "```")) {
            in_fence = !in_fence;
            const lang = std.mem.trim(u8, t[3..], " \t");
            const label = if (in_fence and lang.len > 0) lang else "─────";
            try out.appendSlice(try (zz.Style{}).fg(.brightBlack).render(a, label));
            continue;
        }
        if (in_fence) {
            try out.appendSlice(try (zz.Style{}).fg(.brightBlack).render(a, "▏ "));
            try out.appendSlice(try (zz.Style{}).fg(.cyan).render(a, line));
            continue;
        }
        if (std.mem.startsWith(u8, t, "#")) {
            var h = t;
            while (h.len > 0 and h[0] == '#') h = h[1..];
            try out.appendSlice(try (zz.Style{}).fg(accent).bold(true).render(a, std.mem.trimStart(u8, h, " ")));
            continue;
        }
        var rest = line;
        if (std.mem.startsWith(u8, t, "- ") or std.mem.startsWith(u8, t, "* ")) {
            try out.appendSlice(try (zz.Style{}).fg(accent).render(a, "  • "));
            rest = t[2..];
        }
        try renderInline(&out, a, rest);
    }
    return gpa.dupe(u8, out.items);
}

fn renderInline(out: *std.array_list.Managed(u8), a: std.mem.Allocator, line: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == '`') {
            if (std.mem.indexOfScalarPos(u8, line, i + 1, '`')) |end| {
                try out.appendSlice(try (zz.Style{}).fg(.cyan).render(a, line[i + 1 .. end]));
                i = end + 1;
                continue;
            }
        } else if (c == '*' and i + 1 < line.len and line[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, line, i + 2, "**")) |end| {
                try out.appendSlice(try (zz.Style{}).bold(true).render(a, line[i + 2 .. end]));
                i = end + 2;
                continue;
            }
        }
        try out.append(c);
        i += 1;
    }
}
fn eqlAny(s: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, s, o)) return true;
    return false;
}

/// Strip ANSI/control sequences (and CR) so the agent's live streamed output
/// can be shown as plain text — cursor moves/redraws can't corrupt the pane.
/// Result owned by `a`.
fn stripControl(a: std.mem.Allocator, s: []const u8) []const u8 {
    var out = std.array_list.Managed(u8).init(a);
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == 0x1b) {
            i += 1;
            if (i < s.len and s[i] == '[') {
                i += 1;
                while (i < s.len and !std.ascii.isAlphabetic(s[i])) i += 1;
                if (i < s.len) i += 1;
            } else if (i < s.len and s[i] == ']') {
                i += 1;
                while (i < s.len and s[i] != 0x07 and s[i] != 0x1b) i += 1;
                if (i < s.len) i += 1;
            } else if (i < s.len) {
                i += 1;
            }
        } else if (c == '\r') {
            i += 1;
        } else {
            out.append(c) catch {};
            i += 1;
        }
    }
    return out.items;
}

/// Compact live-activity preview: the last `n` non-empty lines of `plain`, each
/// width-truncated (UTF-8 safe) and dimmed, indented. Keeps the agent's tool
/// chatter from flooding the pane while still showing live progress.
fn tailPreview(a: std.mem.Allocator, plain: []const u8, width: usize, n: usize) ![]const u8 {
    var lines = std.array_list.Managed([]const u8).init(a);
    var it = std.mem.splitScalar(u8, plain, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, " \t");
        if (t.len > 0) try lines.append(t);
    }
    const start = if (lines.items.len > n) lines.items.len - n else 0;
    const cap = if (width > 6) width - 4 else 12;
    var out = std.array_list.Managed(u8).init(a);
    for (lines.items[start..]) |ln| {
        var tw = @min(ln.len, cap);
        while (tw > 0 and tw < ln.len and (ln[tw] & 0xC0) == 0x80) tw -= 1; // don't cut mid-UTF-8
        try out.appendSlice("  ");
        try out.appendSlice(try (zz.Style{}).dim(true).render(a, ln[0..tw]));
        try out.append('\n');
    }
    return out.items;
}

fn parseToggle(arg: []const u8, current: bool) bool {
    if (std.mem.eql(u8, arg, "on")) return true;
    if (std.mem.eql(u8, arg, "off")) return false;
    return !current; // bare toggle
}

fn onOff(v: bool) []const u8 {
    return if (v) "on" else "off";
}

/// Run the REPL. Pass a `turn_fn` (+ opaque ctx + model name) to chat with a
/// model; pass null/null/"" for the offline arithmetic engine.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    turn_ctx: ?*anyopaque,
    turn_fn: ?TurnFn,
    model_fn: ?ModelFn,
    model_name: []const u8,
    models: []const u8,
) !void {
    g_turn_ctx = turn_ctx;
    g_turn_fn = turn_fn;
    g_model_fn = model_fn;
    g_model_name = model_name;
    g_debug = environ_map.get("GRAFF_REPL_DEBUG") != null;
    g_models = models;
    var program = zz.Program(Model).initWithOptions(gpa, io, environ_map, .{ .mouse = true });
    defer program.deinit();
    try program.run();
}

pub fn main(init: std.process.Init) !void {
    return run(init.gpa, init.io, init.environ_map, null, null, null, "", "");
}

// ---------------------------------------------------------------------------
// Tests — headless. Chat path uses a stubbed turn_fn (no network); it still
// exercises the real background-thread path.
// ---------------------------------------------------------------------------

test "eval: precedence and parentheses" {
    try std.testing.expectEqual(@as(i64, 14), try eval("2 + 3 * 4"));
    try std.testing.expectEqual(@as(i64, 20), try eval("(2 + 3) * 4"));
    try std.testing.expectEqual(@as(i64, -6), try eval("-(2 * 3)"));
    try std.testing.expectEqual(@as(i64, 2), try eval("7 / 3"));
    try std.testing.expectEqual(@as(i64, 1), try eval("7 % 3"));
}

test "eval: error cases" {
    try std.testing.expectError(error.DivByZero, eval("1 / 0"));
    try std.testing.expectError(error.SyntaxError, eval("2 +"));
    try std.testing.expectError(error.SyntaxError, eval("2 2"));
    try std.testing.expectError(error.Overflow, eval("9223372036854775807 + 1"));
}

test "model: offline arithmetic path (no turn_fn)" {
    g_turn_fn = null;
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();

    try std.testing.expectEqual(Effect.stay, m.applyLine("2 + 3 * 4"));
    const out = try m.render(std.testing.allocator, 60, 24, 0);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Welcome to graff repl") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "14") != null);

    _ = m.applyLine("/clear");
    try std.testing.expectEqual(@as(usize, 1), m.history.items.len);
    try std.testing.expectEqual(Effect.quit, m.applyLine("/quit"));
}

test "model: commands toggle settings" {
    g_turn_fn = null;
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    _ = m.applyLine("/effort high");
    try std.testing.expectEqual(Effort.high, m.effort);
    _ = m.applyLine("/fast on");
    try std.testing.expect(m.fast);
    _ = m.applyLine("/ultracode");
    try std.testing.expect(m.ultracode);
    _ = m.applyLine("/goal ship the repl");
    try std.testing.expect(m.goal != null);
    _ = m.applyLine("/animation dragon");
    try std.testing.expectEqual(Anim.dragon, m.anim);
}

fn stubTurn(_: ?*anyopaque, gpa: std.mem.Allocator, history: []const Turn, params: Params, _: *StreamBuf) ?[]const u8 {
    const last = history[history.len - 1].text;
    return std.fmt.allocPrint(gpa, "echo[{s}]: {s}", .{ @tagName(params.effort), last }) catch null;
}

test "model: chat path (background thread + multi-turn) via stub" {
    g_turn_fn = stubTurn;
    g_turn_ctx = null;
    defer g_turn_fn = null;
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();

    _ = m.applyLine("/effort high");
    try std.testing.expectEqual(Effect.stay, m.applyLine("hey there"));
    try std.testing.expect(m.pending != null);

    while (!m.pending.?.done.load(.acquire)) {} // wait for the worker
    m.finishJob();
    try std.testing.expect(m.pending == null);

    const out = try m.render(std.testing.allocator, 60, 24, 0);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "hey there") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "echo[high]: hey there") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "thinking") == null);
}

test "repl: main and Program(Model) type-check" {
    _ = &main;
}

test "model: /rewind and /compact (leak-checked)" {
    g_turn_fn = null;
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    _ = m.applyLine("2 + 2");
    _ = m.applyLine("3 + 3");
    _ = m.applyLine("/rewind");
    try std.testing.expectEqual(Entry.Kind.welcome, m.history.items[0].kind);
    var i: usize = 0;
    while (i < 12) : (i += 1) _ = m.applyLine("1 + 1");
    _ = m.applyLine("/compact");
    try std.testing.expectEqual(Entry.Kind.welcome, m.history.items[0].kind);
    try std.testing.expect(m.history.items.len <= 9);
    _ = m.applyLine("/rename my-session");
    try std.testing.expect(m.session_name != null);
}
