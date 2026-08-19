//! Who a peer ping is FOR, and who actually hears it.
//!
//! The JSONL rooms stay append-only logs (ADR 0004). Delivery is the
//! working set: a bare worktree post is still a room, but a named target is
//! a DM — only that session parks it. `session` on peer_message resolves
//! by exact id, pid, unique name fragment, or unique **goal** fragment so a
//! model can ping "the one doing the digest job" without guessing names.
//!
//! A standing liaison subagent is the wrong shape: children never drain the
//! channel (`deliverInbound` returns on `root.sub`), and an idle looper is
//! another model in the room. Exact DM + the collision gate is "only active
//! when needed."

const std = @import("std");
const util = @import("util.zig");
const presence_chan = @import("presence_chan.zig");
const worktree_lease = @import("worktree_lease.zig");

const Message = presence_chan.Message;
const Owner = worktree_lease.Owner;

pub const Resolve = union(enum) { one: Owner, none, ambiguous };

/// Does `to` name this session? Exact match first; then substring either
/// way so a resolved id still matches a slightly longer live name.
pub fn addressedTo(to: []const u8, own: []const u8) bool {
    if (to.len == 0 or own.len == 0) return false;
    if (std.mem.eql(u8, to, own)) return true;
    return std.mem.indexOf(u8, to, own) != null or std.mem.indexOf(u8, own, to) != null;
}

/// Worktree room: unaddressed lines are for everyone here. Addressed lines
/// are a DM — only the named session hears them in history. The log still
/// has the line; this is the working-set filter.
pub fn treeHears(m: Message, own: []const u8) bool {
    if (m.to.len == 0) return true;
    return addressedTo(m.to, own);
}

/// Device room: addressed-only, plus the user's unaddressed `/tell all`.
pub fn deviceHears(m: Message, own: []const u8) bool {
    if (addressedTo(m.to, own)) return true;
    return m.from_user and m.to.len == 0;
}

fn countWhere(peers: []const Owner, comptime kind: enum { exact_id, pid, name, goal }, want: []const u8) Resolve {
    var found: ?Owner = null;
    var n: usize = 0;
    const pid_val: ?i32 = if (kind == .pid) std.fmt.parseInt(i32, want, 10) catch null else null;
    if (kind == .pid and pid_val == null) return .none;
    for (peers) |p| {
        const hit = switch (kind) {
            .exact_id => std.mem.eql(u8, p.session_id, want),
            .pid => p.pid == pid_val.?,
            .name => std.mem.indexOf(u8, p.session_id, want) != null,
            .goal => p.goal.len > 0 and util.indexOfIgnoreCase(p.goal, want) != null,
        };
        if (!hit) continue;
        found = p;
        n += 1;
        if (n > 1) return .ambiguous;
    }
    return if (n == 1) .{ .one = found.? } else .none;
}

/// Pick the one live peer `want` names. Empty wants exactly one peer (the
/// caller decides whether that becomes a DM or a room post). Precedence:
/// exact session id, then pid, then unique name fragment, then unique goal
/// fragment. A name hit always beats a goal hit so "digest" naming a session
/// does not steal a peer whose goal happens to mention digest.
pub fn resolvePeer(peers: []const Owner, want: []const u8) Resolve {
    if (want.len == 0) return if (peers.len == 1) .{ .one = peers[0] } else if (peers.len == 0) .none else .ambiguous;
    const exact = countWhere(peers, .exact_id, want);
    if (exact == .one) return exact;
    const by_pid = countWhere(peers, .pid, want);
    if (by_pid == .one) return by_pid;
    if (by_pid == .ambiguous) return .ambiguous;
    const by_name = countWhere(peers, .name, want);
    if (by_name == .one) return by_name;
    if (by_name == .ambiguous) return .ambiguous;
    return countWhere(peers, .goal, want);
}

const testing = std.testing;

fn peer(id: []const u8, pid: i32, goal: []const u8) Owner {
    return .{ .session_id = id, .pid = pid, .goal = goal };
}

test "addressedTo: exact id, then substring either way; empty is never a hit" {
    try testing.expect(addressedTo("session-111-us", "session-111-us"));
    try testing.expect(addressedTo("session-111", "session-111-us"));
    try testing.expect(addressedTo("session-111-us", "session-111"));
    try testing.expect(!addressedTo("session-999", "session-111-us"));
    try testing.expect(!addressedTo("", "session-111-us"));
    try testing.expect(!addressedTo("session-111", ""));
}

test "treeHears: bare posts are the room; a named to is a DM" {
    const own = "session-aaa";
    try testing.expect(treeHears(.{}, own));
    try testing.expect(treeHears(.{ .to = own }, own));
    try testing.expect(treeHears(.{ .to = "session-aaa" }, own));
    try testing.expect(!treeHears(.{ .to = "session-bbb" }, own));
    try testing.expect(!treeHears(.{ .to = own }, ""));
}

test "deviceHears: addressed lines and the user's /tell cross folders; broadcasts do not" {
    const own = "session-111-us";
    try testing.expect(deviceHears(.{ .to = "session-111" }, own));
    try testing.expect(deviceHears(.{ .to = own }, "session-111"));
    try testing.expect(deviceHears(.{ .from_user = true }, own));
    try testing.expect(!deviceHears(.{ .from_user = true, .to = "session-999-them" }, own));
    try testing.expect(deviceHears(.{ .from_user = true, .to = "session-111" }, own));
    try testing.expect(!deviceHears(.{ .to = "session-999-them" }, own));
    try testing.expect(!deviceHears(.{}, own));
    try testing.expect(!deviceHears(.{ .to = "session-111" }, ""));
}

test "resolvePeer: exact id, pid, unique name, unique goal; name beats goal" {
    const peers = [_]Owner{
        peer("session-digest", 11, "refactor the digest job"),
        peer("session-gui", 22, "hold gui/src until the move lands"),
        peer("session-docs", 33, "draft the digest of the release notes"),
    };
    try testing.expectEqualStrings("session-gui", resolvePeer(&peers, "session-gui").one.session_id);
    try testing.expectEqualStrings("session-digest", resolvePeer(&peers, "11").one.session_id);
    try testing.expectEqualStrings("session-gui", resolvePeer(&peers, "gui").one.session_id);
    // Two goals mention digest, but the name "digest" uniquely names one session.
    try testing.expectEqualStrings("session-digest", resolvePeer(&peers, "digest").one.session_id);
    try testing.expectEqualStrings("session-gui", resolvePeer(&peers, "gui/src").one.session_id);
    try testing.expect(resolvePeer(&peers, "nope") == .none);
    try testing.expect(resolvePeer(&peers, "session-") == .ambiguous);
    try testing.expect(resolvePeer(&peers, "") == .ambiguous);
    const one = [_]Owner{peer("solo", 1, "alone here")};
    try testing.expectEqualStrings("solo", resolvePeer(&one, "").one.session_id);
    try testing.expect(resolvePeer(&.{}, "x") == .none);
}

test "resolvePeer: a goal fragment pings the session doing that work" {
    const peers = [_]Owner{
        peer("session-aaa", 1, "rewrite the peer_channel targeting"),
        peer("session-bbb", 2, "paint the TUI hover chips"),
    };
    try testing.expectEqualStrings("session-aaa", resolvePeer(&peers, "peer_channel").one.session_id);
    try testing.expectEqualStrings("session-bbb", resolvePeer(&peers, "hover").one.session_id);
    try testing.expect(resolvePeer(&peers, "the") == .ambiguous); // both goals contain it
}
