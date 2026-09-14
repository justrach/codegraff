//! Transfer clipboard file ownership across the TUI's bounded callback buffer.
const std = @import("std");
const clip = @import("vision_clipboard.zig");
const Transfer = struct { len: usize, owned: bool };

pub fn transfer(grab: clip.Grab, io: std.Io, gpa: std.mem.Allocator, dest: []u8) ?Transfer {
    if (grab.path.len > dest.len) {
        grab.release(io, gpa);
        return null;
    }
    @memcpy(dest[0..grab.path.len], grab.path);
    defer gpa.free(grab.path);
    return .{ .len = grab.path.len, .owned = grab.owned };
}

test "TUI clipboard transfer preserves ownership and leaves the exported pixels readable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_]bool{ true, false }) |owned| {
        try tmp.dir.writeFile(io, .{ .sub_path = "pixels.png", .data = "pixels" });
        const original = try tmp.dir.realPathFileAlloc(io, "pixels.png", gpa);
        defer gpa.free(original);
        var dest: [4096]u8 = undefined;
        const result = transfer(.{ .path = try gpa.dupe(u8, original), .owned = owned, .flavor = .png }, io, gpa, &dest).?;
        try std.testing.expectEqual(owned, result.owned);
        const pixels = try std.Io.Dir.cwd().openFile(io, dest[0..result.len], .{});
        pixels.close(io);
    }
}

test "a TUI clipboard path that does not fit releases an owned export but preserves an original" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_]bool{ true, false }) |owned| {
        try tmp.dir.writeFile(io, .{ .sub_path = "pixels.png", .data = "pixels" });
        const original = try tmp.dir.realPathFileAlloc(io, "pixels.png", gpa);
        defer gpa.free(original);
        var dest: [1]u8 = undefined;
        try std.testing.expect(transfer(.{ .path = try gpa.dupe(u8, original), .owned = owned, .flavor = .png }, io, gpa, &dest) == null);
        if (owned) {
            try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "pixels.png", .{}));
        } else {
            const pixels = try tmp.dir.openFile(io, "pixels.png", .{});
            pixels.close(io);
        }
    }
}
