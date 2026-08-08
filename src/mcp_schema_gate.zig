//! #416: two-phase MCP tool exposure — names and a one-line description up
//! front, the full JSON Schema on demand.
//!
//! mcp.zig used to put every tool's whole `inputSchema` into the root catalog
//! at connect time, so a session paid for every schema of every configured
//! server on every request. With #345 (a user-level `~/.codegraff/mcp.json`
//! whose servers follow you into every checkout) that is a standing tax: one
//! companion server measured at +2,568 input tokens per call, whether or not
//! the model ever touched it. Measured against the bundled 13-tool Smolify
//! manifest (tool_schema_tests.zig): the catalog served for that one server
//! drops from 10,505 to 3,696 bytes, ~1,700 tokens off EVERY request.
//!
//! The deferred half of the catalog therefore carries `name` + a shortened
//! description + a placeholder schema, and `load_tool_schemas` hands back the
//! real schemas and ENABLES those tools for the rest of the session. A call to
//! a tool whose schema was never loaded is refused with instructions rather
//! than run (exec.zig, layer 2 — see `blocked`).
//!
//! Two invariants this module must never break:
//!
//!  - **Consent is untouched.** Deferral is about context cost, not permission.
//!    Nothing here reads or writes approvals, and the layer-2 refusal lives
//!    INSIDE execToolInner, i.e. downstream of agent_tool_gate.gateTool: the
//!    consent prompt is reached in exactly the cases it was reached before, in
//!    the same order, and deferral can only ever subtract a call that consent
//!    already allowed — never add one it did not.
//!  - **Small servers behave exactly as they do today.** The default is
//!    size-based: a server whose tools cost at most `default_budget` bytes of
//!    description + schema stays EAGER, because the load round trip re-emits
//!    those same bytes and would be a wash. Only servers above the threshold
//!    are deferred, plus whatever the user pins either way.
//!
//! Session state (which schemas have been loaded) is a lock-free append-only
//! list: the only writer is the orchestrator thread — `load_tool_schemas` is a
//! meta tool, handled inline — and pool threads only ever read it, always
//! after the spawn that publishes the write.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const mcp = @import("mcp.zig");
const mcp_config = @import("mcp_config.zig");
const tools_mod = @import("tools.zig");
const util = @import("util.zig");

const ExecResult = tools_mod.ExecResult;

/// Per-server budget, in bytes of description + serialized schema, under which
/// a server is served eagerly. 4 KiB is roughly 1,000 tokens: below that the
/// `load_tool_schemas` round trip (a tool call plus a result that re-emits the
/// very schemas it saved) costs about what deferral saves, so the indirection
/// only pays above it. It also means every small server keeps working byte for
/// byte as it did before #416.
pub const default_budget: usize = 4096;

/// How much of an MCP tool's description survives into the deferred listing.
/// Enough for a model to tell tools apart and decide what to load; a real MCP
/// description runs to paragraphs (codedbpro's `read` is over 400 bytes).
pub const desc_cap: usize = 180;

/// What a deferred tool advertises as its schema. Valid, permissive, and
/// self-describing, so a model that ignores the tool description still gets
/// told what to do — and `serde.defaultRootObjectType` has nothing to fix up.
/// Kept terse on purpose: it is repeated once per deferred tool, so every byte
/// here is paid N times against the savings it exists to buy. The full
/// protocol lives once, in `tool_desc`.
pub const placeholder_schema =
    \\{"type": "object", "description": "Deferred - load_tool_schemas first."}
;

pub const env_enabled = "GRAFF_MCP_LAZY_SCHEMAS"; // "0" turns deferral off entirely
pub const env_budget = "GRAFF_MCP_SCHEMA_BUDGET"; // per-server byte threshold; 0 defers everything
pub const env_eager = "GRAFF_MCP_EAGER"; // comma-separated server names; "*" pins them all

/// The `load_tool_schemas` tool's name/description/schema, kept here as plain
/// strings (the skill_docs.zig pattern) so schema.zig's catalog needs one
/// entry and no import cycle. The description is spliced into a raw JSON
/// string, so it must stay free of characters needing JSON escapes.
pub const tool_name = "load_tool_schemas";
pub const tool_desc = "Load the full JSON input schemas for MCP tools and enable them for the rest of this session. MCP servers with large schemas are registered up front by name and a one-line description only, so that thousands of tokens of JSON Schema stay out of every request. A tool whose schema has not been loaded CANNOT be called: calling it returns an error telling you to load it first. Pass tools with exact qualified names (mcp__server__tool), or pass server to load every deferred tool on one server. Call it with no arguments to list what is currently deferred. Loading is permanent for this session and free to repeat, because the schemas are cached.";
pub const tool_schema =
    \\{"type": "object", "properties": {"tools": {"type": "array", "items": {"type": "string"}, "description": "Exact qualified MCP tool names to load, e.g. mcp__deepwiki__ask_question"}, "server": {"type": "string", "description": "Load every deferred tool on this MCP server instead of naming them one by one"}}}
;

/// How this session decides eager vs deferred. Set once by `configure`.
pub const Policy = struct {
    enabled: bool = true,
    budget: usize = default_budget,
    /// Server names always served eagerly. A single "*" entry pins every
    /// server, which is the escape hatch back to pre-#416 behavior.
    eager: []const []const u8 = &.{},
};

pub var g_policy: Policy = .{};

// --- session state: which schemas have been loaded -------------------------

const Node = struct {
    name: []const u8,
    /// The rendered `{"name":…,"description":…,"input_schema":…}` block, kept
    /// so a repeated load is a pointer copy rather than a re-serialization.
    /// This is the per-session schema cache the issue asks for.
    rendered: []const u8,
    next: ?*Node,
};

var g_head: std.atomic.Value(?*Node) = .init(null);
/// Test seam: how many schemas this session has actually serialized. A second
/// `load_tool_schemas` for the same tool must not move it.
var g_renders: usize = 0;

/// Drop every loaded schema. A new session, and every test that touches the
/// gate.
pub fn reset() void {
    g_head.store(null, .release);
    g_renders = 0;
}

pub fn rendersForTest() usize {
    return g_renders;
}

fn find(name: []const u8) ?*Node {
    var cur = g_head.load(.acquire);
    while (cur) |node| : (cur = node.next) {
        if (std.mem.eql(u8, node.name, name)) return node;
    }
    return null;
}

pub fn isLoaded(name: []const u8) bool {
    return find(name) != null;
}

/// Publish one loaded schema. Single-writer (the orchestrator thread); the
/// release store is what makes the new node visible to a pool thread that
/// later acquires the head.
fn publish(arena: Allocator, name: []const u8, rendered: []const u8) !*Node {
    const node = try arena.create(Node);
    // The name is COPIED, not aliased: `tool.qualified_name` belongs to the
    // registry's arena, and this list has to outlive any registry rebuild.
    node.* = .{ .name = try arena.dupe(u8, name), .rendered = rendered, .next = g_head.load(.acquire) };
    g_head.store(node, .release);
    return node;
}

// --- policy ----------------------------------------------------------------

/// Resolve the session policy from the environment and the merged MCP config.
/// A server object may carry `"eager": true` to pin itself; unknown keys are
/// ignored by `mcp.Registry.startServer`, so the flag costs that path nothing.
/// Best-effort: an unparseable knob falls back to the default rather than
/// failing a session over a typo.
pub fn configure(arena: Allocator, merged: mcp_config.Merged, environ_map: anytype) void {
    var policy: Policy = .{};
    if (environ_map.get(env_enabled)) |v| policy.enabled = !std.mem.eql(u8, std.mem.trim(u8, v, " \t"), "0");
    if (environ_map.get(env_budget)) |v| {
        policy.budget = std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t"), 10) catch default_budget;
    }
    var eager: std.ArrayList([]const u8) = .empty;
    if (environ_map.get(env_eager)) |v| {
        var it = std.mem.tokenizeScalar(u8, v, ',');
        while (it.next()) |raw| {
            const name = std.mem.trim(u8, raw, " \t");
            if (name.len > 0) eager.append(arena, arena.dupe(u8, name) catch continue) catch {};
        }
    }
    var it = merged.servers.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const flag = entry.value_ptr.object.get("eager") orelse continue;
        if (flag != .bool or !flag.bool) continue;
        eager.append(arena, arena.dupe(u8, entry.key_ptr.*) catch continue) catch {};
    }
    policy.eager = eager.items;
    g_policy = policy;
}

/// Startup-only promotion after configure(): a post-connect capability probe
/// (the codedb-pro license check) lands AFTER the registry starts, so it
/// appends here rather than arriving through env/config. Single-threaded
/// startup contract — call it from main() before the first catalog render,
/// never at request time (pool threads read g_policy concurrently).
pub fn pinEagerRuntime(arena: Allocator, server: []const u8) void {
    if (pinnedEager(server)) return;
    var list: std.ArrayList([]const u8) = .empty;
    list.appendSlice(arena, g_policy.eager) catch return;
    list.append(arena, arena.dupe(u8, server) catch return) catch return;
    g_policy.eager = list.items;
}

/// --lean: fold EVERY MCP server behind load_tool_schemas rather than skip
/// MCP entirely — capability survives (a load call away), prefix cost drops
/// to names + shortened descriptions. Clears eager pins too: a licensed
/// companion's runtime pin is worth its bytes in an interactive session, not
/// in a one-shot counting every token. GRAFF_MCP_SCHEMA_BUDGET=0 is the same
/// policy reached by env; this is the flag's path to it.
pub fn deferAllRuntime() void {
    g_policy.budget = 0;
    g_policy.eager = &.{};
}

/// The server half of `mcp__<server>__<tool>`; "" for a name that is not one.
pub fn serverOf(qualified: []const u8) []const u8 {
    const prefix = "mcp__";
    if (!std.mem.startsWith(u8, qualified, prefix)) return "";
    const rest = qualified[prefix.len..];
    const sep = std.mem.indexOf(u8, rest, "__") orelse return rest;
    return rest[0..sep];
}

pub fn pinnedEager(server: []const u8) bool {
    for (g_policy.eager) |p| {
        if (std.mem.eql(u8, p, "*")) return true;
        if (std.mem.eql(u8, p, server)) return true;
    }
    return false;
}

/// What one server costs the catalog: every one of its tools' descriptions
/// plus its serialized schema. Descriptions count because they are half the
/// bill on a verbose server, and deferral shortens them too.
pub fn serverCost(all: []const mcp.Tool, server: []const u8) usize {
    var total: usize = 0;
    for (all) |t| {
        if (!std.mem.eql(u8, serverOf(t.qualified_name), server)) continue;
        total += t.description.len + jsonBytes(t.input_schema, 0);
    }
    return total;
}

/// Whether this tool is advertised with a placeholder schema instead of its
/// own. Pure: the same inputs always give the same answer, and nothing here
/// consults approvals.
pub fn isDeferred(all: []const mcp.Tool, tool: mcp.Tool) bool {
    if (!g_policy.enabled) return false;
    if (isLoaded(tool.qualified_name)) return false;
    const server = serverOf(tool.qualified_name);
    if (pinnedEager(server)) return false;
    return serverCost(all, server) > g_policy.budget;
}

pub fn anyDeferred(all: []const mcp.Tool) bool {
    for (all) |t| if (isDeferred(all, t)) return true;
    return false;
}

/// Whether a built-in spec should be dropped from the rendered root catalog.
/// `load_tool_schemas` is only useful while something is deferred, so a
/// session with no MCP (or with everything eager) is never charged for it —
/// the same "advertise only what can be used" rule #330/#352 apply.
pub fn hiddenSpec(name: []const u8, all: []const mcp.Tool) bool {
    return std.mem.eql(u8, name, tool_name) and !anyDeferred(all);
}

/// The description a deferred tool advertises: the first line (or paragraph)
/// of the real one, capped on a codepoint boundary.
pub fn shortDesc(desc: []const u8) []const u8 {
    var line = desc;
    if (std.mem.indexOfScalar(u8, line, '\n')) |nl| line = line[0..nl];
    line = std.mem.trim(u8, line, " \t\r");
    return util.utf8Prefix(line, desc_cap);
}

// --- layer 2: refuse a call whose schema was never loaded -------------------

/// Whether calling `qualified` right now must be refused. False for an eager
/// tool, for one already loaded, and for a name the registry does not know
/// (mcp.Registry.call owns that error, unchanged).
pub fn blocked(all: []const mcp.Tool, qualified: []const u8) bool {
    for (all) |t| {
        if (!std.mem.eql(u8, t.qualified_name, qualified)) continue;
        return isDeferred(all, t);
    }
    return false;
}

/// The refusal a blocked call gets: never a bare "unknown tool", always the
/// exact next action.
pub fn refusalText(gpa: Allocator, qualified: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "{s} is registered but its schema is not loaded, so it cannot be called yet. " ++
            "Call {s} with {{\"tools\": [\"{s}\"]}} first — that returns the full input schema and enables the tool " ++
            "for the rest of this session — then call {s} again with arguments matching that schema. " ++
            "This is a context-cost deferral only; it does not change approvals or trust.",
        .{ qualified, tool_name, qualified, qualified },
    );
}

// --- the load tool ---------------------------------------------------------

pub const Loaded = struct {
    text: []const u8,
    is_error: bool = false,
    /// How many tools this call newly enabled (0 for a listing or an error).
    loaded: usize = 0,
};

/// Serialize one tool as `{"name":…,"description":…,"input_schema":…}`.
fn renderEntry(arena: Allocator, tool: mcp.Tool) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("name");
    try s.write(tool.qualified_name);
    try s.objectField("description");
    try s.write(tool.description);
    try s.objectField("input_schema");
    try s.write(tool.input_schema);
    try s.endObject();
    g_renders += 1;
    return aw.writer.buffered();
}

/// Render, or reuse this session's cached render, and mark the tool enabled.
fn enable(arena: Allocator, tool: mcp.Tool) ![]const u8 {
    if (find(tool.qualified_name)) |node| return node.rendered;
    const rendered = try renderEntry(arena, tool);
    const node = try publish(arena, tool.qualified_name, rendered);
    return node.rendered;
}

/// The pure core of the `load_tool_schemas` tool: everything except touching
/// the Agent. `input` is the model-supplied argument object.
pub fn loadInto(arena: Allocator, all: []const mcp.Tool, input: Value) !Loaded {
    var wanted: std.ArrayList(usize) = .empty;
    var missing: std.ArrayList([]const u8) = .empty;

    const server = tools_mod.strField(input, "server");
    if (server) |want| {
        for (all, 0..) |t, i| if (std.mem.eql(u8, serverOf(t.qualified_name), want)) try wanted.append(arena, i);
        if (wanted.items.len == 0) try missing.append(arena, want);
    }
    if (input == .object) if (input.object.get("tools")) |list| if (list == .array) {
        for (list.array.items) |item| {
            if (item != .string) continue;
            const found = for (all, 0..) |t, i| {
                if (std.mem.eql(u8, t.qualified_name, item.string)) break i;
            } else null;
            if (found) |i| try wanted.append(arena, i) else try missing.append(arena, item.string);
        }
    };

    if (missing.items.len > 0) return .{ .text = try listing(arena, all, missing.items), .is_error = true };
    if (wanted.items.len == 0) return .{ .text = try listing(arena, all, &.{}), .is_error = false };

    var aw: Io.Writer.Allocating = .init(arena);
    var emitted: usize = 0;
    var fresh: usize = 0;
    for (wanted.items, 0..) |i, k| {
        // Named twice in one call (`server` plus its own name, say), or loaded
        // by an earlier call: neither is an error, both are the cache working.
        if (std.mem.indexOfScalar(usize, wanted.items[0..k], i) != null) continue;
        const first_time = !isLoaded(all[i].qualified_name);
        try aw.writer.print("{s}\n", .{try enable(arena, all[i])});
        emitted += 1;
        if (first_time) fresh += 1;
    }
    var head: Io.Writer.Allocating = .init(arena);
    try head.writer.print(
        "{d} tool schema(s) below are now loaded and callable for the rest of this session ({d} newly enabled). " ++
            "Call them with arguments matching input_schema.\n",
        .{ emitted, fresh },
    );
    try head.writer.writeAll(aw.writer.buffered());
    return .{ .text = head.writer.buffered(), .loaded = fresh };
}

/// What is deferred right now, names + short descriptions. Doubles as the
/// unknown-name error, which must say what DOES exist.
fn listing(arena: Allocator, all: []const mcp.Tool, unknown: []const []const u8) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    for (unknown) |name| try aw.writer.print("no deferred MCP tool or server named '{s}'. ", .{name});
    var n: usize = 0;
    for (all) |t| if (isDeferred(all, t)) {
        n += 1;
    };
    if (n == 0) {
        try aw.writer.writeAll("No MCP tool schemas are deferred: every connected tool is already callable with its full schema in your tool list.");
        return aw.writer.buffered();
    }
    try aw.writer.print("{d} MCP tool(s) are deferred — pass their names to {s} to load and enable them:\n", .{ n, tool_name });
    for (all) |t| if (isDeferred(all, t)) {
        try aw.writer.print("  {s}: {s}\n", .{ t.qualified_name, shortDesc(t.description) });
    };
    return aw.writer.buffered();
}

/// The `load_tool_schemas` meta-tool arm (agent_tools.handleMeta). Meta, not
/// external, for two reasons: it mutates the agent's OWN tool catalog, and
/// running inline on the orchestrator thread is what makes the session state
/// above single-writer.
pub fn handleLoad(agent: anytype, input: Value) ExecResult {
    if (agent.sub) return .{ .text = "load_tool_schemas is root-only; a subagent has no MCP registry of its own", .is_error = true };
    const reg = agent.registry orelse return .{ .text = "no MCP servers are connected, so there are no schemas to load", .is_error = true };
    const r = loadInto(agent.arena, reg.tools, input) catch
        return .{ .text = "load_tool_schemas failed to render the requested schemas", .is_error = true };
    // Re-render the catalog so the provider sees the real schema too, not just
    // the copy in this tool result.
    if (r.loaded > 0) {
        agent.invalidateRootTools();
        agent.ensureRootTools(agent.provider.kind) catch {};
    }
    return .{ .text = r.text, .is_error = r.is_error };
}

// --- size accounting -------------------------------------------------------

const max_depth = 32;

/// Serialized byte count of a JSON value, near enough for a budget decision
/// (escapes and float formatting are approximated). Depth-capped: the value
/// comes from an MCP server, so it is untrusted input.
pub fn jsonBytes(v: Value, depth: u8) usize {
    if (depth >= max_depth) return 0;
    return switch (v) {
        .null => 4,
        .bool => |b| if (b) @as(usize, 4) else 5,
        .integer => |i| blk: {
            var buf: [24]u8 = undefined;
            const printed = std.fmt.bufPrint(&buf, "{d}", .{i}) catch break :blk 1;
            break :blk printed.len;
        },
        .float => 8,
        .number_string => |s| s.len,
        .string => |s| s.len + 2,
        .array => |a| blk: {
            var n: usize = 2;
            for (a.items, 0..) |item, i| n += jsonBytes(item, depth + 1) + @intFromBool(i > 0);
            break :blk n;
        },
        .object => |o| blk: {
            var n: usize = 2;
            var it = o.iterator();
            var first = true;
            while (it.next()) |e| {
                n += e.key_ptr.len + 3 + jsonBytes(e.value_ptr.*, depth + 1);
                if (!first) n += 1;
                first = false;
            }
            break :blk n;
        },
    };
}
// Tests live in mcp_schema_gate_tests.zig (both files answer to the 600-line
// ceiling); the catalog-level half is in tool_schema_tests.zig, next to
// renderRootTools.
