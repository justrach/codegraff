//! Compaction cut: which suffix stays verbatim (#581).
//!
//! `recentContextStart` keeps a recent clean-user suffix inside an 8k token
//! budget. Mid-turn that walk can fill the budget on the tool tail and never
//! reach the opening user message — so an unresolved image prompt was
//! summarized into text. Pin that opening turn while the current prompt is
//! still unresolved, except a child's index-0 mandate (restated via pinChildTask).

const std = @import("std");
const Value = std.json.Value;

const context_tokens = @import("context_tokens.zig");
const peer_context = @import("peer_context.zig");
const trace = @import("trace.zig");

/// Last clean user turn — the opening prompt of the current (or just-finished)
/// turn. Tool-result-only user messages are not clean (see `cleanUserTurn`).
pub fn turnOpeningUserIndex(items: []const Value) ?usize {
    var i = items.len;
    while (i > 0) {
        i -= 1;
        if (cleanUserTurn(items[i])) return i;
    }
    return null;
}

/// True when history ends on a completed model reply (assistant / Responses
/// `message`). Tool outputs, function_call, reasoning, or a trailing user
/// prompt mean the opening turn is still live.
pub fn lastIsResolved(items: []const Value) bool {
    if (items.len == 0) return false;
    const m = items[items.len - 1];
    if (m != .object) return false;
    if (m.object.get("type")) |t| if (t == .string) {
        if (std.mem.eql(u8, t.string, "message")) return true;
        if (std.mem.eql(u8, t.string, "function_call")) return false;
        if (std.mem.eql(u8, t.string, "function_call_output")) return false;
        if (std.mem.eql(u8, t.string, "reasoning")) return false;
    };
    const role = m.object.get("role") orelse return false;
    return role == .string and std.mem.eql(u8, role.string, "assistant");
}

pub fn countImageBlocks(m: Value) u32 {
    if (m != .object) return 0;
    const content = m.object.get("content") orelse return 0;
    if (content != .array) return 0;
    var n: u32 = 0;
    for (content.array.items) |blk| {
        if (blk != .object) continue;
        const t = blk.object.get("type") orelse continue;
        if (t != .string) continue;
        if (std.mem.eql(u8, t.string, "image") or
            std.mem.eql(u8, t.string, "image_url") or
            std.mem.eql(u8, t.string, "input_image")) n += 1;
    }
    return n;
}

pub fn countImagesFrom(items: []const Value) u32 {
    var n: u32 = 0;
    for (items) |m| n += countImageBlocks(m);
    return n;
}

pub fn messageHasImage(m: Value) bool {
    return countImageBlocks(m) > 0;
}

/// Keep the opening user of an unresolved turn when it is not a child's
/// index-0 mandate (those are restated by pinChildTask) or when it carries
/// image blocks (a first-turn paste must not be summarized to text).
fn mustKeepOpening(items: []const Value, t: usize) bool {
    return t > 0 or messageHasImage(items[t]);
}

pub fn pinOpening(items: []const Value) ?usize {
    if (lastIsResolved(items)) return null;
    const t = turnOpeningUserIndex(items) orelse return null;
    return if (mustKeepOpening(items, t)) t else null;
}

pub fn suffixTokens(items: []const Value, start: usize) u64 {
    var total: u64 = 0;
    for (items[start..]) |m| total +|= context_tokens.estimatedTokens(m);
    return total;
}

/// True when an unresolved pin is in force and that suffix alone is already
/// over the recent-context keep budget. Compacting the completed prefix
/// cannot get the live prompt under the line.
pub fn pinOverBudget(items: []const Value, token_budget: u64) bool {
    const t = pinOpening(items) orelse return false;
    return suffixTokens(items, t) > token_budget;
}

pub const DegradeAction = enum { proceed, announce, silent };

pub const CutPlan = struct {
    start: usize,
    pin_over_budget: bool,
    action: DegradeAction,
};

/// #581 residual: budget-check the pinned suffix. Keep the pin (never drop
/// live images). If the suffix alone is over budget, compact the completed
/// prefix once, then degrade — do not spend a summarization every cycle.
/// `already` is the per-turn latch (`Agent.compact_pin_degraded`).
pub fn pinDegrade(items: []const Value, token_budget: u64, already: bool) CutPlan {
    const start = recentContextStart(items, token_budget);
    const over = pinOverBudget(items, token_budget);
    const cannot_help = start == 0 or (over and already);
    if (!cannot_help) return .{ .start = start, .pin_over_budget = over, .action = .proceed };
    return .{
        .start = start,
        .pin_over_budget = over,
        .action = if (already) .silent else .announce,
    };
}

/// Pick the earliest clean user-turn boundary whose suffix fits in the recent
/// context budget. Returning items.len means "summarize everything". We never
/// split at a tool output, so retained call/result history stays valid.
///
/// #581: while the current prompt is unresolved, never put its opening user
/// message (or its image blocks) in the summarized prefix.
pub fn recentContextStart(items: []const Value, token_budget: u64) usize {
    if (items.len == 0 or token_budget == 0) return items.len;
    var total: u64 = 0;
    var start = items.len;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        total +|= context_tokens.estimatedTokens(items[i]);
        if (total > token_budget) break;
        if (cleanUserTurn(items[i])) start = i;
    }
    // If the entire conversation fits, summarizing all is the only operation
    // that can actually reduce context; otherwise compaction would be a no-op.
    if (start == 0) start = items.len;
    if (pinOpening(items)) |t| {
        if (start > t) start = t;
    }
    return start;
}

/// Index to cut history at for an emergency trim: the first clean user turn
/// at or after the midpoint, so messages[cut..] is always a valid
/// conversation start (never an orphaned tool_result). null when there is no
/// safe cut — too short, only tool_result user messages remain, or the only
/// candidate would drop an unresolved image prompt (#581).
pub fn emergencyCutIndex(items: []const Value) ?usize {
    if (items.len < 4) return null;
    const pin = pinOpening(items);
    var i: usize = items.len / 2;
    while (i < items.len) : (i += 1) {
        if (pin) |t| if (i > t) break;
        if (cleanUserTurn(items[i])) return i;
    }
    return null;
}

/// Counts only: boundary index + preserved current-suffix image blocks. Never
/// the pixels (#581).
pub fn noteCut(tracer: ?*trace.Tracer, items: []const Value, start: usize) void {
    const t = tracer orelse return;
    t.write(.{
        .ev = "compact_cut",
        .boundary = start,
        .preserved_images = countImagesFrom(items[start..]),
        .unresolved = !lastIsResolved(items),
    });
}

pub fn cleanUserTurn(m: Value) bool {
    if (m != .object) return false;
    const role = m.object.get("role") orelse return false;
    if (role != .string or !std.mem.eql(u8, role.string, "user")) return false;
    const content = m.object.get("content") orelse return true;
    switch (content) {
        .string => |s| return !peer_context.isPeerInjectContent(s),
        .array => |arr| {
            // An anthropic user message that only carries tool_result blocks
            // is the response half of a tool call — it can't begin a
            // conversation, so it is not a safe trim boundary.
            for (arr.items) |blk| {
                if (blk != .object) continue;
                const t = blk.object.get("type") orelse continue;
                if (t == .string and std.mem.eql(u8, t.string, "tool_result")) return false;
            }
            return true;
        },
        else => return true,
    }
}

fn imageUser(arena: std.mem.Allocator, kind: []const u8, payload: []const u8) !Value {
    var image: std.json.ObjectMap = .empty;
    try image.put(arena, "type", .{ .string = kind });
    if (std.mem.eql(u8, kind, "image_url")) {
        var image_url: std.json.ObjectMap = .empty;
        try image_url.put(arena, "url", .{ .string = payload });
        try image.put(arena, "image_url", .{ .object = image_url });
    } else {
        try image.put(arena, "image_url", .{ .string = payload });
    }
    var content = std.json.Array.init(arena);
    var tb: std.json.ObjectMap = .empty;
    try tb.put(arena, "type", .{ .string = "text" });
    try tb.put(arena, "text", .{ .string = "read these screenshots" });
    try content.append(.{ .object = tb });
    try content.append(.{ .object = image });
    var user: std.json.ObjectMap = .empty;
    try user.put(arena, "role", .{ .string = "user" });
    try user.put(arena, "content", .{ .array = content });
    return .{ .object = user };
}

fn toolTail(arena: std.mem.Allocator, msgs: *std.json.Array, n: usize) !void {
    const util = @import("util.zig");
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var fco: std.json.ObjectMap = .empty;
        try fco.put(arena, "type", .{ .string = "function_call_output" });
        try fco.put(arena, "call_id", .{ .string = "c" });
        try fco.put(arena, "output", .{ .string = &util.repeatBytes("y", 8_000) });
        try msgs.append(.{ .object = fco });
    }
}

test "unresolved image prompt is pinned even when the tool tail fills the budget" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const textMessage = @import("messages.zig").textMessage;
    const util = @import("util.zig");

    var msgs = std.json.Array.init(arena);
    try msgs.append(try textMessage(arena, "user", "old request"));
    try msgs.append(try textMessage(arena, "assistant", &util.repeatBytes("x", 20_000)));
    try msgs.append(try imageUser(arena, "image_url", "data:image/png;base64,AAA"));
    try toolTail(arena, &msgs, 6);

    const start = recentContextStart(msgs.items, 8_000);
    try std.testing.expectEqual(@as(usize, 2), start);
    try std.testing.expect(cleanUserTurn(msgs.items[start]));
    try std.testing.expectEqual(@as(u32, 1), countImagesFrom(msgs.items[start..]));
}

test "just-submitted image prompt is not summarized away" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const textMessage = @import("messages.zig").textMessage;
    const util = @import("util.zig");

    var msgs = std.json.Array.init(arena);
    try msgs.append(try textMessage(arena, "user", &util.repeatBytes("z", 40_000)));
    try msgs.append(try textMessage(arena, "assistant", "old answer"));
    try msgs.append(try imageUser(arena, "input_image", "data:image/png;base64,BBB"));

    const start = recentContextStart(msgs.items, 8_000);
    try std.testing.expectEqual(@as(usize, 2), start);
}

test "HungRequest retry does not move the cut across the live image prompt" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const textMessage = @import("messages.zig").textMessage;
    const util = @import("util.zig");

    var msgs = std.json.Array.init(arena);
    try msgs.append(try textMessage(arena, "user", "old request"));
    try msgs.append(try textMessage(arena, "assistant", &util.repeatBytes("x", 20_000)));
    try msgs.append(try imageUser(arena, "image_url", "data:image/png;base64,AAA"));
    try toolTail(arena, &msgs, 6);

    const first = recentContextStart(msgs.items, 8_000);
    const again = recentContextStart(msgs.items, 8_000);
    try std.testing.expectEqual(first, again);
    try std.testing.expectEqual(@as(usize, 2), again);
}

test "emergencyCutIndex refuses to drop an unresolved image prompt" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const textMessage = @import("messages.zig").textMessage;
    const util = @import("util.zig");

    var msgs = std.json.Array.init(arena);
    try msgs.append(try textMessage(arena, "user", "old request"));
    try msgs.append(try textMessage(arena, "assistant", &util.repeatBytes("x", 20_000)));
    try msgs.append(try imageUser(arena, "image_url", "data:image/png;base64,AAA"));
    try toolTail(arena, &msgs, 6);

    try std.testing.expectEqual(@as(?usize, null), emergencyCutIndex(msgs.items));
}

test "first-turn unresolved images refuse a summarize-all cut" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var msgs = std.json.Array.init(arena);
    try msgs.append(try imageUser(arena, "image_url", "data:image/png;base64,AAA"));
    try toolTail(arena, &msgs, 6);

    try std.testing.expectEqual(@as(usize, 0), recentContextStart(msgs.items, 8_000));
}

fn fatImageUser(arena: std.mem.Allocator, n: usize) !Value {
    var content = std.json.Array.init(arena);
    var tb: std.json.ObjectMap = .empty;
    try tb.put(arena, "type", .{ .string = "text" });
    try tb.put(arena, "text", .{ .string = "read these screenshots" });
    try content.append(.{ .object = tb });
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var image: std.json.ObjectMap = .empty;
        try image.put(arena, "type", .{ .string = "image_url" });
        var image_url: std.json.ObjectMap = .empty;
        try image_url.put(arena, "url", .{ .string = "data:image/png;base64,AAA" });
        try image.put(arena, "image_url", .{ .object = image_url });
        try content.append(.{ .object = image });
    }
    var user: std.json.ObjectMap = .empty;
    try user.put(arena, "role", .{ .string = "user" });
    try user.put(arena, "content", .{ .array = content });
    return .{ .object = user };
}

test "pinned suffix over the keep budget is reported and still pinned" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const textMessage = @import("messages.zig").textMessage;

    var msgs = std.json.Array.init(arena);
    try msgs.append(try textMessage(arena, "user", "old request"));
    try msgs.append(try textMessage(arena, "assistant", "old answer"));
    try msgs.append(try fatImageUser(arena, 3)); // 3 * 4096 image tokens > 8k

    try std.testing.expect(pinOverBudget(msgs.items, 8_000));
    try std.testing.expectEqual(@as(usize, 2), recentContextStart(msgs.items, 8_000));
    try std.testing.expectEqual(@as(u32, 3), countImagesFrom(msgs.items[2..]));
}

test "pinDegrade: over-budget pin announces once, then stays silent" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var msgs = std.json.Array.init(arena);
    try msgs.append(try fatImageUser(arena, 3));
    try toolTail(arena, &msgs, 2);

    const first = pinDegrade(msgs.items, 8_000, false);
    try std.testing.expectEqual(@as(usize, 0), first.start);
    try std.testing.expect(first.pin_over_budget);
    try std.testing.expectEqual(DegradeAction.announce, first.action);

    const again = pinDegrade(msgs.items, 8_000, true);
    try std.testing.expectEqual(@as(usize, 0), again.start);
    try std.testing.expectEqual(DegradeAction.silent, again.action);
}

test "pinDegrade: prefix still compactable once; already-degraded skips the spend" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const textMessage = @import("messages.zig").textMessage;
    const util = @import("util.zig");

    var msgs = std.json.Array.init(arena);
    try msgs.append(try textMessage(arena, "user", "old request"));
    try msgs.append(try textMessage(arena, "assistant", &util.repeatBytes("x", 20_000)));
    try msgs.append(try fatImageUser(arena, 3));

    const first = pinDegrade(msgs.items, 8_000, false);
    try std.testing.expectEqual(@as(usize, 2), first.start);
    try std.testing.expect(first.pin_over_budget);
    try std.testing.expectEqual(DegradeAction.proceed, first.action);

    const again = pinDegrade(msgs.items, 8_000, true);
    try std.testing.expectEqual(@as(usize, 2), again.start);
    try std.testing.expectEqual(DegradeAction.silent, again.action);
}
