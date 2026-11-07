//! Terminal bracketed-paste data:image URI staging. Never let rejected pixels
//! become prompt text (including an over-budget or truncated paste).
const std = @import("std");
const Agent = @import("agent.zig").Agent;
const vision = @import("vision.zig");
const queue = @import("vision_queue.zig");
const image = @import("readline_image.zig");
const PasteStore = @import("readline_paste.zig").Store;
const Allocator = std.mem.Allocator;

pub const max_paste_bytes: usize = std.base64.standard.Encoder.calcSize(@intCast(vision.max_staged_image_bytes)) + 128;
pub const Result = enum { not_uri, staged, invalid, too_large, unsupported, full, no_vision, out_of_memory };

pub fn isCandidate(paste: []const u8) bool {
    const text = std.mem.trimStart(u8, paste, " \t\r\n");
    return text.len >= "data:image".len and std.ascii.eqlIgnoreCase(text[0.."data:image".len], "data:image");
}

pub fn feedback(r: Result) []const u8 {
    return switch (r) {
        .not_uri, .staged => "",
        .invalid => "image data URI is malformed or its bytes do not match its MIME type; image not attached",
        .too_large => "image data URI exceeds the 3.5 MB image limit; image not attached",
        .unsupported => "unsupported image data URI type (use PNG, JPEG, GIF or WebP); image not attached",
        .full => "image queue is full (16 images); image not attached",
        .no_vision => vision.no_vision_message,
        .out_of_memory => "couldn't stage image data URI (out of memory); image not attached",
    };
}

fn matchesMagic(mime: []const u8, bytes: []const u8) bool {
    const actual = @import("image_sniff.zig").sniff(bytes) orelse return false;
    return std.mem.eql(u8, mime, actual);
}

/// Called on the actual bracketed-paste path, before normal paste expansion.
/// Even malformed image candidates are consumed, never inserted as text.
pub fn stagePaste(root: *Agent, gpa: Allocator, buf: *std.ArrayList(u8), cur: *usize, marks: *std.ArrayList([]const u8), pastes: *PasteStore, paste: []const u8, truncated: bool) Result {
    if (!isCandidate(paste)) return .not_uri;
    if (truncated or paste.len > max_paste_bytes) return .too_large;
    const text = std.mem.trim(u8, paste, " \t\r\n");
    const sep = std.mem.indexOfScalar(u8, text, ';') orelse return .invalid;
    const escaped = sep > 0 and text[sep - 1] == '\\';
    const mime_text = text[5 .. sep - @as(usize, if (escaped) 1 else 0)];
    const b64_start: usize = if (text.len >= sep + ";base64,".len and std.ascii.eqlIgnoreCase(text[sep .. sep + ";base64,".len], ";base64,")) sep + ";base64,".len else return .invalid;
    // Use static MIME labels: `text` belongs to the temporary paste buffer.
    const mime: []const u8 = if (std.ascii.eqlIgnoreCase(mime_text, "image/png")) "image/png" else if (std.ascii.eqlIgnoreCase(mime_text, "image/jpeg")) "image/jpeg" else if (std.ascii.eqlIgnoreCase(mime_text, "image/gif")) "image/gif" else if (std.ascii.eqlIgnoreCase(mime_text, "image/webp")) "image/webp" else return .unsupported;
    const b64 = text[b64_start..];
    const size = std.base64.standard.Decoder.calcSizeForSlice(b64) catch return .invalid;
    if (size > vision.max_staged_image_bytes) return .too_large;
    if (size == 0) return .invalid;
    const bytes = gpa.alloc(u8, size) catch return .out_of_memory;
    defer gpa.free(bytes);
    std.base64.standard.Decoder.decode(bytes, b64) catch return .invalid;
    if (!matchesMagic(mime, bytes)) return .invalid;
    if (!vision.visionCapable(root.provider)) return .no_vision;
    image.afterEdit(root, gpa, buf, cur);
    if (root.pending_image_len >= queue.cap) return .full;
    buf.ensureUnusedCapacity(gpa, "[Image #16] ".len) catch return .out_of_memory;
    const copy = root.arena.dupe(u8, b64) catch return .out_of_memory;
    queue.stage(root, .{ .media_type = mime, .b64 = copy, .label = "terminal image", .from_composer = true });
    image.insertComposerChip(root, gpa, buf, cur, marks, pastes);
    return .staged;
}

fn testAgent(gpa: Allocator) Agent {
    return .{ .gpa = gpa, .arena = gpa, .io = undefined, .client = undefined, .provider = .{ .id = "openai", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-4o", .context = 100_000 }, .messages = undefined, .sub = false, .label = "test", .out = null };
}

test "bracketed data URI stages escaped PNG and ordinary GIF drops as native image blocks" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var root = testAgent(a);
    root.arena = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    var marks: std.ArrayList([]const u8) = .empty;
    defer {
        for (marks.items) |mark| a.free(mark);
        marks.deinit(a);
    }
    var pastes: PasteStore = .{};
    defer pastes.deinit(a);
    var cur: usize = 0;
    const owned_drop = try a.dupe(u8, "DATA:IMAGE/PNG\\;BASE64,iVBORw0KGgo=");
    defer a.free(owned_drop);
    try std.testing.expectEqual(Result.staged, stagePaste(&root, a, &buf, &cur, &marks, &pastes, owned_drop, false));
    @memset(owned_drop, '?'); // the queued MIME and base64 must not borrow the paste buffer
    try std.testing.expectEqualStrings("image/png", root.pending_images[0].media_type);
    try std.testing.expectEqual(Result.staged, stagePaste(&root, a, &buf, &cur, &marks, &pastes, "data:image/gif;base64,R0lGODlh", false));
    try std.testing.expectEqualStrings("[Image #1] [Image #2] ", buf.items);
    const msg = try queue.consumePromptImages(arena.allocator(), &root, buf.items);
    try std.testing.expectEqual(@as(usize, 3), msg.object.get("content").?.array.items.len);
    try std.testing.expectEqualStrings("input_image", msg.object.get("content").?.array.items[1].object.get("type").?.string);
}

test "rejected image URI never enters composer or overwrites a full queue" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var root = testAgent(a);
    root.arena = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    var marks: std.ArrayList([]const u8) = .empty;
    defer {
        for (marks.items) |mark| a.free(mark);
        marks.deinit(a);
    }
    var pastes: PasteStore = .{};
    defer pastes.deinit(a);
    var cur: usize = 0;
    for ([_]struct { []const u8, Result }{
        .{ "data:image/png\\;base64,!!!", .invalid },
        .{ "data:image/png;base64,aGVsbG8=", .invalid },
        .{ "data:image/svg+xml;base64,aGVsbG8=", .unsupported },
        .{ "data:image/png;base64,iVBORw0KGgo=", .too_large },
    }) |case| {
        try std.testing.expectEqual(case[1], stagePaste(&root, a, &buf, &cur, &marks, &pastes, case[0], case[1] == .too_large));
        try std.testing.expect(feedback(case[1]).len > 0);
        try std.testing.expectEqualStrings("", buf.items);
    }
    for (0..queue.cap) |i| queue.stage(&root, .{ .media_type = "image/png", .b64 = try std.fmt.allocPrint(arena.allocator(), "command-{d}", .{i}), .label = "command" });
    try std.testing.expectEqual(Result.full, stagePaste(&root, a, &buf, &cur, &marks, &pastes, "data:image/png;base64,iVBORw0KGgo=", false));
    try std.testing.expectEqual(@as(u8, queue.cap), root.pending_image_len);
    try std.testing.expectEqualStrings("command-15", root.pending_images[queue.cap - 1].b64);
}
