//! One claim ledger per Git repository, not per worktree cwd (#1092).
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const process_runner = @import("process_runner.zig");
const runCapped = process_runner.runCapped;
const ranOk = process_runner.ranOk;

pub const persist_rel = ".graff/artifact-claims.json";

/// Main checkout: `.graff/artifact-claims.json` (same bytes as before #1092).
/// Linked worktree: `gitdir:` pointer → main checkout `.graff`.
pub fn canonicalFile(arena: Allocator, io: Io, cwd: []const u8) ?[]const u8 {
    if (cwd.len == 0) return persist_rel;
    const git_here = std.fs.path.join(arena, &.{ cwd, ".git" }) catch return persist_rel;
    const st = Io.Dir.cwd().statFile(io, git_here, .{}) catch {
        if (std.mem.eql(u8, cwd, ".")) return persist_rel;
        return std.fs.path.join(arena, &.{ cwd, persist_rel }) catch persist_rel;
    };
    if (st.kind != .file) {
        if (std.mem.eql(u8, cwd, ".")) return persist_rel;
        return std.fs.path.join(arena, &.{ cwd, persist_rel }) catch persist_rel;
    }
    {
        if (Io.Dir.cwd().readFileAlloc(io, git_here, arena, .limited(4096))) |text| {
            const line = std.mem.trim(u8, text, " \t\r\n");
            const prefix = "gitdir:";
            if (std.mem.startsWith(u8, line, prefix)) {
                const raw = std.mem.trim(u8, line[prefix.len..], " \t");
                const gitdir = if (std.fs.path.isAbsolute(raw))
                    raw
                else
                    (std.fs.path.resolve(arena, &.{ cwd, raw }) catch return persist_rel);
                const marker = std.fs.path.join(arena, &.{ gitdir, "commondir" }) catch return persist_rel;
                const common = blk: {
                    if (Io.Dir.cwd().readFileAlloc(io, marker, arena, .limited(256))) |cd| {
                        const rel = std.mem.trim(u8, cd, " \t\r\n");
                        if (rel.len == 0) break :blk gitdir;
                        if (std.fs.path.isAbsolute(rel)) break :blk rel;
                        break :blk std.fs.path.resolve(arena, &.{ gitdir, rel }) catch gitdir;
                    } else |_| break :blk gitdir;
                };
                const root = std.fs.path.dirname(common) orelse return persist_rel;
                return std.fs.path.join(arena, &.{ root, persist_rel }) catch persist_rel;
            }
        } else |_| {}
    }
    if (std.mem.eql(u8, cwd, ".")) return persist_rel;
    return std.fs.path.join(arena, &.{ cwd, persist_rel }) catch persist_rel;
}

pub fn legacyFile(arena: Allocator, cwd: []const u8) ?[]const u8 {
    if (cwd.len == 0) return null;
    return std.fs.path.join(arena, &.{ cwd, persist_rel }) catch null;
}

pub fn samePath(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "canonicalFile is identical across linked worktrees of one repo" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(tmp_root);
    const root = try std.fmt.allocPrint(a, "{s}/repo-a", .{tmp_root});
    defer a.free(root);
    try Io.Dir.cwd().createDirPath(io, root);
    try git(io, a, &.{ "init", "-q", "-b", "main", root });
    try git(io, a, &.{ "-C", root, "config", "user.email", "t@t" });
    try git(io, a, &.{ "-C", root, "config", "user.name", "t" });
    const tracked = try std.fs.path.join(a, &.{ root, "f" });
    defer a.free(tracked);
    {
        const f = try Io.Dir.cwd().createFile(io, tracked, .{});
        defer f.close(io);
        try f.writePositionalAll(io, "x\n", 0);
    }
    try git(io, a, &.{ "-C", root, "add", "f" });
    try git(io, a, &.{ "-C", root, "commit", "-m", "i" });
    const other = try std.fmt.allocPrint(a, "{s}/repo-b", .{tmp_root});
    defer a.free(other);
    try git(io, a, &.{ "-C", root, "worktree", "add", "--detach", other });
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const pa = canonicalFile(ar, io, root) orelse return error.TestUnexpectedResult;
    const pb = canonicalFile(ar, io, other) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(pa, pb);
    try std.testing.expect(std.mem.endsWith(u8, pa, persist_rel));
    const other_repo = try std.fmt.allocPrint(a, "{s}/other", .{tmp_root});
    defer a.free(other_repo);
    try Io.Dir.cwd().createDirPath(io, other_repo);
    try git(io, a, &.{ "init", "-q", "-b", "main", other_repo });
    const pc = canonicalFile(ar, io, other_repo) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.eql(u8, pa, pc));
}

test "claim follows a worktree switch and does not shadow another repo" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const claims = @import("artifact_claim.zig");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(tmp_root);
    const root = try std.fmt.allocPrint(a, "{s}/wt-main", .{tmp_root});
    defer a.free(root);
    try Io.Dir.cwd().createDirPath(io, root);
    try git(io, a, &.{ "init", "-q", "-b", "main", root });
    try git(io, a, &.{ "-C", root, "config", "user.email", "t@t" });
    try git(io, a, &.{ "-C", root, "config", "user.name", "t" });
    const tracked = try std.fs.path.join(a, &.{ root, "f" });
    defer a.free(tracked);
    {
        const f = try Io.Dir.cwd().createFile(io, tracked, .{});
        defer f.close(io);
        try f.writePositionalAll(io, "x\n", 0);
    }
    try git(io, a, &.{ "-C", root, "add", "f" });
    try git(io, a, &.{ "-C", root, "commit", "-m", "i" });
    const linked = try std.fmt.allocPrint(a, "{s}/wt-link", .{tmp_root});
    defer a.free(linked);
    try git(io, a, &.{ "-C", root, "worktree", "add", "--detach", linked });
    const other = try std.fmt.allocPrint(a, "{s}/wt-other", .{tmp_root});
    defer a.free(other);
    try Io.Dir.cwd().createDirPath(io, other);
    try git(io, a, &.{ "init", "-q", "-b", "main", other });
    try git(io, a, &.{ "-C", other, "config", "user.email", "t@t" });
    try git(io, a, &.{ "-C", other, "config", "user.name", "t" });

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    claims.resetForTest();
    defer claims.resetForTest();
    claims.setTestResolveCwd(true);
    claims.setTestOwner(.{ .session = "s-a", .pid = 11, .start_id = 1 });
    claims.setTestOwnerLive(true);
    const claimed = try claims.handleToolIn(ar, io, "claim", "issue", "1092", "", root, null);
    try std.testing.expect(!claimed.is_error);
    const mine = try claims.handleToolIn(ar, io, "status", "issue", "1092", "", linked, null);
    try std.testing.expect(std.mem.indexOf(u8, mine.text, "mine") != null);
    claims.setTestOwner(.{ .session = "s-b", .pid = 12, .start_id = 2 });
    const foreign = try claims.handleToolIn(ar, io, "status", "issue", "1092", "", linked, null);
    try std.testing.expect(std.mem.indexOf(u8, foreign.text, "foreign") != null);
    const blocked = claims.gateCommandIn(ar, io, "gh issue comment 1092 --body x", "1092", linked);
    try std.testing.expect(blocked != null);
    claims.setTestOwner(.{ .session = "s-a", .pid = 11, .start_id = 1 });
    const released = try claims.handleToolIn(ar, io, "release", "issue", "1092", "", linked, null);
    try std.testing.expect(!released.is_error);
    const free_a = try claims.handleToolIn(ar, io, "status", "issue", "1092", "", root, null);
    try std.testing.expectEqualStrings("no claim", free_a.text);
    const free_b = try claims.handleToolIn(ar, io, "status", "issue", "1092", "", linked, null);
    try std.testing.expectEqualStrings("no claim", free_b.text);
    try std.testing.expect(claims.gateCommandIn(ar, io, "gh issue comment 1092 --body x", "1092", root) == null);
    const other_claim = try claims.handleToolIn(ar, io, "claim", "issue", "1092", "", other, null);
    try std.testing.expect(!other_claim.is_error);
    const still_free = try claims.handleToolIn(ar, io, "status", "issue", "1092", "", root, null);
    try std.testing.expectEqualStrings("no claim", still_free.text);
}

fn git(io: Io, a: Allocator, argv: []const []const u8) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(a);
    try args.append(a, "git");
    try args.appendSlice(a, argv);
    const r = try runCapped(a, io, args.items, 4096, 4096, 15_000);
    defer {
        a.free(r.stdout);
        a.free(r.stderr);
    }
    if (!ranOk(r)) {
        std.debug.print("git {s} failed: {s}\n", .{ argv[0], r.stderr });
        return error.TestUnexpectedResult;
    }
}
