//! Frontend-agnostic types the TUI uses to talk to a turn backend.
//! The package never imports the harness: session glue supplies callbacks.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("engine_types.zig");

const events_mod = @import("events.zig");

pub const Event = events_mod.Event;
pub const EventQueue = events_mod.Queue;
pub const ToolEvent = events_mod.Tool;
pub const Status = events_mod.Status;
pub const ModelChanged = events_mod.ModelChanged;
pub const Cost = events_mod.Cost;

pub const Effort = types.Effort;
pub const Mode = types.Mode;
pub const Turn = types.Turn;
pub const Params = types.Params;
pub const StreamBuf = types.StreamBuf;
pub const TurnFn = types.TurnFn;
pub const CostClass = types.CostClass;
pub const ModelEntry = types.ModelEntry;
pub const Picked = types.Picked;
pub const ModelFn = types.ModelFn;
pub const CancelFn = types.CancelFn;
pub const PasteFn = types.PasteFn;
pub const BashFn = types.BashFn;
pub const FilesFn = types.FilesFn;
pub const CopyFn = types.CopyFn;
pub const CompactOut = types.CompactOut;
pub const CompactFn = types.CompactFn;
pub const HistoryOp = types.HistoryOp;
pub const HistoryFn = types.HistoryFn;
pub const GoalOp = types.GoalOp;
pub const SessionState = types.SessionState;
pub const StateFn = types.StateFn;
pub const ResumeOut = types.ResumeOut;
pub const ResumeFn = types.ResumeFn;
pub const SessionsFn = types.SessionsFn;

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
pub const VersionFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator) ?[]const u8;
pub var g_version_fn: ?VersionFn = null;

/// A background engine op: `/compact`, `/version`, `!cmd`, or the @-file list. Same
/// thread + done-flag contract as Job, so the render+input loop keeps painting
/// and Esc keeps reaching keys.handle while the engine works (#533). Every
/// field the worker writes is read only after `done`.
pub const BgOp = struct {
    pub const Kind = enum { compact, bash, files, version };

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
    /// bash / files / version output — gpa-owned.
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
        .version => if (g_version_fn) |f| {
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
    sessions_fn: ?SessionsFn = null,
    state_fn: ?StateFn = null,
    emergency_fn: ?*const fn (turn_ctx: ?*anyopaque) void = null,
    idle_wake_fn: ?IdleWakeFn = null,
    peer_fn: ?PeerFn = null,
    version_fn: ?VersionFn = null,
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
pub var g_sessions_fn: ?SessionsFn = null;
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
