//! Hashing, serialization, and nonce helpers for learning-store objects.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn rawSha256(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn domainId(domain: []const u8, bytes: []const u8) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hash.update(&.{0});
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, len[0..], @intCast(bytes.len), .big);
    hash.update(&len);
    hash.update(bytes);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn jsonBytes(gpa: Allocator, value: anytype) ![]u8 {
    var allocating: Io.Writer.Allocating = .init(gpa);
    defer allocating.deinit();
    var stringify: std.json.Stringify = .{ .writer = &allocating.writer };
    try stringify.write(value);
    try allocating.writer.writeByte('\n');
    return gpa.dupe(u8, allocating.writer.buffered());
}

pub fn randomId(io: Io) ![64]u8 {
    var raw: [32]u8 = undefined;
    // Trial nonces feed trial-ID derivation, so weak fallback randomness would
    // silently weaken an integrity boundary. Fail closed instead.
    try io.randomSecure(&raw);
    return std.fmt.bytesToHex(raw, .lower);
}
