//! Deferred tool discovery listings and keyword matching for `load_tool_schemas`.
//! Split out of `mcp_schema_gate.zig` to stay under the 600-line ceiling.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const mcp = @import("mcp.zig");
const gate = @import("mcp_schema_gate.zig");
const util = @import("util.zig");

/// The description a deferred tool advertises: the first line (or paragraph)
/// of the real one, capped on a codepoint boundary.
pub fn shortDesc(desc: []const u8) []const u8 {
    var line = desc;
    if (std.mem.indexOfScalar(u8, line, '\n')) |nl| line = line[0..nl];
    line = std.mem.trim(u8, line, " \t\r");
    return util.utf8Prefix(line, gate.desc_cap);
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
pub fn matchQuery(arena: Allocator, all: []const mcp.Tool, query: []const u8) ![]usize {
    const top_k = 8;
    var best: [top_k]struct { score: usize, idx: usize } = undefined;
    var n_best: usize = 0;
    for (all, 0..) |t, i| {
        if (!gate.isDeferred(all, t)) continue;
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
    // as the MCP half — stable mode lists by policy, never by load state,
    // while session-disabled/gated natives stay out (#492).
    const natives = try @import("native_fold.zig").advertisedFolded(arena);
    if (!gate.anyDeferred(all) and natives.len == 0) return gate.tool_desc;
    // Stable-catalog mode lists by POLICY, not load state: a listing that
    // shrinks as tools load would change the prefix this mode exists to fix.
    const deferredRule: *const fn ([]const mcp.Tool, mcp.Tool) bool = if (gate.g_stable_catalog) &gate.policyDeferred else &gate.isDeferred;
    var servers: std.ArrayList([]const u8) = .empty;
    for (all) |t| {
        if (gate.omitMcp(t.qualified_name)) continue;
        if (!deferredRule(all, t)) continue;
        const sv = t.serverName();
        const seen = for (servers.items) |s| {
            if (std.mem.eql(u8, s, sv)) break true;
        } else false;
        if (!seen) try servers.append(arena, sv);
    }
    var aw: Io.Writer.Allocating = .init(arena);
    try aw.writer.writeAll(gate.tool_desc);
    if (natives.len > 0) {
        try aw.writer.writeAll(" Folded native:");
        for (natives, 0..) |name, i| try aw.writer.print("{s}{s}", .{ if (i == 0) " " else ", ", name });
        try aw.writer.writeAll(";");
    }
    if (servers.items.len > 0) try aw.writer.writeAll(" Deferred now:");
    for (servers.items) |sv| {
        try aw.writer.print(" {s} (", .{sv});
        var first = true;
        for (all) |t| {
            if (gate.omitMcp(t.qualified_name)) continue;
            if (!deferredRule(all, t)) continue;
            if (!std.mem.eql(u8, t.serverName(), sv)) continue;
            if (!first) try aw.writer.writeAll(", ");
            try aw.writer.writeAll(shortName(t.qualified_name));
            first = false;
        }
        try aw.writer.writeAll(");");
    }
    return @import("context_limits.zig").applySectionAlloc(arena, "MCP tool catalog", aw.writer.buffered(), @import("context_limits.zig").mcp_schema_bytes, "call deferred tools directly or raise --context-limit mcp_schema_bytes=N");
}

/// What is deferred right now, names + short descriptions. Doubles as the
/// unknown-name error, which must say what DOES exist.
pub fn listing(arena: Allocator, all: []const mcp.Tool, unknown: []const []const u8) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    for (unknown) |name| try aw.writer.print("no deferred MCP tool or server named '{s}'. ", .{name});
    var n: usize = 0;
    for (all) |t| if (gate.isDeferred(all, t)) {
        n += 1;
    };
    if (n == 0) {
        try aw.writer.writeAll("No MCP tool schemas are deferred: every connected tool is already callable with its full schema in your tool list.");
        return aw.writer.buffered();
    }
    try aw.writer.print("{d} MCP tool(s) are deferred — pass their names to {s} to load and enable them:\n", .{ n, gate.tool_name });
    for (all) |t| if (gate.isDeferred(all, t)) {
        try aw.writer.print("  {s}: {s}\n", .{ t.qualified_name, shortDesc(t.description) });
    };
    return aw.writer.buffered();
}
