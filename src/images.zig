//! Pull image URLs out of assistant/tool output text so `/images` can open them
//! in a browser — the terminal can't render images, and a GitHub issue body
//! (via `gh issue view`) carries them as markdown or attachment URLs. Recognizes
//! markdown images (`![alt](url)`), bare URLs whose path ends in an image
//! extension, and GitHub attachment hosts that serve images without one.
//! Order-preserving, de-duplicated, arena-owned. Kept pure (no Agent/IO) so the
//! load-bearing logic is unit-testable without a browser. (#103)

const std = @import("std");

const IMAGE_EXTS = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp", ".avif" };

// Hosts that serve user-pasted images WITHOUT a file extension, so a bare URL to
// one still counts as an image.
const IMAGE_HOSTS = [_][]const u8{
    "user-images.githubusercontent.com",
    "private-user-images.githubusercontent.com",
    "github.com/user-attachments/",
};

/// Bytes that continue a URL. Stops at whitespace and the delimiters that end a
/// URL in prose, markdown, or serialized JSON (a `\n`/`\"` there ends the string).
fn isUrlByte(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', '"', '\'', '`', '<', '>', '(', ')', '[', ']', '{', '}', '|', '\\' => false,
        else => true,
    };
}

fn trimTrailingPunct(url: []const u8) []const u8 {
    var end = url.len;
    while (end > 0) : (end -= 1) {
        switch (url[end - 1]) {
            '.', ',', ';', ':', '!', '?' => {},
            else => break,
        }
    }
    return url[0..end];
}

fn isHttpUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "http://");
}

fn looksLikeImage(url: []const u8) bool {
    for (IMAGE_HOSTS) |h| if (std.mem.indexOf(u8, url, h) != null) return true;
    var path = url;
    if (std.mem.indexOfScalar(u8, path, '?')) |q| path = path[0..q];
    if (std.mem.indexOfScalar(u8, path, '#')) |f| path = path[0..f];
    for (IMAGE_EXTS) |ext| {
        if (path.len >= ext.len and std.ascii.eqlIgnoreCase(path[path.len - ext.len ..], ext)) return true;
    }
    return false;
}

/// Extract image URLs from `text`, order-preserving and de-duplicated. The
/// returned slice and its entries are owned by `arena`.
pub fn extractImageUrls(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMap(void) = .init(arena);

    var i: usize = 0;
    while (i < text.len) {
        // Markdown image `![alt](url)` — the `!` declares it an image, so accept
        // the URL regardless of extension.
        if (text[i] == '!' and i + 1 < text.len and text[i + 1] == '[') {
            if (std.mem.indexOfPos(u8, text, i + 2, "](")) |bar| {
                const us = bar + 2;
                if (std.mem.indexOfScalarPos(u8, text, us, ')')) |ue| {
                    var dest = std.mem.trim(u8, text[us..ue], " \t");
                    // Drop a CommonMark title — ![alt](url "title") — at the space.
                    if (std.mem.indexOfAny(u8, dest, " \t")) |sp| dest = dest[0..sp];
                    // Unwrap an angle-bracket URL — ![alt](<url>).
                    if (dest.len >= 2 and dest[0] == '<' and dest[dest.len - 1] == '>') dest = dest[1 .. dest.len - 1];
                    try add(arena, &out, &seen, dest, false);
                    i = ue + 1;
                    continue;
                }
            }
        }
        // Bare URL — accept only if it looks like an image.
        const scheme: usize = if (std.mem.startsWith(u8, text[i..], "https://"))
            "https://".len
        else if (std.mem.startsWith(u8, text[i..], "http://"))
            "http://".len
        else
            0;
        if (scheme != 0) {
            var j = i + scheme;
            while (j < text.len and isUrlByte(text[j])) : (j += 1) {}
            try add(arena, &out, &seen, trimTrailingPunct(text[i..j]), true);
            i = j;
            continue;
        }
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

fn add(
    arena: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    seen: *std.StringHashMap(void),
    url: []const u8,
    require_image: bool,
) !void {
    if (!isHttpUrl(url)) return; // opened in a browser, so must be http(s)
    if (require_image and !looksLikeImage(url)) return;
    if (seen.contains(url)) return;
    const owned = try arena.dupe(u8, url);
    try seen.put(owned, {});
    try out.append(arena, owned);
}

const testing = std.testing;

fn expectUrls(text: []const u8, expected: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try extractImageUrls(arena.allocator(), text);
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try testing.expectEqualStrings(e, g);
}

test "extractImageUrls: markdown image, with and without extension" {
    try expectUrls("see ![diagram](https://ex.com/a.png) here", &.{"https://ex.com/a.png"});
    try expectUrls("![chart](https://ex.com/chart?v=2)", &.{"https://ex.com/chart?v=2"});
}

test "extractImageUrls: bare image URL by extension (case-insensitive), skips non-image URLs" {
    try expectUrls("open https://ex.com/b.JPG now", &.{"https://ex.com/b.JPG"});
    try expectUrls("visit https://ex.com/page and https://ex.com/docs", &.{});
}

test "extractImageUrls: github attachment hosts without an extension" {
    try expectUrls(
        "![img](https://github.com/user-attachments/assets/abc-123)",
        &.{"https://github.com/user-attachments/assets/abc-123"},
    );
    try expectUrls(
        "raw https://user-images.githubusercontent.com/1/x",
        &.{"https://user-images.githubusercontent.com/1/x"},
    );
}

test "extractImageUrls: de-dupes and strips trailing sentence punctuation" {
    try expectUrls(
        "a https://ex.com/a.png and again https://ex.com/a.png.",
        &.{"https://ex.com/a.png"},
    );
}

test "extractImageUrls: order-preserving across multiple images" {
    try expectUrls(
        "![1](https://ex.com/1.png) then https://ex.com/2.gif",
        &.{ "https://ex.com/1.png", "https://ex.com/2.gif" },
    );
}

test "extractImageUrls: serialized-JSON context bounds the URL at \\n and quotes" {
    // /images scans the serialized message JSON, where a URL is followed by an
    // escaped \n (backslash+n) or a closing quote.
    try expectUrls("{\"output\":\"pic https://ex.com/c.png\\nmore\"}", &.{"https://ex.com/c.png"});
    try expectUrls("{\"content\":\"https://ex.com/d.webp\"}", &.{"https://ex.com/d.webp"});
}

test "extractImageUrls: empty, no-match, and non-http are skipped" {
    try expectUrls("", &.{});
    try expectUrls("no urls here at all", &.{});
    try expectUrls("relative ![x](img/local.png) is skipped", &.{});
}

test "extractImageUrls: markdown CommonMark title and angle-bracket forms" {
    try expectUrls("![a](https://ex.com/x.png \"a caption\")", &.{"https://ex.com/x.png"});
    try expectUrls("![a](<https://ex.com/y.png>)", &.{"https://ex.com/y.png"});
    // Serialized JSON escapes the title's quotes; the URL still ends at the space.
    try expectUrls("![a](https://ex.com/z.png \\\"t\\\")", &.{"https://ex.com/z.png"});
}
