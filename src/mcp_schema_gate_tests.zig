//! #416 coverage for the two-phase MCP tool exposure in mcp_schema_gate.zig,
//! split out of it to keep both files inside the 600-line ceiling. The
//! catalog-level half — what a provider actually receives, and the token
//! saving it buys — lives in tool_schema_tests.zig, next to renderRootTools.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const mcp = @import("mcp.zig");
const mcp_config = @import("mcp_config.zig");
const gate = @import("mcp_schema_gate.zig");

const testing = std.testing;

/// A fixture server: `count` tools whose schemas carry `padding` bytes of
/// property description each, so a test can put a server either side of the
/// budget on purpose.
pub fn fixture(arena: Allocator, server: []const u8, count: usize, padding: usize) ![]mcp.Tool {
    const out = try arena.alloc(mcp.Tool, count);
    for (out, 0..) |*t, i| {
        const filler = try arena.alloc(u8, padding);
        @memset(filler, 'x');
        var inner: std.json.ObjectMap = .empty;
        try inner.put(arena, "type", .{ .string = "string" });
        try inner.put(arena, "description", .{ .string = filler });
        var props: std.json.ObjectMap = .empty;
        try props.put(arena, "q", .{ .object = inner });
        var schema: std.json.ObjectMap = .empty;
        try schema.put(arena, "type", .{ .string = "object" });
        try schema.put(arena, "properties", .{ .object = props });
        t.* = .{
            .server_index = 0,
            .original_name = try std.fmt.allocPrint(arena, "t{d}", .{i}),
            .qualified_name = try std.fmt.allocPrint(arena, "mcp__{s}__t{d}", .{ server, i }),
            .description = "first line of the description\nsecond line nobody needs up front",
            .input_schema = .{ .object = schema },
        };
    }
    return out;
}

/// Every test here mutates module state; none may leak into the next.
pub fn withDefaults() void {
    gate.reset();
    gate.g_policy = .{};
}

test "serverOf splits the qualified name, and tolerates one that is not qualified" {
    try testing.expectEqualStrings("deepwiki", gate.serverOf("mcp__deepwiki__ask_question"));
    try testing.expectEqualStrings("s", gate.serverOf("mcp__s__t"));
    try testing.expectEqualStrings("", gate.serverOf("bash"));
    try testing.expectEqualStrings("lonely", gate.serverOf("mcp__lonely"));
}

test "jsonBytes tracks the real serialized size closely enough to budget with" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src = "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"string\"}},\"required\":[\"a\"],\"n\":12,\"ok\":true}";
    const v = try std.json.parseFromSliceLeaky(Value, arena, src, .{ .allocate = .alloc_always });
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(v);
    const actual = aw.writer.buffered().len;
    const estimate = gate.jsonBytes(v, 0);
    // Within 10% of the bytes std.json actually emits, in both directions.
    try testing.expect(estimate + actual / 10 >= actual);
    try testing.expect(estimate <= actual + actual / 10);
}

test "every server defers by default; the budget knob restores size-based eagerness (#476)" {
    withDefaults();
    defer withDefaults();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Universal deferral: even a tiny server ships placeholders by default.
    const small = try fixture(arena, "small", 2, 40);
    try testing.expect(gate.serverCost(small, "small") > gate.default_budget);
    for (small) |t| try testing.expect(gate.isDeferred(small, t));
    try testing.expect(gate.anyDeferred(small));

    // The old size-based policy stays reachable via GRAFF_MCP_SCHEMA_BUDGET.
    gate.g_policy.budget = 4096;
    try testing.expect(gate.serverCost(small, "small") <= gate.g_policy.budget);
    for (small) |t| try testing.expect(!gate.isDeferred(small, t));
    try testing.expect(!gate.anyDeferred(small));

    const fat = try fixture(arena, "fat", 8, 2000);
    try testing.expect(gate.serverCost(fat, "fat") > gate.g_policy.budget);
    for (fat) |t| try testing.expect(gate.isDeferred(fat, t));
    try testing.expect(gate.anyDeferred(fat));
}

test "the eager pin and the off switch both bypass deferral entirely" {
    withDefaults();
    defer withDefaults();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fat = try fixture(arena, "fat", 8, 2000);
    const other = try fixture(arena, "other", 8, 2000);

    gate.g_policy.eager = &.{"fat"};
    for (fat) |t| try testing.expect(!gate.isDeferred(fat, t));
    // A pin names ONE server; a sibling over the budget is still deferred.
    try testing.expect(gate.isDeferred(other, other[0]));

    gate.g_policy.eager = &.{"*"};
    for (fat) |t| try testing.expect(!gate.isDeferred(fat, t));
    try testing.expect(!gate.isDeferred(other, other[0]));

    gate.g_policy = .{ .enabled = false };
    for (fat) |t| try testing.expect(!gate.isDeferred(fat, t));

    // A budget of 0 is the opposite extreme: defer everything.
    gate.g_policy = .{ .budget = 0 };
    const small = try fixture(arena, "small", 1, 4);
    try testing.expect(gate.isDeferred(small, small[0]));
}

const Env = struct {
    vals: []const [2][]const u8,
    pub fn get(self: @This(), key: []const u8) ?[]const u8 {
        for (self.vals) |kv| if (std.mem.eql(u8, kv[0], key)) return kv[1];
        return null;
    }
};

test "configure reads the env knobs and the per-server eager flag" {
    withDefaults();
    defer withDefaults();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = try std.json.parseFromSliceLeaky(Value, arena,
        \\{"pinned":{"command":"./a","eager":true},"lazy":{"command":"./b"},"off":{"command":"./c","eager":false}}
    , .{ .allocate = .alloc_always });
    const merged: mcp_config.Merged = .{ .servers = cfg.object };

    gate.configure(arena, merged, Env{ .vals = &.{
        .{ gate.env_budget, "1234" },
        .{ gate.env_eager, "one, two ,,three" },
    } });
    try testing.expect(gate.g_policy.enabled);
    try testing.expectEqual(@as(usize, 1234), gate.g_policy.budget);
    // Three names from the env plus the one config entry that opted in.
    try testing.expectEqual(@as(usize, 4), gate.g_policy.eager.len);
    try testing.expect(gate.pinnedEager("three"));
    try testing.expect(gate.pinnedEager("pinned"));
    try testing.expect(!gate.pinnedEager("lazy"));
    try testing.expect(!gate.pinnedEager("off"));

    gate.configure(arena, .{}, Env{ .vals = &.{.{ gate.env_enabled, "0" }} });
    try testing.expect(!gate.g_policy.enabled);
    try testing.expectEqual(gate.default_budget, gate.g_policy.budget);

    // A junk budget falls back rather than failing the session over a typo.
    gate.configure(arena, .{}, Env{ .vals = &.{.{ gate.env_budget, "soon" }} });
    try testing.expectEqual(gate.default_budget, gate.g_policy.budget);
}

test "shortDesc keeps one capped line and never splits a codepoint" {
    try testing.expectEqualStrings("one line", gate.shortDesc("one line\nand more\nand more"));
    // Built with a comptime loop rather than `**`, which the CI compiler
    // rejects however it is spaced: 600 bytes of "é", so a naive cap would
    // land mid-codepoint.
    const long_arr = comptime blk: {
        var buf: [600]u8 = undefined;
        var i: usize = 0;
        while (i < buf.len) : (i += 2) {
            buf[i] = 0xC3;
            buf[i + 1] = 0xA9;
        }
        break :blk buf;
    };
    const short = gate.shortDesc(&long_arr);
    try testing.expect(short.len <= gate.desc_cap);
    try testing.expect(std.unicode.utf8ValidateSlice(short));
}

test "load_tool_schemas returns the full schemas and enables the tools" {
    withDefaults();
    defer withDefaults();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fat = try fixture(arena, "fat", 4, 2000);

    // Before: every tool blocked, with an actionable refusal.
    try testing.expect(gate.blocked(fat, "mcp__fat__t0"));
    const refusal = try gate.refusalText(testing.allocator, "mcp__fat__t0");
    defer testing.allocator.free(refusal);
    try testing.expect(std.mem.indexOf(u8, refusal, gate.tool_name) != null);
    try testing.expect(std.mem.indexOf(u8, refusal, "mcp__fat__t0") != null);
    try testing.expect(std.mem.indexOf(u8, refusal, "does not change approvals") != null);
    try testing.expect(std.mem.indexOf(u8, refusal, "unknown") == null); // never a bare unknown-tool

    const req = try std.json.parseFromSliceLeaky(Value, arena, "{\"tools\":[\"mcp__fat__t0\"]}", .{ .allocate = .alloc_always });
    const r = try gate.loadInto(arena, fat, req);
    try testing.expect(!r.is_error);
    try testing.expectEqual(@as(usize, 1), r.loaded);
    try testing.expect(std.mem.indexOf(u8, r.text, "\"input_schema\":{\"type\":\"object\",\"properties\"") != null);
    try testing.expect(std.mem.indexOf(u8, r.text, "second line nobody needs up front") != null); // the FULL description

    // After: that tool is callable, and only that one.
    try testing.expect(gate.isLoaded("mcp__fat__t0"));
    try testing.expect(!gate.blocked(fat, "mcp__fat__t0"));
    try testing.expect(!gate.isDeferred(fat, fat[0]));
    try testing.expect(gate.blocked(fat, "mcp__fat__t1"));
}

test "schemas are cached per session: a repeat load re-serializes nothing" {
    withDefaults();
    defer withDefaults();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fat = try fixture(arena, "fat", 4, 2000);
    const req = try std.json.parseFromSliceLeaky(Value, arena, "{\"server\":\"fat\"}", .{ .allocate = .alloc_always });

    const first = try gate.loadInto(arena, fat, req);
    try testing.expectEqual(@as(usize, 4), first.loaded);
    try testing.expectEqual(@as(usize, 4), gate.rendersForTest());

    const second = try gate.loadInto(arena, fat, req);
    try testing.expectEqual(@as(usize, 0), second.loaded); // already enabled
    try testing.expectEqual(@as(usize, 4), gate.rendersForTest()); // and nothing re-serialized
    const body = struct {
        fn of(t: []const u8) []const u8 {
            return t[std.mem.indexOfScalar(u8, t, '\n').?..];
        }
    }.of;
    try testing.expectEqualStrings(body(first.text), body(second.text));
}

test "one tool named twice in a call is emitted once, not duplicated" {
    withDefaults();
    defer withDefaults();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fat = try fixture(arena, "fat", 2, 2000);
    // `server` selects both tools, then `tools` names one of them again.
    const req = try std.json.parseFromSliceLeaky(Value, arena,
        \\{"server":"fat","tools":["mcp__fat__t0"]}
    , .{ .allocate = .alloc_always });
    const r = try gate.loadInto(arena, fat, req);
    try testing.expect(!r.is_error);
    try testing.expectEqual(@as(usize, 2), r.loaded);
    try testing.expect(std.mem.startsWith(u8, r.text, "2 tool schema(s) below"));
    // Exactly one entry per tool, and only two entries in total.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, r.text, "\"name\":\"mcp__fat__t"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.text, "\"name\":\"mcp__fat__t0\""));
    try testing.expectEqual(@as(usize, 2), gate.rendersForTest());
}

test "query mode: keywords load the matching deferred tools, a miss lists what exists" {
    withDefaults();
    defer withDefaults();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fat = try fixture(arena, "fat", 3, 2000);

    const hit = try std.json.parseFromSliceLeaky(Value, arena, "{\"query\":\"first line\"}", .{ .allocate = .alloc_always });
    const loaded = try gate.loadInto(arena, fat, hit);
    try testing.expect(!loaded.is_error);
    try testing.expect(loaded.loaded > 0);
    for (fat) |t| try testing.expect(!gate.isDeferred(fat, t)); // all matched + enabled
    try testing.expect(std.mem.indexOf(u8, loaded.text, "input_schema") != null); // full schemas ride the result

    gate.reset();
    const miss = try std.json.parseFromSliceLeaky(Value, arena, "{\"query\":\"zzqqx\"}", .{ .allocate = .alloc_always });
    const none = try gate.loadInto(arena, fat, miss);
    try testing.expect(none.is_error);
    try testing.expect(std.mem.startsWith(u8, none.text, "no deferred tool matched query 'zzqqx'."));
    try testing.expect(std.mem.indexOf(u8, none.text, "mcp__fat__t0") != null); // the listing follows
}

test "an unknown name errors and lists what is actually deferred; no args just lists" {
    withDefaults();
    defer withDefaults();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fat = try fixture(arena, "fat", 3, 2000);

    const bad = try std.json.parseFromSliceLeaky(Value, arena, "{\"tools\":[\"mcp__fat__nope\"]}", .{ .allocate = .alloc_always });
    const err = try gate.loadInto(arena, fat, bad);
    try testing.expect(err.is_error);
    try testing.expectEqual(@as(usize, 0), err.loaded);
    try testing.expect(std.mem.startsWith(u8, err.text, "no deferred MCP tool or server named 'mcp__fat__nope'."));
    try testing.expect(std.mem.indexOf(u8, err.text, "mcp__fat__t0: first line of the description\n") != null);

    const none = try std.json.parseFromSliceLeaky(Value, arena, "{}", .{ .allocate = .alloc_always });
    const list = try gate.loadInto(arena, fat, none);
    try testing.expect(!list.is_error);
    try testing.expect(std.mem.startsWith(u8, list.text, "3 MCP tool(s) are deferred"));
    // A listing must not smuggle the schemas back in — that is the whole point.
    try testing.expect(std.mem.indexOf(u8, list.text, "input_schema") == null);
    try testing.expect(std.mem.indexOf(u8, list.text, "second line nobody needs up front") == null);

    // Nothing deferred at all: say so rather than printing an empty list.
    // (Reachable via the budget knob now that every server defers by default.)
    gate.g_policy.budget = 4096;
    const small = try fixture(arena, "small", 1, 4);
    const quiet = try gate.loadInto(arena, small, none);
    try testing.expect(!quiet.is_error);
    try testing.expect(std.mem.startsWith(u8, quiet.text, "No MCP tool schemas are deferred"));
}

test "an eager tool is never blocked, and the load tool is advertised only when needed" {
    withDefaults();
    defer withDefaults();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const small = try fixture(arena, "small", 2, 40);
    gate.g_policy.budget = 4096; // make "small" eager explicitly — the default defers everything (#476)
    try testing.expect(!gate.blocked(small, "mcp__small__t0"));
    try testing.expect(!gate.hiddenSpec("bash", small)); // only the load tool is ever hidden
    try testing.expect(gate.hiddenSpec(gate.tool_name, small)); // nothing deferred -> not advertised

    const fat = try fixture(arena, "fat", 8, 2000);
    try testing.expect(!gate.hiddenSpec(gate.tool_name, fat));
    // A name no server advertises stays mcp.Registry.call's problem, not ours.
    try testing.expect(!gate.blocked(fat, "mcp__fat__ghost"));
}

test "tool_desc stays JSON-escape-free (it is spliced into a raw schema string)" {
    for (gate.tool_desc) |c| try testing.expect(c != '"' and c != '\\' and c >= 0x20);
    try testing.expect(std.mem.indexOf(u8, gate.tool_desc, "CANNOT be called") != null);
    try testing.expect(std.mem.indexOf(u8, gate.tool_desc, "mcp__server__tool") != null);
    var parsed = try std.json.parseFromSlice(Value, testing.allocator, gate.tool_schema, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("properties").?.object.get("tools") != null);
    var ph = try std.json.parseFromSlice(Value, testing.allocator, gate.placeholder_schema, .{});
    defer ph.deinit();
    try testing.expectEqualStrings("object", ph.value.object.get("type").?.string);
}
