//! Hosted compaction (ADR 0252) on fixtures: every wire format maps to the
//! gateway's neutral transcript, and a reply applies back onto the native
//! items — trimmed results, dropped calls, a spliced summary — without ever
//! leaving a result without its call.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const wire = @import("gateway_compact_wire.zig");
const hosted = @import("gateway_compact.zig");

const TestStub = struct {
    pub fn stub(_: *const TestStub, a: Allocator, full: []const u8) []const u8 {
        if (full.len <= 8) return full;
        return std.fmt.allocPrint(a, "{s}…[trimmed]", .{full[0..8]}) catch full;
    }
};

fn parse(a: Allocator, raw: []const u8) ![]const Value {
    const v = try std.json.parseFromSliceLeaky(Value, a, raw, .{ .allocate = .alloc_always });
    return v.array.items;
}

fn field(v: Value, key: []const u8) Value {
    return v.object.get(key) orelse .null;
}

test "ADR 0252: Anthropic history folds into neutral messages with calls, results and errors" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const items = try parse(a,
        \\[{"role":"user","content":"Fix the failing test"},
        \\ {"role":"assistant","content":[{"type":"thinking","thinking":"plan","signature":"s"},{"type":"text","text":"Reading it"},{"type":"tool_use","id":"t1","name":"read_file","input":{"path":"a.zig"}}]},
        \\ {"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"file body"}]},
        \\ {"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"bash","input":{"cmd":"zig build test"}}]},
        \\ {"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"1 failed"}],"is_error":true},{"type":"text","text":"also check b"}]},
        \\ {"role":"assistant","content":"Done"}]
    );
    const msgs = try wire.transcript(a, items);
    try std.testing.expectEqual(@as(usize, 6), msgs.len);
    try std.testing.expectEqual(wire.Role.assistant, msgs[1].role);
    try std.testing.expectEqualStrings("Reading it", msgs[1].text);
    try std.testing.expectEqualStrings("t1", msgs[1].uses[0].id);
    try std.testing.expectEqualStrings("a.zig", field(msgs[1].uses[0].input, "path").string);
    try std.testing.expectEqualStrings("file body", msgs[2].results[0].text);
    try std.testing.expectEqualStrings("also check b", msgs[4].text);
    try std.testing.expectEqualStrings("1 failed", msgs[4].results[0].text);
    try std.testing.expect(msgs[4].results[0].is_error);
    for (msgs, 0..) |m, i| try std.testing.expectEqual(i, m.lo);
}

test "ADR 0252: Chat tool messages fold into one user message; unparsable arguments are wrapped" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const items = try parse(a,
        \\[{"role":"user","content":"go"},
        \\ {"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{\"cmd\":\"ls\"}"}},{"id":"c2","type":"function","function":{"name":"grep","arguments":"not json"}}]},
        \\ {"role":"tool","tool_call_id":"c1","content":"a\nb"},
        \\ {"role":"tool","tool_call_id":"c2","content":"[error] bad pattern"},
        \\ {"role":"assistant","content":"ok"}]
    );
    const msgs = try wire.transcript(a, items);
    try std.testing.expectEqual(@as(usize, 4), msgs.len);
    try std.testing.expectEqualStrings("ls", field(msgs[1].uses[0].input, "cmd").string);
    try std.testing.expectEqualStrings("not json", field(msgs[1].uses[1].input, "arguments").string);
    try std.testing.expectEqual(@as(usize, 2), msgs[2].lo);
    try std.testing.expectEqual(@as(usize, 4), msgs[2].hi);
    try std.testing.expectEqual(@as(usize, 2), msgs[2].results.len);
    try std.testing.expect(!msgs[2].results[0].is_error);
    try std.testing.expect(msgs[2].results[1].is_error);
}

test "ADR 0252: Responses and Interactions items fold the same way; reasoning joins the model's side" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const responses = try wire.transcript(a, try parse(a,
        \\[{"role":"user","content":"go"},
        \\ {"type":"reasoning","encrypted_content":"x","summary":[]},
        \\ {"type":"function_call","call_id":"f1","name":"bash","arguments":"{\"cmd\":\"ls\"}"},
        \\ {"type":"function_call_output","call_id":"f1","output":"listing"},
        \\ {"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}]
    ));
    try std.testing.expectEqual(@as(usize, 4), responses.len);
    try std.testing.expectEqual(@as(usize, 1), responses[1].lo);
    try std.testing.expectEqual(@as(usize, 3), responses[1].hi);
    try std.testing.expectEqualStrings("f1", responses[2].results[0].id);
    try std.testing.expectEqualStrings("done", responses[3].text);
    const interactions = try wire.transcript(a, try parse(a,
        \\[{"type":"user_input","content":"go"},
        \\ {"type":"thought","signature":"s"},
        \\ {"type":"function_call","id":"g1","name":"bash","arguments":{"cmd":"ls"}},
        \\ {"type":"function_result","call_id":"g1","name":"bash","result":[{"type":"text","text":"listing"}]},
        \\ {"type":"model_output","content":[{"type":"text","text":"done"}]}]
    ));
    try std.testing.expectEqual(@as(usize, 4), interactions.len);
    try std.testing.expectEqualStrings("go", interactions[0].text);
    try std.testing.expectEqualStrings("ls", field(interactions[1].uses[0].input, "cmd").string);
    try std.testing.expectEqualStrings("listing", interactions[2].results[0].text);
}

test "ADR 0252: the request names the model, hybrid mode, the goal and every call by id" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const msgs = try wire.transcript(a, try parse(a,
        \\[{"role":"user","content":"go"},
        \\ {"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"read_file","input":{"path":"a.zig"}}]},
        \\ {"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"body","is_error":true}]}]
    ));
    const body = try wire.request(a, msgs, "clef", "ship the fix");
    const v = try std.json.parseFromSliceLeaky(Value, a, body, .{});
    try std.testing.expectEqualStrings("clef", field(v, "model").string);
    try std.testing.expectEqualStrings("hybrid", field(v, "mode").string);
    try std.testing.expectEqualStrings("ship the fix", field(v, "goal").string);
    const sent = field(v, "messages").array.items;
    try std.testing.expectEqualStrings("assistant", field(sent[1], "role").string);
    const use = field(sent[1], "toolUses").array.items[0];
    try std.testing.expectEqualStrings("t1", field(use, "tool_use_id").string);
    try std.testing.expectEqualStrings("a.zig", field(field(use, "input"), "path").string);
    const result = field(sent[2], "toolResults").array.items[0];
    try std.testing.expect(field(result, "isError").bool);
}

/// Two finished turns' worth of Anthropic history: t1/t2 in the earlier turn,
/// t3/t4 in the live one (it opens at item 6).
const two_turns =
    \\[{"role":"user","content":"first prompt"},
    \\ {"role":"assistant","content":[{"type":"text","text":"look"},{"type":"tool_use","id":"t1","name":"read_file","input":{"path":"a"}}]},
    \\ {"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"aaaaaaaaaaaaaaaaaaaaaaaa"}]},
    \\ {"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"grep","input":{"q":"x"}}]},
    \\ {"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"bbbbbbbbbbbbbbbbbbbbbbbb"}]},
    \\ {"role":"assistant","content":"answer one"},
    \\ {"role":"user","content":"second prompt"},
    \\ {"role":"assistant","content":[{"type":"tool_use","id":"t3","name":"bash","input":{"cmd":"ls"}}]},
    \\ {"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","content":"cccccccccccccccccccccccc"}]},
    \\ {"role":"assistant","content":[{"type":"tool_use","id":"t4","name":"bash","input":{"cmd":"pwd"}}]},
    \\ {"role":"user","content":[{"type":"tool_result","tool_use_id":"t4","content":"short"}]},
    \\ {"role":"assistant","content":"answer two"}]
;

/// The endpoint's transcript for two_turns after t1 drop_result, t2 and t3
/// drop_call, t4 keep: messages holding only dropped calls are gone.
const pruned_reply =
    \\{"messages":[
    \\ {"role":"user","text":"first prompt","toolUses":[],"toolResults":[]},
    \\ {"role":"assistant","text":"look","toolUses":[{"tool_use_id":"t1","tool":"read_file","input":{"path":"a"}}],"toolResults":[]},
    \\ {"role":"user","text":"","toolUses":[],"toolResults":[{"tool_use_id":"t1","text":"aaa…[truncated]"}]},
    \\ {"role":"assistant","text":"answer one","toolUses":[],"toolResults":[]},
    \\ {"role":"user","text":"second prompt","toolUses":[],"toolResults":[]},
    \\ {"role":"assistant","text":"","toolUses":[{"tool_use_id":"t4","tool":"bash","input":{"cmd":"pwd"}}],"toolResults":[]},
    \\ {"role":"user","text":"","toolUses":[],"toolResults":[{"tool_use_id":"t4","text":"short"}]},
    \\ {"role":"assistant","text":"answer two","toolUses":[],"toolResults":[]}],
    \\ "decisions":[{"id":"t1","tool":"read_file","tool_use_id":"t1","action":"drop_result"},
    \\  {"id":"t2","tool":"grep","tool_use_id":"t2","action":"drop_call"},
    \\  {"id":"t3","tool":"bash","tool_use_id":"t3","action":"drop_call"},
    \\  {"id":"t4","tool":"bash","tool_use_id":"t4","action":"keep"}],
    \\ "stats":{"summarized":false}}
;

test "ADR 0252: earlier turns lose dropped calls; the live turn keeps its calls and trims their results" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const items = try parse(a, two_turns);
    const msgs = try wire.transcript(a, items);
    const reply = try wire.parseReply(a, try std.json.parseFromSliceLeaky(Value, a, pruned_reply, .{ .allocate = .alloc_always }));
    try std.testing.expect(!reply.summarized);
    const p = try wire.plan(a, msgs, &reply, null);
    const stubber: TestStub = .{};
    const fresh = try wire.apply(a, items, msgs, p, &reply.decisions, 6, null, &stubber);
    // t2's pair (items 3, 4) is gone; t3 (live turn) keeps its call.
    try std.testing.expectEqual(@as(usize, 10), fresh.items.len);
    const t1 = field(fresh.items[2], "content").array.items[0];
    try std.testing.expectEqualStrings("aaaaaaaa…[trimmed]", field(t1, "content").string);
    try std.testing.expectEqualStrings("answer one", field(fresh.items[3], "content").string);
    try std.testing.expectEqualStrings("t3", field(field(fresh.items[5], "content").array.items[0], "id").string);
    const t3 = field(fresh.items[6], "content").array.items[0];
    try std.testing.expectEqualStrings("cccccccc…[trimmed]", field(t3, "content").string);
    try std.testing.expectEqualStrings("short", field(field(fresh.items[8], "content").array.items[0], "content").string);
    // The live history was not touched: the fresh one shares untouched items.
    try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaa", field(field(items[2], "content").array.items[0], "content").string);
    try wire.checkPairs(a, items, fresh.items);
}

test "ADR 0252: a reply that does not match what its decisions imply is refused" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const items = try parse(a, two_turns);
    const msgs = try wire.transcript(a, items);
    // The endpoint must never rewrite text: an edited message fails the check.
    const edited = try std.mem.replaceOwned(u8, a, pruned_reply, "answer one", "answer 1");
    const reply = try wire.parseReply(a, try std.json.parseFromSliceLeaky(Value, a, edited, .{ .allocate = .alloc_always }));
    try std.testing.expectError(error.UnexpectedReply, wire.plan(a, msgs, &reply, null));
    // So does a decision list that disagrees with the transcript it came with.
    const kept = try std.mem.replaceOwned(u8, a, pruned_reply, "\"action\":\"drop_call\"}", "\"action\":\"keep\"}");
    const mismatch = try wire.parseReply(a, try std.json.parseFromSliceLeaky(Value, a, kept, .{ .allocate = .alloc_always }));
    try std.testing.expectError(error.UnexpectedReply, wire.plan(a, msgs, &mismatch, null));
}

/// Responses history: a task, two earlier calls and a reply, then a new prompt
/// at item 6 and three calls in the live turn.
const long_turn =
    \\[{"role":"user","content":"task"},
    \\ {"type":"function_call","call_id":"a1","name":"bash","arguments":"{}"},
    \\ {"type":"function_call_output","call_id":"a1","output":"one"},
    \\ {"type":"function_call","call_id":"a2","name":"bash","arguments":"{}"},
    \\ {"type":"function_call_output","call_id":"a2","output":"two"},
    \\ {"type":"message","role":"assistant","content":[{"type":"output_text","text":"progress"}]},
    \\ {"role":"user","content":"now do X"},
    \\ {"type":"function_call","call_id":"a3","name":"bash","arguments":"{}"},
    \\ {"type":"function_call_output","call_id":"a3","output":"three"},
    \\ {"type":"function_call","call_id":"a4","name":"bash","arguments":"{}"},
    \\ {"type":"function_call_output","call_id":"a4","output":"four"},
    \\ {"type":"function_call","call_id":"a5","name":"bash","arguments":"{}"},
    \\ {"type":"function_call_output","call_id":"a5","output":"five"}
;

fn summarizedReply(a: Allocator, msgs: []const wire.Msg, kept: usize) !wire.Reply {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll("{\"stats\":{\"summarized\":true},\"decisions\":[],\"messages\":[");
    const neutral = try std.json.parseFromSliceLeaky(Value, a, try wire.request(a, msgs, "clef", null), .{ .allocate = .alloc_always });
    const sent = field(neutral, "messages").array.items;
    try std.json.Stringify.value(sent[0], .{}, w);
    try w.writeAll(",{\"role\":\"user\",\"text\":\"[compacted summary of 6 earlier messages]\\nRan two checks.\",\"toolUses\":[]}");
    for (sent[sent.len - kept ..]) |m| {
        try w.writeByte(',');
        try std.json.Stringify.value(m, .{}, w);
    }
    try w.writeAll("]}");
    return wire.parseReply(a, try std.json.parseFromSliceLeaky(Value, a, out.writer.buffered(), .{ .allocate = .alloc_always }));
}

test "ADR 0252: a summary keeps the unresolved turn's opening prompt and never orphans a result" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    // Unresolved (it ends on a tool result): the prompt at item 6 must survive.
    const unresolved = try parse(a, long_turn ++ "]");
    const msgs = try wire.transcript(a, unresolved);
    try std.testing.expectEqual(@as(usize, 13), msgs.len);
    const reply = try summarizedReply(a, msgs, wire.recent_kept);
    try std.testing.expectEqualStrings("Ran two checks.", reply.summary);
    const p = try wire.plan(a, msgs, &reply, 6);
    const stubber: TestStub = .{};
    const note = try @import("messages.zig").userNote(a, .responses, "SUMMARY");
    const fresh = try wire.apply(a, unresolved, msgs, p, &reply.decisions, 6, note, &stubber);
    try std.testing.expectEqualStrings("task", field(fresh.items[0], "content").string);
    try std.testing.expectEqualStrings("now do X", field(fresh.items[2], "content").string);
    try std.testing.expectEqual(@as(usize, 2 + 7), fresh.items.len); // task, summary, prompt, a3..a5 pairs
    try wire.checkPairs(a, unresolved, fresh.items);
    try std.testing.expectEqual(@as(usize, 5), (try wire.replaced(a, unresolved, msgs, p)).len); // items 1-5

    // Resolved by a reply: the newest six now open on a3's RESULT, so the cut
    // moves back over a3's call instead of shipping an orphan.
    const resolved = try parse(a, long_turn ++
        \\,{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}]
    );
    const msgs2 = try wire.transcript(a, resolved);
    const reply2 = try summarizedReply(a, msgs2, wire.recent_kept);
    const p2 = try wire.plan(a, msgs2, &reply2, null);
    const fresh2 = try wire.apply(a, resolved, msgs2, p2, &reply2.decisions, 6, note, &stubber);
    try std.testing.expectEqualStrings("a3", field(fresh2.items[2], "call_id").string);
    try std.testing.expectEqualStrings("function_call", field(fresh2.items[2], "type").string);
    try wire.checkPairs(a, resolved, fresh2.items);

    // An endpoint that moves its own cut back over the pair keeps seven
    // newest messages; the same history results.
    const reply3 = try summarizedReply(a, msgs2, wire.recent_kept + 1);
    const p3 = try wire.plan(a, msgs2, &reply3, null);
    const fresh3 = try wire.apply(a, resolved, msgs2, p3, &reply3.decisions, 6, note, &stubber);
    try std.testing.expectEqual(fresh2.items.len, fresh3.items.len);
    try std.testing.expectEqualStrings("a3", field(fresh3.items[2], "call_id").string);
    // Too few left to summarize: refused, not misread.
    try std.testing.expectError(error.UnexpectedReply, wire.plan(a, msgs2, &(try summarizedReply(a, msgs2, msgs2.len - 2)), null));
}

test "ADR 0252: a history that pairs worse than the one it replaces is refused" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const before = try parse(a,
        \\[{"role":"user","content":"go"},
        \\ {"type":"function_call","call_id":"f1","name":"bash","arguments":"{}"},
        \\ {"type":"function_call_output","call_id":"f1","output":"ok"}]
    );
    try std.testing.expectError(error.UnpairedToolCall, wire.checkPairs(a, before, &.{ before[0], before[2] }));
    try std.testing.expectError(error.UnpairedToolCall, wire.checkPairs(a, before, before[0..2]));
    // An unanswered call the session already had is not this compaction's doing.
    try wire.checkPairs(a, before[0..2], before[0..2]);
}

test "ADR 0252: refusals are read from the gateway's error envelope" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const credits = try std.json.parseFromSliceLeaky(Value, a, "{\"error\":{\"message\":\"m\",\"type\":\"insufficient_credits\",\"code\":\"insufficient_credits\"}}", .{});
    try std.testing.expectEqualStrings("insufficient_credits", hosted.refusal(credits).?);
    const ok = try std.json.parseFromSliceLeaky(Value, a, "{\"messages\":[],\"decisions\":[]}", .{});
    try std.testing.expect(hosted.refusal(ok) == null);
}

test "ADR 0252: the opt-out and a missing login leave compaction local" {
    const Env = struct {
        off: bool,
        pub fn get(self: @This(), key: []const u8) ?[]const u8 {
            return if (self.off and std.mem.eql(u8, key, "GRAFF_HOSTED_COMPACT")) "0" else null;
        }
    };
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    defer hosted.setLoginKey(std.testing.io, null);
    defer hosted.configure(a, Env{ .off = false }) catch {};
    var agent = @import("agent_compact_test_support.zig").subAgent(a, false);
    agent.io = std.testing.io;
    agent.messages = std.json.Array.init(a);
    try hosted.configure(a, Env{ .off = false });
    hosted.setLoginKey(std.testing.io, null);
    try std.testing.expect(try hosted.run(&agent) == null); // no login: nothing sent
    try hosted.configure(a, Env{ .off = true });
    hosted.setLoginKey(std.testing.io, "cg_sk_synthetic");
    try std.testing.expect(try hosted.run(&agent) == null); // opted out
}
