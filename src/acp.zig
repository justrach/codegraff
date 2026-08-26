//! ACP (Agent Client Protocol) AGENT mode — `graff acp` (#375, "ACP first").
//!
//! ACP is Zed's editor↔agent protocol: JSON-RPC 2.0 over stdio, one message
//! per line. The editor is the CLIENT, graff is the AGENT.
//!
//! Mid-turn, --json events become `session/update` notifications (thought,
//! text, tool_call / tool_call_update) so a client can render tools from the
//! first call. A stub turn that emits no events still writes one final
//! agent_message_chunk (the v0 contract the unit tests pin).
//!
//! stdout discipline: `isAcpSubcommand` flips `json_mode` during flag parse
//! so startup banners never hit stdout. `root.out` is the translating sink
//! only for the duration of a prompt; `g_out` is the same writer so pool-
//! thread subagent tool rows translate too. Between prompts both are null.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const args = @import("args.zig");
const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const providers = @import("providers.zig");
const messages_mod = @import("messages.zig");
const session = @import("session.zig");
const telemetry = @import("telemetry.zig");
const util = @import("util.zig");
const proto = @import("acp_protocol.zig");
const stream = @import("acp_stream.zig");
const playbook_glue = @import("playbook_glue.zig");

pub const protocol_version = proto.protocol_version;
pub const err_method_not_found = proto.err_method_not_found;
pub const err_internal = proto.err_internal;
pub const Request = proto.Request;
pub const parseRequest = proto.parseRequest;
pub const negotiateVersion = proto.negotiateVersion;
pub const flattenPrompt = proto.flattenPrompt;
pub const writeResult = proto.writeResult;
pub const writeError = proto.writeError;
pub const writeSessionUpdate = proto.writeSessionUpdate;

pub fn isAcpSubcommand(positional: []const u8) bool {
    if (!std.mem.eql(u8, positional, "acp")) return false;
    main_mod.json_mode = true;
    return true;
}

pub const TurnFn = *const fn (ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8;

pub const Dispatch = struct {
    turn: TurnFn,
    ctx: *anyopaque,
    session_id: ?[]const u8 = null,
    seed: u64 = 0,
    created: u32 = 0,
    /// Set only for the real stdio agent so a prompt can publish the
    /// session id onto the translating sink. Unit-test stubs leave this null.
    live: ?*LiveTurn = null,
};

fn respond(w: *Io.Writer, req: Request, result: anytype) !void {
    if (req.id == null) return;
    try writeResult(w, req.id, result);
}

fn respondError(w: *Io.Writer, req: Request, code: i32, message: []const u8) !void {
    if (req.id == null) return;
    try writeError(w, req.id, code, message);
}

fn promptTurn(d: *Dispatch, arena: Allocator, w: *Io.Writer, req: Request) !void {
    const obj: ?std.json.ObjectMap = if (req.params) |p| (if (p == .object) p.object else null) else null;
    const sid = blk: {
        if (obj) |o| if (util.strFieldObj(o, "sessionId")) |s| break :blk s;
        break :blk d.session_id orelse "";
    };
    if (d.live) |live| live.session_id = sid;
    const text = try flattenPrompt(arena, if (obj) |o| o.get("prompt") else null);
    if (playbook_glue.isCommand(text)) {
        if (d.live) |live| {
            var aw: Io.Writer.Allocating = .init(arena);
            _ = try playbook_glue.command(live.root, arena, text, &aw.writer);
            const plain = try stripSgr(arena, aw.writer.buffered());
            if (plain.len > 0) try writeSessionUpdate(w, sid, plain);
            return respond(w, req, .{ .stopReason = "end_turn" });
        }
    }
    if (d.live) |live| _ = playbook_glue.applyUserOverride(live.root, arena, text);
    const final = d.turn(d.ctx, arena, text) catch |err| {
        if (err == error.RunBudgetExhausted)
            return respond(w, req, .{ .stopReason = "max_turn_requests" });
        return respondError(w, req, err_internal, @errorName(err));
    };
    // Stub turns (and live turns that never streamed a text delta) still
    // publish the final answer as one chunk. A live turn that already
    // streamed `agent_message_chunk` returns "" so we do not duplicate.
    if (final.len > 0) try writeSessionUpdate(w, sid, final);
    const stop: []const u8 = if (agent_mod.Agent.esc_cancel.load(.acquire)) "cancelled" else "end_turn";
    try respond(w, req, .{ .stopReason = stop });
}

fn stripSgr(arena: Allocator, s: []const u8) ![]const u8 {
    var buf: std.array_list.Managed(u8) = .init(arena);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            i += 2;
            while (i < s.len and (s[i] < '@' or s[i] > '~')) i += 1;
            if (i < s.len) i += 1;
            continue;
        }
        try buf.append(s[i]);
        i += 1;
    }
    return buf.items;
}

pub fn handleLine(d: *Dispatch, arena: Allocator, w: *Io.Writer, line: []const u8) !void {
    const req = parseRequest(arena, line) orelse return;
    if (std.mem.eql(u8, req.method, "initialize")) return respond(w, req, .{
        .protocolVersion = negotiateVersion(req.params),
        .agentCapabilities = .{
            .loadSession = false,
            .promptCapabilities = proto.PromptCapabilities{},
        },
        .agentImplementation = proto.AgentImplementation{ .version = main_mod.harness_version },
    });
    if (std.mem.eql(u8, req.method, "session/new")) {
        d.created += 1;
        d.session_id = try std.fmt.allocPrint(arena, "acp-{x}-{d}", .{ d.seed, d.created });
        try respond(w, req, .{ .sessionId = d.session_id.? });
        try proto.writeAvailableCommands(w, d.session_id.?, proto.slashCommands());
        return;
    }
    if (std.mem.eql(u8, req.method, "session/cancel")) {
        agent_mod.Agent.esc_cancel.store(true, .release);
        if (req.id != null) return respond(w, req, .{});
        return;
    }
    if (std.mem.eql(u8, req.method, "session/prompt")) return promptTurn(d, arena, w, req);
    if (req.id == null) return;
    try writeError(w, req.id, err_method_not_found, try std.fmt.allocPrint(arena, "method not found: {s}", .{req.method}));
}

const LiveTurn = struct {
    root: *agent_mod.Agent,
    keys: *provider_mod.Keys,
    out: *Io.Writer,
    session_id: []const u8 = "",
    saw_text: bool = false,

    fn run(ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8 {
        const self: *LiveTurn = @ptrCast(@alignCast(ctx));
        try self.root.messages.append(try messages_mod.textMessage(arena, "user", text));
        if (telemetry.g_telem) |t| t.beginTurn(@intCast(@min(text.len, std.math.maxInt(u32))), self.root.provider.model);
        self.saw_text = false;
        var sink: stream.EventSink = undefined;
        sink.init(self.root.gpa, self.out, &self.session_id, &self.saw_text);
        defer sink.deinit();
        self.root.out = &sink.writer;
        main_mod.g_out = &sink.writer;
        defer {
            sink.writer.flush() catch {};
            self.root.out = null;
            main_mod.g_out = null;
        }
        const final = try providers.runTurnWithFallback(self.root, self.keys, arena, null);
        if (self.saw_text) return "";
        return final;
    }
};

pub fn runAcpCommand(gpa: Allocator, io: Io, environ_map: anytype, root: *agent_mod.Agent, keys: *provider_mod.Keys, client: *std.http.Client, in: *Io.Reader, out: *Io.Writer, arena: Allocator, flags: args.Flags) !bool {
    if (!(flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "acp"))) return false;
    _ = environ_map;
    _ = client;
    main_mod.unattended = true;
    root.in = null;
    root.out = null;
    root.stream_quiet = true;
    main_mod.g_out = null;
    var live: LiveTurn = .{ .root = root, .keys = keys, .out = out };
    var d: Dispatch = .{ .turn = LiveTurn.run, .ctx = &live, .live = &live, .seed = @bitCast(util.unixMs(io)) };
    while (true) {
        const line = (in.takeDelimiter('\n') catch break) orelse break;
        handleLine(&d, arena, out, line) catch |err| {
            std.debug.print("acp: dispatch failed: {t}\n", .{err});
            break;
        };
        out.flush() catch break;
    }
    session.saveSession(root, arena, root.session_name) catch {};
    root.md_buf.deinit(gpa);
    root.md_word.deinit(gpa);
    for (root.md_table.items) |r| gpa.free(r);
    root.md_table.deinit(gpa);
    root.tools_used.deinit(gpa);
    return true;
}

const testing = std.testing;

fn echoTurn(ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8 {
    _ = ctx;
    return std.fmt.allocPrint(arena, "echo:{s}", .{text});
}

fn budgetTurn(ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8 {
    _ = ctx;
    _ = arena;
    _ = text;
    return error.RunBudgetExhausted;
}

fn failTurn(ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8 {
    _ = ctx;
    _ = arena;
    _ = text;
    return error.ApiError;
}

test "parseRequest: requests, notifications, and lines that are not ours" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();

    const req = parseRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"initialize\",\"params\":{\"protocolVersion\":3}}").?;
    try testing.expectEqualStrings("initialize", req.method);
    try testing.expectEqual(@as(i64, 7), req.id.?.integer);
    try testing.expectEqual(@as(i64, 3), req.params.?.object.get("protocolVersion").?.integer);

    const str_id = parseRequest(a, "{\"id\":\"a1\",\"method\":\"session/new\"}").?;
    try testing.expectEqualStrings("a1", str_id.id.?.string);

    try testing.expect(parseRequest(a, "{\"method\":\"session/cancel\"}").?.id == null);
    try testing.expect(parseRequest(a, "{\"id\":null,\"method\":\"x\"}").?.id == null);

    try testing.expect(parseRequest(a, "   \r\n") == null);
    try testing.expect(parseRequest(a, "{not json") == null);
    try testing.expect(parseRequest(a, "[1,2]") == null);
    try testing.expect(parseRequest(a, "{\"id\":1,\"result\":{}}") == null);
}

test "negotiateVersion takes the lower of the two proposals" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const parse = struct {
        fn f(alloc: Allocator, json: []const u8) Value {
            return std.json.parseFromSliceLeaky(Value, alloc, json, .{}) catch unreachable;
        }
    }.f;
    try testing.expectEqual(@as(i64, 1), negotiateVersion(parse(a, "{\"protocolVersion\":5}")));
    try testing.expectEqual(@as(i64, 0), negotiateVersion(parse(a, "{\"protocolVersion\":0}")));
    try testing.expectEqual(@as(i64, 1), negotiateVersion(parse(a, "{\"protocolVersion\":1}")));
    try testing.expectEqual(@as(i64, 1), negotiateVersion(parse(a, "{}")));
    try testing.expectEqual(@as(i64, 1), negotiateVersion(parse(a, "{\"protocolVersion\":\"1\"}")));
    try testing.expectEqual(@as(i64, 1), negotiateVersion(null));
}

test "flattenPrompt: text blocks join, resource_links contribute their uri" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const parse = struct {
        fn f(alloc: Allocator, json: []const u8) Value {
            return std.json.parseFromSliceLeaky(Value, alloc, json, .{}) catch unreachable;
        }
    }.f;

    try testing.expectEqualStrings("hi", try flattenPrompt(a, parse(a, "[{\"type\":\"text\",\"text\":\"hi\"}]")));
    try testing.expectEqualStrings(
        "look at\nfile:///tmp/a.zig",
        try flattenPrompt(a, parse(a, "[{\"type\":\"text\",\"text\":\"look at\"},{\"type\":\"resource_link\",\"uri\":\"file:///tmp/a.zig\",\"name\":\"a.zig\"}]")),
    );
    try testing.expectEqualStrings("a.zig", try flattenPrompt(a, parse(a, "[{\"type\":\"resource_link\",\"name\":\"a.zig\"}]")));
    try testing.expectEqualStrings("x", try flattenPrompt(a, parse(a, "[{\"type\":\"text\",\"text\":\"\"},{\"type\":\"image\"},{\"type\":\"text\",\"text\":\"x\"}]")));
    try testing.expectEqualStrings("", try flattenPrompt(a, parse(a, "[]")));
    try testing.expectEqualStrings("", try flattenPrompt(a, null));
    try testing.expectEqualStrings("bare", try flattenPrompt(a, parse(a, "\"bare\"")));
}

test "writers compose valid, newline-framed JSON-RPC envelopes" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var buf: [1024]u8 = undefined;

    var w: Io.Writer = .fixed(&buf);
    try writeResult(&w, .{ .integer = 4 }, .{ .stopReason = "end_turn" });
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"stopReason\":\"end_turn\"}}\n", w.buffered());

    w = .fixed(&buf);
    try writeResult(&w, .{ .string = "x1" }, .{ .sessionId = "s" });
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":\"x1\",\"result\":{\"sessionId\":\"s\"}}\n", w.buffered());

    w = .fixed(&buf);
    try writeError(&w, .{ .integer = 9 }, err_method_not_found, "method not found: nope");
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":9,\"error\":{\"code\":-32601,\"message\":\"method not found: nope\"}}\n", w.buffered());

    w = .fixed(&buf);
    try writeSessionUpdate(&w, "sess-1", "line\"one\"\nline two");
    const update = w.buffered();
    try testing.expect(std.mem.indexOf(u8, update, "\"id\"") == null);
    try testing.expectEqual(@as(usize, update.len - 1), std.mem.indexOfScalar(u8, update, '\n').?);
    const reparsed = std.json.parseFromSliceLeaky(Value, a, update, .{}) catch unreachable;
    try testing.expectEqualStrings("session/update", reparsed.object.get("method").?.string);
    const params = reparsed.object.get("params").?.object;
    try testing.expectEqualStrings("sess-1", params.get("sessionId").?.string);
    const upd = params.get("update").?.object;
    try testing.expectEqualStrings("agent_message_chunk", upd.get("sessionUpdate").?.string);
    try testing.expectEqualStrings("text", upd.get("content").?.object.get("type").?.string);
    try testing.expectEqualStrings("line\"one\"\nline two", upd.get("content").?.object.get("text").?.string);
}

test "handleLine: initialize, session/new, then a prompt turn" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var d: Dispatch = .{ .turn = echoTurn, .ctx = undefined, .seed = 0xabc };

    try handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":9,\"clientCapabilities\":{\"fs\":{}}}}");
    const init_line = w.buffered();
    try testing.expect(std.mem.indexOf(u8, init_line, "\"protocolVersion\":1") != null);
    try testing.expect(std.mem.indexOf(u8, init_line, "\"embeddedContext\":true") != null);
    try testing.expect(std.mem.indexOf(u8, init_line, "\"name\":\"graff\"") != null);
    try testing.expect(std.mem.indexOf(u8, init_line, "\"loadSession\":false") != null);

    w = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/new\",\"params\":{\"cwd\":\"/tmp\"}}");
    var new_lines = std.mem.splitScalar(u8, w.buffered(), '\n');
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"sessionId\":\"acp-abc-1\"}}", new_lines.next().?);
    const cmds = new_lines.next().?;
    try testing.expect(std.mem.indexOf(u8, cmds, "available_commands_update") != null);
    try testing.expect(std.mem.indexOf(u8, cmds, "\"name\":\"never\"") != null);
    try testing.expectEqualStrings("acp-abc-1", d.session_id.?);

    w = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"acp-abc-1\",\"prompt\":[{\"type\":\"text\",\"text\":\"ping\"}]}}");
    var lines = std.mem.splitScalar(u8, w.buffered(), '\n');
    const first = lines.next().?;
    try testing.expect(std.mem.indexOf(u8, first, "\"method\":\"session/update\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"text\":\"echo:ping\"") != null);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"stopReason\":\"end_turn\"}}", lines.next().?);
    try testing.expectEqualStrings("", lines.next().?);
    try testing.expect(lines.next() == null);
}

test "handleLine: a prompt with no sessionId falls back to the live session" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var d: Dispatch = .{ .turn = echoTurn, .ctx = undefined, .seed = 1 };
    try handleLine(&d, a, &w, "{\"id\":1,\"method\":\"session/new\"}");
    w = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"id\":2,\"method\":\"session/prompt\",\"params\":{\"prompt\":[{\"type\":\"text\",\"text\":\"hi\"}]}}");
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"sessionId\":\"acp-1-1\"") != null);
}

test "handleLine: unknown methods get -32601 and notifications are never answered" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var d: Dispatch = .{ .turn = echoTurn, .ctx = undefined };

    try handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"session/load\"}");
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"error\":{\"code\":-32601,\"message\":\"method not found: session/load\"}}\n",
        w.buffered(),
    );

    w = .fixed(&buf);
    agent_mod.Agent.esc_cancel.store(false, .release);
    try handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"s\"}}");
    try testing.expect(agent_mod.Agent.esc_cancel.load(.acquire));
    agent_mod.Agent.esc_cancel.store(false, .release);
    try handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\"}");
    try handleLine(&d, a, &w, "");
    try handleLine(&d, a, &w, "{ garbage");
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "handleLine: turn failures map to a stopReason or a -32603" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var buf: [1024]u8 = undefined;
    const prompt = "{\"id\":1,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"s\",\"prompt\":[{\"type\":\"text\",\"text\":\"go\"}]}}";

    var w: Io.Writer = .fixed(&buf);
    var budget: Dispatch = .{ .turn = budgetTurn, .ctx = undefined };
    try handleLine(&budget, a, &w, prompt);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"stopReason\":\"max_turn_requests\"}}\n", w.buffered());

    w = .fixed(&buf);
    var failing: Dispatch = .{ .turn = failTurn, .ctx = undefined };
    try handleLine(&failing, a, &w, prompt);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32603,\"message\":\"ApiError\"}}\n", w.buffered());
}

test "isAcpSubcommand claims only `acp`, and arms the stdout discipline" {
    const saved = main_mod.json_mode;
    defer main_mod.json_mode = saved;
    main_mod.json_mode = false;
    try testing.expect(!isAcpSubcommand("repl"));
    try testing.expect(!isAcpSubcommand("acpx"));
    try testing.expect(!isAcpSubcommand(""));
    try testing.expect(!main_mod.json_mode);
    try testing.expect(isAcpSubcommand("acp"));
    try testing.expect(main_mod.json_mode);
}

test {
    _ = @import("acp_protocol.zig");
    _ = @import("acp_stream.zig");
}
