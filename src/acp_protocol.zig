//! ACP JSON-RPC surface: parse, write, flatten, dispatch.
//!
//! Kept off `acp.zig` so the process command can grow without pushing the
//! protocol tests past the 600-line ceiling. No Agent, no network — `TurnFn`
//! is injected so the method table is unit-testable.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const util = @import("util.zig");
const usage = @import("acp_usage.zig");
const acp_sink = @import("acp_sink.zig");

pub const protocol_version: i64 = 1;
pub const err_method_not_found: i32 = -32601;
pub const err_internal: i32 = -32603;

const harness_version = @import("main.zig").harness_version;

/// ACP's `promptCapabilities` — empty for v0 (no audio, no embedded context,
/// no image blocks). A NAMED empty struct, not `.{}`: an empty anonymous
/// literal is a TUPLE, and std.json writes tuples as `[]`, so the inline form
/// would put an array where the spec requires an object.
const PromptCapabilities = struct {};
const EmptyObject = struct {};

/// One decoded JSON-RPC message. `id == null` means NOTIFICATION — the caller
/// must not send any reply for it (a JSON `"id": null` is treated the same
/// way: it is not a value a response could be correlated by).
pub const Request = struct {
    id: ?Value = null,
    method: []const u8 = "",
    params: ?Value = null,
};

/// Decode one inbound line, or null when there is nothing to answer: a blank
/// line, malformed JSON, a non-object, or a message with no `method` (i.e. a
/// RESPONSE to something we sent — we send no requests, so it is not ours).
/// Values borrow `arena`, which must outlive the returned Request.
pub fn parseRequest(arena: Allocator, line: []const u8) ?Request {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    const v = std.json.parseFromSliceLeaky(Value, arena, trimmed, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    const method = util.strFieldObj(v.object, "method") orelse return null;
    const raw_id = v.object.get("id");
    return .{
        .id = if (raw_id) |id| (if (id == .null) null else id) else null,
        .method = method,
        .params = v.object.get("params"),
    };
}

/// The version both sides can speak: the lower of the client's proposal and
/// ours. A missing/garbage proposal is read as "whatever you support". Date
/// strings (`"2025-11-25"`) and dotted minors (`"0.1"`) are the v1/v2 wire
/// forms some hosts send; those are not integers, so they mean "ours".
pub fn negotiateVersion(params: ?Value) i64 {
    const p = params orelse return protocol_version;
    if (p != .object) return protocol_version;
    const v = p.object.get("protocolVersion") orelse return protocol_version;
    return switch (v) {
        .integer => |n| @min(n, protocol_version),
        .float => |f| @min(@as(i64, @intFromFloat(f)), protocol_version),
        .string => |s| blk: {
            const n = std.fmt.parseInt(i64, s, 10) catch break :blk protocol_version;
            break :blk @min(n, protocol_version);
        },
        else => protocol_version,
    };
}

/// The text a single ContentBlock contributes to the prompt, or null when it
/// carries none. `text` blocks give their text; `resource_link` blocks give
/// their uri (falling back to the display name) so the model at least learns
/// WHICH file the user attached. Unknown block kinds are probed for the same
/// two fields rather than dropped — a future block type that happens to carry
/// text is more useful half-read than silently discarded.
fn blockText(block: Value) ?[]const u8 {
    if (block == .string) return block.string;
    if (block != .object) return null;
    const o = block.object;
    const kind = util.strFieldObj(o, "type") orelse "";
    if (std.mem.eql(u8, kind, "text")) return util.strFieldObj(o, "text");
    if (std.mem.eql(u8, kind, "resource_link"))
        return util.strFieldObj(o, "uri") orelse util.strFieldObj(o, "name");
    return util.strFieldObj(o, "text") orelse util.strFieldObj(o, "uri");
}

/// Flatten a `prompt: [ContentBlock...]` into the single user message a graff
/// turn takes. Blocks join with a newline; empty and unreadable blocks are
/// skipped. A bare string prompt is tolerated (non-spec clients send one).
pub fn flattenPrompt(arena: Allocator, prompt: ?Value) ![]const u8 {
    const blocks = switch (prompt orelse return "") {
        .array => |a| a,
        .string => |s| return s,
        else => return "",
    };
    var buf: std.array_list.Managed(u8) = .init(arena);
    for (blocks.items) |block| {
        const text = blockText(block) orelse continue;
        if (text.len == 0) continue;
        if (buf.items.len != 0) try buf.append('\n');
        try buf.appendSlice(text);
    }
    return buf.items;
}

/// `{"jsonrpc":"2.0","id":<id>,"result":<result>}` + newline.
///
/// None of the three writers below flush: the caller owns line framing and
/// flushing (and unit tests hand them a fixed writer, which cannot drain).
pub fn writeResult(w: *Io.Writer, id: ?Value, result: anytype) !void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(id);
    try s.objectField("result");
    try s.write(result);
    try s.endObject();
    try w.writeByte('\n');
}

/// `{"jsonrpc":"2.0","id":<id>,"error":{"code":…,"message":…}}` + newline.
pub fn writeError(w: *Io.Writer, id: ?Value, code: i32, message: []const u8) !void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(id);
    try s.objectField("error");
    try s.beginObject();
    try s.objectField("code");
    try s.write(code);
    try s.objectField("message");
    try s.write(message);
    try s.endObject();
    try s.endObject();
    try w.writeByte('\n');
}

/// The one `session/update` NOTIFICATION a turn emits: an agent_message_chunk
/// carrying the turn's final text. No `id` — a notification is never answered,
/// in either direction.
pub fn writeSessionUpdate(w: *Io.Writer, session_id: []const u8, text: []const u8) !void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.write(.{
        .jsonrpc = "2.0",
        .method = "session/update",
        .params = .{
            .sessionId = session_id,
            .update = .{
                .sessionUpdate = "agent_message_chunk",
                .content = .{ .type = "text", .text = text },
            },
        },
    });
    try w.writeByte('\n');
}

/// Session-level context window + cumulative cost. Separate from
/// PromptResponse.usage, which is the per-turn token delta (ADR 0012).
pub fn writeUsageUpdate(w: *Io.Writer, session_id: []const u8, sess: usage.SessionUsage) !void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.write(.{
        .jsonrpc = "2.0",
        .method = "session/update",
        .params = .{
            .sessionId = session_id,
            .update = .{
                .sessionUpdate = "usage_update",
                .used = sess.used,
                .size = sess.size,
                .cost = .{ .amount = sess.cost_usd, .currency = "USD" },
            },
        },
    });
    try w.writeByte('\n');
}

/// Runs one root turn on `text` and returns its final text plus optional
/// usage. Injected as a function pointer so the protocol dispatch is
/// unit-testable without a provider, a network, or a constructed Agent.
pub const TurnFn = *const fn (ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror!usage.TurnOutcome;

/// Protocol state for one connection. `arena` values handed to `handleLine`
/// must outlive the connection — `session_id` is allocated from one.
pub const Dispatch = struct {
    turn: TurnFn,
    ctx: *anyopaque,
    /// Live session id, minted on the first `session/new`.
    session_id: ?[]const u8 = null,
    /// Per-process entropy for the minted ids, so two graff agents on one bus
    /// never present the same session id to a client.
    seed: u64 = 0,
    /// How many sessions have been minted (the id's suffix).
    created: u32 = 0,
};

/// Answer a request; a notification is silently dropped instead.
fn respond(w: *Io.Writer, req: Request, result: anytype) !void {
    if (req.id == null) return;
    try writeResult(w, req.id, result);
}

/// Fail a request; a notification is silently dropped instead.
fn respondError(w: *Io.Writer, req: Request, code: i32, message: []const u8) !void {
    if (req.id == null) return;
    try writeError(w, req.id, code, message);
}

/// session/prompt: flatten the blocks, run ONE root turn, emit the update,
/// then answer with a stopReason. A budget-exhausted turn is a normal ACP
/// outcome (`max_turn_requests`), not a protocol error; anything else is
/// -32603 with the error's name, which is all a client can act on.
fn promptTurn(d: *Dispatch, arena: Allocator, w: *Io.Writer, req: Request) !void {
    const obj: ?std.json.ObjectMap = if (req.params) |p| (if (p == .object) p.object else null) else null;
    const sid = blk: {
        if (obj) |o| if (util.strFieldObj(o, "sessionId")) |s| break :blk s;
        break :blk d.session_id orelse "";
    };
    const text = try flattenPrompt(arena, if (obj) |o| o.get("prompt") else null);
    const outcome = d.turn(d.ctx, arena, text) catch |err| {
        if (err == error.RunBudgetExhausted)
            return respond(w, req, .{ .stopReason = "max_turn_requests" });
        return respondError(w, req, err_internal, @errorName(err));
    };
    if (!acp_sink.didStream()) try writeSessionUpdate(w, sid, outcome.text);
    if (outcome.session) |sess| try writeUsageUpdate(w, sid, sess);
    if (outcome.usage) |u|
        return respond(w, req, .{ .stopReason = "end_turn", .usage = u });
    try respond(w, req, .{ .stopReason = "end_turn" });
}

/// Handle one inbound line, writing zero or more protocol lines to `w`.
pub fn handleLine(d: *Dispatch, arena: Allocator, w: *Io.Writer, line: []const u8) !void {
    const req = parseRequest(arena, line) orelse return;
    if (std.mem.eql(u8, req.method, "initialize")) return respond(w, req, .{
        .protocolVersion = negotiateVersion(req.params),
        .agentCapabilities = .{ .loadSession = false, .promptCapabilities = PromptCapabilities{} },
        .agentInfo = .{ .name = "graff", .title = "graff", .version = harness_version },
    });
    if (std.mem.eql(u8, req.method, "session/new")) {
        d.created += 1;
        d.session_id = try std.fmt.allocPrint(arena, "acp-{x}-{d}", .{ d.seed, d.created });
        return respond(w, req, .{ .sessionId = d.session_id.? });
    }
    if (std.mem.eql(u8, req.method, "session/prompt")) return promptTurn(d, arena, w, req);
    // session/cancel is a notification in the spec; some hosts send it as a
    // request. Either way we acknowledge and do not interrupt — the read loop
    // is blocked inside the turn, so a real abort needs stdin multiplexed
    // (ADR 0012). A notification still produces no bytes.
    if (std.mem.eql(u8, req.method, "session/cancel")) return respond(w, req, EmptyObject{});
    // An unimplemented NOTIFICATION is ignored, never answered — replying to
    // one is itself a protocol error. Checked BEFORE formatting the message
    // so a chatty client cannot make us allocate a reply it will never receive.
    if (req.id == null) return;
    try writeError(w, req.id, err_method_not_found, try std.fmt.allocPrint(arena, "method not found: {s}", .{req.method}));
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

fn echoTurn(ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror!usage.TurnOutcome {
    _ = ctx;
    return .{ .text = try std.fmt.allocPrint(arena, "echo:{s}", .{text}) };
}

fn budgetTurn(ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror!usage.TurnOutcome {
    _ = ctx;
    _ = arena;
    _ = text;
    return error.RunBudgetExhausted;
}

fn failTurn(ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror!usage.TurnOutcome {
    _ = ctx;
    _ = arena;
    _ = text;
    return error.ApiError;
}

fn usageTurn(ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror!usage.TurnOutcome {
    _ = ctx;
    return .{
        .text = try std.fmt.allocPrint(arena, "echo:{s}", .{text}),
        .usage = .{
            .totalTokens = 180,
            .inputTokens = 160,
            .outputTokens = 20,
            .cachedReadTokens = 120,
            .cachedWriteTokens = 8,
        },
        .session = .{ .used = 160, .size = 200_000, .cost_usd = 0.25 },
    };
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
    try testing.expectEqual(@as(i64, 0), negotiateVersion(parse(a, "{\"protocolVersion\":\"0\"}")));
    try testing.expectEqual(@as(i64, 1), negotiateVersion(parse(a, "{\"protocolVersion\":\"2025-11-25\"}")));
    try testing.expectEqual(@as(i64, 1), negotiateVersion(parse(a, "{\"protocolVersion\":\"0.1\"}")));
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

    w = .fixed(&buf);
    try writeUsageUpdate(&w, "sess-1", .{ .used = 160, .size = 200_000, .cost_usd = 0.25 });
    const usage_line = w.buffered();
    const usage_v = std.json.parseFromSliceLeaky(Value, a, usage_line, .{}) catch unreachable;
    const u = usage_v.object.get("params").?.object.get("update").?.object;
    try testing.expectEqualStrings("usage_update", u.get("sessionUpdate").?.string);
    try testing.expectEqual(@as(i64, 160), u.get("used").?.integer);
    try testing.expectEqual(@as(i64, 200_000), u.get("size").?.integer);
    try testing.expectEqualStrings("USD", u.get("cost").?.object.get("currency").?.string);
    try testing.expectEqual(@as(f64, 0.25), u.get("cost").?.object.get("amount").?.float);
}

test "handleLine: initialize, session/new, then a prompt turn" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var d: Dispatch = .{ .turn = echoTurn, .ctx = undefined, .seed = 0xabc };

    try handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":9,\"clientCapabilities\":{\"fs\":{}}}}");
    const init = std.json.parseFromSliceLeaky(Value, a, w.buffered(), .{}) catch unreachable;
    const result = init.object.get("result").?.object;
    try testing.expectEqual(@as(i64, 1), result.get("protocolVersion").?.integer);
    try testing.expectEqual(false, result.get("agentCapabilities").?.object.get("loadSession").?.bool);
    try testing.expectEqualStrings("graff", result.get("agentInfo").?.object.get("name").?.string);
    try testing.expectEqualStrings("graff", result.get("agentInfo").?.object.get("title").?.string);
    try testing.expectEqualStrings(harness_version, result.get("agentInfo").?.object.get("version").?.string);

    w = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/new\",\"params\":{\"cwd\":\"/tmp\"}}");
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"sessionId\":\"acp-abc-1\"}}\n", w.buffered());
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
    try handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"s\"}}");
    try handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\"}");
    try handleLine(&d, a, &w, "");
    try handleLine(&d, a, &w, "{ garbage");
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "handleLine: session/cancel as a request is an empty result" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var d: Dispatch = .{ .turn = echoTurn, .ctx = undefined };
    try handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"s\"}}");
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":6,\"result\":{}}\n", w.buffered());
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

test "handleLine: a turn with usage emits usage_update then PromptResponse.usage" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var d: Dispatch = .{ .turn = usageTurn, .ctx = undefined, .session_id = "sess-1" };

    try handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"sess-1\",\"prompt\":[{\"type\":\"text\",\"text\":\"ping\"}]}}");
    var lines = std.mem.splitScalar(u8, w.buffered(), '\n');
    const chunk = lines.next().?;
    try testing.expect(std.mem.indexOf(u8, chunk, "\"sessionUpdate\":\"agent_message_chunk\"") != null);
    try testing.expect(std.mem.indexOf(u8, chunk, "\"text\":\"echo:ping\"") != null);

    const usage_line = lines.next().?;
    const usage_v = std.json.parseFromSliceLeaky(Value, a, usage_line, .{}) catch unreachable;
    const upd = usage_v.object.get("params").?.object.get("update").?.object;
    try testing.expectEqualStrings("usage_update", upd.get("sessionUpdate").?.string);
    try testing.expectEqual(@as(i64, 160), upd.get("used").?.integer);
    try testing.expectEqual(@as(i64, 200_000), upd.get("size").?.integer);

    const result_line = lines.next().?;
    const result_v = std.json.parseFromSliceLeaky(Value, a, result_line, .{}) catch unreachable;
    const u = result_v.object.get("result").?.object.get("usage").?.object;
    try testing.expectEqualStrings("end_turn", result_v.object.get("result").?.object.get("stopReason").?.string);
    try testing.expectEqual(@as(i64, 160), u.get("inputTokens").?.integer);
    try testing.expectEqual(@as(i64, 120), u.get("cachedReadTokens").?.integer);
    try testing.expectEqual(@as(i64, 8), u.get("cachedWriteTokens").?.integer);
    try testing.expectEqual(@as(i64, 20), u.get("outputTokens").?.integer);
    try testing.expectEqual(@as(i64, 180), u.get("totalTokens").?.integer);
    try testing.expectEqualStrings("", lines.next().?);
    try testing.expect(lines.next() == null);
}
