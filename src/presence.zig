//! Cross-session presence registry (#469): disk + lifecycle for worktree_lease.
//! Each root session writes pid + start-id + worktree identity + goal into
//! ~/.graff/live; liveness is probed via proc_identity, never the file.
//! announce/retire/goal are wired into session_run + goal_flow. The first
//! shared-tree mutation against a live peer checkpoints once. No locking.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const proc_identity = @import("proc_identity.zig");
const worktree_lease = @import("worktree_lease.zig");
const util = @import("util.zig");
const main_mod = @import("main.zig"); // `unattended`: one-shots join channel rooms at the tail, not the backlog

const unixMs = util.unixMs;
const presence_mutate = @import("presence_mutate.zig");
const no_local_tools = @import("no_local_tools.zig");
const presence_record = @import("presence_record.zig");

const Owner = worktree_lease.Owner;
pub const formatRecord = presence_record.formatRecord;
pub const parseRecord = presence_record.parseRecord;

pub const isSharedTreeGit = presence_mutate.isSharedTreeGit;
pub const isSharedTreeShell = presence_mutate.isSharedTreeShell;

/// Per-user registry: <home>/.graff/live. Deliberately NOT the per-project .graff/sessions of session_index.zig — presence is device-local and keyed by worktree identity so two checkouts of one repo stay distinct (#320).
pub const registry_subdir = ".graff/live";

const max_peers = 16;
const record_max = 4096;

/// A directory listing's worth of records with each pid's OS probe aligned —
/// the exact pair duplicateOwner/ownerVerdict consume.
pub const Peers = struct {
    records: []const Owner,
    probes: []const proc_identity.Probe,
};

/// Read every record in `dir`, probe each pid, reap the provably dead, and
/// return the survivors. Best-effort throughout: an unreadable registry means
/// "no peers", never an error propagated into a tool call.
pub fn listPeers(io: Io, arena: Allocator, dir: Io.Dir) Peers {
    return listPeersBounded(io, arena, dir, max_peers);
}

pub fn listPeersBounded(io: Io, arena: Allocator, dir: Io.Dir, limit: usize) Peers {
    var records: std.ArrayList(Owner) = .empty;
    var probes: std.ArrayList(proc_identity.Probe) = .empty;
    var d = dir;
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (records.items.len >= @min(limit, 128)) break;
        const text = d.readFileAlloc(io, entry.name, arena, .limited(record_max)) catch continue;
        const rec = parseRecord(arena, text) orelse continue;
        const live = proc_identity.probe(io, rec.pid);
        if (live == .gone) {
            // Provably dead (#413): reap on read so the registry self-cleans
            // even when the owner crashed without retire().
            @import("subagent_activity.zig").cleanup(io, d, rec.pid, rec.start_id);
            d.deleteFile(io, entry.name) catch {};
            continue;
        }
        records.append(arena, rec) catch break;
        probes.append(arena, live) catch break;
    }
    return .{ .records = records.items, .probes = probes.items };
}

/// One stable key per (pid, start identity) — what a checkpoint acknowledgment
/// is remembered by. Start identity, not pid alone: a reused pid must read as
/// a NEW peer, not an already-acked one (#320's whole point).
pub fn ackKey(rec: Owner) u64 {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}:{d}", .{ rec.pid, rec.start_id }) catch unreachable;
    return std.hash.Wyhash.hash(0, text);
}

/// The first live foreign co-owner of `my_identity` that has not been
/// acknowledged yet, if any. Pure: the probe results and the ack set are the
/// caller's, so tests need no processes and no filesystem.
pub fn unackedPeer(peers: Peers, my_identity: []const u8, my_pid: i32, acked: []const u64) ?Owner {
    for (peers.records, 0..) |rec, i| {
        if (i >= peers.probes.len) break;
        switch (worktree_lease.ownerVerdict(rec, my_identity, my_pid, peers.probes[i])) {
            .live_foreign, .live_unverified => {
                const key = ackKey(rec);
                var seen = false;
                for (acked) |k| {
                    if (k == key) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) return rec;
            },
            else => {},
        }
    }
    return null;
}

// --- wired layer: one root session per process, so module state is the
// registry handle. announce is the ONLY writer of this state; retire/noteGoal/
// gateCheck no-op when it never ran (tests, subagents, homeless runs). ---

var g_dir: ?[]const u8 = null; // gpa-owned registry dir path
var g_identity: []const u8 = ""; // gpa-owned own worktree identity
var g_own_name: ?[]const u8 = null; // gpa-owned own record's file name
var g_session: []const u8 = ""; // gpa-owned session id, for rewrites
var g_title: []const u8 = ""; // gpa-owned visible title (#700)
var g_session_base: []const u8 = ""; // gpa-owned saved-session slug (#700)
var g_goal: []const u8 = ""; // last-known goal (session-arena-owned is fine: both outlive the session)
var g_self: proc_identity.Record = .{}; // own pid + start-id, settled by announce
var g_chan: ?[]const u8 = null; // gpa-owned channel file name (hash of g_identity)
var g_inbox_off: u64 = 0; // bytes of the shared channel already delivered
var g_device_off: u64 = 0; // bytes of the device-wide room already delivered
var g_tail_seeked: bool = false; // one-shots fast-forward both rooms exactly once (empty room at join must not re-skip later arrivals)
var g_acked: [max_peers]u64 = undefined;
var g_acked_len: usize = 0;

var g_activity: []const u8 = "waiting";
pub fn noteActivity(io: Io, arena: Allocator, working: bool) void {
    g_activity = if (working) "working" else "waiting";
    writeOwn(io, arena);
}

fn writeOwn(io: Io, arena: Allocator) void {
    const dir_path = g_dir orelse return;
    const name = g_own_name orelse return;
    var owner = worktree_lease.selfOwner(io, g_identity, g_session, unixMs(io));
    owner.goal = g_goal;
    owner.activity = g_activity;
    owner.title = g_title;
    owner.session_base = g_session_base;
    const text = formatRecord(arena, owner) catch return;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{}) catch return;
    defer dir.close(io);
    dir.writeFile(io, .{ .sub_path = name, .data = text }) catch {};
}

/// Register this root session and report any LIVE co-owner already present —
/// the #469 "see each other before, not mid-collision" moment. Returns the
/// owner for the caller to surface (null = alone, or registry unavailable).
/// Never fails a session: every failure mode degrades to silence, because
/// presence must never be the reason graff did not start.
pub fn announce(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, session_id: []const u8, goal: []const u8) ?Owner {
    if (builtin.is_test) return null; // tests get the parameterized store, never the real registry
    // -p / --lean one-shots (evals) live in sibling sandboxes inside the
    // harness repo. git rev-parse walks up to that repo, so parallel -j N
    // sessions share one identity and checkpoint every edit (ADR 0024 SWE).
    if (no_local_tools.lean) return null;
    if (home.len == 0) return null;
    const dir_path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ home, registry_subdir }) catch return null;
    var dir_owned = true; // deinit frees only what the globals point at, so every bail before `g_dir` is set owns dir_path — it used to leak (#549)
    defer if (dir_owned) gpa.free(dir_path);
    Io.Dir.cwd().createDirPath(io, dir_path) catch return null;
    const identity = worktree_lease.currentIdentity(gpa, io, arena);
    if (identity.id.len == 0) return null;
    const self = proc_identity.selfRecord(io);
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{d}-{x}.json", .{ self.pid, self.start_id }) catch return null;
    g_dir = dir_path;
    dir_owned = false;
    g_identity = gpa.dupe(u8, identity.id) catch return null;
    g_session = gpa.dupe(u8, session_id) catch "";
    g_goal = gpa.dupe(u8, goal) catch "";
    g_self = self;
    var chan_buf: [chan_name_max]u8 = undefined;
    g_chan = gpa.dupe(u8, chanName(&chan_buf, g_identity)) catch null;
    g_own_name = gpa.dupe(u8, name) catch return null;
    // Peer check BEFORE writing our own record: the callout describes the tree as it was when we arrived.
    const duplicate = blk: {
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch break :blk null;
        defer dir.close(io);
        const peers = listPeers(io, arena, dir);
        break :blk worktree_lease.duplicateOwner(peers.records, peers.probes, g_identity, self.pid);
    };
    writeOwn(io, arena);
    return duplicate;
}

pub fn rebind(io: Io, gpa: Allocator, arena: Allocator) void {
    if (builtin.is_test or g_own_name == null) return;
    const identity = worktree_lease.currentIdentity(gpa, io, arena);
    if (identity.id.len == 0 or std.mem.eql(u8, identity.id, g_identity)) return;
    if (g_identity.len > 0) gpa.free(g_identity);
    g_identity = gpa.dupe(u8, identity.id) catch return;
    if (g_chan) |c| gpa.free(c);
    var chan_buf: [chan_name_max]u8 = undefined;
    g_chan = gpa.dupe(u8, chanName(&chan_buf, g_identity)) catch null;
    g_inbox_off = 0;
    if (g_dir) |dir_path| if (g_chan) |chan| {
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{}) catch {
            writeOwn(io, arena);
            return;
        };
        defer dir.close(io);
        if (dir.readFileAlloc(io, chan, arena, .limited(16 * 1024 * 1024)) catch null) |text|
            g_inbox_off = @intCast(text.len);
    };
    writeOwn(io, arena);
}

/// retire is hygiene; deinit frees gpa-owned globals for the exit leak check.
pub fn deinit(gpa: Allocator) void {
    if (g_dir) |p| gpa.free(p);
    if (g_identity.len > 0) gpa.free(g_identity);
    if (g_session.len > 0) gpa.free(g_session);
    if (g_title.len > 0) gpa.free(g_title);
    if (g_session_base.len > 0) gpa.free(g_session_base);
    if (g_goal.len > 0) gpa.free(g_goal);
    if (g_own_name) |n| gpa.free(n);
    if (g_chan) |c| gpa.free(c);
    g_dir = null;
    g_identity = "";
    g_session = "";
    g_title = "";
    g_session_base = "";
    g_goal = "";
    g_own_name = null;
    g_chan = null;
    g_self = .{};
    g_inbox_off = 0;
    g_device_off = 0;
    g_tail_seeked = false;
    g_acked_len = 0;
}

pub fn retire(io: Io) void {
    const dir_path = g_dir orelse return;
    const name = g_own_name orelse return;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{}) catch return;
    defer dir.close(io);
    @import("subagent_activity.zig").cleanup(io, dir, g_self.pid, g_self.start_id);
    dir.deleteFile(io, name) catch {};
    // The shared channel is NOT ours to delete: co-resident sessions may still be mid-drain, and its bytes are the room's history.
}

/// Refresh our record's goal — the coordination payload a peer's checkpoint
/// prints. Only the goal_flow setters call this; a cleared goal keeps the
/// last-known text rather than going blank mid-supersession. The goal is
/// re-duped onto the gpa (freeing the previous) so g_goal stays gpa-owned —
/// deinit frees it, and the caller's slice is usually session-arena memory.
pub fn noteGoal(io: Io, gpa: Allocator, arena: Allocator, goal: []const u8) void {
    if (g_own_name == null) return; // never announced (tests, subagents): io may be undefined — touch nothing
    const owned = gpa.dupe(u8, goal) catch return;
    if (g_goal.len > 0) gpa.free(g_goal);
    g_goal = owned;
    writeOwn(io, arena);
}

/// Refresh the visible title and saved-session base (#700). Empty title is
/// honest (pre-title sessions). session_base is the durable file slug; when
/// set it also becomes the live session_id so a rename is addressable.
pub fn noteLabels(io: Io, gpa: Allocator, arena: Allocator, title: []const u8, session_base: []const u8) void {
    if (g_own_name == null) return;
    const owned_title = gpa.dupe(u8, title) catch return;
    const owned_base = gpa.dupe(u8, session_base) catch {
        gpa.free(owned_title);
        return;
    };
    if (g_title.len > 0) gpa.free(g_title);
    if (g_session_base.len > 0) gpa.free(g_session_base);
    g_title = owned_title;
    g_session_base = owned_base;
    if (session_base.len > 0) {
        const owned_session = gpa.dupe(u8, session_base) catch {
            writeOwn(io, arena);
            return;
        };
        if (g_session.len > 0) gpa.free(g_session);
        g_session = owned_session;
    }
    writeOwn(io, arena);
}

pub fn noteLabelsFrom(io: Io, gpa: Allocator, arena: Allocator, title: ?[]const u8, session_base: []const u8) void {
    noteLabels(io, gpa, arena, title orelse "", session_base);
}

/// The tool-gate half (#469): null = no unacknowledged live co-owner, else the
/// checkpoint text the model sees as its (un-executed) tool result. Seeing a
/// peer ACKs it, so the re-issued command runs and one process checkpoints at
/// most once per peer — awareness is the goal, not a tollbooth.
pub fn gateCheck(io: Io, arena: Allocator) ?[]const u8 {
    if (no_local_tools.lean) return null;
    const dir_path = g_dir orelse return null;
    if (g_identity.len == 0) return null;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    const peers = listPeers(io, arena, dir);
    const peer = unackedPeer(peers, g_identity, proc_identity.selfPid(), g_acked[0..g_acked_len]) orelse return null;
    if (g_acked_len < g_acked.len) {
        g_acked[g_acked_len] = ackKey(peer);
        g_acked_len += 1;
    }
    const warning = worktree_lease.duplicateOwnerWarning(arena, peer, unixMs(io) - peer.last_seen_ms);
    return std.fmt.allocPrint(arena, "{s}shared-tree checkpoint: the action was NOT performed. Re-issue the identical call to proceed — this fires once per live peer, across git mutations, file writes, and shell moves alike — coordinate first via the peer_message tool (session \"{s}\"), or keep your edits disjoint from theirs.", .{ warning, peer.session_id }) catch warning;
}

// The channel's wire format (Message, chanName, postMessage, readNewMessages)
// lives in presence_chan.zig — split out under the 600-line ceiling. This file
// keeps the wired layer: which dir/name/offset a LIVE session uses.

const presence_chan = @import("presence_chan.zig");
pub const Message = presence_chan.Message;
const chanName = presence_chan.chanName;
const isOwn = presence_chan.isOwn;
const chan_name_max = presence_chan.chan_name_max;

/// The live co-owners of MY worktree: every registry record whose verdict is
/// live_foreign/live_unverified. The sender's target list for peer_message
/// and /tell; already probed, with the provably dead reaped.
pub fn liveTreePeers(io: Io, arena: Allocator) []const Owner {
    const dir_path = g_dir orelse return &.{};
    if (g_identity.len == 0) return &.{};
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    const peers = listPeers(io, arena, dir);
    var live: std.ArrayList(Owner) = .empty;
    for (peers.records, 0..) |rec, i| {
        if (i >= peers.probes.len) break;
        switch (worktree_lease.ownerVerdict(rec, g_identity, g_self.pid, peers.probes[i])) {
            .live_foreign, .live_unverified => live.append(arena, rec) catch break,
            else => {},
        }
    }
    return live.items;
}

/// Post to the shared worktree channel, stamped with OUR record. `to` names
/// the intended recipient (session substring or pid) and is metadata only —
/// every co-resident session hears the line. false when this session never
/// announced (tests, subagents) or the write failed.
pub fn postTo(io: Io, arena: Allocator, text: []const u8, to: []const u8) bool {
    const dir_path = g_dir orelse return false;
    const chan = g_chan orelse return false;
    if (g_self.pid == 0) return false;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{}) catch return false;
    defer dir.close(io);
    return presence_chan.postMessage(io, arena, dir, chan, .{
        .from_pid = g_self.pid,
        .from_start = g_self.start_id,
        .from_session = g_session,
        .from_goal = g_goal,
        .to = to,
        .ts_ms = unixMs(io),
        .text = text,
    });
}

/// Drain the shared channel: every complete message since our last drain,
//  minus our own echo. Empty when unannounced or caught up. A session that
/// joins late hears the whole backlog once — but peer_channel.deliverInbound
/// tail-caps that first drain (backlog_tail_max) with an omitted-count marker.
/// EXCEPTION: a -p one-shot joins, works, and exits
/// inside a minute — the backlog is context it cannot use (measured ~4k
/// tokens of stale chatter injected on the first step of every benchmark
/// one-shot — and it made ephemeral workers ANSWER old messages, burning
/// turns on coordination theater). Unattended sessions start at the tail:
/// they hear what arrives while they run, not what predates them.
pub fn drainChannel(io: Io, arena: Allocator) []const Message {
    const dir_path = g_dir orelse return &.{};
    const chan = g_chan orelse return &.{};
    if (g_self.pid == 0) return &.{};
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{}) catch return &.{};
    defer dir.close(io);
    if (main_mod.unattended and !g_tail_seeked) {
        g_tail_seeked = true;
        if (dir.readFileAlloc(io, chan, arena, .limited(16 * 1024 * 1024)) catch null) |text| g_inbox_off = @intCast(text.len);
        // The device room too: deliverInbound always drains the worktree
        // channel first, so one fast-forward covers both rooms.
        if (dir.readFileAlloc(io, device_room, arena, .limited(16 * 1024 * 1024)) catch null) |text| g_device_off = @intCast(text.len);
    }
    const raw = presence_chan.readNewMessages(io, arena, dir, chan, &g_inbox_off);
    var out: std.ArrayList(Message) = .empty;
    for (raw) |m| {
        if (!isOwn(m, g_self.pid, g_self.start_id)) out.append(arena, m) catch break;
    }
    return out.items;
}

pub fn registryPath() ?[]const u8 {
    return g_dir;
}

pub fn ownSession() []const u8 {
    return g_session;
}

pub fn ownIdentity() []const u8 {
    return g_identity;
}

// --- the device-wide room (#469: "or just the same device"): one more log
// every announced session drains, regardless of worktree. Worktree rooms stay
// the default for coordination chatter; this one carries /tell all broadcasts
// and messages addressed to a session in another folder. ---

pub const device_room = "chan-all.jsonl";

/// Byte cursors into the worktree and device JSONL rooms. Persist these on
/// the session file so `/resume` continues instead of re-hearing the tail
/// (ADR 0014). Codex keeps a thread cursor; Claude persists the inbox.
pub const RoomCursor = struct { chan: u64, device: u64 };

pub fn roomCursor() RoomCursor {
    return .{ .chan = g_inbox_off, .device = g_device_off };
}

pub fn adoptRoomCursor(c: RoomCursor) void {
    g_inbox_off = c.chan;
    g_device_off = c.device;
    g_tail_seeked = true;
}

/// Join at the live tail — same as a `-p` one-shot. Used when a resumed
/// session has no saved cursor (legacy file) so we do not replay stale room.
pub fn seekRoomsToTail(io: Io, arena: Allocator) void {
    const dir_path = g_dir orelse {
        g_tail_seeked = true;
        return;
    };
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{}) catch {
        g_tail_seeked = true;
        return;
    };
    defer dir.close(io);
    if (g_chan) |chan| {
        if (dir.readFileAlloc(io, chan, arena, .limited(16 * 1024 * 1024)) catch null) |text|
            g_inbox_off = @intCast(text.len);
    }
    if (dir.readFileAlloc(io, device_room, arena, .limited(16 * 1024 * 1024)) catch null) |text|
        g_device_off = @intCast(text.len);
    g_tail_seeked = true;
}

pub fn resetRoomCursorForTest() void {
    g_inbox_off = 0;
    g_device_off = 0;
    g_tail_seeked = false;
}

/// Tests only. `announce` is a no-op under `is_test`; this wires the same
/// process-local handle so `postTo` / `postToDevice` can write a tmp registry.
/// Caller owns the slices — do not `deinit` after this; call `unbindForTest`.
pub fn bindForTest(dir_path: []const u8, identity: []const u8, session: []const u8, self: proc_identity.Record) void {
    g_dir = dir_path;
    g_identity = identity;
    g_session = session;
    g_self = self;
}

pub fn unbindForTest() void {
    g_dir = null;
    g_identity = "";
    g_session = "";
    g_self = .{};
    resetRoomCursorForTest();
}

/// Every live session on this device, any worktree (self excluded) — the
/// /tell target list. Like liveTreePeers but identity-blind.
pub fn liveAllPeers(io: Io, arena: Allocator) []const Owner {
    const dir_path = g_dir orelse return &.{};
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    const peers = listPeers(io, arena, dir);
    var live: std.ArrayList(Owner) = .empty;
    for (peers.records, 0..) |rec, i| {
        if (i >= peers.probes.len) break;
        if (rec.pid == g_self.pid) continue;
        switch (peers.probes[i]) {
            .gone => {},
            else => live.append(arena, rec) catch break,
        }
    }
    return live.items;
}

/// Post to the device-wide room. Delivery there is addressed-only: heard when
/// `to` names the session or the USER posted it (/tell sets from_user).
pub fn postToDevice(io: Io, arena: Allocator, text: []const u8, to: []const u8, from_user: bool) bool {
    const dir_path = g_dir orelse return false;
    if (g_self.pid == 0) return false;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{}) catch return false;
    defer dir.close(io);
    return presence_chan.postMessage(io, arena, dir, device_room, .{
        .from_pid = g_self.pid,
        .from_start = g_self.start_id,
        .from_session = g_session,
        .from_goal = g_goal,
        .to = to,
        .ts_ms = unixMs(io),
        .text = text,
        .from_user = from_user,
    });
}

/// Drain the device-wide room (own echo skipped), same offset discipline as
/// the worktree channel.
pub fn drainDevice(io: Io, arena: Allocator) []const Message {
    const dir_path = g_dir orelse return &.{};
    if (g_self.pid == 0) return &.{};
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{}) catch return &.{};
    defer dir.close(io);
    const raw = presence_chan.readNewMessages(io, arena, dir, device_room, &g_device_off);
    var out: std.ArrayList(Message) = .empty;
    for (raw) |m| {
        if (!isOwn(m, g_self.pid, g_self.start_id)) out.append(arena, m) catch break;
    }
    return out.items;
}

test "roomCursor adopt/reset: resume continues from the saved byte offset" {
    resetRoomCursorForTest();
    defer resetRoomCursorForTest();
    adoptRoomCursor(.{ .chan = 4096, .device = 128 });
    const cur = roomCursor();
    try std.testing.expectEqual(@as(u64, 4096), cur.chan);
    try std.testing.expectEqual(@as(u64, 128), cur.device);
    resetRoomCursorForTest();
    try std.testing.expectEqual(@as(u64, 0), roomCursor().chan);
}

test "listPeers: probes liveness, reaps the provably dead, keeps the alive" {
    // Windows: the live self-record probes .gone on the runner (OpenProcess on own pid fails there) — skip until diagnosed on a real Windows box.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const self = proc_identity.selfRecord(io);
    const alive: Owner = .{ .pid = self.pid, .start_id = self.start_id, .session_id = "s-live", .identity = "/x/.git", .goal = "g" };
    try tmp.dir.writeFile(io, .{ .sub_path = "live.json", .data = try formatRecord(arena, alive) });
    // pid -7 can never hold a process (probe: pid <= 0 is .gone), so the reap path is exercised identically on every platform.
    const dead: Owner = .{ .pid = -7, .start_id = 1, .session_id = "s-dead", .identity = "/x/.git" };
    try tmp.dir.writeFile(io, .{ .sub_path = "dead.json", .data = try formatRecord(arena, dead) });
    // Reopen with .iterate: tmpDir's handle isn't iteration-capable on the Linux backend (dirRead seeks an O_PATH fd → EBADF panic, the CI crash).
    var idir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer idir.close(io);
    const peers = listPeers(io, arena, idir);
    try std.testing.expectEqual(1, peers.records.len);
    try std.testing.expectEqualStrings("s-live", peers.records[0].session_id);
    var buf: [16]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFile(io, "dead.json", &buf));
}

test "unackedPeer: returns the live foreign co-owner once, then yields to the ack" {
    const my_identity = "/repo/.git";
    const foreign: Owner = .{ .pid = 4242, .start_id = 99, .session_id = "s-b", .identity = "/repo/.git", .goal = "theirs" };
    const other_tree: Owner = .{ .pid = 4343, .start_id = 98, .session_id = "s-c", .identity = "/repo/.git/worktrees/wt1" };
    const records = [_]Owner{ other_tree, foreign };
    const probes = [_]proc_identity.Probe{ .{ .id = 98 }, .{ .id = 99 } };
    const peers: Peers = .{ .records = &records, .probes = &probes };
    const found = unackedPeer(peers, my_identity, 1, &.{}) orelse return error.ExpectedPeer;
    try std.testing.expectEqualStrings("s-b", found.session_id);
    const key = ackKey(found);
    try std.testing.expect(unackedPeer(peers, my_identity, 1, &.{key}) == null);
    // A new session reusing that pid is a NEW peer, not an acked one.
    const reused: Owner = .{ .pid = 4242, .start_id = 100, .session_id = "s-d", .identity = "/repo/.git" };
    const records2 = [_]Owner{reused};
    const probes2 = [_]proc_identity.Probe{.{ .id = 100 }};
    try std.testing.expect(unackedPeer(.{ .records = &records2, .probes = &probes2 }, my_identity, 1, &.{key}) != null);
}

test "lean one-shots skip the shared-tree checkpoint" {
    const saved = no_local_tools.lean;
    defer no_local_tools.lean = saved;
    no_local_tools.lean = true;
    try std.testing.expect(gateCheck(std.testing.io, std.testing.allocator) == null);
}
