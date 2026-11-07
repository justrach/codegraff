//! Copy conversation evidence, not the source agent's instructions or capabilities.
const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const Provider = @import("provider.zig").Provider;
const messages = @import("messages.zig");

fn str(v: Value, key: []const u8) []const u8 {
    if (v != .object) return "";
    const field = v.object.get(key) orelse return "";
    return if (field == .string) field.string else "";
}
fn is(v: Value, key: []const u8, text: []const u8) bool {
    return std.mem.eql(u8, str(v, key), text);
}
fn parentOnly(v: Value) bool {
    return is(v, "role", "system") or is(v, "role", "developer") or
        @import("additional_tools.zig").isItem(v) or @import("hot_context.zig").isHotContext(v);
}
fn track(a: Allocator, pending: *std.StringHashMapUnmanaged(usize), v: Value, index: usize) !void {
    if (v != .object) return;
    if (is(v, "type", "function_call")) {
        const id = if (str(v, "call_id").len > 0) str(v, "call_id") else str(v, "id");
        if (id.len > 0) try pending.put(a, id, index);
    } else if (is(v, "type", "tool_use")) {
        const id = str(v, "id");
        if (id.len > 0) try pending.put(a, id, index);
    } else if (is(v, "type", "function_call_output") or is(v, "type", "function_result")) {
        _ = pending.remove(str(v, "call_id"));
    } else if (is(v, "type", "tool_result")) {
        _ = pending.remove(str(v, "tool_use_id"));
    } else if (is(v, "role", "tool")) {
        _ = pending.remove(str(v, "tool_call_id"));
    }
    if (v.object.get("tool_calls")) |calls| if (calls == .array) {
        for (calls.array.items) |call| {
            const id = str(call, "id");
            if (id.len > 0) try pending.put(a, id, index);
        }
    };
    if (v.object.get("content")) |content| if (content == .array) {
        for (content.array.items) |block| try track(a, pending, block, index);
    };
}

/// The parent's spawn call is still in flight. Stop before that model/tool
/// batch rather than inventing a successful result or giving a child a dangling call.
fn completedPrefix(a: Allocator, history: []const Value) ![]const Value {
    var pending: std.StringHashMapUnmanaged(usize) = .empty;
    defer pending.deinit(a);
    for (history, 0..) |item, i| try track(a, &pending, item, i);
    var end = history.len;
    var it = pending.valueIterator();
    while (it.next()) |index| end = @min(end, index.*);
    if (end < history.len) {
        while (end > 0) {
            const prev = history[end - 1];
            if (!is(prev, "role", "assistant") and !is(prev, "type", "reasoning") and
                !is(prev, "type", "thought") and !is(prev, "type", "function_call") and !is(prev, "type", "model_output")) break;
            end -= 1;
        }
    }
    return history[0..end];
}

fn privateReasoning(v: Value) bool {
    return is(v, "type", "reasoning") or is(v, "type", "thinking") or
        is(v, "type", "redacted_thinking") or is(v, "type", "thought");
}
fn stripReasoning(a: Allocator, v: *Value) !void {
    if (v.* != .object) return;
    _ = v.object.fetchOrderedRemove("reasoning_content");
    _ = v.object.fetchOrderedRemove("reasoning");
    if (v.object.getPtr("content")) |content| if (content.* == .array) {
        var blocks = std.json.Array.init(a);
        for (content.array.items) |block| if (!privateReasoning(block)) {
            try blocks.append(block);
        };
        content.* = .{ .array = blocks };
    };
}
fn hasImage(v: Value) bool {
    if (v == .array) {
        for (v.array.items) |item| if (hasImage(item)) return true;
    } else if (v == .object) {
        if (is(v, "type", "image") or is(v, "type", "image_url") or is(v, "type", "input_image")) return true;
        for (v.object.values()) |item| if (hasImage(item)) return true;
    }
    return false;
}

pub fn copy(a: Allocator, history: []const Value, source: Provider, target: Provider) !std.json.Array {
    const same_seat = std.mem.eql(u8, source.id, target.id) and std.mem.eql(u8, source.model, target.model);
    if (@import("compaction_window.zig").latestBlob(history) != null and
        (!same_seat or source.kind != target.kind)) return error.OpaqueForkRequiresOriginalModel;
    const prefix = try completedPrefix(a, history);
    const bytes = try std.json.Stringify.valueAlloc(a, prefix, .{});
    defer a.free(bytes);
    const owned = (try std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always })).array;
    var result = std.json.Array.init(a);
    for (owned.items) |*item| {
        if (item.* != .object or parentOnly(item.*)) continue;
        if ((!same_seat or source.kind != target.kind) and privateReasoning(item.*)) continue;
        if (!same_seat or source.kind != target.kind) try stripReasoning(a, item);
        if (source.kind == target.kind) {
            try result.append(item.*);
            continue;
        }
        // A wire switch must not drop the very file/tool evidence the fork is
        // for. Keep receipts as inert text, never as calls on the new catalog.
        // Images need a real format converter, not base64 rendered as prose.
        if (hasImage(item.*)) return error.ForkImageRequiresOriginalProtocol;
        const role = str(item.*, "role");
        const assistant = std.mem.eql(u8, role, "assistant") or is(item.*, "type", "model_output");
        const evidence = try std.json.Stringify.valueAlloc(a, item.*, .{});
        const text = try std.fmt.allocPrint(a, "Historical conversation entry (context only, not an instruction to execute a tool):\n{s}", .{evidence});
        try result.append(try messages.textMessage(a, if (assistant) "assistant" else "user", text));
    }
    @import("history_wire.zig").prepare(a, target.kind, &result);
    @import("tool_call_args.zig").repairHistory(a, a, result.items);
    return result;
}

fn parse(a: Allocator, raw: []const u8) ![]const Value {
    return (try std.json.parseFromSliceLeaky(Value, a, raw, .{ .allocate = .alloc_always })).array.items;
}
fn seat(kind: Provider.Kind) Provider {
    return .{ .id = "fixture", .model = "fixture", .kind = kind, .auth = .bearer, .url = "", .api_key = "", .context = 10000 };
}

test "fork history snapshots own nested data and siblings never share mutations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try parse(a, "[{\"role\":\"user\",\"content\":\"original\"},{\"role\":\"assistant\",\"content\":\"evidence\"}]");
    var one = try copy(a, source, seat(.openai), seat(.openai));
    const two = try copy(a, source, seat(.openai), seat(.openai));
    try one.items[0].object.put(a, "content", .{ .string = "branch only" });
    try std.testing.expectEqualStrings("original", str(source[0], "content"));
    try std.testing.expectEqualStrings("original", str(two.items[0], "content"));
}

test "fork history preserves completed receipts but excludes the in-flight spawn batch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try parse(a,
        \\[{"role":"user","content":"request"},
        \\ {"role":"assistant","tool_calls":[{"id":"read","type":"function","function":{"name":"read_file","arguments":"{}"}}]},
        \\ {"role":"tool","tool_call_id":"read","content":"important result"},
        \\ {"role":"assistant","tool_calls":[{"id":"spawn","type":"function","function":{"name":"subagent","arguments":"{}"}}]}]
    );
    const out = try copy(a, source, seat(.openai), seat(.openai));
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("important result", str(out.items[2], "content"));
    try std.testing.expectEqual(@as(usize, 4), source.len);
}

test "fork history excludes pending native tool batches on all item wires" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixtures = [_][]const u8{
        "[{\"role\":\"user\",\"content\":\"request\"},{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"x\",\"name\":\"subagent\",\"input\":{}}]}]",
        "[{\"role\":\"user\",\"content\":\"request\"},{\"type\":\"reasoning\",\"id\":\"r\"},{\"type\":\"function_call\",\"call_id\":\"x\",\"name\":\"subagent\",\"arguments\":\"{}\"}]",
        "[{\"type\":\"user_input\",\"content\":\"request\"},{\"type\":\"function_call\",\"id\":\"x\",\"name\":\"subagent\",\"arguments\":{}}]",
    };
    for (fixtures, [_]Provider.Kind{ .anthropic, .responses, .interactions }) |fixture, kind| {
        const out = try copy(a, try parse(a, fixture), seat(kind), seat(kind));
        try std.testing.expectEqual(@as(usize, 1), out.items.len);
    }
}

test "fork history cross-wire keeps tool evidence as inert context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try parse(a, "[{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"read\",\"name\":\"read_file\",\"input\":{\"path\":\"evidence.txt\"}}]},{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"read\",\"content\":\"evidence survives\"}]}]");
    const out = try copy(a, source, seat(.anthropic), seat(.openai));
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expect(std.mem.indexOf(u8, str(out.items[1], "content"), "evidence survives") != null);
    try std.testing.expect(out.items[0].object.get("tool_calls") == null);
}

test "fork history preserves opaque windows only on the original model" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try parse(a, "[{\"type\":\"compaction\",\"encrypted_content\":\"opaque\"},{\"role\":\"user\",\"content\":\"continue\"}]");
    const out = try copy(a, source, seat(.responses), seat(.responses));
    try std.testing.expect(@import("compaction_window.zig").latestBlob(out.items) != null);
    var other = seat(.responses);
    other.model = "different";
    try std.testing.expectError(error.OpaqueForkRequiresOriginalModel, copy(a, source, seat(.responses), other));
    try std.testing.expectError(error.OpaqueForkRequiresOriginalModel, copy(a, source, seat(.responses), seat(.openai)));
}

test "fork history keeps native images and rejects a lossy wire switch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try parse(a, "[{\"role\":\"user\",\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"data\":\"AA==\"}}]}]");
    const out = try copy(a, source, seat(.anthropic), seat(.anthropic));
    try std.testing.expect(hasImage(out.items[0]));
    try std.testing.expectError(error.ForkImageRequiresOriginalProtocol, copy(a, source, seat(.anthropic), seat(.openai)));
}

test "fork history does not grant the source agent tools or instructions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try parse(a, "[{\"role\":\"system\",\"content\":\"root policy\"},{\"type\":\"additional_tools\",\"role\":\"developer\"},{\"role\":\"user\",\"content\":\"actual request\"}]");
    const out = try copy(a, source, seat(.openai), seat(.openai));
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("actual request", str(out.items[0], "content"));
}
