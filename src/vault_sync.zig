//! Vault operations on top of the edge client (harness ADR 0005, contract
//! v1.1): enroll this device, push/pull opaque credential bytes, approve a
//! new device, and remove one with a key rotation. Only graff holds the vault
//! key; the edge stores ciphertext.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const crypto = @import("vault_crypto.zig");
const client = @import("vault_client.zig");
const credential_store = @import("credential_store.zig");

pub const Session = struct {
    io: Io,
    arena: Allocator,
    c: *client.Client,
    user_id: []const u8,
    /// Where the previous vault key waits (0600) until every item has been
    /// re-encrypted under the new epoch. null disables crash recovery.
    prev_key_path: ?[]const u8 = null,
    /// The previous key while this process is mid-rotation.
    prev_key: ?Key = null,

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
            const w = try crypto.wrap(s.io, vk, s.c.keys.box.public_key, s.user_id, s.c.device_id, v.keyEpoch);
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
        return .{ .key = try crypto.unwrap(s.c.keys, raw, s.user_id, s.c.device_id, v.keyEpoch), .epoch = v.keyEpoch };
    }

    fn loadPrevKey(s: *Session) ?Key {
        if (s.prev_key) |k| return k;
        const path = s.prev_key_path orelse return null;
        const data = Io.Dir.cwd().readFileAlloc(s.io, path, s.arena, .limited(256)) catch return null;
        const t = std.mem.trim(u8, data, " \t\r\n");
        const colon = std.mem.indexOfScalar(u8, t, ':') orelse return null;
        var k: Key = .{ .key = undefined, .epoch = std.fmt.parseInt(u64, t[0..colon], 10) catch return null };
        if (t.len - colon - 1 != 2 * crypto.key_len) return null;
        _ = std.fmt.hexToBytes(&k.key, t[colon + 1 ..]) catch return null;
        return k;
    }

    fn savePrevKey(s: *Session, k: Key) !void {
        s.prev_key = k;
        const path = s.prev_key_path orelse return;
        if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(s.io, dir) catch {};
        const text = try std.fmt.allocPrint(s.arena, "{d}:{s}\n", .{ k.epoch, &std.fmt.bytesToHex(k.key, .lower) });
        try credential_store.replaceFile(s.io, Io.Dir.cwd(), path, text, credential_store.private_file);
    }

    /// The key an item was sealed under: the current one, or the cached
    /// previous one for an item a crashed rotation left behind.
    fn keyFor(s: *Session, item_epoch: u64) !Key {
        const k = try s.vaultKey();
        if (item_epoch == k.epoch) return k;
        if (s.loadPrevKey()) |p| if (p.epoch == item_epoch) return p;
        return error.StaleItemEpoch;
    }

    pub const Pulled = struct { bytes: []u8, version: u64, kind: []const u8, status: []const u8, key_epoch: u64 };

    pub fn pull(s: *Session, agent: []const u8, slot: []const u8) !?Pulled {
        const item = (try s.c.getItem(agent, slot)) orelse return null;
        const k = try s.keyFor(item.keyEpoch);
        const bytes = try crypto.open(s.arena, k.key, .{ .user_id = s.user_id, .agent = agent, .slot = slot, .version = item.version, .key_epoch = item.keyEpoch }, try crypto.decode(s.arena, item.nonce), try crypto.decode(s.arena, item.ciphertext));
        return .{ .bytes = bytes, .version = item.version, .kind = item.kind, .status = item.status, .key_epoch = item.keyEpoch };
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

    pub fn deviceFingerprint(s: *Session, d: client.Device) !crypto.Fingerprint {
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
        const w = try crypto.wrap(s.io, k.key, pub_raw[0..32].*, s.user_id, device_id, k.epoch);
        try s.c.approve(device_id, try crypto.encode(s.arena, &w));
    }

    /// Remove a device and rotate: a new vault key wrapped to every remaining
    /// enrolled device, then every item re-encrypted under the new epoch.
    pub fn remove(s: *Session, device_id: []const u8) !void {
        try s.rotateKey(device_id);
        try s.migrate();
    }

    /// First half of `remove`. The old key is cached before the edge rotates,
    /// so a crash before `migrate` finishes strands nothing.
    pub fn rotateKey(s: *Session, device_id: []const u8) !void {
        const old = try s.vaultKey();
        try s.savePrevKey(old);
        try s.c.deleteDevice(device_id);
        const after = try s.c.getVault();
        var new_key: crypto.VaultKey = undefined;
        s.io.random(&new_key);
        var wrapped: std.json.ObjectMap = .empty;
        for (after.devices) |d| {
            if (!std.mem.eql(u8, d.status, "enrolled")) continue;
            const pub_raw = try crypto.decode(s.arena, d.publicKey);
            if (pub_raw.len != 32) return error.BadPublicKey;
            const w = try crypto.wrap(s.io, new_key, pub_raw[0..32].*, s.user_id, d.deviceId, old.epoch + 1);
            try wrapped.put(s.arena, d.deviceId, .{ .string = try crypto.encode(s.arena, &w) });
        }
        try s.c.rotate(old.epoch + 1, wrapped);
    }

    /// Re-encrypt every item still behind the vault's epoch (rotating ones
    /// under their lease, all released whatever happens), then drop the
    /// cached previous key. Safe to rerun after a crash; a no-op once current.
    pub fn migrate(s: *Session) !void {
        const v = try s.c.getVault();
        const Leased = struct { agent: []const u8, slot: []const u8 };
        var leased: std.ArrayList(Leased) = .empty;
        defer for (leased.items) |l| s.c.release(l.agent, l.slot) catch {};
        for (v.items) |h| {
            if (h.keyEpoch >= v.keyEpoch) continue;
            if (std.mem.eql(u8, h.kind, "rotating")) {
                if ((try s.c.lease(h.agent, h.slot, 60)) == null) return error.LeaseHeld;
                try leased.append(s.arena, .{ .agent = h.agent, .slot = h.slot });
            }
            const p = (try s.pull(h.agent, h.slot)) orelse continue;
            switch (try s.putAt(h.agent, h.slot, h.kind, p.version, p.bytes)) {
                .ok => {},
                .conflict, .lease_held => return error.Conflict,
            }
        }
        s.prev_key = null;
        if (s.prev_key_path) |path| Io.Dir.cwd().deleteFile(s.io, path) catch {};
    }
};

test {
    _ = @import("vault_sync_tests.zig");
}
