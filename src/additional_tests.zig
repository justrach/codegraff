const std = @import("std");
const Io = std.Io;
const readline_commit = @import("readline_commit.zig");

test {
    _ = @import("readline_history.zig");
    _ = @import("stable_sort.zig");
    _ = @import("codedbpro_paths.zig");
    _ = @import("agent_request_body_responses.zig");
    _ = @import("agent_server_compact_tests.zig");
    _ = @import("agent_server_compact_route_tests.zig");
    _ = @import("compaction_quiet_delivery_tests.zig");
    _ = @import("compact_at.zig");
    _ = @import("client_tags.zig");
    _ = @import("provider_codegraff_tests.zig");
    _ = @import("agent_responses.zig");
    _ = @import("session_branch.zig");
    _ = @import("acp_subagent_progress.zig");
    _ = @import("vault_crypto.zig");
    _ = @import("vault_client.zig");
    _ = @import("vault_sync.zig");
    _ = @import("keys_vault_cli.zig");
    _ = @import("vault_refresh.zig");
    _ = @import("vault_live.zig");
    _ = @import("peer_cli.zig");
    // engine_events.zig's tests (that file hit the 600-line cap), and the
    // codegraff/runTask facts that cross MCP result -> tool_result -> ACP _meta.
    _ = @import("engine_events_tests.zig");
    _ = @import("run_task_meta.zig");
    _ = @import("acp_run_task_tests.zig");
    _ = @import("mcp_cancel_notice.zig");
    // Claude Agent provider (ADR 0309).
    _ = @import("claude_agent_tests.zig");
    _ = @import("claude_agent_login.zig");
    _ = @import("claude_agent.zig");
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
    const ansi = @import("ansi.zig");
    const saved = ansi.style;
    ansi.style = ansi.Style.harness;
    defer ansi.style = saved;
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const mark = "[Image #1]";
    readline_commit.commit(&output.writer, mark ++ " caption", &.{mark}, null, 2, 1, 3, true);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output.writer.buffered(),
        "\x1b[38;2;232;163;61m\x1b[7m[Image #1]\x1b[0m caption",
    ) != null);
}
