//! White-box tests for agent_server_compact.zig, parked here under the
//! 600-line ceiling (same pattern as router_catalog_tests.zig).

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const main_mod = @import("main.zig");
const Agent = @import("agent.zig").Agent;
const Provider = @import("provider.zig").Provider;
const provider = @import("provider.zig");
const asc = @import("agent_server_compact.zig");
const enabled = asc.enabled;
const noteExposure = asc.noteExposure;
const noteClientSummary = asc.noteClientSummary;
const writeContextManagement = asc.writeContextManagement;
const writeContextManagementBody = asc.writeContextManagementBody;
const manualRoute = asc.manualRoute;
const manualServerEligible = asc.manualServerEligible;
const compactEndpoint = asc.compactEndpoint;
const compactBody = asc.compactBody;
const installCompactedOutput = asc.installCompactedOutput;
const installInStreamCompaction = asc.installInStreamCompaction;
const manualCompact = asc.manualCompact;
const pruneToLatestBlob = asc.pruneToLatestBlob;
const pruneIf = asc.pruneIf;
const autocompact = asc.autocompact;
const autocompactIf = asc.autocompactIf;
const explicitCompact = asc.explicitCompact;
const installCompactionItem = asc.installCompactionItem;
const ManualRoute = asc.ManualRoute;
const test_support = @import("agent_compact_test_support.zig");

fn testAgent(a: std.mem.Allocator, kind: Provider.Kind) Agent {
    var agent = test_support.subAgent(a, false);
    agent.provider.kind = kind;
    agent.gpa = a;
    agent.out = null;
    agent.label = "t";
    agent.goal_note_fp = 0;
    agent.history_rewrites = 0;
    agent.messages = std.json.Array.init(a);
    return agent;
}

fn item(a: std.mem.Allocator, typ: []const u8, call_id: ?[]const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "type", .{ .string = typ });
    if (call_id) |c| try obj.put(a, "call_id", .{ .string = c });
    return .{ .object = obj };
}

test "manual server compaction routes direct OpenAI, Codegraff, and Codex" {
    var p: Provider = .{ .id = "openai", .kind = .responses, .auth = .bearer, .url = "https://api.openai.com/v1/responses", .api_key = "k", .model = "m", .context = 272_000 };
    try std.testing.expectEqual(ManualRoute.standalone, manualRoute(p));
    p.id = "codegraff";
    p.url = "https://gateway.codegraff.com/v1/responses";
    p.model = "gpt-6-astra";
    try std.testing.expectEqual(ManualRoute.standalone, manualRoute(p));
    try std.testing.expect(manualServerEligible(p));
    p.model = "gpt-5.6-sol";
    try std.testing.expectEqual(ManualRoute.standalone, manualRoute(p));
    p.model = "grok-4.6";
    try std.testing.expectEqual(ManualRoute.local, manualRoute(p));
    try std.testing.expect(!manualServerEligible(p));
    p.id = "xai";
    p.model = "grok-4.6";
    try std.testing.expectEqual(ManualRoute.local, manualRoute(p));
    try std.testing.expect(!manualServerEligible(p));
    try std.testing.expect(p.serverCompactUrl() == null);
    p.id = "codex";
    try std.testing.expectEqual(ManualRoute.in_stream, manualRoute(p));
    try std.testing.expect(manualServerEligible(p));
    p.id = "openai-compatible-router";
    try std.testing.expectEqual(ManualRoute.local, manualRoute(p));
    p.id = "openai";
    p.kind = .openai;
    try std.testing.expect(!manualServerEligible(p));
    p.kind = .anthropic;
    try std.testing.expect(!manualServerEligible(p));
}

test "manual compact endpoint appends compact and rejects non-Responses URLs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("http://127.0.0.1:8765/responses/compact", try compactEndpoint(a, "http://127.0.0.1:8765/responses"));
    try std.testing.expectError(error.UnsupportedServerCompaction, compactEndpoint(a, "http://127.0.0.1:8765/chat/completions"));
}

test "manual compact body sends model, canonical Responses input, and instructions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    agent.provider.model = "gpt-test";
    agent.sys_normal = "system-test";
    try agent.messages.append(try item(a, "message", null));
    const body = try compactBody(&agent);
    defer a.free(body);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    try std.testing.expectEqualStrings("gpt-test", parsed.object.get("model").?.string);
    try std.testing.expectEqualStrings("system-test", parsed.object.get("instructions").?.string);
    try std.testing.expectEqual(@as(usize, 1), parsed.object.get("input").?.array.items.len);
}

test "installCompactedOutput transactionally replaces history and resets meters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    try agent.messages.append(try item(a, "message", null));
    agent.last_context_tokens = 99;
    agent.context_local_tokens = 88;
    agent.goal_note_fp = 77;
    const invalid = std.json.Value{ .object = .empty };
    try std.testing.expectError(error.InvalidCompactionResponse, installCompactedOutput(&agent, invalid));
    try std.testing.expectError(error.InvalidCompactionResponse, installInStreamCompaction(&agent, .empty));
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);

    var output = std.json.Array.init(a);
    try output.append(try item(a, "message", null));
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "output", .{ .array = output });
    try std.testing.expectError(error.MissingCompactionItem, installInStreamCompaction(&agent, obj));
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);
    try output.append(try item(a, "compaction", null));
    try output.append(try item(a, "message", null));
    try obj.put(a, "output", .{ .array = output });
    try std.testing.expectEqual(@as(usize, 3), try installCompactedOutput(&agent, .{ .object = obj }));
    try std.testing.expectEqual(@as(usize, 3), agent.messages.items.len);
    try std.testing.expectEqual(@as(usize, 1), try installInStreamCompaction(&agent, obj));
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);
    try std.testing.expectEqualStrings("compaction", agent.messages.items[0].object.get("type").?.string);
    try std.testing.expectEqual(@as(u64, 0), agent.last_context_tokens);
    try std.testing.expectEqual(@as(u64, 0), agent.context_local_tokens);
    try std.testing.expectEqual(@as(u64, 0), agent.goal_note_fp);
    try std.testing.expectEqual(@as(u64, 2), agent.history_rewrites);
}

test "enabled: responses-only; server is the default; override wins" {
    var p: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "k", .model = "m", .context = 272_000 };
    try std.testing.expect(enabled(p)); // server arm by default
    p.kind = .anthropic;
    try std.testing.expect(!enabled(p));
    p.kind = .openai;
    try std.testing.expect(!enabled(p));
    p.kind = .responses;
    p.id = "openai";
    try std.testing.expect(enabled(p));
    p.id = "kilo"; // third-party Responses hosts keep the local summary
    try std.testing.expect(!enabled(p));
    p.id = "xai";
    try std.testing.expect(!enabled(p)); // client summarizer, not xAI blob
    p.id = "codegraff";
    p.model = "gpt-6-astra";
    try std.testing.expect(enabled(p)); // GPT-5.6+ on the gateway uses /responses/compact
    p.kind = .openai;
    try std.testing.expect(!enabled(p));
    p.kind = .responses;
    p.id = "codex";
    asc.g_server_compact_override = false;
    try std.testing.expect(!enabled(p));
    asc.g_server_compact_override = true;
    try std.testing.expect(enabled(p));
    asc.g_server_compact_override = null;
}

test "writeContextManagement: automatic threshold and forced Codex pass stay OpenAI-only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    var aw: @import("std").Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try writeContextManagementBody(&s, 80_000);
    try s.endObject();
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"compact_threshold\":80000") != null);
    agent.provider.id = "codex";
    agent.server_compaction_request = true;
    var aw2: @import("std").Io.Writer.Allocating = .init(a);
    var s2: std.json.Stringify = .{ .writer = &aw2.writer };
    try s2.beginObject();
    try writeContextManagement(&agent, &s2);
    try s2.endObject();
    try std.testing.expect(std.mem.indexOf(u8, aw2.written(), "\"compact_threshold\":1000") != null);
    agent.provider.id = "openai-compatible-router";
    var aw3: @import("std").Io.Writer.Allocating = .init(a);
    var s3: std.json.Stringify = .{ .writer = &aw3.writer };
    try s3.beginObject();
    try writeContextManagement(&agent, &s3);
    try s3.endObject();
    try std.testing.expectEqualStrings("{}", aw3.written());
}

test "pruneToLatestBlob: no blob or blob-first leaves history untouched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    try agent.messages.append(try item(a, "message", null));
    try std.testing.expect(!pruneIf(&agent, true));
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);
    // blob already at the head: nothing to prune
    var agent2 = testAgent(a, .responses);
    try agent2.messages.append(try item(a, "compaction", null));
    try agent2.messages.append(try item(a, "message", null));
    try std.testing.expect(!pruneIf(&agent2, true));
    try std.testing.expectEqual(@as(usize, 2), agent2.messages.items.len);
    try std.testing.expectEqual(@as(u32, 0), agent2.history_rewrites);
}

test "pruneToLatestBlob: prunes to the newest blob and resets the meters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    try agent.messages.append(try item(a, "message", null)); // pruned
    try agent.messages.append(try item(a, "compaction", null)); // older blob — superseded
    try agent.messages.append(try item(a, "message", null)); // pruned
    try agent.messages.append(try item(a, "compaction", null)); // newest blob
    try agent.messages.append(try item(a, "function_call", "c1")); // pair survives intact
    try agent.messages.append(try item(a, "function_call_output", "c1"));
    agent.last_context_tokens = 200_000;
    agent.context_local_tokens = 190_000;
    try std.testing.expect(pruneIf(&agent, true));
    try std.testing.expectEqual(@as(usize, 3), agent.messages.items.len);
    try std.testing.expectEqualStrings("compaction", agent.messages.items[0].object.get("type").?.string);
    try std.testing.expectEqual(@as(u32, 1), agent.history_rewrites);
    try std.testing.expectEqual(@as(u64, 0), agent.last_context_tokens);
    try std.testing.expectEqual(@as(u64, 0), agent.context_local_tokens);
}

fn imageUser(a: std.mem.Allocator) !Value {
    var image: std.json.ObjectMap = .empty;
    try image.put(a, "type", .{ .string = "image_url" });
    var image_url: std.json.ObjectMap = .empty;
    try image_url.put(a, "url", .{ .string = "data:image/png;base64,AAA" });
    try image.put(a, "image_url", .{ .object = image_url });
    var content = std.json.Array.init(a);
    var tb: std.json.ObjectMap = .empty;
    try tb.put(a, "type", .{ .string = "text" });
    try tb.put(a, "text", .{ .string = "read this" });
    try content.append(.{ .object = tb });
    try content.append(.{ .object = image });
    var user: std.json.ObjectMap = .empty;
    try user.put(a, "role", .{ .string = "user" });
    try user.put(a, "content", .{ .array = content });
    return .{ .object = user };
}

test "pruneIf: refuses a blob that would drop an unresolved image prompt (#581)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    try agent.messages.append(try item(a, "message", null));
    try agent.messages.append(try imageUser(a)); // live pin
    try agent.messages.append(try item(a, "function_call", "c1"));
    try agent.messages.append(try item(a, "function_call_output", "c1"));
    try agent.messages.append(try item(a, "compaction", null)); // after the pin
    try std.testing.expect(!pruneIf(&agent, true));
    try std.testing.expectEqual(@as(usize, 5), agent.messages.items.len);
    try std.testing.expectEqual(@as(u32, 0), agent.history_rewrites);
}

test "pruneIf: a blob before the live image pin still prunes the prefix (#581)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    try agent.messages.append(try item(a, "message", null));
    try agent.messages.append(try item(a, "compaction", null));
    try agent.messages.append(try imageUser(a));
    try std.testing.expect(pruneIf(&agent, true));
    try std.testing.expectEqual(@as(usize, 2), agent.messages.items.len);
    try std.testing.expectEqualStrings("compaction", agent.messages.items[0].object.get("type").?.string);
}

test "explicitCompact: refuses to fold an unresolved image prompt into a blob (#581)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    agent.arena = a;
    agent.provider.id = "xai";
    try agent.messages.append(try imageUser(a));
    try agent.messages.append(try item(a, "function_call", "c1"));
    try agent.messages.append(try item(a, "function_call_output", "c1"));
    try std.testing.expect(!explicitCompact(&agent));
    try std.testing.expectEqual(@as(usize, 3), agent.messages.items.len);
    try std.testing.expectEqual(@as(u32, 0), agent.history_rewrites);
}

test "pruneToLatestBlob: an orphaned tool output refuses the prune" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    try agent.messages.append(try item(a, "function_call", "c1")); // pruned by the cut
    try agent.messages.append(try item(a, "compaction", null));
    try agent.messages.append(try item(a, "function_call_output", "c1")); // orphan if pruned
    try std.testing.expect(!pruneIf(&agent, true));
    try std.testing.expectEqual(@as(usize, 3), agent.messages.items.len);
}

test "pruneIf: never fires off the server arm or off responses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .anthropic);
    try agent.messages.append(try item(a, "message", null));
    try agent.messages.append(try item(a, "compaction", null));
    try std.testing.expect(!pruneIf(&agent, true));
    try std.testing.expectEqual(@as(usize, 2), agent.messages.items.len);
}

test "autocompact: responses providers hold at the ordinary threshold without a blob" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses); // context 100_000
    try agent.messages.append(try item(a, "message", null));
    // Over the 80% compactAt line but under the 95% wall, no blob: the server
    // owns compaction now, so history must survive untouched (legacy policy
    // would have run a summary here).
    autocompactIf(&agent, 85_000, true);
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);
    try std.testing.expectEqual(@as(u32, 0), agent.history_rewrites);
}

test "installCompactionItem restarts history from the blob and resets the meters (#502)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    agent.arena = a;
    try agent.messages.append(try item(a, "message", null));
    try agent.messages.append(try item(a, "function_call", "c1"));
    try agent.messages.append(try item(a, "function_call_output", "c1"));
    agent.last_context_tokens = 400_000;
    const resp =
        \\{"id":"cmp_1","object":"response.compaction","output":[{"type":"compaction","id":"cmp_1","encrypted_content":"BLOB"}],
        \\ "usage":{"input_tokens":9000,"output_tokens":400,"dropped_message_count":3}}
    ;
    try std.testing.expect(installCompactionItem(&agent, resp));
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);
    try std.testing.expectEqualStrings("compaction", agent.messages.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("BLOB", agent.messages.items[0].object.get("encrypted_content").?.string);
    try std.testing.expectEqual(@as(u64, 0), agent.last_context_tokens);
    try std.testing.expectEqual(@as(u32, 1), agent.history_rewrites);
}

test "installCompactionItem refuses malformed responses and leaves history intact (#502)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    agent.arena = a;
    try agent.messages.append(try item(a, "message", null));
    for ([_][]const u8{
        "not json",
        "{\"output\":[]}",
        "{\"output\":[{\"type\":\"message\"}]}",
        "{\"output\":[{\"type\":\"compaction\"}]}", // no encrypted_content
    }) |bad| {
        try std.testing.expect(!installCompactionItem(&agent, bad));
        try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);
        try std.testing.expectEqual(@as(u32, 0), agent.history_rewrites);
    }
}

test "explicitCompact anti-thrash: a fresh blob head with little growth refuses (#502)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    agent.arena = a;
    agent.provider.id = "xai"; // serverCompactUrl fires for xai + .responses
    try agent.messages.append(try item(a, "compaction", null));
    try agent.messages.append(try item(a, "message", null));
    // Guard trips BEFORE any network I/O — false, history untouched.
    try std.testing.expect(!explicitCompact(&agent));
    try std.testing.expectEqual(@as(usize, 2), agent.messages.items.len);
    try std.testing.expectEqual(@as(u32, 0), agent.history_rewrites);
}

test "manualCompact (#503): a blob-anchored history on an explicit-compact provider no-ops instead of client-summarizing the blob" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    const saved_wire = provider.g_xai_responses;
    provider.g_xai_responses = true;
    defer provider.g_xai_responses = saved_wire;
    agent.provider = .{ .id = "xai", .kind = .responses, .auth = .bearer, .url = provider.xai_responses_url, .api_key = "k", .model = "grok-4.6", .context = 100_000 };
    // History = one opaque compaction item + one turn: small and blob-anchored,
    // so the anti-thrash guard refuses the endpoint before any POST — and the
    // fallback must NOT be a client summary (it cannot see inside the blob).
    var blob: std.json.ObjectMap = .empty;
    try blob.put(a, "type", .{ .string = "compaction" });
    try blob.put(a, "encrypted_content", .{ .string = "opaque" });
    try agent.messages.append(.{ .object = blob });
    try agent.messages.append(try item(a, "message", null));
    const n = try manualCompact(&agent);
    try std.testing.expectEqual(@as(usize, 0), n);
    try std.testing.expectEqual(@as(usize, 2), agent.messages.items.len); // untouched
}
