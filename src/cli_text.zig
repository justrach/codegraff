//! Runtime-only CLI text; decompression is confined to --help/--version.
const std = @import("std");
const archive = @import("update_archive.zig");

pub fn print(gpa: std.mem.Allocator, out: *std.Io.Writer, help: bool, version: []const u8) !void {
    const text = try archive.gunzip(gpa, if (help) @embedFile("cli_help.gz") else @embedFile("cli_changelog.gz"));
    defer gpa.free(text);
    if (!help) try out.print("graff {s}\n\n", .{version});
    try out.writeAll(text);
}

test "compressed CLI text preserves help and version output" {
    const source = @import("cli_text_source.zig");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try print(std.testing.allocator, &out.writer, true, "test-version");
    try std.testing.expectEqualStrings(source.usage_text, out.written());
    out.clearRetainingCapacity();
    try print(std.testing.allocator, &out.writer, false, "test-version");
    try std.testing.expectEqualStrings("graff test-version\n\n" ++ source.changelog_text, out.written());
}

test "compressed CLI help respects the learn configuration" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try print(std.testing.allocator, &out.writer, true, "unused");
    const learn_line = "  graff learn [help]                local mutate/evaluate/promote/rollback engine\n";
    try std.testing.expectEqual(@import("build_options").learn, std.mem.indexOf(u8, out.written(), learn_line) != null);
}
