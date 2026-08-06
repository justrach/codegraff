//! Isolated review-mode policy. A review is a separate, one-shot execution
//! layer: report findings, never silently cross into remediation or delegation.

const std = @import("std");
const ToolCall = @import("tools.zig").ToolCall;
const ExecResult = @import("tools.zig").ExecResult;
// The read-only classifier only — never the approval session (#422 ratchet).
const policy = @import("harness_policy.zig");

/// Give a review a fresh model-visible history while retaining the parent
/// transcript. The caller restores the parent after the one-shot review and
/// records only its user request and final report there.
pub const Context = struct {
    parent: ?std.json.Array = null,
    parent_context_tokens: u64 = 0,
    parent_context_local_tokens: u64 = 0,
    parent_usage_includes_output: bool = false,

    pub fn begin(arena: std.mem.Allocator, root: anytype, isolate: bool) Context {
        if (!isolate) return .{};
        const context = Context{
            .parent = root.messages,
            .parent_context_tokens = root.last_context_tokens,
            .parent_context_local_tokens = root.context_local_tokens,
            .parent_usage_includes_output = root.last_usage_includes_output,
        };
        root.messages = std.json.Array.init(arena);
        root.last_context_tokens = 0;
        root.context_local_tokens = 0;
        root.last_usage_includes_output = false;
        return context;
    }

    pub fn restore(self: *Context, root: anytype) bool {
        const parent = self.parent orelse return false;
        root.messages = parent;
        root.last_context_tokens = self.parent_context_tokens;
        root.context_local_tokens = self.parent_context_local_tokens;
        root.last_usage_includes_output = self.parent_usage_includes_output;
        self.parent = null;
        return true;
    }
};

pub fn promptFromLine(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "/review ")) return null;
    const prompt = std.mem.trim(u8, line["/review".len..], " \t\r\n");
    return if (prompt.len == 0) null else prompt;
}

pub fn systemPrompt(arena: std.mem.Allocator, base: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\{s}
        \\
        \\[review task: Perform one read-only, defect-first review pass. Inspect
        \\the requested target directly. Start by resolving the comparison and
        \\reading the complete git diff (including staged, unstaged, and untracked
        \\changes when applicable). Run each git command as a separate shell call;
        \\chained commands are rejected. Code search alone is not a review. Continue
        \\through the whole diff, then inspect enough surrounding code, tests, and
        \\callers to prove each issue. Do not modify files, delegate, run workflows,
        \\use the network, or switch from review into implementation. Report only
        \\discrete, actionable regressions the author would likely fix, findings
        \\first and ordered P0-P3 with the smallest useful file:line range. If none
        \\qualify, say "No findings." Then give a brief overall verdict and stop.]
    , .{base});
}

/// Hard capability boundary for a review root. Only local reads/searches,
/// read-only shell inspection, and explicit finalization are admitted.
pub fn rejectTool(arena: std.mem.Allocator, call: ToolCall) !?ExecResult {
    if (std.mem.eql(u8, call.name, "read_file") or
        std.mem.eql(u8, call.name, "codedb") or
        std.mem.eql(u8, call.name, "attempt_completion")) return null;

    if (std.mem.eql(u8, call.name, "bash") and call.input == .object) {
        const command = call.input.object.get("command") orelse return denied(arena, call.name);
        const background = call.input.object.get("run_in_background");
        if (command == .string and
            (background == null or background.? != .bool or !background.?.bool) and
            policy.readOnlyAllowed(command.string)) return null;
    }
    return denied(arena, call.name);
}

fn denied(arena: std.mem.Allocator, name: []const u8) !?ExecResult {
    return .{
        .text = try std.fmt.allocPrint(arena, "review mode is read-only and single-pass; {s} is unavailable — report findings without changing or delegating work", .{name}),
        .is_error = true,
    };
}

test "review command requires a non-empty target" {
    try std.testing.expectEqualStrings("HEAD against main", promptFromLine("/review HEAD against main").?);
    try std.testing.expect(promptFromLine("/review") == null);
    try std.testing.expect(promptFromLine("/review   ") == null);
    try std.testing.expect(promptFromLine("please review this") == null);
}

test "review tool boundary admits reads and rejects edits, delegation, and background shell" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const empty = std.json.parseFromSliceLeaky(std.json.Value, arena, "{}", .{}) catch unreachable;
    const read: ToolCall = .{ .id = "1", .name = "read_file", .input = empty };
    const edit: ToolCall = .{ .id = "2", .name = "edit_file", .input = empty };
    const workflow: ToolCall = .{ .id = "3", .name = "workflow", .input = empty };
    const background: ToolCall = .{
        .id = "4",
        .name = "bash",
        .input = std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"command\":\"git status\",\"run_in_background\":true}", .{}) catch unreachable,
    };
    try std.testing.expect((try rejectTool(arena, read)) == null);
    try std.testing.expect((try rejectTool(arena, edit)).?.is_error);
    try std.testing.expect((try rejectTool(arena, workflow)).?.is_error);
    try std.testing.expect((try rejectTool(arena, background)).?.is_error);
}

test "review context hides and restores parent history" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Root = struct {
        messages: std.json.Array,
        last_context_tokens: u64 = 900,
        context_local_tokens: u64 = 300,
        last_usage_includes_output: bool = true,
    };
    var root = Root{ .messages = std.json.Array.init(arena) };
    try root.messages.append(.{ .string = "parent" });
    var context = Context.begin(arena, &root, true);
    try std.testing.expectEqual(@as(usize, 0), root.messages.items.len);
    try std.testing.expectEqual(@as(u64, 0), root.last_context_tokens);
    try std.testing.expectEqual(@as(u64, 0), root.context_local_tokens);
    try std.testing.expect(!root.last_usage_includes_output);
    try root.messages.append(.{ .string = "review" });
    try std.testing.expect(context.restore(&root));
    try std.testing.expectEqualStrings("parent", root.messages.items[0].string);
    try std.testing.expectEqual(@as(u64, 900), root.last_context_tokens);
    try std.testing.expectEqual(@as(u64, 300), root.context_local_tokens);
    try std.testing.expect(root.last_usage_includes_output);
    try std.testing.expect(!context.restore(&root));
}
