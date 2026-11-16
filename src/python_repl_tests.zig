//! Unit tests for persistent `python_repl`, safety gates, and `--unharnessed` mode.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const Provider = @import("provider.zig").Provider;
const Keys = @import("provider.zig").Keys;
const tools = @import("tools.zig");
const schema = @import("schema.zig");
const no_local_tools = @import("no_local_tools.zig");
const native_fold = @import("native_fold.zig");
const mcp_schema_gate = @import("mcp_schema_gate.zig");
const mcp_select = @import("mcp_select.zig");
const additional_tools = @import("additional_tools.zig");
const exec = @import("exec.zig");
const agent_tool_gate = @import("agent_tool_gate.zig");
const agent_tool_batch = @import("agent_tool_batch.zig");
const agent_eval_control = @import("agent_eval_control.zig");
const tool_balance = @import("tool_balance.zig");
const python_repl = @import("python_repl.zig");
const unharnessed = @import("unharnessed_mode.zig");
const commands_unharnessed = @import("commands_unharnessed.zig");
const acp_unharnessed = @import("acp_unharnessed.zig");
const LiveTurn = @import("acp_live_turn.zig").LiveTurn;
const testAgentFor = @import("agent_request_body_responses.zig").testAgentFor;

fn makeCtx(gpa: Allocator, io: Io, pending: *@import("jev_effort_state.zig").Pending, cwd: ?[]const u8) tools.ToolCtx {
    return .{
        .gpa = gpa,
        .io = io,
        .client = undefined,
        .provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "k", .model = "gpt-6-sol", .context = 200_000 },
        .jev_effort_pending = pending,
        .registry = null,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
        .agent_cwd = cwd,
    };
}

fn requirePython(io: Io, a: Allocator) !void {
    if (builtin.os.tag == .wasi) return error.SkipZigTest;
    if (python_repl.findPython(io, a) == null) return error.SkipZigTest;
}

fn runPy(ctx: tools.ToolCtx, a: Allocator, name: []const u8, payload: []const u8) !tools.ToolOutput {
    const val = try std.json.parseFromSliceLeaky(Value, a, payload, .{});
    return python_repl.execute(ctx, name, val);
}

test "python_repl: persists globals, trailing expression _, resets, and survives errors/sys.exit/SIGALRM" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try requirePython(io, a);
    defer python_repl.stopAll(io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_abs = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var pending: @import("jev_effort_state.zig").Pending = .{};
    const ctx = makeCtx(gpa, io, &pending, root_abs);

    // 1. State + trailing expression repr + `_` binding persist across calls.
    const r1 = try runPy(ctx, a, "python_repl", "{\"code\":\"items = [2, 4, 6]\\nsum(items)\"}");
    defer gpa.free(r1.text);
    try std.testing.expect(!r1.is_error);
    try std.testing.expectEqualStrings("12\n", r1.text);

    const r2 = try runPy(ctx, a, "python_repl", "{\"code\":\"prev_val = _\\ndef doubled():\\n    return prev_val + items[-1]\\ndoubled()\"}");
    defer gpa.free(r2.text);
    try std.testing.expect(!r2.is_error);
    try std.testing.expectEqualStrings("18\n", r2.text);

    // 2. OS-level fd 1/2 output from subprocess without capture_output=True is captured without corrupting framing.
    const r_fd = try runPy(ctx, a, "python_repl", "{\"code\":\"import subprocess, sys\\nsubprocess.run([sys.executable, '-c', 'print(\\\"fd1-ok\\\")'], check=True)\\n'after-fd1'\"}");
    defer gpa.free(r_fd.text);
    try std.testing.expect(!r_fd.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r_fd.text, "fd1-ok\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r_fd.text, "'after-fd1'") != null);

    // 3. Exceptions and SystemExit report is_error while keeping prior globals intact.
    const r_err = try runPy(ctx, a, "python_repl", "{\"code\":\"1 / 0\"}");
    defer gpa.free(r_err.text);
    try std.testing.expect(r_err.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r_err.text, "ZeroDivisionError") != null);

    const r_exit = try runPy(ctx, a, "python_repl", "{\"code\":\"import sys; sys.exit(2)\"}");
    defer gpa.free(r_exit.text);
    try std.testing.expect(r_exit.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r_exit.text, "SystemExit") != null);

    const r_keep = try runPy(ctx, a, "python_repl", "{\"code\":\"items\"}");
    defer gpa.free(r_keep.text);
    try std.testing.expect(!r_keep.is_error);
    try std.testing.expectEqualStrings("[2, 4, 6]\n", r_keep.text);

    // 4. POSIX SIGALRM timeout preserves prior globals.
    if (builtin.os.tag != .windows) {
        const r_to = try runPy(ctx, a, "python_repl", "{\"code\":\"import time; time.sleep(3)\",\"timeout_ms\":1000}");
        defer gpa.free(r_to.text);
        try std.testing.expect(r_to.is_error);
        try std.testing.expect(std.mem.indexOf(u8, r_to.text, "TimeoutError") != null);

        const r_after_to = try runPy(ctx, a, "python_repl", "{\"code\":\"doubled()\"}");
        defer gpa.free(r_after_to.text);
        try std.testing.expect(!r_after_to.is_error);
        try std.testing.expectEqualStrings("18\n", r_after_to.text);
    }

    // 5. Explicit reset clears globals while supporting empty code.
    const r_rst = try runPy(ctx, a, "python_repl", "{\"code\":\"\",\"reset\":true}");
    defer gpa.free(r_rst.text);
    try std.testing.expect(!r_rst.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r_rst.text, "reset") != null);

    const r_gone = try runPy(ctx, a, "python_repl", "{\"code\":\"items\"}");
    defer gpa.free(r_gone.text);
    try std.testing.expect(r_gone.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r_gone.text, "NameError") != null);

    // 6. resetSession stops root worker cleanly.
    const r_reseed = try runPy(ctx, a, "python_repl", "{\"code\":\"x = 42\"}");
    defer gpa.free(r_reseed.text);
    python_repl.resetSession(io);
    const r_recheck = try runPy(ctx, a, "python_repl", "{\"code\":\"x\"}");
    defer gpa.free(r_recheck.text);
    try std.testing.expect(r_recheck.is_error);
}

test "python_repl: workspace switches update cwd while intra-workspace chdir persists" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try requirePython(io, a);
    defer python_repl.stopAll(io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "ws_a/sub");
    try tmp.dir.createDirPath(io, "ws_b");
    var buf_a: [std.fs.max_path_bytes]u8 = undefined;
    var buf_b: [std.fs.max_path_bytes]u8 = undefined;
    const ws_a = buf_a[0..try tmp.dir.realPathFile(io, "ws_a", &buf_a)];
    const ws_b = buf_b[0..try tmp.dir.realPathFile(io, "ws_b", &buf_b)];
    const sub_a = try std.fs.path.join(a, &.{ ws_a, "sub" });

    var pending: @import("jev_effort_state.zig").Pending = .{};
    const ctx_a = makeCtx(gpa, io, &pending, ws_a);
    const r1 = try runPy(ctx_a, a, "python_repl", "{\"code\":\"import os; os.chdir('sub'); os.getcwd()\"}");
    defer gpa.free(r1.text);
    try std.testing.expect(!r1.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r1.text, sub_a) != null);

    // Same workspace_root preserves user's os.chdir('sub').
    const r2 = try runPy(ctx_a, a, "python_repl", "{\"code\":\"os.getcwd()\"}");
    defer gpa.free(r2.text);
    try std.testing.expect(!r2.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r2.text, sub_a) != null);

    // Switching workspace_root updates os.getcwd() automatically.
    const ctx_b = makeCtx(gpa, io, &pending, ws_b);
    const r3 = try runPy(ctx_b, a, "python_repl", "{\"code\":\"os.getcwd()\"}");
    defer gpa.free(r3.text);
    try std.testing.expect(!r3.is_error);
    try std.testing.expect(std.mem.indexOf(u8, r3.text, ws_b) != null);
}

test "python_repl: folded native lifecycle, --no-local-tools, plan_mode, and batch/eval policies" {
    const saved_unh = unharnessed.SavedState.save();
    defer saved_unh.restore();
    const saved_local = no_local_tools.enabled;
    const saved_lean = no_local_tools.lean;
    const saved_fold = native_fold.enabled;
    const saved_plan = main_mod.plan_mode;
    defer {
        no_local_tools.enabled = saved_local;
        no_local_tools.lean = saved_lean;
        native_fold.enabled = saved_fold;
        main_mod.plan_mode = saved_plan;
        native_fold.clearLoadedSession();
        mcp_schema_gate.reset();
    }
    unharnessed.resetForTest();
    no_local_tools.enabled = false;
    no_local_tools.lean = false;
    native_fold.enabled = true;
    main_mod.plan_mode = false;
    native_fold.clearLoadedSession();
    mcp_schema_gate.reset();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expect(native_fold.isFolded("python_repl"));
    try std.testing.expect(native_fold.blocked("python_repl"));
    try std.testing.expect(agent_tool_batch.isSequential("python_repl"));
    try std.testing.expect(agent_tool_batch.isSequential("python"));

    var agent = try testAgentFor(a, "anthropic", .anthropic, "claude-sonnet-5");
    agent.registry = null;
    agent.invalidateRootTools();
    try agent.ensureRootTools(.anthropic);
    try std.testing.expect(std.mem.indexOf(u8, agent.toolsJson(), "\"name\":\"python_repl\"") == null);

    // Deferred listing advertises python_repl and load_tool_schemas loads it cleanly.
    const desc = try mcp_schema_gate.descWithListing(a, &.{});
    try std.testing.expect(std.mem.indexOf(u8, desc, "python_repl") != null);

    const load_in = try std.json.parseFromSliceLeaky(Value, a, "{\"tools\":[\"python_repl\"]}", .{});
    const load_res = mcp_select.loadBoth(&agent, .{ .id = "l1", .name = mcp_schema_gate.tool_name, .input = load_in });
    try std.testing.expect(!load_res.is_error);
    try std.testing.expect(native_fold.isLoaded("python_repl"));
    try std.testing.expect(std.mem.indexOf(u8, agent.toolsJson(), "\"name\":\"python_repl\"") != null);

    const call_py: tools.ToolCall = .{ .id = "c1", .name = "python_repl", .input = try std.json.parseFromSliceLeaky(Value, a, "{\"code\":\"1+1\"}", .{}) };
    try std.testing.expect(agent_eval_control.toolInvalidatesEval(call_py));
    try std.testing.expect(agent_eval_control.batchBlocksCompletion(&.{call_py}));

    // --no-local-tools hides python_repl from folded listing and blocks dispatch for both names.
    no_local_tools.enabled = true;
    unharnessed.g_enabled = true;
    try std.testing.expect(!unharnessed.enabled());
    const remote_desc = try mcp_schema_gate.descWithListing(a, &.{});
    try std.testing.expect(std.mem.indexOf(u8, remote_desc, "python_repl") == null);

    var pending: @import("jev_effort_state.zig").Pending = .{};
    const ctx = makeCtx(std.testing.allocator, std.testing.io, &pending, null);
    for ([_][]const u8{ "python_repl", "python" }) |nm| {
        const out = exec.execTool(ctx, .{ .id = "d1", .name = nm, .input = call_py.input });
        defer if (out.text.len > 0) std.testing.allocator.free(out.text);
        try std.testing.expect(out.is_error);
        try std.testing.expect(std.mem.indexOf(u8, out.text, "--no-local-tools") != null);
    }

    // plan_mode blocks both python_repl and python at gateTool.
    no_local_tools.enabled = false;
    main_mod.plan_mode = true;
    var ap: agent_mod.Approvals = .{ .yolo = true };
    agent.approvals = &ap;
    for ([_][]const u8{ "python_repl", "python" }) |nm| {
        const blocked = (try agent_tool_gate.gateTool(&agent, .{ .id = "p1", .name = nm, .input = call_py.input })).?;
        try std.testing.expect(blocked.is_error);
        try std.testing.expect(std.mem.indexOf(u8, blocked.text, "plan mode") != null);
    }
    _ = tool_balance.reset;
}

test "unharnessed_mode: precedence, single-tool catalog isolation, live toggle, REPL, JSON, and ACP" {
    const saved_unh = unharnessed.SavedState.save();
    defer saved_unh.restore();
    const saved_local = no_local_tools.enabled;
    const saved_stable = mcp_schema_gate.g_stable_catalog;
    defer {
        no_local_tools.enabled = saved_local;
        mcp_schema_gate.g_stable_catalog = saved_stable;
        native_fold.clearLoadedSession();
        mcp_schema_gate.reset();
        python_repl.stopAll(std.testing.io);
    }
    unharnessed.resetForTest();
    no_local_tools.enabled = false;
    mcp_schema_gate.g_stable_catalog = true;
    native_fold.clearLoadedSession();
    mcp_schema_gate.reset();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".harness");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = unharnessed.settings_path,
        .data = "{\"orchestrator\":\"auto\"}\n",
    });
    unharnessed.test_settings_dir = tmp.dir;

    try unharnessed.saveSettingsAt(std.testing.io, tmp.dir, a, true);
    try std.testing.expect(unharnessed.enabled());
    const raw_settings = try tmp.dir.readFileAlloc(std.testing.io, unharnessed.settings_path, a, .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, raw_settings, "\"orchestrator\":\"auto\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw_settings, "\"unharnessed\":true") != null);

    // Precedence: CLI > env > settings.
    unharnessed.g_enabled = false;
    unharnessed.loadSettingsFrom(std.testing.io, tmp.dir, a);
    try std.testing.expect(unharnessed.enabled());
    unharnessed.applyEnv("off");
    unharnessed.loadSettingsFrom(std.testing.io, tmp.dir, a);
    try std.testing.expect(!unharnessed.enabled());
    unharnessed.setFromCli(true);
    unharnessed.applyEnv("off");
    try std.testing.expect(unharnessed.enabled());

    // Single-tool `python` catalog omits all other native/folded/MCP tools and skips additional_tools sync.
    unharnessed.resetForTest();
    unharnessed.test_settings_dir = tmp.dir;
    native_fold.markLoaded("workflow");
    var agent = try testAgentFor(a, "codex", .responses, "gpt-6.1-sol");
    agent.registry = null;
    const normal_prompt = try unharnessed.applyStartupPrompt(std.testing.io, a, "NORMAL-BASE", null, null);
    try std.testing.expectEqualStrings("NORMAL-BASE", normal_prompt);

    try std.testing.expect(try unharnessed.applyLive(&agent, a, true, true));
    try std.testing.expect(std.mem.indexOf(u8, agent.sys_normal, "single-tool Python environment") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent.sys_strict, "STRICT MODE") == null);
    try std.testing.expect(std.mem.indexOf(u8, agent.toolsJson(), "\"name\":\"python\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent.toolsJson(), "\"name\":\"read_file\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, agent.toolsJson(), "\"name\":\"workflow\"") == null);
    const parsed_tools = try std.json.parseFromSliceLeaky(Value, a, agent.toolsJson(), .{});
    try std.testing.expectEqual(@as(usize, 1), parsed_tools.array.items.len);
    const pre_msgs = agent.messages.items.len;
    additional_tools.sync(&agent);
    try std.testing.expectEqual(pre_msgs, agent.messages.items.len);

    // REPL `/unharnessed` and JSON `set_unharnessed` toggle back to normal catalog + prompt.
    var repl_out: Io.Writer.Allocating = .init(a);
    try std.testing.expect(try commands_unharnessed.handle(&agent, a, "/unharnessed off", &repl_out.writer));
    try std.testing.expect(!unharnessed.enabled());
    try std.testing.expect(std.mem.indexOf(u8, repl_out.writer.buffered(), "unharnessed: off") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent.sys_normal, "NORMAL-BASE") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent.toolsJson(), "\"name\":\"read_file\"") != null);

    var json_aw: Io.Writer.Allocating = .init(a);
    agent.out = &json_aw.writer;
    main_mod.json_mode = true;
    defer main_mod.json_mode = false;
    const set_obj = (try std.json.parseFromSliceLeaky(Value, a, "{\"type\":\"set_unharnessed\",\"on\":true}", .{})).object;
    commands_unharnessed.handleJson(&agent, a, set_obj);
    try std.testing.expect(unharnessed.enabled());

    // ACP option & set parity.
    var keys: Keys = .{ .values = @splat(null) };
    var live: LiveTurn = .{ .root = &agent, .keys = &keys, .out = undefined };
    const opt = (try acp_unharnessed.option(&live, a)).?;
    try std.testing.expectEqualStrings("unharnessed", opt.id);
    try std.testing.expectEqualStrings("on", opt.currentValue);
    try std.testing.expect(try acp_unharnessed.set(&live, "off"));
    try std.testing.expect(!unharnessed.enabled());
}
