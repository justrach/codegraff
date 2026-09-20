//! Repository-scoped artifact claims (#840). Presence.gateCheck is a one-shot
//! awareness checkpoint; this ledger is the durable owner of branch / issue /
//! commit / pull-request / publication work. Acknowledging a peer, polling for
//! a missing PR, or waiting does not transfer a claim. Only acquire, release,
//! handoff, or a proven-dead owner does.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const tools_mod = @import("tools.zig");
const ExecResult = tools_mod.ExecResult;
const presence = @import("presence.zig");
const proc_identity = @import("proc_identity.zig");

const claim_ledger = @import("artifact_claim_ledger.zig");
pub const Kind = claim_ledger.Kind;
pub const Owner = claim_ledger.Owner;
pub const Claim = claim_ledger.Claim;
pub const Verdict = claim_ledger.Verdict;
pub const max_claims = claim_ledger.max_claims;
pub const Ledger = claim_ledger.Ledger;
pub const kindFrom = claim_ledger.kindFrom;
pub const sameOwner = claim_ledger.sameOwner;
pub const verdict = claim_ledger.verdict;
pub const find = claim_ledger.find;
pub const acquire = claim_ledger.acquire;
pub const release = claim_ledger.release;
pub const handoff = claim_ledger.handoff;

/// Git / GitHub writes that must not proceed under a foreign live claim.
pub fn isClaimedMutation(cmd: []const u8) bool {
    return @import("artifact_claim_command.zig").classify(cmd) != null;
}

pub fn mutationKind(cmd: []const u8) Kind {
    return switch (@import("artifact_claim_command.zig").classify(cmd) orelse return .publication) {
        .issue => .issue,
        .commit => .commit,
        .pull_request => .pull_request,
        .publication => .publication,
    };
}

pub fn refuseText(arena: Allocator, kind: Kind, key: []const u8, owner: Owner) []const u8 {
    return std.fmt.allocPrint(arena, "artifact claim held: {s} {s} owner=\"{s}\" pid {d}. NOT performed. Asked them on Accord to handoff or release.", .{ @tagName(kind), if (key.len > 0) key else "(worktree)", owner.session, owner.pid }) catch "artifact claim held: the action was NOT performed";
}

/// JSONL is durable; Accord is the live poke (ADR 0134 / 0144). Do not make
/// the model broker a handoff in the user's chat.
fn pingOwner(io: Io, arena: Allocator, owner: Owner, kind: Kind, key: []const u8) void {
    if (builtin.is_test) return;
    const text = std.fmt.allocPrint(arena, "need {s} {s} handed off or released — a publish is blocked", .{ @tagName(kind), if (key.len > 0) key else "worktree" }) catch return;
    _ = presence.postTo(io, arena, text, owner.session);
    _ = presence.postToDevice(io, arena, text, owner.session, false);
}

// --- process-global ledger (one worktree, many tests swap it) ---

var g_ledger: Ledger = .{};
var g_test_owner: Owner = .{};
var g_test_live: bool = true;
var g_persist_path: ?[]const u8 = null;
var g_test_peers: ?[]const @import("worktree_lease.zig").Owner = null;
var g_store: ?std.heap.ArenaAllocator = null;

pub const persist_rel = ".graff/artifact-claims.json";

fn storeAlloc() Allocator {
    if (g_store == null) g_store = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    return g_store.?.allocator();
}

pub fn resetForTest() void {
    g_ledger.len = 0;
    g_test_owner = .{};
    g_test_live = true;
    g_persist_path = null;
    g_test_peers = null;
    if (g_store) |*st| {
        st.deinit();
        g_store = null;
    }
}

pub fn setPersistPath(path: []const u8) void {
    g_persist_path = path;
}

pub fn setTestOwner(owner: Owner) void {
    g_test_owner = owner;
}

pub fn setTestOwnerLive(live: bool) void {
    g_test_live = live;
}

pub fn testLedger() *Ledger {
    return &g_ledger;
}

pub fn selfOwner(io: Io) Owner {
    if (g_test_owner.session.len > 0 or g_test_owner.pid != 0) return g_test_owner;
    return .{
        .session = presence.ownSession(),
        .pid = proc_identity.selfPid(),
        .start_id = proc_identity.selfStartId(io),
    };
}

fn ownerLive(io: Io, owner: Owner) bool {
    if (g_test_owner.session.len > 0 or g_test_owner.pid != 0) {
        if (sameOwner(owner, g_test_owner)) return true;
        return g_test_live;
    }
    // A legacy handoff with no process identity is not held forever.
    if (owner.pid == 0) return false;
    return proc_identity.ownerState(owner.start_id, proc_identity.probe(io, owner.pid)) == .held;
}

fn claimRelevant(held: Kind, mutation: Kind) bool {
    if (held == mutation) return true;
    return switch (mutation) {
        .pull_request => held == .branch or held == .commit or held == .publication,
        .publication => held == .branch or held == .pull_request or held == .commit,
        .commit => held == .branch or held == .publication,
        .issue => false,
        .branch => held == .publication,
    };
}

pub fn gateCommand(arena: Allocator, io: Io, cmd: []const u8, key: []const u8) ?[]const u8 {
    return gateCommandIn(arena, io, cmd, key, ".");
}

pub fn gateCommandIn(arena: Allocator, io: Io, cmd: []const u8, key: []const u8, cwd: []const u8) ?[]const u8 {
    if (!isClaimedMutation(cmd)) return null;
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    var local = readSnapshot(io, scratch.allocator()) catch return "artifact claim ledger unreadable or busy: action NOT performed";
    const ledger = &local;
    if (ledger.len == 0) return null;
    const kind = mutationKind(cmd);
    const me = selfOwner(io);
    // Avoid remote lookups when every potentially relevant claim is ours.
    var foreign = false;
    for (ledger.slice()) |c| if (!sameOwner(c.owner, me)) {
        foreign = true;
        break;
    };
    if (!foreign) return null;
    // Never `gh pr view` an issue create: that attaches the current PR/issue
    // number and makes a new write look like the latest claimed one (#1088).
    const resolved = if (builtin.is_test or kind != .pull_request) null else @import("artifact_claim_target.zig").resolve(arena, io, cmd, kind, cwd);
    // The remote read does not hold the ledger lock. A handoff/release during
    // that read must be observed before deciding whether this action may run.
    const tx = begin(io, scratch.allocator()) catch return "artifact claim ledger unavailable or busy: action NOT performed";
    defer if (tx) |transaction| transaction.end();
    local = .{};
    if (tx) |transaction| {
        loadTransaction(transaction, ledger) catch return "artifact claim ledger unreadable: action NOT performed";
    } else local = g_ledger;
    var target: @import("artifact_claim_target.zig").Target = resolved orelse @import("artifact_claim_target.zig").explicit(cmd, kind) orelse .{ .kind = if (kind == .issue) Kind.issue else Kind.branch, .key = key };
    if (target.kind == .branch and target.key.len == 0) target.key = key;
    for (ledger.slice()) |c| {
        if (!claimRelevant(c.kind, kind)) continue;
        const branch_claim = c.kind == .publication or c.kind == .branch;
        if (c.kind == .branch and claim_ledger.differentRepository(c.repo, target.head_repo)) continue;
        if (claim_ledger.differentRepository(c.repo, target.repo)) {
            // A fork's branch can own the same PR's publication work. Unknown
            // head repository evidence must not silently release that claim.
            if (!branch_claim or claim_ledger.differentRepository(c.repo, target.head_repo)) continue;
        }
        const compare_key = if (branch_claim and target.branch != null) target.branch.? else target.key;
        const comparable = c.kind == target.kind or (branch_claim and (target.kind == .branch or target.branch != null));
        if (!comparable) {
            // `gh pr create` with no head stays conservative. Other new writes
            // (issue create, push of another branch) are not the claimed object.
            if (!(kind == .pull_request and compare_key.len == 0)) continue;
        } else if (compare_key.len > 0 and c.key.len > 0 and !std.mem.eql(u8, c.key, compare_key)) continue;
        // Named claims do not match an unresolved git/issue/push target (#1014, #1088).
        if (compare_key.len == 0 and c.key.len > 0 and kind != .pull_request) continue;
        if (!sameOwner(c.owner, me) and ownerLive(io, c.owner)) {
            pingOwner(io, arena, c.owner, c.kind, c.key);
            return refuseText(arena, c.kind, c.key, c.owner);
        }
    }
    return null;
}

pub fn handleTool(arena: Allocator, io: Io, action: []const u8, kind_s: []const u8, key: []const u8, to_session: []const u8) !ExecResult {
    return handleToolIn(arena, io, action, kind_s, key, to_session, ".", null);
}

pub fn handleToolIn(arena: Allocator, io: Io, action: []const u8, kind_s: []const u8, key: []const u8, to_session: []const u8, cwd: []const u8, requested_repo: ?[]const u8) !ExecResult {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const repo = if (builtin.is_test and requested_repo == null) null else @import("artifact_repository.zig").resolve(arena, io, cwd, requested_repo);
    if (requested_repo != null and repo == null) return .{ .text = "claim repository could not be resolved; no claim changed", .is_error = true };
    const tx = begin(io, scratch.allocator()) catch return .{ .text = "claim ledger unavailable or busy", .is_error = true };
    defer if (tx) |transaction| transaction.end();
    var local: Ledger = .{};
    const ledger = if (tx != null) &local else &g_ledger;
    const storage = if (tx != null) scratch.allocator() else storeAlloc();
    if (tx) |transaction| loadTransaction(transaction, ledger) catch return .{ .text = "claim ledger unreadable; no claim changed", .is_error = true };
    const kind = kindFrom(kind_s) orelse return .{
        .text = "kind must be branch, issue, commit, pull_request, or publication",
        .is_error = true,
    };
    const me = selfOwner(io);
    const now: i64 = 0;
    if (claim_ledger.ambiguous(ledger.slice(), kind, key, repo)) return .{ .text = "claim repository is ambiguous; specify repo explicitly", .is_error = true };
    const existing = claim_ledger.findIn(ledger.slice(), kind, key, repo);
    const live = if (existing) |c| ownerLive(io, c.owner) else false;
    if (std.mem.eql(u8, action, "claim") or std.mem.eql(u8, action, "acquire")) {
        const msg = claim_ledger.acquireIn(ledger, storage, kind, key, me, now, live, repo) catch |err| switch (err) {
            error.ClaimHeld => return .{ .text = refuseText(arena, kind, key, existing.?.owner), .is_error = true },
            else => return .{ .text = "claim acquire failed", .is_error = true },
        };
        if (tx) |transaction| transaction.write(try persistJson(scratch.allocator(), ledger)) catch return .{ .text = "claim was NOT persisted; retry before publishing", .is_error = true };
        return .{ .text = msg, .is_error = false };
    }
    if (std.mem.eql(u8, action, "release")) {
        const existing_owner = if (existing) |c| c.owner else null;
        const recoverable = if (existing_owner) |o| o.pid == 0 and (std.mem.eql(u8, o.session, me.session) or o.session.len == 0) else false;
        const msg = claim_ledger.releaseIn(ledger, kind, key, me, live and !recoverable, repo) catch return .{
            .text = "cannot release a live foreign claim",
            .is_error = true,
        };
        if (tx) |transaction| transaction.write(try persistJson(scratch.allocator(), ledger)) catch return .{ .text = "claim was NOT persisted; retry before publishing", .is_error = true };
        return .{ .text = msg, .is_error = false };
    }
    if (std.mem.eql(u8, action, "handoff")) {
        if (to_session.len == 0) return .{ .text = "handoff needs session (the receiver)", .is_error = true };
        const receiver = switch (@import("peer_target.zig").resolvePeer(if (builtin.is_test) g_test_peers orelse presence.liveAllPeers(io, arena) else presence.liveAllPeers(io, arena), to_session)) {
            .one => |p| p,
            .none => return .{ .text = "handoff receiver is not a live peer", .is_error = true },
            .ambiguous => return .{ .text = "handoff receiver is ambiguous", .is_error = true },
        };
        if (!builtin.is_test and (!std.mem.eql(u8, receiver.identity, presence.ownIdentity()) or receiver.start_id == 0))
            return .{ .text = "handoff receiver must have verified identity in this workspace", .is_error = true };
        const probe = proc_identity.probe(io, receiver.pid);
        if (receiver.pid <= 0 or receiver.session_id.len == 0 or proc_identity.ownerState(receiver.start_id, probe) != .held)
            return .{ .text = "handoff receiver is gone", .is_error = true };
        const start_id = switch (probe) {
            .id => |id| id,
            else => receiver.start_id,
        };
        const msg = claim_ledger.handoffIn(ledger, storage, kind, key, me, .{ .session = receiver.session_id, .pid = receiver.pid, .start_id = start_id }, now, live, repo) catch |err| switch (err) {
            error.ClaimHeld => return .{ .text = "cannot hand off a claim you do not own", .is_error = true },
            error.NoClaim => return .{ .text = "no claim to hand off", .is_error = true },
            else => return .{ .text = "handoff failed", .is_error = true },
        };
        if (tx) |transaction| transaction.write(try persistJson(scratch.allocator(), ledger)) catch return .{ .text = "claim was NOT persisted; retry before publishing", .is_error = true };
        return .{ .text = msg, .is_error = false };
    }
    if (std.mem.eql(u8, action, "status")) {
        if (existing) |c| {
            const v = claim_ledger.verdictIn(ledger.slice(), kind, key, me, live, repo);
            return .{ .text = try std.fmt.allocPrint(arena, "claim {s} {s}: {s} owner=\"{s}\"", .{ @tagName(kind), key, @tagName(v), c.owner.session }), .is_error = false };
        }
        return .{ .text = "no claim", .is_error = false };
    }
    return .{ .text = "action must be claim, release, handoff, or status", .is_error = true };
}

fn persistPath() ?[]const u8 {
    if (g_persist_path) |p| return p;
    if (builtin.is_test) return null;
    return persist_rel;
}

fn begin(io: Io, arena: Allocator) !?@import("repo_transaction.zig").Transaction {
    const path = persistPath() orelse return null;
    return try @import("repo_transaction.zig").Transaction.begin(io, arena, path);
}

fn readSnapshot(io: Io, arena: Allocator) !Ledger {
    const tx = try begin(io, arena);
    defer if (tx) |transaction| transaction.end();
    var ledger: Ledger = .{};
    if (tx) |transaction| try loadTransaction(transaction, &ledger) else return g_ledger;
    return ledger;
}

fn loadTransaction(tx: @import("repo_transaction.zig").Transaction, ledger: *Ledger) !void {
    const text = try tx.read() orelse return;
    try loadJson(tx.arena, ledger, text);
}

fn reload(io: Io) !void {
    const path = persistPath() orelse return;
    // Every transaction reads again under the lock. A previously cached owner
    // must never survive a peer's acknowledged handoff.
    g_ledger.len = 0;
    if (g_store) |*st| st.deinit();
    g_store = null;
    const text = Io.Dir.cwd().readFileAlloc(io, path, storeAlloc(), .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try loadJson(storeAlloc(), &g_ledger, text);
}

pub const persistJson = @import("artifact_claim_store.zig").persistJson;
pub const loadJson = @import("artifact_claim_store.zig").loadJson;

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
    // Session B acknowledges in prose (peer_message send) — that is not a handoff.
    setTestOwner(.{ .session = "s-other", .pid = 12, .start_id = 2 });
    setTestOwnerLive(true);
    const blocked = gateCommand(ar, std.testing.io, "gh pr create --title x --body y", "feat/x").?;
    try std.testing.expect(std.mem.indexOf(u8, blocked, "NOT performed") != null);
    try std.testing.expect(std.mem.indexOf(u8, blocked, "handoff") != null);
    // Explicit handoff atomically enables the receiver.
    setTestOwner(.{ .session = "s-owner", .pid = 11, .start_id = 1 });
    const rec = proc_identity.selfRecord(std.testing.io);
    const peers = [_]@import("worktree_lease.zig").Owner{.{ .session_id = "s-other", .title = "Receiver title", .pid = rec.pid, .start_id = rec.start_id }};
    g_test_peers = &peers;
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
    g_ledger.len = 0;
    try reload(io);
    try std.testing.expectEqual(@as(usize, 1), g_ledger.len);
    try std.testing.expectEqualStrings("feat/x", g_ledger.items[0].key);
    try std.testing.expectEqualStrings("s-persist", g_ledger.items[0].owner.session);
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
    // Re-issuing after presence.gateCheck ACKs the peer — claim still holds.
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
