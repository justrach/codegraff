//! Consecutive identical user turns are not a new ask (#714).
//!
//! The TUI/ACP host can re-submit the same trailing user row; combined with
//! the named-source gate that looked like a fresh question every time. Skip
//! the duplicate. After `max_replays` identical injects, fail closed.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const messages = @import("messages.zig");
const vision = @import("vision.zig");
const vision_queue = @import("vision_queue.zig");
const ansi = @import("ansi.zig");
const style = &ansi.style;
const side_steer = @import("side_steer.zig");

pub const max_replays: u8 = 3;

pub const stuck_text = "stuck replay: the same user turn was injected again; stopping so this session does not loop";

var hits: u8 = 0;

pub fn resetForTest() void {
    hits = 0;
}

pub const Outcome = enum { started, skipped, stuck };

/// Append `text` as this turn's user message, or skip a back-to-back
/// duplicate. The same words after an assistant reply are a new ask
/// (learn-auto sends one prompt per model call).
pub fn enqueue(root: *Agent, arena: Allocator, out: ?*Io.Writer, text: []const u8) !Outcome {
    if (@import("subagent_interactive.zig").line_notice) {
        // ADR 0247: a parked session resuming on its own says what woke it.
        if (out) |w| {
            var buf: [160]u8 = undefined;
            w.print("{s}↻ {s} — continuing{s}\n", .{ style.dim, @import("background_wait.zig").resumeLine(&buf, text), style.reset }) catch {};
            w.flush() catch {};
        }
        try root.messages.append(try @import("session_wake.zig").message(arena, text));
        return .started;
    }
    try side_steer.deliverReports(root, arena, out);
    // A `&`-marked line spawns a side agent instead of becoming the next
    // blocking turn; the session stays interactive and its report is injected
    // at a later boundary.
    if (side_steer.isSideRequest(text)) {
        _ = try side_steer.spawnSide(root, arena, out, text);
        return .skipped;
    }
    if (messages.trailingUserIs(root.messages.items, text)) {
        hits +|= 1;
        if (hits >= max_replays) {
            // A skipped turn runs no model call and records no trajectory
            // nodes; without this note it is invisible next to a prompt the
            // worker never received at all.
            if (root.tracer) |tr| tr.note("turn_dedup", "stuck replay");
            if (out) |w| {
                w.print("{s}{s}{s}\n", .{ style.yellow, stuck_text, style.reset }) catch {};
                w.flush() catch {};
            } else {
                root.say("{s}\n", .{stuck_text}) catch {};
            }
            return .stuck;
        }
        if (root.tracer) |tr| tr.note("turn_dedup", "skipped duplicate");
        return .skipped;
    }
    hits = 0;
    vision.stageGuiImageAttachment(root, text);
    try root.messages.append(try vision_queue.consumePromptImages(arena, root, text));
    return .started;
}

/// True when the caller should not start a model turn.
pub fn enqueueOrSkip(root: *Agent, arena: Allocator, out: ?*Io.Writer, text: []const u8) !bool {
    return try enqueue(root, arena, out, text) != .started;
}

/// #1729: a turn that ended in an error before any reply left its prompt as
/// the last row of history, so resending the same words read as the host
/// re-submitting a pending row and was skipped without a request. Close the
/// failed turn with an assistant row that says what streamed (if anything)
/// and why no reply came. It is persisted with the session, so the boundary
/// survives a checkpoint reload, and the model sees the request failed. A
/// no-op when the turn already left a row after the prompt (a cancel or
/// stream-end marker, a tool result), so those paths keep their own text.
pub fn settleFailedTurn(root: *Agent, arena: Allocator, err: anyerror) !void {
    const items = root.messages.items;
    if (items.len == 0 or messages.userPromptText(items[items.len - 1]) == null) return;
    const why = root.last_api_error orelse @errorName(err);
    const marker = try std.fmt.allocPrint(arena, "[request failed: {s}; no reply was received]", .{why});
    const partial = std.mem.trim(u8, root.partial_text.items, " \t\r\n");
    const text = if (partial.len == 0) marker else try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ partial, marker });
    try root.messages.append(try messages.textMessage(arena, "assistant", text));
}

test "#714: the first copy of a prompt proceeds" {
    resetForTest();
    defer resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = a,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{
            .id = "xai",
            .kind = .openai,
            .auth = .bearer,
            .url = "",
            .api_key = "k",
            .model = "grok-4.6",
            .context = 100_000,
        },
        .messages = .init(a),
        .sub = false,
        .label = "test",
        .out = null,
    };
    try std.testing.expect(!try enqueueOrSkip(&agent, a, null, "Read SPEC.md"));
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);
    try std.testing.expect(try enqueueOrSkip(&agent, a, null, "Read SPEC.md"));
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);
    try std.testing.expect(try enqueueOrSkip(&agent, a, null, "Read SPEC.md"));
    try std.testing.expect(try enqueueOrSkip(&agent, a, null, "Read SPEC.md"));
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);
}

test "#714: the same words after an assistant reply are a new ask" {
    resetForTest();
    defer resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = a,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{
            .id = "xai",
            .kind = .openai,
            .auth = .bearer,
            .url = "",
            .api_key = "k",
            .model = "grok-4.6",
            .context = 100_000,
        },
        .messages = .init(a),
        .sub = false,
        .label = "test",
        .out = null,
    };
    try std.testing.expect(!try enqueueOrSkip(&agent, a, null, "do a little work"));
    try agent.messages.append(try messages.textMessage(a, "assistant", "LEARN_AUTO_OK"));
    try std.testing.expect(!try enqueueOrSkip(&agent, a, null, "do a little work"));
    try std.testing.expectEqual(@as(usize, 3), agent.messages.items.len);
}

test "a skipped duplicate leaves a trace note instead of vanishing" {
    resetForTest();
    defer resetForTest();
    @import("side_steer.zig").resetForTest();
    defer @import("side_steer.zig").resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    var tracer: @import("trace.zig").Tracer = .{
        .io = std.testing.io,
        .gpa = std.testing.allocator,
        .out = &aw.writer,
        .start = Io.Timestamp.now(std.testing.io, .awake),
    };
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = a,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{
            .id = "xai",
            .kind = .openai,
            .auth = .bearer,
            .url = "",
            .api_key = "k",
            .model = "grok-4.6",
            .context = 100_000,
        },
        .messages = .init(a),
        .sub = false,
        .label = "test",
        .out = null,
        .tracer = &tracer,
    };
    try std.testing.expect(!try enqueueOrSkip(&agent, a, null, "Read SPEC.md"));
    try std.testing.expect(try enqueueOrSkip(&agent, a, null, "Read SPEC.md"));
    const logged = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, logged, "\"turn_dedup\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, logged, "skipped duplicate") != null);
}
