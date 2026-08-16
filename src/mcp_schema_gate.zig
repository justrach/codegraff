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
//!  - **Deferral is universal.** Every server's tools ship as placeholders
//!    until `load_tool_schemas` unfolds them — the measured interactive
//!    anatomy (#476) is that most sessions never call most servers, so eager
//!    bytes are re-sent cost with no payoff, and discovery has proven
//!    reliable. `GRAFF_MCP_SCHEMA_BUDGET` restores the old size-based
//!    threshold; `GRAFF_MCP_EAGER` pins specific servers either way.
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
/// a server is served eagerly. Zero by default: EVERY server defers. The old
/// 4 KiB threshold assumed the load round trip was a wash below ~1,000 tokens,
/// but that only holds for sessions that call the tool — the measured
/// interactive anatomy (#476) is that most sessions never touch most servers,
/// so eager bytes are pure re-sent cost and discovery via load_tool_schemas
/// has proven reliable (the codedbpro pin removal shipped with zero discovery
/// turns). GRAFF_MCP_SCHEMA_BUDGET restores a size threshold;
/// GRAFF_MCP_EAGER pins specific servers.
pub const default_budget: usize = 0;

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
pub const tool_desc = "Load the full JSON input schemas for deferred tools and enable them for the rest of this session. Deferred tools — MCP and folded native — ship without their schemas so those bytes stay out of every request; what is deferred right now is listed at the end of this description. A tool whose schema has not been loaded CANNOT be called: load it first. Pass tools with exact names (mcp__server__tool for MCP, a bare name like workflow for native), server to load one whole MCP server, or query with keywords to search deferred tools; no arguments lists everything deferred. Loading is permanent for this session and free to repeat.";
pub const tool_schema =
    \\{"type": "object", "properties": {"tools": {"type": "array", "items": {"type": "string"}, "description": "Exact qualified MCP tool names to load, e.g. mcp__deepwiki__ask_question"}, "server": {"type": "string", "description": "Load every deferred tool on this MCP server instead of naming them one by one"}, "query": {"type": "string", "description": "Search deferred tools by keyword (matches name and description, loads the top 8 matches) — use when you know what you need but not the exact tool name"}}}
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

/// GRAFF_STABLE_CATALOG=1 experiment (#476): a loaded tool's schema rides the
/// load_tool_schemas RESULT in the conversation, so the catalog does not need
/// to re-render it — skipping policy-deferred tools even after load keeps the
/// request prefix byte-identical all session, which is what provider prefix
/// caching charges against. Every load otherwise busts the cache (measured:
/// 0% cache on the calls right after each load).
pub var g_stable_catalog = false;

/// Deferred by POLICY, ignoring load state — the stable-catalog render rule
/// and (in stable mode) the listing, which must not change as tools load.
pub fn policyDeferred(all: []const mcp.Tool, tool: mcp.Tool) bool {
    if (!g_policy.enabled) return false;
    const server = serverOf(tool.qualified_name);
    if (pinnedEager(server)) return false;
    return serverCost(all, server) > g_policy.budget;
}

// --- session state: which schemas have been loaded -------------------------

const Node = struct {
    name: []const u8,
    /// The rendered `{"name":…,"description":…,"input_schema":…}` block, kept
    /// so a repeated load is a pointer copy rather than a re-serialization.
    /// This is the per-session schema cache the issue asks for.
    rendered: []const u8,
    /// Load order (0 = never loaded): the stable-catalog tail appends in this
    /// order so a new load changes only the catalog's tail bytes (#476).
    seq: usize,
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
    node.* = .{ .name = try arena.dupe(u8, name), .rendered = rendered, .seq = nextSeq(), .next = g_head.load(.acquire) };
    g_head.store(node, .release);
    return node;
}

var g_seq: usize = 0;
fn nextSeq() usize {
    g_seq += 1;
    return g_seq;
}

/// A loaded tool's position in load order; null when not loaded. schema.zig's
/// stable-catalog tail sorts by this so loads are append-only.
pub fn loadSeq(qualified: []const u8) ?usize {
    var cur = g_head.load(.acquire);
    while (cur) |n| : (cur = n.next) if (std.mem.eql(u8, n.name, qualified)) return n.seq;
    return null;
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

/// exec.zig's MCP dispatch calls this where it used to refuse: a confident
/// call to a deferred tool renders + publishes its schema and proceeds (user
/// direction — same rule as the native fold's markIfFolded). The catalog's
/// zero-stub listing is unchanged; the call itself was already provider-legal.
pub fn autoLoad(arena: Allocator, all: []const mcp.Tool, qualified: []const u8) void {
    if (!blocked(all, qualified)) return;
    for (all) |t| {
        if (std.mem.eql(u8, t.qualified_name, qualified)) {
            _ = enable(arena, t) catch {};
            return;
        }
    }
}

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
    // codex tool_search pattern: keyword discovery when the exact name is not
    // known — top matches join `wanted` and load exactly like named tools.
    if (tools_mod.strField(input, "query")) |q| {
        const matched = try matchQuery(arena, all, q);
        if (matched.len == 0) {
            const rest = try listing(arena, all, &.{});
            return .{ .text = try std.fmt.allocPrint(arena, "no deferred tool matched query '{s}'. {s}", .{ q, rest }), .is_error = true };
        }
        for (matched) |i| try wanted.append(arena, i);
    }

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

/// The short tool name within its server: mcp__codedbpro__read -> read.
fn shortName(qualified: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, qualified, "mcp__")) return qualified;
    const rest = qualified[5..];
    const sep = std.mem.indexOf(u8, rest, "__") orelse return qualified;
    return rest[sep + 2 ..];
}

/// Case-insensitive substring search (std.ascii has no indexOfIgnoreCase in
/// this toolchain): windowed eqlIgnoreCase, fine at description sizes.
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1)
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    return false;
}

/// Keyword search over deferred tools (the load tool's `query` arm): score
/// each deferred tool by how many query tokens appear, case-insensitively, in
/// its qualified name or description; return the top 8, best first. A token
/// that matches nothing simply does not score — there is no fuzzier fallback,
/// because the no-match path returns the full deferred listing anyway.
fn matchQuery(arena: Allocator, all: []const mcp.Tool, query: []const u8) ![]usize {
    const top_k = 8;
    var best: [top_k]struct { score: usize, idx: usize } = undefined;
    var n_best: usize = 0;
    for (all, 0..) |t, i| {
        if (!isDeferred(all, t)) continue;
        var score: usize = 0;
        var tok = std.mem.tokenizeAny(u8, query, " \t,;:/_-");
        while (tok.next()) |w| {
            if (w.len < 2) continue;
            if (containsIgnoreCase(t.qualified_name, w) or containsIgnoreCase(t.description, w)) score += 1;
        }
        if (score == 0) continue;
        if (n_best < top_k) {
            best[n_best] = .{ .score = score, .idx = i };
            n_best += 1;
        } else {
            // Replace the weakest entry when this one beats it.
            var weakest: usize = 0;
            for (best[0..n_best], 0..) |b, k| if (b.score < best[weakest].score) {
                weakest = k;
            };
            if (score <= best[weakest].score) continue;
            best[weakest] = .{ .score = score, .idx = i };
        }
    }
    const out = try arena.alloc(usize, n_best);
    // Selection-sort descending so the strongest match loads first.
    for (out, 0..) |*slot, k| {
        var top: usize = 0;
        for (best[0..n_best], 0..) |b, j| if (b.score > best[top].score) {
            top = j;
        };
        slot.* = best[top].idx;
        best[top].score = 0;
        _ = k;
    }
    return out;
}

/// The load tool's live catalog description: the static base plus, while
/// anything is deferred, a compact source listing (server: short tool names).
/// Deferred tools ship NO per-tool catalog entries of their own — this
/// listing is how the model learns what exists (codex's tool_search source
/// listing), and `query` covers discovery beyond it (#476).
pub fn descWithListing(arena: Allocator, all: []const mcp.Tool) ![]const u8 {
    // Folded NATIVES ride this listing too (#476, the schema.zig zero-stub
    // rule): their names live here, once, instead of a static enumeration
    // every session re-pays after the tools load. Same stable-catalog rule
    // as the MCP half — stable mode lists by policy, never by load state.
    const native_fold = @import("native_fold.zig");
    var natives: std.ArrayList([]const u8) = .empty;
    if (native_fold.anyFolded()) {
        for (native_fold.folded) |name| {
            if (!g_stable_catalog and native_fold.isLoaded(name)) continue;
            try natives.append(arena, name);
        }
    }
    if (!anyDeferred(all) and natives.items.len == 0) return tool_desc;
    // Stable-catalog mode lists by POLICY, not load state: a listing that
    // shrinks as tools load would change the prefix this mode exists to fix.
    const deferredRule: *const fn ([]const mcp.Tool, mcp.Tool) bool = if (g_stable_catalog) &policyDeferred else &isDeferred;
    var servers: std.ArrayList([]const u8) = .empty;
    for (all) |t| {
        if (!deferredRule(all, t)) continue;
        const sv = serverOf(t.qualified_name);
        const seen = for (servers.items) |s| {
            if (std.mem.eql(u8, s, sv)) break true;
        } else false;
        if (!seen) try servers.append(arena, sv);
    }
    var aw: Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll(tool_desc);
    if (natives.items.len > 0) {
        try aw.writer.writeAll(" Folded native:");
        for (natives.items, 0..) |name, i| try aw.writer.print("{s}{s}", .{ if (i == 0) " " else ", ", name });
        try aw.writer.writeAll(";");
    }
    if (servers.items.len > 0) try aw.writer.writeAll(" Deferred now:");
    for (servers.items) |sv| {
        try aw.writer.print(" {s} (", .{sv});
        var first = true;
        for (all) |t| {
            if (!deferredRule(all, t)) continue;
            if (!std.mem.eql(u8, serverOf(t.qualified_name), sv)) continue;
            if (!first) try aw.writer.writeAll(", ");
            try aw.writer.writeAll(shortName(t.qualified_name));
            first = false;
        }
        try aw.writer.writeAll(");");
    }
    return aw.writer.buffered();
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

/// Body in util.zig (600-line cap); re-exported so serverCost and the tests
/// keep naming this module.
pub const jsonBytes = util.jsonBytes;
// Tests live in mcp_schema_gate_tests.zig (both files answer to the 600-line
// ceiling); the catalog-level half is in tool_schema_tests.zig, next to
// renderRootTools.
