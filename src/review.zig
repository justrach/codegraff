//! Bounded review-mode policy. A review is a separate, one-shot execution
//! layer: report findings, never silently cross into remediation or delegation.

const std = @import("std");
const ToolCall = @import("tools.zig").ToolCall;
const ExecResult = @import("tools.zig").ExecResult;
const Approvals = @import("approvals.zig").Approvals;

pub const max_model_calls: u32 = 10;
pub const max_tool_calls: u64 = 40;
pub const final_note =
    "Review exploration budget reached. Do not call tools. Return the prioritized, actionable findings you can defend from the evidence already gathered, then the overall verdict. If none qualify, say \"No findings.\"";

pub fn promptFromLine(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "/review ")) return null;
    const prompt = std.mem.trim(u8, line["/review".len..], " \t\r\n");
    return if (prompt.len == 0) null else prompt;
}

pub fn steeringNote(arena: std.mem.Allocator, prompt: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\{s}
        \\
        \\[review mode: Perform one read-only, defect-first review pass. Inspect
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
    , .{prompt});
}

/// Hard capability boundary for a review root. Only local reads/searches,
/// read-only shell inspection, and explicit finalization are admitted.
pub fn rejectTool(arena: std.mem.Allocator, call: ToolCall, finalizing: bool) !?ExecResult {
    if (finalizing and !std.mem.eql(u8, call.name, "attempt_completion")) return denied(arena, call.name);
    if (std.mem.eql(u8, call.name, "read_file") or
        std.mem.eql(u8, call.name, "codedb") or
        std.mem.eql(u8, call.name, "attempt_completion")) return null;

    if (std.mem.eql(u8, call.name, "bash") and call.input == .object) {
        const command = call.input.object.get("command") orelse return denied(arena, call.name);
        const background = call.input.object.get("run_in_background");
        if (command == .string and
            (background == null or background.? != .bool or !background.?.bool) and
            Approvals.readOnlyAllowed(command.string)) return null;
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
    try std.testing.expect((try rejectTool(arena, read, false)) == null);
    try std.testing.expect((try rejectTool(arena, edit, false)).?.is_error);
    try std.testing.expect((try rejectTool(arena, workflow, false)).?.is_error);
    try std.testing.expect((try rejectTool(arena, background, false)).?.is_error);
    try std.testing.expect((try rejectTool(arena, read, true)).?.is_error);
}
