//! Refreshing a synced rotating login without racing other devices
//! (harness ADR 0005 decision 7). A single-use refresh token may have only
//! one refresher, so a device that wants to refresh first checks the vault:
//! a newer version is adopted instead; otherwise it takes the 60 s lease,
//! refreshes, writes the next version, and releases. When the provider
//! rejects the refresh token, the vault is pulled before giving up.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const sync = @import("vault_sync.zig");
const credential_store = @import("credential_store.zig");

const versions_file = ".graff/vault-versions.json";

pub const Plan = union(enum) {
    /// The vault had a newer login; it is now in the local file. Use it.
    adopted: u64,
    /// This device holds the lease. Refresh, then call `commit`.
    refresh: u64,
    /// Another device is refreshing. Use the current token; try again later.
    wait,
};

/// Which vault version each local credential file was last synced from.
pub const Versions = struct {
    io: Io,
    arena: Allocator,
    path: []const u8,

    pub fn at(io: Io, arena: Allocator, home: []const u8) !Versions {
        return .{ .io = io, .arena = arena, .path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ home, versions_file }) };
    }

    pub fn get(v: Versions, slot: []const u8) u64 {
        const data = Io.Dir.cwd().readFileAlloc(v.io, v.path, v.arena, .limited(64 * 1024)) catch return 0;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, v.arena, data, .{}) catch return 0;
        if (parsed != .object) return 0;
        const n = parsed.object.get(slot) orelse return 0;
        return if (n == .integer and n.integer > 0) @intCast(n.integer) else 0;
    }

    pub fn set(v: Versions, slot: []const u8, version: u64) !void {
        var obj: std.json.ObjectMap = .empty;
        if (Io.Dir.cwd().readFileAlloc(v.io, v.path, v.arena, .limited(64 * 1024))) |data| {
            if (std.json.parseFromSliceLeaky(std.json.Value, v.arena, data, .{})) |p| {
                if (p == .object) obj = p.object;
            } else |_| {}
        } else |_| {}
        try obj.put(v.arena, slot, .{ .integer = @intCast(version) });
        var aw: Io.Writer.Allocating = .init(v.arena);
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        try s.write(std.json.Value{ .object = obj });
        if (std.fs.path.dirname(v.path)) |dir| Io.Dir.cwd().createDirPath(v.io, dir) catch {};
        try credential_store.replaceFile(v.io, Io.Dir.cwd(), v.path, aw.writer.buffered(), credential_store.private_file);
    }
};

fn adopt(s: *sync.Session, versions: Versions, slot: []const u8, file: []const u8) !?u64 {
    const got = (try s.pull("graff", slot)) orelse return null;
    try credential_store.replaceFile(s.io, Io.Dir.cwd(), file, got.bytes, credential_store.private_file);
    try versions.set(slot, got.version);
    return got.version;
}

pub fn plan(s: *sync.Session, versions: Versions, slot: []const u8, file: []const u8) !Plan {
    const local = versions.get(slot);
    const current: u64 = if (try s.c.getItem("graff", slot)) |it| it.version else 0;
    if (current > local) {
        if (try adopt(s, versions, slot, file)) |v| return .{ .adopted = v };
    }
    if (!try s.c.lease("graff", slot, 60)) return .wait;
    return .{ .refresh = current };
}

/// After a refresh under the lease: write the new login as the next version.
/// If the vault moved anyway, the vault wins and the local result is
/// discarded (its refresh token was already spent elsewhere).
pub fn commit(s: *sync.Session, versions: Versions, slot: []const u8, file: []const u8, base: u64) !u64 {
    defer s.c.release("graff", slot) catch {};
    const bytes = try Io.Dir.cwd().readFileAlloc(s.io, file, s.arena, .limited(1 << 20));
    switch (try s.putAt("graff", slot, "rotating", base, bytes)) {
        .ok => |v| {
            try versions.set(slot, v);
            return v;
        },
        .conflict, .lease_held => return (try adopt(s, versions, slot, file)) orelse error.Conflict,
    }
}

pub const Rejected = union(enum) { adopted: u64, needs_signin };

/// The provider rejected the refresh token (invalid_grant, 401/403 on
/// refresh). Another device may already hold a newer one; otherwise every
/// device should show "sign in again".
pub fn rejected(s: *sync.Session, versions: Versions, slot: []const u8, file: []const u8) !Rejected {
    const local = versions.get(slot);
    const item = (try s.c.getItem("graff", slot)) orelse return .needs_signin;
    if (item.version > local) {
        if (try adopt(s, versions, slot, file)) |v| return .{ .adopted = v };
    }
    s.c.setStatus("graff", slot, "needs_signin", item.version) catch {};
    return .needs_signin;
}

test {
    _ = @import("vault_refresh_tests.zig");
}
