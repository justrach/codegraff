//! Official xAI prompt-cache + Responses WS contract, against shipped builders.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const http = @import("http.zig");
const http_headers = @import("http_headers.zig");
const codex_chain = @import("codex_chain.zig");
const agent_ws = @import("agent_ws.zig");
const ws = @import("ws.zig");

fn textMessage(arena: std.mem.Allocator, role: []const u8, text: []const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "role", .{ .string = role });
    try obj.put(arena, "content", .{ .string = text });
    return .{ .object = obj };
}

fn xaiAgent(arena: std.mem.Allocator, label: []const u8, kind: @import("provider.zig").Provider.Kind) !Agent {
    var messages = std.json.Array.init(arena);
    try messages.append(try textMessage(arena, "user", "hello"));
    return .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "xai", .kind = kind, .auth = .bearer, .url = "https://api.x.ai/v1/responses", .api_key = "k", .model = "grok-4.6", .context = 500_000 },
        .messages = messages,
        .sub = !std.mem.eql(u8, label, "main"),
        .label = label,
        .out = null,
        .sys_normal = "system",
    };
}

fn cacheKeyIn(body: []const u8) ?[]const u8 {
    const needle = "\"prompt_cache_key\":\"";
    const start = std.mem.indexOf(u8, body, needle) orelse return null;
    const from = start + needle.len;
    const end = std.mem.indexOfScalarPos(u8, body, from, '"') orelse return null;
    return body[from..end];
}

test "grok spec: Chat Completions x-grok-conv-id is stable for root; child is a role lane not the root id" {
    const io = std.testing.io;
    var root_slot: usize = 1;
    var child_slot: usize = 2;
    var rbuf: [96]u8 = undefined;
    var cbuf: [96]u8 = undefined;
    const root_id = http_headers.promptCacheKey(io, "main", @ptrCast(&root_slot), &rbuf);
    var rbuf2: [96]u8 = undefined;
    try std.testing.expectEqualStrings(root_id, http_headers.promptCacheKey(io, "main", @ptrCast(&root_slot), &rbuf2));
    try std.testing.expectEqualStrings(root_id, http_headers.projectRootId(io));
    try std.testing.expect(!std.mem.eql(u8, root_id, http_headers.sessionId(io)));
    const child_id = http_headers.promptCacheKey(io, "sub", @ptrCast(&child_slot), &cbuf);
    try std.testing.expect(!std.mem.eql(u8, root_id, child_id));
    var sib_slot: usize = 3;
    var sbuf: [96]u8 = undefined;
    try std.testing.expectEqualStrings(child_id, http_headers.promptCacheKey(io, "sub", @ptrCast(&sib_slot), &sbuf));

    const xai: @import("provider.zig").Provider = .{ .id = "xai", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "grok-4.6", .context = 500_000 };
    var h1: [12]std.http.Header = undefined;
    var h2: [12]std.http.Header = undefined;
    var h3: [12]std.http.Header = undefined;
    const a = http_headers.providerHeadersWithConv(io, xai, "Bearer k", &h1, root_id);
    const b = http_headers.providerHeadersWithConv(io, xai, "Bearer k", &h2, root_id);
    const c = http_headers.providerHeadersWithConv(io, xai, "Bearer k", &h3, child_id);
    const va = blk: {
        for (a) |h| if (std.mem.eql(u8, h.name, "x-grok-conv-id")) break :blk h.value;
        return error.MissingGrokConvId;
    };
    const vb = blk: {
        for (b) |h| if (std.mem.eql(u8, h.name, "x-grok-conv-id")) break :blk h.value;
        return error.MissingGrokConvId;
    };
    const vc = blk: {
        for (c) |h| if (std.mem.eql(u8, h.name, "x-grok-conv-id")) break :blk h.value;
        return error.MissingGrokConvId;
    };
    try std.testing.expectEqualStrings(root_id, va);
    try std.testing.expectEqualStrings(va, vb);
    try std.testing.expectEqualStrings(child_id, vc);
    try std.testing.expect(!std.mem.eql(u8, va, vc));
    // grok-build: session-id stays the conversation; conv-id isolates a child.
    const sa = blk: {
        for (a) |h| if (std.mem.eql(u8, h.name, "x-grok-session-id")) break :blk h.value;
        return error.MissingGrokSessionId;
    };
    const sc = blk: {
        for (c) |h| if (std.mem.eql(u8, h.name, "x-grok-session-id")) break :blk h.value;
        return error.MissingGrokSessionId;
    };
    try std.testing.expectEqualStrings(root_id, sa);
    try std.testing.expectEqualStrings(root_id, sc);
}

// The !live request path: Agent.request → promptCacheKey → postWatched → post.
// A local server records the x-grok-conv-id each POST actually sent.
test "grok spec: !live post wires Agent conv id; root and child differ" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var root = try xaiAgent(a, "main", .openai);
    var child = try xaiAgent(a, "sub", .responses);
    var rbuf: [96]u8 = undefined;
    var cbuf: [96]u8 = undefined;
    const rid = http_headers.promptCacheKey(root.io, root.label, &root, &rbuf);
    const cid = http_headers.promptCacheKey(child.io, child.label, &child, &cbuf);
    try std.testing.expect(!std.mem.eql(u8, rid, cid));
    const child_body = try child.buildBody(null, false, false, false);
    defer gpa.free(child_body);
    const body_key = cacheKeyIn(child_body) orelse return error.MissingPromptCacheKey;
    try std.testing.expectEqualStrings(cid, body_key);

    const Srv = struct {
        seen: [2][96]u8 = undefined,
        lens: [2]usize = .{ 0, 0 },
        n: usize = 0,
        fn run(io_: std.Io, server: *std.Io.net.Server, self: *@This()) void {
            while (self.n < 2) {
                const c = server.accept(io_) catch return;
                defer c.close(io_);
                var rbuf2: [4096]u8 = undefined;
                var sr = std.Io.net.Stream.Reader.init(c, io_, &rbuf2);
                while (true) {
                    const line = (sr.interface.takeDelimiter('\n') catch break) orelse break;
                    if (line.len == 0 or (line.len == 1 and line[0] == '\r')) break;
                    if (std.ascii.startsWithIgnoreCase(line, "x-grok-conv-id:")) {
                        const v = std.mem.trim(u8, line["x-grok-conv-id:".len..], " \t\r");
                        const n = @min(v.len, self.seen[self.n].len);
                        @memcpy(self.seen[self.n][0..n], v[0..n]);
                        self.lens[self.n] = n;
                    }
                }
                _ = sr.interface.take(2) catch {};
                var wbuf: [128]u8 = undefined;
                var sw = std.Io.net.Stream.Writer.init(c, io_, &wbuf);
                sw.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok") catch {};
                sw.interface.flush() catch {};
                self.n += 1;
            }
        }
    };
    var srv: Srv = .{};
    var addr = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    var fut = io.async(Srv.run, .{ io, &server, &srv });
    var bound = server.socket.address;
    defer {
        if (std.Io.net.IpAddress.connect(&bound, io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        fut.await(io);
        server.deinit(io);
    }
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/chat", .{bound.getPort()});
    var p_root = root.provider;
    p_root.url = url;
    var p_child = child.provider;
    p_child.url = url;
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const r1 = http.postWatched(gpa, io, &client, p_root, "{}", rid) catch |e| {
        if (std.Io.net.IpAddress.connect(&bound, io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        return e;
    };
    defer gpa.free(r1);
    const r2 = http.postWatched(gpa, io, &client, p_child, child_body, cid) catch |e| {
        if (std.Io.net.IpAddress.connect(&bound, io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        return e;
    };
    defer gpa.free(r2);
    try std.testing.expectEqual(@as(usize, 2), srv.n);
    try std.testing.expectEqualStrings(rid, srv.seen[0][0..srv.lens[0]]);
    try std.testing.expectEqualStrings(cid, srv.seen[1][0..srv.lens[1]]);
    try std.testing.expectEqualStrings(body_key, srv.seen[1][0..srv.lens[1]]);
    try std.testing.expect(!std.mem.eql(u8, srv.seen[0][0..srv.lens[0]], srv.seen[1][0..srv.lens[1]]));
}

test "grok spec: Responses body has a stable prompt_cache_key; Anthropic does not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = try xaiAgent(a, "main", .responses);
    const first = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(first);
    const second = try agent.buildBody(null, false, true, true);
    defer std.testing.allocator.free(second);
    const k1 = cacheKeyIn(first) orelse return error.MissingPromptCacheKey;
    const k2 = cacheKeyIn(second) orelse return error.MissingPromptCacheKey;
    try std.testing.expectEqualStrings(k1, k2);
    try std.testing.expect(k1.len > 0);

    var anth = try xaiAgent(a, "main", .anthropic);
    anth.provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "k", .model = "claude", .context = 200_000 };
    const abody = try anth.buildBody(null, false, true, true);
    defer std.testing.allocator.free(abody);
    try std.testing.expect(cacheKeyIn(abody) == null);
}

test "grok spec: native grok-4.6 sends effort; gateway grok-build does not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var resp = try xaiAgent(a, "main", .responses);
    resp.reasoning = .xhigh;
    const rb = try resp.buildBody(null, false, true, true);
    defer std.testing.allocator.free(rb);
    try std.testing.expect(std.mem.indexOf(u8, rb, "\"effort\":\"xhigh\"") != null);

    var chat = try xaiAgent(a, "main", .openai);
    chat.reasoning = .xhigh;
    const cb = try chat.buildBody(null, false, true, true);
    defer std.testing.allocator.free(cb);
    try std.testing.expect(std.mem.indexOf(u8, cb, "\"reasoning_effort\":\"xhigh\"") != null);

    var gw = try xaiAgent(a, "main", .openai);
    gw.provider.id = "codegraff";
    gw.provider.model = "grok-build";
    gw.reasoning = .xhigh;
    const gb = try gw.buildBody(null, false, true, true);
    defer std.testing.allocator.free(gb);
    try std.testing.expect(std.mem.indexOf(u8, gb, "\"reasoning_effort\"") == null);
}

test "grok spec: held xAI WS chains previous_response_id + delta; drop rebuilds full input" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    try msgs.append(try textMessage(a, "user", "first"));
    try msgs.append(try textMessage(a, "assistant", "second"));
    try msgs.append(try textMessage(a, "user", "third — not yet sent"));
    var dummy_ws: ws.WsClient = undefined;
    var agent = try xaiAgent(a, "main", .responses);
    agent.messages = msgs;
    agent.codex_ws = &dummy_ws;
    agent.codex_prev_id = try std.testing.allocator.dupe(u8, "resp_live");
    agent.codex_sent_upto = 2;
    agent.codex_props_fp = codex_chain.propsFor(&agent);
    // On-socket xAI chaining is opt-in (GRAFF_XAI_WS_CHAIN — a live probe
    // reproduced a silent stall, so it is off by default); the contract
    // being conformance-tested here is the opted-in behavior.
    codex_chain.g_xai_ws_chain = true;
    defer codex_chain.g_xai_ws_chain = false;
    try std.testing.expect(codex_chain.chainUsable(&agent));

    const delta = try agent.buildBody(null, false, false, false);
    defer std.testing.allocator.free(delta);
    try std.testing.expect(std.mem.indexOf(u8, delta, "\"previous_response_id\":\"resp_live\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, delta, "third — not yet sent") != null);
    try std.testing.expect(std.mem.indexOf(u8, delta, "\"first\"") == null);
    try std.testing.expect(cacheKeyIn(delta) != null);

    try std.testing.expect(codex_chain.shouldDropChain("Previous response with id 'resp_live' not found.", "previous_response_not_found"));
    try std.testing.expect(codex_chain.shouldDropChain("connection limit reached (25 minutes)", "websocket_connection_limit_reached"));
    try std.testing.expect(!agent_ws.wsLifetimeExpired(agent_ws.ws_lifetime_ms, 0));
    try std.testing.expect(agent_ws.wsLifetimeExpired(2 * agent_ws.ws_lifetime_ms, agent_ws.ws_lifetime_ms));

    // store=false drop: same state closeCodexWs leaves — full input, no prev id.
    std.testing.allocator.free(agent.codex_prev_id.?);
    agent.codex_ws = null;
    agent.codex_prev_id = null;
    agent.codex_sent_upto = 0;
    try std.testing.expect(!codex_chain.chainUsable(&agent));
    const rebuilt = try agent.buildBody(null, false, false, false);
    defer std.testing.allocator.free(rebuilt);
    try std.testing.expect(std.mem.indexOf(u8, rebuilt, "\"previous_response_id\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, rebuilt, "\"first\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rebuilt, "third — not yet sent") != null);
}

// Official xAI prompt-caching contract
// (docs.x.ai/developers/advanced-api-usage/prompt-caching):
// Chat always sets x-grok-conv-id; Responses sets prompt_cache_key; same
// routing id. Cache is an exact messages prefix — append only. Usage is
// prompt_tokens_details.cached_tokens (Chat) /
// input_tokens_details.cached_tokens (Responses). xAI must not receive
// OpenAI prompt_cache_options / prompt_cache_breakpoint (ADR 0009).

test "grok spec: official cache routing — Chat header and Responses body share one id" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var chat = try xaiAgent(a, "main", .openai);
    var resp = try xaiAgent(a, "main", .responses);
    var kbuf: [96]u8 = undefined;
    const key = http_headers.promptCacheKey(io, "main", &resp, &kbuf);
    try std.testing.expectEqualStrings(http_headers.projectRootId(io), key);

    var hbuf: [12]std.http.Header = undefined;
    const hdrs = http_headers.providerHeadersWithConv(io, chat.provider, "Bearer k", &hbuf, key);
    const header = blk: {
        for (hdrs) |h| if (std.mem.eql(u8, h.name, "x-grok-conv-id")) break :blk h.value;
        return error.MissingGrokConvId;
    };
    try std.testing.expectEqualStrings(key, header);

    const chat_body = try chat.buildBody(null, false, false, false);
    defer std.testing.allocator.free(chat_body);
    const resp_body = try resp.buildBody(null, false, false, false);
    defer std.testing.allocator.free(resp_body);
    try std.testing.expectEqualStrings(key, cacheKeyIn(resp_body) orelse return error.MissingPromptCacheKey);
    try std.testing.expectEqualStrings(key, cacheKeyIn(chat_body) orelse return error.MissingPromptCacheKey);
    try std.testing.expect(std.mem.indexOf(u8, resp_body, "prompt_cache_options") == null);
    try std.testing.expect(std.mem.indexOf(u8, resp_body, "prompt_cache_breakpoint") == null);
    try std.testing.expect(std.mem.indexOf(u8, chat_body, "prompt_cache_options") == null);
}

test "grok spec: official cache is an exact prefix — append keeps it, edit breaks it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = try xaiAgent(a, "main", .responses);
    const first = try agent.buildBody(null, false, false, false);
    defer std.testing.allocator.free(first);
    try agent.messages.append(try textMessage(a, "assistant", "pong"));
    try agent.messages.append(try textMessage(a, "user", "next"));
    const appended = try agent.buildBody(null, false, false, false);
    defer std.testing.allocator.free(appended);
    try std.testing.expect(std.mem.indexOf(u8, first, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, appended, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, appended, "next") != null);
    try std.testing.expectEqualStrings(cacheKeyIn(first).?, cacheKeyIn(appended).?);

    var edited = agent.messages.items[0].object;
    try edited.put(a, "content", .{ .string = "HELLO-EDITED" });
    agent.messages.items[0] = .{ .object = edited };
    const miss = try agent.buildBody(null, false, false, false);
    defer std.testing.allocator.free(miss);
    try std.testing.expect(std.mem.indexOf(u8, miss, "hello") == null);
    try std.testing.expect(std.mem.indexOf(u8, miss, "HELLO-EDITED") != null);
    try std.testing.expectEqualStrings(cacheKeyIn(first).?, cacheKeyIn(miss).?);
}

test "grok spec: Chat replays reasoning_content (official top cache-miss cause)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = try xaiAgent(a, "main", .openai);
    var asst: std.json.ObjectMap = .empty;
    try asst.put(a, "role", .{ .string = "assistant" });
    try asst.put(a, "content", .{ .string = "pong" });
    try asst.put(a, "reasoning_content", .{ .string = "think-then-pong" });
    try agent.messages.append(.{ .object = asst });
    try agent.messages.append(try textMessage(a, "user", "next"));
    const body = try agent.buildBody(null, false, false, false);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_content\":\"think-then-pong\"") != null);
}

test "grok spec: official usage fields become last_cache_read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = try xaiAgent(a, "main", .openai);
    agent.last_cache_read = 0;
    agent.last_context_tokens = 0;
    agent.context_local_tokens = 0;
    agent.codex_prev_id = null;
    agent.strict = false;
    agent.sys_strict = "";
    agent.tools_openai = "";
    agent.tools_responses = "";

    var details: std.json.ObjectMap = .empty;
    try details.put(a, "cached_tokens", .{ .integer = 98 });
    var usage: std.json.ObjectMap = .empty;
    try usage.put(a, "prompt_tokens", .{ .integer = 125 });
    try usage.put(a, "completion_tokens", .{ .integer = 48 });
    try usage.put(a, "prompt_tokens_details", .{ .object = details });
    var response: std.json.ObjectMap = .empty;
    try response.put(a, "usage", .{ .object = usage });
    @import("agent_context.zig").recordUsage(&agent, response, 400);
    try std.testing.expectEqual(@as(u64, 98), agent.last_cache_read);

    agent.provider.kind = .responses;
    agent.last_cache_read = 0;
    var in_details: std.json.ObjectMap = .empty;
    try in_details.put(a, "cached_tokens", .{ .integer = 50 });
    var rusage: std.json.ObjectMap = .empty;
    try rusage.put(a, "input_tokens", .{ .integer = 125 });
    try rusage.put(a, "output_tokens", .{ .integer = 48 });
    try rusage.put(a, "total_tokens", .{ .integer = 173 });
    try rusage.put(a, "input_tokens_details", .{ .object = in_details });
    var rresp: std.json.ObjectMap = .empty;
    try rresp.put(a, "usage", .{ .object = rusage });
    @import("agent_context.zig").recordUsageResponses(&agent, rresp, 400);
    try std.testing.expectEqual(@as(u64, 50), agent.last_cache_read);
}
