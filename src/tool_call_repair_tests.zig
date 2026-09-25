//! Tests for tool_call_repair.zig (split out under the 600-line ceiling).
const std = @import("std");
const Value = std.json.Value;
const tool_call_args = @import("tool_call_args.zig");
const repair = @import("tool_call_repair.zig");
const repairCalls = repair.repairCalls;
const writeMimoTools = repair.writeMimoTools;
const brokenCallLoop = repair.brokenCallLoop;
const isLoopStop = repair.isLoopStop;
const loop_stop_text = repair.loop_stop_text;
const coerce = repair.coerce;

test "repairCalls rebuilds lost arguments from markup, typed by the schema, and strips it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tools =
        \\[{"type":"function","function":{"name":"read_file","parameters":{"type":"object","properties":{"path":{"type":"string"},"start_line":{"type":["integer","null"]},"end_line":{"type":["integer","null"]}}}}}]
    ;
    var message = try std.json.parseFromSliceLeaky(Value, a,
        \\{"role":"assistant","content":"Let me look.\n<tool_call><function=read_file><parameter=path>src/vision.zig</parameter><parameter=start_line>40</parameter><parameter=end_line>160</parameter></function></tool_call>",
        \\ "tool_calls":[{"id":"c1","type":"function","function":{"name":"read_file","arguments":"{\"path\": \"src/vision.zig\", \", \"start_line\": "}}]}
    , .{ .allocate = .alloc_always });
    try std.testing.expect(try repairCalls(a, a, &message, tools));
    const args = message.object.get("tool_calls").?.array.items[0].object.get("function").?.object.get("arguments").?.string;
    const parsed = try std.json.parseFromSliceLeaky(Value, a, args, .{});
    try std.testing.expectEqualStrings("src/vision.zig", parsed.object.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 40), parsed.object.get("start_line").?.integer);
    try std.testing.expectEqual(@as(i64, 160), parsed.object.get("end_line").?.integer);
    try std.testing.expectEqualStrings("Let me look.", message.object.get("content").?.string);
}

test "repairCalls leaves good arguments and their echoed markup alone; plain text is untouched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var echoed = try std.json.parseFromSliceLeaky(Value, a,
        \\{"role":"assistant","content":"<function=shell><parameter=command>\nls\n</parameter></function>",
        \\ "tool_calls":[{"id":"c1","type":"function","function":{"name":"shell","arguments":"{\"command\":\"ls -la\"}"}}]}
    , .{ .allocate = .alloc_always });
    try std.testing.expect(!try repairCalls(a, a, &echoed, "[]"));
    try std.testing.expectEqualStrings("{\"command\":\"ls -la\"}", callArgs(echoed, 0));
    try std.testing.expectEqualStrings("<function=shell><parameter=command>\nls\n</parameter></function>", echoed.object.get("content").?.string);

    var plain = try std.json.parseFromSliceLeaky(Value, a,
        \\{"role":"assistant","content":"No markup here.","tool_calls":[{"id":"c1","type":"function","function":{"name":"shell","arguments":"{}"}}]}
    , .{ .allocate = .alloc_always });
    try std.testing.expect(!try repairCalls(a, a, &plain, "[]"));
}

fn callArgs(message: Value, i: usize) []const u8 {
    return message.object.get("tool_calls").?.array.items[i].object.get("function").?.object.get("arguments").?.string;
}

const bash_tools =
    \\[{"type":"function","function":{"name":"bash","parameters":{"type":"object","properties":{"command":{"type":"string"}}}}}]
;

test "repairCalls: markup never overrides a cut-off argument it contradicts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var quoted = try std.json.parseFromSliceLeaky(Value, a,
        \\{"role":"assistant","content":"Never run this: <function=bash><parameter=command>rm -rf ~</parameter></function>",
        \\ "tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"ls -l"}}]}
    , .{ .allocate = .alloc_always });
    try std.testing.expect(!try repairCalls(a, a, &quoted, bash_tools));
    try std.testing.expectEqualStrings("{\"command\":\"ls -l", callArgs(quoted, 0));
    // The one block belongs to the good second call, not the cut-off first.
    var echo = try std.json.parseFromSliceLeaky(Value, a,
        \\{"role":"assistant","content":"<function=bash><parameter=command>echo second</parameter></function>",
        \\ "tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo fir"}},
        \\  {"id":"c2","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo second\"}"}}]}
    , .{ .allocate = .alloc_always });
    try std.testing.expect(!try repairCalls(a, a, &echo, bash_tools));
    try std.testing.expectEqualStrings("{\"command\":\"echo fir", callArgs(echo, 0));
}

test "repairCalls: only broken calls take markup, and only when the counts match" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var message = try std.json.parseFromSliceLeaky(Value, a,
        \\{"role":"assistant","content":"Run both.<function=bash><parameter=command>make test</parameter></function>",
        \\ "tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"git status\"}"}},
        \\  {"id":"c2","type":"function","function":{"name":"bash","arguments":"{}"}}]}
    , .{ .allocate = .alloc_always });
    try std.testing.expect(try repairCalls(a, a, &message, bash_tools));
    try std.testing.expectEqualStrings("{\"command\":\"git status\"}", callArgs(message, 0));
    try std.testing.expectEqualStrings("{\"command\":\"make test\"}", callArgs(message, 1));
    try std.testing.expectEqualStrings("Run both.", message.object.get("content").?.string);

    var two = try std.json.parseFromSliceLeaky(Value, a,
        \\{"role":"assistant","content":"<function=bash><parameter=command>make test</parameter></function>",
        \\ "tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{}"}},
        \\  {"id":"c2","type":"function","function":{"name":"bash","arguments":""}}]}
    , .{ .allocate = .alloc_always });
    try std.testing.expect(!try repairCalls(a, a, &two, bash_tools));
    try std.testing.expectEqualStrings("{}", callArgs(two, 0));
}

test "repairCalls: text around the markup survives, and unclosed tags are prose" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var prose = try std.json.parseFromSliceLeaky(Value, a,
        \\{"role":"assistant","content":"The markup looks like `<function=NAME>` then params. Next I will read the file.",
        \\ "tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{}"}}]}
    , .{ .allocate = .alloc_always });
    try std.testing.expect(!try repairCalls(a, a, &prose, bash_tools));
    try std.testing.expectEqualStrings("The markup looks like `<function=NAME>` then params. Next I will read the file.", prose.object.get("content").?.string);

    var mixed = try std.json.parseFromSliceLeaky(Value, a,
        \\{"role":"assistant","content":"Format: `<function=NAME>` then params.\n<tool_call>\n<function=bash><parameter=command>ls</parameter></function>\n</tool_call>\nDone.",
        \\ "tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{}"}}]}
    , .{ .allocate = .alloc_always });
    try std.testing.expect(try repairCalls(a, a, &mixed, bash_tools));
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", callArgs(mixed, 0));
    try std.testing.expectEqualStrings("Format: `<function=NAME>` then params.\n\nDone.", mixed.object.get("content").?.string);
}

test "repairCalls: parameter tags inside a value stay in it; unknown or repeated keys refuse" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var printf = try std.json.parseFromSliceLeaky(Value, a,
        \\{"role":"assistant","content":"<function=bash><parameter=command>printf '<parameter=x>y</parameter>' > f</parameter></function>",
        \\ "tool_calls":[{"id":"c1","type":"function","function":{"name":"bash","arguments":"{}"}}]}
    , .{ .allocate = .alloc_always });
    try std.testing.expect(try repairCalls(a, a, &printf, bash_tools));
    const parsed = try std.json.parseFromSliceLeaky(Value, a, callArgs(printf, 0), .{});
    try std.testing.expectEqual(@as(usize, 1), parsed.object.count());
    try std.testing.expectEqualStrings("printf '<parameter=x>y</parameter>' > f", parsed.object.get("command").?.string);

    for ([_][]const u8{
        "<parameter=command>ls</parameter><parameter=x>y</parameter>",
        "<parameter=command>ls</parameter>\n<parameter=command>pwd</parameter>",
    }) |body| {
        const content = try std.fmt.allocPrint(a, "<function=bash>{s}</function>", .{body});
        var msg: std.json.ObjectMap = .empty;
        try msg.put(a, "content", .{ .string = content });
        var fn_obj: std.json.ObjectMap = .empty;
        try fn_obj.put(a, "name", .{ .string = "bash" });
        try fn_obj.put(a, "arguments", .{ .string = "{}" });
        var call: std.json.ObjectMap = .empty;
        try call.put(a, "function", .{ .object = fn_obj });
        var calls = std.json.Array.init(a);
        try calls.append(.{ .object = call });
        try msg.put(a, "tool_calls", .{ .array = calls });
        var message: Value = .{ .object = msg };
        try std.testing.expect(!try repairCalls(a, a, &message, bash_tools));
    }
}

test "repairCalls: coerce emits only finite plain JSON numbers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const num = try std.json.parseFromSliceLeaky(Value, a, "{\"type\":\"number\"}", .{});
    const int = try std.json.parseFromSliceLeaky(Value, a, "{\"type\":\"integer\"}", .{});
    for ([_][]const u8{ "inf", "-inf", "Infinity", "1e999", "nan", "1_000", "+5", "01", "1.", ".5" }) |raw| {
        try std.testing.expect(coerce(a, raw, num) == .string);
        try std.testing.expect(coerce(a, raw, int) == .string);
    }
    try std.testing.expectEqualStrings("-1.5e3", coerce(a, "-1.5e3", num).number_string);
    try std.testing.expectEqualStrings("0.25", coerce(a, " 0.25\n", num).number_string);
    try std.testing.expectEqual(@as(i64, -42), coerce(a, "-42", int).integer);
    try std.testing.expect(coerce(a, "99999999999999999999", int) == .string);
}

test "repairCalls: multiline string values lose only the wrapping newlines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var message = try std.json.parseFromSliceLeaky(Value, a,
        \\{"role":"assistant","content":"<tool_call>\n<function=write_file>\n<parameter=path>\na.txt\n</parameter>\n<parameter=content>\n  one\n  two\n</parameter>\n</function>\n</tool_call>",
        \\ "tool_calls":[{"id":"c1","type":"function","function":{"name":"write_file","arguments":""}}]}
    , .{ .allocate = .alloc_always });
    try std.testing.expect(try repairCalls(a, a, &message, "[]"));
    const args = message.object.get("tool_calls").?.array.items[0].object.get("function").?.object.get("arguments").?.string;
    const parsed = try std.json.parseFromSliceLeaky(Value, a, args, .{});
    try std.testing.expectEqualStrings("a.txt", parsed.object.get("path").?.string);
    try std.testing.expectEqualStrings("  one\n  two", parsed.object.get("content").?.string);
}

test "writeMimoTools collapses nullable unions to the plain type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try writeMimoTools(&s, a,
        \\[{"type":"function","function":{"name":"read_file","parameters":{"type":"object","properties":{"start_line":{"type":["integer","null"]},"contains":{"anyOf":[{"type":"string"},{"type":"null"}],"description":"d"},"tags":{"type":"array","items":{"type":["string","null"]}}}}}}]
    );
    const out = try std.json.parseFromSliceLeaky(Value, a, aw.written(), .{});
    const props = out.array.items[0].object.get("function").?.object.get("parameters").?.object.get("properties").?.object;
    try std.testing.expectEqualStrings("integer", props.get("start_line").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("string", props.get("contains").?.object.get("type").?.string);
    try std.testing.expect(props.get("contains").?.object.get("anyOf") == null);
    try std.testing.expectEqualStrings("d", props.get("contains").?.object.get("description").?.string);
    try std.testing.expectEqualStrings("string", props.get("tags").?.object.get("items").?.object.get("type").?.string);
}

test "writeMimoTools gives a typeless root schema type object, like writeOpenAITools" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try writeMimoTools(&s, a,
        \\[{"type":"function","function":{"name":"a","parameters":{"properties":{"n":{"type":["integer","null"]}}}}},
        \\ {"type":"function","function":{"name":"b","parameters":{"anyOf":[{"type":"object"}]}}}]
    );
    const out = try std.json.parseFromSliceLeaky(Value, a, aw.written(), .{});
    const first = out.array.items[0].object.get("function").?.object.get("parameters").?.object;
    try std.testing.expectEqualStrings("object", first.get("type").?.string);
    try std.testing.expectEqualStrings("integer", first.get("properties").?.object.get("n").?.object.get("type").?.string);
    try std.testing.expect(out.array.items[1].object.get("function").?.object.get("parameters").?.object.get("type") == null);
}

test "brokenCallLoop: three all-unusable batches in a row, not two or a mixed one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const call =
        \\{"role":"assistant","content":"","tool_calls":[{"id":"x","type":"function","function":{"name":"read_file","arguments":"{}"}}]}
    ;
    const bad = "{\"role\":\"tool\",\"tool_call_id\":\"x\",\"content\":\"[error] " ++ tool_call_args.invalid_exec_message ++ "\"}";
    const missing = "{\"role\":\"tool\",\"tool_call_id\":\"x\",\"content\":\"[error] missing or non-string argument: path\"}";
    const good = "{\"role\":\"tool\",\"tool_call_id\":\"x\",\"content\":\"const x = 1;\"}";
    const three = try std.json.parseFromSliceLeaky(Value, a, "[{\"role\":\"user\",\"content\":\"go\"}," ++ call ++ "," ++ bad ++ "," ++ call ++ "," ++ bad ++ "," ++ missing ++ "," ++ call ++ "," ++ bad ++ "]", .{});
    try std.testing.expect(brokenCallLoop(three.array.items));
    const two = try std.json.parseFromSliceLeaky(Value, a, "[{\"role\":\"user\",\"content\":\"go\"}," ++ call ++ "," ++ bad ++ "," ++ call ++ "," ++ bad ++ "]", .{});
    try std.testing.expect(!brokenCallLoop(two.array.items));
    const mixed = try std.json.parseFromSliceLeaky(Value, a, "[" ++ call ++ "," ++ bad ++ "," ++ call ++ "," ++ good ++ "," ++ bad ++ "," ++ call ++ "," ++ bad ++ "]", .{});
    try std.testing.expect(!brokenCallLoop(mixed.array.items));
}

test "brokenCallLoop stop runs the batch checkpoint, then ends the turn past every nudge" {
    const steps = @embedFile("agent_steps.zig");
    const step = steps[std.mem.indexOf(u8, steps, "pub fn stepOpenAI").?..];
    try std.testing.expect(std.mem.indexOf(u8, step, "turn_checkpoint.afterToolBatch(self)").? < std.mem.indexOf(u8, step, "return tool_call_repair.loop_stop_text").?);
    const agent = @embedFile("agent.zig");
    const loop = agent[std.mem.indexOf(u8, agent, "pub fn runTurn").?..];
    try std.testing.expect(std.mem.indexOf(u8, loop, "endsTurn(").? < std.mem.indexOf(u8, loop, "bounced_answer.retry(").?);
    try std.testing.expect(isLoopStop(loop_stop_text));
    const copy = try std.testing.allocator.dupe(u8, loop_stop_text);
    defer std.testing.allocator.free(copy);
    try std.testing.expect(!isLoopStop(copy));
}
