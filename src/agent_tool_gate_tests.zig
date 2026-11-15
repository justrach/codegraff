const std = @import("std");
const main_mod = @import("main.zig");
const shell_tool = @import("shell_tool.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const tools_mod = @import("tools.zig");
const ToolCall = tools_mod.ToolCall;
const Approvals = @import("approvals.zig").Approvals;
const learning_privacy = @import("learning_privacy.zig");
const presence = @import("presence.zig");
const gate = @import("agent_tool_gate.zig");

const firstWord = gate.firstWord;
const gateSmolifySecrets = gate.gateSmolifySecrets;
const gateHarnessPolicyWrite = gate.gateHarnessPolicyWrite;
const collectPrivateTemplates = gate.collectPrivateTemplates;

test "firstWord splits the command on the first whitespace" {
    try std.testing.expectEqualStrings("git", firstWord("git status -s"));
    try std.testing.expectEqualStrings("ls", firstWord("ls"));
    try std.testing.expectEqualStrings("cat", firstWord("cat\tfile"));
    try std.testing.expectEqualStrings("", firstWord(""));
    try std.testing.expectEqualStrings("", firstWord(" leading"));
}

test "Smolify arguments containing recognizable secrets fail closed locally" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const secret = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"query\":\"github_token=ghp_not-for-egress\"}", .{});
    const public = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"query\":\"Zig HTTP client\"}", .{});
    const blocked = (try gateSmolifySecrets(arena, .{ .id = "1", .name = "mcp__smolify__search_docs", .input = secret })).?;
    try std.testing.expect(blocked.is_error);
    try std.testing.expect(std.mem.indexOf(u8, blocked.text, "blocked locally") != null);
    try std.testing.expect((try gateSmolifySecrets(arena, .{ .id = "2", .name = "mcp__smolify__search_docs", .input = public })) == null);
    try std.testing.expect((try gateSmolifySecrets(arena, .{ .id = "3", .name = "read_file", .input = secret })) == null);
}

test "gateHarnessPolicyWrite: the model never edits the harness's own policy file (#366)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent: Agent = undefined;
    agent.arena = arena;
    const settings = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\".harness/settings.json\",\"content\":\"{}\"}", .{});
    const nested = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"../other/.harness/settings.json\",\"content\":\"{}\"}", .{});
    const normal = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\"src/main.zig\",\"content\":\"x\"}", .{});
    const git_hook = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\".git/hooks/pre-commit\",\"content\":\"x\"}", .{});
    const gitignore = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"path\":\".gitignore\",\"content\":\"x\"}", .{});
    const direct = (try gateHarnessPolicyWrite(&agent, .{ .id = "1", .name = "write_file", .input = settings })).?;
    try std.testing.expect(direct.is_error);
    try std.testing.expect(std.mem.indexOf(u8, direct.text, "policy file") != null);
    try std.testing.expect((try gateHarnessPolicyWrite(&agent, .{ .id = "2", .name = "edit_file", .input = nested })) != null);
    try std.testing.expect((try gateHarnessPolicyWrite(&agent, .{ .id = "5", .name = "write_file", .input = git_hook })) != null);
    try std.testing.expect((try gateHarnessPolicyWrite(&agent, .{ .id = "3", .name = "write_file", .input = normal })) == null);
    try std.testing.expect((try gateHarnessPolicyWrite(&agent, .{ .id = "6", .name = "write_file", .input = gitignore })) == null);
    try std.testing.expect((try gateHarnessPolicyWrite(&agent, .{ .id = "4", .name = "bash", .input = settings })) == null);
}

test "private template collector covers subagents and workflow stages" {
    const io = std.testing.io;
    learning_privacy.setMode(io, .templates);
    defer learning_privacy.setMode(io, .local);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sub_value = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"system_prompt\":\"private one\",\"prompt\":\"task\"}", .{});
    const sub = collectPrivateTemplates(io, .{ .id = "1", .name = "subagent", .input = sub_value });
    try std.testing.expectEqual(@as(usize, 1), sub.len);
    const wf_value = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"phases\":[{\"tasks\":[{\"system_prompt\":\"phase private\",\"prompt\":\"x\"}]}],\"pipeline\":{\"stages\":[{\"system_prompt\":\"stage private\",\"prompt\":\"y\"}]}}", .{});
    const wf = collectPrivateTemplates(io, .{ .id = "2", .name = "workflow", .input = wf_value });
    try std.testing.expectEqual(@as(usize, 2), wf.len);
}

test "#851 bash gate resolves the git target before gateCheck" {
    const src = @embedFile("agent_tool_gate.zig");
    const applies = std.mem.indexOf(u8, src, "sharedTreeGateApplies").?;
    const check = std.mem.indexOfPos(u8, src, applies, "gateCheck(").?;
    try std.testing.expect(applies < check);
}

test "#851 isolated git -C target does not use the caller worktree identity" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const path_a = try std.fmt.allocPrint(a, "{s}/a", .{root});
    const path_b = try std.fmt.allocPrint(a, "{s}/b", .{root});
    try tmp.dir.createDirPath(std.testing.io, "a");
    try tmp.dir.createDirPath(std.testing.io, "b");
    const runner = @import("process_runner.zig");
    for ([_][]const u8{ path_a, path_b }) |p| {
        const r = try runner.runCapped(gpa, std.testing.io, &.{ "git", "init", "-q", p }, 4096, 4096, 15_000);
        defer {
            gpa.free(r.stdout);
            gpa.free(r.stderr);
        }
        try std.testing.expect(runner.ranOk(r));
    }
    const worktree_lease = @import("worktree_lease.zig");
    const id_a = worktree_lease.identityAt(gpa, std.testing.io, a, path_a);
    try std.testing.expect(id_a.id.len > 0);
    presence.bindForTest(root, id_a.id, "s-caller", .{});
    defer presence.unbindForTest();
    const cmd_b = try std.fmt.allocPrint(a, "git -C {s} cherry-pick abc", .{path_b});
    const cmd_a = try std.fmt.allocPrint(a, "git -C {s} cherry-pick abc", .{path_a});
    const cmd_sub = try std.fmt.allocPrint(a, "cd {s}/. && git stash", .{path_a});
    try std.testing.expect(!presence.sharedTreeGateApplies(gpa, std.testing.io, a, cmd_b));
    try std.testing.expect(presence.sharedTreeGateApplies(gpa, std.testing.io, a, cmd_a));
    try std.testing.expect(presence.sharedTreeGateApplies(gpa, std.testing.io, a, cmd_sub));
    try std.testing.expect(presence.sharedTreeGateApplies(gpa, std.testing.io, a, "git cherry-pick abc"));
}

test "plan frontend allow once reaches actual dispatch without a reusable grant" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "proof.txt", .data = "approved read proof" });
    const path = try tmp.dir.realPathFileAlloc(io, "proof.txt", arena.allocator());
    const command = try std.fmt.allocPrint(arena.allocator(), "cat {s}", .{path});
    try std.testing.expect(Approvals.readOnlyExternal(command));
    const Fixture = struct {
        calls: usize = 0,
        fn ask(ptr: *anyopaque, _: std.Io, _: @import("engine_permission.zig").Request) @import("engine_permission.zig").Decision {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            return .allow_once;
        }
    };
    var fixture: Fixture = .{};
    var approvals: Approvals = .{};
    const saved_plan = main_mod.plan_mode;
    defer main_mod.plan_mode = saved_plan;
    main_mod.plan_mode = true;
    var agent: Agent = .{ .gpa = gpa, .arena = arena.allocator(), .io = io, .client = undefined, .provider = .{ .id = "fixture", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "fixture", .context = 1000 }, .messages = .init(arena.allocator()), .sub = false, .label = "root", .out = null, .approvals = &approvals, .permission = .{ .ctx = &fixture, .request = Fixture.ask } };
    defer agent.tools_used.deinit(gpa);
    var args: std.json.ObjectMap = .empty;
    try args.put(arena.allocator(), "command", .{ .string = command });
    const call: ToolCall = .{ .id = "one-read", .name = "bash", .input = .{ .object = args } };
    const results = try agent.runTools(&.{call});
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(!results[0].is_error);
    try std.testing.expect(std.mem.indexOf(u8, results[0].text, "approved read proof") != null);
    try std.testing.expect(!approvals.planReadAllowed(io, command));
    const ctx: tools_mod.ToolCtx = .{ .gpa = gpa, .io = io, .client = undefined, .provider = agent.provider, .registry = null, .from_sub = false, .approvals = &approvals, .tracer = null, .plan_read_owner = &agent };
    const repeated = @import("exec.zig").execTool(ctx, call);
    defer gpa.free(repeated.text);
    try std.testing.expect(repeated.is_error);
    try std.testing.expect(std.mem.indexOf(u8, repeated.text, "plan mode") != null);
    try approvals.approvePlanReadOnce(io, arena.allocator(), &agent, call.id, command);
    _ = try agent.runTools(&.{});
    try std.testing.expect(!approvals.consumePlanReadOnce(io, &agent, call.id, command));
}

test "approval gate asks for shell commands under the advertised name and the bash alias (#1292)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const Fixture = struct {
        calls: usize = 0,
        fn ask(ptr: *anyopaque, _: std.Io, _: @import("engine_permission.zig").Request) @import("engine_permission.zig").Decision {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            return .deny;
        }
    };
    for ([_][]const u8{ shell_tool.tool_name, "bash" }) |name| {
        var fixture: Fixture = .{};
        var approvals: Approvals = .{};
        var agent: Agent = .{ .gpa = gpa, .arena = arena.allocator(), .io = io, .client = undefined, .provider = .{ .id = "fixture", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "fixture", .context = 1000 }, .messages = .init(arena.allocator()), .sub = false, .label = "root", .out = null, .approvals = &approvals, .permission = .{ .ctx = &fixture, .request = Fixture.ask } };
        defer agent.tools_used.deinit(gpa);
        var args: std.json.ObjectMap = .empty;
        try args.put(arena.allocator(), "command", .{ .string = "curl -X POST https://example.invalid/upload -d @nothing.txt" });
        const results = try agent.runTools(&.{.{ .id = "gate", .name = name, .input = .{ .object = args } }});
        try std.testing.expectEqual(@as(usize, 1), fixture.calls);
        try std.testing.expect(results[0].is_error);
        try std.testing.expect(std.mem.indexOf(u8, results[0].text, "declined") != null);
    }
}
