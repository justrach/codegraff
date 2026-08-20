//! Multi-image staging queue (#580).
//!
//! Ctrl-V / drop / `@[path]` used to overwrite a single `pending_image` slot,
//! so nine ask_user pastes left nine `[Image]` markers and one payload. This
//! queue keeps every successful stage (cap 16) until the next model request
//! consumes them as real vision blocks.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const vision = @import("vision.zig");
const PendingImage = vision.PendingImage;
const messages = @import("messages.zig");
const compact_cut = @import("compact_cut.zig");

pub const cap = 16;

pub const unsupported_note =
    "[ask_user: those image attachments did not reach the model. Save the files and pass their paths, paste the text, or send the images in your next normal prompt.]";

pub fn stage(root: *Agent, img: PendingImage) void {
    root.pending_image = img;
    if (root.pending_image_len < cap) {
        root.pending_images[root.pending_image_len] = img;
        root.pending_image_len += 1;
        return;
    }
    root.pending_images[cap - 1] = img;
}

pub fn take(root: *Agent) []const PendingImage {
    const n = root.pending_image_len;
    root.pending_image_len = 0;
    root.pending_image = null;
    return root.pending_images[0..n];
}

pub fn consumePromptImages(arena: Allocator, root: *Agent, text: []const u8) !Value {
    const imgs = take(root);
    if (imgs.len == 0) return messages.textMessage(arena, "user", text);
    return vision.imageMessages(arena, root.provider.kind, text, imgs);
}

/// After an ask_user (or any tool that staged pixels) tool result, attach the
/// queued images as a follow-up user message. Responses/OpenAI tool output is
/// text-only; this is the shared multimodal shape.
pub fn flushPending(root: *Agent) !void {
    const imgs = take(root);
    if (imgs.len == 0) return;
    try root.messages.append(try vision.imageMessages(root.arena, root.provider.kind, "", imgs));
}

pub fn withUnsupportedNote(arena: Allocator, answer: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, answer, "[Image]") == null) return answer;
    return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ answer, unsupported_note });
}

test "queue keeps two staged images in order" {
    var root: Agent = .{
        .gpa = std.testing.allocator,
        .arena = std.testing.allocator,
        .io = undefined,
        .client = undefined,
        .provider = .{ .id = "xai", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "grok-4", .context = 100_000 },
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = null,
    };
    stage(&root, .{ .media_type = "image/png", .b64 = "AAA", .label = "one.png" });
    stage(&root, .{ .media_type = "image/png", .b64 = "BBB", .label = "two.png" });
    try std.testing.expectEqual(@as(u8, 2), root.pending_image_len);
    const imgs = take(&root);
    try std.testing.expectEqual(@as(usize, 2), imgs.len);
    try std.testing.expectEqualStrings("AAA", imgs[0].b64);
    try std.testing.expectEqualStrings("BBB", imgs[1].b64);
    try std.testing.expectEqual(@as(u8, 0), root.pending_image_len);
    try std.testing.expect(root.pending_image == null);
}

test "ask_user images become follow-up vision blocks (#580)" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: Agent = .{
        .gpa = a,
        .arena = arena,
        .io = undefined,
        .client = undefined,
        .provider = .{ .id = "xai", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "grok-4", .context = 100_000 },
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "test",
        .out = null,
    };
    stage(&root, .{ .media_type = "image/png", .b64 = "AAA", .label = "q1.png" });
    stage(&root, .{ .media_type = "image/png", .b64 = "BBB", .label = "q2.png" });
    try root.messages.append(try messages.toolResultMessage(arena, .responses, "ask1", "[Image] [Image]", false));
    try flushPending(&root);
    try std.testing.expectEqual(@as(usize, 2), root.messages.items.len);
    try std.testing.expectEqual(@as(u32, 2), compact_cut.countImageBlocks(root.messages.items[1]));
    const content = root.messages.items[1].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("input_image", content[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("input_image", content[2].object.get("type").?.string);
    try std.testing.expect(std.mem.indexOf(u8, content[1].object.get("image_url").?.string, "AAA") != null);
    try std.testing.expect(std.mem.indexOf(u8, content[2].object.get("image_url").?.string, "BBB") != null);
}

test "placeholder-only ask_user reply gets an explicit fallback" {
    const note = try withUnsupportedNote(std.testing.allocator, "[Image] [Image]");
    defer std.testing.allocator.free(note);
    try std.testing.expect(std.mem.indexOf(u8, note, "did not reach the model") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "next normal prompt") != null);
}
