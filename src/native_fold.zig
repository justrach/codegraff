//! Folded native tools: #416's two-phase exposure applied to the harness's
//! OWN power tools, not just MCP servers.
//!
//! The interactive root catalog measured 42,851 bytes of tool JSON in every
//! request — 77% of the wire body (GRAFF_REQ_STATS), with native specs alone
//! at ~26k bytes. opencode's TUI ships one lean surface for both modes; our
//! REPL paid for workflow/imagegen/learn/eval schemas on EVERY turn whether
//! or not the session ever called them. The fix is the meta-tool pattern the
//! user named: these tools register name + one-line description + a
//! placeholder schema up front, and `load_tool_schemas` (already the MCP
//! meta arm) returns the real schema and enables them on demand.
//!
//! Same two invariants as #416, for the same reasons:
//!  - consent is untouched: the refusal lives in exec.zig's guard chain,
//!    DOWNSTREAM of agent_tool_gate.gateTool, so deferral can only subtract
//!    a call consent already allowed, never add one;
//!  - the enable path needs no catalog re-render: the real schema rides the
//!    load_tool_schemas RESULT, exactly like the MCP half.
//!
//! State is an append-only list with exactly one writer — the orchestrator
//! thread, since load_tool_schemas is handled inline (agent_tools.zig) — and
//! pool threads only read, always after the spawn that publishes the write.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const mcp_schema_gate = @import("mcp_schema_gate.zig"); // shortDesc + placeholder_schema: one deferral style for both halves

/// GRAFF_NO_NATIVE_FOLD turns the fold off (session_settings) — the full
/// power-tool schemas return to every request, the pre-fold behavior.
pub var enabled = true;

/// The folded set: tools an interactive session reaches for LATE if at all,
/// plus the deliberate-act tools whose first use tolerates one load call —
/// measured (GRAFF_REQ_STATS top-5) at ~9.5k bytes of every request, with
/// subagent alone at 5,052 (26% of the tools surface).
/// Deliberately NOT here: the every-turn loop (bash, the file tools, codedb),
/// loop control (ask_user, attempt_completion), and the meta arm itself
/// (load_tool_schemas must stay callable to unfold these). Subagents are
/// exempt at the call gates: their catalogs are comptime-baked full surfaces,
/// so refusing them would be incoherent.
pub const folded = [_][]const u8{
    "workflow",
    "imagegen",
    "learn_candidate",
    "eval",
    "clock_sleep",
    "subagent",
    "todo_write",
    "todo_read",
    "peer_message",
    "note_constraint",
    "agent_output",
    "skill",
    "webfetch",
};

/// A name test only, independent of whether the fold is on.
pub fn isFolded(name: []const u8) bool {
    for (folded) |tool| {
        if (std.mem.eql(u8, name, tool)) return true;
    }
    return false;
}

/// Whether the fold is live at all — hiddenSpec consults this so
/// load_tool_schemas stays advertised while ANY folded tool exists.
pub fn anyFolded() bool {
    return enabled;
}

var g_loaded: [folded.len][]const u8 = undefined;
var g_loaded_len: usize = 0;

pub fn isLoaded(name: []const u8) bool {
    for (g_loaded[0..g_loaded_len]) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// The single writer: load_tool_schemas, inline on the orchestrator.
/// Callers pass slices into per-turn JSON (freed arena memory), so storing
/// them would dangle across turns (#480-family segfault in isLoaded); the
/// load path only admits folded names, so canonicalize to the static entry.
pub fn markLoaded(name: []const u8) void {
    if (isLoaded(name) or g_loaded_len >= g_loaded.len) return;
    for (folded) |tool| {
        if (std.mem.eql(u8, name, tool)) {
            g_loaded[g_loaded_len] = tool;
            g_loaded_len += 1;
            return;
        }
    }
}

/// Whether calling `name` right now must be refused (exec.zig layer 2);
/// schema.zig layer 1 skips the spec entirely while this holds (zero stubs).
pub fn blocked(name: []const u8) bool {
    return enabled and isFolded(name) and !isLoaded(name);
}

/// The session's loaded folded natives, in load order (schema.zig's stable
/// tail appends them after the stable head — load order keeps it append-only).
pub fn loadedNames() []const []const u8 {
    return g_loaded[0..g_loaded_len];
}

/// GRAFF_STABLE_CATALOG tail (schema.zig renderRootTools, #476): every tool
/// whose schema has loaded this session, appended in LOAD ORDER after the
/// stable catalog head — folded natives first, then MCP tools by gate seq.
/// Append-only is the point: a load changes only the tools array's tail
/// bytes, and the provider's prefix cache (tools serialize before messages)
/// survives what a mid-array re-insertion would bust.
pub fn renderLoadedTail(s: *std.json.Stringify, kind: @import("provider.zig").Provider.Kind, out: Allocator, mcp_tools: []const @import("mcp.zig").Tool) !void {
    const schema_mod = @import("schema.zig");
    const mcp = @import("mcp.zig");
    for (loadedNames()) |name| {
        const spec = (try findRootSpec(out, name)) orelse continue;
        try schema_mod.writeToolEntry(s, kind, spec.name, spec.desc, .{ .raw = spec.schema });
    }
    var loaded: std.ArrayList(mcp.Tool) = .empty;
    for (mcp_tools) |m| if (mcp_schema_gate.policyDeferred(mcp_tools, m) and mcp_schema_gate.loadSeq(m.qualified_name) != null)
        try loaded.append(out, m);
    std.mem.sort(mcp.Tool, loaded.items, {}, struct {
        fn lt(_: void, a: mcp.Tool, b: mcp.Tool) bool {
            return mcp_schema_gate.loadSeq(a.qualified_name).? < mcp_schema_gate.loadSeq(b.qualified_name).?;
        }
    }.lt);
    for (loaded.items) |m| try schema_mod.writeToolEntry(s, kind, m.qualified_name, m.description, .{ .value = m.input_schema });
}

/// Whether the root catalog skips this native spec at render: folded and not
/// yet loaded — or, under GRAFF_STABLE_CATALOG, folded at all (the loaded
/// schema already rides the load result; a re-render would bust the prefix
/// cache the mode exists to protect, #476).
pub fn catalogSkips(name: []const u8) bool {
    if (!enabled) return false;
    if (mcp_schema_gate.g_stable_catalog) return isFolded(name);
    return blocked(name);
}

/// Same refusal style as mcp_schema_gate.refusalText: name the fix, not just
/// the block, so the model loads instead of retrying.
pub fn refusalText(gpa: Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "{s} is registered but its schema is not loaded, so it cannot be called yet. " ++
            "Call {s} with {{\"tools\": [\"{s}\"]}} first — that returns the full input schema and enables the tool " ++
            "for the rest of this session — then call {s} again with arguments matching that schema. " ++
            "This is a context-cost deferral only; it does not change approvals or trust.",
        .{ name, mcp_schema_gate.tool_name, name, name },
    );
}

/// agent_tools' meta path and exec's gateExec share this: a confident call
/// to a folded tool loads it in place of the old refusal (user direction —
/// the refuse → load → retry dance cost a round trip, and the eval/review
/// flows' blind eval calls starved on it: test-review-mode RunBudgetExhausted).
pub fn markIfFolded(name: []const u8) void {
    if (blocked(name)) markLoaded(name);
}

/// exec.zig layer 2 as one expression for the guard chain. A call to a
/// folded, not-yet-loaded tool AUTO-LOADS it and proceeds (user direction):
/// the tool is advertised in the deferred listing, the call itself shows the
/// model's intent, and the old refusal → load_tool_schemas → retry dance cost
/// a full round trip per tool per session. The load appends the spec to the
/// next request's catalog exactly as an explicit load would. Deliberately
/// positioned alongside the #416 refusal — downstream of
/// agent_tool_gate.gateTool, so consent is already settled either way. Yields
/// in plan mode: the read-only policy's gate must deliver its own refusal.
pub fn gateExec(gpa: Allocator, name: []const u8, from_sub: bool) ?@import("tools.zig").ToolOutput {
    _ = gpa;
    if (from_sub) return null; // subs are served comptime-baked full catalogs — nothing is folded for them
    if (@import("main.zig").plan_mode) return null;
    if (!blocked(name)) return null;
    markLoaded(name);
    return null;
}

/// The result half of a native load: the tool's REAL spec schema, rendered
/// into the load_tool_schemas result exactly like the MCP half's — the
/// catalog never re-renders. `real_schema` is the spec's raw JSON string.
pub fn loadResultText(arena: Allocator, name: []const u8, real_schema: []const u8) ![]u8 {
    markLoaded(name);
    return std.fmt.allocPrint(
        arena,
        "1 tool schema below is now loaded and callable for the rest of this session. Call it with arguments matching input_schema.\n{s}: {s}\n{s}",
        .{ name, real_schema, name },
    );
}

/// The session's effective spec for one native tool, or null — the native
/// half of load_tool_schemas needs the REAL schema to hand back on load.
/// Lives here (not schema.zig, at the 600 cap); the mutual import with
/// schema.zig is lazy and legal.
pub fn findRootSpec(arena: Allocator, name: []const u8) !?@import("schema.zig").ToolSpec {
    for (try @import("schema.zig").effectiveRootSpecs(arena)) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}

/// Loading a folded native changes the provider-visible tool surface. Root
/// catalogs are cached on Agent, so mutating g_loaded alone leaves the model
/// with the stale pre-load array (#492). Mirror mcp_schema_gate.handleLoad:
/// invalidate every provider encoding and eagerly rebuild the active one.
fn refreshAgentCatalog(agent: anytype) void {
    agent.invalidateRootTools();
    agent.ensureRootTools(agent.provider.kind) catch {};
}

/// The native half of load_tool_schemas, called from agent_tools before the
/// MCP handler: an input naming folded native tools loads them (real schema
/// in the result, enabled for the session). Returns null when the input
/// names NO folded native tool, so MCP-only requests reach the MCP handler
/// unchanged; a named-but-unknown tool falls to the MCP handler's listing.
pub fn handleLoadNative(agent: anytype, input: @import("std").json.Value) !?@import("tools.zig").ExecResult {
    if (!enabled) return null;
    if (input != .object) return null;
    // query arm: token-match over the folded set's names + descriptions, so
    // keyword discovery covers both deferred halves, not just MCP.
    if (input.object.get("query")) |q| {
        if (q != .string) return null;
        var aw: Io.Writer.Allocating = .init(agent.arena);
        var matched: usize = 0;
        for (folded) |name| {
            if (isLoaded(name)) continue;
            const spec = (try findRootSpec(agent.arena, name)) orelse continue;
            var tok = std.mem.tokenizeAny(u8, q.string, " \t,;:/_-");
            var hits: usize = 0;
            while (tok.next()) |w| {
                if (w.len < 2) continue;
                if (mcp_schema_gate.containsIgnoreCase(name, w) or mcp_schema_gate.containsIgnoreCase(spec.desc, w)) hits += 1;
            }
            if (hits == 0) continue;
            markLoaded(name);
            matched += 1;
            aw.writer.print("{s}: {s}\n", .{ name, spec.schema }) catch return null;
        }
        if (matched == 0) return null; // no native match: the MCP half answers the query
        refreshAgentCatalog(agent);
        const head = try std.fmt.allocPrint(agent.arena, "{d} native tool schema(s) below are now loaded and callable for the rest of this session. Call them with arguments matching input_schema.\n", .{matched});
        return .{ .text = try std.fmt.allocPrint(agent.arena, "{s}{s}", .{ head, aw.writer.buffered() }), .is_error = false };
    }
    const list = input.object.get("tools") orelse return null;
    if (list != .array) return null;
    var aw: Io.Writer.Allocating = .init(agent.arena);
    var fresh: usize = 0;
    var total: usize = 0;
    for (list.array.items) |item| {
        if (item != .string or !isFolded(item.string)) continue;
        total += 1;
        if (isLoaded(item.string)) {
            aw.writer.print("{s}: already loaded.\n", .{item.string}) catch return null;
            continue;
        }
        const spec = (try findRootSpec(agent.arena, item.string)) orelse {
            aw.writer.print("{s}: folded but not in this session's catalog (disabled or gated).\n", .{item.string}) catch return null;
            continue;
        };
        markLoaded(item.string);
        fresh += 1;
        aw.writer.print("{s}: {s}\n", .{ item.string, spec.schema }) catch return null;
    }
    if (total == 0) return null;
    if (fresh > 0) refreshAgentCatalog(agent);
    var head: Io.Writer.Allocating = .init(agent.arena);
    head.writer.print("{d} native tool schema(s) below are now loaded and callable for the rest of this session ({d} newly enabled). Call them with arguments matching input_schema.\n", .{ total, fresh }) catch return null;
    return .{ .text = try agent.arena.dupe(u8, try std.fmt.allocPrint(agent.arena, "{s}{s}", .{ head.writer.buffered(), aw.writer.buffered() })), .is_error = false };
}

test "fold: the listed tools are blocked until loaded, everything else flows" {
    const saved = enabled;
    defer enabled = saved;
    enabled = true;
    // State leak guard: these tests share g_loaded with the process, so use a
    // name only this test folds... every folded name is shared state, so
    // assert on the pre-load state only for names no other test loads.
    try std.testing.expect(isFolded("workflow"));
    try std.testing.expect(isFolded("subagent")); // the 5 KB schema — biggest single fold win
    try std.testing.expect(!isFolded("bash"));
    try std.testing.expect(anyFolded());
    enabled = false;
    try std.testing.expect(!blocked("workflow"));
    try std.testing.expect(!anyFolded());
    enabled = true;
    if (!isLoaded("clock_sleep")) {
        try std.testing.expect(blocked("clock_sleep"));
        markLoaded("clock_sleep");
        try std.testing.expect(isLoaded("clock_sleep"));
        try std.testing.expect(!blocked("clock_sleep"));
    }
    // Subagents are exempt: their catalogs are comptime-baked full surfaces.
    try std.testing.expect(gateExec(std.testing.allocator, "workflow", true) == null);
    // A confident call to a folded tool auto-loads it instead of refusing
    // (user direction: the refuse → load → retry dance cost a round trip).
    if (!isLoaded("peer_message")) {
        try std.testing.expect(blocked("peer_message"));
        try std.testing.expect(gateExec(std.testing.allocator, "peer_message", false) == null);
        try std.testing.expect(isLoaded("peer_message"));
        try std.testing.expect(!blocked("peer_message"));
    }
    // A loaded name never double-registers.
    const before = g_loaded_len;
    markLoaded("clock_sleep");
    try std.testing.expectEqual(before, g_loaded_len);
}

test "fold refusal text names the load call, not just the block" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = try refusalText(a, "workflow");
    try std.testing.expect(std.mem.indexOf(u8, text, "load_tool_schemas") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"workflow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "does not change approvals") != null);
    const loaded = try loadResultText(a, "eval", "{\"type\":\"object\"}");
    try std.testing.expect(std.mem.indexOf(u8, loaded, "{\"type\":\"object\"}") != null);
    try std.testing.expect(isLoaded("eval"));
}

test "explicit native loads rebuild the active provider catalog (#492)" {
    const provider_mod = @import("provider.zig");
    const FakeAgent = struct {
        arena: Allocator,
        provider: struct { kind: provider_mod.Provider.Kind } = .{ .kind = .anthropic },
        invalidations: usize = 0,
        rebuilds: usize = 0,

        fn invalidateRootTools(self: *@This()) void {
            self.invalidations += 1;
        }

        fn ensureRootTools(self: *@This(), kind: provider_mod.Provider.Kind) !void {
            try std.testing.expectEqual(provider_mod.Provider.Kind.anthropic, kind);
            self.rebuilds += 1;
        }
    };

    const saved_enabled = enabled;
    const saved_loaded = g_loaded;
    const saved_loaded_len = g_loaded_len;
    defer {
        enabled = saved_enabled;
        g_loaded = saved_loaded;
        g_loaded_len = saved_loaded_len;
    }
    enabled = true;
    g_loaded_len = 0;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent: FakeAgent = .{ .arena = arena };
    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"tools\":[\"workflow\"]}", .{});
    const result = (try handleLoadNative(&agent, input)) orelse return error.TestExpectedLoadResult;

    try std.testing.expect(!result.is_error);
    try std.testing.expect(isLoaded("workflow"));
    try std.testing.expectEqual(@as(usize, 1), agent.invalidations);
    try std.testing.expectEqual(@as(usize, 1), agent.rebuilds);
}
