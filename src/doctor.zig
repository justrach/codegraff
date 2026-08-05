//! Read-only health checks behind /doctor (#321).
//!
//! What #321 exposed was not a missing fix but a missing REPORT: a completed
//! goal kept steering unrelated turns, paired with a checklist a different task
//! had written, and nothing in the harness could say so - the user had to infer
//! health from conversation text. These checks read harness-owned state and
//! name what disagrees, under a stable id per finding so support tooling and
//! automation can key off it instead of parsing prose.
//!
//! Pure: `run` takes the state it inspects as a parameter - never a global,
//! never the filesystem or the process table - so every rule here is unit
//! tested against a literal `State` with an injected clock. `snapshot` is the
//! only place an Agent is touched, and it is a field copy.
//!
//! This is the goal/todo SLICE of #321. Its session-lease, owned-job, listener
//! and aggregate-budget checks (DUPLICATE_WORKTREE_OWNER, STALE_SESSION_LEASE,
//! ORPHANED_OWNED_JOB, JOB_SHARES_ROOT_PGID, LISTENER_AFTER_CLEANUP,
//! BUDGET_EXCEEDED, ...) need a durable job/session registry that does not
//! exist yet; they are deliberately absent rather than faked, because a doctor
//! that reports "healthy" from state it cannot see is worse than no doctor.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const Goal = agent_mod.Goal;
const TodoItem = agent_mod.TodoItem;
const goal_state = @import("goal_state.zig");

/// Ordered least-to-most severe: `worst` compares them by tag value, so the
/// declaration order IS the ladder. `error` is spelled as a quoted identifier
/// so @tagName gives the wire name #321 asks for ("info"/"warn"/"error").
pub const Severity = enum {
    info,
    warn,
    @"error",

    /// The one lowercase wire name shared by the text table and the JSON, so a
    /// support script never has to map two vocabularies.
    pub fn name(self: Severity) []const u8 {
        return @tagName(self);
    }
};

/// One finding. `id` is stable and must never be reworded - it is the key
/// automation matches on; `title` and `detail` are the human half, and `detail`
/// carries the evidence (epochs, counts, ages) that makes the finding checkable.
pub const Check = struct {
    id: []const u8,
    severity: Severity,
    title: []const u8,
    detail: []const u8,
};

/// Everything the goal/todo checks read, passed in rather than reached for.
/// Defaults describe a fresh session with no goal, which is a healthy state.
pub const State = struct {
    goal: ?Goal = null,
    todos: []const TodoItem = &.{},
    /// An attempt_completion was refused and the promised second call is now
    /// pre-accepted (goal_state.completionGate). It crosses turn boundaries by
    /// design (#318), so it is state a doctor can and should read.
    completion_gate_armed: bool = false,
    /// Injected clock reading in unix ms. 0 means "no clock supplied": the
    /// age-dependent rules then report rather than suppress, since an unknown
    /// age is not evidence of freshness.
    now_ms: i64 = 0,
};

/// A goal that replaced live work legitimately starts with no checklist of its
/// own while the previous epoch's open items sit parked beside it (#318 parks,
/// it never deletes). That state is normal for a turn or two - the supersession
/// note is already telling the model to write a fresh list - so the mismatch is
/// only reported once the goal has had time to write one.
pub const epoch_mismatch_grace_ms: i64 = 60_000;

/// Copy the goal/todo slice of a live root Agent. The only Agent-aware code
/// here, kept to a field copy so `run` itself stays testable without one.
pub fn snapshot(root: *const Agent, now_ms: i64) State {
    return .{
        .goal = root.goal,
        .todos = root.todos.items,
        .completion_gate_armed = root.completion_gate_armed,
        .now_ms = now_ms,
    };
}

/// Every check, in report order: the always-present evidence line first, then
/// findings. Read-only by construction - it returns text and mutates nothing.
pub fn run(arena: Allocator, st: State) Allocator.Error![]const Check {
    var out: std.ArrayList(Check) = .empty;
    try out.append(arena, try goalStateLine(arena, st));
    if (try epochMismatch(arena, st)) |c| try out.append(arena, c);
    if (try staleGoal(arena, st)) |c| try out.append(arena, c);
    if (try todoEpochAboveGoal(arena, st)) |c| try out.append(arena, c);
    if (try armedCompletionGate(arena, st)) |c| try out.append(arena, c);
    return out.toOwnedSlice(arena);
}

/// The highest severity present, `.info` when nothing is wrong (the evidence
/// line is always there, so an empty result never happens).
pub fn worst(checks: []const Check) Severity {
    var top: Severity = .info;
    for (checks) |c| {
        if (@intFromEnum(c.severity) > @intFromEnum(top)) top = c.severity;
    }
    return top;
}

/// The always-emitted evidence line #321 asks for: goal epoch, status, age,
/// which epoch owns the checklist, and WHY steering will or will not be
/// appended. Always `.info` - a healthy run must produce no warnings.
fn goalStateLine(arena: Allocator, st: State) Allocator.Error!Check {
    const g = st.goal orelse return .{
        .id = "GOAL_STATE",
        .severity = .info,
        .title = "no standing goal",
        .detail = "no goal is set, so no goal steering is appended to your turns.",
    };
    const open = goal_state.openCount(st.todos, g.epoch);
    const total = countEpoch(st.todos, g.epoch);
    const parked = goal_state.parkedOpenCount(st.todos, g.epoch);
    const steering = if (g.status == .active)
        "steering IS appended to every non-review turn"
    else
        "steering is NOT appended: only an active goal steers";
    return .{
        .id = "GOAL_STATE",
        .severity = .info,
        .title = "standing goal",
        .detail = try std.fmt.allocPrint(
            arena,
            "epoch {d} \"{s}\" [{s}{s}], age {s}; its checklist has {d} open of {d} item(s), and {d} open item(s) are parked under other epochs; {s}.",
            .{
                g.epoch,
                g.objective,
                @tagName(g.status),
                if (g.standing) ", standing" else "",
                ageText(arena, st.now_ms, g.created_ms) catch "unknown",
                open,
                total,
                parked,
                steering,
            },
        ),
    };
}

/// #321 GOAL_TODO_EPOCH_MISMATCH: the goal that is steering owns no checklist,
/// yet open items exist under other epochs - so the list the user (and the
/// model's todo_read) sees is not this goal's plan. Reported, never repaired:
/// silently rebinding unrelated todos onto the live epoch is precisely the
/// #318 defect this check exists to catch.
fn epochMismatch(arena: Allocator, st: State) Allocator.Error!?Check {
    const g = st.goal orelse return null;
    // currentEpoch is 0 for a completed goal: a dead epoch owns nothing, and
    // its parked list is expected, not a mismatch.
    const epoch = goal_state.currentEpoch(st.goal);
    if (epoch == 0) return null;
    if (goal_state.hasCurrent(st.todos, epoch)) return null;
    const foreign = goal_state.parkedOpenCount(st.todos, epoch);
    if (foreign == 0) return null;
    if (st.now_ms != 0 and g.created_ms != 0 and st.now_ms - g.created_ms < epoch_mismatch_grace_ms) return null;
    return .{
        .id = "GOAL_TODO_EPOCH_MISMATCH",
        .severity = .warn,
        .title = "the live checklist does not belong to the standing goal",
        .detail = try std.fmt.allocPrint(
            arena,
            "goal epoch {d} \"{s}\" has no checklist of its own, but {d} open todo(s) belong to other epochs. Those items are parked (retained, not steering), so the goal has no evidence it is done and the visible list is someone else's plan. Ask the model for a fresh todo_write checklist, or retire the goal with /goal clear - do not rebind the parked items.",
            .{ g.epoch, g.objective, foreign },
        ),
    };
}

/// #321 STALE_GOAL (the issue's COMPLETED_CHECKLIST_ACTIVE_GOAL): an active
/// goal whose own checklist is entirely complete keeps steering work already
/// done. goal_state.reconcileRestored retires exactly this state at load time,
/// so seeing it live means the session reached it after load and nobody
/// reconciled. A standing --goal is exempt for reconcileRestored's reason: it
/// is the user's policy for the session, and a finished checklist is not their
/// permission to drop it.
fn staleGoal(arena: Allocator, st: State) Allocator.Error!?Check {
    const g = st.goal orelse return null;
    if (g.status != .active or g.standing) return null;
    if (!goal_state.allDone(st.todos, g.epoch)) return null; // an empty epoch is "no plan yet", never done (#226)
    return .{
        .id = "STALE_GOAL",
        .severity = .warn,
        .title = "an active goal has already finished its checklist",
        .detail = try std.fmt.allocPrint(
            arena,
            "goal epoch {d} \"{s}\" is active with every one of its {d} checklist item(s) completed, so its steering note is re-stating finished work on every turn. Close it with /goal clear, or let the next accepted attempt_completion retire it.",
            .{ g.epoch, g.objective, countEpoch(st.todos, g.epoch) },
        ),
    };
}

/// A todo may never carry an epoch above the live goal's: goal_state.nextEpoch
/// mints each goal above every epoch already present, and todos are stamped
/// with currentEpoch, which is at most the goal's. Above it means the epoch
/// counter regressed or a checklist from another session was grafted on - the
/// collision class #318 fixed, reappearing. Loud on purpose.
fn todoEpochAboveGoal(arena: Allocator, st: State) Allocator.Error!?Check {
    const g = st.goal orelse return null;
    var n: usize = 0;
    var top: u64 = 0;
    for (st.todos) |t| {
        if (t.epoch <= g.epoch) continue;
        n += 1;
        top = @max(top, t.epoch);
    }
    if (n == 0) return null;
    return .{
        .id = "TODO_EPOCH_ABOVE_GOAL",
        .severity = .@"error",
        .title = "todos are stamped above the standing goal's epoch",
        .detail = try std.fmt.allocPrint(
            arena,
            "{d} todo(s) carry epoch(s) up to {d} while the goal is on epoch {d}. Epochs only ever climb, so this state cannot be produced by /goal or todo_write: the session file was merged, hand-edited, or restored across a counter reset. Save the session elsewhere before continuing.",
            .{ n, top, g.epoch },
        ),
    };
}

/// The completion double-check is spent: a refusal was issued and the next
/// attempt_completion is pre-accepted (#318), even though the checklist still
/// has open work. Worth naming because it is the one path on which a goal
/// closes with items open, and nothing else in the UI shows it.
fn armedCompletionGate(arena: Allocator, st: State) Allocator.Error!?Check {
    if (!st.completion_gate_armed) return null;
    const g = st.goal orelse return null;
    if (g.status != .active) return null;
    const open = goal_state.openCount(st.todos, goal_state.currentEpoch(st.goal));
    if (open == 0) return null;
    return .{
        .id = "COMPLETION_GATE_ARMED",
        .severity = .warn,
        .title = "the next completion claim will be accepted unchecked",
        .detail = try std.fmt.allocPrint(
            arena,
            "a completion claim on goal epoch {d} was refused, so the promised second attempt_completion is pre-accepted - it will close the goal with {d} item(s) still open. Any todo_write, or a /goal change, re-arms the double-check.",
            .{ g.epoch, open },
        ),
    };
}

/// Items stamped with `epoch`, completed or not.
fn countEpoch(todos: []const TodoItem, epoch: u64) usize {
    var n: usize = 0;
    for (todos) |t| {
        if (t.epoch == epoch and !t.retired) n += 1; // #394: retired history is not part of the live checklist this reports
    }
    return n;
}

/// Coarse age ("4m", "3h", "2d"). "unknown" when either end of the subtraction
/// is missing, which is honest: a persisted goal from before timestamps existed
/// has created_ms 0, and pretending it was born at the epoch would be a lie.
fn ageText(arena: Allocator, now_ms: i64, created_ms: i64) Allocator.Error![]const u8 {
    if (now_ms == 0 or created_ms == 0 or now_ms < created_ms) return "unknown";
    const secs = @divFloor(now_ms - created_ms, 1000);
    if (secs < 60) return std.fmt.allocPrint(arena, "{d}s", .{secs});
    if (secs < 3600) return std.fmt.allocPrint(arena, "{d}m", .{@divFloor(secs, 60)});
    if (secs < 86_400) return std.fmt.allocPrint(arena, "{d}h", .{@divFloor(secs, 3600)});
    return std.fmt.allocPrint(arena, "{d}d", .{@divFloor(secs, 86_400)});
}

/// The human-readable half of #321's output contract.
pub fn render(arena: Allocator, checks: []const Check) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    for (checks) |c| {
        try aw.writer.print("{s:<5}  {s}  {s}\n        {s}\n", .{ c.severity.name(), c.id, c.title, c.detail });
    }
    return aw.writer.buffered();
}

/// The machine-readable half: a stable array of {id, severity, title, detail}
/// so support and automation key off ids instead of scraping the table.
pub fn toJson(arena: Allocator, checks: []const Check) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginArray();
    for (checks) |c| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(c.id);
        try s.objectField("severity");
        try s.write(c.severity.name());
        try s.objectField("title");
        try s.write(c.title);
        try s.objectField("detail");
        try s.write(c.detail);
        try s.endObject();
    }
    try s.endArray();
    return aw.writer.buffered();
}

// ── tests ─────────────────────────────────────────────────────────────────

fn find(checks: []const Check, id: []const u8) ?Check {
    for (checks) |c| {
        if (std.mem.eql(u8, c.id, id)) return c;
    }
    return null;
}

test "doctor: a healthy session reports the evidence line and nothing else (#321)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();

    // No goal at all.
    const none = try run(ar, .{});
    try std.testing.expectEqual(@as(usize, 1), none.len);
    try std.testing.expectEqualStrings("GOAL_STATE", none[0].id);
    try std.testing.expectEqual(Severity.info, worst(none));

    // An active goal working its own checklist: still no warnings (#321
    // acceptance 9 - a healthy single-session run is quiet).
    const todos = [_]TodoItem{
        .{ .content = "a", .status = "completed", .epoch = 3 },
        .{ .content = "b", .status = "pending", .epoch = 3 },
    };
    const healthy = try run(ar, .{
        .goal = .{ .objective = "ship", .epoch = 3, .created_ms = 1_000, .updated_ms = 1_000 },
        .todos = &todos,
        .now_ms = 5_000_000,
    });
    try std.testing.expectEqual(@as(usize, 1), healthy.len);
    try std.testing.expectEqual(Severity.info, worst(healthy));
    try std.testing.expect(std.mem.indexOf(u8, healthy[0].detail, "1 open of 2 item(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, healthy[0].detail, "steering IS appended") != null);
    try std.testing.expect(std.mem.indexOf(u8, healthy[0].detail, "age 1h") != null);
}

test "doctor: GOAL_TODO_EPOCH_MISMATCH names a checklist the goal does not own (#321)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();

    // Goal B is steering; the only open work belongs to A's parked epoch.
    const todos = [_]TodoItem{
        .{ .content = "A's leftover", .status = "pending", .epoch = 1 },
        .{ .content = "A's finished bit", .status = "completed", .epoch = 1 },
    };
    const goal_b: Goal = .{ .objective = "phase B", .epoch = 2, .created_ms = 1_000, .updated_ms = 1_000 };
    const st: State = .{ .goal = goal_b, .todos = &todos, .now_ms = 1_000 + epoch_mismatch_grace_ms };
    const checks = try run(ar, st);
    const hit = find(checks, "GOAL_TODO_EPOCH_MISMATCH") orelse return error.TestExpectedMismatch;
    try std.testing.expectEqual(Severity.warn, hit.severity);
    try std.testing.expect(std.mem.indexOf(u8, hit.detail, "1 open todo(s)") != null);
    try std.testing.expectEqual(Severity.warn, worst(checks));

    // Inside the grace window the same state is the ordinary post-supersession
    // transient: the supersession note is still asking for a fresh checklist.
    var fresh = st;
    fresh.now_ms = 1_000 + epoch_mismatch_grace_ms - 1;
    try std.testing.expect(find(try run(ar, fresh), "GOAL_TODO_EPOCH_MISMATCH") == null);

    // A goal that owns its own list never mismatches, however much is parked.
    const owned = [_]TodoItem{
        .{ .content = "A's leftover", .status = "pending", .epoch = 1 },
        .{ .content = "B's plan", .status = "pending", .epoch = 2 },
    };
    var scoped = st;
    scoped.todos = &owned;
    try std.testing.expect(find(try run(ar, scoped), "GOAL_TODO_EPOCH_MISMATCH") == null);

    // Nor does a completed goal: its epoch is dead and its list parked (#318).
    var done = st;
    done.goal.?.status = .complete;
    try std.testing.expect(find(try run(ar, done), "GOAL_TODO_EPOCH_MISMATCH") == null);
}

test "doctor: STALE_GOAL fires on an active goal with a finished checklist; standing is exempt (#321)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();

    var todos = [_]TodoItem{
        .{ .content = "a", .status = "completed", .epoch = 4 },
        .{ .content = "b", .status = "completed", .epoch = 4 },
    };
    const st: State = .{ .goal = .{ .objective = "ship", .epoch = 4 }, .todos = &todos };
    const hit = find(try run(ar, st), "STALE_GOAL") orelse return error.TestExpectedStale;
    try std.testing.expectEqual(Severity.warn, hit.severity);
    try std.testing.expect(std.mem.indexOf(u8, hit.detail, "2 checklist item(s) completed") != null);

    // One open item and it is live work, not stale steering.
    todos[1].status = "pending";
    try std.testing.expect(find(try run(ar, st), "STALE_GOAL") == null);
    todos[1].status = "completed";

    // A standing --goal is the user's policy for the session: reconcileRestored
    // leaves it alone, and so does the doctor (#318).
    var standing = st;
    standing.goal.?.standing = true;
    try std.testing.expect(find(try run(ar, standing), "STALE_GOAL") == null);

    // An empty epoch is "no plan yet", never done (#226).
    var empty = st;
    empty.todos = &.{};
    try std.testing.expect(find(try run(ar, empty), "STALE_GOAL") == null);
}

test "doctor: TODO_EPOCH_ABOVE_GOAL is an error, and epochs at or below the goal are not (#321)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();

    const grafted = [_]TodoItem{
        .{ .content = "from another session", .status = "pending", .epoch = 9 },
        .{ .content = "ours", .status = "pending", .epoch = 2 },
    };
    const checks = try run(ar, .{ .goal = .{ .objective = "ship", .epoch = 2 }, .todos = &grafted });
    const hit = find(checks, "TODO_EPOCH_ABOVE_GOAL") orelse return error.TestExpectedAboveGoal;
    try std.testing.expectEqual(Severity.@"error", hit.severity);
    try std.testing.expect(std.mem.indexOf(u8, hit.detail, "epoch(s) up to 9") != null);
    try std.testing.expectEqual(Severity.@"error", worst(checks));

    // The normal shape - everything parked at or below the live goal - is quiet.
    const normal = [_]TodoItem{
        .{ .content = "parked", .status = "pending", .epoch = 1 },
        .{ .content = "ours", .status = "pending", .epoch = 2 },
    };
    try std.testing.expect(find(try run(ar, .{ .goal = .{ .objective = "ship", .epoch = 2 }, .todos = &normal }), "TODO_EPOCH_ABOVE_GOAL") == null);
}

test "doctor: COMPLETION_GATE_ARMED warns only while open work remains (#321)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();

    var todos = [_]TodoItem{.{ .content = "a", .status = "pending", .epoch = 1 }};
    var st: State = .{ .goal = .{ .objective = "ship", .epoch = 1 }, .todos = &todos, .completion_gate_armed = true };
    const hit = find(try run(ar, st), "COMPLETION_GATE_ARMED") orelse return error.TestExpectedArmed;
    try std.testing.expectEqual(Severity.warn, hit.severity);
    try std.testing.expect(std.mem.indexOf(u8, hit.detail, "1 item(s) still open") != null);

    // Disarmed, or with the checklist finished, there is nothing to warn about.
    st.completion_gate_armed = false;
    try std.testing.expect(find(try run(ar, st), "COMPLETION_GATE_ARMED") == null);
    st.completion_gate_armed = true;
    todos[0].status = "completed";
    try std.testing.expect(find(try run(ar, st), "COMPLETION_GATE_ARMED") == null);
}

test "doctor: render and toJson carry the stable id and severity (#321)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();

    const todos = [_]TodoItem{.{ .content = "a\"quoted\"", .status = "completed", .epoch = 4 }};
    const checks = try run(ar, .{ .goal = .{ .objective = "ship", .epoch = 4 }, .todos = &todos });
    const text = try render(ar, checks);
    try std.testing.expect(std.mem.indexOf(u8, text, "info   GOAL_STATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "warn   STALE_GOAL") != null);

    const json = try toJson(ar, checks);
    try std.testing.expect(std.mem.startsWith(u8, json, "[{\"id\":\"GOAL_STATE\",\"severity\":\"info\""));
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"STALE_GOAL\",\"severity\":\"warn\"") != null);
    // Details quote the objective, so the machine-readable half only survives
    // if it is escaped: parse it back rather than trusting the substring above.
    const parsed = try std.json.parseFromSlice(std.json.Value, ar, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    try std.testing.expectEqualStrings("STALE_GOAL", parsed.value.array.items[1].object.get("id").?.string);
    try std.testing.expectEqual(Severity.warn, worst(checks));
}

test "doctor: snapshot copies the goal/todo slice of a live root agent (#321)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();

    var root: Agent = undefined;
    root.arena = ar;
    root.todos = .empty;
    root.goal = .{ .objective = "ship", .epoch = 2, .created_ms = 7 };
    root.completion_gate_armed = true;
    try root.todos.append(ar, .{ .content = "a", .status = "pending", .epoch = 2 });

    const st = snapshot(&root, 9);
    try std.testing.expectEqual(@as(u64, 2), st.goal.?.epoch);
    try std.testing.expectEqual(@as(usize, 1), st.todos.len);
    try std.testing.expect(st.completion_gate_armed);
    try std.testing.expectEqual(@as(i64, 9), st.now_ms);
    // And the doctor reads that snapshot exactly as it reads a literal State.
    try std.testing.expect(find(try run(ar, st), "COMPLETION_GATE_ARMED") != null);
}
