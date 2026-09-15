//! Pure artifact ownership transitions, including repository identity.
const std = @import("std");
const Allocator = std.mem.Allocator;

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
    repo: ?[]const u8 = null, // legacy/unknown claims stay conservative
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
    if (a.pid == 0 and b.pid == 0) return a.session.len > 0 and std.mem.eql(u8, a.session, b.session);
    return a.pid != 0 and a.pid == b.pid and a.start_id == b.start_id and std.mem.eql(u8, a.session, b.session);
}

fn sameKey(a: Claim, kind: Kind, key: []const u8, repo: ?[]const u8) bool {
    if (differentRepository(a.repo, repo)) return false;
    if (a.kind != kind) return false;
    if (key.len == 0 or a.key.len == 0) return std.mem.eql(u8, a.key, key);
    return std.mem.eql(u8, a.key, key);
}

/// `owner_live` is the caller's probe of the recorded owner. Time passing and
/// an absent pull request are not inputs — only a gone process is stale.
pub fn verdictIn(claims: []const Claim, kind: Kind, key: []const u8, me: Owner, owner_live: bool, repo: ?[]const u8) Verdict {
    for (claims) |c| {
        if (!sameKey(c, kind, key, repo)) continue;
        if (sameOwner(c.owner, me)) return .mine;
        return if (owner_live) .foreign_live else .stale;
    }
    return .free;
}

pub fn findIn(claims: []const Claim, kind: Kind, key: []const u8, repo: ?[]const u8) ?Claim {
    for (claims) |c| if (sameKey(c, kind, key, repo)) return c;
    return null;
}

pub fn acquireIn(ledger: *Ledger, arena: Allocator, kind: Kind, key: []const u8, me: Owner, now_ms: i64, owner_live: bool, repo: ?[]const u8) ![]const u8 {
    if (ambiguous(ledger.slice(), kind, key, repo)) return error.AmbiguousClaim;
    switch (verdictIn(ledger.slice(), kind, key, me, owner_live, repo)) {
        .mine => {
            if (repo) |r| for (ledger.items[0..ledger.len]) |*c| {
                if (sameKey(c.*, kind, key, repo) and c.repo == null) c.repo = try arena.dupe(u8, r);
            };
            return "claim already held by this session";
        },
        .foreign_live => return error.ClaimHeld,
        .stale, .free => {},
    }
    var i: usize = 0;
    while (i < ledger.len) {
        if (sameKey(ledger.items[i], kind, key, repo)) {
            ledger.items[i] = .{
                .kind = kind,
                .key = try arena.dupe(u8, key),
                .owner = .{
                    .session = try arena.dupe(u8, me.session),
                    .pid = me.pid,
                    .start_id = me.start_id,
                },
                .acquired_ms = now_ms,
                .repo = if (repo) |r| try arena.dupe(u8, r) else null,
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
        .repo = if (repo) |r| try arena.dupe(u8, r) else null,
    };
    ledger.len += 1;
    return "claim acquired";
}

pub fn releaseIn(ledger: *Ledger, kind: Kind, key: []const u8, me: Owner, owner_live: bool, repo: ?[]const u8) ![]const u8 {
    if (ambiguous(ledger.slice(), kind, key, repo)) return error.AmbiguousClaim;
    switch (verdictIn(ledger.slice(), kind, key, me, owner_live, repo)) {
        .free => return "no claim to release",
        .stale => {}, // a live session may clear a dead owner's claim
        .foreign_live => return error.ClaimHeld,
        .mine => {},
    }
    var i: usize = 0;
    while (i < ledger.len) {
        if (sameKey(ledger.items[i], kind, key, repo)) {
            ledger.items[i] = ledger.items[ledger.len - 1];
            ledger.len -= 1;
            return "claim released";
        }
        i += 1;
    }
    return "no claim to release";
}

pub fn handoffIn(ledger: *Ledger, arena: Allocator, kind: Kind, key: []const u8, from: Owner, to: Owner, now_ms: i64, owner_live: bool, repo: ?[]const u8) ![]const u8 {
    if (ambiguous(ledger.slice(), kind, key, repo)) return error.AmbiguousClaim;
    if (sameOwner(from, to)) return "handoff to self is a no-op";
    switch (verdictIn(ledger.slice(), kind, key, from, owner_live, repo)) {
        .mine => {},
        .stale => if (!owner_live) {} else return error.ClaimHeld,
        .foreign_live => return error.ClaimHeld,
        .free => return error.NoClaim,
    }
    var i: usize = 0;
    while (i < ledger.len) : (i += 1) {
        if (!sameKey(ledger.items[i], kind, key, repo)) continue;
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

pub fn differentRepository(a: ?[]const u8, b: ?[]const u8) bool {
    return a != null and b != null and !std.mem.eql(u8, a.?, b.?);
}

pub fn ambiguous(claims: []const Claim, kind: Kind, key: []const u8, repo: ?[]const u8) bool {
    var count: usize = 0;
    for (claims) |c| if (sameKey(c, kind, key, repo)) {
        count += 1;
    };
    return count > 1;
}

pub fn verdict(claims: []const Claim, kind: Kind, key: []const u8, me: Owner, owner_live: bool) Verdict {
    return verdictIn(claims, kind, key, me, owner_live, null);
}

pub fn find(claims: []const Claim, kind: Kind, key: []const u8) ?Claim {
    return findIn(claims, kind, key, null);
}

pub fn acquire(ledger: *Ledger, arena: Allocator, kind: Kind, key: []const u8, me: Owner, now_ms: i64, owner_live: bool) ![]const u8 {
    return acquireIn(ledger, arena, kind, key, me, now_ms, owner_live, null);
}

pub fn release(ledger: *Ledger, kind: Kind, key: []const u8, me: Owner, owner_live: bool) ![]const u8 {
    return releaseIn(ledger, kind, key, me, owner_live, null);
}

pub fn handoff(ledger: *Ledger, arena: Allocator, kind: Kind, key: []const u8, from: Owner, to: Owner, now_ms: i64, owner_live: bool) ![]const u8 {
    return handoffIn(ledger, arena, kind, key, from, to, now_ms, owner_live, null);
}

test "repository scopes separate identical artifacts and keep handoffs local" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ledger: Ledger = .{};
    const first = Owner{ .session = "first" };
    const second = Owner{ .session = "second" };
    const receiver = Owner{ .session = "receiver" };
    _ = try acquireIn(&ledger, a, .pull_request, "1", first, 0, false, "github.com/org/first");
    _ = try acquireIn(&ledger, a, .pull_request, "1", second, 0, false, "github.com/org/second");
    try std.testing.expectEqual(@as(usize, 2), ledger.len);
    try std.testing.expect(sameOwner(findIn(ledger.slice(), .pull_request, "1", "github.com/org/first").?.owner, first));
    try std.testing.expect(ambiguous(ledger.slice(), .pull_request, "1", null));
    try std.testing.expect(!ambiguous(ledger.slice(), .pull_request, "1", "github.com/org/second"));
    _ = try handoffIn(&ledger, a, .pull_request, "1", second, receiver, 1, true, "github.com/org/second");
    _ = try releaseIn(&ledger, .pull_request, "1", first, true, "github.com/org/first");
    try std.testing.expectEqual(@as(usize, 1), ledger.len);
    try std.testing.expect(sameOwner(ledger.items[0].owner, receiver));
    try std.testing.expectEqualStrings("github.com/org/second", ledger.items[0].repo.?);
}

test "legacy unknown repository claims cannot be bypassed by a new scoped claim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ledger: Ledger = .{};
    _ = try acquire(&ledger, arena.allocator(), .branch, "feature", .{ .session = "first" }, 0, false);
    try std.testing.expectError(error.ClaimHeld, acquireIn(&ledger, arena.allocator(), .branch, "feature", .{ .session = "second" }, 1, true, "github.com/org/other"));
    try std.testing.expect(!differentRepository(null, "github.com/org/other"));
    _ = try acquireIn(&ledger, arena.allocator(), .branch, "feature", .{ .session = "first" }, 1, true, "github.com/org/first");
    try std.testing.expectEqualStrings("github.com/org/first", ledger.items[0].repo.?);
}
