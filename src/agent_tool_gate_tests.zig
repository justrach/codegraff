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
const mcp = @import("mcp.zig");
const plan_read_cmd = @import("plan_read_cmd.zig");
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

test "plan_mode allows stdout pdftotext, quoted rg alternation, read-only gh, and external approvals (#1906, #1908)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expect(plan_read_cmd.inCwdAllowed("pdftotext lecture.pdf - | head -n 40"));
    try std.testing.expect(plan_read_cmd.inCwdAllowed("rg 'foo|bar' src"));
    try std.testing.expect(plan_read_cmd.inCwdAllowed("gh issue list --limit 5"));
    try std.testing.expect(!plan_read_cmd.inCwdAllowed("pdftotext lecture.pdf"));
    try std.testing.expect(!plan_read_cmd.inCwdAllowed("pdftotext lecture.pdf out.txt"));
    try std.testing.expect(!plan_read_cmd.inCwdAllowed("gh issue create --title x"));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "ext dir");
    try tmp.dir.writeFile(io, .{ .sub_path = "ext dir/doc.pdf", .data = "%PDF-1.4\n" });
    const ext_path = try tmp.dir.realPathFileAlloc(io, "ext dir/doc.pdf", a);
    const ext_cmd = try std.fmt.allocPrint(a, "pdftotext \"{s}\" -", .{ext_path});
    try std.testing.expect(!plan_read_cmd.inCwdAllowed(ext_cmd));
    try std.testing.expect(plan_read_cmd.externalAllowed(ext_cmd));

    const Fixture = struct {
        calls: usize = 0,
        decision: @import("engine_permission.zig").Decision = .allow_once,
        fn ask(ptr: *anyopaque, _: std.Io, _: @import("engine_permission.zig").Request) @import("engine_permission.zig").Decision {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            return self.decision;
        }
    };
    var fixture: Fixture = .{};
    var approvals: Approvals = .{};
    defer {
        for (approvals.plan_read_roots.items) |r| gpa.free(r);
        approvals.plan_read_roots.deinit(gpa);
        for (approvals.prefixes.items) |p| gpa.free(p);
        approvals.prefixes.deinit(gpa);
    }
    const saved_plan = main_mod.plan_mode;
    defer main_mod.plan_mode = saved_plan;
    main_mod.plan_mode = true;

    var agent: Agent = .{ .gpa = gpa, .arena = a, .io = io, .client = undefined, .provider = .{ .id = "fixture", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "fixture", .context = 1000 }, .messages = .init(a), .sub = false, .label = "root", .out = null, .approvals = &approvals, .permission = .{ .ctx = &fixture, .request = Fixture.ask } };
    defer agent.tools_used.deinit(gpa);

    // Allowed in-cwd commands need no prompt even when not in plain simple allowlist.
    for ([_][]const u8{ "pdftotext lecture.pdf - | head -n 40", "rg 'foo|bar' src", "gh issue list --limit 5" }) |cmd| {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(a, "command", .{ .string = cmd });
        try std.testing.expect((try gate.gateTool(&agent, .{ .id = "in1", .name = "bash", .input = .{ .object = obj } })) == null);
    }
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expect(approvals.allowed(io, "pdftotext lecture.pdf -"));
    try std.testing.expect(!approvals.allowed(io, "pdftotext lecture.pdf"));

    // File-writing pdftotext and mutating gh stay denied in plan_mode.
    for ([_][]const u8{ "pdftotext lecture.pdf out.txt", "gh issue create --title x" }) |cmd| {
        var obj: std.json.ObjectMap = .empty;
        try obj.put(a, "command", .{ .string = cmd });
        const denied = (try gate.gateTool(&agent, .{ .id = "d1", .name = "bash", .input = .{ .object = obj } })).?;
        try std.testing.expect(denied.is_error);
        try std.testing.expect(std.mem.indexOf(u8, denied.text, "read-only") != null);
    }

    // External pdftotext prompts for permission once, then sticky approvePlanRead skips prompting.
    var ext_obj: std.json.ObjectMap = .empty;
    try ext_obj.put(a, "command", .{ .string = ext_cmd });
    const ext_call: ToolCall = .{ .id = "ext1", .name = "bash", .input = .{ .object = ext_obj } };
    try std.testing.expect((try gate.gateTool(&agent, ext_call)) == null);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(approvals.consumePlanReadOnce(io, &agent, ext_call.id, ext_cmd));
    try approvals.approvePlanRead(io, gpa, ext_cmd);
    try std.testing.expect((try gate.gateTool(&agent, ext_call)) == null);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
}

test "plan_mode permits declared read_only MCP tools with normal consent and blocks non-read-only MCP tools (#1908)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var reg: mcp.Registry = .{ .gpa = gpa, .io = io, .home = "", .arena_state = .init(gpa) };
    defer reg.arena_state.deinit();
    const ro_tools = try a.alloc(mcp.Tool, 2);
    ro_tools[0] = .{ .server_index = 0, .original_name = "read_info", .qualified_name = "mcp__srv__read_info", .description = "", .input_schema = .{ .object = .empty }, .read_only = true };
    ro_tools[1] = .{ .server_index = 0, .original_name = "mutate_state", .qualified_name = "mcp__srv__mutate_state", .description = "", .input_schema = .{ .object = .empty }, .read_only = false };
    reg.tools = ro_tools;

    const Fixture = struct {
        calls: usize = 0,
        decision: @import("engine_permission.zig").Decision = .deny,
        fn ask(ptr: *anyopaque, _: std.Io, _: @import("engine_permission.zig").Request) @import("engine_permission.zig").Decision {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            return self.decision;
        }
    };
    var fixture: Fixture = .{};
    var approvals: Approvals = .{};
    const saved_plan = main_mod.plan_mode;
    defer main_mod.plan_mode = saved_plan;
    main_mod.plan_mode = true;

    var agent: Agent = .{ .gpa = gpa, .arena = a, .io = io, .client = undefined, .provider = .{ .id = "fixture", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "fixture", .context = 1000 }, .messages = .init(a), .registry = &reg, .sub = false, .label = "root", .out = null, .approvals = &approvals, .permission = .{ .ctx = &fixture, .request = Fixture.ask } };
    defer agent.tools_used.deinit(gpa);

    // Non-read-only MCP tool is blocked by plan_mode without reaching consent prompt.
    const blocked = (try gate.gateTool(&agent, .{ .id = "m-rw", .name = "mcp__srv__mutate_state", .input = .{ .object = .empty } })).?;
    try std.testing.expect(blocked.is_error);
    try std.testing.expect(std.mem.indexOf(u8, blocked.text, "plan mode") != null);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);

    // Declared read_only MCP tool passes plan_mode and reaches user consent, respecting .deny vs .allow_once.
    const declined = (try gate.gateTool(&agent, .{ .id = "m-ro-1", .name = "mcp__srv__read_info", .input = .{ .object = .empty } })).?;
    try std.testing.expect(declined.is_error);
    try std.testing.expect(std.mem.indexOf(u8, declined.text, "declined") != null);
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);

    fixture.decision = .allow_once;
    try std.testing.expect((try gate.gateTool(&agent, .{ .id = "m-ro-2", .name = "mcp__srv__read_info", .input = .{ .object = .empty } })) == null);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);

    // Read-only subagent also allows read_only MCP tools and blocks non-read-only ones.
    agent.sub = true;
    agent.read_only = true;
    try std.testing.expect((try gate.gateTool(&agent, .{ .id = "m-sub-ro", .name = "mcp__srv__read_info", .input = .{ .object = .empty } })) == null);
    const sub_blocked = (try gate.gateTool(&agent, .{ .id = "m-sub-rw", .name = "mcp__srv__mutate_state", .input = .{ .object = .empty } })).?;
    try std.testing.expect(sub_blocked.is_error);
}
