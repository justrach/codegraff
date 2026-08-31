//! Frontend-agnostic types the TUI uses to talk to a turn backend.
//! The package never imports the harness: session glue supplies callbacks.

const std = @import("std");
const builtin = @import("builtin");

const events_mod = @import("events.zig");

pub const Event = events_mod.Event;
pub const EventQueue = events_mod.Queue;
pub const ToolEvent = events_mod.Tool;
pub const Status = events_mod.Status;
pub const Cost = events_mod.Cost;

pub const Effort = enum { low, medium, high, xhigh, max, ultra };

/// The session's permission policy. This is ENGINE state, not a badge: the
/// turn backend maps it onto the harness's plan gate and approval policy
/// (repl_glue.replTurnCb). Before #551 round 2 the TUI kept its own copy and
/// the engine was never told, so a footer reading "Plan" sat over a turn that
/// was writing files.
pub const Mode = enum { normal, plan, always_approve };

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
    /// Permission policy for this turn (Shift+Tab, Ctrl+O, /plan).
    mode: Mode = .normal,
    /// /strict — selects the strict system prompt on the turn's agent.
    strict: bool = false,
    goal: []const u8 = "",
};

/// Lock-free single-writer / single-reader preview buffer (same contract as
/// the zigzag REPL stream). Overflow drops live bytes only.
pub const StreamBuf = struct {
    buf: []u8 = &.{},
    len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn appendBytes(self: *StreamBuf, bytes: []const u8) void {
        const cur = self.len.load(.monotonic);
        if (cur >= self.buf.len) return;
        var n = @min(bytes.len, self.buf.len - cur);
        // Overflow drops the tail for good, so a clip must not land INSIDE a
        // codepoint: the missing bytes never arrive and the live row would
        // paint replacement garbage that persists for the rest of the turn.
        if (n < bytes.len) n = utf8Floor(bytes, n);
        if (n == 0) return;
        @memcpy(self.buf[cur .. cur + n], bytes[0..n]);
        self.len.store(cur + n, .release);
    }

    /// Largest k <= n where `s[0..k]` ends on a whole UTF-8 codepoint.
    fn utf8Floor(s: []const u8, n: usize) usize {
        if (n == 0 or n >= s.len) return n;
        var k = n;
        while (k > 0) : (k -= 1) {
            const b = s[k - 1];
            if (b < 0x80) return k; // ASCII byte ends a codepoint
            if (b >= 0xc0) { // lead byte: does its whole sequence fit?
                const len = std.unicode.utf8ByteSequenceLength(b) catch return k - 1;
                return if (k - 1 + len <= n) n else k - 1;
            }
        }
        return 0; // all continuation bytes: nothing whole to keep
    }

    pub fn snapshot(self: *StreamBuf, gpa: std.mem.Allocator) ?[]u8 {
        const n = self.len.load(.acquire);
        if (n == 0) return null;
        return gpa.dupe(u8, self.buf[0..n]) catch null;
    }
};

/// A turn backend gets the live text buffer AND the typed event queue (#551):
/// prose streams into `stream` for the pending row's tail view, while every
/// structured moment (tool call, outcome, refusal, notice, failover) is PUSHED
/// as an event. The TUI used to recover the second kind by parsing the first,
/// which is the defect this seam removes.
pub const TurnFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator, history: []const Turn, params: Params, stream: *StreamBuf, events: *events_mod.Queue) ?[]const u8;
/// How a seat is PAID FOR. The TUI never derives this — src/billing.zig owns
/// the rule and the engine hands the answer over with the catalog, the same
/// way it hands over the model names themselves.
pub const CostClass = enum {
    plan,
    credits,
    api,
    local,

    pub fn badge(self: CostClass) []const u8 {
        return switch (self) {
            .plan => "plan",
            .credits => "credits",
            .api => "api",
            .local => "local",
        };
    }
};

/// One row of the model catalog. A bare name was ambiguous: the same model
/// served by codex (a ChatGPT plan), codegraff (gateway credits) and openai (a
/// metered key) drew three identical rows, and picking one resolved the
/// provider by first-name-match rather than by the row the user chose.
pub const ModelEntry = struct {
    name: []const u8,
    provider: []const u8 = "",
    /// False when this provider has no credential in this session. The row
    /// stays — knowing the seat EXISTS is the point — but it is dimmed.
    has_key: bool = false,
    cost: CostClass = .api,
};

/// What a switch actually landed on. The provider travels back with the model
/// so the current-row marker can tell two same-named seats apart.
pub const Picked = struct { model: []const u8, provider: []const u8 = "" };

/// Switch to `name` ON `provider`. An empty `provider` means "the caller does
/// not know one" (a hand-typed `/model <name>`) and asks the engine to route
/// by name, which is what the picker used to be stuck doing for every pick.
pub const ModelFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator, provider: []const u8, name: []const u8) ?Picked;
pub const CancelFn = *const fn (turn_ctx: ?*anyopaque) void;
/// Fill dest with a staged image path (return >0) or an error line (return <0).
pub const PasteFn = *const fn (turn_ctx: ?*anyopaque, dest: []u8) isize;
/// Run a user-typed `!` shell line; return combined output (caller frees), the
/// gate's refusal, or null when the harness could not produce either. `params`
/// carries the session's policy because `!` goes through the same gate the
/// model's bash tool does — a `!` under /plan must be refused (#551).
pub const BashFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator, cmd: []const u8, params: Params) ?[]const u8;
/// Newline-joined repo-relative paths for @-search (caller frees), or null.
pub const FilesFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator) ?[]const u8;
/// Copy text to the system clipboard; true on success.
pub const CopyFn = *const fn (turn_ctx: ?*anyopaque, text: []const u8) bool;
/// Engine-owned history compaction. Fills `out` with gpa-owned note + turns
/// (caller frees). Returns false when history is unchanged.
pub const CompactOut = struct {
    note: []const u8 = "",
    turns: []Turn = &.{},
};
pub const CompactFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator, history: []const Turn, out: *CompactOut) bool;

/// The frontend just discarded part of its transcript. The engine owns the
/// conversation the model actually sees (#551), so it has to be told: without
/// this, /new left the whole old session in the request body and /rewind left
/// a prompt the user had taken back.
pub const HistoryOp = enum { reset, rewind };
pub const HistoryFn = *const fn (turn_ctx: ?*anyopaque, op: HistoryOp) void;

pub const SessionState = struct {
    session_name: []const u8 = "",
    goal: []const u8 = "",
    strict: bool = false,
    ultracode: bool = false,
};
pub const StateFn = *const fn (turn_ctx: ?*anyopaque, state: SessionState) void;

pub const ResumeOut = struct {
    turns: []Turn = &.{},
    session_name: []const u8 = "",
    goal: []const u8 = "",
    strict: bool = false,
    ultracode: bool = false,
    note: []const u8 = "",
};
pub const ResumeFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator, spec: []const u8, out: *ResumeOut) bool;

pub const Job = struct {
    thread: std.Thread = undefined,
    threaded: bool = true,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Thread creation failed; finish still owns reporting and cleanup.
    start_failed: bool = false,
    result: ?[]const u8 = null,
    gpa: std.mem.Allocator,
    history: []Turn,
    params: Params,
    stream: StreamBuf,
    /// grok-build RawTerminal tail: live bash_output_chunk bytes, not prose.
    raw: StreamBuf = .{},
    /// Typed engine events for this turn (#551). Attached to the model's
    /// allocator by startJob; a Job literal that leaves it unattached simply
    /// carries no events.
    events: events_mod.Queue = .{},
};

/// The live job's raw bash tail. tui_sink writes here from the tool pool.
pub var g_raw: ?*StreamBuf = null;

/// Idle auto-wake: a finished background job wants a turn (grok-build notify).
pub const IdleWakeFn = *const fn (turn_ctx: ?*anyopaque, buf: []u8) ?[]const u8;
pub var g_idle_wake_fn: ?IdleWakeFn = null;

/// Run a peer-talk slash (`/tell`, `/peek`) on the live agent. The TUI does
/// not post to the room itself — the host implements this with the existing
/// mailbox (`tellCommand` / `peekCommand`). Caller frees the returned text.
pub const PeerFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator, line: []const u8) ?[]const u8;
pub var g_peer_fn: ?PeerFn = null;

/// A background engine op: `/compact`, `!cmd`, or the @-file list. Same
/// thread + done-flag contract as Job, so the render+input loop keeps painting
/// and Esc keeps reaching keys.handle while the engine works (#533). Every
/// field the worker writes is read only after `done`.
pub const BgOp = struct {
    pub const Kind = enum { compact, bash, files };

    kind: Kind,
    gpa: std.mem.Allocator,
    thread: std.Thread = undefined,
    threaded: bool = true,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Thread creation failed; finish still owns reporting and cleanup.
    start_failed: bool = false,
    /// Esc/Ctrl+C asked the engine to stop; the callbacks observe it through
    /// the same cancel signal a turn uses.
    cancelled: bool = false,
    /// compact input — gpa-owned turns.
    turns: []Turn = &.{},
    /// bash input — gpa-owned command line.
    cmd: []const u8 = "",
    /// The session policy this op runs under, same as a turn's (#551).
    params: Params = .{},
    /// compact output — gpa-owned.
    compact: CompactOut = .{},
    ok: bool = false,
    /// bash / files output — gpa-owned.
    text: ?[]const u8 = null,
};

pub fn bgRun(op: *BgOp) void {
    switch (op.kind) {
        .compact => if (g_compact_fn) |f| {
            op.ok = f(g_turn_ctx, op.gpa, op.turns, &op.compact);
        },
        .bash => if (g_bash_fn) |f| {
            op.text = f(g_turn_ctx, op.gpa, op.cmd, op.params);
        },
        .files => if (g_files_fn) |f| {
            op.text = f(g_turn_ctx, op.gpa);
        },
    }
    op.done.store(true, .release);
}

pub const HudKind = enum { debug, usage, doctor };
pub const HudFn = *const fn (kind: HudKind, buf: []u8) usize;

/// Everything the host frontend hands the loop at startup: the callbacks that
/// reach the real agent and the facts the chrome renders from. Lives with the
/// seam it describes; `run.zig` re-exports it as `run.RunOpts`.
pub const RunOpts = struct {
    turn_ctx: ?*anyopaque = null,
    turn_fn: ?TurnFn = null,
    model_fn: ?ModelFn = null,
    cancel_fn: ?CancelFn = null,
    model_name: []const u8 = "",
    model_provider: []const u8 = "",
    initial_history: []const Turn = &.{},
    session_name: []const u8 = "",
    initial_goal: []const u8 = "",
    initial_strict: bool = false,
    initial_ultracode: bool = false,
    /// The model catalog with its provider column (see ModelEntry).
    model_entries: []const ModelEntry = &.{},
    cwd: []const u8 = ".",
    yolo: bool = false,
    hud_fn: ?HudFn = null,
    paste_fn: ?PasteFn = null,
    bash_fn: ?BashFn = null,
    files_fn: ?FilesFn = null,
    copy_fn: ?CopyFn = null,
    compact_fn: ?CompactFn = null,
    history_fn: ?HistoryFn = null,
    resume_fn: ?ResumeFn = null,
    state_fn: ?StateFn = null,
    emergency_fn: ?*const fn (turn_ctx: ?*anyopaque) void = null,
    idle_wake_fn: ?IdleWakeFn = null,
    peer_fn: ?PeerFn = null,
};

pub var g_turn_fn: ?TurnFn = null;
pub var g_turn_ctx: ?*anyopaque = null;
pub var g_model_fn: ?ModelFn = null;
pub var g_cancel_fn: ?CancelFn = null;
pub var g_hud_fn: ?HudFn = null;
pub var g_paste_fn: ?PasteFn = null;
pub var g_bash_fn: ?BashFn = null;
pub var g_files_fn: ?FilesFn = null;
pub var g_copy_fn: ?CopyFn = null;
pub var g_compact_fn: ?CompactFn = null;
pub var g_history_fn: ?HistoryFn = null;
pub var g_resume_fn: ?ResumeFn = null;
pub var g_state_fn: ?StateFn = null;

/// Tell the engine the transcript was cut. Silent when nothing is wired
/// (offline TUI, unit tests).
pub fn historyChanged(op: HistoryOp) void {
    if (g_history_fn) |f| f(g_turn_ctx, op);
}
pub var g_model_name: []const u8 = "";
/// Provider id serving `g_model_name`. Empty offline.
pub var g_model_provider: []const u8 = "";
/// The model catalog, provider column and all. Single source of truth for
/// every model surface in the TUI — there is no flat name-only string left.
pub var g_model_entries: []const ModelEntry = &.{};
pub var g_cwd: []const u8 = ".";

pub const JobSpawnFn = *const fn (*Job) anyerror!std.Thread;
pub const JobJoinObserver = *const fn () void;
var job_spawn_override: ?JobSpawnFn = null;
var job_join_observer: ?JobJoinObserver = null;

/// Deterministic test seam for thread creation and join accounting. Production
/// always takes the direct std.Thread paths below.
pub fn setJobThreadHooksForTesting(spawn: ?JobSpawnFn, join_observer: ?JobJoinObserver) void {
    std.debug.assert(builtin.is_test);
    job_spawn_override = spawn;
    job_join_observer = join_observer;
}

pub fn spawnJob(job: *Job) !std.Thread {
    if (builtin.is_test) if (job_spawn_override) |spawn| return spawn(job);
    return std.Thread.spawn(.{}, jobRun, .{job});
}

pub fn joinJob(job: *Job) void {
    if (!job.threaded) return;
    if (builtin.is_test) if (job_join_observer) |observe| observe();
    job.thread.join();
}

pub fn jobRun(job: *Job) void {
    const reply = if (g_turn_fn) |f| f(g_turn_ctx, job.gpa, job.history, job.params, &job.stream, &job.events) else null;
    job.result = reply;
    job.done.store(true, .release);
}

test "StreamBuf: append then snapshot, overflow is silent" {
    var buf: [8]u8 = undefined;
    var s: StreamBuf = .{ .buf = &buf };
    s.appendBytes("hello");
    const snap = s.snapshot(std.testing.allocator).?;
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqualStrings("hello", snap);
    s.appendBytes(" world!!!!");
    try std.testing.expectEqual(@as(usize, 8), s.len.load(.acquire));
}

test "StreamBuf: an overflow clip lands on a codepoint boundary" {
    // The dropped tail never arrives, so a clip inside 🚀 would leave the live
    // row painting replacement garbage for the rest of the turn.
    var buf: [8]u8 = undefined;
    var s: StreamBuf = .{ .buf = &buf };
    s.appendBytes("ab");
    s.appendBytes("🚀🚀"); // 8 bytes: only the first fits whole
    const snap = s.snapshot(std.testing.allocator).?;
    defer std.testing.allocator.free(snap);
    try std.testing.expect(std.unicode.utf8ValidateSlice(snap));
    try std.testing.expectEqualStrings("ab🚀", snap);
    // A chunk that cannot contribute even one whole glyph writes nothing.
    var tiny: [2]u8 = undefined;
    var t: StreamBuf = .{ .buf = &tiny };
    t.appendBytes("日");
    try std.testing.expectEqual(@as(usize, 0), t.len.load(.acquire));
}
