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
    if (@import("review.zig").promptFromLine(text) != null) return null;
    if (@import("issue_cmd.zig").promptFromLine(text) != null) return null;
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

/// Per-turn context meter: the live occupancy estimate against the model's
/// wall, so the client can render remaining context without reading history.
fn liveMeter(ctx: *anyopaque) engine.Meter {
    const live: *LiveTurn = @ptrCast(@alignCast(ctx));
    const root = live.root;
    return .{ .used = root.effectiveContextTokens(), .window = root.provider.context };
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
    if (try @import("acp_mcp_app.zig").handle(arena, w, req, live.root)) return true;
    if (!std.mem.eql(u8, req.method, "graff/models")) return false;
    if (req.id == null) return true;
    const keys = live.keys;
    const root = live.root;
    // Hydrate deferred local metadata without network refresh or MCP startup.
    root.ensureStoredKeys(keys);
    if (root.model_catalog) |*cached|
        cached.ensureCached(root.io, root.gpa, root.arena, root.home, keys.get("codex") orelse "", keys.codex_account);
    if (!live.local_catalog_loaded) {
        if (root.home.len > 0) @import("router_catalog.zig").loadCachedAll(root.io, root.arena, root.home);
        live.local_catalog_loaded = true;
    }
    const er = @import("effort_route.zig");
    if (@import("gateway_picker_catalog.zig").requested(req.params)) @import("gateway_picker_catalog.zig").refresh(root.gpa, root.io, root.arena, keys.*);
    const catalog = pricing.models();
    const Row = struct {
        name: []const u8,
        provider: []const u8,
        context: u64,
        authenticated: bool,
        cost: []const u8,
        current: bool,
        effortLevels: []const []const u8,
        fastSupported: bool,
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
        const supports_effort = if (provider_mod.specFor(m.provider)) |spec|
            @import("schema.zig").providerTakesEffort(spec.kind, m.provider, m.name)
        else
            false;
        row.* = .{
            .name = m.name,
            .provider = m.provider,
            .context = pricing.contextFor(m.provider, m.name),
            .authenticated = keys.get(m.provider) != null,
            .cost = billing.costFor(m.provider, keys.source(m.provider)).badge(),
            .current = std.mem.eql(u8, m.name, root.provider.model) and std.mem.eql(u8, m.provider, root.provider.id),
            .effortLevels = if (supports_effort) er.levels(m.provider, m.name) else &.{},
            .fastSupported = std.mem.eql(u8, m.provider, "codex"),
        };
    }
    const levels: []const []const u8 = if (!root.effortApplies()) &.{} else er.levels(root.provider.id, root.provider.model);
    try proto.writeResult(w, req.id, .{
        .models = rows,
        .commands = proto.slashCommands(),
        .current = .{ .model = root.provider.model, .provider = root.provider.id, .effort = er.normalize(root.provider.id, root.provider.model, @tagName(root.reasoning)), .fast = root.fast, .effortLevels = levels, .fastSupported = std.mem.eql(u8, root.provider.id, "codex") },
    });
    return true;
}

pub fn handleLine(d: *Dispatch, arena: Allocator, w: *Io.Writer, line: []const u8) !void {
    engine.implementation_version = main_mod.harness_version;
    engine.on_cancel = syncEscCancel;
    engine.extra_cancelled = liveCancelled;
    return engine.handleLine(d, arena, w, line);
}

const LiveTurn = @import("acp_live_turn.zig").LiveTurn;

var acp_inbox_nudge: ?*@import("acp_inbox.zig").Inbox = null;

fn nudgeAcp() void {
    if (acp_inbox_nudge) |inbox| inbox.nudge();
}

pub fn runAcpCommand(gpa: Allocator, io: Io, environ_map: anytype, root: *agent_mod.Agent, keys: *provider_mod.Keys, client: *std.http.Client, in: *Io.Reader, out: *Io.Writer, arena: Allocator, flags: args.Flags) !bool {
    if (!(flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "acp"))) return false;
    _ = client;
    main_mod.unattended = true;
    // GUI is an interactive root (ADR 0154): park long shells and resume on exit.
    @import("subagent_interactive.zig").configure(true);
    defer @import("subagent_interactive.zig").configure(false);
    root.in = null;
    root.out = null; // not stream_quiet: that forces SSE and misses resume cache
    main_mod.g_out = null;
    engine.implementation_version = main_mod.harness_version;
    engine.cancel_flag.store(false, .release);
    engine.on_cancel = syncEscCancel;
    var transport_lock: Io.Mutex = .init;
    var framed: @import("acp_line_writer.zig").LineWriter = undefined;
    framed.init(io, out, &transport_lock);
    defer framed.deinit();
    const wire = &framed.writer;
    var permission_framed: @import("acp_line_writer.zig").LineWriter = undefined;
    permission_framed.init(io, out, &transport_lock);
    defer permission_framed.deinit();
    var permission_bridge: @import("acp_permission.zig").Bridge = .{ .io = io, .out = &permission_framed.writer };
    const previous_permission = root.permission;
    root.permission = permission_bridge.handler();
    defer root.permission = previous_permission;
    var inbox: @import("acp_inbox.zig").Inbox = .{ .gpa = gpa, .io = io, .reader = in, .permission = &permission_bridge };
    try inbox.start();
    defer inbox.deinit();
    acp_inbox_nudge = &inbox;
    const prev_queued = @import("job_notify.zig").on_queued;
    @import("job_notify.zig").on_queued = nudgeAcp;
    defer {
        @import("job_notify.zig").on_queued = prev_queued;
        acp_inbox_nudge = null;
    }
    @import("acp_ask.zig").attach(io, gpa);
    defer @import("acp_ask.zig").detach();
    var live: LiveTurn = .{ .root = root, .keys = keys, .out = wire, .inbox = &inbox };
    var d: Dispatch = .{
        .turn = LiveTurn.run,
        .error_message = LiveTurn.errorMessage,
        .ctx = &live,
        .seed = @bitCast(util.unixMs(io)),
        .slash = liveSlash,
        .after_user = liveAfter,
        .bind_session = liveBind,
        .meter = liveMeter,
        .extra = liveModels,
        .mcp_servers = @import("acp_mcp_servers.zig").attach,
        .cwd = if (std.fs.path.isAbsolute(main_mod.g_cwd_display)) main_mod.g_cwd_display else "",
        .draft_subagents_enabled = std.mem.eql(u8, environ_map.get("GRAFF_ACP_DRAFT_SUBAGENTS") orelse "", "1"),
    };
    @import("acp_session_load.zig").configure(&d, &live);
    var background_state: @import("acp_subagent_live.zig").BackgroundState = .{
        .out = out,
        .output_lock = &transport_lock,
    };
    @import("acp_subagent_live.zig").installBackground(io, &background_state);
    defer @import("acp_subagent_live.zig").uninstallBackground(io);
    while (true) {
        const event = (inbox.wait(arena) catch break) orelse break;
        switch (event) {
            .tick => @import("acp_idle.zig").maybeWake(&d, arena, wire, io, root.session_name) catch |err| {
                std.debug.print("acp: idle wake failed: {t}\n", .{err});
            },
            .line => |line| {
                handleLine(&d, arena, wire, line) catch |err| {
                    std.debug.print("acp: dispatch failed: {t}\n", .{err});
                    break;
                };
                @import("acp_subagent_live.zig").configureBackground(io, d.session_id orelse "", d.background_subagents);
                @import("acp_idle.zig").startupEffortNotice(&d, root, wire) catch break;
            },
        }
        wire.flush() catch break;
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

test "userMessage sends a Codex GPT-6 Sol GUI attachment as a native vision block" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();

    var root: agent_mod.Agent = .{
        .gpa = testing.allocator,
        .arena = a,
        .io = testing.io,
        .client = undefined,
        .provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-6-sol", .context = 100_000 },
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

test "negotiateVersion returns the supported ACP v1 protocol" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const parse = struct {
        fn f(alloc: Allocator, json: []const u8) Value {
            return std.json.parseFromSliceLeaky(Value, alloc, json, .{}) catch unreachable;
        }
    }.f;
    try testing.expectEqual(@as(i64, 1), negotiateVersion(parse(a, "{\"protocolVersion\":5}")));
    try testing.expectEqual(@as(i64, 1), negotiateVersion(parse(a, "{\"protocolVersion\":0}")));
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

    try handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":0,\"clientCapabilities\":{\"fs\":{}}}}");
    const init_line = w.buffered();
    try testing.expect(std.mem.indexOf(u8, init_line, "\"protocolVersion\":1") != null);
    try testing.expect(std.mem.indexOf(u8, init_line, "\"embeddedContext\":true") != null);
    try testing.expect(std.mem.indexOf(u8, init_line, "\"name\":\"graff\"") != null);
    const init_response = try std.json.parseFromSliceLeaky(Value, a, std.mem.trim(u8, init_line, "\n"), .{});
    const init_result = init_response.object.get("result").?.object;
    for ([_][]const u8{ "agentInfo", "agentImplementation" }) |field|
        try testing.expectEqualStrings("graff", init_result.get(field).?.object.get("name").?.string);
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
    try handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"acp-abc-1\",\"prompt\":[{\"type\":\"text\",\"text\":\"ping\"},{\"type\":\"resource\",\"resource\":{\"uri\":\"memory://draft\",\"text\":\"draft contents\"}}]}}");
    var lines = std.mem.splitScalar(u8, w.buffered(), '\n');
    const first = lines.next().?;
    try testing.expect(std.mem.indexOf(u8, first, "\"method\":\"session/update\"") != null);
    try testing.expect(std.mem.indexOf(u8, first, "\"text\":\"echo:ping\\nmemory://draft\\ndraft contents\"") != null);
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
    _ = @import("transport_gate.zig");
    _ = @import("acp_mcp_app.zig");
}

test "ACP advertises the complete REPL command catalog including compact" {
    const catalog = @import("command_catalog.zig").commands;
    const advertised = proto.slashCommands();
    try std.testing.expectEqual(catalog.len, advertised.len);
    for (catalog, advertised) |command, exposed| {
        try std.testing.expectEqualStrings(command.name[1..], exposed.name);
    }
}

test "OpenAI effort menu omits Max and keeps Ultra on the Responses wire" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var root = try @import("agent_request_body_responses.zig").testAgentFor(a, "openai", .responses, "gpt-6-astra");
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    var aw: Io.Writer.Allocating = .init(a);
    var live: LiveTurn = .{ .root = &root, .keys = &keys, .out = &aw.writer };
    var d: Dispatch = .{ .turn = echoTurn, .ctx = &live, .extra = liveModels };
    const expected = [_][]const u8{ "low", "medium", "high", "xhigh", "ultra" };
    for ([_][]const u8{ "openai", "codex", "codegraff" }) |pid| {
        root.provider.id = pid;
        root.reasoning = .max; // saved Max remains a valid, visible selection
        aw.clearRetainingCapacity();
        try handleLine(&d, a, &aw.writer, "{\"id\":1,\"method\":\"graff/models\"}");
        const result = try std.json.parseFromSliceLeaky(Value, a, aw.writer.buffered(), .{});
        for (result.object.get("result").?.object.get("models").?.array.items) |row| {
            const fields = row.object;
            try testing.expect(fields.get("effortLevels").? == .array);
            try testing.expect(fields.get("fastSupported").? == .bool);
        }
        const current = result.object.get("result").?.object.get("current").?.object;
        try testing.expectEqualStrings("ultra", current.get("effort").?.string);
        const levels = current.get("effortLevels").?.array.items;
        try testing.expectEqual(expected.len, levels.len);
        for (expected, levels) |tag, level| try testing.expectEqualStrings(tag, level.string);
        // The last advertised choice must serialize as API max, never ultra.
        root.reasoning = std.meta.stringToEnum(main_mod.ReasoningEffort, levels[levels.len - 1].string).?;
        const body = try root.buildBody(null, false, true, true);
        defer testing.allocator.free(body);
        const request = try std.json.parseFromSliceLeaky(Value, a, body, .{});
        try testing.expectEqualStrings("max", request.object.get("reasoning").?.object.get("effort").?.string);
        root.reasoning = .xhigh;
        const extra = try root.buildBody(null, false, true, true);
        defer testing.allocator.free(extra);
        const extra_request = try std.json.parseFromSliceLeaky(Value, a, extra, .{});
        try testing.expectEqualStrings("xhigh", extra_request.object.get("reasoning").?.object.get("effort").?.string);
    }
}
