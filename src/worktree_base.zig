//! Durable landing branch for task workspaces. Never infer it from the caller's current branch.
const std = @import("std");
const runner = @import("process_runner.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub fn text(gpa: Allocator, io: Io, arena: Allocator, argv: []const []const u8) []const u8 {
    const r = runner.runCapped(gpa, io, argv, 8192, 8192, 15_000) catch return "";
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (!runner.ranOk(r)) return "";
    return arena.dupe(u8, std.mem.trim(u8, r.stdout, " \t\r\n")) catch "";
}

pub fn branch(gpa: Allocator, io: Io, arena: Allocator, cwd: []const u8) []const u8 {
    return text(gpa, io, arena, &.{ "git", "-C", cwd, "symbolic-ref", "--short", "HEAD" });
}

pub fn record(gpa: Allocator, io: Io, arena: Allocator, cwd: []const u8, owned: []const u8, base: []const u8) void {
    const ref = text(gpa, io, arena, &.{ "git", "-C", cwd, "rev-parse", "--symbolic-full-name", if (base.len > 0) base else "HEAD" });
    const target = if (std.mem.startsWith(u8, ref, "refs/heads/")) ref[11..] else if (std.mem.startsWith(u8, ref, "refs/remotes/")) blk: {
        const rest = ref[13..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return;
        break :blk rest[slash + 1 ..];
    } else branch(gpa, io, arena, cwd);
    if (target.len == 0) return;
    const key = std.fmt.allocPrint(arena, "branch.{s}.graff-base", .{owned}) catch return;
    _ = text(gpa, io, arena, &.{ "git", "-C", cwd, "config", key, target });
}

pub fn read(gpa: Allocator, io: Io, arena: Allocator, cwd: []const u8, owned: []const u8) []const u8 {
    const key = std.fmt.allocPrint(arena, "branch.{s}.graff-base", .{owned}) catch return "";
    return text(gpa, io, arena, &.{ "git", "-C", cwd, "config", "--get", key });
}
