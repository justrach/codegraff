//! ACP `image` prompt blocks (`{type:"image", data, mimeType}`) become vision
//! input for the next model request, the same queue GUI `@[path]` attachments
//! and MCP screenshots use. Parsing and the size/mime gate are
//! `vision.mcpImageBlock` (the shape is identical). Models that cannot read
//! images skip staging, matching `vision.stageGuiImageAttachment`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const Agent = @import("agent.zig").Agent;
const vision = @import("vision.zig");
const vision_queue = @import("vision_queue.zig");

/// Stage every image block in `prompt`. Returns how many were queued.
pub fn stage(root: *Agent, prompt: ?Value) usize {
    const p = prompt orelse return 0;
    if (p != .array or !vision.visionCapable(root.provider)) return 0;
    var staged: usize = 0;
    for (p.array.items) |block| {
        const img = vision.mcpImageBlock(block) orelse continue;
        var label_buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "image {d}", .{staged + 1}) catch "image";
        // The session arena outlives the request that carried the bytes.
        const pending = img.stage(root.arena, label) catch continue;
        vision_queue.stage(root, pending);
        staged += 1;
    }
    return staged;
}

/// Pure half for tests: the image blocks `stage` would queue.
pub fn count(prompt: ?Value) usize {
    const p = prompt orelse return 0;
    if (p != .array) return 0;
    var n: usize = 0;
    for (p.array.items) |block| {
        if (vision.mcpImageBlock(block) != null) n += 1;
    }
    return n;
}

test "count: ACP image blocks are recognized; text, resource links and non-images are not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const prompt = try std.json.parseFromSliceLeaky(Value, arena.allocator(),
        \\[{"type":"text","text":"what is this?"},
        \\ {"type":"image","data":"iVBORw0KGgo=","mimeType":"image/png"},
        \\ {"type":"image","data":"/9j/4AAQ","mimeType":"image/jpeg"},
        \\ {"type":"image","data":"AAAA","mimeType":"application/pdf"},
        \\ {"type":"resource_link","uri":"file:///x.png","name":"x.png"}]
    , .{});
    try std.testing.expectEqual(@as(usize, 2), count(prompt));
    try std.testing.expectEqual(@as(usize, 0), count(null));
}

fn testAgent(arena: Allocator, id: []const u8, model: []const u8) Agent {
    return .{
        .gpa = arena,
        .arena = arena,
        .io = undefined,
        .client = undefined,
        .provider = .{ .id = id, .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = model, .context = 100_000 },
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = null,
    };
}

test "stage: a codex model receives ACP images as the next request's input_image; text-only models skip them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prompt = try std.json.parseFromSliceLeaky(Value, a,
        \\[{"type":"image","data":"iVBORw0KGgo=","mimeType":"image/png"}]
    , .{});
    // A non-gpt id on the codex provider: only the provider rule makes it vision-capable.
    var codex = testAgent(a, "codex", "o4-mini");
    try std.testing.expectEqual(@as(usize, 1), stage(&codex, prompt));
    const msg = try vision_queue.consumePromptImages(a, &codex, "");
    var out: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.write(msg);
    const wire = out.written();
    try std.testing.expect(std.mem.indexOf(u8, wire, "\"input_image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "data:image/png;base64,iVBORw0KGgo=") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, vision_queue.attached_note) != null); // image-only prompt
    try std.testing.expectEqual(@as(u8, 0), codex.pending_image_len);

    var text_only = testAgent(a, "openrouter", "qwen3.8-27b");
    try std.testing.expectEqual(@as(usize, 0), stage(&text_only, prompt));
    try std.testing.expectEqual(@as(u8, 0), text_only.pending_image_len);
}
