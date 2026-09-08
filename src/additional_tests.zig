const std = @import("std");
const Io = std.Io;
const readline_commit = @import("readline_commit.zig");

test {
    _ = @import("readline_history.zig");
    _ = @import("codedbpro_paths.zig");
    _ = @import("agent_request_body_responses.zig");
    _ = @import("agent_server_compact_tests.zig");
    _ = @import("provider_codegraff_tests.zig");
}

test "oneshot -p still uses the live stall-watched transport" {
    try @import("agent_tests.zig").oneshotUsesLiveTransport(@import("agent.zig").Agent);
}

test "submitted prompt uses autowrap instead of editor-width CRLF" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const text = "a logical prompt long enough to have occupied several narrow editor rows";
    readline_commit.commit(&output.writer, text, &.{}, null, 4, 2, 3, false);
    const bytes = output.writer.buffered();
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, bytes, "\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, bytes, text ++ "\r\n\r\n"));
}

test "submitted prompt preserves authored newline kinds as hard breaks" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    readline_commit.commit(&output.writer, "alpha\nbeta\r\ngamma\rdelta", &.{}, null, 3, 2, 1, false);
    try std.testing.expect(std.mem.endsWith(
        u8,
        output.writer.buffered(),
        "alpha\r\nbeta\r\ngamma\r\ndelta\r\n\r\n",
    ));
}

test "submitted prompt keeps key material masked" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    readline_commit.commit(&output.writer, "/key openai secret-value", &.{}, null, 2, 1, 3, false);
    const bytes = output.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, bytes, "secret-value") == null);
    try std.testing.expect(std.mem.endsWith(u8, bytes, "/key openai ************\r\n\r\n"));
}

test "submitted prompt retains attachment chip styling" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const mark = "[Image #1]";
    readline_commit.commit(&output.writer, mark ++ " caption", &.{mark}, null, 2, 1, 3, true);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.writer.buffered(),
        "\x1b[7;38;2;5;150;105m[Image #1]\x1b[0m caption",
    ) != null);
}
