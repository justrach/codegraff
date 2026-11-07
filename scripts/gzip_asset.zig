//! Build-time helper: `gzip_asset <in> <out>` gzips one file. build.zig runs it
//! over text the CLI only needs at run time (an installer script, HTML pages),
//! so the release binary carries those compressed; callers read them back with
//! update_archive.gunzip, which `graff update` already links in.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) std.process.fatal("usage: gzip_asset <in> <out>", .{});
    const cwd = std.Io.Dir.cwd();
    const plain = try cwd.readFileAlloc(init.io, args[1], init.gpa, .limited(1 << 24));
    defer init.gpa.free(plain);

    // Compress needs a writer that already has room to emit into.
    var out: std.Io.Writer.Allocating = try .initCapacity(init.gpa, plain.len + 1024);
    defer out.deinit();
    const window = try init.gpa.alloc(u8, std.compress.flate.max_window_len);
    defer init.gpa.free(window);
    const c = try init.gpa.create(std.compress.flate.Compress);
    defer init.gpa.destroy(c);
    c.* = try std.compress.flate.Compress.init(&out.writer, window, .gzip, .best);
    try c.writer.writeAll(plain);
    try c.finish();
    try cwd.writeFile(init.io, .{ .sub_path = args[2], .data = out.written() });
}
