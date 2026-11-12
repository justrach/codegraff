//! Canonical worktree identity and the duplicate-owner preflight (#320).
//!
//! Two graff sessions started in different subdirectories of the same checkout
//! (or through a symlink) must resolve to ONE identity, while two separate
//! `git worktree add` checkouts must not collide. `git rev-parse --git-dir
//! --git-common-dir` answers both at once: the common dir is shared by a repo
//! and every worktree linked to it, so `git_dir == common_dir` means "the main
//! checkout" and anything else is a linked worktree whose git dir is already
//! unique per worktree. Both are resolved by git itself, so a symlinked or
//! nested cwd collapses onto the same string.
//!
//! What is deliberately NOT here: the durable lease registry. `ownerVerdict` is
//! the whole decision — given a record it says self / live-foreign / stale —
//! and it already honours #320's rule that a pid alone may never signal an
//! owner. Nothing writes records yet, so no root session is warned at startup;
//! that needs a registry file plus a call site in startup.zig.
//!
//! #413 supplied the missing half: `proc_identity` reads a pid's START
//! identity, so "is that pid still the process that recorded it" is now a
//! question the OS answers rather than one this file has to be handed.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const process_runner = @import("process_runner.zig");
const proc_identity = @import("proc_identity.zig");
const git_dirs = @import("git_dirs.zig");
const runCapped = process_runner.runCapped;
const ranOk = process_runner.ranOk;

pub const Identity = struct {
    /// Stable string two sessions can compare. Empty only when even the cwd
    /// fallback failed.
    id: []const u8 = "",
    kind: Kind = .not_git,

    pub const Kind = enum { not_git, main_checkout, linked_worktree };
};

/// Trim and drop a trailing slash so `/repo/.git` and `/repo/.git/` compare
/// equal. Returns a slice of the input.
fn normalizePath(p: []const u8) []const u8 {
    const t = std.mem.trim(u8, p, " \t\r\n");
    if (t.len <= 1) return t;
    return std.mem.trimEnd(u8, t, "/");
}

/// Pure half of the #320 identity: `git_dir`/`common_dir` are the `git rev-parse
/// --path-format=absolute --git-dir --git-common-dir` answers (empty when git
/// could not be asked), `fallback_path` the canonical cwd used outside a repo.
pub fn canonicalIdentity(git_dir: []const u8, common_dir: []const u8, fallback_path: []const u8) Identity {
    const g = normalizePath(git_dir);
    const c = normalizePath(common_dir);
    if (g.len == 0) return .{ .id = normalizePath(fallback_path), .kind = .not_git };
    // git_dir == common_dir is exactly "this is the repo's own checkout"; a
    // linked worktree's git dir is <common>/worktrees/<name>, already unique.
    if (c.len == 0 or std.mem.eql(u8, g, c)) return .{ .id = g, .kind = .main_checkout };
    return .{ .id = g, .kind = .linked_worktree };
}

/// One recorded root-session owner of a worktree identity. `start_id` is the
/// process START identity, not just the pid: after a crash the OS may hand the
/// same pid to something unrelated, and #320 requires that never look like an
/// owner. `proc_identity` produces the value and knows its units.
pub const Owner = struct {
    pid: i32 = 0,
    start_id: proc_identity.StartId = 0,
    session_id: []const u8 = "",
    identity: []const u8 = "",
    /// #469: the owner's last-known objective — the coordination payload a
    /// peer reads to decide whether its work overlaps. Empty when unknown.
    goal: []const u8 = "",
    last_seen_ms: i64 = 0,
    /// Last root-turn start/completion, not registry refresh. Zero means unknown.
    last_activity_ms: i64 = 0,
    activity: []const u8 = "connected",
    /// #700: the human title from `.session.json`. Empty on older records.
    title: []const u8 = "",
    /// #700: durable saved-session file base (slug). Empty on older records.
    session_base: []const u8 = "",
};

pub const OwnerVerdict = enum {
    /// This record is the running session asking.
    self,
    /// A record for a different worktree — never a conflict.
    other_worktree,
    /// Another root session is alive in MY worktree: the #320 warning case.
    live_foreign,
    /// The pid is alive but its identity could not be read, so we cannot prove
    /// it is NOT the recorded owner. Warned about like a live one (#413): the
    /// cost of a needless warning is a line of text, the cost of staying quiet
    /// is two sessions editing one tree.
    live_unverified,
    /// The owner exited (or its pid now belongs to something else).
    stale_dead,
    /// Not enough evidence to claim anyone owns it; treated as stale.
    stale_unverifiable,
};

/// The record for this process, ready to be written to a registry.
pub fn selfOwner(io: Io, identity: []const u8, session_id: []const u8, now_ms: i64) Owner {
    return .{
        .pid = proc_identity.selfPid(),
        .start_id = proc_identity.selfStartId(io),
        .session_id = session_id,
        .identity = identity,
        .last_seen_ms = now_ms,
    };
}

/// `live` is what the OS says about `rec.pid` right now (`proc_identity.probe`).
pub fn ownerVerdict(rec: Owner, my_identity: []const u8, my_pid: i32, live: proc_identity.Probe) OwnerVerdict {
    if (rec.identity.len == 0 or my_identity.len == 0) return .stale_unverifiable;
    if (!std.mem.eql(u8, rec.identity, my_identity)) return .other_worktree;
    // A record with no start identity can only be matched by pid, and pid alone
    // is precisely what #320 says must not signal an owner. Unlike a mutual
    // exclusion lock — where honouring a legacy record is the safe answer —
    // this one only prints a warning, so the false-positive is the harm.
    if (rec.start_id == 0) return .stale_unverifiable;
    const unverified = switch (live) {
        .gone => return .stale_dead,
        .id => |v| blk: {
            if (v != rec.start_id) return .stale_dead; // pid reuse, not the owner
            break :blk false;
        },
        .unknown => true,
    };
    if (rec.pid == my_pid) return .self;
    return if (unverified) .live_unverified else .live_foreign;
}

/// The #320 preflight: the first live foreign owner of MY worktree, if any.
/// Everything else — my own record, another worktree's, a crashed or pid-reused
/// one — is silent, so a stale registry can never block a startup.
/// `probes[i]` pairs with `records[i]`; a record past the end of `probes` was
/// never probed at all, which is no evidence of anything and so is skipped.
pub fn duplicateOwner(records: []const Owner, probes: []const proc_identity.Probe, my_identity: []const u8, my_pid: i32) ?Owner {
    for (records, 0..) |rec, i| {
        if (i >= probes.len) break;
        switch (ownerVerdict(rec, my_identity, my_pid, probes[i])) {
            .live_foreign, .live_unverified => return rec,
            else => {},
        }
    }
    return null;
}

/// Probe every record's pid once into caller storage; the slice it returns is
/// what `duplicateOwner` expects.
pub fn probeOwners(io: Io, records: []const Owner, out: []proc_identity.Probe) []const proc_identity.Probe {
    const n = @min(records.len, out.len);
    for (records[0..n], out[0..n]) |rec, *slot| slot.* = proc_identity.probe(io, rec.pid);
    return out[0..n];
}

pub fn duplicateOwnerWarning(arena: Allocator, rec: Owner, age_ms: i64) []const u8 {
    const mins = @divTrunc(if (age_ms > 0) age_ms else 0, std.time.ms_per_min);
    const goal = if (rec.goal.len > 0) std.fmt.allocPrint(arena, "\n  goal: {s}", .{rec.goal}) catch "" else "";
    return std.fmt.allocPrint(
        arena,
        "⚠ another graff session already owns this worktree\n  pid {d} · session {s} · active {d}m{s}\n  you would both be editing the same uncommitted tree — restart with -w for an isolated worktree, or continue knowing edits can collide\n",
        .{ rec.pid, if (rec.session_id.len > 0) rec.session_id else "unknown", mins, goal },
    ) catch "⚠ another graff session already owns this worktree\n";
}

/// Every git spawn behind an identity or common-dir question. Swappable so a
/// test can stand in a git that, like git < 2.31, rejects `--path-format`.
pub const RunGitFn = *const fn (gpa: Allocator, io: Io, argv: []const []const u8) anyerror!process_runner.CappedRun;
pub var run_git_hook: RunGitFn = &runGit;

fn runGit(gpa: Allocator, io: Io, argv: []const []const u8) anyerror!process_runner.CappedRun {
    return runCapped(gpa, io, argv, 8192, 8192, 15_000);
}

fn revParse(gpa: Allocator, io: Io, arena: Allocator, flag: []const u8) []const u8 {
    // --path-format=absolute so a nested cwd yields the same string as the repo
    // root. Old git without the flag just fails and we degrade to the cwd.
    const r = run_git_hook(gpa, io, &.{ "git", "rev-parse", "--path-format=absolute", flag }) catch return "";
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    if (!ranOk(r)) return "";
    return arena.dupe(u8, std.mem.trim(u8, r.stdout, " \t\r\n")) catch "";
}

/// `<main checkout>/.git`, shared by the repo and every worktree linked to it.
pub fn gitCommonDir(gpa: Allocator, io: Io, arena: Allocator) []const u8 {
    return revParse(gpa, io, arena, "--git-common-dir");
}

/// Same as `gitCommonDir`, but `git -C dir` so a worktree switch still hits
/// the shared `.git` of the repository.
pub fn gitCommonDirAt(gpa: Allocator, io: Io, arena: Allocator, dir: []const u8) []const u8 {
    if (dir.len == 0) return gitCommonDir(gpa, io, arena);
    return revParseAt(gpa, io, arena, dir, "--git-common-dir");
}

/// Physical path of `dir`; "." or empty is the process cwd, read with
/// `currentPath` (a `realPath` of "." can go stale after chdir, #721).
fn physical(io: Io, arena: Allocator, dir: []const u8) []const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = (if (dir.len == 0 or std.mem.eql(u8, dir, "."))
        std.process.currentPath(io, &buf)
    else
        Io.Dir.cwd().realPathFile(io, dir, &buf)) catch return "";
    return arena.dupe(u8, buf[0..n]) catch "";
}

/// `gitCommonDirAt`, answered in-process when git_dirs can; one spawn only
/// when it defers. Empty when neither finds a repository.
pub fn commonDirAt(gpa: Allocator, io: Io, arena: Allocator, dir: []const u8) []const u8 {
    const start = physical(io, arena, dir);
    if (start.len > 0) switch (git_dirs.resolve(io, arena, start)) {
        .not_git => return "",
        .found => |d| return d.common_dir,
        .fallback => {},
    };
    return gitCommonDirAt(gpa, io, arena, if (dir.len > 0) dir else ".");
}

fn revParseAt(gpa: Allocator, io: Io, arena: Allocator, dir: []const u8, flag: []const u8) []const u8 {
    const r = run_git_hook(gpa, io, &.{ "git", "-C", dir, "rev-parse", "--path-format=absolute", flag }) catch return "";
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    if (!ranOk(r)) return "";
    return arena.dupe(u8, std.mem.trim(u8, r.stdout, " \t\r\n")) catch "";
}

/// git's two answers; both empty when git found no repository (or failed).
pub const RevParse = struct { git_dir: []const u8 = "", common_dir: []const u8 = "" };
pub const RevParseFn = *const fn (gpa: Allocator, io: Io, arena: Allocator, dir: ?[]const u8) RevParse;

/// The one place identity spawns git. Swappable so tests can count or forbid
/// it; `rev_parse_spawns` counts real spawns.
pub var rev_parse_hook: RevParseFn = &spawnRevParse;
pub var rev_parse_spawns: std.atomic.Value(u32) = .init(0);

/// ONE `git rev-parse --git-dir --git-common-dir`. A path with a newline in it
/// cannot be split from the pair, so it takes the old one-flag-per-spawn path.
fn spawnRevParse(gpa: Allocator, io: Io, arena: Allocator, dir: ?[]const u8) RevParse {
    _ = rev_parse_spawns.fetchAdd(1, .monotonic);
    const tail = [_][]const u8{ "rev-parse", "--path-format=absolute", "--git-dir", "--git-common-dir" };
    const r = (if (dir) |d| run_git_hook(gpa, io, &([_][]const u8{ "git", "-C", d } ++ tail)) else run_git_hook(gpa, io, &([_][]const u8{"git"} ++ tail))) catch return .{};
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    if (!ranOk(r)) return .{};
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, r.stdout, "\r\n"), '\n');
    const first = lines.next() orelse "";
    const second = lines.next();
    if (second == null or lines.next() != null) {
        _ = rev_parse_spawns.fetchAdd(2, .monotonic);
        if (dir) |d| return .{ .git_dir = revParseAt(gpa, io, arena, d, "--git-dir"), .common_dir = revParseAt(gpa, io, arena, d, "--git-common-dir") };
        return .{ .git_dir = revParse(gpa, io, arena, "--git-dir"), .common_dir = revParse(gpa, io, arena, "--git-common-dir") };
    }
    const trim = " \t\r\n";
    return .{
        .git_dir = arena.dupe(u8, std.mem.trim(u8, first, trim)) catch "",
        .common_dir = arena.dupe(u8, std.mem.trim(u8, second.?, trim)) catch "",
    };
}

// Memo of git's answer for one cwd (getcwd, what git itself sees). In-process
// answers are cheap and always recomputed; only a spawn that found a
// repository is cached, and only consulted while git_dirs still defers.
var memo_lock: std.atomic.Value(bool) = .init(false);
var memo_key: [4096]u8 = undefined;
var memo_key_len: usize = 0;
var memo_id: [4096]u8 = undefined;
var memo_id_len: usize = 0;
var memo_kind: Identity.Kind = .not_git;

fn memoLock() void {
    while (memo_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

/// Forget the memoized identity. Every chdir of the process calls this.
pub fn invalidateIdentity() void {
    memoLock();
    defer memo_lock.store(false, .release);
    memo_key_len = 0;
}

fn memoGet(arena: Allocator, key: []const u8) ?Identity {
    memoLock();
    defer memo_lock.store(false, .release);
    if (memo_key_len == 0 or !std.mem.eql(u8, memo_key[0..memo_key_len], key)) return null;
    return .{ .id = arena.dupe(u8, memo_id[0..memo_id_len]) catch return null, .kind = memo_kind };
}

fn memoPut(key: []const u8, id: Identity) void {
    if (key.len == 0 or key.len > memo_key.len or id.id.len > memo_id.len) return;
    memoLock();
    defer memo_lock.store(false, .release);
    @memcpy(memo_key[0..key.len], key);
    memo_key_len = key.len;
    @memcpy(memo_id[0..id.id.len], id.id);
    memo_id_len = id.id.len;
    memo_kind = id.kind;
}

/// Live canonical identity for this process's working directory. Zero git
/// spawns for ordinary layouts (git_dirs.zig); otherwise one, memoized.
pub fn currentIdentity(gpa: Allocator, io: Io, arena: Allocator) Identity {
    const here = physical(io, arena, ".");
    if (here.len > 0) switch (git_dirs.resolve(io, arena, here)) {
        .not_git => return canonicalIdentity("", "", here),
        .found => |d| return canonicalIdentity(d.git_dir, d.common_dir, here),
        .fallback => if (memoGet(arena, here)) |hit| return hit,
    };
    const rp = rev_parse_hook(gpa, io, arena, null);
    const id = canonicalIdentity(rp.git_dir, rp.common_dir, here);
    // A spawn that found nothing (old git, a config git rejects, a timeout)
    // is asked again next call, so a later `git init` here is seen (ADR 0118).
    if (rp.git_dir.len > 0) memoPut(here, id);
    return id;
}

/// `currentIdentity` after the cwd may have changed under the same path.
pub fn freshIdentity(gpa: Allocator, io: Io, arena: Allocator) Identity {
    invalidateIdentity();
    return currentIdentity(gpa, io, arena);
}

/// Identity of an explicit path (`git -C` / `cd` target), not the caller cwd.
pub fn identityAt(gpa: Allocator, io: Io, arena: Allocator, path: []const u8) Identity {
    if (path.len == 0) return .{};
    const phys = physical(io, arena, path);
    const real: ?[]const u8 = if (phys.len > 0) phys else null;
    const cwd = real orelse path;
    if (real) |start| switch (git_dirs.resolve(io, arena, start)) {
        .not_git => return canonicalIdentity("", "", cwd),
        .found => |d| return canonicalIdentity(d.git_dir, d.common_dir, cwd),
        .fallback => {},
    };
    const rp = rev_parse_hook(gpa, io, arena, path);
    return canonicalIdentity(rp.git_dir, rp.common_dir, cwd);
}

pub fn identityLine(arena: Allocator, id: Identity) []const u8 {
    const kind = switch (id.kind) {
        .main_checkout => "main checkout",
        .linked_worktree => "linked worktree",
        .not_git => "not a git repository",
    };
    return std.fmt.allocPrint(arena, "identity: {s} ({s})", .{ if (id.id.len > 0) id.id else "unknown", kind }) catch "identity: unknown";
}

test "canonicalIdentity: one id per worktree, distinct across linked worktrees (#320)" {
    // Subdirectory / symlinked cwd: git resolves both to the same git dir, so
    // the identity is the same string.
    const main_a = canonicalIdentity("/repo/.git", "/repo/.git", "/repo");
    const main_b = canonicalIdentity("/repo/.git/", "/repo/.git", "/repo/src/deep");
    try std.testing.expectEqual(Identity.Kind.main_checkout, main_a.kind);
    try std.testing.expectEqualStrings(main_a.id, main_b.id);

    // A linked worktree has its own git dir, so it never collides with main…
    const linked = canonicalIdentity("/repo/.git/worktrees/wt1", "/repo/.git", "/elsewhere/wt1");
    try std.testing.expectEqual(Identity.Kind.linked_worktree, linked.kind);
    try std.testing.expect(!std.mem.eql(u8, linked.id, main_a.id));
    // …nor with a sibling worktree of the same repo.
    const sibling = canonicalIdentity("/repo/.git/worktrees/wt2", "/repo/.git", "/elsewhere/wt2");
    try std.testing.expect(!std.mem.eql(u8, linked.id, sibling.id));

    // Outside a repo we still have an identity: the canonical cwd.
    const loose = canonicalIdentity("", "", "/tmp/scratch/");
    try std.testing.expectEqual(Identity.Kind.not_git, loose.kind);
    try std.testing.expectEqualStrings("/tmp/scratch", loose.id);
}

test "ownerVerdict: only a verified live process in MY worktree is an owner (#320)" {
    const me = "/repo/.git";
    const rec: Owner = .{ .pid = 4242, .start_id = 777, .session_id = "s-1", .identity = me };

    try std.testing.expectEqual(OwnerVerdict.live_foreign, ownerVerdict(rec, me, 99, .{ .id = 777 }));
    try std.testing.expectEqual(OwnerVerdict.self, ownerVerdict(rec, me, 4242, .{ .id = 777 }));
    // Separate git worktrees do not conflict.
    try std.testing.expectEqual(OwnerVerdict.other_worktree, ownerVerdict(rec, "/repo/.git/worktrees/wt1", 99, .{ .id = 777 }));
    // Crashed owner: the pid is simply gone.
    try std.testing.expectEqual(OwnerVerdict.stale_dead, ownerVerdict(rec, me, 99, .gone));
    // PID reuse: the pid is live but it is a different process.
    try std.testing.expectEqual(OwnerVerdict.stale_dead, ownerVerdict(rec, me, 99, .{ .id = 778 }));
    // No start identity recorded — unverifiable is stale, never a warning.
    var no_start = rec;
    no_start.start_id = 0;
    try std.testing.expectEqual(OwnerVerdict.stale_unverifiable, ownerVerdict(no_start, me, 99, .{ .id = 777 }));
}

test "ownerVerdict: a pid we cannot identify is assumed to be the owner (#413)" {
    const me = "/repo/.git";
    const rec: Owner = .{ .pid = 4242, .start_id = 777, .session_id = "s-1", .identity = me };
    // An unreadable identity is not evidence of death: warn rather than treat
    // a possibly live session as stale.
    try std.testing.expectEqual(OwnerVerdict.live_unverified, ownerVerdict(rec, me, 99, .unknown));
    // …but it is still not somebody else when the pid is mine.
    try std.testing.expectEqual(OwnerVerdict.self, ownerVerdict(rec, me, 4242, .unknown));
}

test "duplicateOwner: picks the live foreign session and ignores stale records (#320)" {
    const me = "/repo/.git";
    const records = [_]Owner{
        .{ .pid = 1, .start_id = 10, .session_id = "dead", .identity = me },
        .{ .pid = 2, .start_id = 20, .session_id = "other-wt", .identity = "/repo/.git/worktrees/wt1" },
        .{ .pid = 3, .start_id = 30, .session_id = "mine", .identity = me },
        .{ .pid = 4, .start_id = 40, .session_id = "live", .identity = me },
    };
    const live = [_]proc_identity.Probe{ .gone, .{ .id = 20 }, .{ .id = 30 }, .{ .id = 40 } };
    const found = duplicateOwner(&records, &live, me, 3) orelse return error.ExpectedDuplicate;
    try std.testing.expectEqualStrings("live", found.session_id);
    try std.testing.expectEqual(@as(i32, 4), found.pid);

    // Alone in the worktree: only my own record matches, so no warning.
    const solo = [_]Owner{records[2]};
    try std.testing.expect(duplicateOwner(&solo, &.{.{ .id = 30 }}, me, 3) == null);
    // A registry we cannot read at all must not manufacture an owner.
    try std.testing.expect(duplicateOwner(&records, &.{}, me, 3) == null);
}

test "selfOwner + probeOwners: this process records and verifies as itself (#413)" {
    const io = std.testing.io;
    const me = "/repo/.git";
    const mine = selfOwner(io, me, "s-self", 1234);
    try std.testing.expect(mine.pid > 0);

    var probes: [1]proc_identity.Probe = undefined;
    const live = probeOwners(io, &.{mine}, &probes);
    try std.testing.expectEqual(@as(usize, 1), live.len);
    // My own live record is `self`, never a duplicate owner…
    try std.testing.expectEqual(OwnerVerdict.self, ownerVerdict(mine, me, mine.pid, live[0]));
    try std.testing.expect(duplicateOwner(&.{mine}, live, me, mine.pid) == null);

    // …and a record claiming my pid from a process that no longer exists is
    // stale, which is the whole point: a recycled pid cannot hold a lease.
    if (mine.start_id != 0) {
        var recycled = mine;
        recycled.start_id +%= 1;
        try std.testing.expectEqual(OwnerVerdict.stale_dead, ownerVerdict(recycled, me, mine.pid, live[0]));
    }
}

test "duplicateOwnerWarning: names the pid, the session and an escape hatch (#320)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = duplicateOwnerWarning(arena_state.allocator(), .{ .pid = 4242, .start_id = 1, .session_id = "s-1" }, 5 * std.time.ms_per_min);
    try std.testing.expect(std.mem.indexOf(u8, text, "4242") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "s-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "5m") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "-w") != null);
}

test "identityLine: says which kind of checkout, and stays honest when unknown" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect(std.mem.indexOf(u8, identityLine(a, .{ .id = "/repo/.git", .kind = .main_checkout }), "main checkout") != null);
    try std.testing.expect(std.mem.indexOf(u8, identityLine(a, .{ .id = "/repo/.git/worktrees/w", .kind = .linked_worktree }), "linked worktree") != null);
    try std.testing.expect(std.mem.indexOf(u8, identityLine(a, .{}), "unknown") != null);
}

fn initBareRepo(gpa: Allocator, io: Io, path: []const u8) !void {
    const r = try runCapped(gpa, io, &.{ "git", "init", "-q", path }, 4096, 4096, 15_000);
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    if (!ranOk(r)) return error.GitInitFailed;
}

test "#851 identityAt distinguishes isolated checkouts and matches a subdirectory" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const path_a = try std.fmt.allocPrint(a, "{s}/a", .{root});
    const path_b = try std.fmt.allocPrint(a, "{s}/b", .{root});
    const path_sub = try std.fmt.allocPrint(a, "{s}/a/src", .{root});
    try tmp.dir.createDirPath(io, "a/src");
    try tmp.dir.createDirPath(io, "b");
    try initBareRepo(gpa, io, path_a);
    try initBareRepo(gpa, io, path_b);
    const id_a = identityAt(gpa, io, a, path_a);
    const id_b = identityAt(gpa, io, a, path_b);
    const id_sub = identityAt(gpa, io, a, path_sub);
    try std.testing.expect(id_a.id.len > 0);
    try std.testing.expect(id_b.id.len > 0);
    try std.testing.expect(!std.mem.eql(u8, id_a.id, id_b.id));
    try std.testing.expectEqualStrings(id_a.id, id_sub.id);
}
