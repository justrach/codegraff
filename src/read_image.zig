//! Native read image staging; paths are already confined by exec before entry.
//!
//! #1272: the image goes through the SAME budget and downscale ladder as a
//! clipboard paste (vision_clipboard.planStage, #349). The old 5 MiB raw
//! ceiling base64-expands to ~7 MB, above what providers accept per image, so
//! an accepted read broke the next request. Over the budget the file is
//! downscaled and the model is told what it is actually looking at; where it
//! cannot be downscaled (no `sips` off macOS) it is refused, never queued as-is.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;
const vision = @import("vision.zig");
const clip = @import("vision_clipboard.zig");

/// Stage pixels after exec has confined the path. The tool-batch checkpoint
/// delivers them to the next model request as a native image content block.
/// Null lets an unreadable file fall back to the generic binary-file error.
pub fn stage(gpa: Allocator, io: Io, ctx: ToolCtx, resolved: []const u8, path: []const u8, size: u64) !?ToolOutput {
    return stageWith(gpa, io, ctx, resolved, path, size, clip.sipsResize);
}

/// Width and height from a PNG's IHDR, or null for anything else.
pub fn pngDims(bytes: []const u8) ?[2]u32 {
    if (bytes.len < 24 or !std.mem.startsWith(u8, bytes, clip.png_magic)) return null;
    return .{ std.mem.readInt(u32, bytes[16..20], .big), std.mem.readInt(u32, bytes[20..24], .big) };
}

fn fileDims(io: Io, path: []const u8) ?[2]u32 {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var head: [24]u8 = undefined;
    const got = file.readPositionalAll(io, &head, 0) catch return null;
    return pngDims(head[0..got]);
}

fn stageWith(gpa: Allocator, io: Io, ctx: ToolCtx, resolved: []const u8, path: []const u8, size: u64, resize: clip.Resizer) !?ToolOutput {
    const reg = ctx.registry orelse return .{ .text = try gpa.dupe(u8, "Image could not be attached: the image queue is unavailable."), .is_error = true };
    if (size == 0) return .{ .text = try gpa.dupe(u8, "Image could not be attached: the file is empty."), .is_error = true };
    const media_type = vision.imageMediaType(path);
    if (!vision.visionCapable(ctx.provider)) return .{
        .text = try std.fmt.allocPrint(gpa, "[image: {s}, {d} bytes — the active model does not accept images, so it was not attached]", .{ media_type, size }),
    };
    const limit = clip.max_staged_image_bytes;
    const fit = switch (clip.planStage(io, gpa, resolved, limit, resize)) {
        .not_found => return null,
        .too_large => |bytes| {
            var got: [16]u8 = undefined;
            var cap: [16]u8 = undefined;
            const why = if (builtin.os.tag == .macos) "sips could not shrink it enough" else "downscaling is not available on this platform";
            return .{ .text = try std.fmt.allocPrint(gpa, "Image could not be attached: {s} is {s}, over the {s} per-image limit providers accept, and {s}. Read a smaller crop or a downscaled copy.", .{ path, clip.fmtMb(&got, bytes), clip.fmtMb(&cap, limit), why }), .is_error = true };
        },
        .fits => |f| f,
    };
    defer if (fit.temp) clip.discard(io, gpa, fit.path);
    const data = Io.Dir.cwd().readFileAlloc(io, fit.path, gpa, .limited(@intCast(limit))) catch return null;
    defer gpa.free(data);
    // A downscale step is always PNG (sipsResize forces it, fitToBudget checks
    // the magic), so the media type follows the file actually encoded.
    const sent_type = if (fit.temp) vision.imageMediaType(fit.path) else media_type;
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
        .media_type = try arena.dupe(u8, sent_type),
        .b64 = try arena.dupe(u8, b64),
        .label = try arena.dupe(u8, path),
    };
    if (!fit.temp) return .{
        .text = try std.fmt.allocPrint(gpa, "[image: {s}, {d} bytes — attached to the next model request]", .{ media_type, size }),
    };
    // Scaled: say so, so the model does not read coordinates or fine text off
    // the original resolution.
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.print("[image: {s}, {d} bytes — over the per-image limit, so it was downscaled", .{ media_type, size });
    if (fileDims(io, resolved)) |d| try w.print(" from {d}x{d}", .{ d[0], d[1] });
    if (pngDims(data)) |d| try w.print(" to {d}x{d}", .{ d[0], d[1] });
    try w.print(" ({s}, {d} bytes) and attached to the next model request]", .{ sent_type, data.len });
    return .{ .text = try aw.toOwnedSlice() };
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
    const empty = (try stage(a, io, ctx, file_path, "image.PNG", 0)).?;
    defer a.free(empty.text);
    try std.testing.expect(empty.is_error);
    try std.testing.expect(reg.pending_image == null);
}

/// 1x1 PNG a fake resizer "downscales" to.
const tiny_png = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x01\x00\x00\x00\x01\x08\x04\x00\x00\x00\xb5\x1c\x0c\x02\x00\x00\x00\x0b\x49\x44\x41\x54\x78\xda\x63\xfc\xff\x1f\x00\x03\x03\x02\x00\xef\x9a\x0f\x5b\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";

fn fakeShrink(io: Io, in: []const u8, max_dim: []const u8, out: []const u8) bool {
    _ = in;
    _ = max_dim;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = tiny_png }) catch return false;
    return true;
}

fn noResizer(io: Io, in: []const u8, max_dim: []const u8, out: []const u8) bool {
    _ = .{ io, in, max_dim, out };
    return false;
}

test "#1272: an oversize image is downscaled or refused, never queued as-is" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // downscale temps live in /tmp
    const a = std.testing.allocator;
    const io = std.testing.io;
    var reg = @import("mcp.zig").Registry.empty(a, io);
    defer reg.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Over the base64 wire budget: a PNG header claiming 4000x3000, then filler.
    const big = try a.alloc(u8, clip.max_staged_image_bytes + 300_000);
    defer a.free(big);
    @memset(big, 0);
    @memcpy(big[0..16], tiny_png[0..16]);
    std.mem.writeInt(u32, big[16..20], 4000, .big);
    std.mem.writeInt(u32, big[20..24], 3000, .big);
    try tmp.dir.writeFile(io, .{ .sub_path = "big.png", .data = big });
    const file_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/big.png", .{tmp.sub_path});
    defer a.free(file_path);
    var ctx: ToolCtx = undefined;
    ctx.registry = &reg;
    ctx.provider = .{ .id = "test", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 100000 };

    // No way to downscale: refused with the reason, and nothing is queued.
    const refused = (try stageWith(a, io, ctx, file_path, "big.png", big.len, noResizer)).?;
    defer a.free(refused.text);
    try std.testing.expect(refused.is_error);
    try std.testing.expect(std.mem.indexOf(u8, refused.text, "per-image limit") != null);
    try std.testing.expect(reg.pending_image == null);

    // Downscaled: the queued pixels are the small copy, and the model is told.
    const scaled = (try stageWith(a, io, ctx, file_path, "big.png", big.len, fakeShrink)).?;
    defer a.free(scaled.text);
    try std.testing.expect(!scaled.is_error);
    const pending = reg.pending_image orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(std.base64.standard.Encoder.calcSize(tiny_png.len), pending.b64.len);
    try std.testing.expectEqualStrings("image/png", pending.media_type);
    try std.testing.expect(std.mem.indexOf(u8, scaled.text, "downscaled from 4000x3000 to 1x1") != null);
}
