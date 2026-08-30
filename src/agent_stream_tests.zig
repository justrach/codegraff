//! Stream-termination fixtures kept out of the transport implementation.

const std = @import("std");
const Kind = @import("provider.zig").Provider.Kind;

pub fn streamEnd(is_stream_end: anytype) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // OpenAI/Responses [DONE] sentinel; content merely containing it must not end the stream.
    try std.testing.expect(is_stream_end(arena, Kind.openai, "data: [DONE]"));
    try std.testing.expect(!is_stream_end(arena, Kind.openai, "data: {\"choices\":[{\"delta\":{\"content\":\"[DONE]\"}}]}"));
    // Anthropic event and data payload terminate; a delta with the word does not.
    try std.testing.expect(is_stream_end(arena, Kind.anthropic, "event: message_stop"));
    try std.testing.expect(is_stream_end(arena, Kind.anthropic, "data: {\"type\":\"message_stop\"}"));
    try std.testing.expect(!is_stream_end(arena, Kind.anthropic, "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"message_stop\"}}"));
    // Responses: the event: name is not the end — usage is on the data line.
    try std.testing.expect(!is_stream_end(arena, Kind.responses, "event: response.completed"));
    try std.testing.expect(is_stream_end(arena, Kind.responses, "data: {\"type\":\"response.completed\"}"));
    try std.testing.expect(is_stream_end(arena, Kind.responses, "data: {\"type\":\"response.incomplete\"}"));
    try std.testing.expect(!is_stream_end(arena, Kind.responses, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}"));
    // OpenAI null finish reasons and reasoning deltas remain mid-stream.
    try std.testing.expect(!is_stream_end(arena, Kind.openai, "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":null}]}"));
    try std.testing.expect(!is_stream_end(arena, Kind.openai, "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking\"}}]}"));
}

pub fn openaiCompletion(openai_complete: anytype) !void {
    try std.testing.expect(openai_complete("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}"));
    try std.testing.expect(openai_complete("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}"));
    try std.testing.expect(!openai_complete("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":null}]}"));
    try std.testing.expect(!openai_complete("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"thinking\"}}]}"));
    // Escaped content must not false-match a finish_reason field.
    try std.testing.expect(!openai_complete("data: {\"choices\":[{\"delta\":{\"content\":\"\\\"finish_reason\\\":\\\"x\"}}]}"));
}
