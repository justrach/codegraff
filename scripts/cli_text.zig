//! Materialize the configured CLI text for the shared gzip build helper.
const std = @import("std");
const source = @import("cli_text_source");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) std.process.fatal("usage: cli_text <help> <changelog>", .{});
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(init.io, .{ .sub_path = args[1], .data = source.usage_text });
    try cwd.writeFile(init.io, .{ .sub_path = args[2], .data = source.changelog_text });
}
