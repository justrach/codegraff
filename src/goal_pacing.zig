//! Time-aware /loop pacing: the optional duration prefix on `/loop`, the run
//! clock it arms, and the pacing line every continuation turn carries.
//!
//! Everything the model reads here is INFORMATION, never enforcement. This
//! repo dropped goal budget enforcement on purpose (#224), and that stands: a
//! deadline's only hard effect is that the /loop controller stops the run with
//! the `expired` outcome. The rest is guidance, on the prior art's reasoning -
//! codex renders tokens_used/token_budget/remaining_tokens into its
//! continuation prompt on every turn, and LemonHarness feeds wall-clock phases
//! (explore, implement, validate, wrap up), both because a model that cannot
//! see the clock cannot pace itself and will happily spend a whole budget on
//! exploration.
//!
//! Pure text and arithmetic - no Io, the caller passes the clock reading - so
//! every rule here is unit-tested. Reached through the `test { _ = ... }` hook
//! in main.zig; without that line these tests silently compile to nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Agent = @import("agent.zig").Agent;

/// A parsed `/loop` argument: an optional wall-clock budget and the prompt.
pub const LoopBudget = struct {
    /// Milliseconds from now until the run's deadline, or null for no deadline.
    deadline_ms_delta: ?i64 = null,
    /// The prompt the turn actually runs. Never empty for a parsed budget.
    prompt: []const u8,
};

/// Parse the text after `/loop`. A leading `<integer><s|m|h>` followed by
/// whitespace and a nonempty prompt is a budget; ANYTHING else is not, and the
/// whole text is the prompt. That fallback is the important half: `/loop 30m`
/// on its own is someone asking the model about thirty minutes, not an empty
/// run, and `/loop 30mins of cleanup` is a sentence. Rejecting silently costs
/// nothing (the run just has no deadline); guessing wrong would either eat the
/// user's prompt or start a run they never asked to be timed.
pub fn parseLoopBudget(text: []const u8) LoopBudget {
    const trimmed = std.mem.trim(u8, text, " \t");
    const none: LoopBudget = .{ .prompt = trimmed };
    var digits: usize = 0;
    while (digits < trimmed.len and std.ascii.isDigit(trimmed[digits])) digits += 1;
    if (digits == 0 or digits >= trimmed.len) return none;
    const unit: i64 = switch (trimmed[digits]) {
        's' => std.time.ms_per_s,
        'm' => std.time.ms_per_min,
        'h' => std.time.ms_per_hour,
        else => return none,
    };
    const rest = trimmed[digits + 1 ..];
    // The unit must END the token: "30mins" is a word, not a budget.
    if (rest.len == 0 or (rest[0] != ' ' and rest[0] != '\t')) return none;
    const prompt = std.mem.trim(u8, rest, " \t");
    if (prompt.len == 0) return none;
    const n = std.fmt.parseInt(i64, trimmed[0..digits], 10) catch return none;
    if (n <= 0) return none; // "0m" is not a deadline that already passed, it is a typo
    const delta = std.math.mul(i64, n, unit) catch return none;
    // Clamped, not rejected: "/loop 9999h soak" is a real (if odd) instruction,
    // and an unclamped delta overflowed pacingNote's percent math (round-4
    // verifier: a typed line panicked Debug builds and mis-phased ReleaseFast).
    return .{ .deadline_ms_delta = @min(delta, max_budget_ms), .prompt = prompt };
}

/// A week: past it nothing about a run is meaningful, and the percent math stays in i64.
pub const max_budget_ms: i64 = 7 * 24 * std.time.ms_per_hour;

/// The same parse straight off an input line, so the caller stays one line.
/// Returns null when the line is not a `/loop` invocation at all.
pub fn loopBudgetFromLine(line: []const u8) ?LoopBudget {
    if (!std.mem.startsWith(u8, line, "/loop ")) return null;
    return parseLoopBudget(line["/loop".len..]);
}

/// The wall clock of ONE /loop run: when it started and when it must stop.
/// Run-local like LoopListGate and never persisted - a fresh run, a user steer
/// and a stop all reset it. The deadline is mirrored onto the Agent so a
/// subagent spawned mid-run can inherit it (goal_pacing.childTaskPrompt).
pub const LoopClock = struct {
    started_ms: i64 = 0,
    deadline_ms: ?i64 = null,

    pub fn arm(self: *LoopClock, root: *Agent, now_ms: i64, delta: ?i64) void {
        self.started_ms = now_ms;
        self.deadline_ms = if (delta) |d| now_ms +| d else null;
        root.loop_deadline_ms = self.deadline_ms;
    }

    pub fn clear(self: *LoopClock, root: *Agent) void {
        self.* = .{};
        root.loop_deadline_ms = null;
    }

    /// Has the run's budget run out as of `now_ms`? Always false without one.
    pub fn expired(self: LoopClock, now_ms: i64) bool {
        const d = self.deadline_ms orelse return false;
        return now_ms >= d;
    }
};

/// What every freshly-typed input line does to the run clock. A `/loop ...`
/// line starts a run: its clock begins now (not after the first turn, so a
/// "30m" the user typed really is 30 minutes of theirs) and the previous run's
/// completion evidence is dropped - a checklist finished BEFORE this prompt is
/// not evidence that THIS prompt is done, which ended a standing goal's next
/// run at iteration 1 as accepted (#318). Any other line means no run is in
/// flight, so the clock clears and its deadline stops reaching subagents; a
/// turn that errors out mid-run would otherwise leave one armed for good.
pub fn armFreshRun(clock: *LoopClock, root: *Agent, now_ms: i64, budget: ?LoopBudget) void {
    const b = budget orelse return clock.clear(root);
    root.todos_dirty = false;
    clock.arm(root, now_ms, b.deadline_ms_delta);
}

/// armFreshRun plus one line of feedback the instant a wall clock arms. Silent
/// arming hid misparses: `/loop 5m ...` quietly took the "5m" out of the prompt
/// AND started a deadline whose only trace was an `expired` stop minutes later.
pub fn armAndAnnounce(clock: *LoopClock, root: *Agent, out: *Io.Writer, arena: Allocator, now_ms: i64, budget: ?LoopBudget) !void {
    armFreshRun(clock, root, now_ms, budget);
    const d = (budget orelse return).deadline_ms_delta orelse return;
    try out.print("\xe2\x8f\xb1 /loop budget: {s}\n", .{try fmtDur(arena, d)});
    try out.flush();
}

/// "45s" / "12m" / "1h5m" - short enough to sit inside a bracketed note.
pub fn fmtDur(arena: Allocator, ms: i64) ![]const u8 {
    const secs = @divTrunc(@max(0, ms), std.time.ms_per_s);
    if (secs < 60) return std.fmt.allocPrint(arena, "{d}s", .{secs});
    const mins = @divTrunc(secs, 60);
    if (mins < 60) return std.fmt.allocPrint(arena, "{d}m", .{mins});
    return std.fmt.allocPrint(arena, "{d}h{d}m", .{ @divTrunc(mins, 60), @mod(mins, 60) });
}

/// One phase hint, chosen by how much of the budget is LEFT. Straight from
/// LemonHarness's phase split, compressed to a single sentence so it can ride
/// on every continuation without becoming noise the model learns to skip.
fn phaseHint(pct_left: i64) []const u8 {
    if (pct_left >= 70) return "There is room to explore and plan freely before committing.";
    if (pct_left >= 30) return "Focus on implementation; do not re-explore ground you have already settled.";
    if (pct_left >= 10) return "Prioritize finishing and validating what exists over starting new work.";
    return "Wrap up now: preserve what works, start nothing new, and report the exact state.";
}

/// The pacing line appended to each /loop continuation turn. The iteration
/// count is unconditional - a model that cannot see how many continuations it
/// has left cannot decide whether to open a new thread of work - and a run with
/// a wall-clock budget also gets the remaining time and one phase hint.
pub fn pacingNote(arena: Allocator, now_ms: i64, clock: LoopClock, iters_used: u32, iters_cap: u32) ![]const u8 {
    const elapsed = try fmtDur(arena, now_ms - clock.started_ms);
    const deadline = clock.deadline_ms orelse
        return std.fmt.allocPrint(arena, "[pace: continuation {d} of {d}, {s} elapsed.]", .{ iters_used, iters_cap, elapsed });
    const total = @max(1, deadline - clock.started_ms);
    const left = @max(0, deadline - now_ms);
    // Divide before multiplying: parseLoopBudget clamps, but this math must not
    // depend on every caller remembering that (left * 100 overflowed i64).
    const pct = @divTrunc(left, @max(1, @divTrunc(total, 100)));
    return std.fmt.allocPrint(arena, "[pace: continuation {d} of {d}, {s} elapsed, ~{s} of the time budget left ({d}%). {s}]", .{ iters_used, iters_cap, elapsed, try fmtDur(arena, left), pct, phaseHint(pct) });
}

/// How much of the parent's remaining time a child is asked to leave behind, so
/// the parent can actually integrate what the child returns: 10%, never less
/// than a minute. A child that finishes exactly on the parent's deadline is a
/// child whose work is thrown away.
pub const integration_margin_floor_ms: i64 = std.time.ms_per_min;

/// The budget a child spawned at `now_ms` gets from a parent deadline.
/// Absolute deadlines PROPAGATE; they are never sliced. Wall-clock is shared
/// state - three concurrent children all live through the same minute, so
/// dividing the remaining time between them would give each one a third of a
/// budget it is not actually competing for. Every child gets the same
/// (deadline - now) minus the integration margin. May be <= 0.
pub fn childBudgetMs(deadline_ms: i64, now_ms: i64) i64 {
    const left = deadline_ms - now_ms;
    return left - @max(integration_margin_floor_ms, @divTrunc(left, 10));
}

/// A child's task prompt, prefixed with the parent's time budget when a /loop
/// deadline is live. Returns `prompt` untouched when there is none, so an
/// ordinary session's subagents are byte-identical to before. Guidance only:
/// subagents get no watchdog in this round, because a killed child returns
/// nothing at all, which is strictly worse than a late one.
pub fn childTaskPrompt(arena: Allocator, prompt: []const u8, deadline_ms: ?i64, now_ms: i64) ![]const u8 {
    const deadline = deadline_ms orelse return prompt;
    const budget = childBudgetMs(deadline, now_ms);
    if (budget <= 0)
        return std.fmt.allocPrint(arena, "[time budget: the parent's deadline is imminent; return your best partial result immediately]\n\n{s}", .{prompt});
    const mins = @max(1, @divTrunc(budget, std.time.ms_per_min));
    return std.fmt.allocPrint(arena, "[time budget: conclude within ~{d}m and return results - the parent must integrate them before its own deadline; prefer decisive action and a partial result over overrunning]\n\n{s}", .{ mins, prompt });
}

test "parseLoopBudget: a duration prefix arms a deadline, anything else is prompt" {
    const b1 = parseLoopBudget("30m fix the flaky test");
    try std.testing.expectEqual(@as(?i64, 30 * std.time.ms_per_min), b1.deadline_ms_delta);
    try std.testing.expectEqualStrings("fix the flaky test", b1.prompt);
    try std.testing.expectEqual(@as(?i64, 45 * std.time.ms_per_s), parseLoopBudget("45s ship it").deadline_ms_delta);
    try std.testing.expectEqual(@as(?i64, 2 * std.time.ms_per_hour), parseLoopBudget(" 2h  land the release ").deadline_ms_delta);
    try std.testing.expectEqualStrings("land the release", parseLoopBudget(" 2h  land the release ").prompt);
}

test "parseLoopBudget: every ambiguous shape stays a prompt, verbatim" {
    // The one that matters: a bare duration is a QUESTION, not an empty run.
    const bare = parseLoopBudget("30m");
    try std.testing.expect(bare.deadline_ms_delta == null);
    try std.testing.expectEqualStrings("30m", bare.prompt);
    for ([_][]const u8{
        "30mins of cleanup", // the unit has to end the token
        "30 m fix it", // and be attached to the number
        "30x fix it", // unknown unit
        "fix it in 30m", // not a prefix
        "0m fix it", // a zero budget is a typo, not an instant deadline
        "30m   ", // no prompt after the duration
        "99999999999999999999h go", // parseInt overflow
    }) |text| {
        const b = parseLoopBudget(text);
        try std.testing.expect(b.deadline_ms_delta == null);
        try std.testing.expectEqualStrings(std.mem.trim(u8, text, " \t"), b.prompt);
    }
    // An absurd-but-parseable duration clamps to the week cap instead of
    // feeding pacingNote a deadline whose percent math overflows i64.
    try std.testing.expectEqual(@as(?i64, max_budget_ms), parseLoopBudget("30000000000h go").deadline_ms_delta);
    // And the whole thing only fires on a real /loop line.
    try std.testing.expect(loopBudgetFromLine("/goal 30m ship") == null);
    try std.testing.expectEqual(@as(?i64, 5 * std.time.ms_per_min), loopBudgetFromLine("/loop 5m ship").?.deadline_ms_delta);
}

/// The two Agent fields this file's helpers touch, initialized; everything
/// else stays undefined ON PURPOSE, so a future read of another field in this
/// path fails loudly under the testing allocator instead of passing by luck.
fn pacingRoot() Agent {
    var root: Agent = undefined;
    root.loop_deadline_ms = null;
    root.todos_dirty = false;
    return root;
}

test "LoopClock: arms and clears the Agent-visible deadline together" {
    var root = pacingRoot();
    var clock: LoopClock = .{};
    clock.arm(&root, 1_000, null);
    try std.testing.expect(clock.deadline_ms == null and root.loop_deadline_ms == null);
    try std.testing.expect(!clock.expired(9_999_999)); // no budget, never expires
    clock.arm(&root, 1_000, 60_000);
    try std.testing.expectEqual(@as(?i64, 61_000), clock.deadline_ms);
    try std.testing.expectEqual(@as(?i64, 61_000), root.loop_deadline_ms); // the subagent-visible copy
    try std.testing.expect(!clock.expired(60_999));
    try std.testing.expect(clock.expired(61_000)); // the instant it lands, not one tick later
    clock.clear(&root);
    try std.testing.expect(clock.deadline_ms == null and root.loop_deadline_ms == null and clock.started_ms == 0);
}

test "childTaskPrompt: the same absolute deadline reaches every child, minus a margin" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const prompt = "audit the retry path";

    // No /loop deadline: the child's prompt is untouched, byte for byte.
    try std.testing.expectEqualStrings(prompt, try childTaskPrompt(ar, prompt, null, 0));

    // 60 minutes left -> 6 minutes of margin -> 54 for the child. Three
    // siblings spawned in the same instant all get 54, not 18: they share the
    // clock, they are not spending each other's time.
    const hour: i64 = 60 * std.time.ms_per_min;
    try std.testing.expectEqual(@as(i64, 54 * std.time.ms_per_min), childBudgetMs(hour, 0));
    const timed = try childTaskPrompt(ar, prompt, hour, 0);
    try std.testing.expect(std.mem.startsWith(u8, timed, "[time budget: conclude within ~54m and return results"));
    try std.testing.expect(std.mem.endsWith(u8, timed, "\n\naudit the retry path")); // the task itself is unchanged
    try std.testing.expect(std.mem.indexOf(u8, timed, "partial result over overrunning") != null);

    // The margin has a floor: a short window is mostly margin, and a 90-second
    // one leaves nothing at all rather than pretending 30s is a research budget.
    try std.testing.expectEqual(@as(i64, 9 * std.time.ms_per_min), childBudgetMs(10 * std.time.ms_per_min, 0));
    try std.testing.expectEqual(@as(i64, 30 * std.time.ms_per_s), childBudgetMs(90 * std.time.ms_per_s, 0));
    try std.testing.expect(std.mem.indexOf(u8, try childTaskPrompt(ar, prompt, 90 * std.time.ms_per_s, 0), "~1m") != null); // never "~0m"

    // Inside the margin, or already past the deadline: the spawn is NOT blocked
    // (a refused child is a lost child), it is told to come back at once.
    for ([_]i64{ 30 * std.time.ms_per_s, 0, -60 * std.time.ms_per_s }) |left| {
        const urgent = try childTaskPrompt(ar, prompt, left, 0);
        try std.testing.expect(std.mem.startsWith(u8, urgent, "[time budget: the parent's deadline is imminent"));
        try std.testing.expect(std.mem.endsWith(u8, urgent, "\n\naudit the retry path"));
    }
}

test "armFreshRun: a /loop line starts the clock, any other line ends it" {
    var root = pacingRoot();
    root.todos_dirty = true; // left over from the previous run
    var clock: LoopClock = .{};

    armFreshRun(&clock, &root, 5_000, loopBudgetFromLine("/loop 30m fix the flaky test"));
    try std.testing.expectEqual(@as(i64, 5_000), clock.started_ms); // the user's 30m starts when they typed it
    try std.testing.expectEqual(@as(?i64, 5_000 + 30 * std.time.ms_per_min), root.loop_deadline_ms);
    try std.testing.expect(!root.todos_dirty);

    // A /loop with no duration still starts a run, just an untimed one.
    armFreshRun(&clock, &root, 9_000, loopBudgetFromLine("/loop keep going"));
    try std.testing.expectEqual(@as(i64, 9_000), clock.started_ms);
    try std.testing.expect(root.loop_deadline_ms == null);

    // Any other typed line means no run is in flight. Without this a turn that
    // errored out mid-run left a deadline armed, and every later subagent - of
    // any turn, forever - was told to hurry for a run that ended long ago.
    armFreshRun(&clock, &root, 12_000, loopBudgetFromLine("/loop 5m ship"));
    try std.testing.expect(root.loop_deadline_ms != null);
    armFreshRun(&clock, &root, 13_000, null);
    try std.testing.expect(root.loop_deadline_ms == null and clock.deadline_ms == null and clock.started_ms == 0);
}

test "pacingNote: iterations always, then remaining time and one phase hint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();

    // No budget: the model still learns how many continuations it has left,
    // and nothing more - a sentence restating the absence of a budget was pure
    // compaction fodder (25 unique copies per run, round-4 verifier).
    const plain = try pacingNote(ar, 90_000, .{ .started_ms = 0 }, 3, 25);
    try std.testing.expectEqualStrings("[pace: continuation 3 of 25, 1m elapsed.]", plain);

    const clock: LoopClock = .{ .started_ms = 0, .deadline_ms = 60 * std.time.ms_per_min };
    const hints = [_]struct { now: i64, frag: []const u8 }{
        .{ .now = 6 * std.time.ms_per_min, .frag = "explore and plan freely" }, // 90% left
        .{ .now = 30 * std.time.ms_per_min, .frag = "Focus on implementation" }, // 50% left
        .{ .now = 42 * std.time.ms_per_min, .frag = "Focus on implementation" }, // 30% left, the low edge
        .{ .now = 45 * std.time.ms_per_min, .frag = "Prioritize finishing" }, // 25% left
        .{ .now = 55 * std.time.ms_per_min, .frag = "Wrap up now" }, // 8% left
        .{ .now = 70 * std.time.ms_per_min, .frag = "Wrap up now" }, // already over
    };
    for (hints) |h| {
        const note = try pacingNote(ar, h.now, clock, 1, 25);
        try std.testing.expect(std.mem.indexOf(u8, note, h.frag) != null);
        try std.testing.expect(std.mem.indexOf(u8, note, "continuation 1 of 25") != null);
        try std.testing.expect(std.mem.indexOf(u8, note, "of the time budget left") != null);
    }
    // The boundaries are inclusive-from-above, and an overrun never reports
    // negative time left.
    try std.testing.expect(std.mem.indexOf(u8, try pacingNote(ar, 18 * std.time.ms_per_min, clock, 1, 25), "explore and plan freely") != null); // exactly 70%
    try std.testing.expect(std.mem.indexOf(u8, try pacingNote(ar, 70 * std.time.ms_per_min, clock, 1, 25), "~0s of the time budget left (0%)") != null);
}
