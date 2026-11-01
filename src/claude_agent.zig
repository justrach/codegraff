//! Claude Agent provider (ADR 0309): Claude models through the user's own
//! `claude` program and its login, with graff's harness around it.
//!
//! graff never reads Claude Code's saved login and never sits between Claude
//! Code and Anthropic. It starts `claude` with its built-in tools, settings
//! files, hooks, memory and compaction switched off, and offers graff's
//! tools as an in-process MCP server. When the model calls one, the call is
//! held: this step ends with a `tool_use` response, graff's loop runs the
//! tool (approvals, sinks, ACP, all unchanged), and the next step answers
//! the held call with graff's result. graff's history stays the source of
//! truth, so switching between Claude Agent and any other model works.
//!
//! The wire is Anthropic's: `claude --include-partial-messages` streams the
//! raw Messages events, which go to the same printDelta/assembleAnthropic
//! path the HTTP transport uses. Agent.postLive routes here first.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const main_mod = @import("main.zig");
const Agent = @import("agent.zig").Agent;
const engine_sink = @import("engine_sink.zig");
const tty = @import("term.zig").tty;
const wire = @import("claude_agent_wire.zig");
const history = @import("claude_agent_history.zig");
const session = @import("claude_agent_session.zig");
const Session = session.Session;
const Tracer = @import("trace.zig").Tracer;

pub const provider_id = "claude-agent";
/// Claude Code retries and backs off on its own; silence this long means the
/// child is stuck, not thinking (thinking summaries stream as deltas).
pub const turn_budget_ms: u64 = 300_000;
const init_budget_ms: u64 = 60_000;
const init_id = "graff_init";

pub fn owns(self: *const Agent) bool {
    return std.mem.eql(u8, self.provider.id, provider_id);
}

/// Titles, recaps, judges and compaction summaries run on a throwaway
/// process, so they never disturb the chat's session or its prompt cache.
fn sideCall(self: *const Agent) bool {
    if (self.compaction_request) return true;
    return switch (self.call_kind) {
        .title, .recap, .compaction, .judge => true,
        else => false,
    };
}

fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

fn envGet(name: [:0]const u8) ?[]const u8 {
    if (@import("mcp_lazy.zig").parent_env) |m| return m.get(name);
    return if (std.c.getenv(name.ptr)) |v| std.mem.span(v) else null;
}

pub fn post(self: *Agent, body: []const u8) ![]u8 {
    const a = self.scratchAlloc();
    const req = try std.json.parseFromSliceLeaky(Value, a, body, .{ .allocate = .alloc_always });
    if (req != .object) return error.ClaudeAgentBadRequest;
    const side = sideCall(self);
    const tools: ?Value = if (side) null else if (req.object.get("tools")) |t| (if (t == .array and t.array.items.len > 0) t else null) else null;
    const system = try history.textOf(a, req.object.get("system"));
    const mode = wire.promptMode(envGet("GRAFF_CLAUDE_AGENT_PROMPT"));
    const effort = wire.effortFlag(@tagName(self.reasoning));
    const exe = if (self.provider.api_key.len > 0) self.provider.api_key else "claude";
    const tools_json = if (tools) |t| try std.json.Stringify.valueAlloc(a, t, .{}) else "";
    const spawn: wire.Spawn = .{ .exe = exe, .model = wire.modelArg(self.provider.model), .effort = effort, .has_tools = tools != null };

    // The CLI takes these at start; the tool list can change live (MCP
    // servers connect and go dormant), so it is kept apart.
    var fp = std.hash.Wyhash.init(0);
    for ([_][]const u8{ exe, self.provider.model, effort orelse "", @tagName(mode), system, if (tools != null) "tools" else "", self.agent_cwd orelse "" }) |part| {
        fp.update(part);
        fp.update("\x00");
    }
    const props_fp = fp.final();
    const tools_fp = std.hash.Wyhash.hash(0, tools_json);

    const sink = engine_sink.forAgent(self);
    sink.emit(self.io, .stream_begin);
    defer sink.emit(self.io, .stream_finished);
    resetStreamState(self);
    const watch_esc = !self.sub and self.in != null and main_mod.use_color and !main_mod.json_mode;
    const orig_tio: ?tty.RawState = if (watch_esc) Agent.rawNonblockStdin() else null;
    defer if (orig_tio) |o| {
        _ = Agent.drainSteerStdin(true);
        tty.restore(o);
    };
    const poll = orig_tio != null;

    const items = self.messages.items;
    const owner = @intFromPtr(self);
    const now = nowMs(self.io);
    var held: ?*Session = if (side) null else session.take(self.io, owner);
    if (held) |s| if (staleBecause(a, s, props_fp, self.history_rewrites, items, now)) |why| {
        if (self.tracer) |tr| tr.note("claude-agent", why);
        s.stop();
        held = null;
    } else if (self.tracer) |tr| tr.note("claude-agent", "reused");
    var relisted = false;
    if (held) |s| if (s.tools_fp != tools_fp) {
        if (refreshTools(s, a, tools, poll)) {
            relisted = true;
            if (self.tracer) |tr| tr.note("claude-agent", "tool list refreshed");
        } else |e| switch (e) {
            error.Interrupted => {
                s.stop();
                return e;
            },
            else => {
                // A fresh session reads the new list at start.
                s.stop();
                held = null;
                if (self.tracer) |tr| tr.note("claude-agent", "restart: tool list was not re-read");
            },
        }
    };

    var restarts: u8 = 0;
    const s: *Session = while (true) {
        const s = held orelse start(self, a, spawn, mode, system, tools, props_fp, poll) catch |e| switch (e) {
            error.Interrupted => return e,
            else => return failSse(self, a, startProblem(e)),
        };
        held = s;
        s.tools_fp = tools_fp;
        if (try sendDelta(self, a, s, items, if (relisted) relisted_note else "")) break s;
        // The new messages are not something this session can take: replay
        // everything into a fresh one, once.
        s.stop();
        held = null;
        if (self.tracer) |tr| tr.note("claude-agent", "restart: new messages need a checkpoint");
        restarts += 1;
        if (restarts > 1) return error.ClaudeAgentBadHistory;
    };
    s.seen = items.len;
    s.seen_fp = history.hashMessages(a, items);
    s.rewrites = self.history_rewrites;

    const out = turn(self, a, s, tools, poll) catch |e| {
        s.stop();
        return e;
    };
    s.used_ms = nowMs(self.io);
    if (side or out.failed) s.stop() else session.put(self.io, owner, s, s.used_ms);
    return out.sse;
}

/// Why a held session cannot serve this request, or null if it can.
fn staleBecause(a: std.mem.Allocator, s: *const Session, props_fp: u64, rewrites: u32, items: []const Value, now: i64) ?[]const u8 {
    if (s.props_fp != props_fp) return "restart: model, effort, prompt or tools changed";
    if (s.rewrites != rewrites or s.seen > items.len) return "restart: history was compacted or trimmed";
    if (session.expired(s, now)) return "restart: idle past 5 minutes";
    if (history.hashMessages(a, items[0..s.seen]) != s.seen_fp) return "restart: earlier history changed";
    return null;
}

fn start(self: *Agent, a: std.mem.Allocator, spawn: wire.Spawn, mode: wire.PromptMode, system: []const u8, tools: ?Value, props_fp: u64, poll: bool) !*Session {
    const owner: Owner = .{ .gpa = self.gpa, .io = self.io, .cwd = self.agent_cwd, .tracer = self.tracer, .note = if (sideCall(self)) "started (side call)" else "started" };
    return open(owner, a, spawn, mode, system, tools, props_fp, poll);
}

/// Who a new `claude` process is for: an Agent's step, or a query made
/// without one (claude_agent_query.zig).
pub const Owner = struct {
    gpa: std.mem.Allocator,
    io: Io,
    cwd: ?[]const u8,
    tracer: ?*Tracer,
    note: []const u8,
};

/// Start `claude` and wait for its `initialize` answer.
pub fn open(owner: Owner, a: std.mem.Allocator, spawn: wire.Spawn, mode: wire.PromptMode, system: []const u8, tools: ?Value, props_fp: u64, poll: bool) !*Session {
    const argv = try wire.argv(a, spawn);
    const s = try Session.start(owner.gpa, owner.io, argv, @import("mcp_lazy.zig").parent_env, owner.cwd, props_fp);
    errdefer s.stop();
    if (owner.tracer) |tr| tr.note("claude-agent", owner.note);
    try s.send(try wire.initRequest(a, init_id, mode, system, spawn.has_tools));
    while (true) {
        const line = try s.readLine(poll, init_budget_ms);
        switch (try wire.classify(a, line)) {
            .response => |r| if (std.mem.eql(u8, r.request_id, init_id)) {
                if (!r.ok) return error.ClaudeAgentInitFailed;
                const body = r.body orelse return s;
                if (body == .object) if (wire.strField(body.object, "claude_code_version")) |v| {
                    if (!wire.atLeast(v, wire.min_version)) return error.ClaudeAgentTooOld;
                };
                return s;
            },
            .control => |c| try service(s, a, c, tools),
            else => {},
        }
    }
}

/// Send a control request and wait for its answer, serving whatever Claude
/// Code asks graff in between.
fn control(s: *Session, a: std.mem.Allocator, id: []const u8, request_json: []const u8, tools: ?Value, poll: bool) !void {
    try s.send(try std.fmt.allocPrint(a, "{{\"type\":\"control_request\",\"request_id\":\"{s}\",\"request\":{s}}}", .{ id, request_json }));
    while (true) {
        switch (try wire.classify(a, try s.readLine(poll, init_budget_ms))) {
            .response => |r| if (std.mem.eql(u8, r.request_id, id)) return if (r.ok) {} else error.ClaudeAgentControlFailed,
            .control => |c| try service(s, a, c, tools),
            else => {},
        }
    }
}

/// How long Claude Code gets to re-read the tool list after being told.
const relist_budget_ms: u64 = 15_000;

/// graff's tool list changed (load_tool_schemas, an MCP server joining).
/// Tell Claude Code with MCP's tools/list_changed and serve the tools/list it
/// sends back before answering anything, so the next model request already
/// has the new tools. The server stays connected, so a call graff is still
/// holding (usually the load_tool_schemas that changed the list) stays open.
/// Removing and re-adding the server instead failed that call with
/// "Connection closed", and the model often ended its turn there.
fn refreshTools(s: *Session, a: std.mem.Allocator, tools: ?Value, poll: bool) !void {
    const listed = s.tools_listed;
    try control(s, a, "graff_tools_changed", wire.tools_changed_request, tools, poll);
    const deadline = nowMs(s.io) + @as(i64, relist_budget_ms);
    while (s.tools_listed == listed) {
        const left = deadline - nowMs(s.io);
        if (left <= 0) return error.ClaudeAgentToolsNotRelisted;
        switch (try wire.classify(a, try s.readLine(poll, @intCast(left)))) {
            .control => |c| try service(s, a, c, tools),
            else => {},
        }
    }
}

pub fn startProblem(e: anyerror) []const u8 {
    return switch (e) {
        error.FileNotFound => "Claude Code isn't installed. Install it (https://code.claude.com/docs/en/setup), sign in with `claude auth login`, then try again.",
        error.ClaudeAgentTooOld => "Claude Code is too old for Claude Agent; version " ++ wire.min_version ++ " or later is required. Run `claude update`.",
        error.StreamStalled => "Claude Code did not start within 60 seconds.",
        else => "Claude Code exited while starting. Run `claude auth status` in a terminal to check its login.",
    };
}

/// Told with the results that follow a tool-list refresh. load_tool_schemas
/// prints schemas under graff's own names, and without this the model's
/// first call to a tool it just loaded used that bare name, which Claude
/// Code rejects ("No such tool available").
const relisted_note = "Your tool list was just updated. Call the newly loaded tools by their names in your tool list: graff's tools are named " ++ wire.tool_prefix ++ "<name>.";

/// Send what Claude Code has not seen. False when the session cannot take
/// it and a fresh one must start from a checkpoint. `note` rides with the
/// last result.
fn sendDelta(self: *Agent, a: std.mem.Allocator, s: *Session, items: []const Value, note: []const u8) !bool {
    _ = self;
    if (s.seen == 0) {
        try s.send(try wire.userLine(a, try history.freshContent(a, items)));
        return true;
    }
    const d = (try history.delta(a, items[s.seen..])) orelse return false;
    if (d.results.len == 0) {
        // Claude Code is still waiting on a call graff never answered.
        if (s.pending.items.len > 0) return false;
        try s.send(try wire.userLine(a, d.user.?));
        return true;
    }
    const last_extra = if (note.len == 0) d.extra_text else if (d.extra_text.len == 0) note else try std.mem.concat(a, u8, &.{ d.extra_text, "\n\n", note });
    for (d.results, 0..) |r, i| {
        const result = try wire.toolResult(a, r.block, if (i + 1 == d.results.len) last_extra else "");
        if (pendingIndex(s, r.id)) |pi| {
            const p = s.pending.items[pi];
            try s.send(try wire.mcpReply(a, p.request_id, p.rpc_id, result));
            s.dropPending(pi);
        } else try s.putResult(r.id, result);
    }
    return s.pending.items.len == 0;
}

fn pendingIndex(s: *Session, tool_use_id: []const u8) ?usize {
    for (s.pending.items, 0..) |p, i| if (std.mem.eql(u8, p.tool_use_id, tool_use_id)) return i;
    return null;
}

/// Answer a control request from Claude Code. A `tools/call` graff already
/// has a result for is answered at once; any other is held for graff's loop.
pub fn service(s: *Session, a: std.mem.Allocator, c: wire.Control, tools: ?Value) !void {
    if (std.mem.eql(u8, c.subtype, "mcp_message")) {
        const msg = c.request.get("message") orelse return s.send(try wire.controlErr(a, c.request_id, "missing message"));
        if (msg != .object) return s.send(try wire.controlErr(a, c.request_id, "bad message"));
        const method = wire.strField(msg.object, "method") orelse "";
        const rpc_id: ?[]const u8 = if (msg.object.get("id")) |id| try std.json.Stringify.valueAlloc(a, id, .{}) else null;
        const params: ?std.json.ObjectMap = if (msg.object.get("params")) |p| (if (p == .object) p.object else null) else null;
        if (std.mem.eql(u8, method, "tools/call")) {
            const id = rpc_id orelse return s.send(try wire.controlErr(a, c.request_id, "tools/call without id"));
            const tool_use_id = toolUseId(params) orelse "";
            if (s.takeResult(tool_use_id)) |result| {
                defer s.gpa.free(result);
                return s.send(try wire.mcpReply(a, c.request_id, id, result));
            }
            return s.addPending(c.request_id, id, tool_use_id);
        }
        const result: []const u8 = if (std.mem.eql(u8, method, "initialize"))
            try wire.initializeResult(a, if (params) |p| wire.strField(p, "protocolVersion") orelse "2025-06-18" else "2025-06-18")
        else if (std.mem.eql(u8, method, "tools/list")) blk: {
            s.tools_listed +%= 1;
            break :blk try wire.toolsList(a, tools);
        } else "{}";
        return s.send(try wire.mcpReply(a, c.request_id, rpc_id, result));
    }
    if (std.mem.eql(u8, c.subtype, "can_use_tool")) {
        const input = std.json.Stringify.valueAlloc(a, c.request.get("input") orelse Value{ .object = .empty }, .{}) catch "{}";
        return s.send(try wire.controlOk(a, c.request_id, try std.fmt.allocPrint(a, "{{\"behavior\":\"allow\",\"updatedInput\":{s}}}", .{input})));
    }
    if (std.mem.eql(u8, c.subtype, "hook_callback")) return s.send(try wire.controlOk(a, c.request_id, "{}"));
    return s.send(try wire.controlErr(a, c.request_id, "graff does not handle this request"));
}

fn toolUseId(params: ?std.json.ObjectMap) ?[]const u8 {
    const p = params orelse return null;
    const meta = p.get("_meta") orelse return null;
    if (meta != .object) return null;
    return wire.strField(meta.object, "claudecode/toolUseId");
}

const TurnOut = struct { sse: []u8, failed: bool = false };

/// Read one model step: until a response stops for tool use (the held call
/// is graff's to run) or Claude Code reports the turn's result.
fn turn(self: *Agent, a: std.mem.Allocator, s: *Session, tools: ?Value, poll: bool) !TurnOut {
    var full: Io.Writer.Allocating = .init(self.gpa);
    errdefer full.deinit();
    var loop_guard: @import("agent_model_loop.zig").Stream = .{};
    var stop_reason: []const u8 = "";
    var responses: usize = 0;
    var first_token = false;
    while (true) {
        const line = try s.readLine(poll, turn_budget_ms);
        switch (try wire.classify(a, line)) {
            .event => |event| {
                var ev = event;
                const kind = wire.strField(ev.object, "type") orelse "";
                if (std.mem.eql(u8, kind, "message_start")) {
                    // A second response in one step means Claude Code answered
                    // a call graff did not offer by itself; keep the last one.
                    responses += 1;
                    if (responses > 1) full.clearRetainingCapacity();
                    stop_reason = "";
                }
                _ = wire.unprefixToolUse(&ev);
                if (std.mem.eql(u8, kind, "message_delta")) if (ev.object.get("delta")) |d| {
                    if (d == .object) if (wire.strField(d.object, "stop_reason")) |r| {
                        stop_reason = r;
                    };
                };
                const json = try std.json.Stringify.valueAlloc(a, ev, .{});
                try loop_guard.event(self, json, false);
                const sse_line = try std.mem.concat(a, u8, &.{ "data: ", json });
                self.printDelta(sse_line);
                if (!first_token and std.mem.eql(u8, kind, "content_block_delta")) {
                    first_token = true;
                    self.traceFirstToken();
                }
                try full.writer.writeAll(sse_line);
                try full.writer.writeByte('\n');
                if (std.mem.eql(u8, kind, "message_stop") and std.mem.eql(u8, stop_reason, "tool_use")) break;
            },
            .control => |c| try service(s, a, c, tools),
            .cancel => |id| {
                for (s.pending.items, 0..) |p, i| if (std.mem.eql(u8, p.request_id, id)) {
                    s.dropPending(i);
                    break;
                };
            },
            .result => |r| {
                if (r.is_error) {
                    const sse = try failSse(self, a, try problem(a, r.text));
                    full.deinit();
                    return .{ .sse = sse, .failed = true };
                }
                break;
            },
            .response, .ignore => {},
        }
    }
    self.traceFirstToken();
    engine_sink.forAgent(self).emit(self.io, .{ .stream_complete = .{ .streamed_text = self.streamed_text } });
    return .{ .sse = try full.toOwnedSlice() };
}

pub fn problem(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, text, "Not logged in") != null or std.mem.indexOf(u8, text, "/login") != null)
        return "Claude Code is not logged in. Run `claude auth login` in a terminal, then try again.";
    return std.fmt.allocPrint(a, "Claude Code stopped: {s}", .{text});
}

/// A failure the user should read, as an assistant reply on the Messages
/// wire: it ends the turn without the transport retry ladder resending a
/// request that would fail the same way.
fn failSse(self: *Agent, a: std.mem.Allocator, text: []const u8) ![]u8 {
    var full: Io.Writer.Allocating = .init(self.gpa);
    errdefer full.deinit();
    const quoted = try std.json.Stringify.valueAlloc(a, text, .{});
    const events = [_][]const u8{
        "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_claude_agent\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-agent\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":0,\"output_tokens\":0}}}",
        "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
        try std.fmt.allocPrint(a, "{{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":{s}}}}}", .{quoted}),
        "{\"type\":\"content_block_stop\",\"index\":0}",
        "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":0}}",
        "{\"type\":\"message_stop\"}",
    };
    for (events) |ev| {
        const sse_line = try std.mem.concat(a, u8, &.{ "data: ", ev });
        self.printDelta(sse_line);
        try full.writer.writeAll(sse_line);
        try full.writer.writeByte('\n');
    }
    engine_sink.forAgent(self).emit(self.io, .{ .stream_complete = .{ .streamed_text = self.streamed_text } });
    return full.toOwnedSlice();
}

/// The same per-stream presentation resets postStream makes.
fn resetStreamState(self: *Agent) void {
    self.thinking_open = false;
    main_mod.g_thinking_open = false;
    self.thinking_rows = 0;
    self.thinking_col = 0;
    self.thinking_folded = false;
    self.thinking_text.clearRetainingCapacity();
    self.thinking_overflow = false;
    self.md_buf.clearRetainingCapacity();
    self.arg_live = .{};
    self.md_fence = false;
    self.md_kind = .classify;
    self.md_span = .normal;
    self.md_word.clearRetainingCapacity();
    self.md_word_vis = 0;
    self.md_col = 0;
    self.md_indent = 0;
    self.md_width = 0;
    for (self.md_table.items) |r| self.gpa.free(r);
    self.md_table.clearRetainingCapacity();
    self.partial_text.clearRetainingCapacity();
}
