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
//!
//! Split across sibling files (#123, 600-line goal): repl_parser.zig (the
//! offline arithmetic evaluator), repl_util.zig (stateless string/format
//! helpers), and repl_model_{turn,commands,render}.zig (the Model struct's
//! method bodies, reached back through the member aliases below via the
//! same technique used for the Agent struct split — self.method() and
//! Model.method() resolve unchanged regardless of which file backs them).

const std = @import("std");
const zz = @import("zigzag");

const parser_mod = @import("repl_parser.zig");
const util = @import("repl_util.zig");
const model_turn = @import("repl_model_turn.zig");
const model_commands = @import("repl_model_commands.zig");
const model_render = @import("repl_model_render.zig");
const repl_run = @import("repl_run.zig");
const term = @import("term.zig");

test {
    _ = parser_mod;
    _ = util;
    _ = model_turn;
    _ = model_commands;
    _ = model_render;
    _ = repl_run;
}

// ---------------------------------------------------------------------------
// Arithmetic evaluator — split out to repl_parser.zig (#123, 600-line goal):
// EvalError/Parser/eval (+ their tests) live there now. Offline fallback
// engine + the thing the headless tests exercise when no turn_fn is wired in.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Model hook — injected by the host (src/main.zig). The callback receives the
// whole conversation + the current thinking settings and returns a reply
// allocated with the given allocator (caller owns), or null on failure. This
// keeps repl.zig decoupled from the harness's Agent/Provider (no circular import).
// ---------------------------------------------------------------------------

pub const Effort = enum { low, medium, high, xhigh, max, ultra };

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

pub var g_turn_fn: ?TurnFn = null;
pub var g_turn_ctx: ?*anyopaque = null;
pub var g_model_name: []const u8 = "";
pub const ModelFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator, name: []const u8) ?[]const u8;
pub var g_models: []const u8 = ""; // comma-joined model names (for /models)
pub var g_model_fn: ?ModelFn = null; // switch the active model by name
pub const CancelFn = *const fn (turn_ctx: ?*anyopaque) void;
pub var g_cancel_fn: ?CancelFn = null; // force-interrupt the running turn (steer drain)
pub var g_debug: bool = false; // GRAFF_REPL_DEBUG / `/debug` → dump raw stream + frames to stderr

// ---------------------------------------------------------------------------
// Look & feel.
// ---------------------------------------------------------------------------

pub const accent = zz.Color.fromRgb(0xD9, 0x77, 0x57); // Claude coral

/// `/ultracode` rainbow shine — sweeps across the input border per frame.
pub const rainbow = [_]zz.Color{
    zz.Color.fromRgb(0xFF, 0x5C, 0x57), zz.Color.fromRgb(0xFF, 0x9F, 0x43),
    zz.Color.fromRgb(0xFE, 0xD3, 0x30), zz.Color.fromRgb(0x6B, 0xCB, 0x77),
    zz.Color.fromRgb(0x4D, 0x96, 0xFF), zz.Color.fromRgb(0xB1, 0x7A, 0xFF),
};

pub const braille_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
pub const dragon_frames = [_][]const u8{ "🐉  ", "🐉 ✦", "🐉 ✧", "🐉 ✦" };

const Anim = enum { braille, dragon };
pub const Toast = enum { none, copied, failed };
pub const TOAST_MS: u64 = 1500; // copy-confirmation toast window (wall-clock ms), #85

const POLL_NS: u64 = 50 * std.time.ns_per_ms;

// ---------------------------------------------------------------------------
// Background model call.
// ---------------------------------------------------------------------------

pub const Job = struct {
    thread: std.Thread = undefined,
    threaded: bool = true,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result: ?[]const u8 = null,
    gpa: std.mem.Allocator,
    history: []Turn, // owned snapshot
    params: Params,
    stream: StreamBuf,
};

pub fn jobRun(job: *Job) void {
    const reply = if (g_turn_fn) |f| f(g_turn_ctx, job.gpa, job.history, job.params, &job.stream) else null;
    job.result = reply;
    job.done.store(true, .release);
}

// ---------------------------------------------------------------------------
// Model.
// ---------------------------------------------------------------------------

pub const Entry = struct {
    kind: Kind,
    text: []const u8, // owned by Model.alloc
    const Kind = enum { welcome, input, result, err, info, pending, assistant };
};

pub const Effect = enum { stay, quit };

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
    // Copy-confirmation toast (time-based; auto-dismisses, no tick plumbing), #85.
    toast: Toast = .none,
    toast_until_ms: u64 = 0,
    last_term_width: usize = 0, // cached each frame for post-hoc markdown layout
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
    // Steering: lines typed while a turn streams are queued here and run as
    // follow-up turns; an empty Enter force-interrupts so they drain now.
    steer_queue: std.array_list.Managed([]const u8) = undefined,
    cancel_requested: bool = false,

    pub const Tick = struct { timestamp: u64, delta: u64 };
    pub const Msg = union(enum) { key: zz.KeyEvent, tick: Tick, mouse: zz.MouseEvent };

    pub fn setup(self: *Model, alloc: std.mem.Allocator) void {
        self.* = .{
            .alloc = alloc,
            .input = zz.TextInput.init(alloc),
            .history = std.array_list.Managed(Entry).init(alloc),
            .visible_text = std.array_list.Managed([]const u8).init(alloc),
            .steer_queue = std.array_list.Managed([]const u8).init(alloc),
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
        for (self.steer_queue.items) |s| self.alloc.free(s);
        self.steer_queue.deinit();
        self.input.deinit();
    }

    pub fn push(self: *Model, kind: Entry.Kind, text: []const u8) !void {
        const owned = try self.alloc.dupe(u8, text);
        errdefer self.alloc.free(owned);
        try self.history.append(.{ .kind = kind, .text = owned });
    }
    pub fn pushFmt(self: *Model, kind: Entry.Kind, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.alloc, fmt, args);
        errdefer self.alloc.free(text);
        try self.history.append(.{ .kind = kind, .text = text });
    }
    pub fn pushOwned(self: *Model, kind: Entry.Kind, owned: []const u8) !void {
        try self.history.append(.{ .kind = kind, .text = owned });
    }

    pub fn clearHistory(self: *Model) void {
        for (self.history.items) |e| self.alloc.free(e.text);
        self.history.clearRetainingCapacity();
        self.push(.welcome, "") catch {};
    }

    // Chat-turn/background-thread logic (startJob/finishJob/drainSteer/
    // steerEnter) lives in repl_model_turn.zig.
    pub const startJob = model_turn.startJob;
    pub const finishJob = model_turn.finishJob;
    pub const drainSteer = model_turn.drainSteer;

    // /command handlers live in repl_model_commands.zig.
    pub const setGoal = model_commands.setGoal;

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
        if (parser_mod.eval(line)) |v| {
            self.pushFmt(.result, "{d}", .{v}) catch {};
        } else |e| {
            self.pushFmt(.err, "{s}", .{@errorName(e)}) catch {};
        }
        return .stay;
    }

    pub const runCommand = model_commands.runCommand;
    pub const rewind = model_commands.rewind;
    pub const compact = model_commands.compact;
    pub const setSession = model_commands.setSession;

    pub const steerEnter = model_turn.steerEnter;

    pub fn update(self: *Model, msg: Msg, ctx: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| switch (k.key) {
                .page_up => self.scroll +|= 10,
                .page_down => self.scroll -|= 10,
                .enter => {
                    self.scroll = 0; // jump to the latest on submit
                    if (self.pending != null) {
                        self.steerEnter(); // a turn is streaming: Enter steers, not submits
                        return .{ .tick = POLL_NS };
                    }
                    const effect = self.applyLine(self.input.getValue());
                    self.input.setValue("") catch {};
                    if (effect == .quit) return .quit;
                    if (self.pending != null) return .{ .tick = POLL_NS };
                    return .none;
                },
                // While a turn streams, keys edit the input box too, so the user
                // can compose a steer line; otherwise it's normal line editing.
                else => self.input.handleKey(k),
            },
            .tick => {
                if (self.pending) |job| {
                    if (job.done.load(.acquire)) {
                        self.finishJob();
                        // Run the next queued steer line, if any, as the next turn.
                        if (self.drainSteer() == .quit) return .quit;
                        if (self.pending != null) return .{ .tick = POLL_NS };
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

    // Pane rendering (spinnerFrame/statusLine/render/copySelection) lives in
    // repl_model_render.zig.
    pub const spinnerFrame = model_render.spinnerFrame;
    pub const statusLine = model_render.statusLine;
    pub const render = model_render.render;

    pub fn view(self: *Model, ctx: *const zz.Context) []const u8 {
        return self.render(ctx.allocator, ctx.width, ctx.height, ctx.elapsed / std.time.ns_per_ms) catch "repl: render error";
    }

    pub const copySelection = model_render.copySelection;
    pub const selectionText = model_render.selectionText;
};

pub const HELP_CALC =
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
/// # headers, - bullets, and | pipe tables (box-drawing, wrapped to fit
/// `width_hint` columns; 0 = assume 100). Temporaries live in a local arena;
/// the result is owned by `gpa`.
pub fn renderMarkdown(gpa: std.mem.Allocator, src: []const u8, width_hint: usize) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out = std.array_list.Managed(u8).init(a);

    var line_list = std.array_list.Managed([]const u8).init(a);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| try line_list.append(l);
    const lines = line_list.items;

    var in_fence = false;
    var first = true;
    var idx: usize = 0;
    while (idx < lines.len) : (idx += 1) {
        const line = lines[idx];
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
        if (isTableRow(t) and idx + 1 < lines.len and isTableSep(std.mem.trim(u8, lines[idx + 1], " \t"))) {
            var end = idx;
            while (end < lines.len and isTableRow(std.mem.trimStart(u8, lines[end], " "))) end += 1;
            try renderTable(&out, a, lines[idx..end], width_hint);
            idx = end - 1;
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
        try util.renderInline(&out, a, rest);
    }
    return gpa.dupe(u8, out.items);
}

fn isTableRow(t: []const u8) bool {
    return t.len >= 2 and t[0] == '|';
}

/// `|---|:--:|` style alignment row: pipes/colons/spaces only, dashes required.
fn isTableSep(t: []const u8) bool {
    if (t.len == 0 or t[0] != '|') return false;
    var dash = false;
    for (t) |c| switch (c) {
        '|', ':', ' ', '\t' => {},
        '-' => dash = true,
        else => return false,
    };
    return dash;
}

/// Inline markdown with `code`/**bold** markers stripped — exactly what
/// renderInline makes visible, unstyled. Cell layout is computed from this.
fn plainInline(a: std.mem.Allocator, line: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(a);
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == '`') {
            if (std.mem.indexOfScalarPos(u8, line, i + 1, '`')) |end| {
                try out.appendSlice(line[i + 1 .. end]);
                i = end + 1;
                continue;
            }
        } else if (c == '*' and i + 1 < line.len and line[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, line, i + 2, "**")) |end| {
                try out.appendSlice(line[i + 2 .. end]);
                i = end + 2;
                continue;
            }
        }
        try out.append(c);
        i += 1;
    }
    return out.items;
}

/// Display columns of a UTF-8 string (wcwidth-style, #142). The width table now
/// lives in term.zig so the TUI tables here and the narrow-prompt budgeting
/// (#209) share one definition; delegate so the call sites below stay unqualified.
fn dispWidth(s: []const u8) usize {
    return term.dispWidth(s);
}

test "dispWidth: East-Asian wide, combining, emoji (#142)" {
    try std.testing.expectEqual(@as(usize, 5), dispWidth("hello"));
    try std.testing.expectEqual(@as(usize, 4), dispWidth("\u{4F60}\u{597D}")); // CJK x2 -> 4 cols
    try std.testing.expectEqual(@as(usize, 2), dispWidth("\u{3042}")); // hiragana wide
    try std.testing.expectEqual(@as(usize, 1), dispWidth("\u{00E9}")); // precomposed e-acute -> 1
    try std.testing.expectEqual(@as(usize, 1), dispWidth("e\u{0301}")); // e + combining acute -> 1
    try std.testing.expectEqual(@as(usize, 2), dispWidth("\u{1F600}")); // emoji -> 2
    try std.testing.expectEqual(@as(usize, 0), dispWidth("\u{200B}")); // ZWSP -> 0
    try std.testing.expectEqual(@as(usize, 2), dispWidth("\u{FF21}")); // fullwidth A -> 2
}

/// Word-wrap `s` to `w` display columns; words longer than `w` hard-split at
/// codepoint boundaries. Never emits leading/trailing spaces on a line.
fn wrapCell(a: std.mem.Allocator, s: []const u8, w: usize) ![]const []const u8 {
    var lines = std.array_list.Managed([]const u8).init(a);
    var cur = std.array_list.Managed(u8).init(a);
    var cur_w: usize = 0;
    var words = std.mem.tokenizeScalar(u8, s, ' ');
    while (words.next()) |word| {
        var rem = word;
        while (dispWidth(rem) > w) {
            if (cur_w > 0) {
                try lines.append(try a.dupe(u8, cur.items));
                cur.clearRetainingCapacity();
                cur_w = 0;
            }
            var bytes: usize = 0;
            var cw: usize = 0;
            while (bytes < rem.len) {
                const clen = @min(std.unicode.utf8ByteSequenceLength(rem[bytes]) catch 1, rem.len - bytes);
                const cpw = if (std.unicode.utf8Decode(rem[bytes .. bytes + clen])) |cp| term.codepointWidth(cp) else |_| 1;
                if (cw + cpw > w and bytes > 0) break; // stop before overflowing the column (>=1 char guaranteed)
                bytes += clen;
                cw += cpw;
            }
            try lines.append(try a.dupe(u8, rem[0..bytes]));
            rem = rem[bytes..];
        }
        const ww = dispWidth(rem);
        if (ww == 0) continue;
        if (cur_w > 0 and cur_w + 1 + ww > w) {
            try lines.append(try a.dupe(u8, cur.items));
            cur.clearRetainingCapacity();
            cur_w = 0;
        }
        if (cur_w > 0) {
            try cur.append(' ');
            cur_w += 1;
        }
        try cur.appendSlice(rem);
        cur_w += ww;
    }
    if (cur_w > 0 or lines.items.len == 0) try lines.append(try a.dupe(u8, cur.items));
    return lines.items;
}

fn tableRule(out: *std.array_list.Managed(u8), a: std.mem.Allocator, widths: []const usize, l: []const u8, m: []const u8, r: []const u8) !void {
    var buf = std.array_list.Managed(u8).init(a);
    try buf.appendSlice(l);
    for (widths, 0..) |w, i| {
        for (0..w + 2) |_| try buf.appendSlice("─");
        try buf.appendSlice(if (i + 1 == widths.len) r else m);
    }
    try out.appendSlice(try (zz.Style{}).fg(.brightBlack).render(a, buf.items));
}

/// Narrow-table fallback: one record per data row — bold `Header: value`
/// lines with wrapped continuations indented, a brightBlack rule between
/// records. Used when the box form cannot fit `budget` columns.
fn renderRecords(out: *std.array_list.Managed(u8), a: std.mem.Allocator, rows: []const []const []const u8, budget: usize) !void {
    const header = rows[0];
    var rule_buf = std.array_list.Managed(u8).init(a);
    const rule_w = @max(@as(usize, 16), @min(budget, 40));
    for (0..rule_w) |_| try rule_buf.appendSlice("─");
    var first_line = true;
    for (rows[1..], 0..) |cells, ri| {
        if (ri > 0) {
            try out.append('\n');
            try out.appendSlice(try (zz.Style{}).fg(.brightBlack).render(a, rule_buf.items));
        }
        for (header, 0..) |label, i| {
            const value = if (i < cells.len) cells[i] else "";
            const lw = dispWidth(label);
            const segs = try wrapCell(a, value, @max(@as(usize, 16), budget -| (lw + 2)));
            if (!first_line) try out.append('\n');
            first_line = false;
            try out.appendSlice(try (zz.Style{}).bold(true).render(a, label));
            try out.appendSlice(": ");
            if (segs.len > 0) try out.appendSlice(segs[0]);
            if (segs.len > 1) for (segs[1..]) |seg| {
                try out.append('\n');
                try out.appendSlice("  ");
                try out.appendSlice(seg);
            };
        }
    }
}

/// Per-column alignment parsed from a table's `:---:` separator row (#143).
const TableAlign = enum { left, center, right };

/// Render `| a | b |` source rows (row 1 = alignment separator) as a
/// box-drawing table: bold header, ├─┼─┤ rules between rows, cells
/// word-wrapped so the whole table fits `width_hint` columns.
fn renderTable(out: *std.array_list.Managed(u8), a: std.mem.Allocator, raw_rows: []const []const u8, width_hint: usize) !void {
    var rows = std.array_list.Managed([]const []const u8).init(a);
    for (raw_rows, 0..) |raw, ri| {
        if (ri == 1) continue; // alignment separator row
        var body = std.mem.trim(u8, raw, " \t");
        if (body.len > 0 and body[0] == '|') body = body[1..];
        if (body.len > 0 and body[body.len - 1] == '|') body = body[0 .. body.len - 1];
        var cells = std.array_list.Managed([]const u8).init(a);
        var cell = std.array_list.Managed(u8).init(a);
        var bi: usize = 0;
        while (bi < body.len) : (bi += 1) {
            if (body[bi] == '\\' and bi + 1 < body.len and body[bi + 1] == '|') {
                try cell.append('|'); // escaped \| is a literal pipe, not a column delimiter
                bi += 1;
            } else if (body[bi] == '|') {
                try cells.append(try plainInline(a, std.mem.trim(u8, cell.items, " \t")));
                cell = std.array_list.Managed(u8).init(a);
            } else {
                try cell.append(body[bi]);
            }
        }
        try cells.append(try plainInline(a, std.mem.trim(u8, cell.items, " \t")));
        try rows.append(cells.items);
    }
    if (rows.items.len == 0 or rows.items[0].len == 0) return;
    const ncols = rows.items[0].len;

    // Column alignment from the separator row (raw_rows[1]): ":--" left, "--:"
    // right, ":-:" center, "---" defaults left. Applied to header + data like
    // the GUI's ChatTable (#143). Skipped rows never reach here.
    const aligns = try a.alloc(TableAlign, ncols);
    @memset(aligns, .left);
    if (raw_rows.len > 1) {
        var sbody = std.mem.trim(u8, raw_rows[1], " \t");
        if (sbody.len > 0 and sbody[0] == '|') sbody = sbody[1..];
        if (sbody.len > 0 and sbody[sbody.len - 1] == '|') sbody = sbody[0 .. sbody.len - 1];
        var ci: usize = 0;
        var it = std.mem.splitScalar(u8, sbody, '|');
        while (it.next()) |raw_spec| {
            if (ci >= ncols) break;
            const spec = std.mem.trim(u8, raw_spec, " \t");
            const lc = spec.len > 0 and spec[0] == ':';
            const rc = spec.len > 0 and spec[spec.len - 1] == ':';
            aligns[ci] = if (lc and rc) .center else if (rc) .right else .left;
            ci += 1;
        }
    }

    const widths = try a.alloc(usize, ncols);
    @memset(widths, 1);
    for (rows.items) |cells| {
        for (cells, 0..) |c, i| {
            if (i < ncols) widths[i] = @max(widths[i], dispWidth(c));
        }
    }
    const budget = (if (width_hint == 0) @as(usize, 100) else @max(width_hint, 40)) -| 8;
    const overhead = ncols * 3 + 1;
    while (true) {
        var total: usize = overhead;
        for (widths) |w| total += w;
        if (total <= budget) break;
        var wi: usize = 0;
        var wmax: usize = 0;
        for (widths, 0..) |w, i| {
            if (w > wmax) {
                wmax = w;
                wi = i;
            }
        }
        if (wmax <= 8) break; // column floor reached — record fallback below
        widths[wi] = wmax - 1;
    }

    var total: usize = overhead;
    for (widths) |w| total += w;
    if (total > budget and rows.items.len >= 2) {
        // Even at the column floor the box form overflows the pane — fall back
        // to one record per row, mirroring the harness's narrow rendering.
        try renderRecords(out, a, rows.items, budget);
        return;
    }

    try tableRule(out, a, widths, "┌", "┬", "┐");
    for (rows.items, 0..) |cells, ri| {
        const wrapped = try a.alloc([]const []const u8, ncols);
        var height: usize = 1;
        for (0..ncols) |i| {
            wrapped[i] = try wrapCell(a, if (i < cells.len) cells[i] else "", widths[i]);
            height = @max(height, wrapped[i].len);
        }
        for (0..height) |li| {
            try out.append('\n');
            for (0..ncols) |i| {
                try out.appendSlice(try (zz.Style{}).fg(.brightBlack).render(a, "│"));
                try out.append(' ');
                const seg = if (li < wrapped[i].len) wrapped[i][li] else "";
                const pad = widths[i] -| dispWidth(seg);
                const lead: usize = switch (aligns[i]) {
                    .left => 0,
                    .right => pad,
                    .center => pad / 2,
                };
                for (0..lead) |_| try out.append(' ');
                if (seg.len > 0) {
                    if (ri == 0) {
                        try out.appendSlice(try (zz.Style{}).bold(true).render(a, seg));
                    } else {
                        try out.appendSlice(seg);
                    }
                }
                for (0..pad - lead) |_| try out.append(' ');
                try out.append(' ');
            }
            try out.appendSlice(try (zz.Style{}).fg(.brightBlack).render(a, "│"));
        }
        try out.append('\n');
        if (ri + 1 == rows.items.len) {
            try tableRule(out, a, widths, "└", "┴", "┘");
        } else {
            try tableRule(out, a, widths, "├", "┼", "┤");
        }
    }
}

// run/runScripted (the live TUI loop + the headless/scriptable twin) and
// main() (the standalone `graff-repl` exe's entry point) live in
// repl_run.zig.
pub const run = repl_run.run;
pub const runScripted = repl_run.runScripted;
pub const main = repl_run.main;

// ---------------------------------------------------------------------------
// Tests — headless. Chat path uses a stubbed turn_fn (no network); it still
// exercises the real background-thread path.
// ---------------------------------------------------------------------------

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

test "model: copy toast shows within window then auto-dismisses (#85)" {
    g_turn_fn = null;
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.toast = .copied;
    m.toast_until_ms = 1000;
    const shown = try m.render(std.testing.allocator, 60, 24, 500);
    defer std.testing.allocator.free(shown);
    try std.testing.expect(std.mem.indexOf(u8, shown, "Copied to clipboard") != null);
    const gone = try m.render(std.testing.allocator, 60, 24, 2000);
    defer std.testing.allocator.free(gone);
    try std.testing.expect(std.mem.indexOf(u8, gone, "Copied to clipboard") == null);
}

test "model: selectionText joins non-empty rows and ignores whitespace-only (#85)" {
    g_turn_fn = null;
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.visible_text.append(try std.testing.allocator.dupe(u8, "hello"));
    try m.visible_text.append(try std.testing.allocator.dupe(u8, "world"));
    try m.visible_text.append(try std.testing.allocator.dupe(u8, "   "));
    m.view_rows = 3;
    const joined = m.selectionText(std.testing.allocator, 0, 1).?;
    defer std.testing.allocator.free(joined);
    try std.testing.expectEqualStrings("hello\nworld", joined);
    try std.testing.expect(m.selectionText(std.testing.allocator, 2, 2) == null); // whitespace-only
    try std.testing.expect(m.toast == .none and m.toast_until_ms == 0); // no toast raised
}

test "model: commands toggle settings" {
    g_turn_fn = null;
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    _ = m.applyLine("/effort high");
    try std.testing.expectEqual(Effort.high, m.effort);
    _ = m.applyLine("/effort ultra");
    try std.testing.expectEqual(Effort.ultra, m.effort);
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

var g_test_cancelled: bool = false;
fn testCancel(_: ?*anyopaque) void {
    g_test_cancelled = true;
}

test "model: steering queues a line and drains it as the next turn" {
    g_turn_fn = stubTurn;
    g_turn_ctx = null;
    defer g_turn_fn = null;
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();

    // Turn 1 in flight.
    try std.testing.expectEqual(Effect.stay, m.applyLine("first"));
    try std.testing.expect(m.pending != null);

    // Type a steer line while the turn streams → queued, input cleared (not submitted).
    m.input.setValue("second") catch {};
    m.steerEnter();
    try std.testing.expectEqual(@as(usize, 1), m.steer_queue.items.len);
    try std.testing.expectEqualStrings("", m.input.getValue());

    // Finish turn 1, then drain (what update(.tick) does) → the steer runs as turn 2.
    while (!m.pending.?.done.load(.acquire)) {}
    m.finishJob();
    try std.testing.expect(m.pending == null);
    _ = m.drainSteer();
    try std.testing.expectEqual(@as(usize, 0), m.steer_queue.items.len);
    try std.testing.expect(m.pending != null);

    while (!m.pending.?.done.load(.acquire)) {}
    m.finishJob();

    const out = try m.render(std.testing.allocator, 80, 24, 0);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "echo[medium]: first") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "echo[medium]: second") != null);
}

test "model: empty Enter force-interrupts when a steer line is queued" {
    g_turn_fn = stubTurn;
    g_turn_ctx = null;
    g_cancel_fn = testCancel;
    g_test_cancelled = false;
    defer {
        g_turn_fn = null;
        g_cancel_fn = null;
    }
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();

    _ = m.applyLine("first");
    try std.testing.expect(m.pending != null);

    // Queue one steer line, then an empty Enter forces.
    m.input.setValue("urgent") catch {};
    m.steerEnter();
    m.input.setValue("") catch {};
    m.steerEnter();
    try std.testing.expect(m.cancel_requested); // turn flagged interrupted
    try std.testing.expect(g_test_cancelled); // cancel callback fired

    // Drain to completion so the queued line + jobs are freed (leak-checked).
    while (!m.pending.?.done.load(.acquire)) {}
    m.finishJob();
    _ = m.drainSteer();
    while (m.pending != null and !m.pending.?.done.load(.acquire)) {}
    if (m.pending != null) m.finishJob();
}

test "renderMarkdown: pipe table renders as box-drawing" {
    const gpa = std.testing.allocator;
    const md = "before\n| Impact | Site |\n|---|---|\n| high | `repl.zig:700` |\n| medium | **main.zig** |\nafter";
    const out = try renderMarkdown(gpa, md, 80);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "┼") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "└") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "repl.zig:700") != null); // backticks stripped in cells
    try std.testing.expect(std.mem.indexOf(u8, out, "|---") == null); // separator row consumed
    try std.testing.expect(std.mem.indexOf(u8, out, "before") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "after") != null);
}

test "renderMarkdown: table cells wrap to the width budget" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const md = "| K | V |\n|---|---|\n| x | this is a very long cell that must wrap across multiple lines to stay inside a narrow table |";
    const out = try renderMarkdown(gpa, md, 48);
    defer gpa.free(out);
    const plain = util.stripControl(a, out);
    var it = std.mem.splitScalar(u8, plain, '\n');
    var cell_rows: usize = 0;
    while (it.next()) |line| {
        try std.testing.expect(dispWidth(line) <= 48);
        if (std.mem.indexOf(u8, line, "│") != null) cell_rows += 1;
    }
    try std.testing.expect(cell_rows >= 3); // long cell spans several visual lines
}

test "renderMarkdown: lone pipe line is not a table" {
    const gpa = std.testing.allocator;
    const out = try renderMarkdown(gpa, "| just text with pipes |\nno separator", 80);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "┌") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "| just text with pipes |") != null);
}

test "renderMarkdown: too-wide table falls back to record layout" {
    const gpa = std.testing.allocator;
    const md = "| Impact | Site | Finding | Fix safe? |\n|---|---|---|---|\n| high | repl.zig:700 | full scrollback re-styled and re-allocated every single frame | needs care |\n| medium | main.zig:14048 | never-reset session arena grows RSS forever | no |";
    const out = try renderMarkdown(gpa, md, 44);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "┌") == null); // box form abandoned
    try std.testing.expect(std.mem.indexOf(u8, out, "Impact") != null); // labels repeated per record
    try std.testing.expect(std.mem.indexOf(u8, out, "────") != null); // rule between records
    try std.testing.expect(std.mem.indexOf(u8, out, "repl.zig:700") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "main.zig:14048") != null);
}

test "renderMarkdown: escaped pipe stays inside a table cell" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const md = "| head |\n|---|\n| a \\| b |";
    const out = try renderMarkdown(gpa, md, 100);
    defer gpa.free(out);
    const plain = util.stripControl(a, out); // arena-owned; freed with arena_state
    // the escaped \\| renders as a literal pipe inside the single cell.
    try std.testing.expect(std.mem.indexOf(u8, plain, "a | b") != null);
}

test "renderMarkdown: table honors column alignment" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // right-aligned: short "5" in the 5-wide "Count" column gets 4 leading spaces.
    const rout = try renderMarkdown(gpa, "| Count |\n| ---: |\n| 5 |", 100);
    defer gpa.free(rout);
    try std.testing.expect(std.mem.indexOf(u8, util.stripControl(a, rout), "    5") != null);
    // centered: "x" in the 8-wide "Wide col" column gets leading pad (not flush-left).
    const cout = try renderMarkdown(gpa, "| Wide col |\n| :---: |\n| x |", 100);
    defer gpa.free(cout);
    try std.testing.expect(std.mem.indexOf(u8, util.stripControl(a, cout), "   x") != null);
    // left default: "5" stays flush-left (no leading pad before it).
    const lout = try renderMarkdown(gpa, "| Count |\n| --- |\n| 5 |", 100);
    defer gpa.free(lout);
    try std.testing.expect(std.mem.indexOf(u8, util.stripControl(a, lout), "    5") == null);
}
