//! Claude Agent (ADR 0309): wire and history facts, no child process.

const std = @import("std");
const Value = std.json.Value;
const wire = @import("claude_agent_wire.zig");
const history = @import("claude_agent_history.zig");

fn parse(a: std.mem.Allocator, json: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, json, .{ .allocate = .alloc_always });
}

fn has(argv: []const []const u8, flag: []const u8) ?usize {
    for (argv, 0..) |arg, i| if (std.mem.eql(u8, arg, flag)) return i;
    return null;
}

test "claude-agent argv: built-ins off, graff's tools the only allowed ones, no saved session" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try wire.argv(a, .{ .exe = "claude", .model = "sonnet", .effort = "high", .has_tools = true });
    try std.testing.expectEqualStrings("", argv[has(argv, "--tools").? + 1]);
    try std.testing.expectEqualStrings("mcp__graff__*", argv[has(argv, "--allowedTools").? + 1]);
    try std.testing.expectEqualStrings("dontAsk", argv[has(argv, "--permission-mode").? + 1]);
    try std.testing.expectEqualStrings("", argv[has(argv, "--setting-sources").? + 1]);
    try std.testing.expectEqualStrings("high", argv[has(argv, "--effort").? + 1]);
    try std.testing.expectEqualStrings("sonnet", argv[has(argv, "--model").? + 1]);
    try std.testing.expect(has(argv, "--no-session-persistence") != null);
    try std.testing.expect(has(argv, "--strict-mcp-config") != null);
    const cfg = try parse(a, argv[has(argv, "--mcp-config").? + 1]);
    try std.testing.expectEqualStrings("sdk", cfg.object.get("mcpServers").?.object.get("graff").?.object.get("type").?.string);
    // A tool-less side call offers no server at all.
    const bare = try wire.argv(a, .{ .exe = "claude", .model = "haiku", .effort = null, .has_tools = false });
    try std.testing.expect(has(bare, "--mcp-config") == null and has(bare, "--allowedTools") == null and has(bare, "--effort") == null);
}

test "claude-agent initialize: graff's prompt replaces Claude Code's, or is appended to it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const own = try parse(a, try wire.initRequest(a, "i1", .graff, "You are graff.", true));
    const r = own.object.get("request").?.object;
    try std.testing.expectEqualStrings("initialize", r.get("subtype").?.string);
    try std.testing.expectEqualStrings("You are graff.", r.get("systemPrompt").?.array.items[0].string);
    try std.testing.expectEqualStrings("graff", r.get("sdkMcpServers").?.array.items[0].string);
    try std.testing.expect(r.get("appendSystemPrompt") == null);
    const appended = try parse(a, try wire.initRequest(a, "i2", .claude, "You are graff.", false));
    const r2 = appended.object.get("request").?.object;
    try std.testing.expectEqualStrings("You are graff.", r2.get("appendSystemPrompt").?.string);
    try std.testing.expect(r2.get("systemPrompt") == null and r2.get("sdkMcpServers") == null);
    try std.testing.expectEqual(wire.PromptMode.claude, wire.promptMode("append"));
    try std.testing.expectEqual(wire.PromptMode.graff, wire.promptMode(null));
}

test "claude-agent user line: client-composed, so Claude Code adds no command parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const line = try parse(a, try wire.userLine(a, .{ .string = "/compact hi" }));
    try std.testing.expectEqualStrings("user", line.object.get("type").?.string);
    try std.testing.expect(line.object.get("client_composed").?.bool);
    try std.testing.expectEqualStrings("/compact hi", line.object.get("message").?.object.get("content").?.string);
}

test "claude-agent classify: stream events, held tool calls, results; subagent events skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ev = try wire.classify(a, "{\"type\":\"stream_event\",\"parent_tool_use_id\":null,\"event\":{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"mcp__graff__read_file\",\"input\":{}}}}");
    var event = ev.event;
    try std.testing.expect(wire.unprefixToolUse(&event));
    try std.testing.expectEqualStrings("read_file", event.object.get("content_block").?.object.get("name").?.string);
    const nested = try wire.classify(a, "{\"type\":\"stream_event\",\"parent_tool_use_id\":\"toolu_0\",\"event\":{\"type\":\"message_start\"}}");
    try std.testing.expect(nested == .ignore);
    const call = try wire.classify(a, "{\"type\":\"control_request\",\"request_id\":\"r9\",\"request\":{\"subtype\":\"mcp_message\",\"server_name\":\"graff\",\"message\":{\"method\":\"tools/call\",\"params\":{\"name\":\"read_file\",\"arguments\":{},\"_meta\":{\"claudecode/toolUseId\":\"toolu_1\"}},\"jsonrpc\":\"2.0\",\"id\":2}}}");
    try std.testing.expectEqualStrings("r9", call.control.request_id);
    try std.testing.expectEqualStrings("mcp_message", call.control.subtype);
    const failed = try wire.classify(a, "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"result\":\"Not logged in · Please run /login\"}");
    try std.testing.expect(failed.result.is_error);
    const ok = try wire.classify(a, "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"done\"}");
    try std.testing.expect(!ok.result.is_error);
    try std.testing.expect(try wire.classify(a, "not json") == .ignore);
    const resp = try wire.classify(a, "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"graff_init\",\"response\":{\"claude_code_version\":\"2.1.304\"}}}");
    try std.testing.expect(resp.response.ok);
}

test "claude-agent MCP: a new tool list is announced with list_changed, never a server reset (ADR 0311)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const init = try parse(a, try wire.initializeResult(a, "2025-06-18"));
    const caps = init.object.get("capabilities").?.object.get("tools").?.object;
    try std.testing.expect(caps.get("listChanged").?.bool);
    const req = try parse(a, wire.tools_changed_request);
    try std.testing.expectEqualStrings("mcp_message", req.object.get("subtype").?.string);
    try std.testing.expectEqualStrings(wire.server_name, req.object.get("server_name").?.string);
    const msg = req.object.get("message").?.object;
    try std.testing.expectEqualStrings("notifications/tools/list_changed", msg.get("method").?.string);
    try std.testing.expect(msg.get("id") == null); // a notification: Claude Code answers with a tools/list
    const src = @embedFile("claude_agent.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, "\\\"servers\\\":{}") == null);
}

test "claude-agent MCP: tools/list renames input_schema; a tool_result becomes MCP content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tools = try parse(a, "[{\"name\":\"shell\",\"description\":\"run\",\"input_schema\":{\"type\":\"object\"}}]");
    const listed = try parse(a, try wire.toolsList(a, tools));
    const t0 = listed.object.get("tools").?.array.items[0].object;
    try std.testing.expectEqualStrings("shell", t0.get("name").?.string);
    try std.testing.expectEqualStrings("object", t0.get("inputSchema").?.object.get("type").?.string);
    const block = try parse(a, "{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\",\"is_error\":true,\"content\":[{\"type\":\"text\",\"text\":\"boom\"},{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/jpeg\",\"data\":\"AAAA\"}}]}");
    const result = try parse(a, try wire.toolResult(a, block.object, "steer: also check tests"));
    const content = result.object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), content.len);
    try std.testing.expectEqualStrings("boom", content[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("image/jpeg", content[1].object.get("mimeType").?.string);
    try std.testing.expectEqualStrings("steer: also check tests", content[2].object.get("text").?.string);
    try std.testing.expect(result.object.get("isError").?.bool);
    const reply = try parse(a, try wire.mcpReply(a, "r9", "2", "{\"content\":[]}"));
    const mcp = reply.object.get("response").?.object.get("response").?.object.get("mcp_response").?.object;
    try std.testing.expectEqual(@as(i64, 2), mcp.get("id").?.integer);
}

test "claude-agent env: Claude Code's session identity never reaches the child" {
    try std.testing.expect(wire.dropsEnv("CLAUDECODE"));
    try std.testing.expect(wire.dropsEnv("CLAUDE_CODE_ENTRYPOINT"));
    try std.testing.expect(wire.dropsEnv("CLAUDE_CODE_SIMPLE"));
    try std.testing.expect(wire.dropsEnv("MCP_TOOL_TIMEOUT"));
    try std.testing.expect(wire.dropsEnv("CLAUDE_CODE_MESSAGING_SOCKET"));
    try std.testing.expect(!wire.dropsEnv("CLAUDE_CONFIG_DIR"));
    try std.testing.expect(!wire.dropsEnv("CLAUDE_CODE_OAUTH_TOKEN"));
    try std.testing.expect(!wire.dropsEnv("CLAUDE_CODE_USE_BEDROCK"));
    try std.testing.expect(!wire.dropsEnv("PATH"));
}

test "claude-agent version floor" {
    try std.testing.expect(wire.atLeast("2.1.304", wire.min_version));
    try std.testing.expect(wire.atLeast("2.1.248", wire.min_version));
    try std.testing.expect(!wire.atLeast("2.1.247", wire.min_version));
    try std.testing.expect(wire.atLeast("3.0.0-beta", wire.min_version));
    try std.testing.expect(!wire.atLeast("2.0.999", wire.min_version));
    try std.testing.expectEqualStrings("max", wire.effortFlag("ultra").?);
    try std.testing.expectEqualStrings("sonnet", wire.modelArg("claude-agent-sonnet"));
    try std.testing.expectEqualStrings("claude-opus-5-5[1m]", wire.modelArg("claude-opus-5-5[1m]"));
    try std.testing.expect(wire.effortFlag("none") == null);
}

test "claude-agent fresh session: earlier history is a checkpoint, the prompt keeps its blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msgs = try parse(a,
        \\[{"role":"user","content":"fix the bug"},
        \\ {"role":"assistant","content":[{"type":"thinking","thinking":"secret","signature":"s"},{"type":"tool_use","id":"t1","name":"read_file","input":{"path":"a.zig"}}]},
        \\ {"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"fn main() {}"}]},
        \\ {"role":"assistant","content":[{"type":"text","text":"done"}]},
        \\ {"role":"user","content":[{"type":"text","text":"now add a test","cache_control":{"type":"ephemeral"}}]}]
    );
    const content = try history.freshContent(a, msgs.array.items);
    const blocks = content.array.items;
    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    const cp = blocks[0].object.get("text").?.string;
    try std.testing.expect(std.mem.startsWith(u8, cp, "<conversation-checkpoint>"));
    try std.testing.expect(std.mem.indexOf(u8, cp, "<tool_call name=\"read_file\" id=\"t1\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, cp, "fn main() {}") != null);
    try std.testing.expect(std.mem.indexOf(u8, cp, "secret") == null); // no thinking text
    try std.testing.expectEqualStrings("now add a test", blocks[1].object.get("text").?.string);
    try std.testing.expect(blocks[1].object.get("cache_control") == null);
    // A prompt followed by graff's own notice is still the prompt, not history.
    const noticed = try parse(a,
        \\[{"role":"user","content":"spawn two workers"},{"role":"user","content":"Already loaded for this turn: subagent."}]
    );
    const fresh = try history.freshContent(a, noticed.array.items);
    try std.testing.expectEqual(@as(usize, 2), fresh.array.items.len);
    try std.testing.expectEqualStrings("spawn two workers", fresh.array.items[0].object.get("text").?.string);
    // Ending on tool results (a restart mid-loop): everything is checkpoint.
    const mid = try history.freshContent(a, msgs.array.items[0..3]);
    try std.testing.expectEqual(@as(usize, 2), mid.array.items.len);
    try std.testing.expect(std.mem.startsWith(u8, mid.array.items[1].object.get("text").?.string, "Continue"));
}

test "claude-agent delta: Claude's own reply is skipped; results and a new prompt are told apart" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tool_step = try parse(a,
        \\[{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"shell","input":{}},{"type":"tool_use","id":"t2","name":"shell","input":{}}]},
        \\ {"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"a"},{"type":"tool_result","tool_use_id":"t2","content":"b"},{"type":"text","text":"<reminder>"}]}]
    );
    const d = (try history.delta(a, tool_step.array.items)).?;
    try std.testing.expectEqual(@as(usize, 2), d.results.len);
    try std.testing.expectEqualStrings("t2", d.results[1].id);
    try std.testing.expectEqualStrings("<reminder>", d.extra_text);
    try std.testing.expect(d.user == null);
    const next = try parse(a,
        \\[{"role":"assistant","content":[{"type":"text","text":"done"}]},{"role":"user","content":"thanks, now B"}]
    );
    const d2 = (try history.delta(a, next.array.items)).?;
    try std.testing.expectEqual(@as(usize, 0), d2.results.len);
    try std.testing.expectEqualStrings("thanks, now B", d2.user.?.array.items[0].object.get("text").?.string);
    // An assistant message graff injected after the reply: not a live shape.
    const odd = try parse(a,
        \\[{"role":"assistant","content":"x"},{"role":"assistant","content":"y"},{"role":"user","content":"z"}]
    );
    try std.testing.expect(try history.delta(a, odd.array.items) == null);
    try std.testing.expect(try history.delta(a, next.array.items[0..1]) == null);
}

test "claude-agent history hash: a grown history keeps its prefix identity, a rewrite does not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try parse(a, "[{\"role\":\"user\",\"content\":\"a\"},{\"role\":\"assistant\",\"content\":\"b\"}]");
    const two = try parse(a, "[{\"role\":\"user\",\"content\":\"a\"},{\"role\":\"assistant\",\"content\":\"b\"},{\"role\":\"user\",\"content\":\"c\"}]");
    const edited = try parse(a, "[{\"role\":\"user\",\"content\":\"A\"},{\"role\":\"assistant\",\"content\":\"b\"}]");
    try std.testing.expectEqual(history.hashMessages(a, one.array.items), history.hashMessages(a, two.array.items[0..2]));
    try std.testing.expect(history.hashMessages(a, one.array.items) != history.hashMessages(a, edited.array.items));
}

test "claude-agent routing: once chosen it is the Claude plan; otherwise Claude names stay on anthropic" {
    const provider = @import("provider.zig");
    var keys: provider.Keys = .{ .values = @splat(null) };
    try std.testing.expect(keys.set("anthropic", "sk-ant-test", .environment));
    try std.testing.expectEqualStrings("anthropic", (try keys.providerFor("claude-opus-5-5")).id);
    try std.testing.expect(keys.set("claude-agent", "claude", .login));
    const opus = try keys.providerFor("claude-opus-5-5");
    try std.testing.expectEqualStrings("claude-agent", opus.id);
    try std.testing.expectEqualStrings("claude-agent", (try keys.providerFor("claude-opus-5")).id);
    try std.testing.expectEqualStrings("claude-opus-5-5", wire.modelArg(opus.model));
    // The first aliases still work, and still mean Claude Code's alias.
    const alias = try keys.providerFor("claude-agent-opus");
    try std.testing.expectEqualStrings("claude-agent", alias.id);
    try std.testing.expectEqualStrings("opus", wire.modelArg(alias.model));
    // A Claude model Claude Agent does not list keeps its own route.
    try std.testing.expectEqualStrings("anthropic", (try keys.providerFor("claude-opus-4-8")).id);
    try std.testing.expectEqualStrings("anthropic", (try keys.providerById("anthropic", "claude-opus-5-5")).id);
}
