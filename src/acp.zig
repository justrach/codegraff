//! ACP (Agent Client Protocol) AGENT mode — `graff acp` (#375, "ACP first").
//!
//! ACP is Zed's editor↔agent protocol: JSON-RPC 2.0 over stdio, one message
//! per line. The editor is the CLIENT, graff is the AGENT. This module is the
//! whole surface: the read loop, the method dispatch, and the translation
//! between ACP content blocks and one real graff root turn.
//!
//! v0 scope (deliberate, see "deviations" at the bottom of this comment):
//!   initialize     → protocolVersion (min of the client's and ours) + our
//!                    agentCapabilities.
//!   session/new    → mints one session id. ONE live session per process.
//!   session/prompt → flattens the ContentBlock array to text, runs ONE full
//!                    root turn (tools + MCP + subagents, same loop `-p` uses),
//!                    emits one `session/update` agent_message_chunk carrying
//!                    the final text, then answers `{stopReason:"end_turn"}`.
//!   anything else  → -32601. Notifications (no `id`) are NEVER answered.
//!
//! Why the conversation persists: unlike `-p`, every session/prompt appends to
//! the SAME `root.messages`, so turn N sees turns 1..N-1. That is the entire
//! point of a session protocol, and it is why the unattended setup below runs
//! exactly once, outside the loop.
//!
//! stdout discipline — the load-bearing invariant. Only protocol JSON may ever
//! reach stdout, so three separate producers are shut off:
//!   1. `isAcpSubcommand` (called from args.zig's positional-subcommand test)
//!      flips `main_mod.json_mode`, which is what silences every startup banner
//!      — those print long before this function runs, so the switch has to be
//!      thrown during flag parsing, not here.
//!   2. `root.out = null` kills the root agent's own say()/emit() (say falls
//!      back to stderr; emit no-ops on a null writer).
//!   3. `main_mod.g_out = null` kills guiEmit — the pool-thread subagent and
//!      workflow-progress emitters write --json events straight to that global
//!      stdout alias, and json_mode is now on, so leaving it set would let a
//!      subagent interleave JSONL into the ACP stream.
//!
//! Deviations from the spec, made knowingly for v0:
//!   * No client callbacks at all (no fs/read_text_file, no
//!     session/request_permission). graff reads and writes files itself and
//!     the gate runs unattended, exactly as in `-p`.
//!   * `sessionId` on session/prompt is accepted as given rather than checked
//!     against the live session, and it is echoed back on the update. One
//!     process holds one session, so there is nothing to disambiguate, and a
//!     scripted client can prompt without first parsing session/new's reply.
//!   * loadSession is advertised false; session/load is therefore -32601.
//!   * One update per turn (the final text), not streaming chunks.
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

/// Highest ACP protocol version this agent implements.
pub const protocol_version: i64 = 1;

// JSON-RPC 2.0 error codes used on this surface.
pub const err_method_not_found: i32 = -32601;
pub const err_internal: i32 = -32603;

/// ACP's `promptCapabilities` — empty for v0 (no audio, no embedded context,
/// no image blocks). A NAMED empty struct, not `.{}`: an empty anonymous
/// literal is a TUPLE, and std.json writes tuples as `[]`, so the inline form
/// would put an array where the spec requires an object.
const PromptCapabilities = struct {};

/// True when this positional selects `graff acp`.
///
/// SIDE EFFECT, and the reason this predicate lives here instead of inline in
/// args.zig: it also arms ACP's stdout discipline by turning on `json_mode`.
/// stdout stops being human text and becomes a strict machine protocol for the
/// rest of the process — which is exactly what `json_mode` already means, and
/// what every startup banner is already gated on. Those banners print between
/// flag parsing and `runAcpCommand`, so the flag has to be set during the
/// parse; there is no later hook that would still be early enough.
pub fn isAcpSubcommand(positional: []const u8) bool {
    if (!std.mem.eql(u8, positional, "acp")) return false;
    main_mod.json_mode = true;
    return true;
}

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
/// ours. A missing/garbage proposal is read as "whatever you support".
pub fn negotiateVersion(params: ?Value) i64 {
    const p = params orelse return protocol_version;
    if (p != .object) return protocol_version;
    const v = p.object.get("protocolVersion") orelse return protocol_version;
    return switch (v) {
        .integer => |n| @min(n, protocol_version),
        .float => |f| @min(@as(i64, @intFromFloat(f)), protocol_version),
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

/// Runs one root turn on `text` and returns its final text. Injected as a
/// function pointer so the protocol dispatch is unit-testable without a
/// provider, a network, or a constructed Agent.
pub const TurnFn = *const fn (ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8;

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
    const final = d.turn(d.ctx, arena, text) catch |err| {
        if (err == error.RunBudgetExhausted)
            return respond(w, req, .{ .stopReason = "max_turn_requests" });
        return respondError(w, req, err_internal, @errorName(err));
    };
    try writeSessionUpdate(w, sid, final);
    try respond(w, req, .{ .stopReason = "end_turn" });
}

/// Handle one inbound line, writing zero or more protocol lines to `w`.
pub fn handleLine(d: *Dispatch, arena: Allocator, w: *Io.Writer, line: []const u8) !void {
    const req = parseRequest(arena, line) orelse return;
    if (std.mem.eql(u8, req.method, "initialize")) return respond(w, req, .{
        .protocolVersion = negotiateVersion(req.params),
        .agentCapabilities = .{ .loadSession = false, .promptCapabilities = PromptCapabilities{} },
    });
    if (std.mem.eql(u8, req.method, "session/new")) {
        d.created += 1;
        d.session_id = try std.fmt.allocPrint(arena, "acp-{x}-{d}", .{ d.seed, d.created });
        return respond(w, req, .{ .sessionId = d.session_id.? });
    }
    if (std.mem.eql(u8, req.method, "session/prompt")) return promptTurn(d, arena, w, req);
    // An unimplemented NOTIFICATION (session/cancel, notifications/*) is
    // ignored, never answered — replying to one is itself a protocol error.
    // Checked BEFORE formatting the message so a chatty client cannot make us
    // allocate a reply it will never receive.
    if (req.id == null) return;
    try writeError(w, req.id, err_method_not_found, try std.fmt.allocPrint(arena, "method not found: {s}", .{req.method}));
}

/// The real turn: appends to the SAME root history every time, which is what
/// makes an ACP session a conversation rather than N independent one-shots.
const LiveTurn = struct {
    root: *agent_mod.Agent,
    keys: *provider_mod.Keys,

    fn run(ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8 {
        const self: *LiveTurn = @ptrCast(@alignCast(ctx));
        try self.root.messages.append(try messages_mod.textMessage(arena, "user", text));
        if (telemetry.g_telem) |t| t.beginTurn(@intCast(@min(text.len, std.math.maxInt(u32))), self.root.provider.model);
        return providers.runTurnWithFallback(self.root, self.keys, arena, null);
    }
};

/// `graff acp`: serve the Agent Client Protocol on stdio until the client
/// closes stdin. Mirrors `runReplCommand`'s contract — returns false (having
/// done nothing) when this invocation is not `acp`, true once it has run the
/// whole session, at which point main() returns immediately.
///
/// `root` is already a stable, fully-constructed main()-owned Agent (keys,
/// provider, tools, MCP) by the time this is called, so taking its address is
/// ordinary pointer-passing. `arena` is the process-lifetime session arena:
/// the minted session id, every parsed request and every turn's history all
/// live there for the life of the connection, which is what lets turn N see
/// turns 1..N-1.
pub fn runAcpCommand(gpa: Allocator, io: Io, environ_map: anytype, root: *agent_mod.Agent, keys: *provider_mod.Keys, client: *std.http.Client, in: *Io.Reader, out: *Io.Writer, arena: Allocator, flags: args.Flags) !bool {
    if (!(flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "acp"))) return false;
    _ = environ_map;
    _ = client;
    // Unattended setup, ONCE (see the header): the gate denies instead of
    // prompting, tool progress goes to stderr, and stdout is protocol-only.
    main_mod.unattended = true;
    root.in = null;
    root.out = null;
    root.stream_quiet = true;
    main_mod.g_out = null; // no guiEmit into the ACP stream
    var live: LiveTurn = .{ .root = root, .keys = keys };
    var d: Dispatch = .{ .turn = LiveTurn.run, .ctx = &live, .seed = @bitCast(util.unixMs(io)) };
    while (true) {
        // A read failure (including a line longer than stdin's buffer, which
        // takeDelimiter leaves unconsumed) ends the session rather than
        // spinning on bytes we can never make progress past.
        const line = (in.takeDelimiter('\n') catch break) orelse break;
        handleLine(&d, arena, out, line) catch |err| {
            std.debug.print("acp: dispatch failed: {t}\n", .{err});
            break;
        };
        out.flush() catch break;
    }
    session.saveSession(root, arena, root.session_name) catch {};
    // This path returns before main() registers its REPL cleanup defer, so the
    // root's gpa-backed buffers are freed here (same as the one-shot path).
    root.md_buf.deinit(gpa);
    root.md_word.deinit(gpa);
    for (root.md_table.items) |r| gpa.free(r);
    root.md_table.deinit(gpa);
    root.tools_used.deinit(gpa);
    return true;
}

// ── Tests ─────────────────────────────────────────────────────────────────
// The protocol half is pure, so all of it is tested here with a stub turn:
// no provider, no network, no Agent.

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

    // A string id is just as valid as a numeric one and must round-trip.
    const str_id = parseRequest(a, "{\"id\":\"a1\",\"method\":\"session/new\"}").?;
    try testing.expectEqualStrings("a1", str_id.id.?.string);

    // No id, and an explicit null id, are both notifications.
    try testing.expect(parseRequest(a, "{\"method\":\"session/cancel\"}").?.id == null);
    try testing.expect(parseRequest(a, "{\"id\":null,\"method\":\"x\"}").?.id == null);

    // Nothing to answer: blank, malformed, non-object, and a RESPONSE (no
    // method) that some client bounced back at us.
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
    // Missing, mistyped, or absent params all fall back to our own version.
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
    // A resource_link with no uri still names the attachment.
    try testing.expectEqualStrings("a.zig", try flattenPrompt(a, parse(a, "[{\"type\":\"resource_link\",\"name\":\"a.zig\"}]")));
    // Empty and unreadable blocks are skipped, not rendered as blank lines.
    try testing.expectEqualStrings("x", try flattenPrompt(a, parse(a, "[{\"type\":\"text\",\"text\":\"\"},{\"type\":\"image\"},{\"type\":\"text\",\"text\":\"x\"}]")));
    try testing.expectEqualStrings("", try flattenPrompt(a, parse(a, "[]")));
    try testing.expectEqualStrings("", try flattenPrompt(a, null));
    // Non-spec clients that send a bare string are tolerated.
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

    // A string id round-trips as a string, not as a number.
    w = .fixed(&buf);
    try writeResult(&w, .{ .string = "x1" }, .{ .sessionId = "s" });
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":\"x1\",\"result\":{\"sessionId\":\"s\"}}\n", w.buffered());

    w = .fixed(&buf);
    try writeError(&w, .{ .integer = 9 }, err_method_not_found, "method not found: nope");
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":9,\"error\":{\"code\":-32601,\"message\":\"method not found: nope\"}}\n", w.buffered());

    // The update is a NOTIFICATION: no id field at all, and the payload is
    // escaped rather than pasted in raw.
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
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":1,\"agentCapabilities\":{\"loadSession\":false,\"promptCapabilities\":{}}}}\n",
        w.buffered(),
    );

    w = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/new\",\"params\":{\"cwd\":\"/tmp\"}}");
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"sessionId\":\"acp-abc-1\"}}\n", w.buffered());
    try testing.expectEqualStrings("acp-abc-1", d.session_id.?);

    // One turn: exactly one session/update notification, THEN the response.
    w = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"acp-abc-1\",\"prompt\":[{\"type\":\"text\",\"text\":\"ping\"}]}}");
    var lines = std.mem.splitScalar(u8, w.buffered(), '\n');
    const first = lines.next().?;
    try testing.expect(std.mem.indexOf(u8, first, "\"method\":\"session/update\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"text\":\"echo:ping\"") != null);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"stopReason\":\"end_turn\"}}", lines.next().?);
    try testing.expectEqualStrings("", lines.next().?); // the response's own trailing newline
    try testing.expect(lines.next() == null); // and nothing after it
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

    // Notifications produce no bytes at all — not a result, not an error.
    w = .fixed(&buf);
    try handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"s\"}}");
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

    // Budget exhaustion is a normal ACP outcome, not a protocol error, and it
    // emits no update (there is no final text to carry).
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
    try testing.expect(!main_mod.json_mode); // no side effect on a miss
    try testing.expect(isAcpSubcommand("acp"));
    try testing.expect(main_mod.json_mode); // stdout is protocol-only from here
}
