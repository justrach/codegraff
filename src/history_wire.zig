//! Repair legacy tool payloads on restore and immediately before a request.
const std = @import("std");
const messages = @import("messages.zig");
const Kind = @import("provider.zig").Provider.Kind;

pub fn prepare(a: std.mem.Allocator, kind: Kind, history: *std.json.Array) void {
    messages.sanitizeMessagesUtf8(a, history);
    switch (kind) {
        .openai => messages.normalizeOpenAIHistory(a, history),
        .responses => {
            for (history.items) |*item| {
                if (item.* != .object) continue;
                const typ = item.object.get("type") orelse continue;
                if (typ != .string or !std.mem.eql(u8, typ.string, "function_call_output")) continue;
                repair(a, &item.object, "output", false);
            }
            messages.normalizeResponsesHistory(a, history);
        },
        .anthropic => for (history.items) |*item| {
            if (item.* != .object) continue;
            const content = item.object.getPtr("content") orelse continue;
            if (content.* != .array) continue;
            for (content.array.items) |*block| {
                if (block.* != .object) continue;
                const typ = block.object.get("type") orelse continue;
                if (typ != .string or !std.mem.eql(u8, typ.string, "tool_result")) continue;
                repair(a, &block.object, "content", true);
            }
        },
        .interactions => {},
    }
}

fn repair(a: std.mem.Allocator, obj: *std.json.ObjectMap, field: []const u8, blocks_allowed: bool) void {
    const value = obj.get(field) orelse return;
    if (value == .string) return;
    if (blocks_allowed and value == .array) {
        var blocks = true;
        for (value.array.items) |block| {
            if (block != .object) {
                blocks = false;
                break;
            }
            const typ = block.object.get("type") orelse {
                blocks = false;
                break;
            };
            if (typ != .string) {
                blocks = false;
                break;
            }
        }
        if (blocks) return;
    }
    obj.put(a, field, .{ .string = messages.sanitizeUtf8(a, messages.toolContentString(a, value)) }) catch {};
}

test "legacy tool payloads survive saved-session restore and all request wires" {
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
    for ([_][]const u8{ "anthropic", "openai", "xai" }) |id| {
        var root: Agent = .{
            .gpa = gpa,
            .arena = a,
            .io = io,
            .client = &client,
            .provider = try keys.providerById(id, "fixture-model"),
            .messages = std.json.Array.init(a),
            .sub = false,
            .label = "root",
            .out = null,
            .home = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}),
        };
        const kind = root.provider.kind;
        try std.testing.expect(kind == .anthropic or kind == .openai or kind == .responses);
        const raw = switch (kind) {
            .anthropic => "[{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"one\",\"content\":[61,61,61]},{\"type\":\"tool_result\",\"tool_use_id\":\"two\",\"content\":7}]}]",
            .openai => "[{\"role\":\"tool\",\"tool_call_id\":\"one\",\"content\":[61,61,61]},{\"role\":\"tool\",\"tool_call_id\":\"two\",\"content\":7}]",
            .responses => "[{\"type\":\"function_call_output\",\"call_id\":\"one\",\"output\":[61,61,61]},{\"type\":\"function_call_output\",\"call_id\":\"two\",\"output\":7}]",
            else => unreachable,
        };
        root.messages = (try std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{})).array;
        try root.messages.append(try messages.textMessage(a, "user", "Continue the synthetic session."));
        try session.saveSessionTo(&root, a, tmp.dir, id);
        session.flushSaves();
        root.messages = std.json.Array.init(a);
        try session.loadSession(&root, &keys, a, id);
        const body = try root.buildBody(null, false, false, false);
        defer gpa.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        const items = parsed.value.object.get(if (kind == .responses) "input" else "messages").?.array.items;
        var results: usize = 0;
        for (items) |item| {
            if (kind == .anthropic) {
                const content = item.object.get("content") orelse continue;
                if (content != .array) continue;
                for (content.array.items) |block| {
                    const typ = block.object.get("type") orelse continue;
                    if (!std.mem.eql(u8, typ.string, "tool_result")) continue;
                    const value = block.object.get("content").?;
                    try std.testing.expect(value == .string);
                    try std.testing.expectEqualStrings(if (results == 0) "===" else "7", value.string);
                    results += 1;
                }
            } else {
                const value = item.object.get(if (kind == .responses) "output" else "content") orelse continue;
                if (kind == .openai and !std.mem.eql(u8, item.object.get("role").?.string, "tool")) continue;
                try std.testing.expect(value == .string);
                try std.testing.expectEqualStrings(if (results == 0) "===" else "7", value.string);
                results += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 2), results);
    }
}

test "legacy repair preserves typed image blocks in tool results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "[{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"one\",\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"data\":\"AA==\"}}]}]}]";
    var history = (try std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{})).array;
    prepare(a, .anthropic, &history);
    try std.testing.expect(history.items[0].object.get("content").?.array.items[0].object.get("content").? == .array);
}
