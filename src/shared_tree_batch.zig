//! #1553: one shared-tree checkpoint holds the whole batch.
//!
//! The checkpoint fires once for the peers live now and acknowledges them, so
//! the re-issued call proceeds. Gating a parallel batch call by call let the
//! first mutation take the checkpoint and every sibling after it pass the
//! now-acknowledged gate: one result said "NOT performed" while the other
//! edits landed before any coordination. Once a call in the batch is held,
//! every sibling mutation of the shared tree is held with it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tools_mod = @import("tools.zig");
const presence = @import("presence.zig");
const shell_tool = @import("shell_tool.zig");
const ToolCall = tools_mod.ToolCall;
const ExecResult = tools_mod.ExecResult;

/// The text every checkpoint result carries (presence.gateCheckIdentity).
pub const marker = "shared-tree checkpoint: the action was NOT performed";

pub const sibling_text = "shared-tree checkpoint: the action was NOT performed because a sibling call in this batch hit the checkpoint (see that result). Coordinate or decide first, then re-issue this call.";

pub fn isCheckpoint(r: ExecResult) bool {
    return r.is_error and std.mem.indexOf(u8, r.text, marker) != null;
}

/// A call the checkpoint guards: a file write or edit, or a shell command
/// that mutates the shared tree or index.
pub fn mutates(gpa: Allocator, io: Io, arena: Allocator, call: ToolCall) bool {
    if (std.mem.eql(u8, call.name, "write_file") or std.mem.eql(u8, call.name, "edit_file")) return true;
    if (!shell_tool.runsCommand(call.name) or call.input != .object) return false;
    const v = call.input.object.get("command") orelse return false;
    if (v != .string) return false;
    const cmd = std.mem.trim(u8, v.string, " \t");
    if (!presence.isSharedTreeGit(cmd) and !presence.isSharedTreeShell(cmd)) return false;
    return presence.sharedTreeGateApplies(gpa, io, arena, cmd);
}

/// Take every guarded call out of `run` and answer it with the sibling hold.
pub fn hold(gpa: Allocator, io: Io, arena: Allocator, calls: []const ToolCall, results: []ExecResult, run: *std.ArrayList(usize)) void {
    var kept: usize = 0;
    for (run.items) |i| {
        if (mutates(gpa, io, arena, calls[i])) {
            results[i] = .{ .text = sibling_text, .is_error = true };
            continue;
        }
        run.items[kept] = i;
        kept += 1;
    }
    run.shrinkRetainingCapacity(kept);
}

test "a checkpoint in a batch holds every sibling write, before or after it (#1553)" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var edit_args: std.json.ObjectMap = .empty;
    try edit_args.put(a, "path", .{ .string = "a.txt" });
    var read_args: std.json.ObjectMap = .empty;
    try read_args.put(a, "path", .{ .string = "b.txt" });
    var ls_args: std.json.ObjectMap = .empty;
    try ls_args.put(a, "command", .{ .string = "ls" });
    const calls = [_]ToolCall{
        .{ .id = "0", .name = "edit_file", .input = .{ .object = edit_args } },
        .{ .id = "1", .name = "write_file", .input = .{ .object = edit_args } },
        .{ .id = "2", .name = "read_file", .input = .{ .object = read_args } },
        .{ .id = "3", .name = "bash", .input = .{ .object = ls_args } },
        .{ .id = "4", .name = "edit_file", .input = .{ .object = edit_args } },
    };
    var results: [calls.len]ExecResult = undefined;
    results[1] = .{ .text = marker ++ ". Re-issue the identical call to proceed", .is_error = true };
    try std.testing.expect(isCheckpoint(results[1]));
    var run: std.ArrayList(usize) = .empty;
    defer run.deinit(gpa);
    try run.appendSlice(gpa, &.{ 0, 2, 3, 4 });
    hold(gpa, std.testing.io, a, &calls, &results, &run);
    try std.testing.expectEqualSlices(usize, &.{ 2, 3 }, run.items);
    for ([_]usize{ 0, 4 }) |i| {
        try std.testing.expect(results[i].is_error);
        try std.testing.expect(std.mem.indexOf(u8, results[i].text, "NOT performed") != null);
    }
}

test "a parallel batch of writes beside a live peer lands none of them (#1553)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const proc_identity = @import("proc_identity.zig");
    const Agent = @import("agent.zig").Agent;
    const Approvals = @import("approvals.zig").Approvals;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{root});
    const registry = try std.fmt.allocPrint(a, "{s}/registry", .{root});
    try tmp.dir.createDirPath(io, "repo");
    try tmp.dir.createDirPath(io, "registry");
    const runner = @import("process_runner.zig");
    const r = try runner.runCapped(gpa, io, &.{ "git", "init", "-q", repo }, 4096, 4096, 15_000);
    gpa.free(r.stdout);
    gpa.free(r.stderr);
    const id = @import("worktree_lease.zig").identityAt(gpa, io, a, repo).id;
    try std.testing.expect(id.len > 0);
    // The live peer: this test's parent process, recorded in the same tree.
    const ppid: i32 = @intCast(std.c.getppid());
    const start: proc_identity.StartId = switch (proc_identity.probe(io, ppid)) {
        .gone => return error.SkipZigTest,
        .id => |v| v,
        .unknown => 1,
    };
    const peer: @import("worktree_lease.zig").Owner = .{ .pid = ppid, .start_id = start, .session_id = "s-peer", .identity = id };
    try tmp.dir.writeFile(io, .{ .sub_path = "registry/peer.json", .data = try presence.formatRecord(a, peer) });
    presence.bindForTest(registry, id, "s-caller", proc_identity.selfRecord(io));
    defer presence.unbindForTest();

    var approvals: Approvals = .{ .yolo = true };
    var agent: Agent = .{ .gpa = gpa, .arena = a, .io = io, .client = undefined, .provider = .{ .id = "fixture", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "fixture", .context = 1000 }, .messages = .init(a), .sub = false, .label = "root", .out = null, .approvals = &approvals, .agent_cwd = repo };
    defer agent.tools_used.deinit(gpa);
    var calls: [3]ToolCall = undefined;
    for (&calls, [_][]const u8{ "a.txt", "b.txt", "c.txt" }, 0..) |*call, name, i| {
        var args: std.json.ObjectMap = .empty;
        try args.put(a, "path", .{ .string = name });
        try args.put(a, "content", .{ .string = "x\n" });
        call.* = .{ .id = try std.fmt.allocPrint(a, "w{d}", .{i}), .name = "write_file", .input = .{ .object = args } };
    }
    const results = try agent.runTools(&calls);
    for (results) |res| try std.testing.expect(res.is_error);
    var repo_dir = try tmp.dir.openDir(io, "repo", .{});
    defer repo_dir.close(io);
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }) |name| {
        try std.testing.expectError(error.FileNotFound, repo_dir.access(io, name, .{}));
    }
}
