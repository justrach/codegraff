//! Vault operations on top of the edge client (harness ADR 0005, contract
//! v1.1): enroll this device, push/pull opaque credential bytes, approve a
//! new device, and remove one with a key rotation. Only graff holds the vault
//! key; the edge stores ciphertext.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const crypto = @import("vault_crypto.zig");
const client = @import("vault_client.zig");

pub const Session = struct {
    io: Io,
    arena: Allocator,
    c: *client.Client,
    user_id: []const u8,

    /// A session for `c`. The user id comes from the edge (GET /vault) and
    /// falls back to the bearer's `sub` on edges that do not return it.
    pub fn open(io: Io, arena: Allocator, c: *client.Client) !Session {
        const v = try c.getVault();
        const user = v.userId orelse try crypto.userIdFromBearer(arena, c.bearer);
        return .{ .io = io, .arena = arena, .c = c, .user_id = user };
    }

    pub const Enrolled = enum { enrolled, pending };

    /// Register this device. The first device creates the vault key and
    /// enrolls itself; later devices wait for `approve` on an enrolled one.
    pub fn enable(s: *Session, name: []const u8) !Enrolled {
        const v = try s.c.getVault();
        var any_enrolled = false;
        for (v.devices) |d| {
            if (std.mem.eql(u8, d.deviceId, s.c.device_id)) return if (std.mem.eql(u8, d.status, "enrolled")) .enrolled else .pending;
            any_enrolled = any_enrolled or std.mem.eql(u8, d.status, "enrolled");
        }
        var wrapped: ?[]const u8 = null;
        if (!any_enrolled) {
            var vk: crypto.VaultKey = undefined;
            s.io.random(&vk);
            const w = try crypto.wrap(s.io, vk, s.c.keys.box.public_key, s.user_id, s.c.device_id);
            wrapped = try crypto.encode(s.arena, &w);
        }
        const status = try s.c.registerDevice(name, wrapped);
        return if (std.mem.eql(u8, status, "enrolled")) .enrolled else .pending;
    }

    pub const Key = struct { key: crypto.VaultKey, epoch: u64 };

    pub fn vaultKey(s: *Session) !Key {
        const v = try s.c.getVault();
        const wrapped = v.wrappedKey orelse return error.NotEnrolled;
        const raw = try crypto.decode(s.arena, wrapped);
        return .{ .key = try crypto.unwrap(s.c.keys, raw, s.user_id, s.c.device_id), .epoch = v.keyEpoch };
    }

    pub const Pulled = struct { bytes: []u8, version: u64, kind: []const u8, status: []const u8 };

    pub fn pull(s: *Session, agent: []const u8, slot: []const u8) !?Pulled {
        const item = (try s.c.getItem(agent, slot)) orelse return null;
        const k = try s.vaultKey();
        if (item.keyEpoch != k.epoch) return error.StaleItemEpoch;
        const bytes = try crypto.open(s.arena, k.key, .{ .user_id = s.user_id, .agent = agent, .slot = slot, .version = item.version, .key_epoch = item.keyEpoch }, try crypto.decode(s.arena, item.nonce), try crypto.decode(s.arena, item.ciphertext));
        return .{ .bytes = bytes, .version = item.version, .kind = item.kind, .status = item.status };
    }

    pub const Put = union(enum) { ok: u64, conflict: u64, lease_held };

    /// One compare-and-swap write at `if_match` (0 = create). A stale key
    /// epoch re-reads the vault key and retries once.
    pub fn putAt(s: *Session, agent: []const u8, slot: []const u8, kind: []const u8, if_match: u64, plaintext: []const u8) !Put {
        var attempt: usize = 0;
        while (attempt < 2) : (attempt += 1) {
            const k = try s.vaultKey();
            const sealed = try crypto.seal(s.io, s.arena, k.key, .{ .user_id = s.user_id, .agent = agent, .slot = slot, .version = if_match + 1, .key_epoch = k.epoch }, plaintext);
            const r = try s.c.putItem(agent, slot, if_match, .{
                .kind = kind,
                .keyEpoch = k.epoch,
                .nonce = try crypto.encode(s.arena, &sealed.nonce),
                .ciphertext = try crypto.encode(s.arena, sealed.body),
            });
            switch (r) {
                .ok => |v| return .{ .ok = v },
                .conflict => |v| return .{ .conflict = v },
                .lease_held => return .lease_held,
                .stale_epoch => continue,
            }
        }
        return error.StaleEpoch;
    }

    /// `graff keys push`: write the current bytes as the next version,
    /// whatever version the vault holds now.
    pub fn push(s: *Session, agent: []const u8, slot: []const u8, kind: []const u8, plaintext: []const u8) !u64 {
        var current: u64 = if (try s.c.getItem(agent, slot)) |it| it.version else 0;
        var attempt: usize = 0;
        while (attempt < 3) : (attempt += 1) {
            switch (try s.putAt(agent, slot, kind, current, plaintext)) {
                .ok => |v| return v,
                .conflict => |v| current = v,
                .lease_held => return error.LeaseHeld,
            }
        }
        return error.Conflict;
    }

    pub fn findDevice(v: client.Vault, id: []const u8) ?client.Device {
        for (v.devices) |d| if (std.mem.eql(u8, d.deviceId, id)) return d;
        return null;
    }

    pub fn deviceFingerprint(s: *Session, d: client.Device) ![8]u8 {
        const raw = try crypto.decode(s.arena, d.publicKey);
        if (raw.len != 32) return error.BadPublicKey;
        return crypto.fingerprint(raw[0..32].*);
    }

    /// Wrap the vault key to a pending device and approve it.
    pub fn approve(s: *Session, device_id: []const u8) !void {
        const v = try s.c.getVault();
        const d = findDevice(v, device_id) orelse return error.NoSuchDevice;
        const pub_raw = try crypto.decode(s.arena, d.publicKey);
        if (pub_raw.len != 32) return error.BadPublicKey;
        const k = try s.vaultKey();
        const w = try crypto.wrap(s.io, k.key, pub_raw[0..32].*, s.user_id, device_id);
        try s.c.approve(device_id, try crypto.encode(s.arena, &w));
    }

    /// Remove a device and rotate: new vault key wrapped to every remaining
    /// enrolled device, then every item re-encrypted under the new epoch
    /// (rotating items under their lease).
    pub fn remove(s: *Session, device_id: []const u8) !void {
        const old = try s.vaultKey();
        const before = try s.c.getVault();
        const Plain = struct { agent: []const u8, slot: []const u8, kind: []const u8, version: u64, bytes: []u8, leased: bool };
        var plains: std.ArrayList(Plain) = .empty;
        for (before.items) |h| {
            const rotating = std.mem.eql(u8, h.kind, "rotating");
            if (rotating and !try s.c.lease(h.agent, h.slot, 60)) return error.LeaseHeld;
            const p = (try s.pull(h.agent, h.slot)) orelse continue;
            try plains.append(s.arena, .{ .agent = h.agent, .slot = h.slot, .kind = h.kind, .version = p.version, .bytes = p.bytes, .leased = rotating });
        }
        try s.c.deleteDevice(device_id);
        const after = try s.c.getVault();
        var new_key: crypto.VaultKey = undefined;
        s.io.random(&new_key);
        var wrapped: std.json.ObjectMap = .empty;
        for (after.devices) |d| {
            if (!std.mem.eql(u8, d.status, "enrolled")) continue;
            const pub_raw = try crypto.decode(s.arena, d.publicKey);
            if (pub_raw.len != 32) return error.BadPublicKey;
            const w = try crypto.wrap(s.io, new_key, pub_raw[0..32].*, s.user_id, d.deviceId);
            try wrapped.put(s.arena, d.deviceId, .{ .string = try crypto.encode(s.arena, &w) });
        }
        try s.c.rotate(old.epoch + 1, wrapped);
        for (plains.items) |p| {
            defer if (p.leased) s.c.release(p.agent, p.slot) catch {};
            switch (try s.putAt(p.agent, p.slot, p.kind, p.version, p.bytes)) {
                .ok => {},
                .conflict, .lease_held => return error.Conflict,
            }
        }
    }
};

test {
    _ = @import("vault_sync_tests.zig");
}
