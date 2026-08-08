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

/// The folded set: power/meta tools an interactive session reaches for
/// LATE if at all, whose schemas cost ~9.3k bytes of every request.
/// Deliberately NOT here: the tools a session needs on turn one (bash, the
/// file tools, subagent — the unattended delegation path), the interactive
/// staples (todos, ask_user, peer_message, webfetch, skill), and the meta
/// arm itself (load_tool_schemas must stay callable to unfold these).
pub const folded = [_][]const u8{
    "workflow",
    "imagegen",
    "learn_candidate",
    "eval",
    "clock_sleep",
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
pub fn markLoaded(name: []const u8) void {
    if (isLoaded(name) or g_loaded_len >= g_loaded.len) return;
    g_loaded[g_loaded_len] = name;
    g_loaded_len += 1;
}

/// Whether calling `name` right now must be refused (exec.zig layer 2).
pub fn blocked(name: []const u8) bool {
    return enabled and isFolded(name) and !isLoaded(name);
}

/// Whether a native spec should be served description-only (schema.zig
/// layer 1): folded and not yet loaded.
pub fn servePlaceholder(name: []const u8) bool {
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

/// exec.zig layer 2 as one expression for the guard chain: the refusal when
/// the call is blocked, else null. `gpa` is the exec context's result
/// allocator. Deliberately positioned alongside the #416 refusal — both run
/// downstream of agent_tool_gate.gateTool, so the fold can only subtract a
/// call consent already allowed, never add one. Yields in plan mode: the
/// read-only policy is the stronger reason, and its gate must deliver its
/// own refusal rather than the model hearing "schema not loaded".
pub fn gateExec(gpa: Allocator, name: []const u8) ?@import("tools.zig").ToolOutput {
    if (@import("main.zig").plan_mode) return null;
    if (!blocked(name)) return null;
    return .{ .text = refusalText(gpa, name) catch return null, .is_error = true };
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

/// The native half of load_tool_schemas, called from agent_tools before the
/// MCP handler: an input naming folded native tools loads them (real schema
/// in the result, enabled for the session). Returns null when the input
/// names NO folded native tool, so MCP-only requests reach the MCP handler
/// unchanged; a named-but-unknown tool falls to the MCP handler's listing.
pub fn handleLoadNative(agent: anytype, input: @import("std").json.Value) !?@import("tools.zig").ExecResult {
    if (!enabled) return null;
    if (input != .object) return null;
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
    try std.testing.expect(!isFolded("bash"));
    try std.testing.expect(!isFolded("subagent"));
    try std.testing.expect(anyFolded());
    enabled = false;
    try std.testing.expect(!blocked("workflow"));
    try std.testing.expect(!anyFolded());
    enabled = true;
    if (!isLoaded("clock_sleep")) {
        try std.testing.expect(blocked("clock_sleep"));
        try std.testing.expect(servePlaceholder("clock_sleep"));
        markLoaded("clock_sleep");
        try std.testing.expect(isLoaded("clock_sleep"));
        try std.testing.expect(!blocked("clock_sleep"));
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
