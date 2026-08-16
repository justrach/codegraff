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
const repl = @import("repl.zig");
const repl_glue = @import("repl_glue.zig");
const ReplCtx = repl_glue.ReplCtx;

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
    };
    try prompts.setSystemPrompts(&agent, sys, arena);
    return agent;
}

/// repl.TurnFn — run a full ROOT agent turn (tools + MCP) for the chat
/// frontends, so the model can read files, run bash, search the codebase, etc.
/// Output streams into a thread-safe sink the frontend polls to render live;
/// the clean final text is runTurn's return value. Returns the final assistant
/// text (raw markdown, owned by gpa) or null.
pub fn replTurnCb(ctx_ptr: ?*anyopaque, gpa: Allocator, history: []const repl.Turn, params: repl.Params, stream: *repl.StreamBuf) ?[]const u8 {
    const c: *ReplCtx = @ptrCast(@alignCast(ctx_ptr orelse return null));
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
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
    for (history) |t| {
        const role = switch (t.role) {
            .user => "user",
            .assistant => "assistant",
        };
        agent.messages.append(textMessage(arena, role, t.text) catch return null) catch return null;
    }
    defer {
        c.provider = agent.provider;
        c.fallback_active = agent.fallback_active;
        c.fallback_blocked = agent.fallback_blocked;
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
        error.FallbackConsentRequired => return gpa.dupe(u8, "Saved model unavailable. Allow this provider with /fallback in the standard REPL, or choose another model.") catch null,
        else => return null,
    };
    const trimmed = std.mem.trim(u8, final, " \t\r\n");
    if (trimmed.len == 0) return null;
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

fn testCtx(client: *std.http.Client) ReplCtx {
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
