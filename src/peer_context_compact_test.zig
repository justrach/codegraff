//! Compact/trim boundaries for peer injects (ADR 0004). Lives beside
//! agent_compact_test.zig so that file stays under the 600-line ceiling.

const std = @import("std");
const util = @import("util.zig");
const Value = std.json.Value;
const textMessage = @import("messages.zig").textMessage;
const compact = @import("agent_compact.zig");

test "cleanUserTurn: a peer inject is not a human user turn" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect(!compact.cleanUserTurn(try textMessage(a, "user", "[peer] 1 unread from a — peer_message action=inbox")));
    try std.testing.expect(!compact.cleanUserTurn(try textMessage(a, "user", "[peer message from a]: hold gui/src")));
    try std.testing.expect(!compact.cleanUserTurn(try textMessage(a, "user", "[presence] 1 other live graff session(s)")));
    try std.testing.expect(!compact.cleanUserTurn(try textMessage(a, "user", "[#469 presence] leftover from a resumed transcript")));
    try std.testing.expect(compact.cleanUserTurn(try textMessage(a, "user", "keep going")));
}

test "emergencyCutIndex: a peer inject at the midpoint is not a conversation start" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var items = std.json.Array.init(a);
    try items.append(try textMessage(a, "user", "old")); // 0
    try items.append(try textMessage(a, "assistant", "x")); // 1
    try items.append(try textMessage(a, "user", "still old")); // 2
    try items.append(try textMessage(a, "assistant", "x")); // 3
    try items.append(try textMessage(a, "user", "[peer message from a]: hold gui/src")); // 4 midpoint — skip
    try items.append(try textMessage(a, "assistant", "x")); // 5
    try items.append(try textMessage(a, "user", "keep going")); // 6
    try items.append(try textMessage(a, "assistant", "x")); // 7
    try std.testing.expectEqual(@as(?usize, 6), compact.emergencyCutIndex(items.items));
}

test "recentContextStart: a peer inject is not a keep-verbatim boundary" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    try msgs.append(try textMessage(a, "user", "old request"));
    try msgs.append(try textMessage(a, "assistant", &util.repeatBytes("x", 36_000)));
    try msgs.append(try textMessage(a, "user", "[peer message from a]: hold gui/src"));
    try msgs.append(try textMessage(a, "assistant", "noted"));
    try msgs.append(try textMessage(a, "user", "recent request"));
    try msgs.append(try textMessage(a, "assistant", "recent answer"));
    const start = compact.recentContextStart(msgs.items, 8_000);
    try std.testing.expectEqual(@as(usize, 4), start);
    try std.testing.expectEqualStrings("recent request", msgs.items[start].object.get("content").?.string);
    try std.testing.expect(!compact.cleanUserTurn(msgs.items[2]));
}

test "dropPriorTurnReasoning: a peer inject is not the last-user fence" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Agent = @import("agent.zig").Agent;
    var agent: Agent = undefined;
    agent.arena = a;
    agent.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 270_000 };
    var items = std.json.Array.init(a);
    try items.append(try textMessage(a, "user", "old prompt"));
    var old_r: std.json.ObjectMap = .empty;
    try old_r.put(a, "type", .{ .string = "reasoning" });
    try old_r.put(a, "encrypted", .{ .string = "old" });
    try items.append(.{ .object = old_r });
    try items.append(try textMessage(a, "assistant", "old"));
    try items.append(try textMessage(a, "user", "new prompt"));
    var new_r: std.json.ObjectMap = .empty;
    try new_r.put(a, "type", .{ .string = "reasoning" });
    try new_r.put(a, "encrypted", .{ .string = "new" });
    try items.append(.{ .object = new_r });
    try items.append(try textMessage(a, "assistant", "new"));
    try items.append(try textMessage(a, "user", "[peer message from a]: hold"));
    agent.messages = items;
    // Last real user is "new prompt". Only the older reasoning drops. If the
    // peer inject were the fence, both blobs would go — the API still needs
    // the current turn's reasoning between a function_call and its output.
    const dropped = compact.dropPriorTurnReasoning(&agent);
    try std.testing.expectEqual(@as(usize, 1), dropped);
    try std.testing.expectEqual(@as(usize, 6), agent.messages.items.len);
}
