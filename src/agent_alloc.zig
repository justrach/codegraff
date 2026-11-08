const std = @import("std");
const Agent = @import("agent.zig").Agent;
const main_mod = @import("main.zig");
const util = @import("util.zig");

/// Allocator for per-turn transient scratch (#124): the reset-per-request
/// scratch arena when set (root/subagent), else the session arena.
pub fn scratchAlloc(self: *Agent) std.mem.Allocator {
    return if (self.scratch_arena) |sa| sa.allocator() else self.arena;
}

/// Allocator for live conversation history (`self.messages` and tool outputs).
/// Precedence: temporary transaction arena (`message_mutation_arena`) ->
/// dedicated `gpa`-backed `g_session_arena` on root (#1838) -> `self.arena`.
pub fn messageMutationAlloc(self: *Agent) std.mem.Allocator {
    if (self.message_mutation_arena) |a| return a;
    if (!self.sub) {
        if (main_mod.g_session_arena) |ma| return ma.allocator();
    }
    return self.arena;
}

/// Allocator for history rewrites/handoffs/checkpoints that may also run on
/// partially-initialized test fixtures (`var agent: Agent = undefined` with only
/// `.sub` and `.arena` initialized). Uses `g_session_arena` on the live root
/// agent, else `self.arena`.
pub fn historyAlloc(self: *Agent) std.mem.Allocator {
    if (!self.sub) {
        if (main_mod.g_session_arena) |ma| return ma.allocator();
    }
    return self.arena;
}

/// #1838: Rebuild `g_session_arena` on the root agent by deep-copying only the
/// surviving `self.messages` items into a fresh `gpa`-backed arena and freeing
/// the old slabs back to `gpa` / the OS. Called after compaction, tool-output
/// trimming, session load/restore, and `/clear` or `/new`.
pub fn reclaimMessages(self: *Agent) void {
    if (self.sub) return;
    const ma = main_mod.g_session_arena orelse return;
    if (self.messages.items.len == 0) {
        _ = ma.reset(.free_all);
        self.messages = std.json.Array.init(ma.allocator());
        return;
    }
    var staging = std.heap.ArenaAllocator.init(ma.child_allocator);
    defer staging.deinit();
    const stage_alloc = staging.allocator();
    const staged = stage_alloc.alloc(std.json.Value, self.messages.items.len) catch return;
    for (self.messages.items, 0..) |item, i| {
        staged[i] = util.dupeJsonValue(stage_alloc, item) catch return;
    }
    _ = ma.reset(.free_all);
    const dst = ma.allocator();
    var fresh = std.json.Array.initCapacity(dst, staged.len) catch return;
    for (staged) |item| {
        const duped = util.dupeJsonValue(dst, item) catch return;
        fresh.appendAssumeCapacity(duped);
    }
    self.messages = fresh;
}

test "#1838 reclaimMessages frees dropped message and tool-output slabs from g_session_arena" {
    var base_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer base_arena.deinit();
    var msg_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer msg_arena.deinit();
    const prev_session_arena = main_mod.g_session_arena;
    main_mod.g_session_arena = &msg_arena;
    defer main_mod.g_session_arena = prev_session_arena;

    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = base_arena.allocator(),
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "test", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "test", .context = 100_000 },
        .messages = std.json.Array.init(msg_arena.allocator()),
        .sub = false,
        .label = "test",
        .out = null,
    };

    const alloc = agent.messageMutationAlloc();
    const big_blob = try alloc.alloc(u8, 4 * 1024 * 1024);
    @memset(big_blob, 'x');
    var dropped_obj: std.json.ObjectMap = .empty;
    try dropped_obj.put(alloc, "role", .{ .string = "user" });
    try dropped_obj.put(alloc, "content", .{ .string = big_blob });
    try agent.messages.append(.{ .object = dropped_obj });

    var kept_obj: std.json.ObjectMap = .empty;
    try kept_obj.put(alloc, "role", .{ .string = try alloc.dupe(u8, "assistant") });
    try kept_obj.put(alloc, "content", .{ .string = try alloc.dupe(u8, "short summary") });
    try agent.messages.append(.{ .object = kept_obj });

    const before_cap = msg_arena.queryCapacity();
    try std.testing.expect(before_cap >= 4 * 1024 * 1024);

    // Simulate compaction replacing history with just the kept summary.
    agent.messages.items[0] = agent.messages.items[1];
    agent.messages.shrinkRetainingCapacity(1);
    agent.reclaimMessages();

    const after_cap = msg_arena.queryCapacity();
    try std.testing.expect(after_cap < 64 * 1024);
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);
    try std.testing.expectEqualStrings("short summary", agent.messages.items[0].object.get("content").?.string);
}
