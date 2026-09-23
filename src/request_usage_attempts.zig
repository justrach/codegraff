//! Request-local uncertainty ledger. Failed attempts are not successful API calls.
const std = @import("std");
const pricing = @import("pricing.zig");
pub const Ledger = struct {
    unresolved: u64 = 0,
    pub fn begin(self: *Ledger) void {
        self.unresolved +|= 1;
    }
    pub fn completed(self: *Ledger) void {
        self.unresolved -|= 1;
    }
    pub fn finish(self: *Ledger, io: std.Io, tally: *pricing.CostTally) void {
        if (self.unresolved != 0) tally.failedWithoutUsage(io, self.unresolved);
        self.unresolved = 0;
    }
};

test "usage ledger excludes validation and successful calls from failed attempts" {
    var tally: pricing.CostTally = .{};
    var ledger: Ledger = .{};
    ledger.finish(std.testing.io, &tally); // validation failed before transport
    try std.testing.expectEqual(@as(u64, 0), tally.unreported_failed_attempts);
    ledger.begin(); // failed attempt
    ledger.begin(); // successful retry with usage
    var response: std.json.ObjectMap = .empty;
    defer response.deinit(std.testing.allocator);
    var usage: std.json.ObjectMap = .empty;
    defer usage.deinit(std.testing.allocator);
    try usage.put(std.testing.allocator, "input_tokens", .{ .integer = 10 });
    try usage.put(std.testing.allocator, "output_tokens", .{ .integer = 2 });
    try response.put(std.testing.allocator, "usage", .{ .object = usage });
    ledger.completed();
    _ = noteResponsesUsage(std.testing.io, &tally, response);
    tally.add(std.testing.io, .sub, "fixture", 10, 0, 0, 2);
    ledger.finish(std.testing.io, &tally);
    ledger.finish(std.testing.io, &tally); // no duplicate accounting on cleanup
    try std.testing.expectEqual(@as(u64, 1), tally.api_calls);
    try std.testing.expectEqual(@as(u64, 1), tally.unreported_failed_attempts);
    try std.testing.expectEqual(@as(u64, 10), tally.in_tokens);
    const event = @import("turn_event.zig").fromTally(&tally, std.testing.io, "done", 100, true);
    try std.testing.expect(!event.usage_complete);
    try std.testing.expect(event.metadata_complete and event.complete);
    try std.testing.expectEqual(@as(u64, 1), event.unreported_failed_attempts);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try tally.render(&out.writer);
    try std.testing.expect(std.mem.startsWith(u8, out.written(), "known subtotal: "));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "1 failed request attempt(s) without usage") != null);
}

test "usage ledger records completed Responses absent and malformed usage as unknown" {
    var tally: pricing.CostTally = .{};
    var ledger: Ledger = .{};
    var response: std.json.ObjectMap = .empty;
    defer response.deinit(std.testing.allocator);
    ledger.begin();
    ledger.completed();
    _ = noteResponsesUsage(std.testing.io, &tally, response);
    try response.put(std.testing.allocator, "usage", .null);
    ledger.begin();
    ledger.completed();
    _ = noteResponsesUsage(std.testing.io, &tally, response);
    ledger.finish(std.testing.io, &tally);
    try std.testing.expectEqual(@as(u64, 2), tally.api_calls);
    try std.testing.expectEqual(@as(u64, 2), tally.missing_usage_calls);
    try std.testing.expectEqual(@as(u64, 0), tally.unreported_failed_attempts);
    try std.testing.expectEqual(@as(u64, 0), tally.in_tokens);
    try std.testing.expectEqual(@as(f64, 0), tally.usd); // subtotal only, never fabricated usage
}

fn nonnegative(obj: std.json.ObjectMap, name: []const u8, required: bool) bool {
    const value = obj.get(name) orelse return !required;
    return value == .integer and value.integer >= 0;
}

/// Missing or malformed token components cannot establish a complete cost receipt.
pub fn noteResponsesUsage(io: std.Io, tally: *pricing.CostTally, response: std.json.ObjectMap) bool {
    const valid = blk: {
        const value = response.get("usage") orelse break :blk false;
        if (value != .object) break :blk false;
        const u = value.object;
        if (!nonnegative(u, "input_tokens", true) or !nonnegative(u, "output_tokens", true) or !nonnegative(u, "total_tokens", false)) break :blk false;
        if (u.get("input_tokens_details")) |details| {
            if (details != .object or !nonnegative(details.object, "cached_tokens", false) or !nonnegative(details.object, "cache_write_tokens", false)) break :blk false;
            const cached = if (details.object.get("cached_tokens")) |n| n.integer else 0;
            const written = if (details.object.get("cache_write_tokens")) |n| n.integer else 0;
            if (cached +| written > u.get("input_tokens").?.integer) break :blk false;
        }
        break :blk true;
    };
    if (!valid) tally.missingUsage(io);
    return valid;
}

test "Responses usage rejects partial malformed negative and impossible cached components" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tally: pricing.CostTally = .{};
    for ([_][]const u8{
        "{\"usage\":{}}",
        "{\"usage\":{\"input_tokens\":10}}",
        "{\"usage\":{\"input_tokens\":\"10\",\"output_tokens\":2}}",
        "{\"usage\":{\"input_tokens\":10,\"output_tokens\":-1}}",
        "{\"usage\":{\"input_tokens\":10,\"output_tokens\":2,\"input_tokens_details\":{\"cached_tokens\":11}}}",
    }) |raw| {
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), raw, .{});
        try std.testing.expect(!noteResponsesUsage(std.testing.io, &tally, parsed.object));
    }
    try std.testing.expectEqual(@as(u64, 5), tally.missing_usage_calls);
    try std.testing.expectEqual(@as(u64, 0), tally.in_tokens);
}
