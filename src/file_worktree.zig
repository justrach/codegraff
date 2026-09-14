//! Resolve file-edit ownership from the target directory, including new files.
const std = @import("std");
const lease = @import("worktree_lease.zig");

/// Unknown/non-Git targets retain the caller's conservative checkpoint.
/// Use the same session-relative path resolution as the actual file tools.
pub fn identity(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, cwd: ?[]const u8, file: []const u8) ?[]const u8 {
    if (file.len == 0 or std.mem.eql(u8, file, "?")) return null;
    const absolute = @import("codedbpro_paths.zig").sessionAbs(arena, io, cwd, file) catch return null;
    var parent = std.fs.path.dirname(absolute) orelse return null;
    // New files can have not-yet-created parent directories. Stop at the
    // nearest existing directory; permission errors must not skip boundaries.
    while (true) {
        var dir = std.Io.Dir.cwd().openDir(io, parent, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                const next = std.fs.path.dirname(parent) orelse return null;
                if (std.mem.eql(u8, next, parent)) return null;
                parent = next;
                continue;
            },
            else => return null,
        };
        dir.close(io);
        const at = lease.identityAt(gpa, io, arena, parent);
        if (at.kind == .not_git or at.id.len == 0) return null;
        const source = @import("codedbpro_paths.zig").sessionAbs(arena, io, cwd, ".") catch return null;
        const mine = lease.identityAt(gpa, io, arena, source);
        // Preserve the announced identity when git init occurred after startup.
        if (std.mem.eql(u8, at.id, mine.id)) return null;
        return at.id;
    }
}

test "file checkpoints distinguish nested linked worktrees from ordinary directories" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const linked = try std.fs.path.join(a, &.{ root, "nested" });
    const runner = @import("process_runner.zig");
    const commands = [_][]const []const u8{
        &.{ "git", "init", "-q", root },
        &.{ "git", "-C", root, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "fixture" },
        &.{ "git", "-C", root, "worktree", "add", "--detach", linked },
    };
    for (commands) |argv| {
        const result = try runner.runCapped(gpa, io, argv, 4096, 4096, 15_000);
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        try std.testing.expect(runner.ranOk(result));
    }
    const linked_id = lease.identityAt(gpa, io, a, linked);
    try std.testing.expectEqual(lease.Identity.Kind.linked_worktree, linked_id.kind);
    const existing = try std.fs.path.join(a, &.{ linked, "existing.txt" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = existing, .data = "before" });
    try std.testing.expectEqualStrings(linked_id.id, identity(gpa, io, a, root, existing).?);
    try std.testing.expectEqualStrings(linked_id.id, identity(gpa, io, a, root, "nested/new/deep/file.txt").?);
    try std.testing.expect(identity(gpa, io, a, root, "ordinary/new/file.txt") == null);
    try std.testing.expect(identity(gpa, io, a, linked, "new/file.txt") == null);
    // Unknown input keeps the conservative original checkpoint.
    try std.testing.expect(identity(gpa, io, a, root, "") == null);
}
