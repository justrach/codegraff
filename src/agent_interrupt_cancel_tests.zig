//! A client cancel must cut a retry backoff short, not wait it out (#1699).

const std = @import("std");
const Io = std.Io;
const Agent = @import("agent.zig").Agent;
const acp_engine = @import("acp_engine.zig");
const cancel_source = @import("cancel_source.zig");

fn testAgent(arena: std.mem.Allocator, client: *std.http.Client) Agent {
    return .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = client,
        .provider = .{ .id = "test", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "", .context = 0 },
        .messages = std.json.Array.init(arena),
        .sub = true,
        .label = "",
        .out = null,
    };
}

fn resetCancel() void {
    cancel_source.clear();
    acp_engine.cancel_flag.store(false, .release);
}

const Cancel = enum { acp_flag, shared_source };

fn cancelLater(how: Cancel) void {
    std.testing.io.sleep(.fromMilliseconds(150), .awake) catch {};
    switch (how) {
        // session/cancel without a live-turn hook raises only the ACP flag.
        .acp_flag => acp_engine.cancel_flag.store(true, .release),
        // The live-turn hook records the source and raises the shared flag.
        .shared_source => cancel_source.cancel(.acp_client),
    }
}

test "a client cancel interrupts a retry backoff" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var agent = testAgent(arena_state.allocator(), &client);

    for ([_]Cancel{ .acp_flag, .shared_source }) |how| {
        resetCancel();
        defer resetCancel();
        const thread = try std.Thread.spawn(.{}, cancelLater, .{how});
        const t0 = Io.Timestamp.now(std.testing.io, .awake);
        try std.testing.expectError(error.Interrupted, agent.sleepInterruptible(30_000));
        thread.join();
        try std.testing.expect(t0.untilNow(std.testing.io, .awake).toMilliseconds() < 2_000);
    }
}

test "a cancel raised before the backoff skips it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var agent = testAgent(arena_state.allocator(), &client);

    resetCancel();
    defer resetCancel();
    cancel_source.cancel(.acp_client);
    const t0 = Io.Timestamp.now(std.testing.io, .awake);
    try std.testing.expectError(error.Interrupted, agent.sleepInterruptible(30_000));
    try std.testing.expect(t0.untilNow(std.testing.io, .awake).toMilliseconds() < 500);
}

test "an uncancelled backoff still waits its full delay" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var agent = testAgent(arena_state.allocator(), &client);

    resetCancel();
    const t0 = Io.Timestamp.now(std.testing.io, .awake);
    try agent.sleepInterruptible(250);
    try std.testing.expect(t0.untilNow(std.testing.io, .awake).toMilliseconds() >= 250);
}
