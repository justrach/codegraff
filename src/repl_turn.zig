//! The chat frontends' turn backend: one full ROOT agent turn (tools + MCP)
//! per repl.TurnFn call. Split out of repl_glue.zig (600-line cap) when #551
//! made a turn carry POLICY as well as text — `mode` and `strict` used to be
//! frontend labels the engine never saw, so the TUI could show "Plan" over a
//! turn that was auto-approving writes.
//!
//! `turnAgent` is deliberately its own function: it is the exact construction
//! a live turn runs on, so a test can build one and interrogate the gate and
//! the system prompt without a provider in the loop.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const approvals_mod = @import("approvals.zig");
const Approvals = approvals_mod.Approvals;
const messages_mod = @import("messages.zig");
const textMessage = messages_mod.textMessage;
const prompts = @import("prompts.zig");
const providers = @import("providers.zig");
const session = @import("session.zig");
const util = @import("util.zig");
const repl = @import("repl.zig");
const repl_glue = @import("repl_glue.zig");
const ReplCtx = repl_glue.ReplCtx;
const vision = @import("vision.zig");
const vision_queue = @import("vision_queue.zig");

/// What a turn's permission mode means to the engine. One place, so the gate
/// and the badge can never drift again.
pub const Policy = struct {
    /// main.plan_mode for the length of the turn: read-only, writes denied.
    plan: bool,
    /// Approvals.yolo. On for the non-plan modes because these frontends have
    /// no approval prompt (in = null) — off would deny every unsaved tool
    /// rather than ask. Plan mode does not need it: its gate runs BEFORE the
    /// approval gate and is what refuses the writes.
    yolo: bool,
    /// Agent.strict — systemPrompt() picks sys_strict/sys_ultra_strict.
    strict: bool,

    pub fn from(params: repl.Params) Policy {
        return .{
            .plan = params.mode == .plan,
            .yolo = params.mode != .plan,
            .strict = params.strict,
        };
    }
};

/// The Agent a turn runs on. `out` is the live pane writer; `approvals` must
/// outlive the returned agent (the caller owns both). The system prompts are
/// composed here through the #326 funnel, so ultracode/strict/effort-ultra all
/// resolve against the REAL base rather than the comptime default.
pub fn turnAgent(
    c: *ReplCtx,
    gpa: Allocator,
    arena: Allocator,
    params: repl.Params,
    out: *Io.Writer,
    approvals: *Approvals,
) !Agent {
    const sys = if (params.goal.len > 0)
        (std.fmt.allocPrint(arena, "{s}\n\n# Standing goal (from the user)\n{s}\n\nTrack this as a todo_write checklist and work through it across turns - mark each item in_progress when you start and completed when done. Keep the list current; don't repeat finished items.", .{ c.sys_normal, params.goal }) catch c.sys_normal)
    else
        c.sys_normal;
    var agent: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = c.io,
        .client = c.client,
        .provider = c.provider,
        .messages = std.json.Array.init(arena),
        .sub = false, // root: enables the full tool set + agentic loop
        .label = "repl",
        .session_name = if (c.root) |root| root.session_name else "last",
        .session_parent = if (c.root) |root| root.session_parent else null,
        .out = out,
        .in = null, // never prompt for tool approval / ask_user
        .stream_quiet = false, // stream tokens live into the repl pane
        .registry = c.registry,
        .tracer = c.tracer,
        .run_budget = c.run_budget,
        .approvals = approvals,
        // #551: a frontend that wants the engine's TYPED events installs its
        // sink for this thread's turn (engine_sink.bindTurnSink). Null for
        // `graff repl` and every headless caller, which keeps the process-mode
        // default. Never re-parse rendered output to learn what the engine did.
        .sink = @import("engine_sink.zig").turnSink(),
        .tools_anthropic = c.tools_anthropic,
        .tools_openai = c.tools_openai,
        .tools_responses = c.tools_responses,
        .reasoning = switch (params.effort) {
            .low => .low,
            .medium => .medium,
            .high => .high,
            .xhigh => .xhigh,
            .max => .max,
            .ultra => .ultra,
        },
        .fast = params.fast,
        .fallback_allow = c.fallback_allow,
        .fallback_active = c.fallback_active,
        .fallback_blocked = c.fallback_blocked,
        .ultracode_mode = params.ultracode,
        .show_thinking = params.thinking,
        .strict = Policy.from(params).strict,
        // Session meters, not per-turn ones: see ReplCtx.
        .last_context_tokens = c.last_context_tokens,
        .context_local_tokens = c.context_local_tokens,
        .last_cache_read = c.last_cache_read,
    };
    try seedSessionState(c, &agent, arena, params.goal);
    try prompts.setSystemPrompts(&agent, sys, arena);
    return agent;
}

fn seedSessionState(c: *ReplCtx, agent: *Agent, arena: Allocator, goal_text: []const u8) !void {
    const root = c.root orelse return;
    if (goal_text.len > 0) {
        if (root.goal) |goal| {
            if (std.mem.eql(u8, goal.objective, goal_text)) {
                var copy = goal;
                copy.objective = try arena.dupe(u8, goal.objective);
                agent.goal = copy;
                for (root.todos.items) |todo| try agent.todos.append(arena, .{
                    .content = try arena.dupe(u8, todo.content),
                    .status = try arena.dupe(u8, todo.status),
                    .epoch = todo.epoch,
                    .retired = todo.retired,
                });
                return;
            }
        }
        const now = util.unixMs(agent.io);
        agent.goal = .{ .objective = try arena.dupe(u8, goal_text), .epoch = if (root.goal) |g| g.epoch + 1 else 1, .standing = true, .created_ms = now, .updated_ms = now };
    }
}

/// Give the turn's agent the session's history. With a conversation the agent
/// BORROWS it — only the new prompt is folded in, so the request's prefix is
/// byte-identical to last turn's (prompt caching) and the model still sees the
/// tool calls it made earlier. Without one, the frontend's transcript is
/// materialized into the throwaway arena, which is all `graff repl` needs.
fn borrowHistory(c: *ReplCtx, agent: *Agent, history: []const repl.Turn, arena: Allocator, scratch: *std.heap.ArenaAllocator) !void {
    const cv = c.convo orelse {
        for (history) |t| {
            try agent.messages.append(try userOrText(agent, arena, t));
        }
        return;
    };
    try cv.adopt(history);
    try promoteTailImages(agent, cv, history);
    agent.messages = cv.list().*;
    // Transient parse garbage goes here instead of the session arena (#124).
    agent.scratch_arena = scratch;
}

/// A recalled TUI prompt carries `@[path]` markers. Stage the files so the
/// model gets pixels, not the literal marker (#577).
fn userOrText(agent: *Agent, arena: Allocator, t: repl.Turn) !std.json.Value {
    if (t.role != .user) return textMessage(arena, "assistant", t.text);
    vision.stageGuiImageAttachment(agent, t.text);
    return vision_queue.consumePromptImages(arena, agent, t.text);
}

fn promoteTailImages(agent: *Agent, cv: anytype, history: []const repl.Turn) !void {
    if (history.len == 0 or history[history.len - 1].role != .user) return;
    const text = history[history.len - 1].text;
    vision.stageGuiImageAttachment(agent, text);
    if (agent.pending_image_len == 0) return;
    const msgs = cv.list();
    if (msgs.items.len == 0) return;
    msgs.items[msgs.items.len - 1] = try vision_queue.consumePromptImages(cv.alloc(), agent, text);
}

/// Hand the conversation back. runTurn appended this turn's assistant message
/// and every tool_use/tool_result pair to the borrowed list, and a managed
/// ArrayList is a VALUE — not copying it back would drop the whole turn.
fn returnHistory(c: *ReplCtx, agent: *Agent) void {
    if (c.convo) |cv| cv.list().* = agent.messages;
    const root = c.root orelse return;
    root.strict = agent.strict;
    root.ultracode_mode = agent.ultracode_mode;
    root.last_context_tokens = agent.last_context_tokens;
    root.context_local_tokens = agent.context_local_tokens;
    root.last_cache_read = agent.last_cache_read;
    root.goal = if (agent.goal) |goal| blk: {
        var copy = goal;
        copy.objective = root.arena.dupe(u8, goal.objective) catch break :blk root.goal;
        break :blk copy;
    } else null;
    root.todos.clearRetainingCapacity();
    for (agent.todos.items) |todo| root.todos.append(root.arena, .{
        .content = root.arena.dupe(u8, todo.content) catch continue,
        .status = root.arena.dupe(u8, todo.status) catch continue,
        .epoch = todo.epoch,
        .retired = todo.retired,
    }) catch break;
}

/// repl.TurnFn — run a full ROOT agent turn (tools + MCP) for the chat
/// frontends, so the model can read files, run bash, search the codebase, etc.
/// Output streams into a thread-safe sink the frontend polls to render live;
/// the clean final text is runTurn's return value. Returns the final assistant
/// text (raw markdown, owned by gpa) or null.
pub fn replTurnCb(ctx_ptr: ?*anyopaque, gpa: Allocator, history: []const repl.Turn, params: repl.Params, stream: *repl.StreamBuf) ?[]const u8 {
    const c: *ReplCtx = @ptrCast(@alignCast(ctx_ptr orelse return null));
    // Per-turn scratch. When the session owns a conversation this is the
    // agent's `scratch_arena` (reset per request, #124) and the conversation's
    // arena is the agent's `arena`, so provider responses — the tool_use and
    // tool_result blocks — are written where they OUTLIVE the turn. Without a
    // conversation it is both, which is the old throwaway behavior.
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const arena = if (c.convo) |cv| cv.alloc() else scratch;
    var sink: repl_glue.ReplStreamSink = undefined;
    sink.init(stream); // agent output streams into the repl's live pane (thread-safe)
    const policy = Policy.from(params);
    // plan_mode is a process global (agent_tool_gate/exec read it), so it is
    // armed and restored around the call rather than left set — a chat turn
    // must not silently change the mode of whatever else shares this process.
    const plan_saved = main_mod.plan_mode;
    main_mod.plan_mode = policy.plan;
    defer main_mod.plan_mode = plan_saved;
    var approvals: Approvals = .{ .yolo = policy.yolo };
    var agent = turnAgent(c, gpa, arena, params, &sink.writer, &approvals) catch return null;
    defer agent.tools_used.deinit(gpa);
    borrowHistory(c, &agent, history, arena, &scratch_state) catch return null;
    defer {
        c.provider = agent.provider;
        c.fallback_active = agent.fallback_active;
        c.fallback_blocked = agent.fallback_blocked;
        c.last_context_tokens = agent.last_context_tokens;
        c.context_local_tokens = agent.context_local_tokens;
        c.last_cache_read = agent.last_cache_read;
        returnHistory(c, &agent);
        // The engine's own status line, as a typed event (#551): the frontend
        // renders /context, /session-info and its footer from THIS rather than
        // from characters it counted. Emitted on every exit path, including the
        // early ends, because a stalled turn still moved the meters.
        agent.prompt() catch {};
    }
    const final = providers.runTurnWithFallback(&agent, &c.keys, arena, &sink.writer) catch |err| switch (err) {
        // A mid-stream stall (#134): the repl turn IS live (stream_quiet=false),
        // so postStream can return error.StreamStalled. Don't collapse it to
        // null — the pane renders that as "model call failed — check /model and
        // your API key", mislabeling a harness stall as an auth/config problem.
        // Keep the streamed partial + an honest marker, mirroring mainloop.
        error.StreamStalled => return earlyEnd(gpa, &agent, "stream stalled"),
        // A mid-stream provider drop (#133), same handling as a stall.
        error.StreamDropped => return earlyEnd(gpa, &agent, "connection dropped"),
        // The Responses WS path now preserves a bounded provider diagnostic.
        // Return it as the turn result so the fullscreen TUI does not discard
        // the live error and replace it with the misleading API-key fallback.
        error.ApiError => return gpa.dupe(u8, agent.last_api_error orelse "provider API error") catch null,
        error.FallbackConsentRequired => return gpa.dupe(u8, "Saved model unavailable. Allow this provider with /fallback in the standard REPL, or choose another model.") catch null,
        else => return null,
    };
    const trimmed = std.mem.trim(u8, final, " \t\r\n");
    if (trimmed.len == 0) return null;
    session.saveSessionAsync(&agent, arena, agent.session_name) catch {};
    return gpa.dupe(u8, trimmed) catch null;
}

/// Keep whatever streamed plus an honest marker — never a null, which the pane
/// renders as "model call failed — check /model and your API key".
fn earlyEnd(gpa: Allocator, agent: *Agent, why: []const u8) ?[]const u8 {
    const partial = std.mem.trim(u8, agent.partial_text.items, " \t\r\n");
    return if (partial.len > 0)
        std.fmt.allocPrint(gpa, "{s}\n\n[response ended early: {s}]", .{ partial, why }) catch null
    else
        std.fmt.allocPrint(gpa, "[response ended early: {s}]", .{why}) catch null;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A session context with no provider behind it — enough for anything that
/// exercises gates, prompts or history rather than a model call. Shared with
/// repl_bash.zig's tests, which drive the same turnAgent.
pub fn testCtx(client: *std.http.Client) ReplCtx {
    return .{
        .io = testing.io,
        .client = client,
        .keys = .{ .values = @splat(null) },
        .home = "",
        .provider = .{
            .id = "anthropic",
            .kind = .anthropic,
            .auth = .x_api_key,
            .url = "",
            .api_key = "",
            .model = "sonnet",
            .context = 200_000,
        },
        .fallback_allow = &.{},
        .fallback_active = false,
        .fallback_blocked = false,
        .registry = null,
        .tracer = null,
        .run_budget = null,
        .sys_normal = "BASE-PROMPT",
        .tools_anthropic = "[]",
        .tools_openai = "[]",
        .tools_responses = "[]",
    };
}

test "plan mode on a chat turn actually denies a write_file (#551)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var client: std.http.Client = undefined;
    var c = testCtx(&client);
    var discard_buf: [64]u8 = undefined;
    var discarding: Io.Writer.Discarding = .init(&discard_buf);

    var call_input: std.json.ObjectMap = .empty;
    try call_input.put(arena, "path", .{ .string = "notes.md" });
    try call_input.put(arena, "content", .{ .string = "hello" });
    const call: @import("tools.zig").ToolCall = .{
        .id = "t1",
        .name = "write_file",
        .input = .{ .object = call_input },
    };

    const plan_saved = main_mod.plan_mode;
    defer main_mod.plan_mode = plan_saved;

    // Plan mode: exactly the params a /plan TUI turn sends.
    {
        const params: repl.Params = .{ .mode = .plan };
        const policy = Policy.from(params);
        try testing.expect(policy.plan);
        // Auto-approval is NOT what stops the write; the plan gate is.
        try testing.expect(!policy.yolo);
        main_mod.plan_mode = policy.plan;
        var approvals: Approvals = .{ .yolo = policy.yolo };
        var agent = try turnAgent(&c, testing.allocator, arena, params, &discarding.writer, &approvals);
        defer agent.tools_used.deinit(testing.allocator);
        const denied = (try agent.gateTool(call)) orelse return error.PlanModeLetTheWriteThrough;
        try testing.expect(denied.is_error);
        try testing.expect(std.mem.indexOf(u8, denied.text, "plan mode") != null);
    }

    // The same call in the default mode is not refused — the denial above is
    // the mode doing its job, not a write_file that never works here.
    {
        const params: repl.Params = .{ .mode = .always_approve };
        const policy = Policy.from(params);
        try testing.expect(!policy.plan);
        try testing.expect(policy.yolo);
        main_mod.plan_mode = policy.plan;
        var approvals: Approvals = .{ .yolo = policy.yolo };
        var agent = try turnAgent(&c, testing.allocator, arena, params, &discarding.writer, &approvals);
        defer agent.tools_used.deinit(testing.allocator);
        try testing.expect((try agent.gateTool(call)) == null);
    }
}

/// Stand in for the provider round trip: write into the borrowed history
/// exactly the shape agent_steps writes for an anthropic tool turn — an
/// assistant message carrying a tool_use block, then the user message carrying
/// its tool_result. This is the content the TUI's flattened `.user`/`.assistant`
/// rows can never carry back, which is the whole point of the conversation.
fn fakeToolTurn(agent: *Agent, id: []const u8, cmd: []const u8, result: []const u8) !void {
    const a = agent.arena;
    var use: std.json.ObjectMap = .empty;
    try use.put(a, "type", .{ .string = "tool_use" });
    try use.put(a, "id", .{ .string = id });
    try use.put(a, "name", .{ .string = "bash" });
    var input: std.json.ObjectMap = .empty;
    try input.put(a, "command", .{ .string = cmd });
    try use.put(a, "input", .{ .object = input });
    var content = std.json.Array.init(a);
    try content.append(.{ .object = use });
    var assistant: std.json.ObjectMap = .empty;
    try assistant.put(a, "role", .{ .string = "assistant" });
    try assistant.put(a, "content", .{ .array = content });
    try agent.messages.append(.{ .object = assistant });

    var results = std.json.Array.init(a);
    try results.append(try @import("messages.zig").toolResultMessage(a, .anthropic, id, result, false));
    var wrapper: std.json.ObjectMap = .empty;
    try wrapper.put(a, "role", .{ .string = "user" });
    try wrapper.put(a, "content", .{ .array = results });
    try agent.messages.append(.{ .object = wrapper });
}

test "turn 2 carries turn 1's tool_use and tool_result; /clear drops both (#551)" {
    const gpa = testing.allocator;
    var client: std.http.Client = undefined;
    var c = testCtx(&client);
    var convo = @import("repl_convo.zig").Conversation.init(gpa);
    defer convo.deinit();
    c.convo = &convo;
    var discard_buf: [64]u8 = undefined;
    var discarding: Io.Writer.Discarding = .init(&discard_buf);
    var approvals: Approvals = .{ .yolo = true };
    const tools = "[{\"name\":\"bash\",\"description\":\"\",\"input_schema\":{\"type\":\"object\"}}]";

    // ── turn 1: the user asks, the engine runs a tool ──────────────────────
    {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        var agent = try turnAgent(&c, gpa, convo.alloc(), .{}, &discarding.writer, &approvals);
        defer agent.tools_used.deinit(gpa);
        try borrowHistory(&c, &agent, &.{.{ .role = .user, .text = "count the files" }}, convo.alloc(), &scratch);
        try fakeToolTurn(&agent, "call-1", "ls | wc -l", "42");
        try agent.messages.append(try textMessage(agent.arena, "assistant", "there are 42"));
        returnHistory(&c, &agent);
    }

    // ── turn 2: the request must still contain turn 1's tool exchange ──────
    {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        var agent = try turnAgent(&c, gpa, convo.alloc(), .{}, &discarding.writer, &approvals);
        defer agent.tools_used.deinit(gpa);
        try borrowHistory(&c, &agent, &.{
            .{ .role = .user, .text = "count the files" },
            .{ .role = .assistant, .text = "there are 42" },
            .{ .role = .user, .text = "and how many are zig?" },
        }, convo.alloc(), &scratch);
        const body = try agent.buildBody(tools, false, true, true);
        defer gpa.free(body);
        try testing.expect(std.mem.indexOf(u8, body, "tool_use") != null);
        try testing.expect(std.mem.indexOf(u8, body, "call-1") != null);
        try testing.expect(std.mem.indexOf(u8, body, "tool_result") != null);
        try testing.expect(std.mem.indexOf(u8, body, "ls | wc -l") != null);
        try testing.expect(std.mem.indexOf(u8, body, "and how many are zig?") != null);
        // The first prompt appears ONCE — adopt() folds in only the new tail,
        // it does not re-materialize the transcript on top of itself.
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "count the files"));
        returnHistory(&c, &agent);
    }

    // ── /clear: the next turn carries neither ─────────────────────────────
    convo.reset();
    {
        var scratch = std.heap.ArenaAllocator.init(gpa);
        defer scratch.deinit();
        var agent = try turnAgent(&c, gpa, convo.alloc(), .{}, &discarding.writer, &approvals);
        defer agent.tools_used.deinit(gpa);
        try borrowHistory(&c, &agent, &.{.{ .role = .user, .text = "fresh start" }}, convo.alloc(), &scratch);
        const body = try agent.buildBody(tools, false, true, true);
        defer gpa.free(body);
        try testing.expect(std.mem.indexOf(u8, body, "tool_use") == null);
        try testing.expect(std.mem.indexOf(u8, body, "call-1") == null);
        try testing.expect(std.mem.indexOf(u8, body, "tool_result") == null);
        try testing.expect(std.mem.indexOf(u8, body, "count the files") == null);
        try testing.expect(std.mem.indexOf(u8, body, "fresh start") != null);
        returnHistory(&c, &agent);
    }
}

test "without a conversation every turn is still built from the transcript" {
    // `graff repl`'s scripted path has no session memory and must keep working
    // exactly as it did — this is the branch the TUI no longer takes.
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    var client: std.http.Client = undefined;
    var c = testCtx(&client);
    var discard_buf: [64]u8 = undefined;
    var discarding: Io.Writer.Discarding = .init(&discard_buf);
    var approvals: Approvals = .{ .yolo = true };
    var agent = try turnAgent(&c, gpa, arena, .{}, &discarding.writer, &approvals);
    defer agent.tools_used.deinit(gpa);
    try borrowHistory(&c, &agent, &.{
        .{ .role = .user, .text = "one" },
        .{ .role = .assistant, .text = "two" },
    }, arena, &scratch);
    try testing.expectEqual(@as(usize, 2), agent.messages.items.len);
    try testing.expect(agent.scratch_arena == null);
    returnHistory(&c, &agent); // a no-op without a conversation
}

test "/strict selects the strict system prompt on the turn's agent (#551)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var client: std.http.Client = undefined;
    var c = testCtx(&client);
    var discard_buf: [64]u8 = undefined;
    var discarding: Io.Writer.Discarding = .init(&discard_buf);
    var approvals: Approvals = .{ .yolo = true };

    var relaxed = try turnAgent(&c, testing.allocator, arena, .{}, &discarding.writer, &approvals);
    defer relaxed.tools_used.deinit(testing.allocator);
    try testing.expect(!relaxed.strict);
    try testing.expectEqualStrings(relaxed.sys_normal, relaxed.systemPrompt());

    var strict = try turnAgent(&c, testing.allocator, arena, .{ .strict = true }, &discarding.writer, &approvals);
    defer strict.tools_used.deinit(testing.allocator);
    try testing.expect(strict.strict);
    try testing.expectEqualStrings(strict.sys_strict, strict.systemPrompt());
    // Not the same text — a /strict that resolved back to sys_normal would be
    // the label-only bug wearing a different hat.
    try testing.expect(!std.mem.eql(u8, strict.sys_normal, strict.systemPrompt()));

    // /strict composes with ultracode rather than being replaced by it (#326).
    var both = try turnAgent(&c, testing.allocator, arena, .{ .strict = true, .ultracode = true }, &discarding.writer, &approvals);
    defer both.tools_used.deinit(testing.allocator);
    try testing.expectEqualStrings(both.sys_ultra_strict, both.systemPrompt());
}
