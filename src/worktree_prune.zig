//! The age column on `graff worktree list` and the retention policy behind
//! `graff worktree prune --older-than <days>` (#112). Split out of jobs.zig,
//! which sits against the 600-line cap.
//!
//! Removal reuses agent_worktree.worktreeKeepReason — the same predicate that
//! guards subagent worktree cleanup — so a worktree that is dirty, holds
//! commits nothing else references, or cannot be verified is never removed no
//! matter how old it is. Age only ever makes that gate STRICTER, and retention
//! stays opt-in: bare `prune` still only drops git registrations.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const process_runner = @import("process_runner.zig");
const runCapped = process_runner.runCapped;
const ranOk = process_runner.ranOk;
const agent_worktree = @import("agent_worktree.zig");
const KeepReason = agent_worktree.KeepReason;
const worktreeKeepReason = agent_worktree.worktreeKeepReason;
const keepReasonText = agent_worktree.keepReasonText;
const worktree_lease = @import("worktree_lease.zig");
const unixMs = @import("util.zig").unixMs;

/// True if the current git working tree has uncommitted *tracked* changes
/// (staged or unstaged). Untracked files (`?? …`) don't count —
/// `git reset --hard` leaves them alone, so they are safe around a land.
/// Moved from jobs.zig, which sits against the 600-line cap.
pub fn treeDirty(gpa: Allocator, io: Io) bool {
    const r = runCapped(gpa, io, &.{ "git", "status", "--porcelain" }, 1 << 16, 8192, 30_000) catch return false;
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    if (!ranOk(r)) return false;
    var it = std.mem.tokenizeScalar(u8, r.stdout, '\n');
    while (it.next()) |line| {
        if (line.len >= 2 and !std.mem.startsWith(u8, line, "??")) return true;
    }
    return false;
}

/// Age we could not establish. Never "0" — an unreadable mtime must keep the
/// worktree, not make it look brand new (or, worse, infinitely old).
pub const unknown_age_ms: i64 = -1;

pub const Entry = struct {
    path: []const u8 = "",
    head: []const u8 = "",
    branch: []const u8 = "", // refs/heads/… , empty when detached or bare
    bare: bool = false,
    detached: bool = false,
    locked: bool = false,
    prunable: bool = false,
};

/// Parse `git worktree list --porcelain`. Fields borrow `porcelain`.
pub fn parseEntries(arena: Allocator, porcelain: []const u8) Allocator.Error![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    var it = std.mem.splitScalar(u8, porcelain, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "worktree ")) {
            try list.append(arena, .{ .path = line["worktree ".len..] });
            continue;
        }
        if (list.items.len == 0) continue; // attribute before any record: ignore
        const e = &list.items[list.items.len - 1];
        if (std.mem.startsWith(u8, line, "HEAD ")) {
            e.head = line["HEAD ".len..];
        } else if (std.mem.startsWith(u8, line, "branch ")) {
            e.branch = line["branch ".len..];
        } else if (std.mem.eql(u8, line, "bare")) {
            e.bare = true;
        } else if (std.mem.eql(u8, line, "detached")) {
            e.detached = true;
        } else if (std.mem.startsWith(u8, line, "locked")) {
            e.locked = true;
        } else if (std.mem.startsWith(u8, line, "prunable")) {
            e.prunable = true;
        }
    }
    return list.toOwnedSlice(arena);
}

/// The main checkout's path, derived from `--git-common-dir` (`<main>/.git`).
/// `git worktree list` documents the main worktree first, but the safety of a
/// whole repo should not rest on output ordering (#112).
pub fn mainWorktreePath(common_dir: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, std.mem.trim(u8, common_dir, " \t\r\n"), "/");
    if (std.mem.eql(u8, t, ".git")) return ".";
    if (!std.mem.endsWith(u8, t, "/.git")) return ""; // bare repo, or unknown shape
    return t[0 .. t.len - "/.git".len];
}

pub fn shortBranch(refname: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, refname, "refs/heads/")) refname["refs/heads/".len..] else refname;
}

/// Branch names graff itself mints for scratch worktrees (`-w` tabs and
/// isolated subagents). `prune` deletes only these: a hand-made branch NAME is
/// user state even once its commits are reachable from somewhere else.
pub fn isGraffScratchBranch(refname: []const u8) bool {
    const name = shortBranch(refname);
    return std.mem.startsWith(u8, name, "worktree-") or std.mem.startsWith(u8, name, "graff/agents/");
}

/// True when some ref OTHER than the worktree's own branch contains its HEAD,
/// i.e. its commits are reachable without it. `refs` is one refname per line
/// from `git branch --all --contains <head> --format=%(refname)`.
pub fn containedElsewhere(refs: []const u8, own_branch: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, refs, '\n');
    while (it.next()) |raw| {
        const ref = std.mem.trim(u8, raw, " \t\r*+");
        if (ref.len == 0) continue;
        if (own_branch.len > 0 and std.mem.eql(u8, ref, own_branch)) continue;
        return true;
    }
    return false;
}

/// Sentinel fed to `worktreeKeepReason` as the creation base when a worktree's
/// HEAD is reachable from nowhere else. It is deliberately not a sha, so the
/// base != head comparison there reports `.committed`.
const unique_commits_base = "graff:unique-commits";

/// A prune candidate has no recorded creation base (unlike a subagent worktree,
/// which records one at spawn), so translate the equivalent question git CAN
/// answer — is this HEAD reachable from another ref? — into the base that makes
/// worktreeKeepReason give the right verdict.
pub fn containmentBase(head: []const u8, contained: bool) []const u8 {
    if (head.len == 0) return ""; // unknown head: worktreeKeepReason says unverifiable
    return if (contained) head else unique_commits_base;
}

pub const PruneVerdict = enum { remove, keep_main, keep_too_new, keep_dirty, keep_committed, keep_unverifiable };

/// The whole retention decision, pure. Safety comes BEFORE age: an ancient
/// worktree that still holds uncommitted work or branch-only commits stays,
/// however far past the retention window it is.
pub fn pruneVerdict(is_main: bool, keep: KeepReason, age_ms: i64, older_than_ms: i64) PruneVerdict {
    if (is_main) return .keep_main; // never the user's own repo
    switch (keep) {
        .dirty => return .keep_dirty,
        .committed => return .keep_committed,
        .unverifiable => return .keep_unverifiable,
        .removed => {},
    }
    if (age_ms < 0) return .keep_unverifiable; // unreadable mtime is not "age 0"
    return if (age_ms >= older_than_ms) .remove else .keep_too_new;
}

pub fn verdictText(v: PruneVerdict) []const u8 {
    return switch (v) {
        .remove => "",
        .keep_main => "the main checkout",
        .keep_too_new => "newer than the retention window",
        .keep_dirty => keepReasonText(.dirty),
        .keep_committed => keepReasonText(.committed),
        .keep_unverifiable => keepReasonText(.unverifiable),
    };
}

/// `--older-than <days>`; fractional days allowed so `--older-than 0.5` cleans
/// up within a day. Anything not a finite, non-negative, plausible number is
/// rejected rather than silently widening the window to "everything".
pub fn parseOlderThanMs(text: []const u8) ?i64 {
    const days = std.fmt.parseFloat(f64, std.mem.trim(u8, text, " \t")) catch return null;
    if (!(days >= 0) or !(days <= 3650)) return null; // NaN fails both comparisons
    return @intFromFloat(days * @as(f64, @floatFromInt(std.time.ms_per_day)));
}

/// Age column vocabulary: the same shape /sessions uses, but from an elapsed
/// span so the formatting stays testable without a clock.
pub fn formatAge(buf: []u8, age_ms: i64) []const u8 {
    if (age_ms < 0) return "?";
    const s = @divTrunc(age_ms, std.time.ms_per_s);
    if (s < 60) return "new";
    if (s < std.time.s_per_hour) return std.fmt.bufPrint(buf, "{d}m", .{@divTrunc(s, 60)}) catch "?";
    if (s < std.time.s_per_day) return std.fmt.bufPrint(buf, "{d}h", .{@divTrunc(s, std.time.s_per_hour)}) catch "?";
    return std.fmt.bufPrint(buf, "{d}d", .{@divTrunc(s, std.time.s_per_day)}) catch "?";
}

fn worktreeAgeMs(io: Io, now_ms: i64, path: []const u8) i64 {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return unknown_age_ms;
    const mtime_ms: i64 = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms));
    const age = now_ms - mtime_ms;
    return if (age < 0) 0 else age; // clock skew, not a stale worktree
}

/// `worktreeKeepReason` for a listed worktree, gathering the two facts it needs
/// from git. Any failed probe stays `.unverifiable`, i.e. keeps the worktree.
fn keepReasonFor(gpa: Allocator, io: Io, e: Entry) KeepReason {
    const st = runCapped(gpa, io, &.{ "git", "-C", e.path, "status", "--porcelain" }, 1 << 16, 8192, 30_000) catch return .unverifiable;
    defer {
        gpa.free(st.stdout);
        gpa.free(st.stderr);
    }
    if (!ranOk(st)) return .unverifiable;
    if (e.head.len == 0) return .unverifiable;
    const refs = runCapped(gpa, io, &.{ "git", "branch", "--all", "--contains", e.head, "--format=%(refname)" }, 1 << 16, 8192, 30_000) catch return .unverifiable;
    defer {
        gpa.free(refs.stdout);
        gpa.free(refs.stderr);
    }
    if (!ranOk(refs)) return .unverifiable;
    const base = containmentBase(e.head, containedElsewhere(refs.stdout, e.branch));
    return worktreeKeepReason(true, st.stdout, base, e.head);
}

/// Remove the directory git registered for `e`. No `--force`: we already proved
/// the tree is clean, so git's own refusal is a second belt — #112 must not
/// turn `prune` into a data-loss command.
fn removeWorktree(gpa: Allocator, io: Io, e: Entry) bool {
    const rm = runCapped(gpa, io, &.{ "git", "worktree", "remove", e.path }, 8192, 8192, 60_000) catch return false;
    defer {
        gpa.free(rm.stdout);
        gpa.free(rm.stderr);
    }
    if (!ranOk(rm)) return false;
    if (isGraffScratchBranch(e.branch)) {
        if (runCapped(gpa, io, &.{ "git", "branch", "-D", shortBranch(e.branch) }, 8192, 8192, 30_000)) |b| {
            gpa.free(b.stdout);
            gpa.free(b.stderr);
        } else |_| {}
    }
    return true;
}

fn listPorcelain(gpa: Allocator, io: Io) ?process_runner.CappedRun {
    const r = runCapped(gpa, io, &.{ "git", "worktree", "list", "--porcelain" }, 1 << 18, 8192, 30_000) catch return null;
    if (!ranOk(r)) {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
        return null;
    }
    return r;
}

/// `graff worktree list`: every worktree with how long it has sat untouched,
/// under the canonical identity of the checkout you are standing in (#320).
pub fn listWithAge(gpa: Allocator, io: Io, arena: Allocator, out: *Io.Writer) !void {
    const r = listPorcelain(gpa, io) orelse {
        try out.writeAll("not a git repository (no worktrees)\n");
        return;
    };
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    try out.print("{s}\n", .{worktree_lease.identityLine(arena, worktree_lease.currentIdentity(gpa, io, arena))});
    const entries = try parseEntries(arena, r.stdout);
    const main_path = mainWorktreePath(worktree_lease.gitCommonDir(gpa, io, arena));
    const now_ms = unixMs(io);
    for (entries, 0..) |e, i| {
        var abuf: [24]u8 = undefined;
        const age = formatAge(&abuf, worktreeAgeMs(io, now_ms, e.path));
        const label = if (e.branch.len > 0) shortBranch(e.branch) else if (e.detached) "(detached)" else if (e.bare) "(bare)" else "";
        const is_main = i == 0 or (main_path.len > 0 and std.mem.eql(u8, e.path, main_path));
        const tag: []const u8 = if (is_main)
            "  (main checkout)"
        else if (@import("experiment_pool.zig").isExperimentTree(e.path, e.branch))
            "  (experiment pool)"
        else
            "";
        try out.print("{s: <5} {s}  [{s}]{s}\n", .{ age, e.path, label, tag });
    }
}

/// `graff worktree prune [--older-than <days>]`. The registration sweep is
/// unconditional (that is what prune always did); directory removal only
/// happens when the user names a retention window (#112).
pub fn pruneCommand(gpa: Allocator, io: Io, arena: Allocator, out: *Io.Writer, args: []const []const u8) !void {
    const p = runCapped(gpa, io, &.{ "git", "worktree", "prune" }, 8192, 8192, 30_000) catch {
        try out.writeAll("not a git repository (nothing to prune)\n");
        return;
    };
    gpa.free(p.stdout);
    gpa.free(p.stderr);
    try out.writeAll("✓ pruned stale worktree registrations\n");

    const window = parseOlderThanArg(args) orelse {
        try out.writeAll("  directories left alone — `graff worktree prune older-than <days>` also removes stale ones\n");
        return;
    };
    const older_than_ms = window orelse {
        try out.writeAll("usage: graff worktree prune [older-than <days>]   (days: a non-negative number)\n");
        return;
    };
    try removeStale(gpa, io, arena, out, older_than_ms);
}

/// null = the window was not asked for; `.?` = null means it was asked for with
/// a value we refuse.
///
/// Both spellings are accepted on purpose. `older-than <days>` is the one that
/// works today: args.zig's global flag loop fatals on any unrecognised `--flag`
/// before a subcommand ever sees it, and only `mcp`/`learn` are on its
/// pass-everything-through list. `--older-than` is the spelling #112 asks for,
/// so it is honoured here and lights up as soon as `worktree` joins that list.
pub fn parseOlderThanArg(args: []const []const u8) ??i64 {
    for (args, 0..) |a, i| {
        const key = std.mem.trimStart(u8, a, "-");
        if (std.mem.startsWith(u8, key, "older-than=")) return parseOlderThanMs(key["older-than=".len..]);
        if (std.mem.eql(u8, key, "older-than")) {
            if (i + 1 >= args.len) return @as(?i64, null);
            return parseOlderThanMs(args[i + 1]);
        }
    }
    return null;
}

fn removeStale(gpa: Allocator, io: Io, arena: Allocator, out: *Io.Writer, older_than_ms: i64) !void {
    const r = listPorcelain(gpa, io) orelse return;
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    const entries = try parseEntries(arena, r.stdout);
    const main_path = mainWorktreePath(worktree_lease.gitCommonDir(gpa, io, arena));
    const now_ms = unixMs(io);
    var removed: usize = 0;
    for (entries, 0..) |e, i| {
        const is_main = i == 0 or (main_path.len > 0 and std.mem.eql(u8, e.path, main_path));
        const verdict = pruneVerdict(is_main, keepReasonFor(gpa, io, e), worktreeAgeMs(io, now_ms, e.path), older_than_ms);
        switch (verdict) {
            .keep_main => continue,
            .remove => if (removeWorktree(gpa, io, e)) {
                removed += 1;
                try out.print("  removed {s}\n", .{e.path});
            } else {
                try out.print("  kept {s} — git refused to remove it\n", .{e.path});
            },
            else => try out.print("  kept {s} — {s}\n", .{ e.path, verdictText(verdict) }),
        }
    }
    try out.print("✓ removed {d} stale worktree director{s}\n", .{ removed, if (removed == 1) @as([]const u8, "y") else "ies" });
}

test "pruneVerdict: age never overrides the #276 safety gate (#112)" {
    const week = 7 * std.time.ms_per_day;
    const ancient = 400 * std.time.ms_per_day;
    // Only a clean, verifiable, base-identical worktree past the window goes.
    try std.testing.expectEqual(PruneVerdict.remove, pruneVerdict(false, .removed, week, week));
    try std.testing.expectEqual(PruneVerdict.remove, pruneVerdict(false, .removed, ancient, week));
    try std.testing.expectEqual(PruneVerdict.keep_too_new, pruneVerdict(false, .removed, week - 1, week));
    // …and being ancient buys nothing when the worktree still holds work.
    try std.testing.expectEqual(PruneVerdict.keep_dirty, pruneVerdict(false, .dirty, ancient, week));
    try std.testing.expectEqual(PruneVerdict.keep_committed, pruneVerdict(false, .committed, ancient, week));
    try std.testing.expectEqual(PruneVerdict.keep_unverifiable, pruneVerdict(false, .unverifiable, ancient, week));
    // An unreadable mtime keeps the worktree instead of reading as brand new.
    try std.testing.expectEqual(PruneVerdict.keep_unverifiable, pruneVerdict(false, .removed, unknown_age_ms, week));
    // The main checkout is never a candidate, whatever git says about it.
    try std.testing.expectEqual(PruneVerdict.keep_main, pruneVerdict(true, .removed, ancient, week));
    try std.testing.expectEqual(PruneVerdict.keep_main, pruneVerdict(true, .removed, ancient, 0));
}

test "parseOlderThanMs: rejects anything that would widen the window silently (#112)" {
    try std.testing.expectEqual(@as(?i64, 7 * std.time.ms_per_day), parseOlderThanMs("7"));
    try std.testing.expectEqual(@as(?i64, std.time.ms_per_day / 2), parseOlderThanMs("0.5"));
    try std.testing.expectEqual(@as(?i64, 0), parseOlderThanMs(" 0 "));
    try std.testing.expectEqual(@as(?i64, null), parseOlderThanMs("-1"));
    try std.testing.expectEqual(@as(?i64, null), parseOlderThanMs("nan"));
    try std.testing.expectEqual(@as(?i64, null), parseOlderThanMs("inf"));
    try std.testing.expectEqual(@as(?i64, null), parseOlderThanMs("seven"));
    try std.testing.expectEqual(@as(?i64, null), parseOlderThanMs(""));
}

test "parseOlderThanArg: absent window keeps prune non-destructive, bad value is an error (#112)" {
    try std.testing.expect(parseOlderThanArg(&.{}) == null);
    try std.testing.expect(parseOlderThanArg(&.{"--dry"}) == null);
    const three = @as(?i64, 3 * std.time.ms_per_day);
    // The spelling that survives args.zig's global flag loop today…
    try std.testing.expectEqual(three, parseOlderThanArg(&.{ "older-than", "3" }).?);
    try std.testing.expectEqual(three, parseOlderThanArg(&.{"older-than=3"}).?);
    // …and the one #112 names, ready for when `worktree` gets pass-through.
    try std.testing.expectEqual(three, parseOlderThanArg(&.{ "--older-than", "3" }).?);
    try std.testing.expectEqual(three, parseOlderThanArg(&.{"--older-than=3"}).?);
    try std.testing.expect(parseOlderThanArg(&.{"older-than"}).? == null); // missing value
    try std.testing.expect(parseOlderThanArg(&.{ "--older-than", "soon" }).? == null);
}

test "parseEntries: reads paths, heads, branches and flags from --porcelain (#112)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try parseEntries(arena_state.allocator(),
        \\worktree /repo
        \\HEAD aaaa
        \\branch refs/heads/main
        \\
        \\worktree /repo/.graff/worktrees/foo
        \\HEAD bbbb
        \\branch refs/heads/worktree-foo
        \\
        \\worktree /repo/.graff/worktrees/bar
        \\HEAD cccc
        \\detached
        \\prunable gitdir file points to non-existent location
        \\
    );
    try std.testing.expectEqual(@as(usize, 3), out.len);
    try std.testing.expectEqualStrings("/repo", out[0].path);
    try std.testing.expectEqualStrings("refs/heads/worktree-foo", out[1].branch);
    try std.testing.expectEqualStrings("bbbb", out[1].head);
    try std.testing.expect(out[2].detached and out[2].prunable);
    try std.testing.expectEqualStrings("", out[2].branch);
}

test "mainWorktreePath: the repo itself is identified by its common dir, not list order (#112)" {
    try std.testing.expectEqualStrings("/repo", mainWorktreePath("/repo/.git\n"));
    try std.testing.expectEqualStrings("/repo", mainWorktreePath("/repo/.git/"));
    try std.testing.expectEqualStrings(".", mainWorktreePath(".git"));
    try std.testing.expectEqualStrings("", mainWorktreePath("")); // unknown: fall back to list order
    try std.testing.expectEqualStrings("", mainWorktreePath("/repo/bare.git"));
}

test "containedElsewhere/containmentBase: branch-only commits map to .committed (#112)" {
    const own = "refs/heads/worktree-foo";
    try std.testing.expect(!containedElsewhere("refs/heads/worktree-foo\n", own));
    try std.testing.expect(containedElsewhere("refs/heads/worktree-foo\nrefs/heads/main\n", own));
    try std.testing.expect(containedElsewhere("refs/remotes/origin/main\n", own));
    try std.testing.expect(!containedElsewhere("\n  \n", own));

    // Reachable from main → nothing unique here → removable.
    try std.testing.expectEqual(KeepReason.removed, worktreeKeepReason(true, "", containmentBase("bbbb", true), "bbbb"));
    // Reachable from nowhere else → its commits exist ONLY here.
    try std.testing.expectEqual(KeepReason.committed, worktreeKeepReason(true, "", containmentBase("bbbb", false), "bbbb"));
    // No head at all → unverifiable, so it is kept.
    try std.testing.expectEqual(KeepReason.unverifiable, worktreeKeepReason(true, "", containmentBase("", true), ""));
}

test "isGraffScratchBranch: prune deletes graff's own branches, never a hand-made one (#112)" {
    try std.testing.expect(isGraffScratchBranch("refs/heads/worktree-foo"));
    try std.testing.expect(isGraffScratchBranch("refs/heads/graff/agents/sa-1-aa11"));
    try std.testing.expect(!isGraffScratchBranch("refs/heads/main"));
    try std.testing.expect(!isGraffScratchBranch("refs/heads/feature/my-worktree-thing"));
    try std.testing.expectEqualStrings("worktree-foo", shortBranch("refs/heads/worktree-foo"));
}

test "formatAge: the list column, and '?' when the mtime could not be read (#112)" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("?", formatAge(&buf, unknown_age_ms));
    try std.testing.expectEqualStrings("new", formatAge(&buf, 30 * std.time.ms_per_s));
    try std.testing.expectEqualStrings("5m", formatAge(&buf, 5 * std.time.ms_per_min));
    try std.testing.expectEqualStrings("3h", formatAge(&buf, 3 * std.time.ms_per_hour));
    try std.testing.expectEqualStrings("9d", formatAge(&buf, 9 * std.time.ms_per_day + 3 * std.time.ms_per_hour));
}

test "verdictText: every kept reason explains itself, reusing the #276 wording" {
    try std.testing.expectEqualStrings(keepReasonText(.dirty), verdictText(.keep_dirty));
    try std.testing.expectEqualStrings(keepReasonText(.committed), verdictText(.keep_committed));
    try std.testing.expect(std.mem.indexOf(u8, verdictText(.keep_too_new), "retention") != null);
    try std.testing.expectEqualStrings("", verdictText(.remove));
}
