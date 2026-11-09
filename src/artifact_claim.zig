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
const unresolved_mod = @import("artifact_claim_unresolved.zig");
const claim_ledger = @import("artifact_claim_ledger.zig");
const claim_path = @import("artifact_claim_path.zig");
const claim_stale = @import("artifact_claim_stale.zig");
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

fn announceLive(io: Io, arena: Allocator, ledger: *const Ledger) void {
    const json = persistJson(arena, ledger) catch return;
    @import("presence_accord.zig").liveClaim(io, json);
}

// --- process-global ledger (one worktree, many tests swap it) ---

var g_ledger: Ledger = .{};
var g_test_owner: Owner = .{};
var g_test_live: bool = true;
var g_persist_path: ?[]const u8 = null;
var g_test_resolve_cwd: bool = false;
var g_test_peers: ?[]const @import("worktree_lease.zig").Owner = null;
var g_store: ?std.heap.ArenaAllocator = null;

pub const persist_rel = claim_path.persist_rel;

fn storeAlloc() Allocator {
    if (g_store == null) g_store = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    return g_store.?.allocator();
}

pub fn resetForTest() void {
    g_ledger.len = 0;
    g_test_owner = .{};
    g_test_live = true;
    g_persist_path = null;
    g_test_resolve_cwd = false;
    g_test_peers = null;
    if (g_store) |*st| {
        st.deinit();
        g_store = null;
    }
}

pub fn setPersistPath(path: []const u8) void {
    g_persist_path = path;
}

pub fn setTestResolveCwd(on: bool) void {
    g_test_resolve_cwd = on;
}

pub fn setTestOwner(owner: Owner) void {
    g_test_owner = owner;
}

pub fn setTestOwnerLive(live: bool) void {
    g_test_live = live;
}

pub fn setTestPeers(peers: []const @import("worktree_lease.zig").Owner) void {
    g_test_peers = peers;
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

pub fn ownerLive(io: Io, owner: Owner) bool {
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
    var local = readSnapshot(io, scratch.allocator(), cwd) catch return "artifact claim ledger unreadable or busy: action NOT performed";
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
    const tx = begin(io, scratch.allocator(), cwd, null) catch return "artifact claim ledger unavailable or busy: action NOT performed";
    defer if (tx) |transaction| transaction.end();
    local = .{};
    if (tx) |transaction| {
        loadTransaction(io, transaction, ledger, cwd) catch return "artifact claim ledger unreadable: action NOT performed";
    } else local = g_ledger;
    const before_len = ledger.len;
    var stale_i: usize = 0;
    while (stale_i < ledger.len) {
        if (ledger.items[stale_i].kind == .publication and !ownerLive(io, ledger.items[stale_i].owner)) {
            ledger.items[stale_i] = ledger.items[ledger.len - 1];
            ledger.len -= 1;
            continue;
        }
        stale_i += 1;
    }
    if (ledger.len < before_len) {
        if (tx) |transaction| {
            if (persistJson(scratch.allocator(), ledger)) |json| transaction.write(json) catch {} else |_| {}
        }
    }
    // A failed `gh pr view` is unknown identity, not "PR N in no repo" (#1344).
    const unresolved = kind == .pull_request and resolved == null and (!builtin.is_test or unresolved_mod.g_force_for_test);
    var target: @import("artifact_claim_target.zig").Target = if (unresolved) unresolved_mod.target(arena, cmd) else if (kind == .pull_request and !builtin.is_test)
        resolved.?
    else
        resolved orelse @import("artifact_claim_target.zig").explicit(cmd, kind) orelse .{ .kind = if (kind == .issue) Kind.issue else Kind.branch, .key = key };
    if (target.kind == .branch and target.key.len == 0) target.key = key;
    for (ledger.slice()) |c| {
        if (!claimRelevant(c.kind, kind)) continue;
        if (unresolved) {
            if (sameOwner(c.owner, me) or !ownerLive(io, c.owner) or unresolved_mod.provablyUnrelated(ledger.slice(), me, c, target)) continue;
            return unresolved_mod.refuseText(arena, c, target);
        }
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

fn resolveRepo(arena: Allocator, io: Io, cwd: []const u8, requested_repo: ?[]const u8) ?[]const u8 {
    if (builtin.is_test and g_test_resolve_cwd) {
        if (requested_repo) |r| {
            if (@import("artifact_repository.zig").valid(r)) return std.ascii.allocLowerString(arena, r) catch null;
        }
        return claim_path.remoteIdentity(arena, io, cwd);
    }
    if (builtin.is_test and requested_repo == null) return null;
    return @import("artifact_repository.zig").resolve(arena, io, cwd, requested_repo) orelse claim_path.remoteIdentity(arena, io, cwd);
}

pub fn handleToolIn(arena: Allocator, io: Io, action: []const u8, kind_s: []const u8, key: []const u8, to_session: []const u8, cwd: []const u8, requested_repo: ?[]const u8) !ExecResult {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    const repo = resolveRepo(arena, io, cwd, requested_repo);
    if (requested_repo != null and repo == null) return .{ .text = "claim repository could not be resolved; no claim changed", .is_error = true };
    const tx = begin(io, scratch.allocator(), cwd, repo) catch return .{ .text = "claim ledger unavailable or busy", .is_error = true };
    defer if (tx) |transaction| transaction.end();
    var local: Ledger = .{};
    const ledger = if (tx != null) &local else &g_ledger;
    const storage = if (tx != null) scratch.allocator() else storeAlloc();
    if (tx) |transaction| loadTransaction(io, transaction, ledger, cwd) catch return .{ .text = "claim ledger unreadable; no claim changed", .is_error = true };
    const kind = kindFrom(kind_s) orelse return .{
        .text = "kind must be branch, issue, commit, pull_request, or publication",
        .is_error = true,
    };
    const me = selfOwner(io);
    if (std.mem.eql(u8, action, "status") and key.len == 0) return .{ .text = try @import("artifact_claim_inventory.zig").status(arena, io, ledger.slice(), me), .is_error = false };
    if (claim_ledger.ambiguous(ledger.slice(), kind, key, repo)) return .{ .text = "claim repository is ambiguous; specify repo explicitly", .is_error = true };
    const existing = claim_ledger.findIn(ledger.slice(), kind, key, repo) orelse
        if (kind == .publication) claim_stale.publicationRecord(ledger.slice(), key, repo) else null;
    const live = if (existing) |c| ownerLive(io, c.owner) else false;
    if (std.mem.eql(u8, action, "claim") or std.mem.eql(u8, action, "acquire")) {
        const msg = claim_ledger.acquireIn(ledger, storage, kind, key, me, 0, live, repo) catch |err| switch (err) {
            error.ClaimHeld => return .{ .text = refuseText(arena, kind, key, existing.?.owner), .is_error = true },
            else => |e| return .{ .text = try @import("artifact_claim_inventory.zig").acquireFail(arena, io, e, ledger.slice(), me), .is_error = true }, // #1614: at capacity, list what can be released
        };
        if (tx) |transaction| transaction.write(try persistJson(scratch.allocator(), ledger)) catch return .{ .text = "claim was NOT persisted; retry before publishing", .is_error = true };
        announceLive(io, scratch.allocator(), ledger);
        return .{ .text = msg, .is_error = false };
    }
    if (std.mem.eql(u8, action, "release")) {
        const existing_owner = if (existing) |c| c.owner else null;
        const recoverable = if (existing_owner) |o| o.pid == 0 and (std.mem.eql(u8, o.session, me.session) or o.session.len == 0) else false;
        const held = existing orelse return .{ .text = "no claim to release", .is_error = false };
        const msg = claim_ledger.releaseIn(ledger, held.kind, held.key, me, live and !recoverable, held.repo orelse repo) catch return .{
            .text = "cannot release a live foreign claim",
            .is_error = true,
        };
        if (tx) |transaction| transaction.write(try persistJson(scratch.allocator(), ledger)) catch return .{ .text = "claim was NOT persisted; retry before publishing", .is_error = true };
        announceLive(io, scratch.allocator(), ledger);
        return .{ .text = msg, .is_error = false };
    }
    if (std.mem.eql(u8, action, "handoff")) {
        if (to_session.len == 0) return .{ .text = "handoff needs session (the receiver)", .is_error = true };
        const receiver = switch (@import("peer_target.zig").resolvePeer(if (builtin.is_test) g_test_peers orelse presence.liveAllPeers(io, arena) else presence.liveAllPeers(io, arena), to_session)) {
            .one => |p| p,
            .none => return .{ .text = "handoff receiver is not a live peer", .is_error = true },
            .ambiguous => return .{ .text = "handoff receiver is ambiguous", .is_error = true },
        };
        const same_workspace = std.mem.eql(u8, receiver.identity, presence.ownIdentity());
        const same_repo = claim_path.sameRepositoryPeer(arena, io, cwd, receiver.identity, repo);
        if (!builtin.is_test and ((!same_workspace and !same_repo) or receiver.start_id == 0))
            return .{ .text = "handoff receiver must have verified identity in this workspace", .is_error = true };
        const probe = proc_identity.probe(io, receiver.pid);
        if (receiver.pid <= 0 or receiver.session_id.len == 0 or proc_identity.ownerState(receiver.start_id, probe) != .held)
            return .{ .text = "handoff receiver is gone", .is_error = true };
        const start_id = switch (probe) {
            .id => |id| id,
            else => receiver.start_id,
        };
        const msg = claim_ledger.handoffIn(ledger, storage, kind, key, me, .{ .session = receiver.session_id, .pid = receiver.pid, .start_id = start_id }, 0, live, repo) catch |err| switch (err) {
            error.ClaimHeld => return .{ .text = "cannot hand off a claim you do not own", .is_error = true },
            error.NoClaim => return .{ .text = "no claim to hand off", .is_error = true },
            else => return .{ .text = "handoff failed", .is_error = true },
        };
        if (tx) |transaction| transaction.write(try persistJson(scratch.allocator(), ledger)) catch return .{ .text = "claim was NOT persisted; retry before publishing", .is_error = true };
        announceLive(io, scratch.allocator(), ledger);
        return .{ .text = msg, .is_error = false };
    }
    if (std.mem.eql(u8, action, "status")) {
        if (existing) |c| {
            const v = claim_ledger.verdictIn(ledger.slice(), c.kind, c.key, me, live, c.repo orelse repo);
            return .{ .text = try std.fmt.allocPrint(arena, "claim {s} {s}: {s} owner=\"{s}\"", .{ @tagName(c.kind), c.key, @tagName(v), c.owner.session }), .is_error = false };
        }
        return .{ .text = "no claim", .is_error = false };
    }
    return .{ .text = "action must be claim, release, handoff, or status", .is_error = true };
}

fn persistPath(io: Io, arena: Allocator, cwd: []const u8, repo: ?[]const u8) ?[]const u8 {
    if (g_persist_path) |p| return p;
    if (builtin.is_test and !g_test_resolve_cwd) return null;
    if ((cwd.len == 0 or std.mem.eql(u8, cwd, ".")) and repo == null) return persist_rel;
    if (claim_path.canonicalFileForRepo(arena, io, cwd, repo)) |p| return p;
    if (builtin.is_test) return null;
    return persist_rel;
}

fn begin(io: Io, arena: Allocator, cwd: []const u8, repo: ?[]const u8) !?@import("repo_transaction.zig").Transaction {
    const path = persistPath(io, arena, cwd, repo) orelse return null;
    return try @import("repo_transaction.zig").Transaction.begin(io, arena, path);
}

fn readSnapshot(io: Io, arena: Allocator, cwd: []const u8) !Ledger {
    const tx = try begin(io, arena, cwd, null);
    defer if (tx) |transaction| transaction.end();
    var ledger: Ledger = .{};
    if (tx) |transaction| try loadTransaction(io, transaction, &ledger, cwd) else return g_ledger;
    return ledger;
}

fn mergeLegacyFile(io: Io, arena: Allocator, ledger: *Ledger, path: []const u8) void {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch return;
    var extra: Ledger = .{};
    loadJson(arena, &extra, text) catch return;
    for (extra.slice()) |c| {
        if (claim_ledger.findIn(ledger.slice(), c.kind, c.key, c.repo) != null) continue;
        if (ledger.len >= max_claims) return;
        ledger.items[ledger.len] = c;
        ledger.len += 1;
    }
}

fn loadTransaction(io: Io, tx: @import("repo_transaction.zig").Transaction, ledger: *Ledger, cwd: []const u8) !void {
    if (try tx.read()) |text| try loadJson(tx.arena, ledger, text);
    if (builtin.is_test and !g_test_resolve_cwd) return;
    if (cwd.len == 0 or std.mem.eql(u8, cwd, ".")) return;
    const legacy = claim_path.legacyFile(tx.arena, cwd) orelse return;
    if (!claim_path.samePath(legacy, tx.path)) mergeLegacyFile(io, tx.arena, ledger, legacy);
}

pub fn reloadForTest(io: Io) !void {
    const path = persistPath(io, storeAlloc(), ".", null) orelse return;
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

test {
    _ = @import("artifact_claim_path.zig");
    _ = @import("artifact_claim_stale.zig");
    _ = @import("artifact_claim_tests.zig");
}
