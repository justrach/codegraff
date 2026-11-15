const std = @import("std");
const policy = @import("hard_policy.zig");
const context = @import("hard_policy_context.zig");
const gate = @import("hard_policy_gate.zig");
const tools = @import("tools.zig");
const io = std.testing.io;
const restrictions =
    \\{"policies":[{"action":"tool.use","resource":"shell","effect":"deny"},{"action":"tool.use","resource":"ask_user","effect":"deny"},{"action":"provider.use","resource":"fixture","effect":"deny"},{"action":"mcp.use","resource":"fixture","effect":"deny"},{"action":"plugin.use","resource":"fixture","effect":"deny"},{"action":"websearch.use","resource":"fixture","effect":"deny"},{"action":"skill.use","resource":"fixture","effect":"deny"}]}
;

fn save(dir: std.Io.Dir, text: []const u8) !void {
    try dir.createDirPath(io, ".harness");
    try dir.writeFile(io, .{ .sub_path = policy.settings_path, .data = text });
}

fn toolContext(cwd: []const u8, inherited: ?*const policy.Document) tools.ToolCtx {
    return .{ .gpa = std.testing.allocator, .io = io, .client = undefined, .provider = .{ .id = "fixture", .url = "", .api_key = "", .model = "", .kind = .openai, .auth = .bearer, .context = 10000 }, .registry = null, .from_sub = true, .approvals = null, .tracer = null, .agent_cwd = cwd, .hard_policy = inherited };
}

test "hard policy isolated child missing settings and explicit allows cannot escape root ceiling" {
    var root = std.testing.tmpDir(.{});
    defer root.cleanup();
    var child = std.testing.tmpDir(.{});
    defer child.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try save(root.dir, restrictions);
    const root_path = try root.dir.realPathFileAlloc(io, ".", a);
    const child_path = try child.dir.realPathFileAlloc(io, ".", a);
    var root_agent: @import("agent.zig").Agent = .{
        .gpa = a,
        .arena = a,
        .io = io,
        .client = undefined,
        .provider = toolContext(root_path, null).provider,
        .messages = .init(a),
        .sub = false,
        .label = "fixture",
        .out = null,
        .agent_cwd = root_path,
        .worker_family = "fixture",
    };
    const inherited = @import("agent_tool_batch.zig").context(&root_agent).hard_policy.?;
    var child_agent = root_agent;
    child_agent.sub = true;
    child_agent.agent_cwd = child_path;
    child_agent.hard_policy = inherited;
    try std.testing.expect(context.checkAgent(&child_agent, a, "provider.use", "fixture") != null);
    try std.testing.expect(context.checkAgent(&child_agent, a, "plugin.use", "fixture") != null);
    try std.testing.expect(gate.denialAgent(&child_agent, a, .{ .id = "fixture", .name = "ask_user", .input = .null }) != null);
    // A naive cwd-scoped check loses the operator restriction when the
    // isolated tree has no settings. Original ambient-cwd checks instead
    // lose that identity when the root changes workspace (next regression).
    try std.testing.expect(policy.checkAt(io, a, child.dir, "tool.use", "shell") == null);
    const ctx = toolContext(child_path, inherited);
    for ([_][]const u8{ "{}", "{\"policies\":[{\"action\":\"tool.use\",\"resource\":\"*\",\"effect\":\"allow\"},{\"action\":\"provider.use\",\"resource\":\"*\",\"effect\":\"allow\"},{\"action\":\"mcp.use\",\"resource\":\"*\",\"effect\":\"allow\"},{\"action\":\"websearch.use\",\"resource\":\"*\",\"effect\":\"allow\"}]}" }) |local| {
        try save(child.dir, local);
        for ([_][]const u8{ "bash", "shell", "bash_kill", "mcp__fixture__read", "ask_user" }) |name| {
            const blocked = gate.exec(ctx, .{ .id = "fixture", .name = name, .input = .null }).?;
            defer std.testing.allocator.free(blocked.text);
            try std.testing.expect(blocked.is_error);
        }
        const doc = context.load(io, a, child_path, inherited);
        for ([_][]const u8{ "provider.use", "mcp.use", "plugin.use", "websearch.use", "skill.use" }) |action| {
            try std.testing.expect(doc.denial(a, action, "fixture") != null);
        }
        const wire = "[{\"type\":\"function\",\"name\":\"bash\"},{\"type\":\"function\",\"name\":\"ask_user\"},{\"type\":\"function\",\"name\":\"mcp__fixture__read\"},{\"type\":\"web_search\"},{\"name\":\"read_file\"}]";
        try std.testing.expectEqualStrings("[{\"name\":\"read_file\"}]", try @import("hard_policy_catalog.zig").filterDocument(doc, a, wire, "fixture", null));
        // No HTTP client is needed: inherited provider denial precedes dispatch.
        const skill_input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"name\":\"fixture\"}", .{});
        const skill = try @import("skill_policy.zig").exec(ctx.gpa, io, skill_input, ctx.agent_cwd, ctx.hard_policy);
        defer std.testing.allocator.free(skill.text);
        try std.testing.expect(skill.is_error);
        try std.testing.expect(std.mem.indexOf(u8, skill.text, "skill.use") != null);
        const query = @import("rlm_query.zig").run(ctx, "{\"prompt\":\"fixture\"}");
        defer std.testing.allocator.free(query.text);
        try std.testing.expect(query.is_error);
        try std.testing.expect(std.mem.indexOf(u8, query.text, "provider.use") != null);
    }
}

test "hard policy root workspace switches and edits do not replace live child snapshots" {
    var first = std.testing.tmpDir(.{});
    defer first.cleanup();
    var second = std.testing.tmpDir(.{});
    defer second.cleanup();
    var child = std.testing.tmpDir(.{});
    defer child.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first_path = try first.dir.realPathFileAlloc(io, ".", a);
    const second_path = try second.dir.realPathFileAlloc(io, ".", a);
    const child_path = try child.dir.realPathFileAlloc(io, ".", a);
    try save(first.dir, restrictions);
    try std.testing.expect(policy.checkAt(io, a, first.dir, "tool.use", "shell") != null);
    // The pre-fix ambient check follows the new root directory and allows
    // this operation. A live worker must retain its original ceiling.
    try std.testing.expect(policy.checkAt(io, a, second.dir, "tool.use", "shell") == null);
    const old_child = context.capture(io, a, first_path, null);
    const other_child = context.capture(io, a, second_path, null);
    const Worker = struct {
        fn run(path: []const u8, inherited: *const policy.Document, denied: bool, wrong: *std.atomic.Value(u32)) void {
            var local = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer local.deinit();
            for (0..32) |_| {
                const actual = context.check(io, local.allocator(), path, inherited, "tool.use", "shell") != null;
                if (actual != denied) _ = wrong.fetchAdd(1, .monotonic);
            }
        }
    };
    var wrong: std.atomic.Value(u32) = .init(0);
    var children: std.Io.Group = .init;
    defer children.cancel(io);
    try children.concurrent(io, Worker.run, .{ child_path, old_child, true, &wrong });
    try children.concurrent(io, Worker.run, .{ child_path, other_child, false, &wrong });
    try children.await(io);
    try std.testing.expectEqual(@as(u32, 0), wrong.load(.acquire));
    try save(first.dir, "{}");
    try std.testing.expect(context.check(io, a, first_path, null, "tool.use", "shell") == null);
    try std.testing.expect(context.check(io, a, second_path, null, "tool.use", "shell") == null);
    try std.testing.expect(context.check(io, a, child_path, old_child, "tool.use", "shell") != null);
    try std.testing.expect(context.check(io, a, child_path, other_child, "tool.use", "shell") == null);
    const new_child = context.capture(io, a, first_path, null);
    try std.testing.expect(context.check(io, a, child_path, new_child, "tool.use", "shell") == null);
    // Grandchildren retain intermediate restrictions, not just the root.
    try save(child.dir, "{\"policies\":[{\"action\":\"tool.use\",\"resource\":\"read_file\",\"effect\":\"deny\"}]}");
    const grandchild = context.capture(io, a, child_path, old_child);
    try std.testing.expect(context.check(io, a, second_path, grandchild, "tool.use", "read_file") != null);
    try std.testing.expect(context.check(io, a, second_path, grandchild, "tool.use", "shell") != null);
}

test "hard policy detached snapshots own policy bytes after spawning arena teardown" {
    var owned = @import("subagent_owned.zig").Owned.init(std.testing.allocator);
    defer owned.deinit();
    var copy: tools.ToolCtx = undefined;
    {
        var source_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer source_arena.deinit();
        const a = source_arena.allocator();
        const doc = try a.create(policy.Document);
        doc.* = policy.parse(a, restrictions);
        const layered = try a.create(policy.Document);
        layered.* = policy.parse(a, "{\"policies\":[{\"action\":\"tool.use\",\"resource\":\"*\",\"effect\":\"allow\"}]}");
        layered.ceiling = doc;
        copy = try owned.context(toolContext(".", layered));
        try std.testing.expect(copy.hard_policy.? != layered);
        try std.testing.expect(copy.hard_policy.?.ceiling.? != doc);
    }
    try std.testing.expect(copy.hard_policy.?.denial(owned.arena.allocator(), "tool.use", "shell") != null);
    try std.testing.expect(copy.hard_policy.?.denial(owned.arena.allocator(), "provider.use", "fixture") != null);
}
