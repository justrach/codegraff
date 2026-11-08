//! Native half of `load_tool_schemas`: lookup, session gate checks, catalog
//! verification, and truthful reporting for folded, eager, and gated natives.
//! Split out of `native_fold.zig` to stay under the 600-line ceiling (#492).

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const schema = @import("schema.zig");
const Provider = @import("provider.zig").Provider;
const tools_mod = @import("tools.zig");
const ExecResult = tools_mod.ExecResult;
const native_fold = @import("native_fold.zig");
const mcp_schema_gate = @import("mcp_schema_gate.zig");
const no_local_tools = @import("no_local_tools.zig");
const tool_gates = @import("tool_gates.zig");
const tool_surface = @import("tool_surface.zig");
const imagegen = @import("imagegen.zig");
const learn_store = @import("learn_store.zig");
const ask_user = @import("ask_user.zig");
const rlm = @import("rlm.zig");
const shell_tool = @import("shell_tool.zig");
const local_tools = @import("local_tools.zig");
const schedule = @import("schedule.zig");
const jev_tool = @import("jev_tool.zig");

fn bareNativeName(raw: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, raw, "bash") or std.mem.eql(u8, raw, "bash_output") or std.mem.eql(u8, raw, "bash_kill"))
        return shell_tool.tool_name;
    for (schema.root_specs) |s| if (std.mem.eql(u8, raw, s.name)) return s.name;
    for (schema.optional_specs) |s| if (std.mem.eql(u8, raw, s.name)) return s.name;
    if (std.mem.eql(u8, raw, rlm.tool_name)) return rlm.tool_name;
    if (std.mem.eql(u8, raw, local_tools.install_name)) return local_tools.install_name;
    if (std.mem.eql(u8, raw, schedule.tool_name)) return schedule.tool_name;
    if (std.mem.eql(u8, raw, jev_tool.name)) return jev_tool.name;
    return null;
}

/// Resolve a model-supplied tool name (including shell aliases, `mcp__graff__`
/// prefixes, and installed `local__*` tools) to its canonical native spec name.
pub fn canonicalNativeName(arena: Allocator, raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (bareNativeName(trimmed)) |canon| return canon;
    if (std.mem.startsWith(u8, trimmed, "mcp__graff__")) {
        if (bareNativeName(trimmed["mcp__graff__".len..])) |canon| return canon;
    }
    if (local_tools.isLocal(trimmed)) {
        for (local_tools.catalogExtras(arena)) |s| if (std.mem.eql(u8, s.name, trimmed)) return s.name;
    }
    return null;
}

pub fn isKnownNative(arena: Allocator, raw: []const u8) bool {
    return canonicalNativeName(arena, raw) != null;
}

fn agentProvider(agent: anytype) ?Provider {
    if (@hasField(@TypeOf(agent.*), "provider")) {
        if (@TypeOf(agent.provider) == Provider) return agent.provider;
    }
    return null;
}

pub fn findSessionSpec(arena: Allocator, name: []const u8, maybe_provider: ?Provider) !?schema.ToolSpec {
    if (std.mem.eql(u8, name, "ask_user") and ask_user.g_no_human) return null;
    if (tool_surface.hideBuiltin(name)) return null;
    for (try schema.effectiveRootSpecs(arena)) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    for (local_tools.catalogExtras(arena)) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    for (schedule.catalogExtras(arena)) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    if (maybe_provider) |p| {
        for (jev_tool.catalogExtras(p)) |spec| {
            if (std.mem.eql(u8, spec.name, name)) return spec;
        }
    }
    return null;
}

/// The session's effective spec for one native tool, or null — includes root
/// catalog extras (`install_agent_tool`, `schedule_task`) alongside root_specs.
pub fn findRootSpec(arena: Allocator, name: []const u8) !?schema.ToolSpec {
    return findSessionSpec(arena, name, null);
}

/// Whether folded native `name` can enter the session's active catalog once
/// marked loaded. Handles `--lean`, where `leanKeeps` admits folded tools only
/// after `isLoaded(name)` flips true, without mutating global flags.
pub fn canLoadFoldedSpec(arena: Allocator, name: []const u8) !?schema.ToolSpec {
    if (try findRootSpec(arena, name)) |spec| return spec;
    if (!no_local_tools.lean or !native_fold.isFolded(name)) return null;
    if (no_local_tools.blocks(name) or tool_surface.hideBuiltin(name)) return null;
    if (std.mem.eql(u8, name, "clock_sleep") and !main_mod.g_clock_sleep) return null;
    if (std.mem.eql(u8, name, "learn_candidate") and !learn_store.active_agent_loaded) return null;
    if (std.mem.eql(u8, name, rlm.tool_name) and !rlm.available) return null;
    if (tool_gates.blocks(name)) return null;
    if (std.mem.eql(u8, name, "ask_user") and ask_user.g_no_human) return null;
    const raw_spec: schema.ToolSpec = blk: {
        for (schema.root_specs) |s| if (std.mem.eql(u8, s.name, name)) break :blk s;
        for (schema.optional_specs) |s| if (std.mem.eql(u8, s.name, name)) break :blk s;
        if (std.mem.eql(u8, name, rlm.tool_name)) break :blk .{ .name = rlm.tool_name, .desc = rlm.tool_desc, .schema = rlm.tool_schema };
        return null;
    };
    const compacted = try no_local_tools.compactLeanSpecs(schema.ToolSpec, arena, &.{raw_spec});
    return if (compacted.len > 0) compacted[0] else null;
}

/// Folded native names eligible for `load_tool_schemas`'s `Folded native:`
/// description listing. Excludes gated/disabled tools so the prompt never
/// advertises a tool that cannot enter the active catalog (#492).
pub fn advertisedFolded(arena: Allocator) ![]const []const u8 {
    if (!native_fold.anyFolded() or no_local_tools.lean) return &.{};
    var natives: std.ArrayList([]const u8) = .empty;
    for (native_fold.folded) |name| {
        if (!native_fold.isFolded(name)) continue;
        if (std.mem.eql(u8, name, "rlm")) continue; // tail-only; listing rewrites the head
        if (!mcp_schema_gate.g_stable_catalog and native_fold.isLoaded(name)) continue;
        if ((try canLoadFoldedSpec(arena, name)) == null) continue;
        try natives.append(arena, name);
    }
    return natives.items;
}

pub fn unavailableReason(name: []const u8) []const u8 {
    if (no_local_tools.blocks(name)) return "disabled by --no-local-tools in this session.";
    if (std.mem.eql(u8, name, local_tools.install_name) or std.mem.eql(u8, name, schedule.tool_name)) {
        if (no_local_tools.enabled) return "disabled by --no-local-tools in this session.";
        if (no_local_tools.lean) return "disabled under --lean one-shot mode.";
    }
    if (std.mem.eql(u8, name, imagegen.tool_name) and !imagegen.available)
        return "image generation runtime is not installed or configured in this environment.";
    if (std.mem.eql(u8, name, "clock_sleep") and !main_mod.g_clock_sleep)
        return "off unless --clock-sleep or GRAFF_CLOCK_SLEEP=1 is set.";
    if (std.mem.eql(u8, name, "learn_candidate") and !learn_store.active_agent_loaded)
        return "no active learning policy is loaded in this workspace.";
    if (std.mem.eql(u8, name, "ask_user") and ask_user.g_no_human)
        return "disabled in non-interactive mode (no human available to answer).";
    if (std.mem.eql(u8, name, rlm.tool_name) and !rlm.available)
        return "disabled in --old / --no-rlm mode.";
    if (std.mem.eql(u8, name, jev_tool.name))
        return "not enabled for the active provider or model.";
    if (tool_surface.hideBuiltin(name))
        return "superseded by the connected companion MCP surface in this session.";
    if (no_local_tools.lean and !no_local_tools.leanKeeps(name))
        return "omitted under --lean one-shot mode.";
    return "disabled or gated off in this session.";
}

/// Loading a folded native changes the provider-visible tool surface. Root
/// catalogs are cached on Agent, so mutating g_loaded alone leaves the model
/// with the stale pre-load array (#492). Mirror mcp_schema_gate.handleLoad:
/// invalidate every provider encoding and eagerly rebuild the active one.
fn refreshAgentCatalog(agent: anytype) void {
    agent.invalidateRootTools();
    agent.ensureRootTools(agent.provider.kind) catch {};
}

fn catalogJsonHasTool(arena: Allocator, catalog_json: []const u8, want: []const u8) bool {
    const parsed = std.json.parseFromSliceLeaky(Value, arena, catalog_json, .{}) catch return false;
    if (parsed != .array) return false;
    for (parsed.array.items) |item| {
        if (item != .object) continue;
        const fn_obj = if (item.object.get("function")) |f| (if (f == .object) f.object else continue) else item.object;
        const nm = fn_obj.get("name") orelse continue;
        if (nm == .string and std.mem.eql(u8, nm.string, want)) return true;
    }
    return false;
}

fn agentCatalogHasTool(agent: anytype, name: []const u8) bool {
    if (!@hasDecl(@TypeOf(agent.*), "toolsJson")) return true;
    return catalogJsonHasTool(agent.arena, agent.toolsJson(), name);
}

fn isDescStopword(w: []const u8) bool {
    const stops = [_][]const u8{ "use", "the", "and", "for", "with", "from", "into", "this", "that", "when", "only" };
    for (stops) |s| if (std.ascii.eqlIgnoreCase(w, s)) return true;
    return false;
}

fn scoreSpec(name: []const u8, desc: []const u8, query: []const u8) usize {
    var hits: usize = 0;
    var tok = std.mem.tokenizeAny(u8, query, " \t,;:/_-");
    while (tok.next()) |w| {
        if (w.len < 2) continue;
        if (mcp_schema_gate.containsIgnoreCase(name, w)) {
            hits += 1;
            continue;
        }
        if (w.len < 3 or isDescStopword(w)) continue;
        if (mcp_schema_gate.containsIgnoreCase(desc, w)) hits += 1;
    }
    return hits;
}

/// Deferred native listing for `{}` (no-arg) calls and query misses.
pub fn listDeferredNative(arena: Allocator) !?[]const u8 {
    if (!native_fold.enabled) return null;
    var aw: Io.Writer.Allocating = .init(arena);
    var count: usize = 0;
    for (native_fold.folded) |name| {
        if (!native_fold.blocked(name)) continue;
        const spec = (try canLoadFoldedSpec(arena, name)) orelse continue;
        if (count == 0) {
            // Header requires count; buffer entries separately.
        }
        _ = spec;
        count += 1;
    }
    if (count == 0) return null;
    try aw.writer.print("{d} native tool(s) are deferred — pass their bare names in tools to {s} to load and enable them:\n", .{ count, mcp_schema_gate.tool_name });
    for (native_fold.folded) |name| {
        if (!native_fold.blocked(name)) continue;
        const spec = (try canLoadFoldedSpec(arena, name)) orelse continue;
        try aw.writer.print("  {s}: {s}\n", .{ name, mcp_schema_gate.shortDesc(spec.desc) });
    }
    return aw.writer.buffered();
}

/// Fallback when neither deferred natives nor deferred MCP tools matched `query`:
/// surface already-active native matches as callable, or explain gated/miss state.
pub fn fallbackNativeQuery(agent: anytype, query: []const u8) !?ExecResult {
    const prov = agentProvider(agent);
    var active_aw: Io.Writer.Allocating = .init(agent.arena);
    var active_count: usize = 0;
    var seen: std.ArrayList([]const u8) = .empty;
    if (@hasDecl(@TypeOf(agent.*), "toolsJson") and agent.toolsJson().len == 0) {
        agent.ensureRootTools(agent.provider.kind) catch {};
    }
    for (schema.root_specs) |s| {
        if (native_fold.blocked(s.name)) continue;
        const spec = (try findSessionSpec(agent.arena, s.name, prov)) orelse continue;
        if (scoreSpec(spec.name, spec.desc, query) == 0) continue;
        if (!agentCatalogHasTool(agent, spec.name)) continue;
        try seen.append(agent.arena, spec.name);
        try active_aw.writer.print("{s}: {s}\n", .{ spec.name, spec.schema });
        active_count += 1;
    }
    for (local_tools.catalogExtras(agent.arena)) |s| {
        if (native_fold.blocked(s.name) or scoreSpec(s.name, s.desc, query) == 0) continue;
        if (!agentCatalogHasTool(agent, s.name)) continue;
        try active_aw.writer.print("{s}: {s}\n", .{ s.name, s.schema });
        active_count += 1;
    }
    for (schedule.catalogExtras(agent.arena)) |s| {
        if (native_fold.blocked(s.name) or scoreSpec(s.name, s.desc, query) == 0) continue;
        if (!agentCatalogHasTool(agent, s.name)) continue;
        try active_aw.writer.print("{s}: {s}\n", .{ s.name, s.schema });
        active_count += 1;
    }
    if (active_count > 0) {
        const head = try std.fmt.allocPrint(
            agent.arena,
            "{d} native tool schema(s) below are already active and callable in your tool list (0 newly enabled). Call them directly with arguments matching input_schema.\n",
            .{active_count},
        );
        return .{ .text = try std.fmt.allocPrint(agent.arena, "{s}{s}", .{ head, active_aw.writer.buffered() }), .is_error = false };
    }
    // Check gated-off native tools so a query like "imagegen" explains why it is absent.
    for (native_fold.folded) |name| {
        if ((try canLoadFoldedSpec(agent.arena, name)) != null) continue;
        const desc = for (schema.root_specs) |s| {
            if (std.mem.eql(u8, s.name, name)) break s.desc;
        } else for (schema.optional_specs) |s| {
            if (std.mem.eql(u8, s.name, name)) break s.desc;
        } else "";
        if (scoreSpec(name, desc, query) == 0) continue;
        const rest = (try listDeferredNative(agent.arena)) orelse "";
        const sep = if (rest.len > 0) "\n" else "";
        return .{
            .text = try std.fmt.allocPrint(agent.arena, "native tool '{s}' is unavailable in this session: {s}{s}{s}", .{ name, unavailableReason(name), sep, rest }),
            .is_error = true,
        };
    }
    return null;
}

/// The native half of `load_tool_schemas`, called before the MCP handler:
/// enables deferred folded natives, answers truthfully for already-active and
/// gated/unavailable native tools, and verifies post-rebuild catalog presence (#492).
pub fn handleLoadNative(agent: anytype, input: Value) !?ExecResult {
    if (@hasField(@TypeOf(agent.*), "sub") and agent.sub) return null;
    if (input != .object) return null;
    const prov = agentProvider(agent);

    if (input.object.get("query")) |q| if (q == .string and input.object.get("tools") == null) {
        if (!native_fold.enabled) return null;
        const Candidate = struct { name: []const u8, spec: schema.ToolSpec };
        var matched: std.ArrayList(Candidate) = .empty;
        for (native_fold.folded) |name| {
            if (!native_fold.blocked(name)) continue;
            const spec = (try canLoadFoldedSpec(agent.arena, name)) orelse continue;
            if (scoreSpec(name, spec.desc, q.string) == 0) continue;
            native_fold.markLoaded(name);
            try matched.append(agent.arena, .{ .name = name, .spec = spec });
        }
        if (matched.items.len == 0) return null;
        refreshAgentCatalog(agent);
        var aw: Io.Writer.Allocating = .init(agent.arena);
        var verified: usize = 0;
        for (matched.items) |m| {
            if (!agentCatalogHasTool(agent, m.name)) {
                native_fold.unloadForTest(m.name);
                continue;
            }
            verified += 1;
            try aw.writer.print("{s}: {s}\n", .{ m.name, m.spec.schema });
        }
        if (verified == 0) return null;
        const head = try std.fmt.allocPrint(
            agent.arena,
            "{d} native tool schema(s) below are now loaded and callable for the rest of this session. Call them with arguments matching input_schema.\n",
            .{verified},
        );
        return .{ .text = try std.fmt.allocPrint(agent.arena, "{s}{s}", .{ head, aw.writer.buffered() }), .is_error = false };
    };

    const list = input.object.get("tools") orelse return null;
    if (list != .array) return null;

    const Candidate = struct { name: []const u8, spec: schema.ToolSpec, fresh: bool };
    const Unavail = struct { name: []const u8, reason: []const u8 };
    var candidates: std.ArrayList(Candidate) = .empty;
    var unavailable: std.ArrayList(Unavail) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;
    var need_refresh = false;

    for (list.array.items) |item| {
        if (item != .string) continue;
        const canon = canonicalNativeName(agent.arena, item.string) orelse continue;
        const dup = for (seen.items) |prev| {
            if (std.mem.eql(u8, prev, canon)) break true;
        } else false;
        if (dup) continue;
        try seen.append(agent.arena, canon);

        if (native_fold.blocked(canon)) {
            if (try canLoadFoldedSpec(agent.arena, canon)) |spec| {
                native_fold.markLoaded(canon);
                need_refresh = true;
                try candidates.append(agent.arena, .{ .name = canon, .spec = spec, .fresh = true });
            } else {
                try unavailable.append(agent.arena, .{ .name = canon, .reason = unavailableReason(canon) });
            }
        } else {
            if (try findSessionSpec(agent.arena, canon, prov)) |spec| {
                if (@hasDecl(@TypeOf(agent.*), "toolsJson") and !agentCatalogHasTool(agent, canon)) need_refresh = true;
                try candidates.append(agent.arena, .{ .name = canon, .spec = spec, .fresh = false });
            } else {
                try unavailable.append(agent.arena, .{ .name = canon, .reason = unavailableReason(canon) });
            }
        }
    }

    if (candidates.items.len == 0 and unavailable.items.len == 0) return null;
    if (need_refresh) refreshAgentCatalog(agent);

    var callable: std.ArrayList(Candidate) = .empty;
    var fresh_verified: usize = 0;
    for (candidates.items) |c| {
        if (!agentCatalogHasTool(agent, c.name)) {
            if (c.fresh) native_fold.unloadForTest(c.name);
            try unavailable.append(agent.arena, .{ .name = c.name, .reason = unavailableReason(c.name) });
            continue;
        }
        if (c.fresh) fresh_verified += 1;
        try callable.append(agent.arena, c);
    }

    var out: Io.Writer.Allocating = .init(agent.arena);
    if (callable.items.len == 0) {
        for (unavailable.items, 0..) |u, i| {
            if (i > 0) try out.writer.writeByte('\n');
            try out.writer.print("native tool '{s}' is unavailable in this session: {s}", .{ u.name, u.reason });
        }
        return .{ .text = out.writer.buffered(), .is_error = true };
    }

    if (fresh_verified > 0) {
        try out.writer.print(
            "{d} native tool schema(s) below are now loaded and callable for the rest of this session ({d} newly enabled). Call them with arguments matching input_schema.\n",
            .{ callable.items.len, fresh_verified },
        );
    } else {
        try out.writer.print(
            "{d} native tool schema(s) below are already active and callable in your tool list (0 newly enabled). Call them directly with arguments matching input_schema.\n",
            .{callable.items.len},
        );
    }
    for (callable.items) |c| {
        try out.writer.print("{s}: {s}\n", .{ c.name, c.spec.schema });
    }
    if (unavailable.items.len > 0) {
        try out.writer.writeAll("Unavailable native tool(s) in this session (not loaded, cannot be called):\n");
        for (unavailable.items) |u| {
            try out.writer.print("  {s}: {s}\n", .{ u.name, u.reason });
        }
    }
    return .{ .text = out.writer.buffered(), .is_error = false };
}
