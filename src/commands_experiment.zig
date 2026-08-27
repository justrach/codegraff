//! `/experiment` — arm or inspect the #629 worktree pool (279 continuation).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const pool = @import("experiment_pool.zig");
const style = &@import("ansi.zig").style;

pub fn tryHandle(root: *Agent, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    if (!std.mem.eql(u8, line, "/experiment") and !std.mem.startsWith(u8, line, "/experiment "))
        return false;
    const rest = std.mem.trim(u8, line["/experiment".len..], " \t");
    if (rest.len == 0 or std.mem.eql(u8, rest, "status")) {
        var buf: [80]u8 = undefined;
        try out.print("  {s}{s}{s}\n", .{ style.dim, pool.statusLine(&buf), style.reset });
        try out.flush();
        return true;
    }
    if (std.mem.eql(u8, rest, "off") or std.mem.eql(u8, rest, "clear")) {
        pool.reset();
        try out.print("  {s}experiment pool off{s}\n", .{ style.dim, style.reset });
        try out.flush();
        return true;
    }
    const n = std.fmt.parseInt(u8, rest, 10) catch 0;
    if (n == 0 or n > pool.cap) {
        try out.print("  {s}usage: /experiment [N|off|status]  (N is 1-{d}){s}\n", .{ style.dim, pool.cap, style.reset });
        try out.flush();
        return true;
    }
    const raw = if (root.session_name.len > 0) root.session_name else "live";
    var idbuf: [64]u8 = undefined;
    const id = pool.sanitizeId(&idbuf, raw);
    const minted = pool.arm(root.gpa, root.io, arena, id, n) catch |err| {
        try out.print("  {s}experiment: {t}{s}\n", .{ style.red, err, style.reset });
        try out.flush();
        return true;
    };
    if (pool.directive()) |d| {
        if (root.sys_base.len > 0 and std.mem.indexOf(u8, root.sys_base, pool.directive_marker) == null) {
            const next = std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ root.sys_base, d }) catch root.sys_base;
            @import("prompts.zig").setSystemPrompts(root, next, arena) catch {};
        }
    }
    try out.print("  {s}experiment {s}: {d} trees under .graff/worktrees/exp-{s}/ — spawn, do not edit here{s}\n", .{
        style.dim, id, minted, id, style.reset,
    });
    try out.flush();
    return true;
}

fn stubRoot(out: *Io.Writer) Agent {
    return .{
        .gpa = std.testing.allocator,
        .arena = std.testing.allocator,
        .io = std.testing.io,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = out,
        .session_name = "live",
    };
}

test "tryHandle: status/off/usage, unrelated lines fall through" {
    pool.reset();
    defer pool.reset();
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var root = stubRoot(&aw.writer);
    const a = std.testing.allocator;

    try std.testing.expect(!try tryHandle(&root, a, "/help", &aw.writer));
    try std.testing.expect(!try tryHandle(&root, a, "/experimental", &aw.writer));

    try std.testing.expect(try tryHandle(&root, a, "/experiment", &aw.writer));
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "experiment pool off") != null);

    aw.clearRetainingCapacity();
    try std.testing.expect(try tryHandle(&root, a, "/experiment status", &aw.writer));
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "experiment pool off") != null);

    aw.clearRetainingCapacity();
    try std.testing.expect(try tryHandle(&root, a, "/experiment off", &aw.writer));
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "experiment pool off") != null);

    aw.clearRetainingCapacity();
    try std.testing.expect(try tryHandle(&root, a, "/experiment 0", &aw.writer));
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "usage:") != null);

    aw.clearRetainingCapacity();
    try std.testing.expect(try tryHandle(&root, a, "/experiment 17", &aw.writer));
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "usage:") != null);

    aw.clearRetainingCapacity();
    try std.testing.expect(try tryHandle(&root, a, "/experiment no", &aw.writer));
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "usage:") != null);
}
