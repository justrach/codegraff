//! #1622: the shared-tree checkpoint's acknowledgments. It fired once per
//! live peer, but remembered at most `acked.len` of them and never forgot a
//! peer that had exited. With peers respawning, the set filled up; every new
//! peer could then never be acknowledged and every mutating call was refused
//! for good, each re-issue naming another peer. One checkpoint now covers
//! every live peer at once, and only live peers keep their acknowledgment.

const std = @import("std");
const presence = @import("presence.zig");
const worktree_lease = @import("worktree_lease.zig");
const Owner = worktree_lease.Owner;

pub const Acked = struct {
    /// The first newly acknowledged peer, null when every live peer already was.
    first: ?Owner = null,
    /// How many live peers were newly acknowledged.
    fresh: usize = 0,
};

fn live(peers: presence.Peers, i: usize, my_identity: []const u8, my_pid: i32, my_session: []const u8) bool {
    if (i >= peers.probes.len) return false;
    const rec = peers.records[i];
    if (presence.ownSessionRecord(rec, my_session)) return false;
    return switch (worktree_lease.ownerVerdict(rec, my_identity, my_pid, peers.probes[i])) {
        .live_foreign, .live_unverified => true,
        else => false,
    };
}

/// Drop acknowledgments of peers that are no longer live, then acknowledge
/// every live peer not yet acknowledged. `acked[0..len.*]` is updated in place.
pub fn ackLive(peers: presence.Peers, my_identity: []const u8, my_pid: i32, my_session: []const u8, acked: []u64, len: *usize) Acked {
    var kept: usize = 0;
    for (acked[0..len.*]) |key| {
        for (peers.records, 0..) |rec, i| {
            if (presence.ackKey(rec) == key and live(peers, i, my_identity, my_pid, my_session)) {
                acked[kept] = key;
                kept += 1;
                break;
            }
        }
    }
    len.* = kept;
    var out: Acked = .{};
    for (peers.records, 0..) |rec, i| {
        if (!live(peers, i, my_identity, my_pid, my_session)) continue;
        const key = presence.ackKey(rec);
        if (std.mem.indexOfScalar(u64, acked[0..len.*], key) != null) continue;
        if (out.first == null) out.first = rec;
        out.fresh += 1;
        if (len.* < acked.len) {
            acked[len.*] = key;
            len.* += 1;
        }
    }
    return out;
}

test "#1622 one checkpoint covers every live peer, and churn cannot fill the ack set" {
    const proc_identity = @import("proc_identity.zig");
    const my_identity = "/repo/.git";
    var acked: [4]u64 = undefined;
    var len: usize = 0;

    const a: Owner = .{ .pid = 10, .start_id = 1, .session_id = "s-a", .identity = my_identity };
    const b: Owner = .{ .pid = 11, .start_id = 2, .session_id = "s-b", .identity = my_identity };
    const records = [_]Owner{ a, b };
    const probes = [_]proc_identity.Probe{ .{ .id = 1 }, .{ .id = 2 } };
    const first = ackLive(.{ .records = &records, .probes = &probes }, my_identity, 1, "s-me", &acked, &len);
    try std.testing.expectEqualStrings("s-a", first.first.?.session_id);
    try std.testing.expectEqual(@as(usize, 2), first.fresh);
    // The identical re-issue proceeds: both peers were acknowledged together.
    try std.testing.expectEqual(@as(usize, 0), ackLive(.{ .records = &records, .probes = &probes }, my_identity, 1, "s-me", &acked, &len).fresh);

    // Peers keep exiting and respawning: far more than the ack set holds.
    var pid: i32 = 100;
    while (pid < 140) : (pid += 1) {
        const fresh: Owner = .{ .pid = pid, .start_id = @intCast(pid), .session_id = "s-new", .identity = my_identity };
        const churn = [_]Owner{fresh};
        const churn_probes = [_]proc_identity.Probe{.{ .id = @intCast(pid) }};
        const peers: presence.Peers = .{ .records = &churn, .probes = &churn_probes };
        try std.testing.expectEqual(@as(usize, 1), ackLive(peers, my_identity, 1, "s-me", &acked, &len).fresh);
        // ...and the re-issue after each checkpoint goes through.
        try std.testing.expectEqual(@as(usize, 0), ackLive(peers, my_identity, 1, "s-me", &acked, &len).fresh);
    }
    try std.testing.expectEqual(@as(usize, 1), len);
}
