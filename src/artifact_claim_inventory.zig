//! #1614: what the claim ledger holds. A full ledger refuses new claims and
//! tells the caller to release a finished one, and `status` without a key
//! asks about the whole ledger, so both list every claim with whether the
//! caller may release it: its own claims, and claims whose owner has exited.
//! A claim a live session holds is listed but never evicted.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const claim_ledger = @import("artifact_claim_ledger.zig");
const Claim = claim_ledger.Claim;
const Owner = claim_ledger.Owner;

/// `status` without a key: every claim, or "no claim" for an empty ledger.
pub fn status(arena: Allocator, io: Io, claims: []const Claim, me: Owner) ![]const u8 {
    if (claims.len == 0) return "no claim";
    const header = try std.fmt.allocPrint(arena, "{d}/{d} claims held:", .{ claims.len, claim_ledger.max_claims });
    return list(arena, header, claims, me, try liveness(arena, io, claims));
}

/// A refused acquire. At capacity the refusal also lists what can be released.
pub fn acquireFail(arena: Allocator, io: Io, err: anyerror, claims: []const Claim, me: Owner) ![]const u8 {
    const text = claim_ledger.acquireFailText(arena, err);
    if (err != error.ClaimFull) return text;
    return list(arena, text, claims, me, try liveness(arena, io, claims));
}

fn liveness(arena: Allocator, io: Io, claims: []const Claim) ![]const bool {
    const live = try arena.alloc(bool, claims.len);
    for (claims, live) |c, *owner_live| owner_live.* = @import("artifact_claim.zig").ownerLive(io, c.owner);
    return live;
}

/// `header`, then one line per claim. `live[i]` is whether `claims[i]`'s
/// recorded owner is still running.
pub fn list(arena: Allocator, header: []const u8, claims: []const Claim, me: Owner, live: []const bool) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll(header);
    for (claims, live) |c, owner_live| {
        try w.print("\n- {s} {s}", .{ @tagName(c.kind), if (c.key.len > 0) c.key else "(unnamed)" });
        if (c.repo) |repo| try w.print(" in {s}", .{repo});
        if (claim_ledger.sameOwner(c.owner, me)) {
            try w.writeAll(": yours");
        } else if (owner_live) {
            try w.print(": held by live session \"{s}\"", .{c.owner.session});
            continue;
        } else {
            try w.print(": owner session \"{s}\" has exited", .{c.owner.session});
        }
        try w.print("; release with action=release kind={s} key={s}", .{ @tagName(c.kind), c.key });
        if (c.repo) |repo| try w.print(" repo={s}", .{repo});
    }
    return out.written();
}

test "the inventory marks which claims the caller may release" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const me: Owner = .{ .session = "me", .pid = 1, .start_id = 1 };
    const claims = [_]Claim{
        .{ .kind = .issue, .key = "12", .owner = me, .repo = "github.com/org/repo" },
        .{ .kind = .branch, .key = "feature", .owner = .{ .session = "gone", .pid = 2, .start_id = 2 } },
        .{ .kind = .pull_request, .key = "45", .owner = .{ .session = "busy", .pid = 3, .start_id = 3 } },
    };
    const text = try list(arena_state.allocator(), "3/32 claims held:", &claims, me, &.{ true, false, true });
    try std.testing.expectEqualStrings(
        \\3/32 claims held:
        \\- issue 12 in github.com/org/repo: yours; release with action=release kind=issue key=12 repo=github.com/org/repo
        \\- branch feature: owner session "gone" has exited; release with action=release kind=branch key=feature
        \\- pull_request 45: held by live session "busy"
    , text);
}

test "a full ledger and a keyless status list the claims (#1614)" {
    const claims = @import("artifact_claim.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const io = std.testing.io;
    claims.resetForTest();
    defer claims.resetForTest();
    claims.setTestOwner(.{ .session = "s-a", .pid = 11, .start_id = 1 });
    try std.testing.expectEqualStrings("no claim", (try claims.handleTool(ar, io, "status", "issue", "", "")).text);
    var i: usize = 0;
    while (i < claim_ledger.max_claims) : (i += 1) {
        const r = try claims.handleTool(ar, io, "claim", "issue", try std.fmt.allocPrint(ar, "{d}", .{i + 1}), "");
        try std.testing.expect(!r.is_error);
    }
    const full = try claims.handleTool(ar, io, "claim", "issue", "999", "");
    try std.testing.expect(full.is_error);
    try std.testing.expect(std.mem.indexOf(u8, full.text, "ledger is full") != null);
    try std.testing.expect(std.mem.indexOf(u8, full.text, "\n- issue 32: yours; release with action=release kind=issue key=32") != null);

    // Another session sees whose claims they are, and which owners exited.
    claims.setTestOwner(.{ .session = "s-b", .pid = 12, .start_id = 2 });
    const held = try claims.handleTool(ar, io, "status", "issue", "", "");
    try std.testing.expect(std.mem.startsWith(u8, held.text, "32/32 claims held:"));
    try std.testing.expect(std.mem.indexOf(u8, held.text, "- issue 1: held by live session \"s-a\"") != null);
    claims.setTestOwnerLive(false);
    const stale = try claims.handleTool(ar, io, "status", "issue", "", "");
    try std.testing.expect(std.mem.indexOf(u8, stale.text, "- issue 1: owner session \"s-a\" has exited; release") != null);
    // A keyed status still answers only for that key.
    try std.testing.expectEqualStrings("no claim", (try claims.handleTool(ar, io, "status", "issue", "999", "")).text);
}
