//! Unit tests for repository-scoped artifact claims (#840, #1092, #1752).
//! Split out of `artifact_claim.zig` to keep it below the 600-line ceiling.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const claims = @import("artifact_claim.zig");
const claim_path = @import("artifact_claim_path.zig");
const proc_identity = @import("proc_identity.zig");

const Ledger = claims.Ledger;
const Owner = claims.Owner;
const Verdict = claims.Verdict;
const acquire = claims.acquire;
const release = claims.release;
const handoff = claims.handoff;
const verdict = claims.verdict;
const sameOwner = claims.sameOwner;
const persistJson = claims.persistJson;
const loadJson = claims.loadJson;
const isClaimedMutation = claims.isClaimedMutation;
const resetForTest = claims.resetForTest;
const setPersistPath = claims.setPersistPath;
const setTestOwner = claims.setTestOwner;
const setTestOwnerLive = claims.setTestOwnerLive;
const setTestResolveCwd = claims.setTestResolveCwd;
const setTestPeers = claims.setTestPeers;
const handleTool = claims.handleTool;
const handleToolIn = claims.handleToolIn;
const gateCommand = claims.gateCommand;
const gateCommandIn = claims.gateCommandIn;
const selfOwner = claims.selfOwner;
const ownerLive = claims.ownerLive;
const testLedger = claims.testLedger;
const reloadForTest = claims.reloadForTest;

test "acquire / handoff / release are atomic and session-scoped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var ledger: Ledger = .{};
    const a = Owner{ .session = "s-a", .pid = 1, .start_id = 10 };
    const b = Owner{ .session = "s-b", .pid = 2, .start_id = 20 };
    _ = try acquire(&ledger, ar, .publication, "feat/x", a, 1, false);
    try std.testing.expectEqual(Verdict.mine, verdict(ledger.slice(), .publication, "feat/x", a, true));
    try std.testing.expectEqual(Verdict.foreign_live, verdict(ledger.slice(), .publication, "feat/x", b, true));
    try std.testing.expectError(error.ClaimHeld, acquire(&ledger, ar, .publication, "feat/x", b, 2, true));
    _ = try handoff(&ledger, ar, .publication, "feat/x", a, b, 3, true);
    try std.testing.expectEqual(Verdict.mine, verdict(ledger.slice(), .publication, "feat/x", b, true));
    try std.testing.expectEqual(Verdict.foreign_live, verdict(ledger.slice(), .publication, "feat/x", a, true));
    _ = try release(&ledger, .publication, "feat/x", b, true);
    try std.testing.expectEqual(Verdict.free, verdict(ledger.slice(), .publication, "feat/x", a, true));
}

test "stale-owner recovery is only a gone process, never a missing PR" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var ledger: Ledger = .{};
    const dead = Owner{ .session = "s-dead", .pid = 9, .start_id = 1 };
    const live = Owner{ .session = "s-live", .pid = 8, .start_id = 2 };
    _ = try acquire(&ledger, ar, .pull_request, "none-yet", dead, 1, false);
    try std.testing.expectEqual(Verdict.stale, verdict(ledger.slice(), .pull_request, "none-yet", live, false));
    try std.testing.expectEqual(Verdict.foreign_live, verdict(ledger.slice(), .pull_request, "none-yet", live, true));
    const msg = try acquire(&ledger, ar, .pull_request, "none-yet", live, 2, false);
    try std.testing.expect(std.mem.indexOf(u8, msg, "stale") != null);
    try std.testing.expectEqual(Verdict.mine, verdict(ledger.slice(), .pull_request, "none-yet", live, true));
}

test "a different branch or issue stays independently writable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var ledger: Ledger = .{};
    const a = Owner{ .session = "s-a" };
    const b = Owner{ .session = "s-b" };
    _ = try acquire(&ledger, ar, .branch, "feat/a", a, 1, false);
    _ = try acquire(&ledger, ar, .issue, "840", b, 1, false);
    try std.testing.expectEqual(Verdict.free, verdict(ledger.slice(), .branch, "feat/b", b, true));
    try std.testing.expectEqual(Verdict.free, verdict(ledger.slice(), .issue, "841", a, true));
}

test "persist round-trip survives a resume-shaped reload" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var ledger: Ledger = .{};
    _ = try acquire(&ledger, ar, .publication, "feat/x", .{ .session = "s-a", .pid = 3, .start_id = 7 }, 1, false);
    const json = try persistJson(ar, &ledger);
    var restored: Ledger = .{};
    try loadJson(ar, &restored, json);
    try std.testing.expectEqual(@as(usize, 1), restored.len);
    try std.testing.expectEqualStrings("feat/x", restored.items[0].key);
    try std.testing.expectEqualStrings("s-a", restored.items[0].owner.session);
    try std.testing.expectEqual(@as(i32, 3), restored.items[0].owner.pid);
}

test "claimed mutations include push and gh pr create, not status or checks --watch" {
    try std.testing.expect(!isClaimedMutation("git add -A"));
    try std.testing.expect(isClaimedMutation("git commit -m wip"));
    try std.testing.expect(isClaimedMutation("git push origin HEAD"));
    try std.testing.expect(isClaimedMutation("gh pr create --title x --body y"));
    try std.testing.expect(isClaimedMutation("gh pr edit 1 --body z"));
    try std.testing.expect(!isClaimedMutation("git status"));
    try std.testing.expect(!isClaimedMutation("gh pr checks --watch"));
    try std.testing.expect(!isClaimedMutation("gh pr list"));
}

test "#840 acknowledged handoff does not let the other session create the PR" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    resetForTest();
    defer resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    setPersistPath(try std.fmt.allocPrint(ar, ".zig-cache/tmp/{s}/claims.json", .{tmp.sub_path}));
    setTestOwner(.{ .session = "s-owner", .pid = 11, .start_id = 1 });
    const got = try handleTool(ar, std.testing.io, "claim", "publication", "feat/x", "");
    try std.testing.expect(!got.is_error);
    setTestOwner(.{ .session = "s-other", .pid = 12, .start_id = 2 });
    setTestOwnerLive(true);
    const blocked = gateCommand(ar, std.testing.io, "gh pr create --title x --body y", "feat/x").?;
    try std.testing.expect(std.mem.indexOf(u8, blocked, "NOT performed") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocked, "handoff") != null);
    setTestOwner(.{ .session = "s-owner", .pid = 11, .start_id = 1 });
    const rec = proc_identity.selfRecord(std.testing.io);
    const peers = [_]@import("worktree_lease.zig").Owner{.{ .session_id = "s-other", .title = "Receiver title", .pid = rec.pid, .start_id = rec.start_id }};
    setTestPeers(&peers);
    const ho = try handleTool(ar, std.testing.io, "handoff", "publication", "feat/x", "Receiver title");
    try std.testing.expect(!ho.is_error);
    setTestOwner(.{ .session = "s-other", .pid = rec.pid, .start_id = rec.start_id });
    try std.testing.expect(gateCommand(ar, std.testing.io, "gh pr create --title x --body y", "feat/x") == null);
    setTestOwner(.{ .session = "s-owner", .pid = 11, .start_id = 1 });
    try std.testing.expect(gateCommand(ar, std.testing.io, "gh pr create --title x --body y", "feat/x") != null);
}

test "empty bash key still blocks a named publication claim" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    resetForTest();
    defer resetForTest();
    setTestOwner(.{ .session = "s-owner" });
    _ = try handleTool(ar, std.testing.io, "claim", "publication", "feat/x", "");
    setTestOwner(.{ .session = "s-other" });
    setTestOwnerLive(true);
    try std.testing.expect(gateCommand(ar, std.testing.io, "gh pr create --title x --body y", "") != null);
    try std.testing.expect(gateCommand(ar, std.testing.io, "git commit -m wip", "") == null);
}

test "file persist reloads after a resume-shaped reset" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try std.fmt.allocPrint(ar, ".zig-cache/tmp/{s}/claims.json", .{tmp.sub_path});
    Io.Dir.cwd().deleteFile(io, file) catch {};
    defer Io.Dir.cwd().deleteFile(io, file) catch {};
    resetForTest();
    defer resetForTest();
    setPersistPath(file);
    setTestOwner(.{ .session = "s-persist", .pid = 4, .start_id = 9 });
    _ = try handleTool(ar, io, "claim", "publication", "feat/x", "");
    testLedger().len = 0;
    try reloadForTest(io);
    try std.testing.expectEqual(@as(usize, 1), testLedger().len);
    try std.testing.expectEqualStrings("feat/x", testLedger().items[0].key);
    try std.testing.expectEqualStrings("s-persist", testLedger().items[0].owner.session);
}

test "#840 malformed ledger and recycled identity never authorize ownership" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    var ledger: Ledger = .{};
    const invalid = [_][]const u8{
        "{}",                                                                         "[{}]",                                                                    "[1]",
        "[{\"kind\":\"branch\",\"key\":\"x\",\"session\":\"s\",\"pid\":2147483648}]", "[{\"kind\":\"branch\",\"key\":\"x\",\"session\":\"s\",\"start_id\":-1}]", "[{\"kind\":\"branch\",\"key\":\"x\",\"session\":\"s\"},{\"kind\":\"branch\",\"key\":\"x\",\"session\":\"t\"}]",
    };
    for (invalid) |text| try std.testing.expectError(error.InvalidClaimLedger, loadJson(ar, &ledger, text));
    resetForTest();
    defer resetForTest();
    const me = selfOwner(std.testing.io);
    var reused = me;
    reused.start_id +%= 1;
    try std.testing.expect(!sameOwner(me, reused));
    if (me.start_id != 0) try std.testing.expect(!ownerLive(std.testing.io, reused));
    reused = me;
    reused.pid += 1;
    try std.testing.expect(!sameOwner(me, reused));
    setTestOwner(.{ .session = "owner" });
    _ = try handleTool(ar, std.testing.io, "claim", "issue", "840", "");
    try std.testing.expect((try handleTool(ar, std.testing.io, "handoff", "issue", "840", "unresolved")).is_error);
    try std.testing.expectEqualStrings("owner", testLedger().items[0].owner.session);
}

test "shared-tree ACK is not a claim release" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    resetForTest();
    defer resetForTest();
    setTestOwner(.{ .session = "s-owner" });
    _ = try handleTool(ar, std.testing.io, "claim", "publication", "feat/x", "");
    setTestOwner(.{ .session = "s-other" });
    setTestOwnerLive(true);
    try std.testing.expect(gateCommand(ar, std.testing.io, "git commit -m wip", "feat/x") != null);
    try std.testing.expect(gateCommand(ar, std.testing.io, "git push origin HEAD", "feat/x") != null);
}

test "publication claims do not block unrelated issue creation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    resetForTest();
    defer resetForTest();
    setTestOwner(.{ .session = "s-pub", .pid = 21, .start_id = 3 });
    _ = try handleTool(ar, std.testing.io, "claim", "publication", "feat/x", "");
    setTestOwner(.{ .session = "s-other", .pid = 22, .start_id = 4 });
    setTestOwnerLive(true);
    try std.testing.expect(gateCommand(ar, std.testing.io, "gh issue create --title x --body y", "12") == null);
    try std.testing.expect(gateCommand(ar, std.testing.io, "gh pr create --title x --body y", "feat/x") != null);
}

test "#1088 issue create is not the latest claimed issue; push is not an unrelated PR" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    resetForTest();
    defer resetForTest();
    setTestOwner(.{ .session = "s-owner", .pid = 41, .start_id = 7 });
    _ = try handleTool(ar, std.testing.io, "claim", "issue", "1087", "");
    _ = try handleTool(ar, std.testing.io, "claim", "pull_request", "1079", "");
    setTestOwner(.{ .session = "s-other", .pid = 42, .start_id = 8 });
    setTestOwnerLive(true);
    try std.testing.expect(gateCommand(ar, std.testing.io, "gh issue create --title x --body y", "") == null);
    try std.testing.expect(gateCommand(ar, std.testing.io, "gh issue create --title 'x' --body y", "") == null);
    try std.testing.expect(gateCommand(ar, std.testing.io, "gh issue edit 1087 --title x", "") != null);
    try std.testing.expect(gateCommand(ar, std.testing.io, "git push origin HEAD", "release/v0.0.302") == null);
    try std.testing.expect(gateCommand(ar, std.testing.io, "git push origin HEAD", "") == null);
    try std.testing.expect(gateCommand(ar, std.testing.io, "git add src/artifact_claim.zig", "release/v0.0.301") == null);
    try std.testing.expect(gateCommand(ar, std.testing.io, "git -C other commit -m wip", "") == null);
}

test "legacy pid-zero handoff can be released by the labeled session" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    resetForTest();
    defer resetForTest();
    setTestOwner(.{ .session = "s-legacy", .pid = 0, .start_id = 0 });
    _ = try handleTool(ar, std.testing.io, "claim", "publication", "feat/legacy", "");
    setTestOwner(.{ .session = "s-legacy", .pid = 44, .start_id = 8 });
    setTestOwnerLive(true);
    const released = try handleTool(ar, std.testing.io, "release", "publication", "feat/legacy", "");
    try std.testing.expect(!released.is_error);
}

test "#1752 same-remote independent clones coordinate claims and allow verified cross-clone handoff" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(tmp_root);
    const clone_a = try std.fmt.allocPrint(a, "{s}/clone-a", .{tmp_root});
    defer a.free(clone_a);
    const clone_b = try std.fmt.allocPrint(a, "{s}/clone-b", .{tmp_root});
    defer a.free(clone_b);
    try Io.Dir.cwd().createDirPath(io, clone_a);
    try Io.Dir.cwd().createDirPath(io, clone_b);
    try claim_path.git(io, a, &.{ "init", "-q", "-b", "main", clone_a });
    try claim_path.git(io, a, &.{ "init", "-q", "-b", "main", clone_b });
    const remote_url = "https://github.com/org/same-remote-1752.git";
    try claim_path.git(io, a, &.{ "-C", clone_a, "remote", "add", "origin", remote_url });
    try claim_path.git(io, a, &.{ "-C", clone_b, "remote", "add", "origin", remote_url });

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const shared_file = claim_path.canonicalFile(ar, io, clone_a) orelse return error.TestUnexpectedResult;
    defer Io.Dir.cwd().deleteFile(io, shared_file) catch {};
    try std.testing.expectEqualStrings(shared_file, claim_path.canonicalFile(ar, io, clone_b).?);

    resetForTest();
    defer resetForTest();
    setTestResolveCwd(true);
    setTestOwner(.{ .session = "s-clone-a", .pid = 101, .start_id = 11 });
    setTestOwnerLive(true);

    const got = try handleToolIn(ar, io, "claim", "branch", "feat/1752", "", clone_a, "github.com/org/same-remote-1752");
    try std.testing.expect(!got.is_error);

    setTestOwner(.{ .session = "s-clone-b", .pid = 102, .start_id = 22 });
    const dup = try handleToolIn(ar, io, "claim", "branch", "feat/1752", "", clone_b, "github.com/org/same-remote-1752");
    try std.testing.expect(dup.is_error);
    try std.testing.expect(std.mem.indexOf(u8, dup.text, "artifact claim held") != null);
    try std.testing.expect(gateCommandIn(ar, io, "git push origin feat/1752", "feat/1752", clone_b) != null);

    setTestOwner(.{ .session = "s-clone-a", .pid = 101, .start_id = 11 });
    const rec = proc_identity.selfRecord(io);
    const clone_b_git = try std.fmt.allocPrint(ar, "{s}/.git", .{clone_b});
    const peers = [_]@import("worktree_lease.zig").Owner{.{
        .session_id = "s-clone-b",
        .title = "Clone B peer",
        .identity = clone_b_git,
        .pid = rec.pid,
        .start_id = rec.start_id,
    }};
    setTestPeers(&peers);
    const ho = try handleToolIn(ar, io, "handoff", "branch", "feat/1752", "Clone B peer", clone_a, "github.com/org/same-remote-1752");
    try std.testing.expect(!ho.is_error);

    setTestOwner(.{ .session = "s-clone-b", .pid = rec.pid, .start_id = rec.start_id });
    try std.testing.expect(gateCommandIn(ar, io, "git push origin feat/1752", "feat/1752", clone_b) == null);
}
