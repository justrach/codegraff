//! Session-observed failing checks cannot be replaced by publication prose.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ToolCall = @import("tools.zig").ToolCall;
const ExecResult = @import("tools.zig").ExecResult;

pub fn isCheck(command: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, command, " \t\r\n");
    const executable = std.fs.path.basename(words.next() orelse return false);
    if (std.mem.eql(u8, executable, "pytest")) return true;
    const first = words.next() orelse return false;
    if (std.mem.eql(u8, executable, "python") or std.mem.eql(u8, executable, "python3")) {
        if (std.mem.eql(u8, first, "-m")) {
            const module = words.next() orelse return false;
            return std.mem.eql(u8, module, "unittest") or std.mem.eql(u8, module, "pytest");
        }
        const script = std.fs.path.basename(first);
        return std.mem.startsWith(u8, script, "test-") or std.mem.startsWith(u8, script, "test_") or std.mem.startsWith(u8, script, "eval-tier");
    }
    if (std.mem.eql(u8, executable, "zig"))
        return std.mem.eql(u8, first, "test") or (std.mem.eql(u8, first, "build") and std.mem.startsWith(u8, words.next() orelse "", "test"));
    for ([_][]const u8{ "cargo", "go", "bun", "npm", "pnpm", "yarn", "make" }) |runner| {
        if (!std.mem.eql(u8, executable, runner)) continue;
        return std.mem.eql(u8, first, "test") or (std.mem.eql(u8, first, "run") and std.mem.startsWith(u8, words.next() orelse "", "test"));
    }
    return false;
}

pub fn record(root: anytype, call: ToolCall, result: ExecResult) !void {
    if (root.sub or !std.mem.eql(u8, call.name, "bash") or call.input != .object) return;
    const command = call.input.object.get("command") orelse return;
    if (command != .string or !isCheck(command.string)) return;
    var dir = try std.Io.Dir.cwd().openDir(root.io, root.agent_cwd orelse ".", .{});
    defer dir.close(root.io);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = buffer[0..try dir.realPath(root.io, &buffer)];
    try root.publication_checks.observe(root.arena, cwd, call, result);
}

pub fn batchGate(root: anytype, calls: []const ToolCall, call: ToolCall) !?ExecResult {
    if (calls.len <= 1 or !std.mem.eql(u8, call.name, "bash") or call.input != .object) return null;
    const raw = call.input.object.get("command") orelse return null;
    if (raw != .string) return null;
    const command = @import("pr_command.zig").parse(root.arena, raw.string) catch return null;
    if (!std.mem.eql(u8, command.verb, "create") and !std.mem.eql(u8, command.verb, "ready")) return null;
    if (std.mem.eql(u8, command.verb, "create") and command.draft()) return null;
    const text = "PR publication preflight: run non-draft publication in a separate tool call after other work finishes; write NOT performed.";
    root.emitToolRejected(call, "publication_batch", text);
    return .{ .text = text, .is_error = true };
}

pub const State = struct {
    const Entry = struct { cwd: []const u8, command: []const u8 };
    failed: std.ArrayList(Entry) = .empty,

    pub fn observe(self: *State, arena: Allocator, cwd: []const u8, call: ToolCall, result: ExecResult) !void {
        if (!std.mem.eql(u8, call.name, "bash") or call.input != .object) return;
        const raw = call.input.object.get("command") orelse return;
        if (raw != .string or !isCheck(raw.string)) return;
        const command = std.mem.trim(u8, raw.string, " \t\r\n");
        for (self.failed.items, 0..) |entry, i| {
            if (!std.mem.eql(u8, entry.cwd, cwd) or !std.mem.eql(u8, entry.command, command)) continue;
            if (!result.is_error and !result.cancelled and std.mem.indexOf(u8, result.text, "[job ") == null)
                _ = self.failed.orderedRemove(i);
            return;
        }
        if (!result.is_error and !result.cancelled and std.mem.indexOf(u8, result.text, "[job ") == null) return;
        try self.failed.append(arena, .{ .cwd = try arena.dupe(u8, cwd), .command = try arena.dupe(u8, command) });
    }

    pub fn write(self: *const State, writer: anytype) !void {
        try writer.objectField("publication_failed_checks");
        try writer.write(self.failed.items);
    }

    pub fn mixFingerprint(self: *const State, fingerprint: anytype) void {
        fingerprint.num(self.failed.items.len);
        for (self.failed.items) |entry| {
            fingerprint.text(entry.cwd);
            fingerprint.text(entry.command);
        }
    }

    pub fn restore(self: *State, arena: Allocator, object: std.json.ObjectMap) !void {
        var restored: State = .{};
        const saved = object.get("publication_failed_checks") orelse {
            self.* = restored;
            return;
        };
        if (saved != .array) return error.InvalidPublicationChecks;
        for (saved.array.items) |item| {
            if (item != .object) return error.InvalidPublicationChecks;
            const cwd = item.object.get("cwd") orelse return error.InvalidPublicationChecks;
            const command = item.object.get("command") orelse return error.InvalidPublicationChecks;
            if (cwd != .string or command != .string or !std.fs.path.isAbsolute(cwd.string) or command.string.len == 0)
                return error.InvalidPublicationChecks;
            try restored.failed.append(arena, .{ .cwd = try arena.dupe(u8, cwd.string), .command = try arena.dupe(u8, command.string) });
        }
        self.* = restored;
    }

    pub fn unresolved(self: *const State, cwd: []const u8) ?[]const u8 {
        for (self.failed.items) |entry| if (std.mem.eql(u8, entry.cwd, cwd)) return entry.command;
        return null;
    }
};

test "observed failed check survives unrelated success and clears only on its successful rerun" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var state: State = .{};
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"command\":\"python3 -m unittest test_delete -v\"}", .{});
    const call: ToolCall = .{ .id = "test", .name = "bash", .input = input };
    try state.observe(a, "/fixture", call, .{ .text = "FAIL", .is_error = true });
    try std.testing.expect(state.unresolved("/fixture") != null);
    try std.testing.expect(state.unresolved("/other") == null);
    const unrelated = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"command\":\"git diff\"}", .{});
    try state.observe(a, "/fixture", .{ .id = "inspect", .name = "bash", .input = unrelated }, .{ .text = "", .is_error = false });
    try std.testing.expect(state.unresolved("/fixture") != null);
    try state.observe(a, "/fixture", call, .{ .text = "[job 1 started]", .is_error = false });
    try std.testing.expect(state.unresolved("/fixture") != null);
    try state.observe(a, "/fixture", call, .{ .text = "OK", .is_error = false });
    try std.testing.expect(state.unresolved("/fixture") == null);
}

test "check classification excludes prose and ordinary inspection" {
    try std.testing.expect(isCheck("python3 -m unittest test_delete -v"));
    try std.testing.expect(isCheck("zig build test"));
    try std.testing.expect(!isCheck("echo pytest failed"));
    try std.testing.expect(!isCheck("git diff"));
}

test "failed checks survive serialization and malformed state is not a clean resume" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var original: State = .{};
    try original.failed.append(a, .{ .cwd = "/fixture", .command = "zig build test" });
    var output: std.Io.Writer.Allocating = .init(a);
    var writer: std.json.Stringify = .{ .writer = &output.writer };
    try writer.beginObject();
    try original.write(&writer);
    try writer.endObject();
    const saved = try std.json.parseFromSliceLeaky(std.json.Value, a, output.writer.buffered(), .{});
    var resumed: State = .{};
    try resumed.restore(a, saved.object);
    try std.testing.expectEqualStrings("zig build test", resumed.unresolved("/fixture").?);
    const malformed = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"publication_failed_checks\":false}", .{});
    try std.testing.expectError(error.InvalidPublicationChecks, resumed.restore(a, malformed.object));
    try std.testing.expect(resumed.unresolved("/fixture") != null);
}
