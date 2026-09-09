
test "non-image @[path] stays literal text" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var root: agent_mod.Agent = .{
        .gpa = testing.allocator,
        .arena = a,
        .io = testing.io,
        .client = undefined,
        .provider = .{ .id = "xai", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "grok-4", .context = 100_000 },
        .messages = std.json.Array.init(a),
        .sub = false,
        .label = "test",
        .out = null,
    };
    const txt = try userMessage(a, &root, "read @[build.zig] please");
    try testing.expect(txt.object.get("content").? == .string);
    try testing.expectEqualStrings("read @[build.zig] please", txt.object.get("content").?.string);
}
