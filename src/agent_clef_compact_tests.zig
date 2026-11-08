//! Tests for agent_clef_compact.zig (split out for the 600-line ceiling).

const std = @import("std");
const Value = std.json.Value;
const Agent = @import("agent.zig").Agent;
const clef = @import("agent_clef_compact.zig");
const archive = @import("agent_clef_archive.zig");
const compactUrl = clef.compactUrl;
const translateHistory = clef.translateHistory;
const parseDecisions = clef.parseDecisions;
const applyDecisions = clef.applyDecisions;
const eligible = clef.eligible;
const GwMessage = clef.GwMessage;
const Decision = clef.Decision;

const testing = std.testing;

test "compactUrl derives /v1/compact from chat and responses gateway URLs" {
    const a = testing.allocator;
    const chat = compactUrl(a, "https://gateway.codegraff.com/v1/chat/completions").?;
    defer a.free(chat);
    const resp = compactUrl(a, "https://gateway.codegraff.com/v1/responses").?;
    defer a.free(resp);
    try testing.expectEqualStrings("https://gateway.codegraff.com/v1/compact", chat);
    try testing.expectEqualStrings("https://gateway.codegraff.com/v1/compact", resp);
    try testing.expect(compactUrl(a, "https://example.com/no-version-here") == null);
}

test "translateHistory pairs Responses calls with outputs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const items = try std.json.parseFromSliceLeaky(Value, a,
        \\[{"role":"user","content":"fix it"},
        \\ {"type":"function_call","call_id":"c1","name":"bash","arguments":"{}"},
        \\ {"type":"function_call_output","call_id":"c1","output":"ok"}]
    , .{});
    var out: std.ArrayList(GwMessage) = .empty;
    try translateHistory(a, items.array.items, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(usize, 1), out.items[1].toolUses.items.len);
    try testing.expectEqualStrings("c1", out.items[1].toolUses.items[0].tool_use_id);
    try testing.expectEqual(@as(usize, 1), out.items[1].toolResults.items.len);
    try testing.expectEqualStrings("ok", out.items[1].toolResults.items[0].text);
}

test "parseDecisions keeps unknown actions (safety-first)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ds = try parseDecisions(a,
        \\{"model":"clef-flash","mode":"prune","messages":[],"decisions":[{"tool_use_id":"c1","action":"drop_call"},{"tool_use_id":"c2","action":"frobnicate"}],"stats":{},"usage":{}}
    );
    try testing.expectEqual(@as(usize, 2), ds.len);
    try testing.expectEqualStrings("drop_call", ds[0].action);
    try testing.expectEqualStrings("frobnicate", ds[1].action); // applied as keep
}

test "eligible: knob on + codegraff provider + key; review never" {
    const saved = clef.g_enabled;
    defer clef.g_enabled = saved;
    clef.g_enabled = true;
    var agent: Agent = undefined;
    agent.review_mode = false;
    agent.provider = .{ .id = "codegraff", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "m", .context = 100_000 };
    try testing.expect(eligible(&agent));
    agent.provider.id = "codex";
    try testing.expect(!eligible(&agent));
    agent.provider.id = "codegraff";
    agent.provider.api_key = "";
    try testing.expect(!eligible(&agent));
    agent.provider.api_key = "k";
    agent.review_mode = true;
    try testing.expect(!eligible(&agent));
    clef.g_enabled = false;
    agent.review_mode = false;
    try testing.expect(!eligible(&agent));
}

test "applyDecisions degrades a partial chat drop_call to truncation (wave-1 wedge)" {
    // One assistant message with two calls; the gateway lists only c1 for
    // drop_call. Dropping the whole message would orphan c2's result (a 400
    // on the next send); instead c1's output truncates and nothing is
    // removed.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const items = try std.json.parseFromSliceLeaky(Value, a,
        \\[{"role":"user","content":"go"},
        \\ {"role":"assistant","content":"","tool_calls":[
        \\   {"id":"c1","type":"function","function":{"name":"read","arguments":"{}"}},
        \\   {"id":"c2","type":"function","function":{"name":"read","arguments":"{}"}}]},
        \\ {"role":"tool","tool_call_id":"c1","content":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"},
        \\ {"role":"tool","tool_call_id":"c2","content":"BBBB"}]
    , .{});
    var agent: Agent = undefined;
    agent.gpa = testing.allocator;
    agent.message_mutation_arena = a;
    agent.messages = std.json.Array.init(a);
    try agent.messages.appendSlice(items.array.items);
    const ds = [_]Decision{.{ .tool_use_id = "c1", .action = "drop_call" }};
    const removed = applyDecisions(&agent, &ds, 2).removed;
    try testing.expectEqual(@as(usize, 0), removed);
    try testing.expectEqual(@as(usize, 4), agent.messages.items.len);
    // c1's output truncated in place; c2 untouched.
    try testing.expectEqualStrings("BBBB", agent.messages.items[3].object.get("content").?.string);
    const c1out = agent.messages.items[2].object.get("content").?.string;
    try testing.expect(std.mem.startsWith(u8, c1out, "AA"));
    try testing.expect(std.mem.indexOf(u8, c1out, "truncated") != null);
}

test "applyDecisions drops a fully-listed chat message with its results" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const items = try std.json.parseFromSliceLeaky(Value, a,
        \\[{"role":"user","content":"go"},
        \\ {"role":"assistant","content":"","tool_calls":[
        \\   {"id":"c1","type":"function","function":{"name":"read","arguments":"{}"}},
        \\   {"id":"c2","type":"function","function":{"name":"read","arguments":"{}"}}]},
        \\ {"role":"tool","tool_call_id":"c1","content":"AAAA"},
        \\ {"role":"tool","tool_call_id":"c2","content":"BBBB"},
        \\ {"role":"assistant","content":"done"}]
    , .{});
    var agent: Agent = undefined;
    agent.gpa = testing.allocator;
    agent.message_mutation_arena = a;
    agent.messages = std.json.Array.init(a);
    try agent.messages.appendSlice(items.array.items);
    const ds = [_]Decision{
        .{ .tool_use_id = "c1", .action = "drop_call" },
        .{ .tool_use_id = "c2", .action = "drop_call" },
    };
    const removed = applyDecisions(&agent, &ds, 2).removed;
    try testing.expectEqual(@as(usize, 3), removed);
    try testing.expectEqual(@as(usize, 2), agent.messages.items.len);
}

test "applyDecisions drops Responses pairs singly (no atomicity grouping)" {
    // Responses wire: one call per item, so a single drop_call removes
    // exactly its call + output pair even with surviving siblings.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const items = try std.json.parseFromSliceLeaky(Value, a,
        \\[{"role":"user","content":"go"},
        \\ {"type":"function_call","call_id":"c1","name":"read","arguments":"{}"},
        \\ {"type":"function_call_output","call_id":"c1","output":"AAAA"},
        \\ {"type":"function_call","call_id":"c2","name":"read","arguments":"{}"},
        \\ {"type":"function_call_output","call_id":"c2","output":"BBBB"},
        \\ {"role":"assistant","content":"done"}]
    , .{});
    var agent: Agent = undefined;
    agent.gpa = testing.allocator;
    agent.message_mutation_arena = a;
    agent.messages = std.json.Array.init(a);
    try agent.messages.appendSlice(items.array.items);
    const ds = [_]Decision{.{ .tool_use_id = "c1", .action = "drop_call" }};
    const removed = applyDecisions(&agent, &ds, 2).removed;
    try testing.expectEqual(@as(usize, 2), removed);
    try testing.expectEqual(@as(usize, 4), agent.messages.items.len);
    // c2's pair survives intact.
    try testing.expectEqualStrings("c2", agent.messages.items[1].object.get("call_id").?.string);
    try testing.expectEqualStrings("BBBB", agent.messages.items[2].object.get("output").?.string);
}

test "archive mode keeps a dropped call and archives its output (GRAFF_CLEF_ARCHIVE)" {
    const tool_spill = @import("tool_spill.zig");
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    tool_spill.resetForTest();
    defer tool_spill.resetForTest();
    tool_spill.enable(.{ .io = io, .dir = tmp.dir, .base_abs = "" });
    const saved = archive.g_enabled;
    defer archive.g_enabled = saved;
    archive.g_enabled = true;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The output must outweigh the archive stub, which embeds the artifact's
    // absolute path: a short fixture frees nothing in a deep checkout.
    const items = try std.json.parseFromSliceLeaky(Value, a,
        \\[{"role":"user","content":"go"},
        \\ {"role":"assistant","content":"","tool_calls":[
        \\   {"id":"c1","type":"function","function":{"name":"read","arguments":"{}"}}]},
        \\ {"role":"tool","tool_call_id":"c1","content":"
    ++ &@import("util.zig").repeatBytes("A", std.fs.max_path_bytes + 1024) ++
        \\Z"},
        \\ {"role":"assistant","content":"done"}]
    , .{});
    var agent: Agent = undefined;
    agent.gpa = testing.allocator;
    agent.message_mutation_arena = a;
    agent.sub = false;
    agent.session_name = "s9";
    agent.messages = std.json.Array.init(a);
    try agent.messages.appendSlice(items.array.items);
    const ds = [_]Decision{.{ .tool_use_id = "c1", .action = "drop_call" }};
    const applied = applyDecisions(&agent, &ds, 4);
    // Nothing removed: the call and its (stubbed) result both stay, so pairing holds.
    try testing.expectEqual(@as(usize, 0), applied.removed);
    try testing.expectEqual(@as(usize, 1), applied.shrunk);
    try testing.expect(applied.progressed());
    try testing.expectEqual(@as(usize, 4), agent.messages.items.len);
    const stub = agent.messages.items[2].object.get("content").?.string;
    try testing.expect(std.mem.startsWith(u8, stub, "AAAA"));
    try testing.expect(std.mem.indexOf(u8, stub, "archived by compaction") != null);
    const full = try tmp.dir.readFileAlloc(io, ".graff/sessions/s9/artifacts/tool-0.txt", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(full);
    try testing.expect(std.mem.endsWith(u8, full, "Z"));
}
