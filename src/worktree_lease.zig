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

fn revParse(gpa: Allocator, io: Io, arena: Allocator, flag: []const u8) []const u8 {
    // --path-format=absolute so a nested cwd yields the same string as the repo
    // root. Old git without the flag just fails and we degrade to the cwd.
    const r = runCapped(gpa, io, &.{ "git", "rev-parse", "--path-format=absolute", flag }, 8192, 8192, 15_000) catch return "";
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

/// Live canonical identity for this process's working directory.
pub fn currentIdentity(gpa: Allocator, io: Io, arena: Allocator) Identity {
    const git_dir = revParse(gpa, io, arena, "--git-dir");
    const common = gitCommonDir(gpa, io, arena);
    var buf: [4096]u8 = undefined;
    const cwd = blk: {
        const n = Io.Dir.cwd().realPathFile(io, ".", &buf) catch break :blk "";
        break :blk arena.dupe(u8, buf[0..n]) catch "";
    };
    return canonicalIdentity(git_dir, common, cwd);
}

const lease_rel = ".graff/owner.json";

pub fn loadOwner(io: Io, arena: Allocator) ?Owner {
    const body = Io.Dir.cwd().readFileAlloc(io, lease_rel, arena, .limited(4096)) catch return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    const o = v.object;
    const pid = o.get("pid") orelse return null;
    if (pid != .integer) return null;
    return .{
        .pid = @intCast(pid.integer),
        .start_id = if (o.get("start_id")) |s| (if (s == .integer) @intCast(s.integer) else 0) else 0,
        .session_id = if (o.get("session_id")) |s| (if (s == .string) s.string else "") else "",
        .identity = if (o.get("identity")) |s| (if (s == .string) s.string else "") else "",
        .goal = if (o.get("goal")) |s| (if (s == .string) s.string else "") else "",
        .last_seen_ms = if (o.get("last_seen_ms")) |s| (if (s == .integer) s.integer else 0) else 0,
    };
}

pub fn saveOwner(io: Io, arena: Allocator, rec: Owner) void {
    Io.Dir.cwd().createDirPath(io, ".graff") catch {};
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.write(.{
        .pid = rec.pid,
        .start_id = rec.start_id,
        .session_id = rec.session_id,
        .identity = rec.identity,
        .goal = rec.goal,
        .last_seen_ms = rec.last_seen_ms,
    }) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = lease_rel, .data = aw.writer.buffered(), .flags = .{ .read = true } }) catch {};
}

pub fn preflight(gpa: Allocator, io: Io, arena: Allocator, session_id: []const u8, now_ms: i64) ?[]const u8 {
    const id = currentIdentity(gpa, io, arena);
    if (id.id.len == 0) return null;
    const me = selfOwner(io, id.id, session_id, now_ms);
    if (loadOwner(io, arena)) |rec| {
        const live = proc_identity.probe(io, rec.pid);
        switch (ownerVerdict(rec, id.id, me.pid, live)) {
            .live_foreign, .live_unverified => {
                saveOwner(io, arena, me);
                return duplicateOwnerWarning(arena, rec, now_ms - rec.last_seen_ms);
            },
            else => {},
        }
    }
    saveOwner(io, arena, me);
    return null;
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

test "#320: preflight records this process and is silent when we are the owner" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var orig = try Io.Dir.cwd().openDir(io, ".", .{});
    defer orig.close(io);
    defer _ = std.posix.system.fchdir(orig.handle);
    if (std.posix.system.fchdir(tmp.dir.handle) != 0) return error.ChdirFailed;
    try std.testing.expect(preflight(gpa, io, arena, "sess-a", 1_000) == null);
    try std.testing.expect(preflight(gpa, io, arena, "sess-a", 2_000) == null);
    try std.testing.expect(loadOwner(io, arena) != null);
}
