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
    if (messages.trailingUserIs(root.messages.items, text)) {
        hits +|= 1;
        if (hits >= max_replays) {
            if (out) |w| {
                w.print("{s}{s}{s}\n", .{ style.yellow, stuck_text, style.reset }) catch {};
                w.flush() catch {};
            } else {
                root.say("{s}\n", .{stuck_text}) catch {};
            }
            return .stuck;
        }
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
