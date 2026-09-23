//! Async direct tools are a narrow Responses capability, not a wire-format default.
const std = @import("std");
const Provider = @import("provider.zig").Provider;
pub var configured: bool = true;

pub fn configure(value: ?[]const u8) void {
    configured = if (value) |v| !std.mem.eql(u8, v, "0") else true;
}

pub fn enabled(provider: Provider) bool {
    return configured and provider.kind == .responses and
        (std.mem.eql(u8, provider.id, "openai") or std.mem.eql(u8, provider.id, "codex")) and
        (std.mem.eql(u8, provider.model, "gpt-6-astra") or std.mem.eql(u8, provider.model, "gpt-6-sol"));
}

pub fn eligible(name: []const u8) bool {
    return std.mem.eql(u8, name, "webfetch");
}

/// Only call with executor_ready after the streaming executor has been armed.
/// Worker and side-question paths must leave executor_ready false.
pub fn decorate(alloc: std.mem.Allocator, provider: Provider, payload: []const u8, executor_ready: bool) ![]const u8 {
    if (!executor_ready or !enabled(provider)) return payload;
    const value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, payload, .{ .allocate = .alloc_always });
    if (value != .array) return payload;
    var changed = false;
    for (value.array.items) |*tool| {
        if (tool.* != .object) continue;
        const kind = tool.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "function")) continue;
        const name = tool.object.get("name") orelse continue;
        if (name != .string or !eligible(name.string)) continue;
        // PTC-enabled definitions are not direct-only tools.
        if (tool.object.contains("allowed_callers")) continue;
        try tool.object.put(alloc, "async", .{ .bool = true });
        changed = true;
    }
    if (!changed) return payload;
    var out: std.Io.Writer.Allocating = .init(alloc);
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try json.write(value);
    return out.toOwnedSlice();
}

fn fixture() Provider {
    return .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-6-astra", .context = 1 };
}

test "async tool policy exact route model and off switch" {
    const saved = configured;
    defer configured = saved;
    configure(null);
    var p = fixture();
    for ([_][]const u8{ "codex", "openai" }) |id| {
        p.id = id;
        for ([_][]const u8{ "gpt-6-astra", "gpt-6-sol" }) |model| {
            p.model = model;
            try std.testing.expect(enabled(p));
        }
    }
    for ([_][]const u8{ "gpt-5.6-terra", "gpt-6-unknown", "gpt-6-sol-future", "grok-4.7" }) |model| {
        p.model = model;
        try std.testing.expect(!enabled(p));
    }
    p = fixture();
    p.kind = .openai;
    try std.testing.expect(!enabled(p));
    p = fixture();
    p.id = "codegraff";
    try std.testing.expect(!enabled(p));
    p = fixture();
    configure("0");
    try std.testing.expect(!enabled(p));
}

test "async tool policy decorates only armed direct webfetch" {
    const saved = configured;
    defer configured = saved;
    configure(null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const payload = "[{\"type\":\"function\",\"name\":\"webfetch\"},{\"type\":\"function\",\"name\":\"edit_file\"},{\"type\":\"function\",\"name\":\"rlm\"},{\"type\":\"web_search\"},{\"type\":\"custom\",\"name\":\"webfetch\"},{\"type\":\"function\",\"name\":\"webfetch\",\"allowed_callers\":[\"code_execution\"]}]";
    try std.testing.expectEqualStrings(payload, try decorate(alloc, fixture(), payload, false));
    const result = try decorate(alloc, fixture(), payload, true);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, result, .{});
    try std.testing.expect(parsed.array.items[0].object.get("async").?.bool);
    for (parsed.array.items[1..]) |tool| try std.testing.expect(!tool.object.contains("async"));
    configure("0");
    try std.testing.expectEqualStrings(payload, try decorate(alloc, fixture(), payload, true));
}
