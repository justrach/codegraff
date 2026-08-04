//! Structured workflow progress (#63) plus the text run manifest, split out of
//! workflow.zig (which sits at the 600-line cap). Both answer "what did this
//! run do" — one for a machine, one for the model reading the tool result.
//!
//! Why the events exist (#63): an ultracode run reached the REPL only as
//! std.debug.print lines ("  [workflow] phase 1/2: find (3 task(s))"), so any
//! UI wanting a live workflow map had to scrape text. `workflow_progress` is
//! ADDITIVE — the human lines stay, tool_call/tool_result are untouched — and
//! rides the SAME --json stdout path as every other event (main_mod.g_out
//! under g_gui_mu), so parallel task emits can never interleave mid-line.
//!
//! Deliberately NOT here: the navigable REPL element #63 also asks for. That
//! is a separable follow-up; this module is the state it will render.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const shapes = @import("shapes.zig");
const util = @import("util.zig");
const protocol_seq = @import("protocol_seq.zig"); // #330: monotonic `seq` on every --json event

/// Titles and task labels are free text from the model. Cap them so one absurd
/// title can never turn a progress line into a megabyte of JSONL.
const label_cap = 200;

/// Monotonic counter behind the `wf-N` ids. Atomic because two workflows can be
/// in flight on different pool threads (a background job's run alongside the
/// root turn's), and the ids have to stay distinct.
var g_next_run: std.atomic.Value(u64) = .init(1);

/// Test seam: when set, events render here instead of stdout. Lets a unit test
/// prove the workflow.zig call sites actually fire without a live --json
/// session (the real path needs both a stdout writer and a working Io).
pub var g_test_sink: ?*Io.Writer.Allocating = null;

pub const PhaseEvent = struct {
    type: []const u8 = "workflow_progress",
    workflow_id: []const u8,
    /// "" for the run-level event (phase_index 0), "<workflow_id>/p<n>" otherwise.
    phase_id: []const u8,
    /// 1-based. 0 means the run itself — a pipeline has stages, not phases.
    phase_index: usize,
    phase_count: usize,
    /// The canonical slot from shapes.zig, "" when the title is off-vocabulary.
    /// A CLOSED vocabulary is what a consumer can switch on; the authored text
    /// rides along as `title`, which is what it renders.
    phase: []const u8,
    title: []const u8,
    /// started | skipped
    status: []const u8,
    task_count: usize,
};

pub const TaskEvent = struct {
    type: []const u8 = "workflow_progress",
    workflow_id: []const u8,
    phase_id: []const u8,
    task_id: []const u8,
    /// 1-based, within the phase.
    task_index: usize,
    task_count: usize,
    task: []const u8,
    /// running | completed | failed
    status: []const u8,
};

fn writeLine(w: *Io.Writer, ev: anytype, stamp: bool) void {
    if (stamp) {
        // #330: the shared --json stream is one sequence; a workflow event
        // emitted from a pool thread takes its id from the same counter.
        protocol_seq.writeEvent(w, ev) catch return;
    } else {
        var s: std.json.Stringify = .{ .writer = w };
        s.write(ev) catch return;
    }
    w.writeByte('\n') catch return;
}

/// One complete JSON object per line on the shared --json stdout. Best-effort
/// throughout: a progress event must never be able to fail a workflow, so every
/// error path is a silent return.
fn emit(io: Io, ev: anytype) void {
    if (g_test_sink) |sink| return writeLine(&sink.writer, ev, false);
    if (!main_mod.json_mode) return;
    const w = main_mod.g_out orelse return;
    // The same lock guiEmit/printDelta take: workflow tasks emit from pool
    // threads, and a half-written line would corrupt the SDK's JSONL parse.
    main_mod.g_gui_mu.lockUncancelable(io);
    defer main_mod.g_gui_mu.unlock(io);
    writeLine(w, ev, true);
    w.flush() catch return;
}

/// A fresh `wf-N` id, arena-allocated so every phase and task event of the run
/// keys to the same string.
pub fn nextRunId(arena: Allocator) ![]const u8 {
    return std.fmt.allocPrint(arena, "wf-{d}", .{g_next_run.fetchAdd(1, .monotonic)});
}

fn phaseId(arena: Allocator, run_id: []const u8, index: usize) ?[]const u8 {
    if (index == 0) return "";
    return std.fmt.allocPrint(arena, "{s}/p{d}", .{ run_id, index }) catch null;
}

/// Phase lifecycle (#63). `index` is 1-based; 0 is the run-level event a
/// pipeline emits in place of a phase.
pub fn phase(io: Io, arena: Allocator, run_id: []const u8, index: usize, count: usize, title: []const u8, status: []const u8, task_count: usize) void {
    emit(io, PhaseEvent{
        .workflow_id = run_id,
        .phase_id = phaseId(arena, run_id, index) orelse return,
        .phase_index = index,
        .phase_count = count,
        .phase = shapes.canonicalSlot(title),
        .title = util.utf8Prefix(title, label_cap),
        .status = status,
        .task_count = task_count,
    });
}

/// Task lifecycle inside a phase (#63). `index` is 1-based within the phase.
pub fn task(io: Io, arena: Allocator, run_id: []const u8, phase_index: usize, index: usize, count: usize, label: []const u8, status: []const u8) void {
    const pid = phaseId(arena, run_id, phase_index) orelse return;
    emit(io, TaskEvent{
        .workflow_id = run_id,
        .phase_id = pid,
        .task_id = std.fmt.allocPrint(arena, "{s}/t{d}", .{ pid, index }) catch return,
        .task_index = index,
        .task_count = count,
        .task = util.utf8Prefix(label, label_cap),
        .status = status,
    });
}

// ── U2: all-failed abort + run manifest ─────────────────────────────────────
// A phase where every task failed used to still feed {{prev}} — a bare
// "(no result — task failed)" header per task — into the next phase, so a
// synthesis stage confidently answered from zero evidence (the worst output
// class: a wrong answer that looks researched). buildAbortText and
// buildManifest are kept PURE (no ctx/io) so both are unit-testable without
// running a real subagent.

pub const PhaseTally = struct {
    phase_no: usize,
    total_phases: usize,
    title: []const u8,
    ok: usize,
    total: usize,
    retried: usize,
    skipped_when: ?[]const u8 = null,
    /// #382 — the fleet-diversity note for this phase, or "" when its briefs
    /// were varied enough (or too few to judge). Carried on the tally rather
    /// than printed at the phase, because the manifest is the one part of a
    /// workflow result the ROOT reliably reads: intermediate phases are
    /// summarised into {{prev}} for the NEXT phase, and a note meant for the
    /// orchestrator must not end up in a worker's prompt instead.
    diversity: []const u8 = "",
};

/// Build the hard-stop text for a phase where every task failed: the
/// assembled per-task failure headers plus a line naming the phase, so the
/// caller (or a human) can see exactly why the run stopped instead of
/// silently receiving empty "evidence". `details` is parallel to `labels`
/// (#248): each entry is that task's capped one-line error excerpt, or "" when
/// the task left nothing to report.
pub fn buildAbortText(arena: Allocator, labels: []const []const u8, details: []const []const u8, phase_no: usize, total_phases: usize, title: []const u8) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    for (labels, details) |label, detail| {
        try aw.writer.print("### {s} (no result — task failed)\n", .{label});
        if (detail.len > 0) try aw.writer.print("{s}\n", .{detail});
        try aw.writer.writeAll("\n");
    }
    try aw.writer.print("workflow aborted: every task in phase {d}/{d} ({s}) failed", .{ phase_no, total_phases, title });
    return aw.writer.buffered();
}

/// Build the trailing "## workflow" manifest block from one tally per phase —
/// currently the only way the orchestrator learns a phase was skipped, or
/// that a synthesis stage is about to work from partial (some-tasks-failed)
/// evidence rather than a clean phase.
pub fn buildManifest(arena: Allocator, tallies: []const PhaseTally) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll("## workflow\n");
    for (tallies) |t| {
        if (t.skipped_when) |w| {
            try aw.writer.print("phase {d}/{d} {s}: SKIPPED (when=\"{s}\")\n", .{ t.phase_no, t.total_phases, t.title, w });
        } else {
            try aw.writer.print("phase {d}/{d} {s}: {d}/{d} ok, {d} retried\n", .{ t.phase_no, t.total_phases, t.title, t.ok, t.total, t.retried });
        }
        if (t.diversity.len > 0) try aw.writer.print("{s}\n", .{t.diversity});
    }
    return std.mem.trimEnd(u8, aw.writer.buffered(), "\n");
}

// ── tests ───────────────────────────────────────────────────────────────────
// Imported here only so the tests below can drive the real engine; workflow.zig
// imports this module back, which Zig allows (no comptime cycle).
const tools = @import("tools.zig");
const workflow = @import("workflow.zig");

test "workflow_progress (#63): a phase transition emits structured state, not just a log line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var sink: Io.Writer.Allocating = .init(a);
    g_test_sink = &sink;
    defer g_test_sink = null;

    // A phase whose task entries are not objects returns AFTER the phase-start
    // emit and BEFORE any subagent is spawned, so this drives the real
    // execWorkflow call site with no network and no fan-out.
    var ctx: tools.ToolCtx = undefined;
    ctx.gpa = std.testing.allocator;
    ctx.io = std.testing.io;
    ctx.from_sub = false;
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"phases\":[{\"title\":\"find security bugs\",\"tasks\":[1,2]}]}", .{});
    const out = try workflow.execWorkflow(ctx, input);
    std.testing.allocator.free(out.text);

    const line = std.mem.trimEnd(u8, sink.writer.buffered(), "\n");
    // Exactly one event, and one complete JSON object on its own line.
    try std.testing.expect(line.len > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
    const ev = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
    try std.testing.expectEqualStrings("workflow_progress", ev.object.get("type").?.string);
    try std.testing.expectEqualStrings("started", ev.object.get("status").?.string);
    // The phase is named from the CLOSED slot vocabulary so a consumer can key
    // on it; the authored text rides along as `title` for rendering.
    try std.testing.expectEqualStrings("find", ev.object.get("phase").?.string);
    try std.testing.expectEqualStrings("find security bugs", ev.object.get("title").?.string);
    try std.testing.expectEqual(@as(i64, 1), ev.object.get("phase_index").?.integer);
    try std.testing.expectEqual(@as(i64, 1), ev.object.get("phase_count").?.integer);
    try std.testing.expectEqual(@as(i64, 2), ev.object.get("task_count").?.integer);
    // Stable ids: the phase id is derived from the run id.
    const wf = ev.object.get("workflow_id").?.string;
    try std.testing.expect(std.mem.startsWith(u8, wf, "wf-"));
    const pid = ev.object.get("phase_id").?.string;
    try std.testing.expect(std.mem.startsWith(u8, pid, wf));
    try std.testing.expectEqualStrings("/p1", pid[wf.len..]);
}

test "workflow_progress (#63): task ids nest under the phase, and a run-level event carries no phase" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var sink: Io.Writer.Allocating = .init(a);
    g_test_sink = &sink;
    defer g_test_sink = null;

    const run = try nextRunId(a);
    task(std.testing.io, a, run, 2, 3, 4, "read ChatWorkRow.tsx", "running");
    // phase_index 0 is the run-level event a pipeline emits: no phase, no id.
    phase(std.testing.io, a, run, 0, 2, "pipeline", "started", 5);

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, sink.writer.buffered(), "\n"), '\n');
    const t = try std.json.parseFromSliceLeaky(std.json.Value, a, lines.next().?, .{});
    try std.testing.expectEqualStrings("workflow_progress", t.object.get("type").?.string);
    try std.testing.expectEqualStrings("running", t.object.get("status").?.string);
    try std.testing.expectEqualStrings("read ChatWorkRow.tsx", t.object.get("task").?.string);
    try std.testing.expectEqual(@as(i64, 3), t.object.get("task_index").?.integer);
    try std.testing.expectEqual(@as(i64, 4), t.object.get("task_count").?.integer);
    const pid = t.object.get("phase_id").?.string;
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/p2", .{run}), pid);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/t3", .{pid}), t.object.get("task_id").?.string);

    const p = try std.json.parseFromSliceLeaky(std.json.Value, a, lines.next().?, .{});
    try std.testing.expectEqual(@as(i64, 0), p.object.get("phase_index").?.integer);
    try std.testing.expectEqualStrings("", p.object.get("phase_id").?.string);
    // "pipeline" is not a canonical slot, so the closed-vocabulary field is
    // empty rather than minting a cell name nothing can score.
    try std.testing.expectEqualStrings("", p.object.get("phase").?.string);
    try std.testing.expectEqualStrings("pipeline", p.object.get("title").?.string);
    try std.testing.expect(lines.next() == null);
}
