//! Focused regression tests for transactional compaction and context recovery.

const std = @import("std");
const util = @import("util.zig");
const Value = std.json.Value;
const Agent = @import("agent.zig").Agent;
const textMessage = @import("messages.zig").textMessage;
const compact_instruction = @import("prompts.zig").compact_instruction;

const compact = @import("agent_compact.zig");
const summaryResponseComplete = compact.summaryResponseComplete;
const cloneJsonArray = compact.cloneJsonArray;
const dropPriorTurnReasoning = compact.dropPriorTurnReasoning;
const trimOldestToolOutputsAlloc = compact.trimOldestToolOutputsAlloc;
const repeatedOpaqueCompactionFailure = compact.repeatedOpaqueCompactionFailure;
const trimOldestToolOutputs = compact.trimOldestToolOutputs;
const capOversizedToolOutputs = compact.capOversizedToolOutputs;
const recentContextStart = compact.recentContextStart;
const cleanUserTurn = compact.cleanUserTurn;
const emergencyCutIndex = compact.emergencyCutIndex;
const emergencyTrim = compact.emergencyTrim;
const handoffMessage = compact.handoffMessage;
const pinChildTask = compact.pinChildTask;
const task_pin_cap = compact.task_pin_cap;
const th = @import("agent_compact_test_support.zig");

test "compaction accepts only complete provider terminal states" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = undefined;

    agent.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 100_000 };
    const responses_ok = try std.json.parseFromSliceLeaky(Value, a, "{}", .{});
    const responses_partial = try std.json.parseFromSliceLeaky(Value, a, "{\"incomplete\":true}", .{});
    try std.testing.expect(summaryResponseComplete(&agent, responses_ok.object));
    try std.testing.expect(!summaryResponseComplete(&agent, responses_partial.object));

    agent.provider.kind = .anthropic;
    const anthropic_ok = try std.json.parseFromSliceLeaky(Value, a, "{\"stop_reason\":\"end_turn\"}", .{});
    const anthropic_short = try std.json.parseFromSliceLeaky(Value, a, "{\"stop_reason\":\"max_tokens\"}", .{});
    const anthropic_compat = try std.json.parseFromSliceLeaky(Value, a, "{}", .{});
    try std.testing.expect(summaryResponseComplete(&agent, anthropic_ok.object));
    try std.testing.expect(!summaryResponseComplete(&agent, anthropic_short.object));
    try std.testing.expect(summaryResponseComplete(&agent, anthropic_compat.object));

    agent.provider.kind = .openai;
    const openai_ok = try std.json.parseFromSliceLeaky(Value, a, "{\"choices\":[{\"finish_reason\":\"stop\"}]}", .{});
    const openai_short = try std.json.parseFromSliceLeaky(Value, a, "{\"choices\":[{\"finish_reason\":\"length\"}]}", .{});
    const openai_compat = try std.json.parseFromSliceLeaky(Value, a, "{\"choices\":[{}]}", .{});
    const openai_stream_partial = try std.json.parseFromSliceLeaky(Value, a, "{\"incomplete\":true,\"choices\":[{\"finish_reason\":\"stop\"}]}", .{});
    try std.testing.expect(summaryResponseComplete(&agent, openai_ok.object));
    try std.testing.expect(!summaryResponseComplete(&agent, openai_short.object));
    try std.testing.expect(summaryResponseComplete(&agent, openai_compat.object));
    try std.testing.expect(!summaryResponseComplete(&agent, openai_stream_partial.object));
}

test "compaction working copy isolates reasoning and tool-output pruning" {
    var live_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer live_arena_state.deinit();
    const live_arena = live_arena_state.allocator();

    var live = std.json.Array.init(live_arena);
    try live.append(try textMessage(live_arena, "user", "run the tool loop"));
    try live.append(try std.json.parseFromSliceLeaky(Value, live_arena, "{\"type\":\"reasoning\",\"encrypted_content\":\"KEEP\"}", .{}));
    const big = try live_arena.alloc(u8, 5000);
    @memset(big, 'x');
    for (0..10) |i| {
        var output: std.json.ObjectMap = .empty;
        try output.put(live_arena, "type", .{ .string = "function_call_output" });
        try output.put(live_arena, "call_id", .{ .string = try std.fmt.allocPrint(live_arena, "c{d}", .{i}) });
        try output.put(live_arena, "output", .{ .string = big });
        try live.append(.{ .object = output });
    }

    var work_arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer work_arena_state.deinit();
    const work_arena = work_arena_state.allocator();
    var agent: Agent = undefined;
    agent.arena = work_arena;
    agent.messages = try cloneJsonArray(work_arena, live);
    agent.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 100_000 };
    agent.last_context_tokens = 90_000;
    agent.sub = false;
    agent.strict = false;
    agent.sys_normal = "";
    agent.sys_strict = "";
    agent.tools_responses = "";
    agent.context_local_tokens = agent.fullRequestEstimateTokens();

    try agent.messages.append(try textMessage(work_arena, "user", compact_instruction));
    try std.testing.expectEqual(@as(usize, 1), dropPriorTurnReasoning(&agent));
    try std.testing.expect(trimOldestToolOutputsAlloc(&agent, work_arena) > 0);

    // The temporary request changed, while the live conversation retained both
    // the active-loop reasoning item and every original output byte.
    try std.testing.expectEqual(@as(usize, 12), live.items.len);
    try std.testing.expectEqualStrings("reasoning", live.items[1].object.get("type").?.string);
    try std.testing.expectEqual(@as(usize, 5000), live.items[2].object.get("output").?.string.len);
    for (agent.messages.items) |item| {
        if (item != .object) continue;
        const t = item.object.get("type") orelse continue;
        try std.testing.expect(!(t == .string and std.mem.eql(u8, t.string, "reasoning")));
    }
    try std.testing.expect(agent.messages.items[1].object.get("output").?.string.len < 5000);
}

test "dropPriorTurnReasoning (#174): prior-turn reasoning goes, current turn + non-responses stay" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var msgs = std.json.Array.init(a);
    try msgs.append(try textMessage(a, "user", "turn one"));
    try msgs.append(try std.json.parseFromSliceLeaky(Value, a, "{\"type\":\"reasoning\",\"encrypted_content\":\"OLD1\"}", .{}));
    try msgs.append(try textMessage(a, "assistant", "reply one"));
    try msgs.append(try std.json.parseFromSliceLeaky(Value, a, "{\"type\":\"reasoning\",\"encrypted_content\":\"OLD2\"}", .{}));
    try msgs.append(try textMessage(a, "user", "turn two"));
    try msgs.append(try std.json.parseFromSliceLeaky(Value, a, "{\"type\":\"reasoning\",\"encrypted_content\":\"CURRENT\"}", .{}));
    try msgs.append(try std.json.parseFromSliceLeaky(Value, a, "{\"type\":\"function_call\",\"name\":\"bash\",\"call_id\":\"c1\",\"arguments\":\"{}\"}", .{}));

    var agent: Agent = undefined;
    agent.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 100_000 };
    agent.messages = msgs;

    try std.testing.expectEqual(@as(usize, 2), dropPriorTurnReasoning(&agent));
    try std.testing.expectEqual(@as(usize, 5), agent.messages.items.len);
    // current-turn reasoning (after the last user message) survives, in order
    const kept = agent.messages.items[3].object.get("encrypted_content").?.string;
    try std.testing.expectEqualStrings("CURRENT", kept);

    // Once compact() appends its synthetic user turn, the formerly-current
    // reasoning belongs to a prior turn and is safe to omit from the full
    // summary resend too.
    try agent.messages.append(try textMessage(a, "user", compact_instruction));
    try std.testing.expectEqual(@as(usize, 1), dropPriorTurnReasoning(&agent));
    for (agent.messages.items) |m| {
        if (m != .object) continue;
        const t = m.object.get("type") orelse continue;
        try std.testing.expect(!(t == .string and std.mem.eql(u8, t.string, "reasoning")));
    }

    // non-responses providers are untouched
    agent.provider.kind = .openai;
    try std.testing.expectEqual(@as(usize, 0), dropPriorTurnReasoning(&agent));
    try std.testing.expectEqual(@as(usize, 5), agent.messages.items.len);
}

test "repeated opaque compaction transport failures unlock bounded recovery" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = undefined;
    agent.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 100_000 };
    agent.messages = std.json.Array.init(a);
    agent.sub = false;
    agent.strict = false;
    agent.sys_normal = "";
    agent.sys_strict = "";
    agent.tools_responses = "";
    agent.last_context_tokens = 96_000;
    agent.context_local_tokens = agent.fullRequestEstimateTokens();
    agent.compact_transport_failures = 0;
    agent.last_request_write_failed = true;

    try std.testing.expect(!repeatedOpaqueCompactionFailure(&agent, error.ApiError));
    try std.testing.expectEqual(@as(u8, 1), agent.compact_transport_failures);
    try std.testing.expect(repeatedOpaqueCompactionFailure(&agent, error.ApiError));
    try std.testing.expectEqual(@as(u8, 2), agent.compact_transport_failures);

    // Merely crossing compact@ (80%) is not overflow proof.
    agent.last_context_tokens = 90_000;
    agent.compact_transport_failures = 1;
    try std.testing.expect(!repeatedOpaqueCompactionFailure(&agent, error.ApiError));

    // A non-WriteFailed provider outcome breaks the streak.
    agent.last_request_write_failed = false;
    try std.testing.expect(!repeatedOpaqueCompactionFailure(&agent, error.ApiError));
    try std.testing.expectEqual(@as(u8, 0), agent.compact_transport_failures);

    // Other transport failures are represented as false, not overflow evidence.
    agent.compact_transport_failures = 1;
    try std.testing.expect(!repeatedOpaqueCompactionFailure(&agent, error.ApiError));
    try std.testing.expectEqual(@as(u8, 0), agent.compact_transport_failures);

    // Unknown context windows never authorize destructive recovery by count.
    agent.provider.context = 0;
    agent.last_request_write_failed = true;
    agent.compact_transport_failures = 1;
    try std.testing.expect(!repeatedOpaqueCompactionFailure(&agent, error.ApiError));
}

test "trimOldestToolOutputs recovers a runaway tool-loop history (#163)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    try msgs.append(try textMessage(a, "user", "babysit the CI")); // the only clean user turn
    const big = try a.alloc(u8, 5000);
    @memset(big, 'x');
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "type", .{ .string = "function_call_output" });
        try o.put(a, "call_id", .{ .string = "c" });
        try o.put(a, "output", .{ .string = big });
        try msgs.append(.{ .object = o });
    }
    var agent: Agent = undefined;
    agent.messages = msgs;
    agent.arena = a;
    agent.last_context_tokens = 100000;
    agent.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 270_000 };
    agent.sub = false;
    agent.strict = false;
    agent.sys_normal = "";
    agent.sys_strict = "";
    agent.tools_responses = "";
    agent.message_mutation_arena = null;
    const before_request = agent.fullRequestEstimateTokens();
    agent.context_local_tokens = before_request;
    // no clean user turn after the midpoint -> the old emergencyTrim would give up
    try std.testing.expect(emergencyCutIndex(agent.messages.items) == null);
    const reclaimed = trimOldestToolOutputs(&agent);
    try std.testing.expect(reclaimed > 0); // recovered instead of wedging
    // A small trim conservatively lowers, rather than replaces, the server meter.
    try std.testing.expect(agent.last_context_tokens > 0);
    try std.testing.expectEqual(agent.fullRequestEstimateTokens() +| (@as(u64, 100000) -| before_request), agent.last_context_tokens);
    var truncated: usize = 0;
    var full: usize = 0;
    for (agent.messages.items) |m| {
        if (m == .object) if (m.object.get("output")) |out| if (out == .string) {
            if (out.string.len < 1000) truncated += 1 else full += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 6), truncated); // 10 outputs, oldest 6 truncated
    try std.testing.expectEqual(@as(usize, 4), full); // 4 most-recent kept verbatim
    try std.testing.expectEqual(@as(usize, 11), agent.messages.items.len); // no message dropped
}

test "recentContextStart keeps a clean recent suffix and never orphans tool output" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    try msgs.append(try textMessage(a, "user", "old request"));
    try msgs.append(try textMessage(a, "assistant", &util.repeatBytes("x", 36_000)));
    try msgs.append(try textMessage(a, "user", "recent request"));
    try msgs.append(try std.json.parseFromSliceLeaky(Value, a, "{\"type\":\"function_call_output\",\"call_id\":\"c1\",\"output\":\"recent result\"}", .{}));
    try msgs.append(try textMessage(a, "assistant", "recent answer"));

    const start = recentContextStart(msgs.items, 8_000);
    try std.testing.expectEqual(@as(usize, 2), start);
    try std.testing.expect(cleanUserTurn(msgs.items[start]));
    try std.testing.expectEqualStrings("recent request", msgs.items[start].object.get("content").?.string);

    // A short entire conversation must still compact rather than retain all
    // messages and perform a no-op summary.
    try std.testing.expectEqual(msgs.items[2..].len, recentContextStart(msgs.items[2..], 8_000));
}

test "recentContextStart preserves a fresh image without counting its Base64 as text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const payload = try arena.alloc(u8, 1_600_000);
    @memset(payload, 'A');
    const uri = try std.fmt.allocPrint(arena, "data:image/png;base64,{s}", .{payload});

    var image_url: std.json.ObjectMap = .empty;
    try image_url.put(arena, "url", .{ .string = uri });
    var image: std.json.ObjectMap = .empty;
    try image.put(arena, "type", .{ .string = "image_url" });
    try image.put(arena, "image_url", .{ .object = image_url });
    var content = std.json.Array.init(arena);
    try content.append(.{ .object = image });
    var user: std.json.ObjectMap = .empty;
    try user.put(arena, "role", .{ .string = "user" });
    try user.put(arena, "content", .{ .array = content });
    var messages = std.json.Array.init(arena);
    try messages.append(.{ .object = user });

    // The whole short conversation still needs summarizing when compact() is
    // explicitly requested, but the image itself fits the recent-turn budget
    // and can be retained when older history exists.
    try messages.insert(0, try textMessage(arena, "user", &util.repeatBytes("x", 40_000)));
    try std.testing.expectEqual(@as(usize, 1), recentContextStart(messages.items, 8_000));
}

test "capOversizedToolOutputs (#193): bounds an oversized output in every wire format, leaves small ones + non-tool msgs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cap: usize = 1024;
    const big = try a.alloc(u8, 8192);
    @memset(big, 'x');

    var msgs = std.json.Array.init(a);
    // responses function_call_output (oversized)
    var fco: std.json.ObjectMap = .empty;
    try fco.put(a, "type", .{ .string = "function_call_output" });
    try fco.put(a, "call_id", .{ .string = "c1" });
    try fco.put(a, "output", .{ .string = big });
    try msgs.append(.{ .object = fco });
    // openai role:"tool" (oversized)
    var tool: std.json.ObjectMap = .empty;
    try tool.put(a, "role", .{ .string = "tool" });
    try tool.put(a, "tool_call_id", .{ .string = "c2" });
    try tool.put(a, "content", .{ .string = big });
    try msgs.append(.{ .object = tool });
    // anthropic user turn carrying a tool_result block (oversized)
    var user: std.json.ObjectMap = .empty;
    try user.put(a, "role", .{ .string = "user" });
    var blocks = std.json.Array.init(a);
    var tr: std.json.ObjectMap = .empty;
    try tr.put(a, "type", .{ .string = "tool_result" });
    try tr.put(a, "tool_use_id", .{ .string = "c3" });
    try tr.put(a, "content", .{ .string = big });
    try blocks.append(.{ .object = tr });
    try user.put(a, "content", .{ .array = blocks });
    try msgs.append(.{ .object = user });
    // a small tool output (within cap) — must be left untouched
    var small: std.json.ObjectMap = .empty;
    try small.put(a, "type", .{ .string = "function_call_output" });
    try small.put(a, "output", .{ .string = "ok" });
    try msgs.append(.{ .object = small });
    // a plain assistant text message — never a tool output, left untouched
    try msgs.append(try textMessage(a, "assistant", "hello"));

    var agent: Agent = undefined;
    agent.arena = a;
    agent.messages = msgs;
    agent.last_context_tokens = 200_000;
    agent.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 270_000 };
    agent.sub = false;
    agent.strict = false;
    agent.sys_normal = "";
    agent.sys_strict = "";
    agent.tools_responses = "";
    agent.message_mutation_arena = null;
    // The high provider meter predates these unsent tool outputs.
    agent.context_local_tokens = 8_000;

    const reclaimed = capOversizedToolOutputs(&agent, cap);
    try std.testing.expect(reclaimed > 0);
    // The known-underestimating local serializer must not replace a high server meter.
    try std.testing.expect(agent.last_context_tokens > 0);
    try std.testing.expectEqual(agent.fullRequestEstimateTokens() +| (@as(u64, 200_000) - 8_000), agent.last_context_tokens);

    // every oversized tool output is now within the cap, with a marker
    const out0 = agent.messages.items[0].object.get("output").?.string;
    try std.testing.expect(out0.len <= cap);
    try std.testing.expect(std.mem.indexOf(u8, out0, "truncated") != null);
    const out1 = agent.messages.items[1].object.get("content").?.string;
    try std.testing.expect(out1.len <= cap);
    const block = agent.messages.items[2].object.get("content").?.array.items[0];
    try std.testing.expect(block.object.get("content").?.string.len <= cap);
    // within-cap output and the non-tool message are untouched
    try std.testing.expectEqualStrings("ok", agent.messages.items[3].object.get("output").?.string);
    try std.testing.expectEqualStrings("hello", agent.messages.items[4].object.get("content").?.string);
    // cap == 0 disables the cap entirely (unknown window)
    try std.testing.expectEqual(@as(usize, 0), capOversizedToolOutputs(&agent, 0));
}

test "cleanUserTurn: plain user text yes; assistant/tool_result no" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect(cleanUserTurn(try textMessage(a, "user", "hello")));
    try std.testing.expect(!cleanUserTurn(try textMessage(a, "assistant", "hi")));
    // an anthropic tool_result-only user message is NOT a clean conversation start
    const tr = try std.json.parseFromSliceLeaky(Value, a, "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"ok\"}]}", .{});
    try std.testing.expect(!cleanUserTurn(tr));
}

test "emergencyCutIndex: cuts at a clean user turn at/after the midpoint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var items = std.json.Array.init(a);
    const roles = [_][]const u8{ "user", "assistant", "user", "assistant", "user", "assistant", "user", "assistant" };
    for (roles) |r| try items.append(try textMessage(a, r, "x"));
    try std.testing.expectEqual(@as(?usize, 4), emergencyCutIndex(items.items)); // midpoint 4 is a user turn
    try std.testing.expectEqual(@as(?usize, null), emergencyCutIndex(items.items[0..3])); // too short to trim
}

test "emergencyTrim preserves the authoritative meter after a partial cut" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var items = std.json.Array.init(a);
    const roles = [_][]const u8{ "user", "assistant", "user", "assistant", "user", "assistant", "user", "assistant" };
    for (roles) |role| try items.append(try textMessage(a, role, "a retained message with some measurable bytes"));

    var agent: Agent = undefined;
    agent.arena = a;
    agent.messages = items;
    agent.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 270_000 };
    agent.last_context_tokens = 200_000;
    agent.sub = false;
    agent.strict = false;
    agent.sys_normal = "";
    agent.sys_strict = "";
    agent.tools_responses = "";
    // emergencyTrim now re-queues the standing goal state (#318), so the fields
    // that decision reads have to be real even in the no-goal case.
    agent.review_mode = false;
    agent.goal = null;
    agent.pending_goal_note = null;

    const before = agent.fullInputEstimateTokens();
    const before_request = agent.fullRequestEstimateTokens();
    agent.context_local_tokens = before_request;
    try std.testing.expectEqual(@as(usize, 4), emergencyTrim(&agent));
    const after = agent.fullInputEstimateTokens();
    try std.testing.expect(after < before);
    const expected = agent.fullRequestEstimateTokens() +| (@as(u64, 200_000) -| before_request);
    try std.testing.expectEqual(expected, agent.last_context_tokens);
    try std.testing.expect(agent.last_context_tokens > 0);
}

test "emergencyCutIndex: skips a tool_result user message at the midpoint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var items = std.json.Array.init(a);
    try items.append(try textMessage(a, "user", "x")); // 0
    try items.append(try textMessage(a, "assistant", "x")); // 1
    try items.append(try textMessage(a, "user", "x")); // 2
    try items.append(try textMessage(a, "assistant", "x")); // 3
    // 4: an anthropic tool_result-only user message (not a valid conversation start)
    try items.append(try std.json.parseFromSliceLeaky(Value, a, "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"x\"}]}", .{})); // 4 (skip)
    try items.append(try textMessage(a, "assistant", "x")); // 5
    try items.append(try textMessage(a, "user", "x")); // 6 (first clean user >= midpoint)
    try items.append(try textMessage(a, "assistant", "x")); // 7
    try std.testing.expectEqual(@as(?usize, 6), emergencyCutIndex(items.items));
}

test "a compaction handoff carries the live checklist across the summary (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = undefined;
    agent.arena = a;
    agent.task_prompt = null; // this test flips agent.sub to true below (#B3)
    agent.sub = false;
    agent.review_mode = false;
    agent.todos = .empty;
    agent.goal = .{ .objective = "ship the epoch fix", .epoch = 2 };
    try agent.todos.append(a, .{ .content = "write the helper", .status = "completed", .epoch = 2 });
    try agent.todos.append(a, .{ .content = "wire it into compact", .status = "completed", .epoch = 2 });
    try agent.todos.append(a, .{ .content = "test it", .status = "pending", .epoch = 2 });
    try agent.todos.append(a, .{ .content = "parked by an older goal", .status = "pending", .epoch = 1 });

    const handoff = try handoffMessage(&agent, "the model summarized the earlier work");
    // The summary and its framing are unchanged...
    try std.testing.expect(std.mem.indexOf(u8, handoff, "the model summarized the earlier work") != null);
    try std.testing.expect(std.mem.indexOf(u8, handoff, "Continue assisting the user based on this summary.") != null);
    // ...and the state a summary cannot be trusted to carry rides with it. The
    // last todo_write result is not in the ~8k suffix after a long tool loop,
    // and the summarizer may never have seen the item statuses at all.
    try std.testing.expect(std.mem.indexOf(u8, handoff, "ship the epoch fix") != null);
    try std.testing.expect(std.mem.indexOf(u8, handoff, "Checklist (1 open)") != null);
    try std.testing.expect(std.mem.indexOf(u8, handoff, "[x] write the helper") != null);
    try std.testing.expect(std.mem.indexOf(u8, handoff, "[x] wire it into compact") != null);
    try std.testing.expect(std.mem.indexOf(u8, handoff, "[ ] test it") != null);
    // The REPLACES warning is the whole point: without it the model rewrote the
    // list from the summary's prose, todo_write's clearEpoch dropped the three
    // completed items, allDone flipped false, and the goal never completed -
    // durably, because the autosave persisted the damaged list (#318).
    try std.testing.expect(std.mem.indexOf(u8, handoff, "todo_write REPLACES") != null);
    try std.testing.expect(std.mem.indexOf(u8, handoff, "todo_read") != null);
    // Parked work is never resurrected into the handoff.
    try std.testing.expect(std.mem.indexOf(u8, handoff, "parked by an older goal") == null);

    // A subagent shares the Agent struct but not the goal, so its handoff is
    // byte-identical to the pre-#318 text - as is a session with no goal.
    agent.sub = true;
    const plain = try handoffMessage(&agent, "the model summarized the earlier work");
    try std.testing.expect(std.mem.indexOf(u8, plain, "standing state") == null);
    try std.testing.expect(std.mem.endsWith(u8, plain, "Continue assisting the user based on this summary."));
    agent.sub = false;
    agent.goal = null;
    try std.testing.expectEqualStrings(plain, try handoffMessage(&agent, "the model summarized the earlier work"));
}

test "an emergency trim re-queues the standing state, never over a user note (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const roles = [_][]const u8{ "user", "assistant", "user", "assistant", "user", "assistant", "user", "assistant" };

    var agent: Agent = undefined;
    agent.arena = a;
    agent.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 270_000 };
    agent.last_context_tokens = 200_000;
    agent.context_local_tokens = 200_000;
    agent.sub = false;
    agent.review_mode = false;
    agent.strict = false;
    agent.sys_normal = "";
    agent.sys_strict = "";
    agent.tools_responses = "";
    agent.todos = .empty;
    agent.goal = .{ .objective = "keep the tree green", .epoch = 1 };
    agent.pending_goal_note = null;
    try agent.todos.append(a, .{ .content = "audit the loop", .status = "in_progress", .epoch = 1 });

    // emergencyTrim has no synthetic message of its own to append the standing
    // state to (compact() does), so it hands it to the one-shot slot instead -
    // otherwise a mid-turn trim leaves the rest of the turn checklist-blind.
    var items = std.json.Array.init(a);
    for (roles) |role| try items.append(try textMessage(a, role, "a retained message with some measurable bytes"));
    agent.messages = items;
    try std.testing.expectEqual(@as(usize, 4), emergencyTrim(&agent));
    try std.testing.expect(agent.pending_goal_note != null);
    try std.testing.expect(std.mem.indexOf(u8, agent.pending_goal_note.?, "keep the tree green") != null);
    try std.testing.expect(std.mem.indexOf(u8, agent.pending_goal_note.?, "[~] audit the loop") != null);
    try std.testing.expectEqual(@as(u64, 0), agent.goal_note_fp);

    // A queued supersession note (/goal replace|clear) always wins: it is the
    // user changing the objective, and the standing state is only the harness
    // restating itself. Clobbering it lost "stop working the old objective".
    var again = std.json.Array.init(a);
    for (roles) |role| try again.append(try textMessage(a, role, "a retained message with some measurable bytes"));
    agent.messages = again;
    agent.pending_goal_note = "[goal update: the standing goal above supersedes the previous goal]";
    _ = emergencyTrim(&agent);
    try std.testing.expectEqualStrings("[goal update: the standing goal above supersedes the previous goal]", agent.pending_goal_note.?);

    // And with no live goal there is nothing to queue at all.
    var third = std.json.Array.init(a);
    for (roles) |role| try third.append(try textMessage(a, role, "a retained message with some measurable bytes"));
    agent.messages = third;
    agent.goal = null;
    agent.pending_goal_note = null;
    _ = emergencyTrim(&agent);
    try std.testing.expect(agent.pending_goal_note == null);
}
test "recentContextStart keeps NOTHING verbatim for a subagent-shaped history (the #318-shaped failure one level down)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const short = try th.paddedSubHistory(a, 1, "ok");
    try std.testing.expectEqual(short.items.len, recentContextStart(short.items, 8000));
    const pad = util.repeatBytes("x", 4000);
    const long = try th.paddedSubHistory(a, 10, &pad);
    try std.testing.expectEqual(long.items.len, recentContextStart(long.items, 8000));
}
test "a compacting subagent's handoff restates its task prompt verbatim" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = th.subAgent(a, true);
    agent.task_prompt = "AUDIT src/foo.zig and report every unguarded json deref";
    const handoff = try handoffMessage(&agent, "the model summarized the earlier work");
    try std.testing.expect(std.mem.indexOf(u8, handoff, agent.task_prompt.?) != null and std.mem.indexOf(u8, handoff, "the model summarized the earlier work") != null and std.mem.indexOf(u8, handoff, "still your mandate") != null);
}
test "the root handoff is byte-identical to before the child pin" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = th.subAgent(a, false);
    const handoff = try handoffMessage(&agent, "the model summarized the earlier work");
    try std.testing.expectEqualStrings("Context: the earlier conversation was compacted to save space.\nSummary of the earlier work:\n\nthe model summarized the earlier work\n\nContinue assisting the user based on this summary.", handoff);
}
test "pinChildTask captures the mandate once, never re-pins, and ignores a root agent or an unrecognised head" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = th.subAgent(a, true);
    agent.messages = try th.msg1(a, "user", "TASK X");
    pinChildTask(&agent);
    agent.messages = try th.msg1(a, "user", "Context: the earlier conversation was compacted...");
    pinChildTask(&agent);
    try std.testing.expectEqualStrings("TASK X", agent.task_prompt.?);
    for ([_]struct { s: bool, r: ?[]const u8 }{ .{ .s = false, .r = "user" }, .{ .s = true, .r = "assistant" }, .{ .s = true, .r = null } }) |c| {
        var ag = th.subAgent(a, c.s);
        ag.messages = if (c.r) |r| try th.msg1(a, r, "x") else std.json.Array.init(a);
        pinChildTask(&ag);
        try std.testing.expect(ag.task_prompt == null);
    }
}
test "an oversized task prompt is head-capped in the child handoff" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = th.subAgent(a, true);
    const big = util.repeatBytes("T", 20000);
    agent.task_prompt = &big;
    const handoff = try handoffMessage(&agent, "summary text");
    try std.testing.expect(handoff.len < 12_000 and std.mem.indexOf(u8, handoff, "task prompt truncated for the handoff") != null and std.mem.indexOf(u8, handoff, big[0..100]) != null and std.mem.indexOf(u8, handoff, &big) == null);
}
test "emergencyCutIndex finds no cut in a subagent-shaped history, so the pinned mandate survives an emergency trim" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const items = try th.paddedSubHistory(a, 6, "ok");
    try std.testing.expectEqual(@as(?usize, null), emergencyCutIndex(items.items));
}
