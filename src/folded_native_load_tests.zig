//! Regression coverage for #492 (original + reopened) and direct-call auto-load
//! catalog synchronization across provider routes and subagents.

const std = @import("std");
const testing = std.testing;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const mcp = @import("mcp.zig");
const mcp_select = @import("mcp_select.zig");
const mcp_schema_gate = @import("mcp_schema_gate.zig");
const native_fold = @import("native_fold.zig");
const additional_tools = @import("additional_tools.zig");
const agent_catalog = @import("agent_catalog.zig");
const worker_mcp = @import("worker_mcp.zig");
const no_local_tools = @import("no_local_tools.zig");
const imagegen = @import("imagegen.zig");
const learn_store = @import("learn_store.zig");
const skill_docs = @import("skill_docs.zig");
const Provider = @import("provider.zig").Provider;
const Agent = @import("agent.zig").Agent;
const testAgentFor = @import("agent_request_body_responses.zig").testAgentFor;
const fixture = @import("mcp_schema_gate_tests.zig").fixture;

const SavedGlobals = struct {
    fold_enabled: bool,
    stable: bool,
    policy: mcp_schema_gate.Policy,
    no_local: bool,
    lean: bool,
    img: bool,
    clock: bool,
    learn: bool,
    ws_skills: bool,

    fn save() SavedGlobals {
        const s: SavedGlobals = .{
            .fold_enabled = native_fold.enabled,
            .stable = mcp_schema_gate.g_stable_catalog,
            .policy = mcp_schema_gate.g_policy,
            .no_local = no_local_tools.enabled,
            .lean = no_local_tools.lean,
            .img = imagegen.available,
            .clock = main_mod.g_clock_sleep,
            .learn = learn_store.active_agent_loaded,
            .ws_skills = skill_docs.g_workspace_skills,
        };
        native_fold.enabled = true;
        mcp_schema_gate.g_stable_catalog = true;
        mcp_schema_gate.g_policy = .{ .enabled = true, .budget = 0, .eager = &.{} };
        no_local_tools.enabled = false;
        no_local_tools.lean = false;
        imagegen.available = false;
        main_mod.g_clock_sleep = false;
        learn_store.active_agent_loaded = false;
        skill_docs.g_workspace_skills = false;
        native_fold.resetRlmDiscovery();
        native_fold.clearLoadedSession();
        mcp_schema_gate.reset();
        return s;
    }

    fn restore(self: SavedGlobals) void {
        native_fold.resetRlmDiscovery();
        native_fold.clearLoadedSession();
        mcp_schema_gate.reset();
        native_fold.enabled = self.fold_enabled;
        mcp_schema_gate.g_stable_catalog = self.stable;
        mcp_schema_gate.g_policy = self.policy;
        no_local_tools.enabled = self.no_local;
        no_local_tools.lean = self.lean;
        imagegen.available = self.img;
        main_mod.g_clock_sleep = self.clock;
        learn_store.active_agent_loaded = self.learn;
        skill_docs.g_workspace_skills = self.ws_skills;
    }
};

fn parseJson(arena: Allocator, raw: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, raw, .{ .allocate = .alloc_always });
}

fn bodyHasTool(arena: Allocator, body: []const u8, want: []const u8) !bool {
    const req = try parseJson(arena, body);
    if (req.object.get("tools")) |tools_v| if (tools_v == .array) {
        for (tools_v.array.items) |item| {
            if (item != .object) continue;
            if (item.object.get("function_declarations")) |decls| if (decls == .array) {
                for (decls.array.items) |d| {
                    if (d == .object) if (d.object.get("name")) |nm| if (nm == .string and std.mem.eql(u8, nm.string, want)) return true;
                }
            };
            const fn_obj = if (item.object.get("function")) |f| (if (f == .object) f.object else continue) else item.object;
            if (fn_obj.get("name")) |nm| if (nm == .string and std.mem.eql(u8, nm.string, want)) return true;
        }
    };
    if (req.object.get("input")) |inp| if (inp == .array) {
        for (inp.array.items) |m| {
            if (additional_tools.isItem(m)) if (m.object.get("tools")) |list| if (list == .array) {
                for (list.array.items) |t| {
                    if (t == .object) if (t.object.get("name")) |nm| if (nm == .string and std.mem.eql(u8, nm.string, want)) return true;
                }
            };
        }
    };
    if (req.object.get("messages")) |msgs| if (msgs == .array) {
        for (msgs.array.items) |m| {
            if (m != .object) continue;
            const c = m.object.get("content") orelse continue;
            if (c == .string and std.mem.indexOf(u8, c.string, "<tools>") != null) {
                const needle = try std.fmt.allocPrint(arena, "\"name\":\"{s}\"", .{want});
                if (std.mem.indexOf(u8, c.string, needle) != null) return true;
            }
        }
    };
    return false;
}

test "#492: folded natives loaded via load_tool_schemas enter the next request across all wires" {
    const saved = SavedGlobals.save();
    defer saved.restore();
    imagegen.available = true;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const Route = struct { id: []const u8, kind: Provider.Kind, model: []const u8, stable: bool = true };
    const routes = [_]Route{
        .{ .id = "anthropic", .kind = .anthropic, .model = "claude-sonnet-5" },
        .{ .id = "zai", .kind = .openai, .model = "glm-5.3" },
        .{ .id = "deepseek", .kind = .openai, .model = "deepseek-v4" },
        .{ .id = "xai", .kind = .responses, .model = "grok-4.6" },
        .{ .id = "chatgpt-new", .kind = .responses, .model = "gpt-6.1-sol" },
        .{ .id = "codex", .kind = .responses, .model = "gpt-5.6-sol", .stable = true },
        .{ .id = "codex", .kind = .responses, .model = "gpt-5.6-sol", .stable = false },
        .{ .id = "gemini", .kind = .interactions, .model = "gemini-3.1-pro-preview" },
    };

    const wanted = [_][]const u8{ "imagegen", "workflow", "subagent", "install_agent_tool", "schedule_task" };
    for (routes) |route| {
        native_fold.clearLoadedSession();
        mcp_schema_gate.g_stable_catalog = route.stable;

        var agent = try testAgentFor(a, route.id, route.kind, route.model);
        agent.registry = null;
        agent.invalidateRootTools();
        try agent.ensureRootTools(route.kind);

        for (wanted) |w| {
            const pre_body = try agent.buildBody(agent.toolsJson(), false, true, true);
            defer testing.allocator.free(pre_body);
            try testing.expect(!try bodyHasTool(a, pre_body, w));
        }

        const input = try parseJson(a, "{\"tools\":[\"imagegen\",\"workflow\",\"subagent\",\"install_agent_tool\",\"schedule_task\"]}");
        const res = mcp_select.loadBoth(&agent, .{ .id = "c1", .name = mcp_schema_gate.tool_name, .input = input });
        try testing.expect(!res.is_error);
        try testing.expect(std.mem.indexOf(u8, res.text, "5 native tool schema(s) below are now loaded and callable") != null);

        additional_tools.sync(&agent);
        const post_body = try agent.buildBody(agent.toolsJson(), false, true, true);
        defer testing.allocator.free(post_body);

        for (wanted) |w| {
            try testing.expect(try bodyHasTool(a, post_body, w));
        }
        // On Codex non-stable mode, unfolded tools enter `tools` directly and must NOT be re-marked defer_loading:true.
        if (std.mem.eql(u8, route.id, "codex") and !route.stable) {
            const parsed = try parseJson(a, post_body);
            for (parsed.object.get("tools").?.array.items) |t| {
                const nm_v = t.object.get("name") orelse continue;
                for (wanted) |w| if (std.mem.eql(u8, nm_v.string, w)) {
                    if (t.object.get("defer_loading")) |df| try testing.expect(df != .bool or !df.bool);
                };
            }
        }
    }
}

test "#492: gated/unavailable natives are never advertised in Folded native or claimed callable" {
    const saved = SavedGlobals.save();
    defer saved.restore();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Default session: imagegen, clock_sleep, learn_candidate are all gated off.
    const desc = try mcp_schema_gate.descWithListing(a, &.{});
    try testing.expect(std.mem.indexOf(u8, desc, "Folded native:") != null);
    try testing.expect(std.mem.indexOf(u8, desc, "workflow") != null);
    try testing.expect(std.mem.indexOf(u8, desc, "imagegen") == null);
    try testing.expect(std.mem.indexOf(u8, desc, "clock_sleep") == null);
    try testing.expect(std.mem.indexOf(u8, desc, "learn_candidate") == null);

    // Under --no-local-tools: host-touching folded tools drop out even if imagegen is otherwise available.
    imagegen.available = true;
    no_local_tools.enabled = true;
    const remote_desc = try mcp_schema_gate.descWithListing(a, &.{});
    for ([_][]const u8{ "read_tool_result", "render_html", "imagegen", "install_agent_tool", "schedule_task" }) |gated| {
        try testing.expect(std.mem.indexOf(u8, remote_desc, gated) == null);
    }
    for ([_][]const u8{ "webfetch", "subagent", "workflow", "todo_write" }) |kept| {
        try testing.expect(std.mem.indexOf(u8, remote_desc, kept) != null);
    }
    no_local_tools.enabled = false;
    imagegen.available = false;

    var agent = try testAgentFor(a, "anthropic", .anthropic, "claude-sonnet-5");
    agent.registry = null;
    agent.invalidateRootTools();
    try agent.ensureRootTools(.anthropic);

    // Asking solely for gated `imagegen` must error and NEVER claim "loaded and callable".
    const only_gated = try parseJson(a, "{\"tools\":[\"imagegen\"]}");
    const r_err = mcp_select.loadBoth(&agent, .{ .id = "c2", .name = mcp_schema_gate.tool_name, .input = only_gated });
    try testing.expect(r_err.is_error);
    try testing.expect(std.mem.indexOf(u8, r_err.text, "loaded and callable") == null);
    try testing.expect(std.mem.indexOf(u8, r_err.text, "unavailable in this session") != null);
    try testing.expect(!native_fold.isLoaded("imagegen"));

    // Mixed gated + loadable (`imagegen`, `workflow`, `subagent`): only 2 are callable; `imagegen` is reported unavailable.
    const mixed_gated = try parseJson(a, "{\"tools\":[\"imagegen\",\"workflow\",\"subagent\"]}");
    const r_mix = mcp_select.loadBoth(&agent, .{ .id = "c3", .name = mcp_schema_gate.tool_name, .input = mixed_gated });
    try testing.expect(!r_mix.is_error);
    try testing.expect(std.mem.indexOf(u8, r_mix.text, "2 native tool schema(s) below are now loaded and callable") != null);
    try testing.expect(std.mem.indexOf(u8, r_mix.text, "Unavailable native tool(s)") != null);
    try testing.expect(std.mem.indexOf(u8, r_mix.text, "imagegen:") != null);
    try testing.expect(!native_fold.isLoaded("imagegen"));
    try testing.expect(native_fold.isLoaded("workflow"));
    try testing.expect(native_fold.isLoaded("subagent"));

    // `--lean`: folded root tools (`workflow`, `todo_write`) load, while `install_agent_tool` stays unavailable.
    native_fold.clearLoadedSession();
    no_local_tools.lean = true;
    agent.invalidateRootTools();
    try agent.ensureRootTools(.anthropic);
    const lean_in = try parseJson(a, "{\"tools\":[\"workflow\",\"todo_write\",\"install_agent_tool\"]}");
    const r_lean = mcp_select.loadBoth(&agent, .{ .id = "c4", .name = mcp_schema_gate.tool_name, .input = lean_in });
    try testing.expect(!r_lean.is_error);
    try testing.expect(std.mem.indexOf(u8, r_lean.text, "2 native tool schema(s) below are now loaded and callable") != null);
    try testing.expect(std.mem.indexOf(u8, agent.toolsJson(), "\"name\":\"workflow\"") != null);
    try testing.expect(std.mem.indexOf(u8, agent.toolsJson(), "\"name\":\"todo_write\"") != null);
    try testing.expect(std.mem.indexOf(u8, agent.toolsJson(), "\"name\":\"install_agent_tool\"") == null);
}

test "#492 reopened: skill, todo_write, core tools, and GRAFF_NO_NATIVE_FOLD never fall through to MCP unknown" {
    const saved = SavedGlobals.save();
    defer saved.restore();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var registry = mcp.Registry.empty(testing.allocator, testing.io);
    defer registry.deinit();
    const fat = try fixture(a, "fat", 2, 1000);
    registry.tools = fat;

    var agent = try testAgentFor(a, "anthropic", .anthropic, "claude-sonnet-5");
    agent.registry = &registry;

    // Workspace with skills (`skill` is eager in root catalog; `todo_write` is folded).
    skill_docs.g_workspace_skills = true;
    agent.invalidateRootTools();
    try agent.ensureRootTools(.anthropic);
    try testing.expect(std.mem.indexOf(u8, agent.toolsJson(), "\"name\":\"skill\"") != null);
    try testing.expect(std.mem.indexOf(u8, agent.toolsJson(), "\"name\":\"todo_write\"") == null);

    const req = try parseJson(a, "{\"tools\":[\"skill\",\"todo_write\"]}");
    const first = mcp_select.loadBoth(&agent, .{ .id = "r1", .name = mcp_schema_gate.tool_name, .input = req });
    try testing.expect(!first.is_error);
    try testing.expect(std.mem.indexOf(u8, first.text, "no deferred MCP tool") == null);
    try testing.expect(std.mem.indexOf(u8, first.text, "2 native tool schema(s) below are now loaded and callable") != null);
    try testing.expect(std.mem.indexOf(u8, first.text, "(1 newly enabled)") != null);
    try testing.expect(std.mem.indexOf(u8, agent.toolsJson(), "\"name\":\"todo_write\"") != null);

    // Repeat call when both are already active/loaded: returns schemas, 0 newly enabled, no MCP error.
    const second = mcp_select.loadBoth(&agent, .{ .id = "r2", .name = mcp_schema_gate.tool_name, .input = req });
    try testing.expect(!second.is_error);
    try testing.expect(std.mem.indexOf(u8, second.text, "no deferred MCP tool") == null);
    try testing.expect(std.mem.indexOf(u8, second.text, "already active and callable") != null);
    try testing.expect(std.mem.indexOf(u8, second.text, "todo_write: {") != null);
    try testing.expect(std.mem.indexOf(u8, second.text, "skill: {") != null);

    // GRAFF_NO_NATIVE_FOLD (`native_fold.enabled = false`): still resolves native tools cleanly!
    native_fold.clearLoadedSession();
    native_fold.enabled = false;
    agent.invalidateRootTools();
    try agent.ensureRootTools(.anthropic);
    const nofold = mcp_select.loadBoth(&agent, .{ .id = "r3", .name = mcp_schema_gate.tool_name, .input = req });
    try testing.expect(!nofold.is_error);
    try testing.expect(std.mem.indexOf(u8, nofold.text, "no deferred MCP tool") == null);
    try testing.expect(std.mem.indexOf(u8, nofold.text, "already active and callable") != null);

    // Core eager tools (`read_file`, `bash` alias), `mcp__graff__*`, and `mcp_select_tool` (`name`).
    native_fold.enabled = true;
    const aliases = try parseJson(a, "{\"tools\":[\"read_file\",\"bash\",\"mcp__graff__workflow\"]}");
    const r_alias = mcp_select.loadBoth(&agent, .{ .id = "r4", .name = mcp_schema_gate.tool_name, .input = aliases });
    try testing.expect(!r_alias.is_error);
    try testing.expect(std.mem.indexOf(u8, r_alias.text, "no deferred MCP tool") == null);
    try testing.expect(native_fold.isLoaded("workflow"));

    const sel = try parseJson(a, "{\"name\":\"skill\"}");
    const r_sel = mcp_select.loadBoth(&agent, .{ .id = "r5", .name = mcp_select.select_name, .input = sel });
    try testing.expect(!r_sel.is_error);
    try testing.expect(std.mem.indexOf(u8, r_sel.text, "no deferred MCP tool") == null);
}

test "#492: mixed native+MCP loads, queries, and registry == null native operations" {
    const saved = SavedGlobals.save();
    defer saved.restore();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // 1. `registry == null` for tools, query, `{}` listing, and unknown names.
    var solo = try testAgentFor(a, "xai", .responses, "grok-4.6");
    solo.registry = null;
    solo.invalidateRootTools();
    try solo.ensureRootTools(.responses);

    const list_res = mcp_select.loadBoth(&solo, .{ .id = "n1", .name = mcp_schema_gate.tool_name, .input = try parseJson(a, "{}") });
    try testing.expect(!list_res.is_error);
    try testing.expect(std.mem.indexOf(u8, list_res.text, "native tool(s) are deferred") != null);

    const q_res = mcp_select.loadBoth(&solo, .{ .id = "n2", .name = mcp_schema_gate.tool_name, .input = try parseJson(a, "{\"query\":\"workflow\"}") });
    try testing.expect(!q_res.is_error);
    try testing.expect(native_fold.isLoaded("workflow"));
    try testing.expect(std.mem.indexOf(u8, solo.toolsJson(), "\"name\":\"workflow\"") != null);
    try testing.expect(std.mem.indexOf(u8, q_res.text, "no MCP servers are connected") == null);

    const unk_res = mcp_select.loadBoth(&solo, .{ .id = "n3", .name = mcp_schema_gate.tool_name, .input = try parseJson(a, "{\"tools\":[\"bogus_tool_xyz\"]}") });
    try testing.expect(unk_res.is_error);
    try testing.expect(std.mem.indexOf(u8, unk_res.text, "bogus_tool_xyz") != null);

    // 2. Mixed native + MCP loads and native-only query when `registry != null`.
    native_fold.clearLoadedSession();
    var registry = mcp.Registry.empty(testing.allocator, testing.io);
    defer registry.deinit();
    const fat = try fixture(a, "fat", 2, 1000);
    registry.tools = fat;

    var both = try testAgentFor(a, "anthropic", .anthropic, "claude-sonnet-5");
    both.registry = &registry;
    both.invalidateRootTools();
    try both.ensureRootTools(.anthropic);

    const mix_in = try parseJson(a, "{\"tools\":[\"read_file\",\"subagent\",\"mcp__fat__t0\"]}");
    const mix_res = mcp_select.loadBoth(&both, .{ .id = "m1", .name = mcp_schema_gate.tool_name, .input = mix_in });
    try testing.expect(!mix_res.is_error);
    try testing.expect(std.mem.indexOf(u8, mix_res.text, "no deferred MCP tool") == null);
    try testing.expect(native_fold.isLoaded("subagent"));
    try testing.expect(mcp_schema_gate.isLoaded("mcp__fat__t0"));
    try testing.expect(std.mem.indexOf(u8, both.toolsJson(), "\"name\":\"subagent\"") != null);
    try testing.expect(std.mem.indexOf(u8, both.toolsJson(), "\"name\":\"mcp__fat__t0\"") != null);

    // Native query hit when MCP has 0 matches must NOT append MCP's "no deferred tool matched query" error.
    const q_nat = mcp_select.loadBoth(&both, .{ .id = "m2", .name = mcp_schema_gate.tool_name, .input = try parseJson(a, "{\"query\":\"webfetch\"}") });
    try testing.expect(!q_nat.is_error);
    try testing.expect(native_fold.isLoaded("webfetch"));
    try testing.expect(std.mem.indexOf(u8, q_nat.text, "no deferred tool matched query") == null);
}

test "#492: direct-call auto-loads sync stale catalogs on non-additional_tools providers and subagents" {
    const saved = SavedGlobals.save();
    defer saved.restore();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var registry = mcp.Registry.empty(testing.allocator, testing.io);
    defer registry.deinit();
    const fat = try fixture(a, "wiki", 2, 500);
    registry.tools = fat;

    // 1. Root agent on non-additional_tools route (`anthropic`): gateExec + autoLoad mark catalog stale and syncLoadedTools rebuilds.
    var root_agent = try testAgentFor(a, "anthropic", .anthropic, "claude-sonnet-5");
    root_agent.registry = &registry;
    root_agent.invalidateRootTools();
    try root_agent.ensureRootTools(.anthropic);
    try testing.expect(!try agent_catalog.syncLoadedTools(&root_agent, false));

    _ = native_fold.gateExec(testing.allocator, "peer_message", false);
    try testing.expect(additional_tools.staleCatalog(&root_agent));
    try testing.expect(try agent_catalog.syncLoadedTools(&root_agent, false));
    try testing.expect(std.mem.indexOf(u8, root_agent.toolsJson(), "\"name\":\"peer_message\"") != null);
    try testing.expect(!additional_tools.staleCatalog(&root_agent));

    // 2. Subagent (`sub = true`): autoLoad on root's registry refreshes worker_tools idempotently without duplicating entries.
    var child: Agent = .{
        .gpa = testing.allocator,
        .arena = a,
        .io = testing.io,
        .client = undefined,
        .provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .bearer, .url = "", .api_key = "k", .model = "claude-sonnet-5", .context = 200_000 },
        .messages = undefined,
        .sub = true,
        .label = "child",
        .out = null,
        .registry = &registry,
    };
    worker_mcp.inherit(&child);
    try testing.expect(std.mem.indexOf(u8, child.toolsJson(), "mcp__wiki__t0") == null);

    mcp_schema_gate.autoLoad(a, fat, fat[0].qualified_name);
    try testing.expect(try agent_catalog.syncLoadedTools(&child, false));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, child.toolsJson(), "\"name\":\"mcp__wiki__t0\""));

    mcp_schema_gate.autoLoad(a, fat, fat[1].qualified_name);
    try testing.expect(try agent_catalog.syncLoadedTools(&child, false));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, child.toolsJson(), "\"name\":\"mcp__wiki__t0\""));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, child.toolsJson(), "\"name\":\"mcp__wiki__t1\""));
}
