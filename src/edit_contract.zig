//! The work-landing guarantee: a phase contracted to MUTATE must leave a diff.
//!
//! Split from escalation.zig (600-line cap) along a real seam — the ladder
//! decides HOW MUCH orchestration to buy, this decides whether the
//! orchestration produced a patch. They compose (escalation re-exports every
//! symbol here, so call sites see one module) but they answer different
//! questions and fail in different ways.
//!
//! The failure it exists for is stark. Eval run 01-bugfix-B: a two-function
//! bug in one file, a fleet of five workers, three judges, one retry, all 30
//! model calls spent — and `git status` clean at the end. Every worker
//! reported. Nobody edited. Verification read those reports and believed them.
//!
//! So verification stops reading reports. A phase whose canonical slot is
//! implement/build/repair is CONTRACTED, and after it awaits, a
//! `git status --porcelain` probe — no model call, no network — asks the
//! filesystem instead. A tree that did not move converts the result to
//! `is_error`, which makes it eligible for the single retry the workflow loop
//! already runs, with a message that says exactly what was not done.
//! (grok-build's doctrine: edits flow through workers, verification reads real
//! diffs, never worker self-reports.)

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const pb = @import("phase_budget.zig");
const orch_rows = @import("orchestration_rows.zig");
const process_runner = @import("process_runner.zig");

/// The failure text a contracted phase gets when nothing changed on disk.
/// Carries no retry_unsafe_note, so failureAllowsRetry says yes and the
/// existing single retry (workflow.zig) picks it up — which is the point: the
/// worker gets one more attempt, told explicitly what it failed to do.
pub const contract_unmet =
    "edit contract unmet: no files changed. This phase's slot (implement/build/repair) is contracted " ++
    "to MUTATE the working tree, and `git status --porcelain` is unchanged, so whatever was reported " ++
    "was a plan, not a patch. Make the edits with the file tools and end your reply by listing every " ++
    "changed path.";

/// Boilerplate appended to a contracted phase's briefs. Stolen from codex's
/// patch-biased delegation: the worker must name the paths it changed, so the
/// verify phase and the root both review a DIFF rather than a claim.
pub const contract_brief_note =
    "This phase is contracted to change files. Use the file tools to make the edits yourself — do not " ++
    "describe them — and end your final message with a `changed:` line listing every path you wrote.";

pub fn isContracted(role: []const u8) bool {
    return pb.isLandingRole(role);
}

/// PURE contract verdict over two `git status --porcelain` snapshots.
///
/// Two distinct failures, both of which mean nothing landed:
///   * the tree is CLEAN after the phase — no edit, no question;
///   * the tree is byte-identical to before the phase — it was already dirty
///     from earlier work, and this phase added nothing to it. Without this
///     second arm any phase run in a workspace with uncommitted changes would
///     pass the contract for free, which is most real workspaces.
/// Anything else (new lines, changed lines) is a real diff and passes.
pub fn contractUnmet(contracted: bool, before: []const u8, after: []const u8) bool {
    if (!contracted) return false;
    const a = std.mem.trim(u8, after, " \t\r\n");
    if (a.len == 0) return true;
    return std.mem.eql(u8, std.mem.trim(u8, before, " \t\r\n"), a);
}

fn porcelain(gpa: Allocator, io: Io, cwd: ?[]const u8) ?[]u8 {
    const r = if (cwd) |p|
        process_runner.runCapped(gpa, io, &.{ "git", "-C", p, "status", "--porcelain" }, 1 << 16, 8192, 15_000) catch return null
    else
        process_runner.runCapped(gpa, io, &.{ "git", "status", "--porcelain" }, 1 << 16, 8192, 15_000) catch return null;
    defer gpa.free(r.stderr);
    if (!process_runner.ranOk(r)) {
        gpa.free(r.stdout);
        return null;
    }
    return r.stdout;
}

/// Snapshot the working tree, arena-owned. Returns "" for an uncontracted
/// phase (no probe is spawned at all) and for any git failure — a repo the
/// probe cannot read must never fail a phase that may well have succeeded.
pub fn treeSnapshot(arena: Allocator, gpa: Allocator, io: Io, cwd: ?[]const u8, contracted: bool) []const u8 {
    if (!contracted) return "";
    const out = porcelain(gpa, io, cwd) orelse return "";
    defer gpa.free(out);
    return arena.dupe(u8, out) catch "";
}

/// Post-await gate: convert a contracted phase that changed nothing into an
/// error the existing retry can act on. `out` is taken by value and returned
/// (possibly rewritten) so the call site stays one statement.
///
/// Never touches a result that is ALREADY an error — that failure has its own
/// cause and its own retry verdict, and overwriting it would throw away the
/// API error #248 works to surface.
pub fn contractCheck(gpa: Allocator, io: Io, cwd: ?[]const u8, contracted: bool, before: []const u8, out: anytype) @TypeOf(out) {
    if (!contracted or out.is_error) return out;
    const after = porcelain(gpa, io, cwd) orelse return out; // unreadable repo: pass
    defer gpa.free(after);
    if (!contractUnmet(true, before, after)) {
        orch_rows.notePendingLanded(true);
        return out;
    }
    gpa.free(out.text);
    return .{ .text = gpa.dupe(u8, contract_unmet) catch "", .is_error = true };
}
