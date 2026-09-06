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
const engine = @import("acp_engine.zig");
const stream = @import("acp_stream.zig");
const playbook_glue = @import("playbook_glue.zig");
const command_catalog = @import("command_catalog.zig");
const vision = @import("vision.zig");
const vision_queue = @import("vision_queue.zig");
const pricing = @import("pricing.zig");
const billing = @import("billing.zig");
const models_rank = @import("models_rank");

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
pub const TurnFn = engine.TurnFn;
pub const Dispatch = engine.Dispatch;

pub fn isAcpSubcommand(positional: []const u8) bool {
    if (!std.mem.eql(u8, positional, "acp")) return false;
    main_mod.json_mode = true;
    return true;
}

fn syncEscCancel() void {
    @import("cancel_source.zig").cancel(.acp_cancel); // #728
}

fn liveCancelled() bool {
    return agent_mod.Agent.esc_cancel.load(.acquire);
}

/// A slash command typed in a client runs the same handler the REPL runs,
/// so the menu the agent advertises is not a menu of things that then get
/// sent to the model as prose. Anything outside the catalog returns null
/// and stays an ordinary prompt. Pickers here find no TTY and fall back to
/// printing their list, so nothing waits on a keypress that cannot come.
fn liveSlash(ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror!?[]const u8 {
    const live: *LiveTurn = @ptrCast(@alignCast(ctx));
    var aw: Io.Writer.Allocating = .init(arena);
    // /never is the playbook's own, and handleCommand does not know it.
    if (playbook_glue.isCommand(text)) {
        _ = try playbook_glue.command(live.root, arena, text, &aw.writer);
        return try engine.stripSgr(arena, aw.writer.buffered());
    }
    if (command_catalog.match(text) == null) return null;
    try main_mod.handleCommand(live.root, live.keys, arena, text, &aw.writer);
    return try engine.stripSgr(arena, aw.writer.buffered());
}

fn liveAfter(ctx: *anyopaque, arena: Allocator, text: []const u8) void {
    const live: *LiveTurn = @ptrCast(@alignCast(ctx));
    _ = playbook_glue.applyUserOverride(live.root, arena, text);
}

fn liveBind(ctx: *anyopaque, session_id: []const u8) void {
    const live: *LiveTurn = @ptrCast(@alignCast(ctx));
    live.session_id = session_id;
}

/// The ACP user message: GUI `@[image]` attachments become native vision
/// blocks — the same promotion mainloop and the REPL do — instead of the
/// pixels never leaving the client and the model reading literal marker text.
fn userMessage(arena: Allocator, root: *agent_mod.Agent, text: []const u8) !Value {
    vision.stageGuiImageAttachment(root, text);
    return vision_queue.consumePromptImages(arena, root, text);
}

/// `graff/models` (vendor extension, dispatched through `engine.Dispatch.extra`):
/// the same catalog + credential view the REPL `/models` table prints, so an
/// ACP client can offer only the models this install can actually reach.
/// Rows come back in election order (plan, then local, credits, api).
fn liveModels(ctx: *anyopaque, arena: Allocator, w: *Io.Writer, req: proto.Request) anyerror!bool {
    const live: *LiveTurn = @ptrCast(@alignCast(ctx));
    if (try @import("acp_agents.zig").handle(arena, live.root.io, live.root.home, w, req)) return true;
    if (try @import("acp_changes.zig").handle(arena, live.root.io, w, req)) return true;
    if (!std.mem.eql(u8, req.method, "graff/models")) return false;
    if (req.id == null) return true;
    const keys = live.keys;
    const root = live.root;
    const catalog = pricing.models();
    const Row = struct {
        name: []const u8,
        provider: []const u8,
        context: u64,
        authenticated: bool,
        cost: []const u8,
        current: bool,
    };
    const ranked = try arena.alloc(models_rank.Scored, catalog.len);
    for (catalog, 0..) |m, i| ranked[i] = .{
        .idx = i,
        .score = models_rank.electionRank(
            keys.get(m.provider) != null,
            billing.costFor(m.provider, keys.source(m.provider)),
        ),
    };
    std.mem.sort(models_rank.Scored, ranked, {}, models_rank.scoredLess);
    const rows = try arena.alloc(Row, catalog.len);
    for (ranked, rows) |r, *row| {
        const m = catalog[r.idx];
        row.* = .{
            .name = m.name,
            .provider = m.provider,
            .context = pricing.contextFor(m.provider, m.name),
            .authenticated = keys.get(m.provider) != null,
            .cost = billing.costFor(m.provider, keys.source(m.provider)).badge(),
            .current = std.mem.eql(u8, m.name, root.provider.model) and std.mem.eql(u8, m.provider, root.provider.id),
        };
    }
    const all_efforts = [_][]const u8{ "low", "medium", "high", "xhigh", "max", "ultra" };
    const levels: []const []const u8 = if (!root.effortApplies()) &.{} else if (@import("effort_route.zig").hidesMax(root.provider.id, root.provider.model)) all_efforts[0..4] else &all_efforts;
    try proto.writeResult(w, req.id, .{
        .models = rows,
        .commands = proto.slashCommands(),
        .current = .{ .model = root.provider.model, .provider = root.provider.id, .effort = @tagName(root.reasoning), .fast = root.fast, .effortLevels = levels, .fastSupported = std.mem.eql(u8, root.provider.id, "codex") },
    });
    return true;
}

pub fn handleLine(d: *Dispatch, arena: Allocator, w: *Io.Writer, line: []const u8) !void {
    engine.implementation_version = main_mod.harness_version;
    engine.on_cancel = syncEscCancel;
    engine.extra_cancelled = liveCancelled;
    return engine.handleLine(d, arena, w, line);
}

const LiveTurn = struct {
    root: *agent_mod.Agent,
    keys: *provider_mod.Keys,
    out: *Io.Writer,
    session_id: []const u8 = "",
    saw_text: bool = false,

    fn run(ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8 {
        const self: *LiveTurn = @ptrCast(@alignCast(ctx));
        agent_mod.Agent.prepareRootTurn(); // #753: a prior stream cancel must not steal the continuation
        switch (try @import("turn_dedup.zig").enqueue(self.root, arena, self.out, text)) {
            .started => {},
            .skipped => return "",
            .stuck => return @import("turn_dedup.zig").stuck_text,
        }
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
        const final = providers.runTurnWithFallback(self.root, self.keys, arena, null) catch |err| {
            // #753: an API interruption is a failed turn, not a dead ACP
            // process. Save so the next prompt (and a respawn --resume) still
            // sees the tool results and the background-agent ledger.
            session.saveSession(self.root, self.root.arena, self.root.session_name) catch {};
            if (err == error.ApiError) {
                const msg = self.root.last_api_error orelse "provider API error";
                return std.fmt.allocPrint(arena, "{s}", .{msg});
            }
            return err;
        };
        // The REPL checkpoints after every turn (mainloop); an ACP host's
        // conversation deserves the same durability. Without this a text-only
        // turn reached .graff/sessions only at stdin EOF, and a tab the host
        // killed never did. The root arena, not this turn's: the queued write
        // outlives the turn.
        session.saveSessionAsync(self.root, self.root.arena, self.root.session_name) catch {};
        // saw_text is "the LAST streamed event was answer text" (tool events
        // reset it in the sink): a turn that ended mid-text already delivered
        // the answer; one that ended on tools (attempt_completion flows) has
        // its answer only in `final`, so that must still go on the wire.
        if (self.saw_text) return "";
        // A streamed preamble and the final answer are separate paragraphs;
        // without the break the client renders "…answering.The three files…".
        if (final.len > 0 and sink.streamed_any)
            return try std.fmt.allocPrint(arena, "\n\n{s}", .{final});
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
    engine.implementation_version = main_mod.harness_version;
    engine.cancel_flag.store(false, .release);
    engine.on_cancel = syncEscCancel;
    var live: LiveTurn = .{ .root = root, .keys = keys, .out = out };
    var d: Dispatch = .{
        .turn = LiveTurn.run,
        .ctx = &live,
        .seed = @bitCast(util.unixMs(io)),
        .slash = liveSlash,
        .after_user = liveAfter,
        .bind_session = liveBind,
        .extra = liveModels,
    };
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

test "userMessage promotes a GUI @[image] attachment to a native vision block" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();

    var root: agent_mod.Agent = .{
        .gpa = testing.allocator,
        .arena = a,
        .io = testing.io,
        .client = undefined,
        .provider = .{ .id = "xai", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "grok-4", .context = 100_000 },
        .messages = std.json.Array.init(a),
        .sub = false,
        .label = "test",
        .out = null,
    };

    // Non-image @[path] stays literal text: the agent opens it with its tools.
    const txt = try userMessage(a, &root, "read @[build.zig] please");
    try testing.expect(txt.object.get("content").? == .string);
    try testing.expectEqualStrings("read @[build.zig] please", txt.object.get("content").?.string);

    // An image path becomes text + input_image blocks.
    const img = try userMessage(a, &root, "look @[gui/public/favicon.png]");
    const content = img.object.get("content").?.array.items;
    try testing.expectEqual(@as(usize, 2), content.len);
    try testing.expectEqualStrings("input_image", content[1].object.get("type").?.string);
    try testing.expect(std.mem.indexOf(u8, content[1].object.get("image_url").?.string, "data:image/") != null);
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
    var buf: [16384]u8 = undefined; // session/new advertises the whole command catalog
    var w: Io.Writer = .fixed(&buf);
    var d: Dispatch = .{ .turn = echoTurn, .ctx = undefined, .seed = 0xabc };

    try handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":9,\"clientCapabilities\":{\"fs\":{}}}}");
    const init_line = w.buffered();
    try testing.expect(std.mem.indexOf(u8, init_line, "\"protocolVersion\":1") != null);
    try testing.expect(std.mem.indexOf(u8, init_line, "\"embeddedContext\":true") != null);
    try testing.expect(std.mem.indexOf(u8, init_line, "\"name\":\"graff\"") != null);
    try testing.expect(std.mem.indexOf(u8, init_line, "\"loadSession\":false") != null);
    try testing.expect(std.mem.indexOf(u8, init_line, "graff-login") != null);
    try testing.expect(std.mem.indexOf(u8, init_line, "\"type\":\"terminal\"") != null);

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
    var buf: [16384]u8 = undefined; // session/new advertises the whole command catalog
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

test "ACP advertises the complete REPL command catalog including compact" {
    const catalog = @import("command_catalog.zig").commands;
    const advertised = proto.slashCommands();
    try std.testing.expectEqual(catalog.len, advertised.len);
    for (catalog, advertised) |command, exposed| {
        try std.testing.expectEqualStrings(command.name[1..], exposed.name);
    }
}
