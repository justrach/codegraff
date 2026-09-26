//! End-to-end crypto for the login vault (harness ADR 0005, contract v1.1).
//! The edge only ever sees public keys, wrapped keys, and ciphertext.
//!
//! - Device keys: X25519 (key wrapping) + Ed25519 (request signing).
//! - Vault key: 32 random bytes, created by the first device.
//! - Wrap: ephemeral X25519 to the recipient's public key → HKDF-SHA256
//!   (salt = ephPub‖recipientPub, info = "harness-vault-v1 wrap") →
//!   XChaCha20-Poly1305, random 24-byte nonce, aad = "wrap|userId|deviceId".
//!   wrappedKey = ephPub ‖ nonce ‖ ciphertext ‖ tag.
//! - Item: XChaCha20-Poly1305 under the vault key, random nonce,
//!   aad = "userId|agent|slot|version|keyEpoch"; stored as ciphertext ‖ tag.
//! - Requests: Ed25519 over "method|path|sha256hex(body)|timestampMs|deviceId".

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const X25519 = std.crypto.dh.X25519;
const Ed25519 = std.crypto.sign.Ed25519;
const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const b64 = std.base64.url_safe_no_pad;

pub const key_len = 32;
pub const nonce_len = Aead.nonce_length;
pub const tag_len = Aead.tag_length;
pub const wrapped_len = X25519.public_length + nonce_len + key_len + tag_len;
const wrap_info = "harness-vault-v1 wrap";

pub const VaultKey = [key_len]u8;

pub const DeviceKeys = struct {
    box: X25519.KeyPair,
    sign: Ed25519.KeyPair,

    pub fn generate(io: Io) DeviceKeys {
        return .{ .box = X25519.KeyPair.generate(io), .sign = Ed25519.KeyPair.generate(io) };
    }

    /// Both secrets as one hex string, for the Keychain or a 0600 file.
    pub fn encodeSecret(k: DeviceKeys) [2 * (X25519.secret_length + Ed25519.KeyPair.seed_length)]u8 {
        var raw: [X25519.secret_length + Ed25519.KeyPair.seed_length]u8 = undefined;
        @memcpy(raw[0..X25519.secret_length], &k.box.secret_key);
        @memcpy(raw[X25519.secret_length..], &k.sign.secret_key.seed());
        return std.fmt.bytesToHex(raw, .lower);
    }

    pub fn decodeSecret(hex: []const u8) !DeviceKeys {
        var raw: [X25519.secret_length + Ed25519.KeyPair.seed_length]u8 = undefined;
        if (hex.len != raw.len * 2) return error.BadDeviceKey;
        _ = std.fmt.hexToBytes(&raw, hex) catch return error.BadDeviceKey;
        const box_secret = raw[0..X25519.secret_length].*;
        const seed = raw[X25519.secret_length..].*;
        return .{
            .box = .{ .secret_key = box_secret, .public_key = try X25519.recoverPublicKey(box_secret) },
            .sign = try Ed25519.KeyPair.generateDeterministic(seed),
        };
    }
};

/// First 8 hex chars of sha256(X25519 public key): what `approve` asks the
/// user to compare, and what `status` prints for this device.
pub fn fingerprint(box_public: [X25519.public_length]u8) [8]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(&box_public, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return hex[0..8].*;
}

fn wrapAad(buf: []u8, user_id: []const u8, device_id: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "wrap|{s}|{s}", .{ user_id, device_id });
}

fn wrapKeyFor(shared: [X25519.shared_length]u8, eph_pub: [32]u8, recipient_pub: [32]u8) [key_len]u8 {
    var salt: [64]u8 = undefined;
    @memcpy(salt[0..32], &eph_pub);
    @memcpy(salt[32..], &recipient_pub);
    const prk = Hkdf.extract(&salt, &shared);
    var out: [key_len]u8 = undefined;
    Hkdf.expand(&out, wrap_info, prk);
    return out;
}

/// Wrap the vault key to one device's X25519 public key.
pub fn wrap(io: Io, vault_key: VaultKey, recipient_pub: [32]u8, user_id: []const u8, device_id: []const u8) ![wrapped_len]u8 {
    const eph = X25519.KeyPair.generate(io);
    const shared = try X25519.scalarmult(eph.secret_key, recipient_pub);
    const k = wrapKeyFor(shared, eph.public_key, recipient_pub);
    var out: [wrapped_len]u8 = undefined;
    @memcpy(out[0..32], &eph.public_key);
    const nonce = out[32..][0..nonce_len];
    io.random(nonce);
    var abuf: [512]u8 = undefined;
    const aad = try wrapAad(&abuf, user_id, device_id);
    const ct = out[32 + nonce_len ..][0..key_len];
    const tag = out[32 + nonce_len + key_len ..][0..tag_len];
    Aead.encrypt(ct, tag, &vault_key, aad, nonce.*, k);
    return out;
}

pub fn unwrap(keys: DeviceKeys, wrapped: []const u8, user_id: []const u8, device_id: []const u8) !VaultKey {
    if (wrapped.len != wrapped_len) return error.BadWrappedKey;
    const eph_pub = wrapped[0..32].*;
    const shared = try X25519.scalarmult(keys.box.secret_key, eph_pub);
    const k = wrapKeyFor(shared, eph_pub, keys.box.public_key);
    var abuf: [512]u8 = undefined;
    const aad = try wrapAad(&abuf, user_id, device_id);
    var out: VaultKey = undefined;
    const nonce = wrapped[32..][0..nonce_len].*;
    const ct = wrapped[32 + nonce_len ..][0..key_len];
    const tag = wrapped[32 + nonce_len + key_len ..][0..tag_len].*;
    Aead.decrypt(&out, ct, tag, aad, nonce, k) catch return error.WrongKeyOrTampered;
    return out;
}

pub const ItemRef = struct {
    user_id: []const u8,
    agent: []const u8,
    slot: []const u8,
    version: u64,
    key_epoch: u64,
};

fn itemAad(arena: Allocator, r: ItemRef) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}|{s}|{s}|{d}|{d}", .{ r.user_id, r.agent, r.slot, r.version, r.key_epoch });
}

pub const Sealed = struct {
    nonce: [nonce_len]u8,
    /// ciphertext ‖ tag
    body: []u8,
};

pub fn seal(io: Io, arena: Allocator, vault_key: VaultKey, r: ItemRef, plaintext: []const u8) !Sealed {
    var s: Sealed = .{ .nonce = undefined, .body = try arena.alloc(u8, plaintext.len + tag_len) };
    io.random(&s.nonce);
    Aead.encrypt(s.body[0..plaintext.len], s.body[plaintext.len..][0..tag_len], plaintext, try itemAad(arena, r), s.nonce, vault_key);
    return s;
}

pub fn open(arena: Allocator, vault_key: VaultKey, r: ItemRef, nonce: []const u8, body: []const u8) ![]u8 {
    if (nonce.len != nonce_len or body.len < tag_len) return error.WrongKeyOrTampered;
    const n = body.len - tag_len;
    const out = try arena.alloc(u8, n);
    Aead.decrypt(out, body[0..n], body[n..][0..tag_len].*, try itemAad(arena, r), nonce[0..nonce_len].*, vault_key) catch return error.WrongKeyOrTampered;
    return out;
}

/// The string a mutating request signs. An empty body contributes an empty
/// hash field.
pub fn signingString(arena: Allocator, method: []const u8, path: []const u8, body: []const u8, ts_ms: i64, device_id: []const u8) ![]const u8 {
    var hex: [2 * Sha256.digest_length]u8 = undefined;
    const hash: []const u8 = if (body.len == 0) "" else blk: {
        var d: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(body, &d, .{});
        hex = std.fmt.bytesToHex(d, .lower);
        break :blk &hex;
    };
    return std.fmt.allocPrint(arena, "{s}|{s}|{s}|{d}|{s}", .{ method, path, hash, ts_ms, device_id });
}

/// base64url Ed25519 signature for X-Vault-Signature.
pub fn signRequest(arena: Allocator, keys: DeviceKeys, method: []const u8, path: []const u8, body: []const u8, ts_ms: i64, device_id: []const u8) ![]const u8 {
    const msg = try signingString(arena, method, path, body, ts_ms, device_id);
    const sig = try keys.sign.sign(msg, null);
    return encode(arena, &sig.toBytes());
}

pub fn encode(arena: Allocator, bytes: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, b64.Encoder.calcSize(bytes.len));
    return b64.Encoder.encode(out, bytes);
}

pub fn decode(arena: Allocator, text: []const u8) ![]u8 {
    const n = b64.Decoder.calcSizeForSlice(text) catch return error.BadBase64;
    const out = try arena.alloc(u8, n);
    b64.Decoder.decode(out, text) catch return error.BadBase64;
    return out;
}

/// The Harness bearer is a JWT whose `sub` is the user id. graff only reads
/// it; the edge verifies it. A dev-mode bearer is `user` or `user@org`.
pub fn userIdFromBearer(arena: Allocator, bearer: []const u8) ![]const u8 {
    var parts = std.mem.splitScalar(u8, bearer, '.');
    _ = parts.next();
    const payload = parts.next() orelse {
        const at = std.mem.indexOfScalar(u8, bearer, '@') orelse bearer.len;
        if (at == 0) return error.BadBearer;
        return bearer[0..at];
    };
    const json = try decode(arena, payload);
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return error.BadBearer;
    if (v != .object) return error.BadBearer;
    const sub = v.object.get("sub") orelse return error.BadBearer;
    if (sub != .string or sub.string.len == 0) return error.BadBearer;
    return sub.string;
}

test "wrap/unwrap round-trips to the right device and rejects the wrong aad or device" {
    const io = std.testing.io;
    const a = DeviceKeys.generate(io);
    const b = DeviceKeys.generate(io);
    var vk: VaultKey = undefined;
    io.random(&vk);
    const w = try wrap(io, vk, a.box.public_key, "u1", "dev-a");
    try std.testing.expectEqualSlices(u8, &vk, &(try unwrap(a, &w, "u1", "dev-a")));
    try std.testing.expectError(error.WrongKeyOrTampered, unwrap(a, &w, "u2", "dev-a"));
    try std.testing.expectError(error.WrongKeyOrTampered, unwrap(a, &w, "u1", "dev-b"));
    try std.testing.expectError(error.WrongKeyOrTampered, unwrap(b, &w, "u1", "dev-a"));
}

test "item seal/open round-trips and any aad field change is rejected" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var vk: VaultKey = undefined;
    io.random(&vk);
    const r: ItemRef = .{ .user_id = "u1", .agent = "graff", .slot = "codex", .version = 3, .key_epoch = 1 };
    const s = try seal(io, arena, vk, r, "{\"refresh\":\"secret\"}");
    try std.testing.expectEqualStrings("{\"refresh\":\"secret\"}", try open(arena, vk, r, &s.nonce, s.body));
    var bad = r;
    bad.version = 4;
    try std.testing.expectError(error.WrongKeyOrTampered, open(arena, vk, bad, &s.nonce, s.body));
    bad = r;
    bad.key_epoch = 2;
    try std.testing.expectError(error.WrongKeyOrTampered, open(arena, vk, bad, &s.nonce, s.body));
    bad = r;
    bad.slot = "kimi";
    try std.testing.expectError(error.WrongKeyOrTampered, open(arena, vk, bad, &s.nonce, s.body));
    s.body[0] ^= 1;
    try std.testing.expectError(error.WrongKeyOrTampered, open(arena, vk, r, &s.nonce, s.body));
}

test "device secret survives encode/decode and request signatures verify" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const k = DeviceKeys.generate(io);
    const back = try DeviceKeys.decodeSecret(&k.encodeSecret());
    try std.testing.expectEqualSlices(u8, &k.box.public_key, &back.box.public_key);
    try std.testing.expectEqualSlices(u8, &k.sign.public_key.toBytes(), &back.sign.public_key.toBytes());
    const sig_b64 = try signRequest(arena, back, "PUT", "/vault/items/graff/codex", "{}", 1700000000000, "dev-a");
    const sig = Ed25519.Signature.fromBytes((try decode(arena, sig_b64))[0..64].*);
    try sig.verify(try signingString(arena, "PUT", "/vault/items/graff/codex", "{}", 1700000000000, "dev-a"), k.sign.public_key);
    try std.testing.expectError(error.SignatureVerificationFailed, sig.verify(try signingString(arena, "PUT", "/vault/items/graff/kimi", "{}", 1700000000000, "dev-a"), k.sign.public_key));
    try std.testing.expectEqualStrings("GET|/vault||5|d", try signingString(arena, "GET", "/vault", "", 5, "d"));
}

test "userIdFromBearer reads the JWT sub and the dev forms" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const payload = try encode(arena, "{\"sub\":\"user-42\",\"aud\":\"harness-edge\"}");
    const jwt = try std.fmt.allocPrint(arena, "eyJhbGciOiJIUzI1NiJ9.{s}.sig", .{payload});
    try std.testing.expectEqualStrings("user-42", try userIdFromBearer(arena, jwt));
    try std.testing.expectEqualStrings("alice", try userIdFromBearer(arena, "alice@org1"));
    try std.testing.expectEqualStrings("bob", try userIdFromBearer(arena, "bob"));
    const pub_key: [32]u8 = @splat(1);
    try std.testing.expectEqual(@as(usize, 8), fingerprint(pub_key).len);
}
