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
