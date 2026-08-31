//! Line-composer image chips (#702).
//!
//! Ctrl-V / drop stage pixels on `Agent.pending_images` and insert `[Image #N]`.
//! Deleting a chip must drop that queue slot and rewrite remaining numbers so
//! the next paste is `#1` again — not a ghost `#2`. Content-derived paste
//! traces wait until submit (ADR 0056).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const vision = @import("vision.zig");
const vision_queue = @import("vision_queue.zig");
const input_util = @import("input_util.zig");
const PasteStore = @import("readline_paste.zig").Store;

pub const Chip = struct { start: usize, end: usize, n: u8 };

/// `[Image #N]` starting at `i`, or null.
pub fn imageChipAt(text: []const u8, i: usize) ?Chip {
    if (!std.mem.startsWith(u8, text[i..], "[Image #")) return null;
    var p = i + "[Image #".len;
    var num: u16 = 0;
    while (p < text.len and text[p] >= '0' and text[p] <= '9') : (p += 1) {
        num = num *% 10 + (text[p] - '0');
    }
    if (num < 1 or num > vision_queue.cap or p >= text.len or text[p] != ']') return null;
    return .{ .start = i, .end = p + 1, .n = @intCast(num) };
}

/// Start of the image chip that `cur` is inside (including a trailing space).
pub fn left(text: []const u8, cur: usize) ?usize {
    var i: usize = 0;
    while (i < text.len) {
        if (imageChipAt(text, i)) |chip| {
            var end = chip.end;
            if (end < text.len and text[end] == ' ') end += 1;
            if (cur > chip.start and cur <= end) return chip.start;
            i = chip.end;
            continue;
        }
        i += 1;
    }
    return null;
}

/// End of the image chip that `cur` is inside (including a trailing space).
pub fn right(text: []const u8, cur: usize) ?usize {
    var i: usize = 0;
    while (i < text.len) {
        if (imageChipAt(text, i)) |chip| {
            var end = chip.end;
            if (end < text.len and text[end] == ' ') end += 1;
            if (cur >= chip.start and cur < end) return end;
            i = chip.end;
            continue;
        }
        i += 1;
    }
    return null;
}

/// Drop composer slots the buffer no longer names and rewrite remaining `#N`s.
pub fn afterEdit(root: *Agent, gpa: Allocator, buf: *std.ArrayList(u8), cur: *usize) void {
    const remap = vision_queue.retainReferenced(root, buf.items);
    rewriteChips(gpa, buf, cur, remap);
}

pub fn deleteAtom(root: *Agent, gpa: Allocator, buf: *std.ArrayList(u8), cur: *usize, pastes: *PasteStore, from: usize, to: usize) void {
    pastes.edited(gpa, from, to, 0);
    input_util.delRange(buf, from, to);
    afterEdit(root, gpa, buf, cur);
}

pub fn clearLine(root: *Agent, gpa: Allocator, buf: *std.ArrayList(u8), cur: *usize, pastes: *PasteStore) void {
    buf.clearRetainingCapacity();
    pastes.clear(gpa);
    cur.* = 0;
    afterEdit(root, gpa, buf, cur);
}

/// Rewrite `[Image #old]` to the compacted chip numbers. Identity is a no-op.
pub fn rewriteChips(gpa: Allocator, buf: *std.ArrayList(u8), cur: *usize, remap: vision_queue.Remap) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var i: usize = 0;
    var new_cur = cur.*;
    var changed = false;
    while (i < buf.items.len) {
        if (imageChipAt(buf.items, i)) |chip| {
            const new_n: u8 = if (chip.n >= 1 and chip.n <= vision_queue.cap) remap[chip.n - 1] else 0;
            var tmp: [20]u8 = undefined;
            const repl = if (new_n == 0 or new_n == chip.n)
                buf.items[chip.start..chip.end]
            else blk: {
                changed = true;
                break :blk std.fmt.bufPrint(&tmp, "[Image #{d}]", .{new_n}) catch buf.items[chip.start..chip.end];
            };
            const old_len = chip.end - chip.start;
            if (cur.* >= chip.end) {
                if (repl.len >= old_len) new_cur += repl.len - old_len else new_cur -= old_len - repl.len;
            } else if (cur.* > chip.start) {
                new_cur = out.items.len + repl.len;
            }
            out.appendSlice(gpa, repl) catch return;
            i = chip.end;
            continue;
        }
        out.append(gpa, buf.items[i]) catch return;
        i += 1;
    }
    if (!changed) return;
    buf.clearRetainingCapacity();
    buf.appendSlice(gpa, out.items) catch return;
    cur.* = @min(new_cur, buf.items.len);
}

pub fn insertComposerChip(
    root: *Agent,
    gpa: Allocator,
    buf: *std.ArrayList(u8),
    cur: *usize,
    marks: *std.ArrayList([]const u8),
    pastes: *PasteStore,
) void {
    vision_queue.markLastComposer(root);
    const at = cur.*;
    input_util.insertImageChip(gpa, buf, cur, marks, root.pending_image_len);
    if (cur.* > at) pastes.edited(gpa, at, at, cur.* - at);
}

test "imageChipAt parses a numbered marker" {
    const chip = imageChipAt("[Image #3] look", 0).?;
    try std.testing.expectEqual(@as(usize, 0), chip.start);
    try std.testing.expectEqual(@as(usize, 10), chip.end);
    try std.testing.expectEqual(@as(u8, 3), chip.n);
    try std.testing.expect(imageChipAt("see [Image #1]", 4) != null);
    try std.testing.expect(imageChipAt("[Image]", 0) == null);
}

test "left/right treat an image chip as one atom (#702)" {
    const text = "hi [Image #1] there";
    try std.testing.expectEqual(@as(usize, 3), left(text, 13).?); // on the trailing space
    try std.testing.expectEqual(@as(usize, 3), left(text, 12).?); // on ]
    try std.testing.expect(left(text, 3) == null);
    try std.testing.expectEqual(@as(usize, 14), right(text, 3).?);
    try std.testing.expect(right(text, 14) == null);
}

test "afterEdit drops an abandoned chip and remaps the rest (#702)" {
    const gpa = std.testing.allocator;
    var root: Agent = .{
        .gpa = gpa,
        .arena = gpa,
        .io = undefined,
        .client = undefined,
        .provider = .{ .id = "xai", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "grok-4", .context = 100_000 },
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = null,
    };
    vision_queue.stage(&root, .{ .media_type = "image/png", .b64 = "AAA", .label = "one.png", .from_composer = true });
    vision_queue.stage(&root, .{ .media_type = "image/png", .b64 = "BBB", .label = "two.png", .from_composer = true });
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "[Image #2] look");
    var cur: usize = buf.items.len;
    afterEdit(&root, gpa, &buf, &cur);
    try std.testing.expectEqual(@as(u8, 1), root.pending_image_len);
    try std.testing.expectEqualStrings("BBB", root.pending_images[0].b64);
    try std.testing.expectEqualStrings("[Image #1] look", buf.items);
    try std.testing.expectEqual(@as(u8, 2), vision_queue.nextChipNumber(&root));
}

test "rewriteChips remaps #2 to #1 after the first slot is dropped (#702)" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, "[Image #2] look");
    var cur: usize = buf.items.len;
    var remap: vision_queue.Remap = @splat(0);
    remap[1] = 1;
    rewriteChips(gpa, &buf, &cur, remap);
    try std.testing.expectEqualStrings("[Image #1] look", buf.items);
    try std.testing.expectEqual(@as(usize, buf.items.len), cur);
}
