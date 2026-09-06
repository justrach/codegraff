//! Native read image staging; paths are already confined by exec before entry.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;
const vision = @import("vision.zig");

/// Stage pixels after exec has confined the path. The tool-batch checkpoint
/// delivers them to the next model request as a native image content block.
/// Null lets an unreadable file fall back to the generic binary-file error.
pub fn stage(gpa: Allocator, io: Io, ctx: ToolCtx, resolved: []const u8, path: []const u8, size: u64) !?ToolOutput {
    const reg = ctx.registry orelse return .{ .text = try gpa.dupe(u8, "Image could not be attached: the image queue is unavailable."), .is_error = true };
    if (size == 0 or size > 5 * 1024 * 1024) return .{ .text = try gpa.dupe(u8, "Image could not be attached: use a non-empty image under 5 MiB, or read a smaller crop."), .is_error = true };
    const media_type = vision.imageMediaType(path);
    if (!vision.visionCapable(ctx.provider)) return .{
        .text = try std.fmt.allocPrint(gpa, "[image: {s}, {d} bytes — the active model does not accept images, so it was not attached]", .{ media_type, size }),
    };
    const data = Io.Dir.cwd().readFileAlloc(io, resolved, gpa, .limited(5 * 1024 * 1024)) catch return null;
    defer gpa.free(data);
    const enc = std.base64.standard.Encoder;
    const b64 = try gpa.alloc(u8, enc.calcSize(data.len));
    defer gpa.free(b64);
    _ = enc.encode(b64, data);
    reg.mutex.lockUncancelable(reg.io);
    defer reg.mutex.unlock(reg.io);
    if (reg.pending_image != null) return .{
        .text = try std.fmt.allocPrint(gpa, "[image: {s}, {d} bytes — not attached: another image is already queued for the next turn]", .{ media_type, size }),
    };
    const arena = reg.arena();
    reg.pending_image = .{
        .media_type = try arena.dupe(u8, media_type),
        .b64 = try arena.dupe(u8, b64),
        .label = try arena.dupe(u8, path),
    };
    return .{
        .text = try std.fmt.allocPrint(gpa, "[image: {s}, {d} bytes — attached to the next model request]", .{ media_type, size }),
    };
}

test "native image read stages pixels and tool checkpoint sends them without a user follow-up" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var reg = @import("mcp.zig").Registry.empty(a, io);
    defer reg.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x01\x00\x00\x00\x01\x08\x04\x00\x00\x00\xb5\x1c\x0c\x02\x00\x00\x00\x0b\x49\x44\x41\x54\x78\xda\x63\xfc\xff\x1f\x00\x03\x03\x02\x00\xef\x9a\x0f\x5b\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";
    try tmp.dir.writeFile(io, .{ .sub_path = "image.PNG", .data = bytes });
    const file_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/image.PNG", .{tmp.sub_path});
    defer a.free(file_path);
    var root: @import("agent.zig").Agent = .{
        .gpa = a,
        .arena = arena.allocator(),
        .io = io,
        .client = undefined,
        .provider = .{ .id = "test", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 100000 },
        .messages = std.json.Array.init(arena.allocator()),
        .sub = true,
        .label = "test",
        .out = null,
        .registry = &reg,
    };
    var ctx: ToolCtx = undefined;
    ctx.registry = &reg;
    ctx.provider = root.provider;
    const out = (try stage(a, io, ctx, file_path, "image.PNG", bytes.len)).?;
    defer a.free(out.text);
    try std.testing.expect(!out.is_error);
    try std.testing.expect(reg.pending_image != null);
    try @import("turn_checkpoint.zig").afterToolBatch(&root);
    try std.testing.expect(reg.pending_image == null);
    try std.testing.expectEqual(@as(usize, 1), root.messages.items.len);
    const content = root.messages.items[0].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("input_image", content[1].object.get("type").?.string);
    try std.testing.expect(std.mem.startsWith(u8, content[1].object.get("image_url").?.string, "data:image/png;base64,"));
    const oversize = (try stage(a, io, ctx, file_path, "image.PNG", 6 * 1024 * 1024)).?;
    defer a.free(oversize.text);
    try std.testing.expect(oversize.is_error);
    try std.testing.expect(reg.pending_image == null);
}
