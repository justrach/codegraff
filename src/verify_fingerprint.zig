//! #412: the no-progress guard in front of a repeated verification.
//!
//! A /goal (or /loop) run is plan-act-VERIFY, and the verifier is the `eval`
//! tool: it runs the --eval command, optionally spawns an LLM judge subagent,
//! and a RED verdict blocks attempt_completion until a fresh green one
//! (agent_tools.handleMeta). So a continuation turn's obvious move is to call
//! eval again - and a model that has not edited anything since the last RED
//! does exactly that, repeatedly. Every one of those re-runs costs the wall
//! clock of the whole scoring command, a judge model call when --judge is set,
//! and 1500 bytes of output tail in the context window, to re-derive a verdict
//! that cannot have changed.
//!
//! So before a re-verify, fingerprint the worktree. Identical to the tree the
//! last verification failed on means nothing can be different, so the verifier
//! is not run at all: the attempt still counts (a no-progress loop must
//! converge on the iteration cap, not spin for free) and the model is steered
//! at the actual blocker - it has to change something first. Straight from the
//! prime agent's `core/autonomous.ts` gate.
//!
//! The fingerprint answers one question - could this verification produce a
//! different result than the last one? - so it folds every input to that
//! answer: the verifier itself, plus the three streams that together describe
//! every uncommitted byte.
//!   * the verifier's own identity (the --eval command text). A session that
//!     re-points --eval is running a DIFFERENT check, and it must run.
//!   * `git status --porcelain -z -uall` - which paths are dirty, and how;
//!   * `git diff --binary HEAD` - the exact content of every TRACKED change;
//!   * the contents of every untracked file the status listed - which the
//!     other two streams do NOT cover. Editing an untracked file leaves both
//!     of them byte-identical (`?? notes.md` says nothing about its bytes), so
//!     without this third stream the guard would skip a verify over real work.
//!
//! FAIL-OPEN is the whole safety story: no repo, no git, a timed-out probe, a
//! truncated stream, an unreadable file, an absurd number of untracked files -
//! every one of them yields "unknown", and an unknown fingerprint never
//! matches, so the verifier runs. The guard can only ever cost a skipped
//! re-run when it is certain nothing moved; it can never invent a pass.
//!
//! The fold and the decision are PURE (digestOf / untrackedPaths /
//! skipReverify) and unit-tested without a repo; only capture() touches git.
//! Reached through the test-root hook in test_hooks.zig - without that line
//! these tests silently compile to nothing and the suite still reports green.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const process_runner = @import("process_runner.zig");

/// A worktree fingerprint. `null` anywhere in this module means UNKNOWN, which
/// is always treated as "changed".
pub const Digest = [32]u8;

/// The sentence the model is steered with when a re-verify is skipped. Kept as
/// its own decl so the tests assert on the contract, not on a format string.
pub const no_progress_steer =
    "the workspace has not changed since the last failed verification — edit source files or tests before attempting to finish again";

/// One labelled byte stream folded into a fingerprint.
pub const Part = struct { label: []const u8, bytes: []const u8 };

/// Per-git-stream output ceiling. Above it the probe reports unknown rather
/// than fingerprinting a truncated diff - a change past the cut would be
/// invisible, which is the one way this guard could wrongly skip a verify.
pub const max_stream_bytes: usize = 8 << 20;
/// Untracked-file ceilings. A workspace carrying a whole vendored tree as
/// untracked files is not worth hashing on every eval; report unknown and let
/// the verifier run.
pub const max_untracked_files: usize = 512;
pub const max_untracked_bytes: usize = 8 << 20;

/// PURE fold. Every field is length-prefixed, so no two different part lists
/// can produce the same byte stream: ("ab","") and ("a","b") must not collide,
/// or moving a byte across a file boundary would read as no change at all.
pub fn digestOf(parts: []const Part) Digest {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var len: [8]u8 = undefined;
    for (parts) |p| {
        std.mem.writeInt(u64, &len, p.label.len, .little);
        h.update(&len);
        h.update(p.label);
        std.mem.writeInt(u64, &len, p.bytes.len, .little);
        h.update(&len);
        h.update(p.bytes);
    }
    var out: Digest = undefined;
    h.final(&out);
    return out;
}

/// PURE parse of `git status --porcelain -z -uall` into the untracked paths
/// whose CONTENTS still have to be folded in. NUL-separated records, so paths
/// are never quoted or escaped - which is exactly why -z is used instead of
/// the human porcelain. A rename/copy record carries its origin path as a
/// second NUL field; that field is consumed here so it can never be mistaken
/// for a record of its own.
pub fn untrackedPaths(arena: Allocator, status_z: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, status_z, 0);
    while (it.next()) |rec| {
        if (rec.len < 4 or rec[2] != ' ') continue;
        const x = rec[0];
        const y = rec[1];
        if (x == 'R' or x == 'C' or y == 'R' or y == 'C') _ = it.next();
        if (x == '?' and y == '?') try out.append(arena, rec[3..]);
    }
    return out.items;
}

/// One git stream, or null on ANY failure: spawn error, nonzero exit, timeout,
/// or a stdout cap hit. Allocated on `arena`; nothing here outlives the turn.
fn gitStream(arena: Allocator, gpa: Allocator, io: Io, argv: []const []const u8) ?[]const u8 {
    const r = process_runner.runCapped(gpa, io, argv, max_stream_bytes, 8192, 30_000) catch return null;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (!process_runner.ranOk(r) or r.stdout_truncated or r.timed_out) return null;
    return arena.dupe(u8, r.stdout) catch null;
}

/// Fingerprint the verification about to run: `verifier` (the --eval command
/// text) over the working tree at the PROCESS cwd, which is where runEval
/// spawns it. Returns null (unknown, i.e. "changed") for anything that is not
/// a clean, complete read.
///
/// Everything read here is scratch and only the 32-byte digest escapes, so it
/// is folded in a PRIVATE arena rather than the caller's: an eval loop calls
/// this once per iteration, and an 8 MiB diff parked on the session arena
/// every time would outlive the whole run.
pub fn capture(gpa: Allocator, io: Io, verifier: []const u8) ?Digest {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const status = gitStream(arena, gpa, io, &.{ "git", "status", "--porcelain", "-z", "-uall" }) orelse return null;
    const diff = gitStream(arena, gpa, io, &.{ "git", "diff", "--binary", "HEAD" }) orelse return null;
    const paths = untrackedPaths(arena, status) catch return null;
    if (paths.len > max_untracked_files) return null;
    var parts: std.ArrayList(Part) = .empty;
    parts.append(arena, .{ .label = "verifier", .bytes = verifier }) catch return null;
    parts.append(arena, .{ .label = "status", .bytes = status }) catch return null;
    parts.append(arena, .{ .label = "diff", .bytes = diff }) catch return null;
    var budget: usize = max_untracked_bytes;
    for (paths) |p| {
        // A file that will not read - deleted between the two probes, a fifo,
        // a symlink to nowhere, or simply bigger than what is left of the
        // budget - makes the whole fingerprint unknown rather than partial.
        const body = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(budget)) catch return null;
        budget -= body.len;
        parts.append(arena, .{ .label = p, .bytes = body }) catch return null;
    }
    return digestOf(parts.items);
}

/// PURE decision: skip the verifier only when the LAST attempt failed and both
/// fingerprints are known and equal. Unknown on either side is "changed".
pub fn skipReverify(last_failed: bool, last: ?Digest, current: ?Digest) bool {
    if (!last_failed) return false;
    const a = last orelse return false;
    const b = current orelse return false;
    return std.mem.eql(u8, &a, &b);
}

/// The tool result a skipped re-verify hands back. It names the iteration (the
/// attempt is counted either way) and says plainly that nothing ran, so the
/// model cannot read it as a fresh verdict.
pub fn noProgressText(arena: Allocator, iter: u32) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "eval #{d} was not run: {s}. The previous RED verdict stands and completion is still blocked; a verifier re-run over an identical tree can only repeat it.",
        .{ iter, no_progress_steer },
    );
}

test "digestOf: identical evidence folds identically, and every stream moves it" {
    const base = [_]Part{
        .{ .label = "verifier", .bytes = "zig build test" },
        .{ .label = "status", .bytes = "?? notes.md\x00" },
        .{ .label = "diff", .bytes = "diff --git a/x b/x\n+one\n" },
        .{ .label = "notes.md", .bytes = "first draft" },
    };
    try std.testing.expectEqual(digestOf(&base), digestOf(&base));

    // A different VERIFIER moves it: a re-pointed --eval is a different check
    // over the same tree, and it has to run.
    var reverifier = base;
    reverifier[0].bytes = "pytest -q";
    try std.testing.expect(!std.mem.eql(u8, &digestOf(&base), &digestOf(&reverifier)));

    // A TRACKED edit moves it (the diff stream changed).
    var tracked = base;
    tracked[2].bytes = "diff --git a/x b/x\n+two\n";
    try std.testing.expect(!std.mem.eql(u8, &digestOf(&base), &digestOf(&tracked)));

    // An UNTRACKED-ONLY edit moves it too, and this is the case the other two
    // streams cannot see: `?? notes.md` and `git diff HEAD` are byte-identical
    // whatever that file contains. Without folding the contents in, editing an
    // untracked file would read as "nothing changed" and skip a real verify.
    var untracked = base;
    untracked[3].bytes = "second draft";
    try std.testing.expect(!std.mem.eql(u8, &digestOf(&untracked), &digestOf(&base)));
    try std.testing.expectEqualStrings(base[1].bytes, untracked[1].bytes);
    try std.testing.expectEqualStrings(base[2].bytes, untracked[2].bytes);

    // A new untracked file is a change even when it is empty.
    const grown = base ++ [_]Part{.{ .label = "scratch", .bytes = "" }};
    try std.testing.expect(!std.mem.eql(u8, &digestOf(&grown), &digestOf(&base)));
}

test "digestOf: length-prefixed, so a byte moved across a boundary is not a collision" {
    // Plain concatenation would make these three indistinguishable - i.e. a
    // rename, or one file's tail becoming the next file's head, would fold to
    // "unchanged" and skip a verification over real work.
    const a = [_]Part{ .{ .label = "f", .bytes = "ab" }, .{ .label = "g", .bytes = "" } };
    const b = [_]Part{ .{ .label = "f", .bytes = "a" }, .{ .label = "g", .bytes = "b" } };
    const c = [_]Part{ .{ .label = "f", .bytes = "" }, .{ .label = "g", .bytes = "ab" } };
    try std.testing.expect(!std.mem.eql(u8, &digestOf(&a), &digestOf(&b)));
    try std.testing.expect(!std.mem.eql(u8, &digestOf(&b), &digestOf(&c)));
    // And the LABEL is part of the identity: the same bytes under a different
    // path is a different worktree.
    const renamed = [_]Part{ .{ .label = "f2", .bytes = "ab" }, .{ .label = "g", .bytes = "" } };
    try std.testing.expect(!std.mem.eql(u8, &digestOf(&renamed), &digestOf(&a)));
    try std.testing.expectEqual(digestOf(&[_]Part{}), digestOf(&[_]Part{}));
}

test "untrackedPaths: only ?? records, and a rename's origin field is consumed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();

    // A realistic -z porcelain: modified, staged-add, a rename (two fields),
    // two untracked files, one of them with a space in its name (unquoted,
    // which is the reason -z is used at all).
    const status = " M src/main.zig\x00A  src/new.zig\x00R  dst.zig\x00src.zig\x00?? notes.md\x00?? a b.txt\x00";
    const paths = try untrackedPaths(ar, status);
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("notes.md", paths[0]);
    try std.testing.expectEqualStrings("a b.txt", paths[1]);

    // The rename's ORIGIN field must not be read as a record of its own: a
    // path beginning "?? " would otherwise be picked up out of it.
    const trap = "R  dst\x00?? not-a-record\x00?? real.txt\x00";
    const trapped = try untrackedPaths(ar, trap);
    try std.testing.expectEqual(@as(usize, 1), trapped.len);
    try std.testing.expectEqualStrings("real.txt", trapped[0]);

    // Empty, all-tracked, and malformed input all yield nothing rather than
    // erroring: a clean tree has no untracked contents to fold.
    try std.testing.expectEqual(@as(usize, 0), (try untrackedPaths(ar, "")).len);
    try std.testing.expectEqual(@as(usize, 0), (try untrackedPaths(ar, " M a\x00")).len);
    try std.testing.expectEqual(@as(usize, 0), (try untrackedPaths(ar, "??\x00?x\x00")).len);
}

test "skipReverify fails OPEN: only a known, equal fingerprint after a failure skips" {
    const a = digestOf(&[_]Part{.{ .label = "s", .bytes = "one" }});
    const b = digestOf(&[_]Part{.{ .label = "s", .bytes = "two" }});

    // The one case that skips.
    try std.testing.expect(skipReverify(true, a, a));
    // A changed tree re-arms it.
    try std.testing.expect(!skipReverify(true, a, b));
    // The last attempt did not fail: there is nothing to re-verify, so the
    // guard is inert (a green eval must never be turned into a skip).
    try std.testing.expect(!skipReverify(false, a, a));
    // Fail-open: a git error, a truncated stream or an unreadable untracked
    // file lands here as null on either side, and never matches. A repo the
    // probe cannot read must never be able to suppress a verification.
    try std.testing.expect(!skipReverify(true, null, a));
    try std.testing.expect(!skipReverify(true, a, null));
    try std.testing.expect(!skipReverify(true, null, null));
}

test "noProgressText names the iteration, carries the steer, and never reads as a verdict" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const text = try noProgressText(ar, 4);
    try std.testing.expect(std.mem.startsWith(u8, text, "eval #4 was not run:"));
    try std.testing.expect(std.mem.indexOf(u8, text, no_progress_steer) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "completion is still blocked") != null);
    // No score, no "TARGET MET": the model must not be able to mistake a
    // skipped run for a fresh green one.
    try std.testing.expect(std.mem.indexOf(u8, text, "score") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "TARGET MET") == null);
}
