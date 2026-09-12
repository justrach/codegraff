//! Resume the layout snapshot, not stale instructions or permission policy.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const map = @import("repo_map.zig");
const prompts = @import("prompts.zig");

pub fn snapshot(root: *const Agent) ?[]const u8 {
    if (root.repo_map_snapshot) |saved| {
        if (std.mem.indexOf(u8, root.sys_base, saved) != null) return saved;
    }
    if (map.cachedSegment()) |fresh| {
        if (std.mem.indexOf(u8, root.sys_base, fresh) != null) return fresh;
    }
    return null;
}

pub fn write(root: *const Agent, s: *std.json.Stringify) !void {
    try s.objectField("repo_map");
    try s.write(snapshot(root));
}

fn savedMap(obj: std.json.ObjectMap) ?[]const u8 {
    const value = obj.get("repo_map") orelse return null;
    if (value != .string or value.string.len > 6 * 1024 + 512) return null;
    if (!std.mem.startsWith(u8, value.string, "\n\n# Project layout (working tree at session start,") or
        !std.mem.endsWith(u8, value.string, "\n")) return null;
    return value.string;
}

pub fn restore(root: *Agent, obj: std.json.ObjectMap) !void {
    const current = snapshot(root) orelse {
        root.repo_map_snapshot = null; // The current prompt opted out of a map.
        return;
    };
    const workspace = obj.get("workspace");
    const same_workspace = if (workspace) |v|
        v == .string and std.mem.eql(u8, v.string, @import("main.zig").g_cwd_display)
    else
        false;
    // Legacy saves and cross-workspace resumes use this process's fresh map.
    const desired = (if (same_workspace) savedMap(obj) else null) orelse map.cachedSegment() orelse current;
    if (!std.mem.eql(u8, current, desired)) {
        const at = std.mem.indexOf(u8, root.sys_base, current) orelse return;
        const base = try std.fmt.allocPrint(root.arena, "{s}{s}{s}", .{
            root.sys_base[0..at], desired, root.sys_base[at + current.len ..],
        });
        // Recompose all variants while keeping today's instructions on both sides.
        try prompts.setSystemPrompts(root, base, root.arena);
    }
    root.repo_map_snapshot = desired;
}

test "#867 production save load preserves layout after tree changes without restoring old rules" {
    const session = @import("session.zig");
    const writer = @import("session_writer.zig");
    const transcript = @import("session_transcript.zig");
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    writer.resetForTest();
    defer writer.resetForTest();
    transcript.resetForTest();
    defer transcript.resetForTest();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = path_buf[0..try tmp.dir.realPath(io, &path_buf)];
    try tmp.dir.writeFile(io, .{ .sub_path = "first.txt", .data = "synthetic" });
    const original = map.build(io, a, abs) orelse return error.TestUnexpectedResult;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var keys: @import("provider.zig").Keys = .{ .values = @splat("test-key") };
    var root: Agent = .{
        .gpa = gpa,
        .arena = a,
        .io = io,
        .client = &client,
        .provider = try keys.providerById("anthropic", "sonnet"),
        .messages = (try std.json.parseFromSliceLeaky(std.json.Value, a, "[{\"role\":\"user\",\"content\":\"synthetic\"}]", .{})).array,
        .sub = false,
        .label = "root",
        .out = null,
        .home = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}),
        .repo_map_snapshot = original,
    };
    const before = try std.fmt.allocPrint(a, "RULE{s}\n\nAFTER", .{original});
    try prompts.setSystemPrompts(&root, before, a);
    try session.saveSessionTo(&root, a, tmp.dir, "layout-867");
    session.flushSaves();
    try tmp.dir.writeFile(io, .{ .sub_path = "later.txt", .data = "synthetic" });
    const fresh = map.build(io, a, abs) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.eql(u8, original, fresh));
    const rebooted = try std.fmt.allocPrint(a, "RULE{s}\n\nAFTER", .{fresh});
    try prompts.setSystemPrompts(&root, rebooted, a);
    root.repo_map_snapshot = fresh;
    try session.loadSession(&root, &keys, a, "layout-867");
    try std.testing.expectEqualStrings(before, root.sys_base);
    try std.testing.expectEqualStrings(original, snapshot(&root).?);
    // The old map must never freeze new instructions around it.
    const changed_rules = try std.fmt.allocPrint(a, "CURRENT RULE{s}\n\nCURRENT AFTER", .{fresh});
    try prompts.setSystemPrompts(&root, changed_rules, a);
    root.repo_map_snapshot = fresh;
    try session.loadSession(&root, &keys, a, "layout-867");
    const expected = try std.fmt.allocPrint(a, "CURRENT RULE{s}\n\nCURRENT AFTER", .{original});
    try std.testing.expectEqualStrings(expected, root.sys_base);
    try prompts.setSystemPrompts(&root, "NO MAP", a);
    root.repo_map_snapshot = null;
    try session.loadSession(&root, &keys, a, "layout-867");
    try std.testing.expectEqualStrings("NO MAP", root.sys_base);
}
