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
const sniff = @import("image_sniff.zig");
const orient = @import("image_orient.zig");
const inbox = @import("image_inbox.zig");

/// Stage pixels after exec has confined the path. The tool-batch checkpoint
/// delivers them to the next model request as a native image content block.
/// Null lets an unreadable file fall back to the generic binary-file error.
pub fn stage(gpa: Allocator, io: Io, ctx: ToolCtx, resolved: []const u8, path: []const u8, size: u64) !?ToolOutput {
    return stageWith(gpa, io, ctx, resolved, path, size, clip.sipsResize, orient.sipsRotate);
}

/// Width and height from a PNG's IHDR, or null for anything else.
pub fn pngDims(bytes: []const u8) ?[2]u32 {
    if (bytes.len < 24 or !std.mem.startsWith(u8, bytes, clip.png_magic)) return null;
    return .{ std.mem.readInt(u32, bytes[16..20], .big), std.mem.readInt(u32, bytes[20..24], .big) };
}

const HeadRead = union(enum) {
    bytes: []const u8,
    not_found,
    unreadable,
};

fn openHead(io: Io, path: []const u8, buf: *[24]u8) HeadRead {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| return switch (err) {
        error.FileNotFound => .not_found,
        else => .unreadable,
    };
    defer file.close(io);
    const got = file.readPositionalAll(io, buf, 0) catch return .unreadable;
    return .{ .bytes = buf[0..got] };
}

/// The first bytes of `path`: enough for a PNG's dimensions and any
/// `image_sniff` signature. Null when the file cannot be read.
fn fileHead(io: Io, path: []const u8, buf: *[24]u8) ?[]const u8 {
    return switch (openHead(io, path, buf)) {
        .bytes => |b| b,
        else => null,
    };
}

fn fileDims(io: Io, path: []const u8) ?[2]u32 {
    var buf: [24]u8 = undefined;
    return pngDims(fileHead(io, path, &buf) orelse return null);
}

fn notRaster(gpa: Allocator, path: []const u8) !?ToolOutput {
    return .{ .text = try std.fmt.allocPrint(gpa, "Image could not be attached: {s} is not a {s} image (its bytes match none of them, whatever its extension says), so it was not sent. Convert it to one of those formats first.", .{ path, sniff.supported_names }), .is_error = true };
}

fn stageWith(gpa: Allocator, io: Io, ctx: ToolCtx, resolved: []const u8, path: []const u8, size: u64, resize: clip.Resizer, rotate: orient.Rotator) !?ToolOutput {
    const reg = ctx.registry orelse return .{ .text = try gpa.dupe(u8, "Image could not be attached: the image queue is unavailable."), .is_error = true };
    if (size == 0) return .{ .text = try gpa.dupe(u8, "Image could not be attached: the file is empty."), .is_error = true };
    // #1762: the type comes from the bytes. The extension is only a label for
    // a model that will not see the pixels anyway.
    var norm_arena: std.heap.ArenaAllocator = .init(gpa);
    defer norm_arena.deinit();
    var actual_resolved = resolved;
    var actual_path = path;
    var head_buf: [24]u8 = undefined;
    const head_bytes = switch (openHead(io, actual_resolved, &head_buf)) {
        .bytes => |b| b,
        .unreadable => return null,
        .not_found => blk: {
            const raw = if (@import("harness_policy.zig").confinedPath(resolved)) resolved else path;
            const hit = @import("read_path_norm.zig").resolveFallback(io, norm_arena.allocator(), ctx.agent_cwd, raw) orelse return null;
            actual_resolved = hit.resolved;
            actual_path = hit.display_path;
            break :blk switch (openHead(io, actual_resolved, &head_buf)) {
                .bytes => |b| b,
                else => return null,
            };
        },
    };
    const sniffed = sniff.sniff(head_bytes);
    if (!vision.visionCapable(ctx.provider)) return .{
        .text = try std.fmt.allocPrint(gpa, "[image: {s}, {d} bytes — the active model does not accept images, so it was not attached]", .{ sniffed orelse vision.imageMediaType(actual_path), size }),
    };
    const media_type = sniffed orelse return notRaster(gpa, actual_path);
    const limit = clip.max_staged_image_bytes;
    const fit = switch (clip.planStage(io, gpa, actual_resolved, limit, resize)) {
        .not_found => return null,
        .too_large => |bytes| {
            var got: [16]u8 = undefined;
            var cap: [16]u8 = undefined;
            const why = if (builtin.os.tag == .macos) "sips could not shrink it enough" else "downscaling is not available on this platform";
            return .{ .text = try std.fmt.allocPrint(gpa, "Image could not be attached: {s} is {s}, over the {s} per-image limit providers accept, and {s}. Read a smaller crop or a downscaled copy.", .{ actual_path, clip.fmtMb(&got, bytes), clip.fmtMb(&cap, limit), why }), .is_error = true };
        },
        .fits => |f| f,
    };
    defer if (fit.temp) clip.discard(io, gpa, fit.path);
    const raw = Io.Dir.cwd().readFileAlloc(io, fit.path, gpa, .limited(@intCast(limit))) catch return null;
    defer gpa.free(raw);
    // A photo stored turned (EXIF orientation) is turned upright first; the
    // model never sees the tag that says how to hold it.
    const turn = orient.upright(io, gpa, fit.path, raw, rotate);
    const data = switch (turn) {
        .turned => |t| t,
        .as_is, .stuck => raw,
    };
    defer if (turn == .turned) gpa.free(data);
    // The type of the bytes actually encoded: a downscale step re-encodes
    // (sipsResize forces PNG), so it is sniffed again rather than assumed.
    const sent_type = sniff.sniff(data) orelse return notRaster(gpa, actual_path);
    const enc = std.base64.standard.Encoder;
    const b64 = try gpa.alloc(u8, enc.calcSize(data.len));
    defer gpa.free(b64);
    _ = enc.encode(b64, data);
    reg.mutex.lockUncancelable(reg.io);
    defer reg.mutex.unlock(reg.io);
    // #1866: every read in a batch is queued, up to the inbox's limits. One
    // that does not fit is an error the model can act on, not a quiet note.
    const verdict = reg.pending_images.admit(b64.len);
    if (verdict != .queued) return .{ .text = try inbox.refusal(gpa, actual_path, verdict), .is_error = true };
    const arena = reg.arena();
    _ = reg.pending_images.pushAt(.{
        .media_type = try arena.dupe(u8, sent_type),
        .b64 = try arena.dupe(u8, b64),
        .label = try arena.dupe(u8, actual_path),
    }, ctx.call_seq);
    switch (turn) {
        .as_is => {},
        .turned => if (!fit.temp) return .{
            .text = try std.fmt.allocPrint(gpa, "[image: {s}, {d} bytes — turned upright from its EXIF orientation and attached to the next model request]", .{ media_type, size }),
        },
        .stuck => |v| return .{
            .text = try std.fmt.allocPrint(gpa, "[image: {s}, {d} bytes — attached to the next model request. Its EXIF orientation says the stored pixels are {s}; they could not be turned here, so read them that way]", .{ media_type, size, orient.hint(v) }),
        },
    }
    if (!fit.temp) return .{
        .text = try std.fmt.allocPrint(gpa, "[image: {s}, {d} bytes — attached to the next model request]", .{ media_type, size }),
    };
    // Scaled: say so, so the model does not read coordinates or fine text off
    // the original resolution.
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.print("[image: {s}, {d} bytes — over the per-image limit, so it was downscaled", .{ media_type, size });
    if (fileDims(io, actual_resolved)) |d| try w.print(" from {d}x{d}", .{ d[0], d[1] });
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
    ctx.agent_cwd = null;
    ctx.call_seq = 0;
    ctx.provider = root.provider;
    const out = (try stage(a, io, ctx, file_path, "image.PNG", bytes.len)).?;
    defer a.free(out.text);
    try std.testing.expect(!out.is_error);
    try std.testing.expect(!reg.pending_images.isEmpty());
    try @import("turn_checkpoint.zig").afterToolBatch(&root);
    try std.testing.expect(reg.pending_images.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), root.messages.items.len);
    const content = root.messages.items[0].object.get("content").?.array.items;
    try std.testing.expectEqualStrings("input_image", content[1].object.get("type").?.string);
    try std.testing.expect(std.mem.startsWith(u8, content[1].object.get("image_url").?.string, "data:image/png;base64,"));
    const empty = (try stage(a, io, ctx, file_path, "image.PNG", 0)).?;
    defer a.free(empty.text);
    try std.testing.expect(empty.is_error);
    try std.testing.expect(reg.pending_images.isEmpty());
}

test "#1866: two image reads in one tool batch both reach the next model request, named in order" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var reg = @import("mcp.zig").Registry.empty(a, io);
    defer reg.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Different bytes after the PNG header, so the two payloads are distinct.
    try tmp.dir.writeFile(io, .{ .sub_path = "before.png", .data = tiny_png });
    try tmp.dir.writeFile(io, .{ .sub_path = "after.png", .data = tiny_png ++ "\x00" });
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
    ctx.agent_cwd = null;
    ctx.call_seq = 0;
    ctx.provider = root.provider;
    // The second call's read finishes first: the model still gets them in
    // the order it asked.
    for ([_][]const u8{ "after.png", "before.png" }, [_]u32{ 1, 0 }) |name, call| {
        const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
        defer a.free(path);
        ctx.call_seq = call;
        const out = (try stage(a, io, ctx, path, name, tiny_png.len)).?;
        defer a.free(out.text);
        try std.testing.expect(!out.is_error);
        try std.testing.expect(std.mem.indexOf(u8, out.text, "attached to the next model request") != null);
    }
    try std.testing.expectEqual(@as(usize, 2), reg.pending_images.len);
    try @import("turn_checkpoint.zig").afterToolBatch(&root);
    try std.testing.expect(reg.pending_images.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), root.messages.items.len);
    const content = root.messages.items[0].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), content.len); // the caption, then both images
    try std.testing.expectEqualStrings("Attached 2 images, in this order:\n1. before.png\n2. after.png", content[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("input_image", content[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("input_image", content[2].object.get("type").?.string);
    try std.testing.expect(!std.mem.eql(u8, content[1].object.get("image_url").?.string, content[2].object.get("image_url").?.string));

    // A full inbox refuses the next read as an error that names the way out.
    for (0..inbox.cap) |_| _ = reg.pending_images.push(.{ .media_type = "image/png", .b64 = "x", .label = "x" });
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/before.png", .{tmp.sub_path});
    defer a.free(path);
    const refused = (try stage(a, io, ctx, path, "before.png", tiny_png.len)).?;
    defer a.free(refused.text);
    try std.testing.expect(refused.is_error);
    try std.testing.expect(std.mem.indexOf(u8, refused.text, "Read it again in a later tool call") != null);
    try std.testing.expectEqual(@as(usize, inbox.cap), reg.pending_images.len);
}

test "#1737: after workspace use, an image in the new tree attaches; one outside both trees is refused" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // enterPath is POSIX-only
    const a = std.testing.allocator;
    const io = std.testing.io;
    const policy = @import("harness_policy.zig");
    const switcher = @import("workspace_switch.zig");
    const main_mod = @import("main.zig");
    var launch = std.testing.tmpDir(.{});
    defer launch.cleanup();
    var other = std.testing.tmpDir(.{});
    defer other.cleanup();
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try other.dir.writeFile(io, .{ .sub_path = "shot.png", .data = tiny_png });
    try outside.dir.writeFile(io, .{ .sub_path = "shot.png", .data = tiny_png });
    var orig = try Io.Dir.cwd().openDir(io, ".", .{});
    defer orig.close(io);
    defer _ = std.posix.system.fchdir(orig.handle);
    const saved = .{ main_mod.g_cwd_display, main_mod.g_worktree_branch };
    defer {
        main_mod.g_cwd_display = saved[0];
        main_mod.g_worktree_branch = saved[1];
        switcher.deinitDisplay(a);
        @import("tool_spill.zig").resetForTest();
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const other_abs = try arena.allocator().dupe(u8, buf[0..try other.dir.realPath(io, &buf)]);
    const outside_abs = try arena.allocator().dupe(u8, buf[0..try outside.dir.realPath(io, &buf)]);
    if (std.posix.system.fchdir(launch.dir.handle) != 0) return error.ChdirFailed;
    _ = try switcher.enterPath(a, io, arena.allocator(), other_abs);

    // The native tools' own confinement now roots at the switched tree.
    try std.testing.expect(policy.confinedPath("shot.png") and policy.noSymlinkEscape(io, "shot.png", null));
    const resolved = try @import("codedbpro_paths.zig").sessionAbs(a, io, null, "shot.png");
    defer a.free(resolved);
    try std.testing.expect(std.mem.startsWith(u8, resolved, other_abs));
    var reg = @import("mcp.zig").Registry.empty(a, io);
    defer reg.deinit();
    var ctx: ToolCtx = undefined;
    ctx.registry = &reg;
    ctx.agent_cwd = null;
    ctx.call_seq = 0;
    ctx.provider = .{ .id = "test", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 100000 };
    const out = (try stage(a, io, ctx, resolved, "shot.png", tiny_png.len)).?;
    defer a.free(out.text);
    try std.testing.expect(!out.is_error);
    try std.testing.expect(!reg.pending_images.isEmpty());

    // Outside both the launch tree and the switched tree: still refused.
    const escaped = try std.fmt.allocPrint(arena.allocator(), "{s}/shot.png", .{outside_abs});
    try std.testing.expect(!policy.confinedPath(escaped) and !policy.noSymlinkEscape(io, escaped, null));
    try std.testing.expect(!policy.confinedPath("../outside/shot.png"));
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
    ctx.agent_cwd = null;
    ctx.call_seq = 0;
    ctx.provider = .{ .id = "test", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 100000 };

    // No way to downscale: refused with the reason, and nothing is queued.
    const refused = (try stageWith(a, io, ctx, file_path, "big.png", big.len, noResizer, noRotator)).?;
    defer a.free(refused.text);
    try std.testing.expect(refused.is_error);
    try std.testing.expect(std.mem.indexOf(u8, refused.text, "per-image limit") != null);
    try std.testing.expect(reg.pending_images.isEmpty());

    // Downscaled: the queued pixels are the small copy, and the model is told.
    const scaled = (try stageWith(a, io, ctx, file_path, "big.png", big.len, fakeShrink, noRotator)).?;
    defer a.free(scaled.text);
    try std.testing.expect(!scaled.is_error);
    const pending = reg.pending_images.first() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(std.base64.standard.Encoder.calcSize(tiny_png.len), pending.b64.len);
    try std.testing.expectEqualStrings("image/png", pending.media_type);
    try std.testing.expect(std.mem.indexOf(u8, scaled.text, "downscaled from 4000x3000 to 1x1") != null);
}

test "#1762: read_image types a WebP named .png by its bytes, and refuses non-raster bytes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var reg = @import("mcp.zig").Registry.empty(a, io);
    defer reg.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx: ToolCtx = undefined;
    ctx.registry = &reg;
    ctx.agent_cwd = null;
    ctx.call_seq = 0;
    ctx.provider = .{ .id = "test", .kind = .anthropic, .auth = .bearer, .url = "", .api_key = "", .model = "claude-x", .context = 100000 };
    const webp = "RIFF\x24\x00\x00\x00WEBPVP8 \x18\x00\x00\x00";
    try tmp.dir.writeFile(io, .{ .sub_path = "shot.png", .data = webp });
    const webp_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/shot.png", .{tmp.sub_path});
    defer a.free(webp_path);
    const out = (try stageWith(a, io, ctx, webp_path, "shot.png", webp.len, noResizer, noRotator)).?;
    defer a.free(out.text);
    try std.testing.expect(!out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "image/webp") != null);
    const pending = reg.pending_images.first() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("image/webp", pending.media_type);
    reg.pending_images.clear();

    // Text saved as .png: a tool error, and no block that would wedge the chat.
    const text = "not an image at all";
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.png", .data = text });
    const text_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/notes.png", .{tmp.sub_path});
    defer a.free(text_path);
    const refused = (try stageWith(a, io, ctx, text_path, "notes.png", text.len, noResizer, noRotator)).?;
    defer a.free(refused.text);
    try std.testing.expect(refused.is_error);
    try std.testing.expect(std.mem.indexOf(u8, refused.text, sniff.supported_names) != null);
    try std.testing.expect(reg.pending_images.isEmpty());
}

fn noRotator(io: Io, in: []const u8, value: u16, out: []const u8) bool {
    _ = .{ io, in, value, out };
    return false;
}

/// Stands in for `sips`: writes the photo back still tagged 6, as sips does.
fn fakeRotator(io: Io, in: []const u8, value: u16, out: []const u8) bool {
    _ = .{ in, value };
    Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = &orient.testJpeg(false, 6) }) catch return false;
    return true;
}

test "read_image: a photo stored sideways is sent upright, or the model is told how to hold it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // rotate temps live in /tmp
    const a = std.testing.allocator;
    const io = std.testing.io;
    var reg = @import("mcp.zig").Registry.empty(a, io);
    defer reg.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var ctx: ToolCtx = undefined;
    ctx.registry = &reg;
    ctx.agent_cwd = null;
    ctx.call_seq = 0;
    ctx.provider = .{ .id = "test", .kind = .anthropic, .auth = .bearer, .url = "", .api_key = "", .model = "claude-x", .context = 100000 };
    const photo = orient.testJpeg(false, 6);
    try tmp.dir.writeFile(io, .{ .sub_path = "photo.jpg", .data = &photo });
    const p = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/photo.jpg", .{tmp.sub_path});
    defer a.free(p);

    const turned = (try stageWith(a, io, ctx, p, "photo.jpg", photo.len, noResizer, fakeRotator)).?;
    defer a.free(turned.text);
    try std.testing.expect(std.mem.indexOf(u8, turned.text, "turned upright") != null);
    const pending = reg.pending_images.first() orelse return error.TestUnexpectedResult;
    var sent: [photo.len]u8 = undefined;
    try std.base64.standard.Decoder.decode(&sent, pending.b64);
    try std.testing.expectEqual(@as(u16, 1), orient.find(&sent).?.value);
    reg.pending_images.clear();

    const stuck = (try stageWith(a, io, ctx, p, "photo.jpg", photo.len, noResizer, noRotator)).?;
    defer a.free(stuck.text);
    try std.testing.expect(!stuck.is_error);
    try std.testing.expect(std.mem.indexOf(u8, stuck.text, "rotate it 90° clockwise") != null);
    try std.testing.expect(!reg.pending_images.isEmpty());
}
