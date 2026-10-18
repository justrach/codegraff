//! Keep client tool calls paired across aborted batches and restored history.
//! Never replay a tool: a missing receipt means its outcome is unknown.
const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const messages = @import("messages.zig");

pub const unknown_outcome = "Tool result unavailable because the batch was interrupted or history was incomplete. Execution outcome is unknown; do not retry side-effecting operations without checking their state.";

fn field(v: Value, key: []const u8) []const u8 {
    if (v != .object) return "";
    const s = v.object.get(key) orelse return "";
    return if (s == .string) s.string else "";
}

fn is(v: Value, key: []const u8, text: []const u8) bool {
    return std.mem.eql(u8, field(v, key), text);
}

fn blocks(v: Value) []const Value {
    if (v != .object) return &.{};
    const content = v.object.get("content") orelse return &.{};
    return if (content == .array) content.array.items else &.{};
}

fn resultFor(v: Value, id: []const u8) bool {
    return is(v, "type", "tool_result") and is(v, "tool_use_id", id);
}

fn withContent(a: Allocator, msg: Value, content: std.json.Array) !Value {
    var obj = try msg.object.clone(a);
    try obj.put(a, "content", .{ .array = content });
    return .{ .object = obj };
}

fn user(a: Allocator, content: std.json.Array) !Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "role", .{ .string = "user" });
    try obj.put(a, "content", .{ .array = content });
    return .{ .object = obj };
}

/// Copy-on-write: allocation failure leaves the original history untouched.
/// Lift delayed receipts ahead of notices, retain their full typed content,
/// and mark only genuinely missing receipts as unknown-outcome errors.
pub fn repair(a: Allocator, history: *std.json.Array) !void {
    var work = history.*;
    var changed = false;
    var i: usize = 0;
    while (i < work.items.len) : (i += 1) {
        const msg = work.items[i];
        if (!is(msg, "role", "assistant")) continue;
        var needs_repair = false;
        var has_calls = false;
        for (blocks(msg)) |call| {
            if (!is(call, "type", "tool_use") or field(call, "id").len == 0) continue;
            has_calls = true;
            var found = false;
            if (i + 1 < work.items.len and is(work.items[i + 1], "role", "user")) {
                for (blocks(work.items[i + 1])) |b| {
                    if (resultFor(b, field(call, "id"))) found = true;
                }
            }
            if (!found) needs_repair = true;
        }
        if (!has_calls or !needs_repair) continue;
        if (!changed) {
            work = .init(a);
            try work.appendSlice(history.items);
            changed = true;
        }
        var results: std.json.Array = .init(a);
        for (blocks(msg)) |call| {
            if (!is(call, "type", "tool_use")) continue;
            const id = field(call, "id");
            if (id.len == 0) continue;
            var receipt: ?Value = null;
            var j = i + 1;
            while (j < work.items.len and receipt == null) : (j += 1) {
                if (!is(work.items[j], "role", "user")) continue;
                const content = blocks(work.items[j]);
                for (content, 0..) |b, k| {
                    if (!resultFor(b, id)) continue;
                    receipt = b;
                    var remaining: std.json.Array = .init(a);
                    try remaining.appendSlice(content[0..k]);
                    try remaining.appendSlice(content[k + 1 ..]);
                    if (remaining.items.len == 0) {
                        _ = work.orderedRemove(j);
                    } else {
                        work.items[j] = try withContent(a, work.items[j], remaining);
                    }
                    break;
                }
            }
            try results.append(receipt orelse try messages.toolResultMessage(a, .anthropic, id, unknown_outcome, true));
        }
        // A separate user wrapper ensures results precede even a string notice.
        // Consecutive user messages are legal and retain notification metadata.
        try work.insert(i + 1, try user(a, results));
    }
    if (changed) history.* = work;
}

fn parse(a: Allocator, raw: []const u8) !std.json.Array {
    return (try std.json.parseFromSliceLeaky(Value, a, raw, .{})).array;
}

const fixture_call = "{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"one\",\"name\":\"shell\",\"input\":{}}]}";
const fixture_receipt = "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"one\",\"content\":\"done\"}]}";
const notice = "{\"role\":\"user\",\"content\":\"synthetic peer wake\"}";

fn expectPair(history: std.json.Array, index: usize, id: []const u8) !Value {
    try std.testing.expect(is(history.items[index + 1], "role", "user"));
    const b = blocks(history.items[index + 1])[0];
    try std.testing.expect(resultFor(b, id));
    return b;
}

test "#1670 tool pairs recover missing receipts before a notice and remain idempotent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var history = try parse(a, "[" ++ fixture_call ++ "," ++ notice ++ "]");
    @import("history_wire.zig").prepare(a, .anthropic, &history);
    const b = try expectPair(history, 0, "one");
    try std.testing.expect(b.object.get("is_error").?.bool);
    try std.testing.expectEqualStrings(unknown_outcome, field(b, "content"));
    try std.testing.expectEqualStrings("synthetic peer wake", field(history.items[2], "content"));
    const before = history.items.ptr;
    try repair(a, &history);
    try std.testing.expectEqual(@as(usize, 3), history.items.len);
    try std.testing.expect(before == history.items.ptr);
}

test "#1670 tool pairs move delayed receipts without losing typed content or notices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var history = try parse(a, "[" ++ fixture_call ++ "," ++ notice ++ ",{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"one\",\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"data\":\"AA==\"}}]},{\"type\":\"text\",\"text\":\"keep me\"}]}]");
    try repair(a, &history);
    const b = try expectPair(history, 0, "one");
    try std.testing.expect(b.object.get("content").? == .array);
    try std.testing.expect(b.object.get("is_error") == null);
    try std.testing.expectEqual(@as(usize, 4), history.items.len);
    try std.testing.expectEqualStrings("keep me", field(blocks(history.items[3])[0], "text"));
}

test "#1670 tool pairs preserve successful batches and fill only missing parallel receipts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var valid = try parse(a, "[" ++ fixture_call ++ "," ++ fixture_receipt ++ "]");
    const original = valid.items.ptr;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try repair(failing.allocator(), &valid); // healthy history needs no allocation
    try std.testing.expect(original == valid.items.ptr);
    var history = try parse(a, "[{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"one\"},{\"type\":\"tool_use\",\"id\":\"two\"}]}," ++ fixture_receipt ++ "]");
    try repair(a, &history);
    try std.testing.expectEqualStrings("done", field(try expectPair(history, 0, "one"), "content"));
    const second = blocks(history.items[1])[1];
    try std.testing.expect(resultFor(second, "two"));
    try std.testing.expect(second.object.get("is_error").?.bool);
}

test "#1670 tool pairs recover trailing calls and ignore server-side tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var history = try parse(a, "[" ++ fixture_call ++ "]");
    try repair(a, &history);
    _ = try expectPair(history, 0, "one");
    var hosted = try parse(a, "[{\"role\":\"assistant\",\"content\":[{\"type\":\"server_tool_use\",\"id\":\"hosted\"}]}]");
    try repair(a, &hosted);
    try std.testing.expectEqual(@as(usize, 1), hosted.items.len);
}

test "#1670 tool pairs close a batch when execution fails before receipts are appended" {
    const Agent = @import("agent.zig").Agent;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer client.deinit();
    var agent: Agent = .{
        .gpa = failing.allocator(),
        .arena = a,
        .io = std.testing.io,
        .client = &client,
        .provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .bearer, .url = "", .api_key = "", .model = "fixture", .context = 100_000 },
        .messages = .init(a),
        .sub = true,
        .label = "fixture",
        .out = null,
    };
    const response = try std.json.parseFromSliceLeaky(Value, a, "{\"content\":[{\"type\":\"tool_use\",\"id\":\"one\",\"name\":\"shell\",\"input\":{}}]}", .{});
    try std.testing.expectError(error.OutOfMemory, @import("agent_steps.zig").stepAnthropic(&agent, response.object));
    const b = try expectPair(agent.messages, 0, "one");
    try std.testing.expect(b.object.get("is_error").?.bool);
}
