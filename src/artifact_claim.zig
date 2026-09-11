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

pub const Kind = enum { branch, issue, commit, pull_request, publication };

pub const Owner = struct {
    session: []const u8 = "",
    pid: i32 = 0,
    start_id: u64 = 0,
};

pub const Claim = struct {
    kind: Kind,
    key: []const u8,
    owner: Owner,
    acquired_ms: i64 = 0,
};

pub const Verdict = enum { free, mine, foreign_live, stale };

pub const max_claims = 32;

pub const Ledger = struct {
    items: [max_claims]Claim = undefined,
    len: usize = 0,

    pub fn slice(self: *const Ledger) []const Claim {
        return self.items[0..self.len];
    }
};

pub fn kindFrom(text: []const u8) ?Kind {
    if (std.mem.eql(u8, text, "branch")) return .branch;
    if (std.mem.eql(u8, text, "issue")) return .issue;
    if (std.mem.eql(u8, text, "commit")) return .commit;
    if (std.mem.eql(u8, text, "pull_request") or std.mem.eql(u8, text, "pr")) return .pull_request;
    if (std.mem.eql(u8, text, "publication")) return .publication;
    return null;
}

pub fn sameOwner(a: Owner, b: Owner) bool {
    if (a.session.len > 0 and b.session.len > 0 and std.mem.eql(u8, a.session, b.session)) return true;
    return a.pid != 0 and a.pid == b.pid and a.start_id == b.start_id;
}

fn sameKey(a: Claim, kind: Kind, key: []const u8) bool {
    if (a.kind != kind) return false;
    if (key.len == 0 or a.key.len == 0) return std.mem.eql(u8, a.key, key);
    return std.mem.eql(u8, a.key, key);
}

/// `owner_live` is the caller's probe of the recorded owner. Time passing and
/// an absent pull request are not inputs — only a gone process is stale.
pub fn verdict(claims: []const Claim, kind: Kind, key: []const u8, me: Owner, owner_live: bool) Verdict {
    for (claims) |c| {
        if (!sameKey(c, kind, key)) continue;
        if (sameOwner(c.owner, me)) return .mine;
        return if (owner_live) .foreign_live else .stale;
    }
    return .free;
}

pub fn find(claims: []const Claim, kind: Kind, key: []const u8) ?Claim {
    for (claims) |c| if (sameKey(c, kind, key)) return c;
    return null;
}

pub fn acquire(ledger: *Ledger, arena: Allocator, kind: Kind, key: []const u8, me: Owner, now_ms: i64, owner_live: bool) ![]const u8 {
    switch (verdict(ledger.slice(), kind, key, me, owner_live)) {
        .mine => return "claim already held by this session",
        .foreign_live => return error.ClaimHeld,
        .stale, .free => {},
    }
    var i: usize = 0;
    while (i < ledger.len) {
        if (sameKey(ledger.items[i], kind, key)) {
            ledger.items[i] = .{
                .kind = kind,
                .key = try arena.dupe(u8, key),
                .owner = .{
                    .session = try arena.dupe(u8, me.session),
                    .pid = me.pid,
                    .start_id = me.start_id,
                },
                .acquired_ms = now_ms,
            };
            return "claim acquired (replaced stale owner)";
        }
        i += 1;
    }
    if (ledger.len >= max_claims) return error.ClaimFull;
    ledger.items[ledger.len] = .{
        .kind = kind,
        .key = try arena.dupe(u8, key),
        .owner = .{
            .session = try arena.dupe(u8, me.session),
            .pid = me.pid,
            .start_id = me.start_id,
        },
        .acquired_ms = now_ms,
    };
    ledger.len += 1;
    return "claim acquired";
}

pub fn release(ledger: *Ledger, kind: Kind, key: []const u8, me: Owner, owner_live: bool) ![]const u8 {
    switch (verdict(ledger.slice(), kind, key, me, owner_live)) {
        .free => return "no claim to release",
        .stale => {}, // a live session may clear a dead owner's claim
        .foreign_live => return error.ClaimHeld,
        .mine => {},
    }
    var i: usize = 0;
    while (i < ledger.len) {
        if (sameKey(ledger.items[i], kind, key)) {
            ledger.items[i] = ledger.items[ledger.len - 1];
            ledger.len -= 1;
            return "claim released";
        }
        i += 1;
    }
    return "no claim to release";
}

pub fn handoff(ledger: *Ledger, arena: Allocator, kind: Kind, key: []const u8, from: Owner, to: Owner, now_ms: i64, owner_live: bool) ![]const u8 {
    if (sameOwner(from, to)) return "handoff to self is a no-op";
    switch (verdict(ledger.slice(), kind, key, from, owner_live)) {
        .mine => {},
        .stale => if (!owner_live) {} else return error.ClaimHeld,
        .foreign_live => return error.ClaimHeld,
        .free => return error.NoClaim,
    }
    var i: usize = 0;
    while (i < ledger.len) : (i += 1) {
        if (!sameKey(ledger.items[i], kind, key)) continue;
        ledger.items[i].owner = .{
            .session = try arena.dupe(u8, to.session),
            .pid = to.pid,
            .start_id = to.start_id,
        };
        ledger.items[i].acquired_ms = now_ms;
        return "claim handed off";
    }
    return error.NoClaim;
}

/// Git / GitHub writes that must not proceed under a foreign live claim.
pub fn isClaimedMutation(cmd: []const u8) bool {
    if (@import("presence_mutate.zig").isSharedTreeGit(cmd)) return true;
    var it = std.mem.tokenizeAny(u8, cmd, " \t\r\n;&|\"'`()");
    var saw_git = false;
    var saw_gh = false;
    var saw_pr = false;
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "git")) {
            saw_git = true;
            continue;
        }
        if (saw_git and (std.mem.eql(u8, tok, "push") or std.mem.eql(u8, tok, "commit") or std.mem.eql(u8, tok, "add"))) return true;
        if (std.mem.eql(u8, tok, "gh")) {
            saw_gh = true;
            continue;
        }
        if (saw_gh and std.mem.eql(u8, tok, "pr")) {
            saw_pr = true;
            continue;
        }
        if (saw_pr and (std.mem.eql(u8, tok, "create") or std.mem.eql(u8, tok, "edit") or std.mem.eql(u8, tok, "ready"))) return true;
    }
    return false;
}

pub fn mutationKind(cmd: []const u8) Kind {
    if (std.mem.indexOf(u8, cmd, "gh pr") != null) return .pull_request;
    if (std.mem.indexOf(u8, cmd, "git push") != null) return .publication;
    if (std.mem.indexOf(u8, cmd, "git commit") != null or std.mem.indexOf(u8, cmd, "git add") != null) return .commit;
    return .publication;
}

pub fn refuseText(arena: Allocator, kind: Kind, key: []const u8, owner: Owner) []const u8 {
    return std.fmt.allocPrint(arena, "artifact claim held: {s} {s} is owned by live session \"{s}\" (pid {d}). The action was NOT performed. Acknowledging the shared-tree checkpoint, polling, or finding no pull request does not transfer ownership. The owner must peer_message action=handoff (or action=release) first.", .{ @tagName(kind), if (key.len > 0) key else "(worktree)", owner.session, owner.pid }) catch "artifact claim held: the action was NOT performed";
}

// --- process-global ledger (one worktree, many tests swap it) ---

var g_ledger: Ledger = .{};
var g_test_owner: Owner = .{};
var g_test_live: bool = true;
var g_persist_path: ?[]const u8 = null;
var g_loaded: bool = false;
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
    g_loaded = true; // tests start with an empty in-memory ledger
    if (g_store) |*st| {
        st.deinit();
        g_store = null;
    }
}

pub fn setPersistPath(path: []const u8) void {
    g_persist_path = path;
    g_loaded = false;
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

pub fn selfOwner() Owner {
    if (g_test_owner.session.len > 0 or g_test_owner.pid != 0) return g_test_owner;
    return .{
        .session = presence.ownSession(),
        .pid = proc_identity.selfPid(),
        .start_id = 0,
    };
}

fn ownerLive(io: Io, owner: Owner) bool {
    if (g_test_owner.session.len > 0 or g_test_owner.pid != 0) {
        if (sameOwner(owner, g_test_owner)) return true;
        return g_test_live;
    }
    if (owner.pid == 0) return true;
    return proc_identity.probe(io, owner.pid) != .gone;
}

fn claimRelevant(held: Kind, mutation: Kind) bool {
    if (held == mutation or held == .publication) return true;
    return switch (mutation) {
        .pull_request => held == .branch or held == .commit,
        .publication => held == .branch or held == .pull_request or held == .commit,
        .commit => held == .branch,
        else => false,
    };
}

pub fn gateCommand(arena: Allocator, io: Io, cmd: []const u8, key: []const u8) ?[]const u8 {
    if (!isClaimedMutation(cmd)) return null;
    ensureLoaded(io);
    const kind = mutationKind(cmd);
    const me = selfOwner();
    if (key.len == 0) {
        for (g_ledger.slice()) |c| {
            if (!claimRelevant(c.kind, kind)) continue;
            const live = ownerLive(io, c.owner);
            if (verdict(g_ledger.slice(), c.kind, c.key, me, live) == .foreign_live)
                return refuseText(arena, c.kind, c.key, c.owner);
        }
        return null;
    }
    const existing = find(g_ledger.slice(), kind, key) orelse find(g_ledger.slice(), .publication, key);
    const check_kind = if (existing) |c| c.kind else kind;
    const check_key = if (existing) |c| c.key else key;
    const held = find(g_ledger.slice(), check_kind, check_key) orelse return null;
    const live = ownerLive(io, held.owner);
    return switch (verdict(g_ledger.slice(), check_kind, check_key, me, live)) {
        .foreign_live => refuseText(arena, check_kind, check_key, held.owner),
        else => null,
    };
}

pub fn handleTool(arena: Allocator, io: Io, action: []const u8, kind_s: []const u8, key: []const u8, to_session: []const u8) !ExecResult {
    ensureLoaded(io);
    const kind = kindFrom(kind_s) orelse return .{
        .text = "kind must be branch, issue, commit, pull_request, or publication",
        .is_error = true,
    };
    const me = selfOwner();
    const now: i64 = 0;
    const existing = find(g_ledger.slice(), kind, key);
    const live = if (existing) |c| ownerLive(io, c.owner) else false;
    if (std.mem.eql(u8, action, "claim") or std.mem.eql(u8, action, "acquire")) {
        const msg = acquire(&g_ledger, storeAlloc(), kind, key, me, now, live) catch |err| switch (err) {
            error.ClaimHeld => return .{ .text = refuseText(arena, kind, key, existing.?.owner), .is_error = true },
            else => return .{ .text = "claim acquire failed", .is_error = true },
        };
        flush(io);
        return .{ .text = msg, .is_error = false };
    }
    if (std.mem.eql(u8, action, "release")) {
        const msg = release(&g_ledger, kind, key, me, live) catch return .{
            .text = "cannot release a live foreign claim",
            .is_error = true,
        };
        flush(io);
        return .{ .text = msg, .is_error = false };
    }
    if (std.mem.eql(u8, action, "handoff")) {
        if (to_session.len == 0) return .{ .text = "handoff needs session (the receiver)", .is_error = true };
        const msg = handoff(&g_ledger, storeAlloc(), kind, key, me, .{ .session = to_session }, now, live) catch |err| switch (err) {
            error.ClaimHeld => return .{ .text = "cannot hand off a claim you do not own", .is_error = true },
            error.NoClaim => return .{ .text = "no claim to hand off", .is_error = true },
            else => return .{ .text = "handoff failed", .is_error = true },
        };
        flush(io);
        return .{ .text = msg, .is_error = false };
    }
    if (std.mem.eql(u8, action, "status")) {
        if (existing) |c| {
            const v = verdict(g_ledger.slice(), kind, key, me, live);
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

fn ensureLoaded(io: Io) void {
    if (g_loaded) return;
    g_loaded = true;
    const path = persistPath() orelse return;
    const text = Io.Dir.cwd().readFileAlloc(io, path, storeAlloc(), .limited(64 * 1024)) catch return;
    loadJson(storeAlloc(), &g_ledger, text) catch {
        g_ledger.len = 0;
    };
}

fn flush(io: Io) void {
    const path = persistPath() orelse return;
    const json = persistJson(storeAlloc(), &g_ledger) catch return;
    if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json }) catch {};
}

pub fn persistJson(arena: Allocator, ledger: *const Ledger) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginArray();
    for (ledger.slice()) |c| {
        try s.beginObject();
        try s.objectField("kind");
        try s.write(@tagName(c.kind));
        try s.objectField("key");
        try s.write(c.key);
        try s.objectField("session");
        try s.write(c.owner.session);
        try s.objectField("pid");
        try s.write(c.owner.pid);
        try s.objectField("start_id");
        try s.write(c.owner.start_id);
        try s.endObject();
    }
    try s.endArray();
    return aw.writer.buffered();
}

pub fn loadJson(arena: Allocator, ledger: *Ledger, text: []const u8) !void {
    ledger.len = 0;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return;
    if (parsed != .array) return;
    for (parsed.array.items) |item| {
        if (item != .object) continue;
        const kind_s = if (item.object.get("kind")) |v| (if (v == .string) v.string else continue) else continue;
        const kind = kindFrom(kind_s) orelse continue;
        const key = if (item.object.get("key")) |v| (if (v == .string) v.string else "") else "";
        const session = if (item.object.get("session")) |v| (if (v == .string) v.string else "") else "";
        const pid: i32 = if (item.object.get("pid")) |v| (if (v == .integer) @intCast(v.integer) else 0) else 0;
        const start_id: u64 = if (item.object.get("start_id")) |v| (if (v == .integer and v.integer >= 0) @intCast(v.integer) else 0) else 0;
        if (ledger.len >= max_claims) break;
        ledger.items[ledger.len] = .{
            .kind = kind,
            .key = try arena.dupe(u8, key),
            .owner = .{ .session = try arena.dupe(u8, session), .pid = pid, .start_id = start_id },
        };
        ledger.len += 1;
    }
}

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
    try std.testing.expect(isClaimedMutation("git add -A"));
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
    const ho = try handleTool(ar, std.testing.io, "handoff", "publication", "feat/x", "s-other");
    try std.testing.expect(!ho.is_error);
    setTestOwner(.{ .session = "s-other", .pid = 12, .start_id = 2 });
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
    try std.testing.expect(gateCommand(ar, std.testing.io, "git commit -m wip", "") != null);
}

test "file persist reloads after a resume-shaped reset" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const io = std.testing.io;
    const file = "zig-cache/artifact-claims-persist-test.json";
    Io.Dir.cwd().deleteFile(io, file) catch {};
    defer Io.Dir.cwd().deleteFile(io, file) catch {};
    resetForTest();
    defer resetForTest();
    setPersistPath(file);
    g_loaded = true;
    setTestOwner(.{ .session = "s-persist", .pid = 4, .start_id = 9 });
    _ = try handleTool(ar, io, "claim", "publication", "feat/x", "");
    g_ledger.len = 0;
    g_loaded = false;
    ensureLoaded(io);
    try std.testing.expectEqual(@as(usize, 1), g_ledger.len);
    try std.testing.expectEqualStrings("feat/x", g_ledger.items[0].key);
    try std.testing.expectEqualStrings("s-persist", g_ledger.items[0].owner.session);
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
