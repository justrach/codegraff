//! A PR command whose target could not be looked up (#1340, #1344).
//!
//! The claim gate resolves `gh pr <verb> N` to the PR's repository and head
//! branch before comparing it with foreign claims. When that lookup fails,
//! the target is unknown and a foreign claim still blocks conservatively,
//! except a numbered PR claim for a different number, which is provably
//! another artifact. The refusal then says what could not be resolved and
//! asks nobody for a handoff: the other session's claim was never shown to be
//! about this PR.

const std = @import("std");
const ledger = @import("artifact_claim_ledger.zig");
const Target = @import("artifact_claim_target.zig").Target;

/// Tests take the unresolved path; production reaches it when the lookup fails.
pub var g_force_for_test = false;

/// The literal PR number (or a create's `--head`) from the command, or an
/// unknown target.
pub fn target(a: std.mem.Allocator, cmd: []const u8) Target {
    return @import("artifact_claim_identity.zig").target(a, cmd);
}

/// A different numbered PR is another artifact whatever its branch. When
/// this session holds the explicit target itself (#1340), a foreign claim on
/// another named PR or branch is another artifact too. A foreign claim on the
/// same PR or head branch, or a worktree-wide one, still blocks.
pub fn provablyUnrelated(claims: []const ledger.Claim, me: ledger.Owner, c: ledger.Claim, t: Target) bool {
    if (c.kind == .pull_request and t.key.len > 0 and c.key.len > 0 and !std.mem.eql(u8, c.key, t.key)) return true;
    if (c.key.len == 0 or !ownsTarget(claims, me, t)) return false;
    return switch (c.kind) {
        .pull_request => !std.mem.eql(u8, c.key, t.key),
        .branch, .publication, .commit => if (t.branch) |b| !std.mem.eql(u8, c.key, b) else true,
        .issue => true,
    };
}

/// This session's own claim on the PR number, or on the head branch a create
/// names, in the repository the command names (when both are known).
pub fn ownsTarget(claims: []const ledger.Claim, me: ledger.Owner, t: Target) bool {
    for (claims) |c| {
        if (!ledger.sameOwner(c.owner, me) or c.key.len == 0 or !sameRepository(c.repo, t.repo)) continue;
        if (c.kind == .pull_request and std.mem.eql(u8, c.key, t.key)) return true;
        if ((c.kind == .branch or c.kind == .publication) and t.branch != null and std.mem.eql(u8, c.key, t.branch.?)) return true;
    }
    return false;
}

/// A claim's `host/owner/repo` against a command's `[host/]owner/repo`.
fn sameRepository(claim_repo: ?[]const u8, flag: ?[]const u8) bool {
    const held = claim_repo orelse return true;
    const named = flag orelse return true;
    if (std.ascii.eqlIgnoreCase(held, named)) return true;
    return held.len > named.len and held[held.len - named.len - 1] == '/' and std.ascii.eqlIgnoreCase(held[held.len - named.len ..], named);
}

pub fn refuseText(a: std.mem.Allocator, c: ledger.Claim, t: Target) []const u8 {
    const what = if (t.key.len > 0)
        std.fmt.allocPrint(a, " (#{s})", .{t.key}) catch ""
    else if (t.branch) |b|
        std.fmt.allocPrint(a, " (head {s})", .{b}) catch ""
    else
        "";
    return std.fmt.allocPrint(a, "artifact claim check: could not resolve which pull request this command targets{s} (the GitHub lookup failed), so another session's live {s} claim {s} blocks it conservatively. NOT performed; no handoff was requested because that claim was not shown to cover this PR. Retry the command, or claim this PR number (or a create's --head branch) for this session and write it literally before any $(...) text.", .{
        what,
        @tagName(c.kind),
        if (c.key.len > 0) c.key else "(worktree)",
    }) catch "artifact claim check: the pull request target could not be resolved; NOT performed";
}

test {
    _ = @import("artifact_claim_identity.zig");
}

test "an unresolved explicit PR skips a different numbered claim only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = target(a, "gh pr edit 42 --body-file notes.md");
    try std.testing.expectEqualStrings("42", t.key);
    const me: ledger.Owner = .{ .session = "me", .pid = 2 };
    const other: ledger.Claim = .{ .kind = .pull_request, .key = "7", .owner = .{ .session = "peer", .pid = 1 } };
    const same: ledger.Claim = .{ .kind = .pull_request, .key = "42", .owner = .{ .session = "peer", .pid = 1 } };
    const branch: ledger.Claim = .{ .kind = .branch, .key = "feature", .owner = .{ .session = "peer", .pid = 1 } };
    try std.testing.expect(provablyUnrelated(&.{}, me, other, t));
    try std.testing.expect(!provablyUnrelated(&.{}, me, same, t));
    try std.testing.expect(!provablyUnrelated(&.{}, me, branch, t));
    try std.testing.expect(!provablyUnrelated(&.{}, me, other, target(a, "gh pr edit --body-file notes.md")));
    const text = refuseText(a, branch, t);
    try std.testing.expect(std.mem.indexOf(u8, text, "(#42)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "no handoff was requested") != null);
}

test "#1340 owning the explicit PR or head makes only other named claims unrelated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const me: ledger.Owner = .{ .session = "me", .pid = 2 };
    const peer: ledger.Owner = .{ .session = "peer", .pid = 1 };
    const mine = [_]ledger.Claim{
        .{ .kind = .pull_request, .key = "42", .owner = me, .repo = "github.com/owner/repo" },
        .{ .kind = .branch, .key = "feat/mine", .owner = me, .repo = "github.com/owner/repo" },
    };
    const edit = target(a, "gh pr edit 42 --repo Owner/Repo --body \"$(cat notes.md)\"");
    const unrelated: ledger.Claim = .{ .kind = .branch, .key = "feature", .owner = peer };
    const worktree: ledger.Claim = .{ .kind = .publication, .key = "", .owner = peer };
    try std.testing.expect(ownsTarget(&mine, me, edit));
    try std.testing.expect(provablyUnrelated(&mine, me, unrelated, edit));
    try std.testing.expect(!provablyUnrelated(&mine, me, worktree, edit));
    // Another repository's PR 42 is not the one this session holds.
    try std.testing.expect(!ownsTarget(&mine, me, target(a, "gh pr edit 42 --repo owner/fork --body x")));
    // A claim the peer holds is not this session's.
    try std.testing.expect(!ownsTarget(&mine, peer, edit));
    // A create's owned head: a peer's claim on that same branch still blocks.
    const create = target(a, "gh pr create --repo owner/repo --head feat/mine --body \"$(cat b)\"");
    try std.testing.expect(provablyUnrelated(&mine, me, unrelated, create));
    try std.testing.expect(!provablyUnrelated(&mine, me, .{ .kind = .publication, .key = "feat/mine", .owner = peer }, create));
    const text = refuseText(a, worktree, create);
    try std.testing.expect(std.mem.indexOf(u8, text, "(head feat/mine)") != null);
}

test "#1340 the gate honors an owned explicit PR and still respects a foreign branch" {
    const claims = @import("artifact_claim.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const io = std.testing.io;
    claims.resetForTest();
    defer claims.resetForTest();
    g_force_for_test = true;
    defer g_force_for_test = false;
    claims.setTestOwner(.{ .session = "s-other" });
    _ = try claims.handleTool(ar, io, "claim", "branch", "feature", "");
    claims.setTestOwner(.{ .session = "s-me" });
    claims.setTestOwnerLive(true);
    const edit = "cd ../my-tree && gh pr edit 42 --repo owner/repo --body \"$(cat notes.md)\"";
    const ready = "gh pr ready 42 --repo owner/repo";
    // Unowned, the PR's head is unknown and the foreign branch claim may cover it.
    try std.testing.expect(claims.gateCommand(ar, io, edit, "") != null);
    _ = try claims.handleTool(ar, io, "claim", "pull_request", "42", "");
    try std.testing.expect(claims.gateCommand(ar, io, edit, "") == null);
    try std.testing.expect(claims.gateCommand(ar, io, ready, "") == null);
    try std.testing.expect(claims.gateCommand(ar, io, "gh pr ready 43 --repo owner/repo", "") != null);
    try std.testing.expect(claims.gateCommand(ar, io, "gh pr edit --body \"$(cat notes.md)\" 42", "") != null);
    // Creating from an owned head; the foreign branch itself stays respected.
    _ = try claims.handleTool(ar, io, "claim", "branch", "feat/mine", "");
    const body = " --title 'Fix it' --body \"$(cat <<'EOF'\nbody\nEOF\n)\"";
    try std.testing.expect(claims.gateCommand(ar, io, try std.fmt.allocPrint(ar, "gh pr create --repo owner/repo --base main --head feat/mine{s}", .{body}), "") == null);
    const foreign = claims.gateCommand(ar, io, try std.fmt.allocPrint(ar, "gh pr create --repo owner/repo --base main --head feature{s}", .{body}), "") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, foreign, "branch claim feature") != null);
    // A foreign worktree-wide claim still blocks even an owned target.
    claims.setTestOwner(.{ .session = "s-other" });
    _ = try claims.handleTool(ar, io, "claim", "publication", "", "");
    claims.setTestOwner(.{ .session = "s-me" });
    try std.testing.expect(claims.gateCommand(ar, io, ready, "") != null);
}

test "#1344 the gate: another numbered PR claim does not block, a branch claim explains without a handoff" {
    const claims = @import("artifact_claim.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const io = std.testing.io;
    claims.resetForTest();
    defer claims.resetForTest();
    g_force_for_test = true;
    defer g_force_for_test = false;
    claims.setTestOwner(.{ .session = "s-owner" });
    _ = try claims.handleTool(ar, io, "claim", "pull_request", "7", "");
    claims.setTestOwner(.{ .session = "s-other" });
    claims.setTestOwnerLive(true);
    try std.testing.expect(claims.gateCommand(ar, io, "gh pr edit 42 --body-file notes.md", "") == null);
    const same = claims.gateCommand(ar, io, "gh pr edit 7 --body-file notes.md", "") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, same, "could not resolve") != null);
    claims.setTestOwner(.{ .session = "s-owner" });
    _ = try claims.handleTool(ar, io, "claim", "branch", "feature", "");
    claims.setTestOwner(.{ .session = "s-other" });
    const branch = claims.gateCommand(ar, io, "gh pr edit 42 --body-file notes.md", "") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, branch, "(#42)") != null);
    try std.testing.expect(std.mem.indexOf(u8, branch, "no handoff was requested") != null);
}
