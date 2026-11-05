//! Waiting for one MCP reply without leaving the user stuck.
//!
//! A `tools/call` over stdio used to block on the pipe until the server
//! answered: Esc set the turn's cancel flag but nothing looked at it, so a
//! slow or hung server held the turn, and the server kept working on a
//! request nobody wanted. The read now races a watcher on the cancel flag.
//! On cancel graff stops reading, tells the server with
//! `notifications/cancelled`, and returns `error.McpCancelled`. A late reply
//! to that id is skipped by the next request's id match.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const mcp_elicitation = @import("mcp_elicitation.zig");
const mcp_http = @import("mcp_http.zig");
const mcp_inbound = @import("mcp_inbound.zig");
const mcp_notify = @import("mcp_notify.zig");
const mcp_stdio = @import("mcp_stdio.zig");

/// Whether the user asked to stop the current turn. The engine points this
/// at its cancel flag; tests replace it.
pub var cancel_requested: *const fn () bool = escPressed;

fn escPressed() bool {
    return @import("agent.zig").Agent.esc_cancel.load(.acquire);
}

const poll_ms = 50;

/// Returns when cancel is requested or `done` is set.
pub fn watchCancel(io: Io, done: *std.atomic.Value(bool)) void {
    while (!done.load(.acquire)) {
        if (cancel_requested()) return;
        io.sleep(.fromMilliseconds(poll_ms), .awake) catch return;
    }
    // `done` wins: park until the select cancels this task.
    while (true) io.sleep(.fromSeconds(3600), .awake) catch return;
}

pub const Stdio = struct {
    writer: *Io.Writer,
    reader: *Io.Reader,
    sink: *mcp_notify.Sink,
};

fn readReply(s: Stdio, io: Io, a: Allocator, id: i64) !Value {
    while (true) {
        const line = try mcp_stdio.takeLine(s.reader);
        if (try mcp_elicitation.replyStdio(s.writer, a, line)) continue;
        if (try mcp_inbound.replyStdio(s.writer, a, line)) continue;
        if (mcp_http.matchingResponse(a, line, id)) |parsed| return parsed;
        _ = mcp_notify.observe(s.sink, io, line);
    }
}

const Done = union(enum) {
    replied: anyerror!Value,
    cancelled,
};

/// Await the reply to `id` on a stdio server, honoring cancel.
pub fn awaitStdio(s: Stdio, io: Io, a: Allocator, id: i64) !Value {
    if (cancel_requested()) return cancelStdio(s, a, id);
    var done = std.atomic.Value(bool).init(false);
    var buf: [2]Done = undefined;
    var select: Io.Select(Done) = .init(io, &buf);
    select.concurrent(.replied, readReply, .{ s, io, a, id }) catch return readReply(s, io, a, id);
    select.concurrent(.cancelled, watchCancel, .{ io, &done }) catch {
        const only = select.await() catch return error.McpCancelled;
        select.cancelDiscard();
        return only.replied;
    };
    const first = select.await() catch return error.McpCancelled;
    done.store(true, .release);
    switch (first) {
        .replied => |result| {
            select.cancelDiscard();
            return result;
        },
        .cancelled => {
            _ = select.cancel(); // blocks until the read task has stopped
            return cancelStdio(s, a, id);
        },
    }
}

fn cancelStdio(s: Stdio, a: Allocator, id: i64) error{McpCancelled} {
    const line = mcp_notify.cancelledLine(a, id) catch return error.McpCancelled;
    mcp_stdio.writeRequest(s.writer, line) catch {};
    return error.McpCancelled;
}

const testing = std.testing;

var test_cancel = std.atomic.Value(bool).init(false);
fn testCancelled() bool {
    return test_cancel.load(.acquire);
}

test "awaitStdio: notifications are observed and the matching reply returns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var in: Io.Reader = .fixed(
        \\{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":3,"progress":1}}
        \\{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}
        \\{"jsonrpc":"2.0","id":2,"result":{"stale":true}}
        \\{"jsonrpc":"2.0","id":3,"result":{"ok":true}}
        \\
    );
    var out_buf: [512]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    var sink: mcp_notify.Sink = .{ .server = "demo" };
    const got = try readReply(.{ .writer = &out, .reader = &in, .sink = &sink }, testing.io, a, 3);
    try testing.expect(got.object.get("result").?.object.get("ok").?.bool);
    try testing.expect(sink.tools_stale.load(.acquire));
}

test "MCP inbound ping: wait reader answers interleaved pings without losing progress or tool result" {
    const Progress = struct {
        var observed = false;
        fn record(_: Io, server: []const u8, text: []const u8) void {
            observed = std.mem.eql(u8, server, "demo") and std.mem.eql(u8, text, "1/2 working");
        }
    };
    Progress.observed = false;
    const saved = mcp_notify.on_progress;
    defer mcp_notify.on_progress = saved;
    mcp_notify.on_progress = Progress.record;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var in: Io.Reader = .fixed(
        \\{"jsonrpc":"2.0","id":3,"method":"ping"}
        \\{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":3,"progress":1,"total":2,"message":"working"}}
        \\{"jsonrpc":"2.0","id":"server-ping","method":"ping","params":{}}
        \\{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"done"}]}}
        \\
    );
    var out_buf: [512]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    var sink: mcp_notify.Sink = .{ .server = "demo" };
    const got = try readReply(.{ .writer = &out, .reader = &in, .sink = &sink }, testing.io, arena.allocator(), 3);
    try testing.expect(Progress.observed);
    try testing.expectEqualStrings("done", got.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":\"server-ping\",\"result\":{}}\n",
        out.buffered(),
    );
}

test "awaitStdio: a cancel already requested sends notifications/cancelled" {
    const saved = cancel_requested;
    defer cancel_requested = saved;
    cancel_requested = testCancelled;
    test_cancel.store(true, .release);
    defer test_cancel.store(false, .release);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var in: Io.Reader = .fixed("");
    var out_buf: [512]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    var sink: mcp_notify.Sink = .{};
    try testing.expectError(error.McpCancelled, awaitStdio(.{ .writer = &out, .reader = &in, .sink = &sink }, testing.io, arena.allocator(), 11));
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "\"notifications/cancelled\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "\"requestId\":11") != null);
}
