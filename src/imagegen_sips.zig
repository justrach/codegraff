//! #352: the two macOS `sips` operations the imagegen tool needs — reading an
//! image's pixel dimensions, and resizing one.
//!
//! Resizing is graff's job, never the generator's. The codex engine's hosted
//! `image_gen` tool has no size parameter, and the #352 transcript is exactly
//! what happens when a model is left to "make it 64x64" on its own: it reached
//! for sips itself, resized the wrong (stale) file, and reported the result as
//! a generation. So when a caller asks for a size, graff runs the resize on the
//! artifact it has already verified, deterministically, and reports the
//! dimensions it measured afterwards rather than the ones it asked for.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const run_mod = @import("imagegen_run.zig");

pub const available = builtin.os.tag == .macos;
const sips_deadline_ms: u64 = 30 * 1000;

pub const Size = struct { w: u32, h: u32 };

/// "1024x1536" -> 1024 wide, 1536 tall. Rejects anything that is not two plain
/// positive numbers, so the value can never smuggle an argument into sips.
pub fn parseSize(text: []const u8) ?Size {
    const x = std.mem.indexOfAny(u8, text, "xX") orelse return null;
    const w = std.fmt.parseInt(u32, text[0..x], 10) catch return null;
    const h = std.fmt.parseInt(u32, text[x + 1 ..], 10) catch return null;
    if (w == 0 or h == 0 or w > 16384 or h > 16384) return null;
    return .{ .w = w, .h = h };
}

/// `sips -z <height> <width> <path>` — sips takes height first.
pub fn resizeArgv(arena: Allocator, path: []const u8, size: Size) ![]const []const u8 {
    const h = try std.fmt.allocPrint(arena, "{d}", .{size.h});
    const w = try std.fmt.allocPrint(arena, "{d}", .{size.w});
    return arena.dupe([]const u8, &.{ "sips", "-z", h, w, path });
}

pub fn dimsArgv(arena: Allocator, path: []const u8) ![]const []const u8 {
    return arena.dupe([]const u8, &.{ "sips", "-g", "pixelWidth", "-g", "pixelHeight", path });
}

/// Resize in place. Returns false when sips is unavailable or failed — the
/// caller keeps the native-size image and says so rather than pretending.
pub fn resize(arena: Allocator, io: Io, path: []const u8, size: Size) bool {
    if (!available) return false;
    const argv = resizeArgv(arena, path, size) catch return false;
    const out = run_mod.run(arena, io, argv, sips_deadline_ms, null) catch return false;
    return out.ranClean();
}

/// Measured pixel dimensions, best-effort: reporting detail, never part of a
/// pass/fail decision.
pub fn dims(arena: Allocator, io: Io, path: []const u8) ?Size {
    if (!available) return null;
    const argv = dimsArgv(arena, path) catch return null;
    const out = run_mod.run(arena, io, argv, sips_deadline_ms, null) catch return null;
    if (!out.ranClean()) return null;
    return .{
        .w = fieldAfter(out.stdout, "pixelWidth:") orelse return null,
        .h = fieldAfter(out.stdout, "pixelHeight:") orelse return null,
    };
}

fn fieldAfter(text: []const u8, key: []const u8) ?u32 {
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    return std.fmt.parseInt(u32, std.mem.trim(u8, rest[0..line_end], " \t\r"), 10) catch null;
}

const testing = std.testing;

test "#352: sizes parse only as two plain numbers, so the value cannot reach sips as a flag" {
    try testing.expectEqual(Size{ .w = 1024, .h = 1024 }, parseSize("1024x1024").?);
    try testing.expectEqual(Size{ .w = 1024, .h = 1536 }, parseSize("1024X1536").?);
    for ([_][]const u8{ "auto", "", "1024", "1024x", "x1024", "-1x2", "0x512", "20000x20000", "10 x 10", "1024x1024 -j" }) |bad|
        try testing.expect(parseSize(bad) == null);
}

test "#352: resize passes height before width, and dims reads what sips measured" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try resizeArgv(arena, "out.png", .{ .w = 64, .h = 128 });
    // Element-wise: expectEqualSlices on []const u8 would compare pointers.
    const want = [_][]const u8{ "sips", "-z", "128", "64", "out.png" };
    try testing.expectEqual(want.len, argv.len);
    for (want, argv) |w, got| try testing.expectEqualStrings(w, got);

    const S = struct {
        fn fake(_: Allocator, _: Io, _: []const []const u8, _: u64, _: ?[]const u8) anyerror!run_mod.Outcome {
            return .{ .exit_code = 0, .stdout = "/tmp/a.png\n  pixelWidth: 1024\n  pixelHeight: 768\n" };
        }
        fn broken(_: Allocator, _: Io, _: []const []const u8, _: u64, _: ?[]const u8) anyerror!run_mod.Outcome {
            return .{ .exit_code = 1, .stderr = "sips: no such file" };
        }
    };
    const saved = run_mod.hook;
    defer run_mod.hook = saved;

    run_mod.hook = S.fake;
    if (available) {
        try testing.expectEqual(Size{ .w = 1024, .h = 768 }, dims(arena, testing.io, "/tmp/a.png").?);
        try testing.expect(resize(arena, testing.io, "/tmp/a.png", .{ .w = 64, .h = 64 }));
        run_mod.hook = S.broken;
        try testing.expect(!resize(arena, testing.io, "/tmp/a.png", .{ .w = 64, .h = 64 })); // failure is reported, not swallowed
        try testing.expect(dims(arena, testing.io, "/tmp/a.png") == null);
    } else {
        // Off macOS both are honest no-ops; the caller reports native size.
        try testing.expect(dims(arena, testing.io, "/tmp/a.png") == null);
        try testing.expect(!resize(arena, testing.io, "/tmp/a.png", .{ .w = 64, .h = 64 }));
    }
}
