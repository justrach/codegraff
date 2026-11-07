//! engine_events.zig's tests, split out when that file reached the 600-line
//! cap (the same move as workflow.zig -> workflow_test.zig). The vocabulary
//! itself stays in engine_events.zig; these only classify it.

const std = @import("std");
const ee = @import("engine_events.zig");
const protocol_seq = @import("protocol_seq.zig");

const EngineEvent = ee.EngineEvent;
const ToolInvocation = ee.ToolInvocation;
const ToolOutcome = ee.ToolOutcome;
const PromptStatus = ee.PromptStatus;
const durable = ee.durable;
const stamp = ee.stamp;
const generation = ee.generation;
const bumpGeneration = ee.bumpGeneration;

test "every variant constructs; only the wire deltas are durable" {
    const wire: [2]EngineEvent = .{
        .{ .reasoning_delta = .{ .text = "why" } },
        .{ .text_delta = .{ .text = "hi" } },
    };
    for (wire) |ev| try std.testing.expect(durable(ev));
    const pulses: [5]EngineEvent = .{
        .stream_begin,
        .thinking_fold_toggle,
        .{ .stream_aborted = .stalled },
        .{ .stream_complete = .{ .streamed_text = true } },
        .stream_finished,
    };
    for (pulses) |ev| try std.testing.expect(!durable(ev));
}

test "stamp: reserving draws fresh monotonic ids; observing never advances" {
    protocol_seq.resetForTest();
    defer protocol_seq.resetForTest();
    const a = stamp(true);
    const b = stamp(true);
    try std.testing.expectEqual(@as(u64, 1), a.sequence);
    try std.testing.expectEqual(a.sequence + 1, b.sequence);
    // A pulse rides at the last reserved position and reserves nothing.
    const o = stamp(false);
    try std.testing.expectEqual(b.sequence, o.sequence);
    try std.testing.expectEqual(b.sequence, protocol_seq.current());
    try std.testing.expectEqual(generation(), o.generation);
}

test "slice 1b: tool-arg prose and transport aborts are presentation pulses" {
    // Neither ever appeared on the --json wire (argLiveDelta gates --json
    // off; the transport notices were TTY-only), so neither may reserve a
    // sequence id — promoting one is a schema_version event, not a default.
    const pulses: [5]EngineEvent = .{
        .{ .tool_arg_delta = .{ .text = "prose" } },
        .{ .tool_output_delta = .{ .name = "bash", .text = "ok" } },
        .{ .job_completed = .{ .id = 1, .exit_code = 0 } },
        .{ .transport_aborted = .{ .reason = .stalled, .turn_ending = true } },
        .{ .transport_aborted = .{ .reason = .dropped, .turn_ending = false } },
    };
    for (pulses) |ev| try std.testing.expect(!durable(ev));
}

test "slice 1c: the tool bracket is durable per TOOL, not per tag" {
    const call: ToolInvocation = .{ .name = "bash", .input = .null };
    const ask: ToolInvocation = .{ .name = "ask_user", .input = .null, .ask_user = true };
    // An ordinary tool's bracket is the wire's tool_call/tool_call_started…
    try std.testing.expect(durable(.{ .tool_call_announced = call }));
    try std.testing.expect(durable(.{ .tool_call_started = call }));
    // …while ask_user's reaches a --json client as the `ask_user` event, so
    // neither half may reserve an id the wire will not spend (#330).
    try std.testing.expect(!durable(.{ .tool_call_announced = ask }));
    try std.testing.expect(!durable(.{ .tool_call_started = ask }));
    // arg_streamed is a TUI-only suppression: the wire still carries the call.
    const streamed: ToolInvocation = .{ .name = "bash", .input = .null, .arg_streamed = true };
    try std.testing.expect(durable(.{ .tool_call_announced = streamed }));

    const ext: ToolOutcome = .{ .name = "bash", .text = "ok", .is_error = false };
    const meta: ToolOutcome = .{ .name = "todo_write", .text = "ok", .is_error = false, .meta = true };
    const answer: ToolOutcome = .{ .name = "ask_user", .text = "yes", .is_error = false, .meta = true, .ask_user = true };
    try std.testing.expect(durable(.{ .tool_result = ext }));
    try std.testing.expect(durable(.{ .tool_call_finished = ext }));
    try std.testing.expect(!durable(.{ .tool_result = meta }));
    try std.testing.expect(!durable(.{ .tool_call_finished = meta }));
    try std.testing.expect(durable(.{ .tool_result = answer }));
    try std.testing.expect(durable(.{ .tool_call_finished = answer }));

    // A refusal has always been a wire-only moment.
    try std.testing.expect(durable(.{ .tool_rejected = .{ .name = "bash", .input = .null, .reason = "budget", .message = "no" } }));
}

test "slice 1c: the tool-cluster notices are presentation pulses" {
    // None of these ever appeared on the --json wire, so promoting one is a
    // schema_version event rather than refactor fallout.
    const pulses: [6]EngineEvent = .{
        .{ .parallel_batch_started = .{ .count = 3 } },
        .{ .parallel_batch_finished = .{ .done = 2, .failed = 1, .cancelled = 0 } },
        .completion_deferred,
        .goal_completed,
        .{ .completion_text = .{ .text = "done" } },
        .{ .todo_list_updated = .{ .text = "todos" } },
    };
    for (pulses) |ev| try std.testing.expect(!durable(ev));
}

test "slice 2: the lifecycle cluster is pulses, except the failover the wire carries" {
    const pulses: [9]EngineEvent = .{
        .{ .session_notice = .{ .text = "loaded 2 saved approval(s)", .tone = .dim } },
        .{ .session_banner = .{ .cwd = "/repo", .trace_path = ".graff/traces/a.jsonl" } },
        .{ .worktree_entered = .{ .path = ".graff/worktrees/w", .branch = "worktree-w", .autocommit = true } },
        .{ .shared_worktree_owner = .{ .session_id = "session-1", .pid = 42, .active_minutes = 5, .goal = "ship safely" } },
        .{ .saved_model_unavailable = .{ .saved = "old", .model = "new", .provider = "codex", .blocked = false } },
        .{ .mcp_consent_prompt = .{ .count = 3 } },
        .{ .session_saved = .{ .name = "session-1", .ext = ".session.json" } },
        .run_finished,
        // A notice with a badge is still a notice, not a second variant.
        .{ .session_notice = .{ .lead = "⚠ YOLO", .text = " mode", .tone = .alert } },
    };
    for (pulses) |ev| try std.testing.expect(!durable(ev));
    // The failover has always reached a --json client as the `model` event, so
    // it reserves an id like any other wire line.
    try std.testing.expect(durable(.{ .provider_fallback = .{
        .from_provider = "codex",
        .from_model = "gpt-5.5",
        .to_provider = "anthropic",
        .to_model = "sonnet",
        .to_context = 200_000,
        .context_note = "context kept",
    } }));
}

test "batch 3: the status line is a presentation pulse, never a wire line" {
    // The --json wire has never had a prompt event and must not grow one by
    // accident: a client that drives its own turns would read a burned
    // sequence id as lost data (#330).
    const status: PromptStatus = .{
        .model = "gpt-5.6",
        .provider_id = "codex",
        .cwd = "~/src/graff",
        .privacy_label = "Privacy:Aggregate",
        .privacy = .aggregate,
        .effort = .high,
        .context = .{ .tokens = 12_345, .window = 200_000, .compact_at = 160_000 },
        .cache_read = 2048,
        .cost = .subscription,
    };
    try std.testing.expect(!durable(.{ .prompt_ready = status }));
}

test "generation only moves forward, one restart at a time" {
    const before = generation();
    try std.testing.expect(before >= 1);
    try std.testing.expectEqual(before + 1, bumpGeneration());
    try std.testing.expectEqual(before + 1, generation());
}
