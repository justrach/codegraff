//! The attachment trailer an ACP client leaves in prompt text (#1865).
//!
//! A client that could not inline an upload as an ACP `image` block sends its
//! path instead, in a trailer after the prompt:
//!
//!     Attached images (local files — open them to view):
//!     - /abs/uploads/ab12-shot.png
//!
//! Uploads live outside the session's working directory, so the model's
//! `read_file` on that path was refused and it fell back to copying the file
//! with the shell. The file tools stay confined. The prompt path reads the
//! trailer the way it reads `@[path]` markers: a ref whose bytes are an image
//! is staged as a native vision block, and its line leaves the text, so the
//! model is never pointed at a path its tools cannot open. A ref that could
//! not be staged keeps its line.
//!
//! A prompt that arrives while a turn is running is normally steered into it
//! as raw text. One carrying this trailer is not (acp_inbox.trySteer): it
//! goes back to the client and returns as an ordinary prompt, which takes
//! the path above.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const PendingImage = @import("vision.zig").PendingImage;
const sniff = @import("image_sniff.zig");

/// The header's start, matched without regard to case after a blank line. The
/// line must also end `):`.
const marker = "\n\nattached images (local files";

pub const Trailer = struct {
    text: []const u8,
    /// The blank line before the header.
    start: usize,
    /// The newline after the header line, or `text.len`.
    header_end: usize,
    /// The newline after the last ref line, or `text.len`.
    end: usize,

    pub fn refs(self: Trailer) Refs {
        return .{ .text = self.text, .pos = self.header_end };
    }

    fn header(self: Trailer) []const u8 {
        return std.mem.trimEnd(u8, self.text[self.start + 2 .. self.header_end], "\r");
    }
};

/// The `- <path>` lines under the header, in order. Stops at the first line
/// that is not one.
pub const Refs = struct {
    text: []const u8,
    /// The newline before the next candidate line, or `text.len`.
    pos: usize,

    pub fn next(self: *Refs) ?[]const u8 {
        while (self.pos < self.text.len) {
            const line_start = self.pos + 1;
            const line_end = std.mem.indexOfScalarPos(u8, self.text, line_start, '\n') orelse self.text.len;
            const line = std.mem.trimStart(u8, self.text[line_start..line_end], " \t");
            if (!std.mem.startsWith(u8, line, "- ")) return null;
            self.pos = line_end;
            const path = std.mem.trim(u8, line[2..], " \t\r");
            if (path.len > 0) return path;
        }
        return null;
    }
};

/// The first well-formed trailer that names at least one path.
pub fn find(text: []const u8) ?Trailer {
    var from: usize = 0;
    while (std.ascii.findIgnoreCasePos(text, from, marker)) |start| {
        const header_start = start + 2;
        const header_end = std.mem.indexOfScalarPos(u8, text, header_start, '\n') orelse text.len;
        from = header_start;
        if (!std.mem.endsWith(u8, std.mem.trimEnd(u8, text[header_start..header_end], " \t\r"), "):")) continue;
        var it: Refs = .{ .text = text, .pos = header_end };
        if (it.next() == null) continue;
        while (it.next()) |_| {}
        return .{ .text = text, .start = start, .header_end = header_end, .end = it.pos };
    }
    return null;
}

/// Whether the file's first bytes are a raster image graff can send. The
/// name proves nothing, and a ref that is not an image is never read further.
pub fn isImageFile(io: Io, path: []const u8) bool {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    var head: [24]u8 = undefined;
    const got = file.readPositionalAll(io, &head, 0) catch return false;
    return sniff.sniff(head[0..got]) != null;
}

/// `text` without the trailer lines whose image is in `staged` (matched by
/// label, the path as the trailer spells it). The header goes with its last
/// line; lines that were not staged stay under it. Unchanged when nothing
/// matched or on allocation failure.
pub fn withoutStaged(arena: Allocator, text: []const u8, staged: []const PendingImage) []const u8 {
    const trailer = find(text) orelse return text;
    var kept: usize = 0;
    var dropped: usize = 0;
    var it = trailer.refs();
    while (it.next()) |path| {
        if (isStaged(staged, path)) dropped += 1 else kept += 1;
    }
    if (dropped == 0) return text;
    var aw: Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.writeAll(text[0..trailer.start]) catch return text;
    if (kept > 0) {
        w.print("\n\n{s}", .{trailer.header()}) catch return text;
        it = trailer.refs();
        while (it.next()) |path| {
            if (!isStaged(staged, path)) w.print("\n- {s}", .{path}) catch return text;
        }
    }
    w.writeAll(text[trailer.end..]) catch return text;
    return aw.written();
}

fn isStaged(staged: []const PendingImage, path: []const u8) bool {
    for (staged) |img| {
        if (std.mem.eql(u8, img.label, path)) return true;
    }
    return false;
}

const sample = "what colour is this?\n\nAttached images (local files — open them to view):\n- /up/ab12-red.png\n- /up/cd34-blue.png";

fn images(comptime paths: []const []const u8) [paths.len]PendingImage {
    var out: [paths.len]PendingImage = undefined;
    for (paths, &out) |path, *img| img.* = .{ .media_type = "image/png", .b64 = "x", .label = path };
    return out;
}

test "#1865: the trailer's refs are read in order, and only under a real header" {
    var it = find(sample).?.refs();
    try std.testing.expectEqualStrings("/up/ab12-red.png", it.next().?);
    try std.testing.expectEqualStrings("/up/cd34-blue.png", it.next().?);
    try std.testing.expect(it.next() == null);

    // Case and CRLF do not matter; text after the refs is not a ref.
    var crlf = find("hi\n\nATTACHED IMAGES (local files):\r\n  - a.png\r\nthanks").?.refs();
    try std.testing.expectEqualStrings("a.png", crlf.next().?);
    try std.testing.expect(crlf.next() == null);

    // Not a trailer: no blank line before it, no `):`, or no path under it.
    try std.testing.expect(find("see\nAttached images (local files):\n- a.png") == null);
    try std.testing.expect(find("see\n\nAttached images (local files\n- a.png") == null);
    try std.testing.expect(find("see\n\nAttached images (local files):\nnothing here") == null);
    try std.testing.expect(find("- /etc/passwd") == null);
}

test "#1865: staged refs leave the text; a ref that was not staged keeps its line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Every ref staged: the model reads the prompt alone.
    const both = images(&.{ "/up/ab12-red.png", "/up/cd34-blue.png" });
    try std.testing.expectEqualStrings("what colour is this?", withoutStaged(a, sample, &both));

    // One staged: the other still names its file under the header.
    const one = images(&.{"/up/ab12-red.png"});
    try std.testing.expectEqualStrings(
        "what colour is this?\n\nAttached images (local files — open them to view):\n- /up/cd34-blue.png",
        withoutStaged(a, sample, &one),
    );

    // None staged, or no trailer at all: the same bytes come back.
    try std.testing.expectEqual(sample.ptr, withoutStaged(a, sample, &.{}).ptr);
    const plain = "no attachments here";
    try std.testing.expectEqual(plain.ptr, withoutStaged(a, plain, &both).ptr);

    // Text after the trailer survives it.
    const tail = sample ++ "\n\nthanks";
    try std.testing.expectEqualStrings("what colour is this?\n\nthanks", withoutStaged(a, tail, &both));
}

test "#1865: only a file whose bytes are an image counts as one" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "shot.bin", .data = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.png", .data = "not an image at all" });
    var buf: [256]u8 = undefined;
    try std.testing.expect(isImageFile(io, try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/shot.bin", .{tmp.sub_path})));
    try std.testing.expect(!isImageFile(io, try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/notes.png", .{tmp.sub_path})));
    try std.testing.expect(!isImageFile(io, try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/missing.png", .{tmp.sub_path})));
}
