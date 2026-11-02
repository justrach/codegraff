//! An image's media type from its bytes, not its name (#1762).
//!
//! Providers check the declared media type against the pixels and reject a
//! mismatch, and the rejected block stays in the transcript, so every later
//! turn fails the same way. A WebP saved as `shot.png` used to go out as
//! `image/png` because the type came from the file extension. Every path that
//! holds the bytes asks here first; the four types below are the raster
//! formats every vision provider accepts.

const std = @import("std");

/// The formats `sniff` recognizes, for error text.
pub const supported_names = "PNG, JPEG, GIF, or WebP";

/// The media type the bytes actually are, or null when they are none of the
/// four supported raster formats (BMP, TIFF, HEIC, SVG, text, truncated...).
pub fn sniff(bytes: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return "image/png";
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return "image/jpeg";
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return "image/gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    return null;
}

/// `sniff` on base64 text, decoding only the 12-byte head every signature
/// fits in. Null for unrecognized bytes or base64 that does not decode.
pub fn sniffBase64(b64: []const u8) ?[]const u8 {
    const dec = std.base64.standard.Decoder;
    var head: [12]u8 = undefined;
    // 16 base64 chars are exactly 12 bytes with no padding; shorter input
    // decodes whole (its own padding included).
    const text = b64[0..@min(b64.len, 16)];
    const n = dec.calcSizeForSlice(text) catch return null;
    if (n > head.len) return null;
    dec.decode(head[0..n], text) catch return null;
    return sniff(head[0..n]);
}

/// The type to send for pixels that arrived with a declared type (an MCP or
/// ACP `mimeType`, a request `media_type`): the bytes win when they are a
/// supported format, and the declaration stands only when they are not.
pub fn resolveDeclared(b64: []const u8, declared: []const u8) []const u8 {
    return sniffBase64(b64) orelse declared;
}

const webp_head = "RIFF\x24\x00\x00\x00WEBPVP8 ";

test "sniff: each supported format by its signature, whatever the file is called" {
    try std.testing.expectEqualStrings("image/png", sniff("\x89PNG\r\n\x1a\n\x00\x00").?);
    try std.testing.expectEqualStrings("image/jpeg", sniff("\xff\xd8\xff\xe0\x00\x10JFIF").?);
    try std.testing.expectEqualStrings("image/gif", sniff("GIF89a\x01\x00").?);
    try std.testing.expectEqualStrings("image/gif", sniff("GIF87a\x01\x00").?);
    try std.testing.expectEqualStrings("image/webp", sniff(webp_head).?);
}

test "sniff: unsupported or truncated bytes are not guessed" {
    try std.testing.expect(sniff("") == null);
    try std.testing.expect(sniff("BM\x36\x00\x00\x00") == null); // BMP
    try std.testing.expect(sniff("II*\x00\x08\x00\x00\x00") == null); // TIFF
    try std.testing.expect(sniff("\x00\x00\x00\x18ftypheic") == null); // HEIC
    try std.testing.expect(sniff("<svg xmlns=") == null);
    try std.testing.expect(sniff("RIFF\x24\x00\x00\x00WAVE") == null); // RIFF, but audio
    try std.testing.expect(sniff("RIFF\x24\x00") == null); // truncated WebP
    try std.testing.expect(sniff("\x89PNG") == null); // truncated PNG
}

test "#1762: WebP bytes declared as image/png resolve to image/webp" {
    var b64: [std.base64.standard.Encoder.calcSize(webp_head.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&b64, webp_head);
    try std.testing.expectEqualStrings("image/webp", sniffBase64(&b64).?);
    try std.testing.expectEqualStrings("image/webp", resolveDeclared(&b64, "image/png"));
    // A real PNG keeps its type; bytes we cannot place keep the declaration.
    try std.testing.expectEqualStrings("image/png", resolveDeclared("iVBORw0KGgo=", "image/jpeg"));
    try std.testing.expectEqualStrings("image/png", resolveDeclared("aGVsbG8=", "image/png"));
    try std.testing.expect(sniffBase64("!!!!") == null);
    try std.testing.expect(sniffBase64("") == null);
}
