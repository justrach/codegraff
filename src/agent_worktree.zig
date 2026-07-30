//! Per-agent git-worktree isolation for fanned-out subagents.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const process_runner = @import("process_runner.zig");
const runCapped = process_runner.runCapped;
const ranOk = process_runner.ranOk;

pub const AgentWorktree = struct { path: []const u8, branch: []const u8, base: []const u8 = "" };
pub const AgentWorktreeError = error{ NotAGitRepo, CreateFailed };
pub const AgentWorktreeOutcome = struct { kept: bool, reason: KeepReason = .removed };

pub const KeepReason = enum { removed, dirty, committed, unverifiable };

/// Pure removal decision. `status_ok`/`porcelain` are the `git status --porcelain`
/// result in the worktree; `head` is `git rev-parse HEAD` there (empty when it
/// could not be read); `base` is the commit the worktree was created at (empty
/// when unknown). Removal requires positive proof on every axis - anything we
/// could not establish keeps the worktree, because `git branch -D` on a branch
/// whose commits nothing else references destroys the child's work silently.
pub fn worktreeKeepReason(status_ok: bool, porcelain: []const u8, base: []const u8, head: []const u8) KeepReason {
    if (!status_ok) return .unverifiable;
    if (isWorktreeStatusDirty(porcelain)) return .dirty;
    if (base.len == 0 or head.len == 0) return .unverifiable;
    if (!std.mem.eql(u8, base, head)) return .committed;
    return .removed;
}

pub fn keepReasonText(reason: KeepReason) []const u8 {
    return switch (reason) {
        .dirty => "has changes",
        .committed => "has commits that exist ONLY on this branch - merge or cherry-pick them, nothing else references them",
        .unverifiable => "could not verify it is safe to remove",
        .removed => "",
    };
}

pub fn isolationFailureText(err: anyerror) []const u8 {
    return switch (err) {
        error.NotAGitRepo => "isolation:\"worktree\" requested but this isn't a git repository (or `git` isn't on PATH) — worktrees need a git repo; drop isolation, or set isolation_fallback:true to run in the shared working tree instead",
        error.CreateFailed => "isolation:\"worktree\" requested but `git worktree add` failed (dirty HEAD, a name collision, or a git error) — set isolation_fallback:true to run in the shared working tree instead, or retry",
        else => "isolation:\"worktree\" requested but setup failed — set isolation_fallback:true to run in the shared working tree instead, or retry",
    };
}

pub fn agentWorktreeNames(arena: Allocator, sub_id: []const u8, nonce: []const u8) !AgentWorktree {
    return .{
        .path = try std.fmt.allocPrint(arena, ".graff/worktrees/agent-{s}-{s}", .{ sub_id, nonce }),
        .branch = try std.fmt.allocPrint(arena, "graff/agents/{s}-{s}", .{ sub_id, nonce }),
    };
}

pub fn agentWorktreeCreate(gpa: Allocator, io: Io, arena: Allocator, sub_id: []const u8) (AgentWorktreeError || Allocator.Error)!AgentWorktree {
    const probe = runCapped(gpa, io, &.{ "git", "rev-parse", "--is-inside-work-tree" }, 4096, 4096, 15_000) catch return error.NotAGitRepo;
    defer {
        gpa.free(probe.stdout);
        gpa.free(probe.stderr);
    }
    if (!ranOk(probe)) return error.NotAGitRepo;

    var raw: [4]u8 = undefined;
    io.random(&raw);
    const nonce = std.fmt.bytesToHex(raw, .lower);
    const names = try agentWorktreeNames(arena, sub_id, &nonce);
    const add = runCapped(gpa, io, &.{ "git", "worktree", "add", names.path, "-b", names.branch }, 8192, 8192, 60_000) catch return error.CreateFailed;
    defer {
        gpa.free(add.stdout);
        gpa.free(add.stderr);
    }
    if (!ranOk(add)) return error.CreateFailed;

    var base: []const u8 = "";
    if (runCapped(gpa, io, &.{ "git", "-C", names.path, "rev-parse", "HEAD" }, 4096, 4096, 15_000)) |r| {
        defer {
            gpa.free(r.stdout);
            gpa.free(r.stderr);
        }
        if (ranOk(r)) base = try arena.dupe(u8, std.mem.trim(u8, r.stdout, " \t\r\n"));
    } else |_| {}

    var buf: [4096]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(io, names.path, &buf) catch return .{ .path = names.path, .branch = names.branch, .base = base };
    return .{ .path = try arena.dupe(u8, buf[0..n]), .branch = names.branch, .base = base };
}

pub fn isWorktreeStatusDirty(porcelain: []const u8) bool {
    return std.mem.trim(u8, porcelain, " \t\r\n").len > 0;
}

pub fn agentWorktreeFinish(gpa: Allocator, io: Io, wt: AgentWorktree) AgentWorktreeOutcome {
    const st = runCapped(gpa, io, &.{ "git", "-C", wt.path, "status", "--porcelain" }, 1 << 16, 8192, 30_000) catch return .{ .kept = true, .reason = .unverifiable };
    defer {
        gpa.free(st.stdout);
        gpa.free(st.stderr);
    }

    var head: []const u8 = "";
    var head_buf: [4096]u8 = undefined;
    var head_len: usize = 0;
    if (runCapped(gpa, io, &.{ "git", "-C", wt.path, "rev-parse", "HEAD" }, 4096, 4096, 15_000)) |r| {
        defer {
            gpa.free(r.stdout);
            gpa.free(r.stderr);
        }
        if (ranOk(r)) {
            const trimmed = std.mem.trim(u8, r.stdout, " \t\r\n");
            head_len = @min(trimmed.len, head_buf.len);
            @memcpy(head_buf[0..head_len], trimmed[0..head_len]);
            head = head_buf[0..head_len];
        }
    } else |_| {}

    const reason = worktreeKeepReason(ranOk(st), st.stdout, wt.base, head);
    if (reason != .removed) return .{ .kept = true, .reason = reason };

    if (runCapped(gpa, io, &.{ "git", "worktree", "remove", wt.path }, 8192, 8192, 30_000)) |r| {
        defer {
            gpa.free(r.stdout);
            gpa.free(r.stderr);
        }
        if (!ranOk(r)) return .{ .kept = true, .reason = .unverifiable };
    } else |_| return .{ .kept = true, .reason = .unverifiable };

    if (runCapped(gpa, io, &.{ "git", "branch", "-D", wt.branch }, 8192, 8192, 30_000)) |r| {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    } else |_| {}
    return .{ .kept = false, .reason = .removed };
}

test "agentWorktreeNames: unique path/branch per nonce, never collide across repeated spawns (#276)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const first = try agentWorktreeNames(a, "sa-001-dead", "aa11bb22");
    try std.testing.expectEqualStrings(".graff/worktrees/agent-sa-001-dead-aa11bb22", first.path);
    try std.testing.expectEqualStrings("graff/agents/sa-001-dead-aa11bb22", first.branch);

    const second = try agentWorktreeNames(a, "sa-001-dead", "cc33dd44");
    try std.testing.expect(!std.mem.eql(u8, first.path, second.path));
    try std.testing.expect(!std.mem.eql(u8, first.branch, second.branch));
}

test "isWorktreeStatusDirty: clean drives auto-cleanup, tracked or untracked changes drive retention (#276)" {
    try std.testing.expect(!isWorktreeStatusDirty(""));
    try std.testing.expect(!isWorktreeStatusDirty("\n  \n"));
    try std.testing.expect(isWorktreeStatusDirty(" M src/foo.zig\n"));
    try std.testing.expect(isWorktreeStatusDirty("?? new_file.zig\n"));
}

test "isolationFailureText: friendly, distinct messages for the non-git and create-failed error paths (#276)" {
    const not_git = isolationFailureText(error.NotAGitRepo);
    try std.testing.expect(std.mem.indexOf(u8, not_git, "isn't a git repository") != null);
    try std.testing.expect(std.mem.indexOf(u8, not_git, "isolation_fallback") != null);

    const create_failed = isolationFailureText(error.CreateFailed);
    try std.testing.expect(std.mem.indexOf(u8, create_failed, "git worktree add") != null);
    try std.testing.expect(std.mem.indexOf(u8, create_failed, "isolation_fallback") != null);
    try std.testing.expect(!std.mem.eql(u8, not_git, create_failed));
}

test "worktreeKeepReason: committed work is never removable, and every unproven axis keeps the worktree" {
    try std.testing.expectEqual(KeepReason.removed, worktreeKeepReason(true, "", "abc123", "abc123"));
    try std.testing.expectEqual(KeepReason.dirty, worktreeKeepReason(true, " M src/foo.zig\n", "abc123", "abc123"));
    try std.testing.expectEqual(KeepReason.dirty, worktreeKeepReason(true, "?? new.zig\n", "abc123", "abc123"));
    try std.testing.expectEqual(KeepReason.committed, worktreeKeepReason(true, "", "abc123", "def456"));
    try std.testing.expectEqual(KeepReason.committed, worktreeKeepReason(true, "\n  \n", "abc123", "def456"));
    try std.testing.expectEqual(KeepReason.unverifiable, worktreeKeepReason(false, "", "abc123", "abc123"));
    try std.testing.expectEqual(KeepReason.unverifiable, worktreeKeepReason(true, "", "", "def456"));
    try std.testing.expectEqual(KeepReason.unverifiable, worktreeKeepReason(true, "", "abc123", ""));
}

test "keepReasonText: each kept reason names its cause, and .dirty keeps its historical wording" {
    try std.testing.expectEqualStrings("has changes", keepReasonText(.dirty));
    const committed = keepReasonText(.committed);
    try std.testing.expect(std.mem.indexOf(u8, committed, "commits") != null);
    try std.testing.expect(std.mem.indexOf(u8, committed, "cherry-pick") != null);
    try std.testing.expect(!std.mem.eql(u8, keepReasonText(.committed), keepReasonText(.unverifiable)));
    try std.testing.expect(!std.mem.eql(u8, keepReasonText(.unverifiable), keepReasonText(.dirty)));
    try std.testing.expect(!std.mem.eql(u8, keepReasonText(.committed), keepReasonText(.dirty)));
}
