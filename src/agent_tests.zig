//! Larger Agent fixtures kept separate from the state/method definition.

const std = @import("std");
const mcp = @import("mcp.zig");
const tick_gate = @import("tick_gate.zig");

/// #tui-tick: Agent.say's worker branch formats into one slot-sized fixed
/// buffer, so an argument longer than the slot (an uncapped provider error)
/// overflows it — the sink cuts the text and eats the trailing newline. The
/// bytes handed to the gate must still end their row, or the next worker line
/// released after this one starts mid-column: the reported interleave.
pub fn workerLineAlwaysEndsRow(comptime Agent: type) !void {
    const gpa = std.testing.allocator;
    var huge_buf: [tick_gate.slot_bytes + 64]u8 = @splat('x');
    const huge: []const u8 = &huge_buf;

    var agent: Agent = undefined;
    agent.out = null; // a pool-thread child has no writer: the worker branch
    agent.sub = true;
    agent.label = "Review Python hot path";

    tick_gate.hold(); // foreground mid-row, so the gate keeps what say() offers
    defer _ = tick_gate.setLineStart(true); // leave the global gate as we found it
    try agent.say("{s}\n", .{huge});

    var buf: [tick_gate.slot_bytes]u8 = undefined;
    const n = tick_gate.g_gate.take(&buf) orelse return error.WorkerLineNotOffered;
    try std.testing.expect(n > 0 and n <= tick_gate.slot_bytes);
    try std.testing.expect(n < huge.len); // it really was cut
    try std.testing.expectEqual(@as(u8, '\n'), buf[n - 1]);

    // …so a second tick released after it starts its own row.
    const tick2 = "  [w] ⚙ bash {}\n";
    var gate: tick_gate.Gate = .{};
    gate.noteForeground("guard `if (buf.len - ");
    try std.testing.expect(gate.offer(buf[0..n]));
    try std.testing.expect(gate.offer(tick2));
    gate.noteForeground("\n");
    var screen: std.ArrayList(u8) = .empty;
    defer screen.deinit(gpa);
    var slot: [tick_gate.slot_bytes]u8 = undefined;
    while (gate.take(&slot)) |m| try screen.appendSlice(gpa, slot[0..m]);
    const at = std.mem.indexOf(u8, screen.items, tick2).?;
    try std.testing.expect(at > 0 and screen.items[at - 1] == '\n');
}

pub fn lazyRootTools(comptime Agent: type) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var registry = mcp.Registry.empty(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    var connected = [_]mcp.Tool{.{
        .server_index = 0,
        .original_name = "search",
        .qualified_name = "mcp__bench__search",
        .description = "search the benchmark index",
        .input_schema = .{ .object = .empty },
    }};
    registry.tools = &connected;

    var agent: Agent = undefined;
    agent.arena = arena;
    agent.sub = false;
    agent.registry = &registry;
    agent.tools_anthropic = "";
    agent.tools_openai = "";
    agent.tools_responses = "";

    try agent.ensureRootTools(.responses);
    // Deferred tools ship no catalog entry (#476): the qualified name is
    // absent and discovery rides the meta tool's server listing instead.
    try std.testing.expect(std.mem.indexOf(u8, agent.tools_responses, "mcp__bench__search") == null);
    try std.testing.expect(std.mem.indexOf(u8, agent.tools_responses, "bench (search)") != null);
    try std.testing.expectEqual(@as(usize, 0), agent.tools_openai.len);
    try std.testing.expectEqual(@as(usize, 0), agent.tools_anthropic.len);

    agent.invalidateRootTools();
    try agent.ensureRootTools(.anthropic);
    try std.testing.expect(std.mem.indexOf(u8, agent.tools_anthropic, "mcp__bench__search") == null);
    try std.testing.expect(std.mem.indexOf(u8, agent.tools_anthropic, "bench (search)") != null);
    try std.testing.expectEqual(@as(usize, 0), agent.tools_responses.len);
}

/// `-p` sets `out=null` and `stream_quiet` so stdout stays the answer, but
/// the root still takes postLive (head/stream stall) instead of the 5-minute
/// watched POST that burned json-stream / cookie-store to a 300s SIGKILL.
pub fn oneshotUsesLiveTransport(comptime Agent: type) !void {
    var root: Agent = undefined;
    root.sub = false;
    root.out = null;
    root.stream_quiet = true;
    try std.testing.expect(root.usesLiveTransport());

    var child: Agent = undefined;
    child.sub = true;
    child.out = null;
    child.stream_quiet = true;
    try std.testing.expect(!child.usesLiveTransport());
}
