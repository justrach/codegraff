//! Upright pixels for a photo whose EXIF orientation tag says it was stored
//! turned.
//!
//! A phone stores the sensor's pixels as captured and writes the way to hold
//! them into EXIF tag 0x0112. Viewers honor the tag; a model does not see it,
//! so a portrait photo reached the model sideways and was described with
//! confidence anyway. Every image path that encodes bytes for the wire asks
//! here first. The tag is read from a JPEG's APP1 `Exif` segment or a PNG's
//! `eXIf` chunk (which `sips` carries into a downscaled copy). On macOS the
//! pixels are turned with `sips` and the tag in the result is reset to 1, so
//! a provider that does honor EXIF cannot turn them a second time. Where they
//! cannot be turned the bytes go out unchanged and the caller can say so.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const clip = @import("vision_clipboard.zig");
const sniff = @import("image_sniff.zig");

/// Where the orientation value lives in a file's bytes.
pub const Tag = struct {
    /// 1 is upright; 2..8 are the EXIF mirror/rotate cases.
    value: u16,
    /// Offset of the 2-byte value.
    at: usize,
    big_endian: bool,
    /// A PNG `eXIf` chunk's type offset and data length: its CRC covers the
    /// type and the data, so a patch has to rewrite it.
    png_chunk: ?struct { start: usize, len: usize } = null,
};

/// The orientation tag in a JPEG or PNG, or null when there is none (or the
/// metadata is malformed — never guessed).
pub fn find(bytes: []const u8) ?Tag {
    if (std.mem.startsWith(u8, bytes, "\xff\xd8")) return findJpeg(bytes);
    if (std.mem.startsWith(u8, bytes, clip.png_magic)) return findPng(bytes);
    return null;
}

fn findJpeg(bytes: []const u8) ?Tag {
    var i: usize = 2;
    while (i + 4 <= bytes.len) {
        if (bytes[i] != 0xff) return null;
        const marker = bytes[i + 1];
        if (marker == 0xff) {
            i += 1; // fill byte
            continue;
        }
        if (marker == 0x01 or (marker >= 0xd0 and marker <= 0xd8)) {
            i += 2; // standalone marker, no length
            continue;
        }
        if (marker == 0xda or marker == 0xd9) return null; // scan data: metadata is over
        const len = std.mem.readInt(u16, bytes[i + 2 ..][0..2], .big);
        if (len < 2 or i + 2 + len > bytes.len) return null;
        const seg = bytes[i + 4 .. i + 2 + len];
        if (marker == 0xe1 and std.mem.startsWith(u8, seg, "Exif\x00\x00"))
            return findTiff(bytes, i + 4 + 6, seg.len - 6);
        i += 2 + len;
    }
    return null;
}

fn findPng(bytes: []const u8) ?Tag {
    var i: usize = clip.png_magic.len;
    while (i + 12 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[i..][0..4], .big);
        if (len > bytes.len - i - 12) return null;
        const kind = bytes[i + 4 .. i + 8];
        if (std.mem.eql(u8, kind, "eXIf")) {
            var tag = findTiff(bytes, i + 8, len) orelse return null;
            tag.png_chunk = .{ .start = i + 4, .len = len };
            return tag;
        }
        if (std.mem.eql(u8, kind, "IEND")) return null;
        i += 12 + len;
    }
    return null;
}

/// IFD0 of the TIFF structure at `bytes[base..][0..len]`.
fn findTiff(bytes: []const u8, base: usize, len: usize) ?Tag {
    if (len < 8 or base + len > bytes.len) return null;
    const t = bytes[base .. base + len];
    const endian: std.builtin.Endian = if (std.mem.startsWith(u8, t, "II*\x00"))
        .little
    else if (std.mem.startsWith(u8, t, "MM\x00*"))
        .big
    else
        return null;
    const ifd = std.mem.readInt(u32, t[4..8], endian);
    if (ifd > t.len - 2) return null;
    const count = std.mem.readInt(u16, t[ifd..][0..2], endian);
    var e: usize = ifd + 2;
    var n: usize = 0;
    while (n < count and e + 12 <= t.len) : ({
        n += 1;
        e += 12;
    }) {
        if (std.mem.readInt(u16, t[e..][0..2], endian) != 0x0112) continue;
        if (std.mem.readInt(u16, t[e + 2 ..][0..2], endian) != 3) return null; // SHORT
        return .{
            .value = std.mem.readInt(u16, t[e + 8 ..][0..2], endian),
            .at = base + e + 8,
            .big_endian = endian == .big,
        };
    }
    return null;
}

/// Reset the tag at `tag` to 1 (upright), fixing a PNG chunk's CRC.
pub fn markUpright(bytes: []u8, tag: Tag) void {
    std.mem.writeInt(u16, bytes[tag.at..][0..2], 1, if (tag.big_endian) .big else .little);
    const c = tag.png_chunk orelse return;
    const crc = std.hash.Crc32.hash(bytes[c.start .. c.start + 4 + c.len]);
    std.mem.writeInt(u32, bytes[c.start + 4 + c.len ..][0..4], crc, .big);
}

/// The `sips` operations that make orientation `value` upright. Order
/// matters: sips applies them as given (checked against an EXIF-aware
/// decoder for all eight values).
pub fn sipsOps(value: u16) ?[]const []const u8 {
    return switch (value) {
        2 => &.{ "-f", "horizontal" },
        3 => &.{ "-r", "180" },
        4 => &.{ "-f", "vertical" },
        5 => &.{ "-f", "horizontal", "-r", "90" },
        6 => &.{ "-r", "90" },
        7 => &.{ "-f", "horizontal", "-r", "270" },
        8 => &.{ "-r", "270" },
        else => null,
    };
}

/// How to view pixels left in orientation `value`, for the model.
pub fn hint(value: u16) []const u8 {
    return switch (value) {
        2 => "mirrored left-to-right",
        3 => "upside down",
        4 => "mirrored top-to-bottom",
        5, 7 => "mirrored and turned on its side",
        6 => "turned 90° counter-clockwise (rotate it 90° clockwise to view it upright)",
        8 => "turned 90° clockwise (rotate it 90° counter-clockwise to view it upright)",
        else => "not upright",
    };
}

/// Turn `in` upright for orientation `value`, writing `out` in the same
/// encoding. False when it cannot be done here.
pub const Rotator = *const fn (io: Io, in: []const u8, value: u16, out: []const u8) bool;

pub fn sipsRotate(io: Io, in: []const u8, value: u16, out: []const u8) bool {
    if (builtin.os.tag != .macos) return false;
    const ops = sipsOps(value) orelse return false;
    var argv: [8][]const u8 = undefined;
    argv[0] = "sips";
    @memcpy(argv[1 .. 1 + ops.len], ops);
    argv[1 + ops.len ..][0..3].* = .{ in, "--out", out };
    return clip.runQuiet(io, argv[0 .. ops.len + 4]);
}

pub const Outcome = union(enum) {
    /// No tag, already upright, or a value no viewer acts on either.
    as_is,
    /// Upright bytes, allocated with the caller's allocator; tag reset to 1.
    turned: []u8,
    /// Not upright, and could not be turned; the bytes go out as they are.
    stuck: u16,
};

/// `data` holds the bytes of `path`. The turned copy has to stay inside the
/// staging budget and keep its type, or the original is kept.
pub fn upright(io: Io, gpa: Allocator, path: []const u8, data: []const u8, rotate: Rotator) Outcome {
    const tag = find(data) orelse return .as_is;
    if (tag.value < 2 or tag.value > 8) return .as_is;
    const stuck: Outcome = .{ .stuck = tag.value };
    const kind = sniff.sniff(data) orelse return stuck;
    const out = clip.tempPath(io, gpa, if (data[0] == 0xff) "jpg" else "png") orelse return stuck;
    defer clip.discard(io, gpa, out);
    if (!rotate(io, path, tag.value, out)) return stuck;
    const limit: Io.Limit = .limited(@intCast(clip.max_staged_image_bytes));
    const turned = Io.Dir.cwd().readFileAlloc(io, out, gpa, limit) catch return stuck;
    const same = if (sniff.sniff(turned)) |k| std.mem.eql(u8, k, kind) else false;
    if (!same) {
        gpa.free(turned);
        return stuck;
    }
    if (find(turned)) |t| markUpright(turned, t);
    return .{ .turned = turned };
}

/// `upright` for an arena-owned buffer: the turned copy, or `data` itself.
pub fn uprightIn(io: Io, arena: Allocator, path: []const u8, data: []u8) []u8 {
    return switch (upright(io, arena, path, data, sipsRotate)) {
        .turned => |t| t,
        .as_is, .stuck => data,
    };
}

// ── tests ─────────────────────────────────────────────────────────────────

/// A JPEG head: SOI, an APP0, then an APP1 Exif segment whose IFD0 holds
/// one unrelated entry and then Orientation = `value`.
pub fn testJpeg(comptime big: bool, comptime value: u16) [52]u8 {
    const E: std.builtin.Endian = if (big) .big else .little;
    var b: [52]u8 = @splat(0);
    @memcpy(b[0..6], "\xff\xd8\xff\xe0\x00\x02");
    @memcpy(b[6..10], "\xff\xe1\x00\x2c"); // APP1, len 44: 2 + 6 + 36
    @memcpy(b[10..16], "Exif\x00\x00");
    @memcpy(b[16..20], if (big) "MM\x00*" else "II*\x00");
    std.mem.writeInt(u32, b[20..24], 8, E); // IFD0 at TIFF offset 8
    std.mem.writeInt(u16, b[24..26], 2, E); // two entries
    std.mem.writeInt(u16, b[26..28], 0x010f, E); // Make, skipped
    std.mem.writeInt(u16, b[38..40], 0x0112, E);
    std.mem.writeInt(u16, b[40..42], 3, E);
    std.mem.writeInt(u32, b[42..46], 1, E);
    std.mem.writeInt(u16, b[46..48], value, E);
    return b;
}

test "image_orient: finds Orientation in a JPEG's Exif segment, either byte order" {
    const le = testJpeg(false, 6);
    const tag = find(&le).?;
    try std.testing.expectEqual(@as(u16, 6), tag.value);
    try std.testing.expectEqual(@as(usize, 46), tag.at);
    try std.testing.expectEqual(@as(u16, 8), find(&testJpeg(true, 8)).?.value);
    var patched = le;
    markUpright(&patched, tag);
    try std.testing.expectEqual(@as(u16, 1), find(&patched).?.value);
}

test "image_orient: no tag, truncated, or malformed metadata is never guessed" {
    try std.testing.expect(find("") == null);
    try std.testing.expect(find("\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xda") == null);
    const ok = testJpeg(false, 6);
    try std.testing.expect(find(ok[0..40]) == null); // segment runs past the end
    var bad_ifd = ok;
    std.mem.writeInt(u32, bad_ifd[20..24], 0xffff, .little);
    try std.testing.expect(find(&bad_ifd) == null);
    var wrong_type = ok;
    std.mem.writeInt(u16, wrong_type[40..42], 4, .little); // LONG, not SHORT
    try std.testing.expect(find(&wrong_type) == null);
    try std.testing.expect(find("GIF89a\x01\x00") == null);
}

test "image_orient: a PNG eXIf chunk is found and its CRC is rewritten on patch" {
    const j = testJpeg(false, 3);
    const tiff = j[16..];
    var b: [8 + 12 + tiff.len + 12]u8 = undefined;
    @memcpy(b[0..8], clip.png_magic);
    std.mem.writeInt(u32, b[8..12], tiff.len, .big);
    @memcpy(b[12..16], "eXIf");
    @memcpy(b[16 .. 16 + tiff.len], tiff);
    const crc_at = 16 + tiff.len;
    std.mem.writeInt(u32, b[crc_at..][0..4], std.hash.Crc32.hash(b[12..crc_at]), .big);
    @memcpy(b[crc_at + 4 ..][0..12], "\x00\x00\x00\x00IEND\xaeB`\x82");
    const tag = find(&b).?;
    try std.testing.expectEqual(@as(u16, 3), tag.value);
    markUpright(&b, tag);
    try std.testing.expectEqual(@as(u16, 1), find(&b).?.value);
    try std.testing.expectEqual(std.hash.Crc32.hash(b[12..crc_at]), std.mem.readInt(u32, b[crc_at..][0..4], .big));
}

test "image_orient: every non-upright value maps to sips operations and a hint" {
    try std.testing.expect(sipsOps(1) == null);
    try std.testing.expect(sipsOps(9) == null);
    var v: u16 = 2;
    while (v <= 8) : (v += 1) {
        try std.testing.expect(sipsOps(v) != null);
        try std.testing.expect(!std.mem.eql(u8, hint(v), "not upright"));
    }
    try std.testing.expectEqualStrings("-r", sipsOps(6).?[0]);
    try std.testing.expectEqualStrings("90", sipsOps(6).?[1]);
}

fn rotateToFixture(io: Io, in: []const u8, value: u16, out: []const u8) bool {
    _ = .{ in, value };
    // sips turns the pixels but keeps the tag; upright() must reset it.
    Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = &testJpeg(false, 6) }) catch return false;
    return true;
}

fn cannotRotate(io: Io, in: []const u8, value: u16, out: []const u8) bool {
    _ = .{ io, in, value, out };
    return false;
}

test "image_orient: upright turns a tagged photo, resets the tag, and reports when it cannot" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // temps live in /tmp
    const a = std.testing.allocator;
    const io = std.testing.io;
    const sideways = testJpeg(false, 6);
    switch (upright(io, a, "unused.jpg", &sideways, rotateToFixture)) {
        .turned => |t| {
            defer a.free(t);
            try std.testing.expectEqual(@as(u16, 1), find(t).?.value);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(Outcome{ .stuck = 6 }, upright(io, a, "unused.jpg", &sideways, cannotRotate));
    try std.testing.expectEqual(Outcome.as_is, upright(io, a, "unused.jpg", &testJpeg(false, 1), cannotRotate));
}
