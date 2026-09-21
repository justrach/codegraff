//! Publication claims share one repository-scoped record for status, release,
//! and the write gate. An orphaned (dead-owner) publication must not block
//! unrelated Git writes.

const std = @import("std");
const ledger = @import("artifact_claim_ledger.zig");
const Claim = ledger.Claim;
const Kind = ledger.Kind;
const Owner = ledger.Owner;
const Ledger = ledger.Ledger;

pub fn publicationRecord(claims: []const Claim, key: []const u8, repo: ?[]const u8) ?Claim {
    if (ledger.findIn(claims, .publication, key, repo)) |found| return found;
    if (key.len != 0) return null;
    var found: ?Claim = null;
    for (claims) |c| {
        if (c.kind != .publication) continue;
        if (ledger.differentRepository(c.repo, repo)) continue;
        if (found != null) return null;
        found = c;
    }
    return found;
}

pub fn expireOrphans(store: *Ledger, live: bool) usize {
    var removed: usize = 0;
    var i: usize = 0;
    while (i < store.len) {
        if (store.items[i].kind == .publication and !live) {
            store.items[i] = store.items[store.len - 1];
            store.len -= 1;
            removed += 1;
            continue;
        }
        i += 1;
    }
    return removed;
}

pub fn expireDead(store: *Ledger, owner_live: *const fn (Owner) bool) usize {
    var removed: usize = 0;
    var i: usize = 0;
    while (i < store.len) {
        if (store.items[i].kind == .publication and !owner_live(store.items[i].owner)) {
            store.items[i] = store.items[store.len - 1];
            store.len -= 1;
            removed += 1;
            continue;
        }
        i += 1;
    }
    return removed;
}

test "status and release share the repo-scoped publication record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store: Ledger = .{};
    const owner = Owner{ .session = "s-gone", .pid = 9, .start_id = 1 };
    _ = try ledger.acquireIn(&store, arena.allocator(), .publication, "feat/x", owner, 1, false, "github.com/org/repo");
    try std.testing.expect(ledger.findIn(store.slice(), .publication, "", "github.com/org/repo") == null);
    const found = publicationRecord(store.slice(), "", "github.com/org/repo").?;
    try std.testing.expectEqualStrings("feat/x", found.key);
    try std.testing.expect(publicationRecord(store.slice(), "feat/other", "github.com/org/repo") == null);
}

test "orphaned publication claims expire and do not block unrelated writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var store: Ledger = .{};
    const dead = Owner{ .session = "s-dead", .pid = 9, .start_id = 1 };
    const live = Owner{ .session = "s-live", .pid = 8, .start_id = 2 };
    _ = try ledger.acquire(&store, arena.allocator(), .publication, "feat/x", dead, 1, false);
    _ = try ledger.acquire(&store, arena.allocator(), .issue, "12", live, 1, false);
    const none = struct {
        fn gone(_: Owner) bool {
            return false;
        }
    };
    try std.testing.expectEqual(@as(usize, 1), expireDead(&store, none.gone));
    try std.testing.expectEqual(@as(usize, 1), store.len);
    try std.testing.expectEqual(Kind.issue, store.items[0].kind);
    try std.testing.expect(publicationRecord(store.slice(), "", null) == null);
}
