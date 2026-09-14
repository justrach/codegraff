//! A failed PATH lookup does not establish that a CLI is not installed.
//! Read-only suggestions only: never replay a shell command or change PATH.
const std = @import("std");
const builtin = @import("builtin");

fn bareCommand(cmd: []const u8) ?[]const u8 {
    var words = std.mem.tokenizeAny(u8, cmd, " \t\r\n");
    const word = words.next() orelse return null;
    if (word.len > 80 or word.len == 0 or word[0] == '-') return null;
    for (word) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') return null;
    return word;
}

fn lookupFailure(cmd: []const u8, output: []const u8) ?[]const u8 {
    const name = bareCommand(cmd) orelse return null;
    var buf: [128]u8 = undefined;
    for ([_][]const u8{ ": command not found", ": not found" }) |suffix| {
        const needle = std.fmt.bufPrint(&buf, "{s}{s}", .{ name, suffix }) catch unreachable;
        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.endsWith(u8, line, needle)) {
                const start = line.len - needle.len;
                if (start == 0 or line[start - 1] == ' ' or line[start - 1] == ':') return name;
            }
        }
    }
    const needle = std.fmt.bufPrint(&buf, "command not found: {s}", .{name}) catch unreachable;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| if (std.mem.endsWith(u8, std.mem.trim(u8, line, " \t\r"), needle)) return name;
    return null;
}

pub fn append(a: std.mem.Allocator, io: std.Io, cmd: []const u8, result: *@import("tools.zig").ToolOutput) !void {
    if (!result.is_error or result.cancelled) return;
    const name = lookupFailure(cmd, result.text) orelse return;
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(result.text);
    try w.writeAll("\n[CLI lookup] A PATH lookup failure does not prove the executable is absent. Check standard install locations before declaring it unavailable or switching to browser automation. Preserve the requested CLI workflow when an installed executable works. Do not replay a compound command that may already have performed earlier actions.\n");
    if (builtin.os.tag != .windows) {
        for ([_][]const u8{ "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin" }) |dir| {
            var buf: [256]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch unreachable;
            const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch continue;
            if (stat.kind != .file) continue;
            std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch continue;
            try w.print("Executable candidate: {s}. Verify its identity and use its absolute path for the still-authorized operation.\n", .{path});
        }
        try w.writeAll("If no candidate works, check user install directories such as ~/bin and ~/.local/bin through the shell before concluding it is unavailable.");
    } else try w.writeAll("Check the standard application installation directory and user installation directories through the shell before concluding it is unavailable.");
    const text = try aw.toOwnedSlice();
    a.free(result.text);
    result.text = text;
}

test "recognize shell lookup failures for the invoked bare CLI" {
    try std.testing.expectEqualStrings("gh", lookupFailure("gh issue list", "/bin/bash: line 1: gh: command not found").?);
    try std.testing.expectEqualStrings("gh", lookupFailure("gh issue list", "zsh:1: command not found: gh").?);
    try std.testing.expectEqualStrings("gh", lookupFailure("gh issue list", "sh: gh: not found").?);
    try std.testing.expect(lookupFailure("gh issue list", "authentication failed") == null);
    try std.testing.expect(lookupFailure("gh issue list", "notgh: command not found") == null);
    try std.testing.expect(lookupFailure("echo gh", "gh: command not found") == null);
    try std.testing.expect(lookupFailure("/missing/gh version", "/missing/gh: not found") == null);
    try std.testing.expect(lookupFailure("PATH=none gh version", "gh: not found") == null);
}

test "successful and cancelled results never gain CLI recovery advice" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |cancelled| {
        var result: @import("tools.zig").ToolOutput = .{ .text = try a.dupe(u8, "gh: command not found"), .is_error = cancelled, .cancelled = cancelled };
        defer a.free(result.text);
        try append(a, std.testing.io, "gh version", &result);
        try std.testing.expectEqualStrings("gh: command not found", result.text);
    }
}

test "lookup advice preserves the failure and reports an installed executable" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const a = std.testing.allocator;
    var result: @import("tools.zig").ToolOutput = .{ .text = try a.dupe(u8, "sh: command not found\n[exit code 127]"), .is_error = true };
    defer a.free(result.text);
    try append(a, std.testing.io, "sh -c true", &result);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.startsWith(u8, result.text, "sh: command not found\n[exit code 127]"));
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Executable candidate: /bin/sh.") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Do not replay a compound command") != null);
}
