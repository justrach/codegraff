//! The ultracode escalation ladder, and the work-landing guarantee.
//!
//! WHAT THIS FIXES. A 16-run eval study ran five ordinary coding tasks three
//! ways: the model solo, the same model with the `ultracode` codeword, and a
//! frontier model solo. Ultracode's ANSWERS were fine — where it finished, it
//! finished correctly. Its PRICE was not: mean 80 against solo's 100, at 3.7x
//! the model calls, two runs killed at the budget ceiling, and one bugfix that
//! spent all 30 calls producing findings and never edited the file at all.
//! That is not a reasoning failure but an ADMISSION failure: nothing ever
//! asked whether the ask deserved a fleet, so the answer was always yes.
//!
//! THE LADDER. `admit()` runs once, before anything spawns, on cheap
//! observables only — no probe call, no model in the loop:
//!
//!   R0 solo    the ask names 1-2 files, or no higher rung admits. The
//!              workflow tool DECLINES, non-error, and says why. This is the
//!              floor, and on ordinary work it is the right answer.
//!   R1 scout   an open-ended exploration ask: one sweep + one synthesis.
//!              opencode's context-economy rule — delegate to keep the
//!              parent's context clean, not to parallelize.
//!   R2 fleet   3+ distinct files/modules named AND the plan plus the landing
//!              reserve fits what is left.
//!   R3 full    audit-class language in the ask (the user asked for breadth,
//!              breadth is what they are paying for), or a prior solo/scout
//!              attempt already failed — first-attempt failure is the free
//!              escalation signal, and the only one worth trusting.
//!   R0d deep   between R0 and the fleet: a FIRST failure on a 1-2 file ask
//!              is reasoning-shaped, not coverage-shaped, so the ladder
//!              prescribes one sequential revision carrying the observed
//!              failure evidence — but only where a verifier exists to catch
//!              a second miss (failure_evidence.zig). A second failure, or a
//!              verifier-less class, goes to R3: the judges are the feedback.
//!
//! Where a learned cell has evidence (orchestration_policy.zig) it overrides
//! the hand rung and the row says `source:"learned"`; otherwise the ladder
//! decides and says `source:"bootstrap"`. A shape the USER named is
//! `source:"explicit"` and is never overridden, in either direction.
//!
//! THE EDIT CONTRACT. Separately from the ladder: a phase whose canonical
//! slot is implement/build/repair is contracted to MUTATE. After it awaits, a
//! `git status --porcelain` probe (no model call) asks whether anything
//! actually changed; a tree that did not move converts the result to
//! `is_error`, making it eligible for the retry that already exists.
//! grok-build's doctrine, and the direct answer to the 30-calls-no-edit run:
//! verification reads a real diff, never a worker's self-report.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig"); // `unattended`: the -p/eval one-shot flag
const shapes = @import("shapes.zig");
const route_policy = @import("route_policy.zig");
const orch = @import("orchestration_policy.zig");
const orch_rows = @import("orchestration_rows.zig");
const pb = @import("phase_budget.zig");
const fe = @import("failure_evidence.zig");
const brief_diversity = @import("brief_diversity.zig");
const fleet = @import("fleet.zig");
const trace = @import("trace.zig");
const util = @import("util.zig");

pub const Rung = orch.Rung;
pub const Source = orch.Source;

/// A fleet is for INDEPENDENT workstreams, and the cheapest honest proxy for
/// "independent" the harness can compute without a model call is "the ask
/// names this many distinct files". Two files is a pair; three is a fan-out.
pub const fleet_scope_min: usize = 3;

// ── observables ────────────────────────────────────────────────────────────

pub const Observables = struct {
    shape: route_policy.Shape = .adhoc,
    task_class: shapes.TaskClass = .other,
    /// Distinct file paths named across every task brief in the plan.
    files: usize = 0,
    /// Widest phase, i.e. how far this plan actually fans out.
    widest: usize = 0,
    tasks: usize = 0,
    plan_estimate: u64 = 0,
    audit: bool = false,
    prior_failure: bool = false,
    /// How MANY times this class already declined — 1 opens R0d, 2+ means the
    /// deep retry was already spent and only the fleet is left.
    prior_failure_count: u8 = 0,
    verifier: fe.Verifier = .none,
    remaining: u64 = 0,
    cap: u64 = 0,
};

/// Bytes that can appear inside a path token. Excludes ':' and ',' so
/// `stats.py:24` and `a.py, b.py` still resolve to one file each.
fn isPathByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == '/' or c == '\\';
}

/// Does this token look like a file path? It needs an extension: a dot with
/// 1-5 letters after it and an alphanumeric before it. That refuses version
/// numbers ("3.11"), ellipses and sentence-ending periods, and accepts
/// `stats.py`, `src/main.zig` and `settings.json`.
fn looksLikeFile(tok: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, tok, '.') orelse return false;
    if (dot == 0 or dot + 1 >= tok.len) return false;
    if (!std.ascii.isAlphanumeric(tok[dot - 1])) return false;
    const ext = tok[dot + 1 ..];
    if (ext.len > 5) return false;
    for (ext) |c| if (!std.ascii.isAlphabetic(c)) return false;
    return true;
}

/// Bound on the file set, so a pathological brief cannot make this loop
/// expensive or the scratch large. Well above `fleet_scope_min`, which is the
/// only threshold that reads the count.
pub const max_files_counted = 32;

const FileSet = struct {
    hashes: [max_files_counted]u64 = @splat(0),
    n: usize = 0,

    fn add(self: *FileSet, tok: []const u8) void {
        if (self.n == self.hashes.len) return;
        var buf: [64]u8 = undefined;
        const m = @min(tok.len, buf.len);
        for (buf[0..m], tok[0..m]) |*d, s| d.* = std.ascii.toLower(s);
        const h = std.hash.Wyhash.hash(0, buf[0..m]);
        for (self.hashes[0..self.n]) |x| if (x == h) return;
        self.hashes[self.n] = h;
        self.n += 1;
    }

    fn scan(self: *FileSet, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) {
            while (i < text.len and !isPathByte(text[i])) : (i += 1) {}
            const start = i;
            while (i < text.len and isPathByte(text[i])) : (i += 1) {}
            if (i == start) continue;
            const tok = std.mem.trim(u8, text[start..i], ".");
            if (tok.len > 0 and looksLikeFile(tok)) self.add(tok);
        }
    }
};

/// Distinct file paths named in `text`. Pure, allocation-free, and bounded.
pub fn countDistinctFiles(text: []const u8) usize {
    var set: FileSet = .{};
    set.scan(text);
    return set.n;
}

fn taskPrompts(pv: Value, set: *FileSet, tasks: *usize, widest: *usize) void {
    if (pv != .object) return;
    const tv = pv.object.get("tasks") orelse return;
    if (tv != .array) return;
    widest.* = @max(widest.*, tv.array.items.len);
    for (tv.array.items) |task_val| {
        tasks.* += 1;
        if (task_val != .object) continue;
        const p = task_val.object.get("prompt") orelse continue;
        if (p == .string) set.scan(p.string);
    }
}

/// Everything the ladder needs, read off the authored plan plus the raw ask.
/// Pure: `raw` is what the user typed (shapes.rawAsk()), `remaining`/`cap`
/// come from the shared RunBudget.
pub fn observe(phases: []const Value, raw: []const u8, shape: route_policy.Shape, remaining: u64, cap: u64) Observables {
    var set: FileSet = .{};
    // The ASK names files too — "fix stats.py" is scope evidence even when
    // the plan's briefs paraphrase it.
    set.scan(raw);
    var o: Observables = .{
        .shape = shape,
        .task_class = shapes.classOf(raw),
        .audit = shapes.isAuditClass(raw),
        .prior_failure = priorAttemptFailed(shapes.classOf(raw)),
        .prior_failure_count = declineCount(shapes.classOf(raw)),
        .verifier = fe.verifierFor(shapes.classOf(raw), false),
        .remaining = remaining,
        .cap = cap,
        .plan_estimate = pb.planEstimate(phases),
    };
    for (phases) |pv| taskPrompts(pv, &set, &o.tasks, &o.widest);
    o.files = set.n;
    return o;
}

// ── the ladder ─────────────────────────────────────────────────────────────

pub const Verdict = union(enum) {
    /// Run the plan as authored.
    proceed,
    /// Run it with every phase capped at this many tasks.
    downsize: usize,
    /// Do not run it; hand the root this advisory instead.
    solo: []const u8,
};

pub const Decision = struct {
    rung: Rung = .R0,
    source: Source = .bootstrap,
    verdict: Verdict = .proceed,
    downsized_from: usize = 0,
};

/// The advisory the workflow tool returns on R0. NON-error on purpose: a
/// declined fleet is not a failed tool call, and returning `is_error` here
/// would burn the retry the edit contract wants to keep, and would read to the
/// model as "the harness is broken" rather than "do this yourself".
pub const solo_advice =
    "workflow declined (escalation R0): budget and scope fit solo work. This ask names 1-2 files, " ++
    "or the pool cannot cover a fleet plus the calls needed to land the work. Do it yourself — read " ++
    "the files, make the edits, verify — and re-invoke the workflow tool only if verification fails, " ++
    "which is the signal that earns a fleet.";

/// The R0d advisory. Same non-error contract as solo_advice; the difference
/// is the prescription — a REVISION, not a redo: re-derive from the observed
/// failure, not from the reasoning that already missed once.
pub const deep_retry_advice =
    "workflow declined (escalation R0d): the first solo attempt failed, but this is a revision case, " ++
    "not a fleet case. Redo the work yourself, deeper: re-read the failure evidence, re-derive the " ++
    "approach from that evidence rather than from your earlier reasoning, and verify against the " ++
    "same signal before answering. If verification fails again, re-invoke the workflow tool — a " ++
    "second failure earns the fleet.";

/// The hand ladder's rung. Ordered by precedence, NOT by cost: the revision
/// rung, then the two escalation signals (an ask that asked for breadth, an
/// attempt that already failed), then the cheap rungs, and R0 is the
/// fallthrough — so a plan that justifies nothing gets nothing.
pub fn ladderRung(o: Observables) Rung {
    const l = pb.Ledger.init(o.cap);
    const fleet_affordable = l.fits(o.remaining, pb.fleetFloor(o.shape));
    // One deep solo retry before the fleet. Checked BEFORE affordability:
    // a revision spends no spawns, so a pool too dry for a fleet can still
    // afford it — and the failure that earns it is reasoning-shaped (small
    // scope), which parallel sampling cannot fix. Weng's gate applies: no
    // verifier, no revision loop.
    if (o.prior_failure and !o.audit and o.prior_failure_count == 1 and
        o.files < fleet_scope_min and o.verifier != .none) return .R0d;
    if ((o.audit or o.prior_failure) and fleet_affordable) return .R3;
    // An open-ended question is the one case where delegation pays for itself
    // at width ONE: the scout burns its own context on the search and hands
    // back a summary, which is the whole benefit. Wider adds cost, not value —
    // measured, in the study's research run: three sweepers over three small
    // files scored identically to one, at 4x the calls, on briefs that
    // measured 1.00 similar to each other.
    if (o.shape == .research and !o.audit) return .R1;
    if (o.files >= fleet_scope_min and o.widest >= 2 and fleet_affordable) return .R2;
    return .R0;
}

/// The widest per-phase task count whose trimmed plan still fits on top of
/// the landing reserve, or 0 when even one worker per phase does not fit.
///
/// Width is the trimming axis because of WHAT it trims. A plan's wide phases
/// are its finders and sweepers — redundant evidence-gathering, the cheapest
/// thing to lose. Its landing phase carries exactly one implementer, so any
/// width cap of 1 or more leaves it completely untouched. That is the
/// ordering §4-P1 asks for (judges first via the P3 gate, redundant finders
/// second, the edit-contract phase never) expressed as one number instead of
/// three special cases.
pub fn downsizeWidth(phases: []const Value, cap: u64, remaining: u64) usize {
    const l = pb.Ledger.init(cap);
    var widest: usize = 1;
    for (phases) |pv| {
        if (pv != .object) continue;
        const tv = pv.object.get("tasks") orelse continue;
        if (tv == .array) widest = @max(widest, tv.array.items.len);
    }
    var w = widest;
    while (w >= 1) : (w -= 1) {
        var total: u64 = 0;
        for (phases) |pv| {
            if (pv != .object) continue;
            const tv = pv.object.get("tasks") orelse continue;
            if (tv != .array) continue;
            total += pb.phaseCost(route_policy.phaseSlot(pv), @min(tv.array.items.len, w));
        }
        if (l.fits(remaining, total)) return w;
        if (w == 1) break;
    }
    return 0;
}

/// Turn a rung into what the workflow loop should actually do.
pub fn verdictFor(rung: Rung, o: Observables, phases: []const Value) Verdict {
    const l = pb.Ledger.init(o.cap);
    switch (rung) {
        .R0 => return .{ .solo = solo_advice },
        .R0d => return .{ .solo = deep_retry_advice },
        // One scout, one synthesis: cap every phase at a single task.
        .R1 => return .{ .downsize = 1 },
        .R2, .R3 => {
            if (l.fits(o.remaining, o.plan_estimate)) return .proceed;
            const w = downsizeWidth(phases, o.cap, o.remaining);
            // Nothing fits, not even one worker per phase, so a fleet here
            // would be a fan-out that cannot finish. Solo is not a demotion,
            // it is the only rung with a budget.
            if (w == 0) return .{ .solo = solo_advice };
            return .{ .downsize = w };
        },
    }
}

// ── session state: prior failure, explicit choice, exploration ─────────────

/// How many times this session already declined (or scouted) an ask of each
/// class. A SECOND workflow call for the same class of ask is the harness's
/// cheapest evidence that the first, cheaper answer did not stick — which is
/// exactly the "a prior solo/R1 attempt failed verification" signal, observed
/// rather than asked for.
/// std.enums.values rather than @typeInfo(...).fields.len: 0.16 spells that
/// field `fields` and the CI-pinned 0.17-dev spells it `field_names`, and this
/// tree has to compile on both.
var g_declined: [std.enums.values(shapes.TaskClass).len]u8 = @splat(0);

pub fn priorAttemptFailed(tc: shapes.TaskClass) bool {
    return g_declined[@intFromEnum(tc)] > 0;
}

pub fn declineCount(tc: shapes.TaskClass) u8 {
    return g_declined[@intFromEnum(tc)];
}

pub fn noteDeclined(tc: shapes.TaskClass) void {
    const i = @intFromEnum(tc);
    if (g_declined[i] < 255) g_declined[i] += 1;
}

/// Test seam / session reset.
pub fn resetSession() void {
    g_declined = @splat(0);
    g_explore_used = false;
    fe.reset();
}

/// R0d's advisory with the class's observed evidence appended. Falls back to
/// the bare advisory on an empty ledger or OOM — the prescription stands even
/// when the harness observed nothing concrete.
pub fn deepRetryAdvice(arena: Allocator, tc: shapes.TaskClass) []const u8 {
    const ev = fe.evidence(tc);
    if (ev.len == 0) return deep_retry_advice;
    return std.fmt.allocPrint(arena, "{s}\n\nPRIOR ATTEMPT EVIDENCE (verify against this, not against your recollection):\n{s}", .{ deep_retry_advice, ev }) catch deep_retry_advice;
}

/// The evidence for THIS turn's ask class — what workflow prepends to R3
/// briefs so a post-failure fleet attacks the observed failure rather than a
/// paraphrase of the original ask.
pub fn evidenceForAsk() []const u8 {
    return fe.evidence(shapes.classOf(shapes.rawAsk()));
}

/// A pipeline that could not fit the pool counts as a declined attempt for
/// every class at once: a pipeline carries items, not an ask, so there is no
/// per-class signal — and under-counting a failed attempt is the error that
/// leaves a genuinely stuck task stuck.
pub fn notePipelineDeclined() void {
    for (&g_declined) |*d| if (d.* < 255) {
        d.* += 1;
    };
}

/// Did the USER choose the shape? Then the ladder advises but never
/// overrules, and the resulting rows are `source:"explicit"` and never fold —
/// the #290 firewall, applied to orchestration the same way it is applied to
/// prompt genomes.
pub fn userChoseShape(raw: []const u8) bool {
    const needles = [_][]const u8{
        "shape a",               "shape b",     "shape c",         "shape d", "shape e",       "shape f",
        "fan out",               "fan-out",     "in parallel",     "spawn ",  "one agent per", "subagents",
        "use the workflow tool", "run a fleet", "parallel agents",
    };
    for (needles) |n| if (util.indexOfIgnoreCase(raw, n) != null) return true;
    return false;
}

/// ε for the exploration probe. One in ten R0 answers is spent buying an
/// observation of the rung above, because a policy that only ever files rows
/// for the arm it already prefers can never learn it was wrong.
pub const explore_epsilon: u32 = 10;
/// Test seam for the one-shot gate below; production reads the real flag.
pub var g_force_oneshot: bool = false;
var g_explore_used: bool = false;
var g_explore_rng: std.Random.DefaultPrng = .init(0x51ac0de);

/// Exploration runs on one-shot / eval invocations only — `main.unattended`,
/// the flag session_run sets on the `-p` path. An interactive session is
/// somebody's actual work, and spending their turn on a probe they did not
/// ask for is not a trade the harness gets to make.
pub fn exploreAllowed() bool {
    return g_force_oneshot or main_mod.unattended;
}

/// Should this R0 answer be spent on a probe instead? Once per session, only
/// on a one-shot run, and only when the rung above is affordable ON TOP of
/// the landing reserve — an exploration that cannot finish teaches nothing
/// except that the budget was too small, which the ladder already knew.
pub fn shouldExplore(o: Observables) bool {
    if (!exploreAllowed() or g_explore_used) return false;
    const l = pb.Ledger.init(o.cap);
    if (!l.fits(o.remaining, pb.fleetFloor(o.shape))) return false;
    if (g_explore_rng.random().uintLessThan(u32, explore_epsilon) != 0) return false;
    g_explore_used = true;
    return true;
}

// ── the whole gate ─────────────────────────────────────────────────────────

/// Everything `admit` needs from the calling agent, so this module never has
/// to import tools.zig (which would put it on the workflow import cycle).
pub const Ctx = struct {
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    tracer: ?*trace.Tracer = null,
    /// The shared pool's state, read once — it is atomic and shared with
    /// concurrent children, so a cached copy would go stale immediately.
    remaining: u64 = std.math.maxInt(u64),
    cap: u64 = 0,
    used: u64 = 0,
    /// The ROOT's resolved model: this decision's fitness stratum.
    stratum: []const u8 = "",
    /// An --eval loop is configured: the strongest verifier, any class.
    has_eval: bool = false,
    agent_cwd: ?[]const u8 = null,
};

/// Build a Ctx from a live ToolCtx, taken as `anytype` so this module stays
/// off tools.zig's import graph (the same trick brief_diversity.noteSiblingBatch
/// uses). Reads the shared pool ONCE, here, so every gate below this point
/// reasons about one consistent snapshot.
pub fn ctxFrom(t: anytype, arena: Allocator) Ctx {
    return .{
        .gpa = t.gpa,
        .io = t.io,
        .arena = arena,
        .tracer = t.tracer,
        .remaining = pb.remainingOf(t.run_budget),
        .cap = pb.capOf(t.run_budget),
        .used = pb.usedOf(t.run_budget),
        .stratum = t.provider.model,
        .has_eval = t.has_eval,
        .agent_cwd = t.agent_cwd,
    };
}

/// The pure decision: ladder, then the learned override, then exploration.
/// Split out of `admit` so the whole threshold matrix is unit-testable with
/// no allocator, no trace file and no process. `arms` is the folded evidence
/// (orch.g_arms in production, fixtures in tests) and `key` is the cell it is
/// consulted under — passed in rather than rebuilt so a test can drive the
/// learned path without a live archive.
pub fn decide(o: Observables, phases: []const Value, explicit: bool, arms: []const orch.ArmObs, key: orch.Key) Decision {
    const ladder = ladderRung(o);
    if (explicit) {
        // The user asked for orchestration. Honour it at R2 or above, mark it
        // explicit, and let nothing learned move it in either direction.
        const rung: Rung = if (ladder.level() >= Rung.R2.level()) ladder else .R2;
        return .{ .rung = rung, .source = .explicit, .verdict = verdictFor(rung, o, phases) };
    }
    const reserve = pb.landingReserve(o.cap);
    if (orch.override(arms, key, ladder, o.remaining, reserve)) |learned| {
        return .{ .rung = learned, .source = .learned, .verdict = verdictFor(learned, o, phases) };
    }
    if (ladder == .R0 and shouldExplore(o)) {
        return .{ .rung = .R1, .source = .explore, .verdict = verdictFor(.R1, o, phases) };
    }
    return .{ .rung = ladder, .source = .bootstrap, .verdict = verdictFor(ladder, o, phases) };
}

/// The learned answer this cell has, falling back to the compiled bootstrap
/// prior — the same two-layer lookup `orch.learnedRung` performs, exposed as
/// a slice so `decide` stays pure.
fn armsFor(key: orch.Key) []const orch.ArmObs {
    for (orch.g_arms) |a| if (a.key.eql(key)) return orch.g_arms;
    return &.{};
}

/// Production entry: observe, decide, record, park. Called once at the top of
/// execWorkflow, before a single future is allocated.
pub fn admit(c: Ctx, phases: []const Value, shape: route_policy.Shape) Decision {
    const raw = shapes.rawAsk();
    var o = observe(phases, raw, shape, c.remaining, c.cap);
    if (c.has_eval) o.verifier = .eval;
    const key: orch.Key = .{
        .task_class = o.task_class,
        .budget_band = orch.BudgetBand.of(o.remaining),
        .stratum = route_policy.stratumOf(c.stratum),
    };
    // The learned lookup is keyed with the REAL stratum; `decide` takes the
    // arms slice so the pure path can be driven with fixtures.
    var d = decide(o, phases, userChoseShape(raw), armsFor(key), key);
    // Nothing learned for this cell? Fall back to the compiled bootstrap
    // prior, which is the study's own measurements as n=2 pseudo-rows.
    if (d.source == .bootstrap and !userChoseShape(raw)) {
        if (orch.learnedRung(key, d.rung, o.remaining, pb.landingReserve(o.cap))) |learned| {
            d = .{ .rung = learned, .source = .learned, .verdict = verdictFor(learned, o, phases) };
        }
    }
    // R0d's advisory carries the observed failure evidence, composed here
    // because verdictFor is pure and the evidence needs the arena.
    if (d.rung == .R0d) d.verdict = .{ .solo = deepRetryAdvice(c.arena, o.task_class) };
    const collapse = predictedCollapse(c.arena, phases);
    orch_rows.emitDecision(.{
        .key = key,
        .arm = d.rung,
        .source = d.source,
        .remaining = o.remaining,
        .scope = orch.ScopeBucket.of(o.files),
        .files = o.files,
        .tasks_authored = o.tasks,
        .tasks_collapsed = collapse.collapsed,
        .downsized_from = switch (d.verdict) {
            .downsize => o.widest,
            else => 0,
        },
        .diversity_mean = collapse.mean,
        .diversity_warn = collapse.warn,
    });
    orch_rows.setPending(key, d.rung, d.source, c.used);
    if (c.tracer) |tr| {
        var buf: [192]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "arm={s} source={s} class={s} files={d} tasks={d} band={s} plan={d} reserve={d}", .{
            d.rung.label(), d.source.label(),        o.task_class.label(), o.files,
            o.tasks,        key.budget_band.label(), o.plan_estimate,      pb.landingReserve(o.cap),
        }) catch "";
        tr.note("escalation", line);
    }
    // A declined (or scouted) ask is what `prior_failure` reads back if the
    // same class of ask returns — the cheapest honest "the small answer did
    // not stick" signal the harness has.
    switch (d.verdict) {
        .solo => noteDeclined(o.task_class),
        .downsize => |w| {
            if (d.rung == .R1) noteDeclined(o.task_class);
            d.downsized_from = if (w < o.widest) o.widest else 0;
        },
        else => {},
    }
    return d;
}

/// A `variants` phase keeps a collapse floor of 2 (see brief_diversity's
/// floors), read off the same canonical slot everything else keys on.
pub fn isVariantsPhase(pv: Value) bool {
    return std.mem.eql(u8, route_policy.phaseSlot(pv), "variants");
}

const CollapsePreview = struct { collapsed: usize = 0, mean: f64 = 0, warn: bool = false };

/// What the collapse gate WILL do to the widest phase, computed pre-spawn so
/// the decision row can carry it. Cheap: the same bounded Jaccard the gate
/// itself runs, over briefs already in memory.
fn predictedCollapse(arena: Allocator, phases: []const Value) CollapsePreview {
    var best: CollapsePreview = .{};
    for (phases) |pv| {
        if (pv != .object) continue;
        const tv = pv.object.get("tasks") orelse continue;
        if (tv != .array or tv.array.items.len < 2) continue;
        const n = @min(tv.array.items.len, brief_diversity.max_briefs);
        const briefs = arena.alloc([]const u8, n) catch return best;
        const genomes = arena.alloc(?[]const u8, n) catch return best;
        for (tv.array.items[0..n], briefs, genomes) |task_val, *b, *g| {
            b.* = "";
            g.* = null;
            if (task_val != .object) continue;
            const p = task_val.object.get("prompt") orelse continue;
            if (p == .string) b.* = p.string;
            g.* = fleet.resolveOverride(task_val.object);
        }
        const r = brief_diversity.analyze(arena, brief_diversity.personaAxis(arena, briefs, genomes) orelse briefs);
        const c = brief_diversity.collapse(arena, briefs, genomes, isVariantsPhase(pv));
        if (c.collapsed() > best.collapsed or r.mean > best.mean) best = .{
            .collapsed = @max(best.collapsed, c.collapsed()),
            .mean = @max(best.mean, r.mean),
            .warn = best.warn or r.warn,
        };
    }
    return best;
}

// ── the edit contract ──────────────────────────────────────────────────────
// Lives next door (600-line cap) and is re-exported whole, so a call site
// reaches the ladder and the landing guarantee through one import.
pub const edit_contract = @import("edit_contract.zig");
pub const failure_evidence = fe;
pub const contract_unmet = edit_contract.contract_unmet;
pub const contract_brief_note = edit_contract.contract_brief_note;
pub const isContracted = edit_contract.isContracted;
pub const contractUnmet = edit_contract.contractUnmet;
pub const treeSnapshot = edit_contract.treeSnapshot;
pub const contractCheck = edit_contract.contractCheck;

test {
    _ = edit_contract;
    _ = fe;
    _ = @import("escalation_tests.zig");
}
