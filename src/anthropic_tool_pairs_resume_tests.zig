//! Saved-session and outgoing-wire regression for missing tool receipts.
const std = @import("std");

test "#1670 tool pairs restored session serializes complete receipts" {
    const session = @import("session.zig");
    const writer = @import("session_writer.zig");
    const transcript = @import("session_transcript.zig");
    const Agent = @import("agent.zig").Agent;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    writer.resetForTest();
    defer writer.resetForTest();
    transcript.resetForTest();
    defer transcript.resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var keys: @import("provider.zig").Keys = .{ .values = @splat("test-key") };
    var agent: Agent = .{
        .gpa = gpa,
        .arena = a,
        .io = io,
        .client = &client,
        .provider = try keys.providerById("anthropic", "fixture-model"),
        .messages = .init(a),
        .sub = false,
        .label = "fixture",
        .out = null,
        .home = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}),
    };
    const raw = "[{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"one\",\"name\":\"shell\",\"input\":{}}]},{\"role\":\"user\",\"content\":\"synthetic notice\"}]";
    agent.messages = (try std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{})).array;
    try session.saveSessionTo(&agent, a, tmp.dir, "orphan");
    session.flushSaves();
    agent.messages = .init(a);
    try session.loadSession(&agent, &keys, a, "orphan");
    const body = try agent.buildBody(null, false, false, false);
    defer gpa.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    const msgs = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), msgs.len);
    const result = msgs[1].object.get("content").?.array.items[0];
    try std.testing.expectEqualStrings("tool_result", result.object.get("type").?.string);
    try std.testing.expectEqualStrings("one", result.object.get("tool_use_id").?.string);
    try std.testing.expect(result.object.get("is_error").?.bool);
    try std.testing.expectEqualStrings(@import("anthropic_tool_pairs.zig").unknown_outcome, result.object.get("content").?.string);
}
