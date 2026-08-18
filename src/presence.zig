//! Cross-session presence registry (#469): the disk + lifecycle half that
//! worktree_lease.zig's pure #320 logic never got wired to. Every root session
//! writes a small owner record (pid + start identity + worktree identity +
//! current goal) into the per-user registry at birth and removes it at exit.
//! Liveness is PROBED via proc_identity (#413), never trusted from the file,
//! so a crashed session's record reaps itself on the next read — no heartbeat
//! thread, no reaper daemon.
//!
//! Adherence is structural, not prompt-level:
//!   - announce/retire/goal updates are wired into session_run + goal_flow, so
//!     a session cannot forget to register;
//!   - agent_tool_gate refuses the FIRST index/worktree-mutating git command
//!     issued while a live foreign session co-owns this worktree — under
//!     --yolo too, where no approvals prompt exists — until the command is
//!     re-issued. That re-issue is the deliberate acknowledgment the #469
//!     incident (two --yolo sessions, one staging renames under the other)
//!     never had a chance to make.
//!
//! No locking, no arbitration (#469 v1 non-goals): the registry carries
//! presence + intent; humans and agents still serialize the work.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const proc_identity = @import("proc_identity.zig");
const worktree_lease = @import("worktree_lease.zig");
const util = @import("util.zig");
const main_mod = @import("main.zig"); // `unattended`: one-shots join channel rooms at the tail, not the backlog

const unixMs = util.unixMs;

const Owner = worktree_lease.Owner;

/// Per-user registry: <home>/.graff/live. Deliberately NOT the per-project .graff/sessions of session_index.zig — presence is device-local and keyed by worktree identity so two checkouts of one repo stay distinct (#320).
pub const registry_subdir = ".graff/live";

const max_peers = 16;
const record_max = 4096;

/// Git subcommands that mutate the index, refs, or working tree — the shared state the #469 collision tore up. Read-only git (status/log/diff) and remote-only git (fetch/push) stay ungated: the checkpoint exists because two sessions edit ONE uncommitted tree, not because git ran.
fn isSharedTreeSubcommand(sub: []const u8) bool {
    const subs = [_][]const u8{
        "add",     "rm",       "mv",           "commit", "reset",
        "restore", "checkout", "switch",       "stash",  "pull",
        "rebase",  "merge",    "cherry-pick",  "revert", "am",
        "apply",   "clean",    "update-index",
    };
    for (subs) |s| if (std.mem.eql(u8, sub, s)) return true;
    return false;
}

/// Whether `cmd` runs an index/tree-mutating git subcommand. Tokenizes on
/// shell separators so `cd x && git add -A` and `sh -c 'git rm y'` classify by
/// the subcommand, and skips git's global options so `git -C repo reset` is
/// seen as `reset`. A quoted "git add" inside an echo string is a known false
/// positive — the cost is one needless checkpoint line, the same trade
/// harness_policy.isDestructiveGit makes for its substring scan.
pub fn isSharedTreeGit(cmd: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, cmd, " \t\r\n;&|\"'`()");
    while (it.next()) |tok| {
        if (!std.mem.eql(u8, tok, "git")) continue;
        while (it.next()) |arg| {
            if (arg[0] == '-') {
                // -C/-c take the NEXT token as their value; skip it too.
                if (std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "-c")) _ = it.next();
                continue;
            }
            return isSharedTreeSubcommand(arg);
        }
        return false; // a bare `git` mutates nothing
    }
    return false;
}

/// The shell half of the #469 incident vector: `mv` (any form — a rename can
/// disappear a file a peer just wrote) and recursive `rm`. Plain `rm` of one
/// file stays ungated: the checkpoint exists for tree-level disruption, and
/// it fires once per peer regardless, so the odd false positive costs one
/// line, never a workflow.
pub fn isSharedTreeShell(cmd: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, cmd, " \t\r\n;&|\"'`()");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "mv")) {
            var operands: usize = 0;
            while (it.next()) |arg| {
                if (arg[0] == '-') continue;
                operands += 1;
            }
            if (operands >= 2) return true;
            continue;
        }
        if (std.mem.eql(u8, tok, "rm")) {
            while (it.next()) |arg| {
                if (arg[0] != '-') break;
                if (std.mem.indexOfAny(u8, arg, "rR") != null) return true;
            }
            continue;
        }
    }
    return false;
}

/// The on-disk shape. Older/newer graffs tolerate each other via
/// ignore_unknown_fields both ways (a superset write parses down fine).
const RecordJson = struct {
    pid: i32 = 0,
    start_id: u64 = 0,
    session_id: []const u8 = "",
    identity: []const u8 = "",
    goal: []const u8 = "",
    last_seen_ms: i64 = 0,
};

pub fn formatRecord(arena: Allocator, owner: Owner) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(RecordJson{
        .pid = owner.pid,
        .start_id = owner.start_id,
        .session_id = owner.session_id,
        .identity = owner.identity,
        .goal = owner.goal,
        .last_seen_ms = owner.last_seen_ms,
    });
    return aw.writer.buffered();
}

pub fn parseRecord(arena: Allocator, text: []const u8) ?Owner {
    const rec = std.json.parseFromSliceLeaky(RecordJson, arena, text, .{ .ignore_unknown_fields = true }) catch return null;
    if (rec.pid == 0) return null;
    return .{
        .pid = rec.pid,
        .start_id = rec.start_id,
        .session_id = rec.session_id,
        .identity = rec.identity,
        .goal = rec.goal,
        .last_seen_ms = rec.last_seen_ms,
    };
}

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
    var records: std.ArrayList(Owner) = .empty;
    var probes: std.ArrayList(proc_identity.Probe) = .empty;
    var d = dir;
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (records.items.len >= max_peers) break;
        const text = d.readFileAlloc(io, entry.name, arena, .limited(record_max)) catch continue;
        const rec = parseRecord(arena, text) orelse continue;
        const live = proc_identity.probe(io, rec.pid);
        if (live == .gone) {
            // Provably dead (#413): reap on read so the registry self-cleans
            // even when the owner crashed without retire().
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
var g_goal: []const u8 = ""; // last-known goal (session-arena-owned is fine: both outlive the session)
var g_self: proc_identity.Record = .{}; // own pid + start-id, settled by announce
var g_chan: ?[]const u8 = null; // gpa-owned channel file name (hash of g_identity)
var g_inbox_off: u64 = 0; // bytes of the shared channel already delivered
var g_device_off: u64 = 0; // bytes of the device-wide room already delivered
var g_tail_seeked: bool = false; // one-shots fast-forward both rooms exactly once (empty room at join must not re-skip later arrivals)
var g_acked: [max_peers]u64 = undefined;
var g_acked_len: usize = 0;

fn writeOwn(io: Io, arena: Allocator) void {
    const dir_path = g_dir orelse return;
    const name = g_own_name orelse return;
    var owner = worktree_lease.selfOwner(io, g_identity, g_session, unixMs(io));
    owner.goal = g_goal;
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

/// Remove our record. Best-effort: a crashed session leaves it behind and the
/// next listPeers probes it dead and reaps it — retire is hygiene, not
/// correctness.
/// Free the gpa-owned globals. finalizeSession calls this at exit: a Debug
/// build's SafeAllocator reports any gpa allocation still held at process end
/// as a leak (and exits non-zero), and these five strings are otherwise
/// exactly that. After deinit the module is inert.
pub fn deinit(gpa: Allocator) void {
    if (g_dir) |p| gpa.free(p);
    if (g_identity.len > 0) gpa.free(g_identity);
    if (g_session.len > 0) gpa.free(g_session);
    if (g_goal.len > 0) gpa.free(g_goal);
    if (g_own_name) |n| gpa.free(n);
    if (g_chan) |c| gpa.free(c);
    g_dir = null;
    g_identity = "";
    g_session = "";
    g_goal = "";
    g_own_name = null;
    g_chan = null;
    g_self = .{};
    g_inbox_off = 0;
    g_tail_seeked = false;
    g_acked_len = 0;
}

pub fn retire(io: Io) void {
    const dir_path = g_dir orelse return;
    const name = g_own_name orelse return;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{}) catch return;
    defer dir.close(io);
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

/// The tool-gate half (#469): null = no unacknowledged live co-owner, else the
/// checkpoint text the model sees as its (un-executed) tool result. Seeing a
/// peer ACKs it, so the re-issued command runs and one process checkpoints at
/// most once per peer — awareness is the goal, not a tollbooth.
pub fn gateCheck(io: Io, arena: Allocator) ?[]const u8 {
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

test "isSharedTreeGit: flags index/tree-mutating git, ignores read-only git" {
    try std.testing.expect(isSharedTreeGit("git add -A"));
    try std.testing.expect(isSharedTreeGit("git commit -m \"wip\""));
    try std.testing.expect(isSharedTreeGit("GIT_EDITOR=true git commit --amend"));
    try std.testing.expect(isSharedTreeGit("git -C /tmp/repo reset HEAD~1"));
    try std.testing.expect(isSharedTreeGit("git -c user.name=x commit"));
    try std.testing.expect(isSharedTreeGit("cd sub && git stash"));
    try std.testing.expect(isSharedTreeGit("sh -c 'git rm -r old/'"));
    try std.testing.expect(isSharedTreeGit("git checkout -- src/"));
    try std.testing.expect(!isSharedTreeGit("git status"));
    try std.testing.expect(!isSharedTreeGit("git log --oneline -5"));
    try std.testing.expect(!isSharedTreeGit("git diff HEAD"));
    try std.testing.expect(!isSharedTreeGit("git push origin main"));
    try std.testing.expect(!isSharedTreeGit("git branch"));
    try std.testing.expect(!isSharedTreeGit("gh issue list"));
    try std.testing.expect(!isSharedTreeGit("git"));
    try std.testing.expect(!isSharedTreeGit("ls src/"));
}

test "isSharedTreeShell: flags mv and recursive rm, leaves everyday commands alone" {
    try std.testing.expect(isSharedTreeShell("mv old/ new/"));
    try std.testing.expect(isSharedTreeShell("mv a.ts b.ts"));
    try std.testing.expect(isSharedTreeShell("mv src/a src/b dest/"));
    try std.testing.expect(isSharedTreeShell("rm -rf node_modules"));
    try std.testing.expect(isSharedTreeShell("rm -r build"));
    try std.testing.expect(isSharedTreeShell("cd x && mv a b"));
    try std.testing.expect(!isSharedTreeShell("rm -f .lock"));
    try std.testing.expect(!isSharedTreeShell("rm one-file.txt"));
    try std.testing.expect(!isSharedTreeShell("mv")); // no operands: a usage error, not a tree event
    try std.testing.expect(!isSharedTreeShell("ls -la"));
    try std.testing.expect(!isSharedTreeShell("echo moved"));
}

test "presence record round-trips pid, identity, and goal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const owner: Owner = .{
        .pid = 4242,
        .start_id = 0xdeadbeef,
        .session_id = "session-1",
        .identity = "/repo/.git",
        .goal = "agent-inbox redesign",
        .last_seen_ms = 123456,
    };
    const text = try formatRecord(arena, owner);
    const back = parseRecord(arena, text) orelse return error.ExpectedRecord;
    try std.testing.expectEqual(owner.pid, back.pid);
    try std.testing.expectEqual(owner.start_id, back.start_id);
    try std.testing.expectEqualStrings(owner.session_id, back.session_id);
    try std.testing.expectEqualStrings(owner.identity, back.identity);
    try std.testing.expectEqualStrings(owner.goal, back.goal);
    try std.testing.expectEqual(owner.last_seen_ms, back.last_seen_ms);
}

test "parseRecord: rejects garbage and pid-less records, tolerates extra fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(parseRecord(arena, "not json") == null);
    try std.testing.expect(parseRecord(arena, "{\"goal\":\"x\"}") == null);
    const forward = parseRecord(arena, "{\"pid\":7,\"start_id\":3,\"future\":\"field\"}") orelse return error.ExpectedRecord;
    try std.testing.expectEqual(7, forward.pid);
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
