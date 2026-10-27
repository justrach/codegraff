//! #1729: a failed turn must not turn its own retry into a "duplicate".
//!
//! turn_dedup skips a prompt only when history already ends on that exact
//! user row (#714: a host re-submitting a pending row). A turn that failed
//! before any reply used to leave its prompt in that position, so resending
//! the same words after the endpoint recovered finished without a request.
//! `settleFailedTurn` closes the failed turn with an assistant row; these
//! tests pin that the retry starts, that the boundary survives a checkpoint
//! round trip on every wire, and that the #714 guard still holds.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const messages = @import("messages.zig");
const dedup = @import("turn_dedup.zig");
const session = @import("session.zig");
const session_writer = @import("session_writer.zig");
const session_transcript = @import("session_transcript.zig");

fn testAgent(a: Allocator, client: ?*std.http.Client) Agent {
    return .{
        .gpa = std.testing.allocator,
        .arena = a,
        .io = std.testing.io,
        .client = if (client) |c| c else undefined,
        .provider = .{ .id = "xai", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "grok-4.6", .context = 100_000 },
        .messages = .init(a),
        .sub = false,
        .label = "test",
        .out = null,
        .session_title = "retry test",
    };
}

fn lastText(agent: *Agent) []const u8 {
    const last = agent.messages.items[agent.messages.items.len - 1];
    return last.object.get("content").?.string;
}

test "#1729: an identical prompt after a failed turn starts a new request" {
    dedup.resetForTest();
    defer dedup.resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, null);
    defer agent.partial_text.deinit(std.testing.allocator);
    try std.testing.expectEqual(dedup.Outcome.started, try dedup.enqueue(&agent, a, null, "summarize the README"));
    agent.last_api_error = "network error: ConnectionRefused (gave up after 6 attempts)";
    try dedup.settleFailedTurn(&agent, a, error.ApiError);
    try std.testing.expectEqual(@as(usize, 2), agent.messages.items.len);
    try std.testing.expectEqualStrings(
        "[request failed: network error: ConnectionRefused (gave up after 6 attempts); no reply was received]",
        lastText(&agent),
    );
    // The endpoint is back and the user sends the same words: a new ask, not
    // a host replay. Repeating it after each failure never trips the stuck
    // latch either, because every attempt was a real request.
    for (0..dedup.max_replays + 1) |_| {
        try std.testing.expectEqual(dedup.Outcome.started, try dedup.enqueue(&agent, a, null, "summarize the README"));
        try dedup.settleFailedTurn(&agent, a, error.ConnectionRefused);
    }
    try std.testing.expectEqualStrings("[request failed: network error: ConnectionRefused (gave up after 6 attempts); no reply was received]", lastText(&agent));
}

test "#1729: the boundary keeps what streamed and falls back to the error name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, null);
    defer agent.partial_text.deinit(std.testing.allocator);
    try agent.messages.append(try messages.textMessage(a, "user", "go"));
    try agent.partial_text.appendSlice(std.testing.allocator, "  half an answer \n");
    try dedup.settleFailedTurn(&agent, a, error.FallbackConsentRequired);
    try std.testing.expectEqualStrings("half an answer\n\n[request failed: FallbackConsentRequired; no reply was received]", lastText(&agent));
}

test "#1729: a turn that already left a row after its prompt is not settled twice" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, null);
    defer agent.partial_text.deinit(std.testing.allocator);
    try dedup.settleFailedTurn(&agent, a, error.ApiError); // empty history
    try std.testing.expectEqual(@as(usize, 0), agent.messages.items.len);
    try agent.messages.append(try messages.textMessage(a, "user", "go"));
    // A cancel or stream-end marker already closed the turn.
    try agent.messages.append(try messages.textMessage(a, "assistant", "[response ended early: connection dropped]"));
    try dedup.settleFailedTurn(&agent, a, error.StreamDropped);
    try std.testing.expectEqual(@as(usize, 2), agent.messages.items.len);
}

test "#1729: a host re-submitting a pending prompt is still skipped (#714)" {
    dedup.resetForTest();
    defer dedup.resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, null);
    try std.testing.expectEqual(dedup.Outcome.started, try dedup.enqueue(&agent, a, null, "Read SPEC.md"));
    // No failure was recorded: the row is still pending, so the copy is a replay.
    try std.testing.expectEqual(dedup.Outcome.skipped, try dedup.enqueue(&agent, a, null, "Read SPEC.md"));
    try std.testing.expectEqual(dedup.Outcome.skipped, try dedup.enqueue(&agent, a, null, "Read SPEC.md"));
    try std.testing.expectEqual(dedup.Outcome.stuck, try dedup.enqueue(&agent, a, null, "Read SPEC.md"));
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);
}

test "#1729: the failed-request boundary survives a checkpoint reload on every wire" {
    const gpa = std.testing.allocator;
    dedup.resetForTest();
    defer dedup.resetForTest();
    session_writer.resetForTest();
    defer session_writer.resetForTest();
    session_transcript.resetForTest();
    defer session_transcript.resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var client: std.http.Client = .{ .allocator = gpa, .io = std.testing.io };
    var agent = testAgent(a, &client);
    defer agent.partial_text.deinit(gpa);
    try std.testing.expectEqual(dedup.Outcome.started, try dedup.enqueue(&agent, a, null, "summarize the README"));
    try dedup.settleFailedTurn(&agent, a, error.ApiError);
    try session.saveSessionTo(&agent, a, tmp.dir, "retry");
    session.flushSaves();
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, ".graff/sessions/retry.session.json", gpa, .limited(64 * 1024));
    defer gpa.free(bytes);
    // Load applies history_wire.prepare for the session's wire; the boundary
    // must stay the last row whichever wire the session resumes on.
    for ([_]@import("provider.zig").Provider.Kind{ .openai, .responses, .anthropic, .interactions }) |kind| {
        const saved = try std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always });
        var reloaded = testAgent(a, null);
        reloaded.messages = saved.object.get("messages").?.array;
        @import("history_wire.zig").prepare(a, kind, &reloaded.messages);
        try std.testing.expect(!messages.trailingUserIs(reloaded.messages.items, "summarize the README"));
        try std.testing.expectEqual(dedup.Outcome.started, try dedup.enqueue(&reloaded, a, null, "summarize the README"));
    }
}
