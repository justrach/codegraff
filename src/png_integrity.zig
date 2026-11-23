//! Bounded structural integrity checks for inline PNG attachments.
//! This verifies chunk framing and CRCs, not compressed pixel decoding.
const std = @import("std");

const signature = "\x89PNG\r\n\x1a\n";

pub fn valid(bytes: []const u8) bool {
    if (!std.mem.startsWith(u8, bytes, signature)) return false;
    var offset: usize = signature.len;
    var saw_ihdr = false;
    var saw_idat = false;
    while (offset <= bytes.len and bytes.len - offset >= 12) {
        const remaining = bytes.len - offset;
        const len_u32 = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        if (len_u32 > remaining - 12) return false;
        const len: usize = @intCast(len_u32);
        const kind = bytes[offset + 4 ..][0..4];
        const data_start = offset + 8;
        const crc_at = data_start + len;
        const crc = std.mem.readInt(u32, bytes[crc_at..][0..4], .big);
        if (std.hash.Crc32.hash(bytes[offset + 4 .. crc_at]) != crc) return false;

        if (!saw_ihdr) {
            if (!std.mem.eql(u8, kind, "IHDR") or len != 13) return false;
            if (std.mem.readInt(u32, bytes[data_start..][0..4], .big) == 0 or
                std.mem.readInt(u32, bytes[data_start + 4 ..][0..4], .big) == 0) return false;
            saw_ihdr = true;
        } else if (std.mem.eql(u8, kind, "IHDR")) {
            return false;
        }

        if (std.mem.eql(u8, kind, "IDAT")) saw_idat = true;
        if (std.mem.eql(u8, kind, "IEND")) return len == 0 and saw_idat;
        offset = crc_at + 4;
    }
    return false;
}

const good_png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x00\x00\x00\x00\x3a\x7e\x9b\x55\x00\x00\x00\x0aIDATx\x9c\x63\x60\x00\x00\x00\x02\x00\x01\x48\xaf\xa4\x71\x00\x00\x00\x00IEND\xae\x42\x60\x82";

test "PNG integrity accepts a complete CRC-checked PNG" {
    try std.testing.expect(valid(good_png));
}

test "#1926 PNG integrity rejects missing IHDR CRC, bad lengths, and later CRC errors" {
    var missing_crc: [good_png.len - 4]u8 = undefined;
    @memcpy(missing_crc[0..29], good_png[0..29]);
    @memcpy(missing_crc[29..], good_png[33..]);
    try std.testing.expect(!valid(&missing_crc));

    var bad_crc = good_png.*;
    bad_crc[28] ^= 1;
    try std.testing.expect(!valid(&bad_crc));

    var bad_length = good_png.*;
    bad_length[8] = 0xff;
    try std.testing.expect(!valid(&bad_length));
    try std.testing.expect(!valid(good_png[0 .. good_png.len - 1]));

    var later_crc = good_png.*;
    later_crc[44] ^= 1;
    try std.testing.expect(!valid(&later_crc));
}
