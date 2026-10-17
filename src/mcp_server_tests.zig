const std = @import("std");
const mcp = @import("mcp_server.zig");
const Value = std.json.Value;
const init = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\"}}\n" ++
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n";

fn fake(_: ?*anyopaque, _: std.mem.Allocator, task: mcp.Task) !mcp.Result {
    if (std.mem.eql(u8, task.prompt, "fail")) return error.MockFailure;
    return .{ .text = task.prompt };
}
fn check(a: std.mem.Allocator, input: []const u8) ![]const u8 {
    var source = std.Io.Reader.fixed(input);
    var out: std.Io.Writer.Allocating = .init(a);
    var server: mcp.Server = .{ .execute = fake };
    try mcp.serve(a, &source, &out.writer, &server);
    return out.written();
}

test "MCP handshake discovery and tool call return newline framed JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try check(a, init ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":\"task\",\"method\":\"tools/call\",\"params\":{\"name\":\"run_task\",\"arguments\":{\"prompt\":\"hello\\nworld\"}}}\n");
    var lines = std.mem.tokenizeScalar(u8, result, '\n');
    const hello = try std.json.parseFromSliceLeaky(Value, a, lines.next().?, .{});
    try std.testing.expectEqualStrings("codegraff", hello.object.get("result").?.object.get("serverInfo").?.object.get("name").?.string);
    try std.testing.expect(hello.object.get("result").?.object.get("capabilities").?.object.get("tools").? == .object);
    const list = try std.json.parseFromSliceLeaky(Value, a, lines.next().?, .{});
    const tool = list.object.get("result").?.object.get("tools").?.array.items[0];
    try std.testing.expectEqualStrings("run_task", tool.object.get("name").?.string);
    const call = try std.json.parseFromSliceLeaky(Value, a, lines.next().?, .{});
    try std.testing.expectEqualStrings("task", call.object.get("id").?.string);
    try std.testing.expectEqualStrings("hello\nworld", call.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string);
    try std.testing.expect(lines.next() == null);
}

test "MCP rejects malformed requests and recovers for ping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try check(arena.allocator(), "{bad\n[]\n{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"ping\"}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"ping\"}\n");
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, result, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, result, "-32700") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":4,\"result\":{}") != null);
}

test "MCP rejects calls before initialization and ignores notifications" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try check(arena.allocator(), "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}\n" ++
        "{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"run_task\",\"arguments\":{\"prompt\":\"fail\"}}}\n");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, result, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, result, "Initialize the server first") != null);
}

test "MCP argument validation bounds work and rejects configuration injection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "null",                                     "{}",                                         "{\"prompt\":\" \"}",                        "{\"prompt\":2}",
        "{\"prompt\":\"x\",\"timeout_seconds\":0}", "{\"prompt\":\"x\",\"timeout_seconds\":301}", "{\"prompt\":\"x\",\"max_model_calls\":33}", "{\"prompt\":\"x\",\"max_model_calls\":1.5}",
        "{\"prompt\":\"x\",\"cwd\":\"/tmp\"}",      "{\"prompt\":\"x\",\"yolo\":true}",           "{\"prompt\":\"x\\u0000y\"}",
    }) |input| {
        const value = try std.json.parseFromSliceLeaky(Value, a, input, .{});
        try std.testing.expectError(error.InvalidArguments, mcp.parseTask(value));
    }
    const task = try mcp.parseTask(try std.json.parseFromSliceLeaky(Value, a, "{\"prompt\":\"x\",\"timeout_seconds\":300,\"max_model_calls\":32}", .{}));
    try std.testing.expectEqual(@as(u64, 300), task.timeout_seconds);
    try std.testing.expectEqual(@as(u64, 32), task.max_model_calls);
}

test "MCP context is bounded text, never configuration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const task = try mcp.parseTask(try std.json.parseFromSliceLeaky(Value, a, "{\"prompt\":\"x\",\"context\":\"prior decisions\"}", .{}));
    try std.testing.expectEqualStrings("prior decisions", task.context.?);
    // Absent context stays absent: the flag is only added when there is text.
    try std.testing.expect((try mcp.parseTask(try std.json.parseFromSliceLeaky(Value, a, "{\"prompt\":\"x\"}", .{}))).context == null);
    const filler = try a.alloc(u8, 32769);
    @memset(filler, 'a');
    const over = try std.fmt.allocPrint(a, "{{\"prompt\":\"x\",\"context\":\"{s}\"}}", .{filler});
    for ([_][]const u8{
        "{\"prompt\":\"x\",\"context\":\"\"}",
        "{\"prompt\":\"x\",\"context\":\"  \"}",
        "{\"prompt\":\"x\",\"context\":5}",
        "{\"prompt\":\"x\",\"context\":\"a\\u0000b\"}",
        over,
    }) |input| {
        const value = try std.json.parseFromSliceLeaky(Value, a, input, .{});
        try std.testing.expectError(error.InvalidArguments, mcp.parseTask(value));
    }
}

test "MCP task argv appends context as text and keeps server-owned policy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx: mcp.Context = .{ .io = std.testing.io, .exe = "/fake/graff", .env = undefined };
    const task: mcp.Task = .{ .prompt = "do the thing", .context = "prior decisions", .max_model_calls = 3 };
    const argv = try mcp.taskArgv(a, &ctx, task, "\n\nBackground context:\n\nprior decisions");
    const joined = try std.mem.join(a, "\u{1}", argv);
    try std.testing.expect(std.mem.indexOf(u8, joined, "--append-system-prompt\u{1}\n\nBackground context:\n\nprior decisions") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "--safe") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "--yolo") == null);
    // The task prompt is still the last argument, and context never becomes a flag.
    try std.testing.expect(std.mem.endsWith(u8, joined, "-p\u{1}do the thing"));
    // No context means no flag at all.
    const bare = try mcp.taskArgv(a, &ctx, .{ .prompt = "x" }, null);
    try std.testing.expect(std.mem.indexOf(u8, try std.mem.join(a, "\u{1}", bare), "--append-system-prompt") == null);
}

test "MCP reports the context it carried" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var server: mcp.Server = .{ .execute = fake_context, .initialized = true, .ready = true };
    var out: std.Io.Writer.Allocating = .init(a);
    try server.handle(a, &out.writer, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"run_task\",\"arguments\":{\"prompt\":\"x\",\"context\":\"hi\"}}}");
    const response = try std.json.parseFromSliceLeaky(Value, a, out.written(), .{});
    const result = response.object.get("result").?;
    const data = result.object.get("structuredContent").?;
    try std.testing.expectEqual(@as(i64, 40), data.object.get("context_chars").?.integer);
    try std.testing.expect(data.object.get("context_summarized").?.bool);
    try std.testing.expectEqual(@as(i64, 7), data.object.get("context_used_chars").?.integer);
    // Unavailable usage is stated, not omitted: a client must be able to tell
    // "no charge reported" apart from "the field was dropped".
    try std.testing.expect(!data.object.get("usage_reported").?.bool);
    try std.testing.expect(data.object.get("usage_unavailable_reason").?.string.len > 0);
    // The same metadata rides the namespaced slot for raw-result readers.
    const meta = result.object.get("_meta").?.object.get("codegraff/runTask").?;
    try std.testing.expectEqual(@as(i64, 40), meta.object.get("context_chars").?.integer);
    try std.testing.expectEqual(@as(i64, 7), meta.object.get("context_used_chars").?.integer);
    try std.testing.expect(!meta.object.get("usage_reported").?.bool);
    try std.testing.expectEqualStrings(data.object.get("usage_unavailable_reason").?.string, meta.object.get("usage_unavailable_reason").?.string);
}

fn fake_context(_: ?*anyopaque, a: std.mem.Allocator, task: mcp.Task) !mcp.Result {
    _ = a;
    return .{ .text = task.prompt, .context_chars = 40, .context_summarized = true, .context_used_chars = 7 };
}

// The summarizer's settled-charge parsing, without spawning a child.
// A charge is reported only when the engine said the usage was complete and
// nothing was unpriced or missing; otherwise the cost is null, never guessed.
test "summarizer usage: a settled charge is read, an incomplete one is not invented" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const good = try mcp.parseTurn(a, "{\"type\":\"text\",\"text\":\"noise\"}\n" ++
        "{\"type\":\"turn\",\"text\":\"  the summary  \",\"cost_usd\":0.0012,\"usage_complete\":true," ++
        "\"input_tokens\":1200,\"output_tokens\":30,\"unpriced_calls\":0,\"missing_usage_calls\":0}\n");
    try std.testing.expectEqualStrings("the summary", good.text);
    try std.testing.expect(good.usage.usage_complete);
    try std.testing.expectEqual(@as(f64, 0.0012), good.usage.cost_usd.?);
    try std.testing.expectEqual(@as(u64, 1200), good.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 30), good.usage.output_tokens);

    // Every way the report can be incomplete: no number is claimed.
    for ([_][]const u8{
        "{\"type\":\"turn\",\"text\":\"s\",\"cost_usd\":0.5,\"usage_complete\":false}",
        "{\"type\":\"turn\",\"text\":\"s\",\"cost_usd\":0.5,\"usage_complete\":true,\"unpriced_calls\":1}",
        "{\"type\":\"turn\",\"text\":\"s\",\"cost_usd\":0.5,\"usage_complete\":true,\"missing_usage_calls\":2}",
        "{\"type\":\"turn\",\"text\":\"s\",\"usage_complete\":true}",
    }) |line| {
        const m = try mcp.parseTurn(a, line);
        try std.testing.expect(m.usage.cost_usd == null);
        try std.testing.expect(!m.usage.usage_complete);
    }

    // No turn event at all, and an empty answer, are failures — not an empty
    // context handed to a child.
    try std.testing.expectError(error.ContextSummarizationFailed, mcp.parseTurn(a, "{\"type\":\"text\",\"text\":\"x\"}\n"));
    try std.testing.expectError(error.ContextSummarizationFailed, mcp.parseTurn(a, "{\"type\":\"turn\",\"text\":\"   \"}\n"));
    try std.testing.expectError(error.ContextSummarizationFailed, mcp.parseTurn(a, "not json at all\n"));
}

test "MCP execution errors are tool errors and server remains usable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try check(arena.allocator(), init ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"run_task\",\"arguments\":{\"prompt\":\"fail\"}}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}\n");
    try std.testing.expect(std.mem.indexOf(u8, result, "\"isError\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "MockFailure") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"id\":3,\"result\":{}") != null);
}

test "MCP task HTTP deadline outlives the validated child budget" {
    const a = std.testing.allocator;
    const default = "{\"params\":{\"arguments\":{\"prompt\":\"hello\"}}}";
    try std.testing.expectEqual(@as(i64, 135), mcp.transportTimeoutSeconds(a, "tools/call", "run_task", default));
    const bounded = "{\"params\":{\"arguments\":{\"prompt\":\"hello\",\"timeout_seconds\":300}}}";
    try std.testing.expectEqual(@as(i64, 315), mcp.transportTimeoutSeconds(a, "tools/call", "run_task", bounded));
    try std.testing.expectEqual(@as(i64, 15), mcp.transportTimeoutSeconds(a, "tools/list", "run_task", bounded));
    try std.testing.expectEqual(@as(i64, 15), mcp.transportTimeoutSeconds(a, "tools/call", "other", bounded));
    try std.testing.expectEqual(@as(i64, 15), mcp.transportTimeoutSeconds(a, "tools/call", null, bounded));
}

test "MCP task HTTP deadline includes only required context preprocessing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const context = try a.alloc(u8, 8193);
    @memset(context, 'x');
    const long = try std.fmt.allocPrint(a, "{{\"params\":{{\"arguments\":{{\"prompt\":\"hello\",\"context\":\"{s}\",\"timeout_seconds\":300}}}}}}", .{context});
    try std.testing.expectEqual(@as(i64, 375), mcp.transportTimeoutSeconds(a, "tools/call", "run_task", long));
    const short = try std.fmt.allocPrint(a, "{{\"params\":{{\"arguments\":{{\"prompt\":\"hello\",\"context\":\"{s}\",\"timeout_seconds\":300}}}}}}", .{context[0..8192]});
    try std.testing.expectEqual(@as(i64, 315), mcp.transportTimeoutSeconds(a, "tools/call", "run_task", short));
}

test "MCP task HTTP deadline rejects unbounded or malformed inputs" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "not json",                                                                "null",                                                                   "{}",                                                                      "{\"params\":[]}",
        "{\"params\":{\"arguments\":{\"prompt\":\"x\",\"timeout_seconds\":301}}}", "{\"params\":{\"arguments\":{\"prompt\":\"x\",\"timeout_seconds\":-1}}}", "{\"params\":{\"arguments\":{\"prompt\":\"x\",\"timeout_seconds\":1.5}}}", "{\"params\":{\"arguments\":{\"prompt\":\"x\",\"cwd\":\"other\"}}}",
    }) |input| try std.testing.expectEqual(@as(i64, 15), mcp.transportTimeoutSeconds(a, "tools/call", "run_task", input));
}

test "MCP failed task preserves partial output and truncation markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try mcp.formatResult(a, .{
        .term = .{ .exited = 1 },
        .stdout = try a.dupe(u8, "partial"),
        .stderr = try a.dupe(u8, "diagnostic"),
        .stdout_truncated = true,
        .stderr_truncated = true,
        .timed_out = true,
    });
    try std.testing.expect(result.isError);
    try std.testing.expect(std.mem.startsWith(u8, result.text, "partial"));
    try std.testing.expect(std.mem.indexOf(u8, result.text, "timed out") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Diagnostics truncated") != null);
}

test "MCP Apps negotiate metadata and serve only the declared resource" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const app = @import("mcp_server_app.zig");
    const params = try std.json.parseFromSliceLeaky(Value, a,
        \\{"capabilities":{"extensions":{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]}}}}
    , .{});
    try std.testing.expect(app.supported(params));
    try std.testing.expect(!app.supported(.null));
    var server: mcp.Server = .{ .execute = fake, .initialized = true, .ready = true, .apps = true };
    var out: std.Io.Writer.Allocating = .init(a);
    try server.handle(a, &out.writer, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}");
    const listed = try std.json.parseFromSliceLeaky(Value, a, out.written(), .{});
    const tool = listed.object.get("result").?.object.get("tools").?.array.items[0];
    try std.testing.expectEqualStrings(app.uri, tool.object.get("_meta").?.object.get("ui").?.object.get("resourceUri").?.string);
    const result = try check(a, init ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"resources/read\",\"params\":{\"uri\":\"ui://codegraff/task-result\"}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"resources/read\",\"params\":{\"uri\":\"file:///private\"}}\n");
    var lines = std.mem.tokenizeScalar(u8, result, '\n');
    _ = lines.next();
    const read = try std.json.parseFromSliceLeaky(Value, a, lines.next().?, .{});
    const resource = read.object.get("result").?.object.get("contents").?.array.items[0];
    try std.testing.expectEqualStrings(app.mime, resource.object.get("mimeType").?.string);
    try std.testing.expect(std.mem.startsWith(u8, resource.object.get("text").?.string, "<!doctype html>"));
    const rejected = try std.json.parseFromSliceLeaky(Value, a, lines.next().?, .{});
    try std.testing.expectEqual(@as(i64, -32002), rejected.object.get("error").?.object.get("code").?.integer);
}

test "MCP plain clients keep text fallback and structured errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try check(a, init ++
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"run_task\",\"arguments\":{\"prompt\":\"fail\",\"timeout_seconds\":5}}}\n");
    var lines = std.mem.tokenizeScalar(u8, result, '\n');
    _ = lines.next();
    const list = try std.json.parseFromSliceLeaky(Value, a, lines.next().?, .{});
    const tool = list.object.get("result").?.object.get("tools").?.array.items[0];
    try std.testing.expect(!tool.object.contains("_meta"));
    try std.testing.expect(tool.object.contains("outputSchema"));
    const templates = try check(a, init ++ "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"resources/templates/list\"}\n");
    try std.testing.expect(std.mem.indexOf(u8, templates, "\"resourceTemplates\":[]") != null);
    const response = try std.json.parseFromSliceLeaky(Value, a, lines.next().?, .{});
    const call = response.object.get("result").?;
    const data = call.object.get("structuredContent").?;
    try std.testing.expectEqualStrings("failed", data.object.get("status").?.string);
    try std.testing.expectEqual(@as(i64, 5), data.object.get("timeout_seconds").?.integer);
    try std.testing.expectEqualStrings(call.object.get("content").?.array.items[0].object.get("text").?.string, data.object.get("text").?.string);
}
