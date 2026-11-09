//! Phase-1 deterministic tool-result spilling/pruning before LLM compaction.
//!
//! Runs only once `autoCompact` / `compactOrRecover` has already decided that
//! context exceeds `compactAt()`, so ordinary turns never touch historical
//! tool outputs or perturb prefix caches. Inspects only messages strictly
//! before the last `keep_recent_messages`, replacing oversized inline tool
//! outputs (`>= min_inline_bytes`, not already spilled) in-place with a
//! deterministic structural digest (shape hint + 512B UTF-8 head + 256B UTF-8
//! tail + byte-count footer).

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const Agent = @import("agent.zig").Agent;
const tool_handle = @import("tool_handle.zig");
const util = @import("util.zig");
const output_elide = @import("output_elide.zig");

pub const default_keep_recent_messages: usize = 6;
pub const default_min_inline_bytes: usize = 4096;
pub const head_preview_bytes: usize = 512;
pub const tail_preview_bytes: usize = 256;

/// True when `body` is already a spilled handle or compaction-pruned digest.
pub fn isAlreadySpilled(body: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, body, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "[tool output spilled")) return true;
    if (std.mem.startsWith(u8, trimmed, "[spilled")) return true;
    if (std.mem.startsWith(u8, trimmed, "[tool result handle:")) return true;
    if (std.mem.startsWith(u8, trimmed, "[compaction-pruned:")) return true;
    if (std.mem.indexOf(u8, body, ".graff/tool-results/") != null) return true;
    if (std.mem.indexOf(u8, body, "[compaction-pruned:") != null) return true;
    return false;
}

/// Build the compact deterministic digest for an oversized tool output.
/// Returns `null` if `body` is below `min_inline_bytes`, already spilled, or
/// if the digest would not shrink `body`.
pub fn formatPrunedDigest(arena: Allocator, body: []const u8, min_inline_bytes: usize) ?[]const u8 {
    if (body.len < min_inline_bytes) return null;
    if (isAlreadySpilled(body)) return null;
    const hint = tool_handle.shapeHint(arena, arena, body);
    const head = util.utf8Prefix(body, head_preview_bytes);
    const tail = output_elide.utf8Suffix(body, tail_preview_bytes);
    const digest = if (hint.len > 0)
        std.fmt.allocPrint(
            arena,
            "[{s}]\n{s}\n...\n{s}\n[compaction-pruned: {d} bytes -> preview; re-read if exact middle bytes needed]",
            .{ hint, head, tail, body.len },
        ) catch return null
    else
        std.fmt.allocPrint(
            arena,
            "{s}\n...\n{s}\n[compaction-pruned: {d} bytes -> preview; re-read if exact middle bytes needed]",
            .{ head, tail, body.len },
        ) catch return null;
    if (digest.len >= body.len) return null;
    return digest;
}

fn pruneBodyInPlace(arena: Allocator, slot: *Value, min_inline_bytes: usize) usize {
    if (slot.* != .string) return 0;
    const orig = slot.string;
    const digest = formatPrunedDigest(arena, orig, min_inline_bytes) orelse return 0;
    const saved = orig.len - digest.len;
    slot.* = .{ .string = digest };
    return saved;
}

fn pruneMessage(arena: Allocator, msg: *Value, min_inline_bytes: usize) usize {
    if (msg.* != .object) return 0;
    var reclaimed: usize = 0;

    // Responses wire: {"type": "function_call_output", "output": "..."}
    if (msg.object.get("type")) |t| {
        if (t == .string and std.mem.eql(u8, t.string, "function_call_output")) {
            if (msg.object.getPtr("output")) |out_ptr| {
                reclaimed += pruneBodyInPlace(arena, out_ptr, min_inline_bytes);
            }
            return reclaimed;
        }
    }

    const role_val = msg.object.get("role") orelse return 0;
    if (role_val != .string) return 0;

    // OpenAI chat wire: {"role": "tool", "content": "..."}
    if (std.mem.eql(u8, role_val.string, "tool")) {
        if (msg.object.getPtr("content")) |content_ptr| {
            reclaimed += pruneBodyInPlace(arena, content_ptr, min_inline_bytes);
        }
        return reclaimed;
    }

    // Anthropic wire: {"role": "user", "content": [{"type": "tool_result", "content": "..."}]}
    if (std.mem.eql(u8, role_val.string, "user")) {
        const content_ptr = msg.object.getPtr("content") orelse return 0;
        if (content_ptr.* != .array) return 0;
        for (content_ptr.array.items) |*block| {
            if (block.* != .object) continue;
            const btype = block.object.get("type") orelse continue;
            if (btype != .string or !std.mem.eql(u8, btype.string, "tool_result")) continue;
            const bcontent = block.object.getPtr("content") orelse continue;
            if (bcontent.* == .string) {
                reclaimed += pruneBodyInPlace(arena, bcontent, min_inline_bytes);
            } else if (bcontent.* == .array) {
                for (bcontent.array.items) |*sub| {
                    if (sub.* != .object) continue;
                    const stype = sub.object.get("type") orelse continue;
                    if (stype != .string or !std.mem.eql(u8, stype.string, "text")) continue;
                    if (sub.object.getPtr("text")) |tptr| {
                        reclaimed += pruneBodyInPlace(arena, tptr, min_inline_bytes);
                    }
                }
            }
        }
    }

    return reclaimed;
}

/// Deterministically prune oversized inline tool results strictly before the
/// last `keep_recent_messages`. Returns the total number of bytes reclaimed
/// and updates the agent's token estimate when bytes are reclaimed.
pub fn pruneOldToolResults(agent: *Agent, keep_recent_messages: usize, min_inline_bytes: usize) usize {
    const items = agent.messages.items;
    if (items.len <= keep_recent_messages) return 0;
    const cutoff = items.len - keep_recent_messages;
    const threshold = if (min_inline_bytes == 0) default_min_inline_bytes else min_inline_bytes;
    const before_local = agent.fullInputEstimateTokens();

    var reclaimed: usize = 0;
    for (items[0..cutoff]) |*msg| {
        reclaimed += pruneMessage(agent.arena, msg, threshold);
    }
    if (reclaimed > 0) {
        const after_local = agent.fullInputEstimateTokens();
        @import("agent_compact.zig").accountForReclaimedTokens(agent, before_local -| after_local);
        if (main_mod.g_session_arena != null) agent.reclaimMessages();
    }
    return reclaimed;
}

fn testAgentFixture(arena: Allocator) Agent {
    return .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "test", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "test", .context = 100_000 },
        .messages = .init(arena),
        .sub = false,
        .label = "test",
        .out = null,
    };
}

test "compact_prune: recent messages within keep_recent_messages are never touched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent = testAgentFixture(arena);
    const big = try arena.alloc(u8, 6000);
    @memset(big, 'A');
    for (0..6) |i| {
        const id = try std.fmt.allocPrint(arena, "c{d}", .{i});
        try agent.messages.append(try @import("messages.zig").toolResultMessage(arena, .openai, id, big, false));
    }
    const before_tokens = agent.approxTokens();
    const reclaimed = pruneOldToolResults(&agent, 6, 4096);
    try std.testing.expectEqual(@as(usize, 0), reclaimed);
    try std.testing.expectEqual(before_tokens, agent.approxTokens());
    for (agent.messages.items) |m| {
        try std.testing.expectEqual(@as(usize, 6000), m.object.get("content").?.string.len);
    }
}

test "compact_prune: already-spilled handles and small (< 4096 B) tool results are untouched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent = testAgentFixture(arena);
    const small = try arena.alloc(u8, 2048);
    @memset(small, 's');
    const spilled_pad = try arena.alloc(u8, 4500);
    @memset(spilled_pad, 'p');
    const spilled_prefix = try std.fmt.allocPrint(arena, "[tool output spilled to .graff/tool-results/run/out-1.txt]\n{s}", .{spilled_pad});
    const spilled_short = try std.fmt.allocPrint(arena, "[spilled 12000 bytes]\n{s}", .{spilled_pad});
    try agent.messages.append(try @import("messages.zig").toolResultMessage(arena, .openai, "c1", small, false));
    try agent.messages.append(try @import("messages.zig").toolResultMessage(arena, .openai, "c2", spilled_prefix, false));
    try agent.messages.append(try @import("messages.zig").toolResultMessage(arena, .openai, "c3", spilled_short, false));
    for (0..6) |_| try agent.messages.append(try @import("messages.zig").textMessage(arena, "user", "recent turn"));
    const reclaimed = pruneOldToolResults(&agent, 6, 4096);
    try std.testing.expectEqual(@as(usize, 0), reclaimed);
    try std.testing.expectEqualStrings(small, agent.messages.items[0].object.get("content").?.string);
    try std.testing.expectEqualStrings(spilled_prefix, agent.messages.items[1].object.get("content").?.string);
    try std.testing.expectEqualStrings(spilled_short, agent.messages.items[2].object.get("content").?.string);
}

test "compact_prune: oversized older tool results (>= 4096 B) are compacted with head, tail, and shape hint, reducing approxTokens()" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent = testAgentFixture(arena);
    var json_buf: std.ArrayList(u8) = .empty;
    try json_buf.appendSlice(arena, "{\"status\":\"ok\",\"alpha\":1,\"beta\":\"HEAD_MARKER_");
    try json_buf.appendNTimes(arena, 'x', 5000);
    try json_buf.appendSlice(arena, "_TAIL_MARKER\"}");
    const big_json = json_buf.items;
    try std.testing.expect(big_json.len >= 4096);
    try agent.messages.append(try @import("messages.zig").toolResultMessage(arena, .openai, "old_openai", big_json, false));
    var anth_blocks = std.json.Array.init(arena);
    try anth_blocks.append(try @import("messages.zig").toolResultMessage(arena, .anthropic, "old_anth", big_json, false));
    var anth_user: std.json.ObjectMap = .empty;
    try anth_user.put(arena, "role", .{ .string = "user" });
    try anth_user.put(arena, "content", .{ .array = anth_blocks });
    try agent.messages.append(.{ .object = anth_user });
    for (0..6) |_| try agent.messages.append(try @import("messages.zig").textMessage(arena, "user", "recent"));
    const before_tokens = agent.approxTokens();
    const reclaimed = pruneOldToolResults(&agent, 6, 4096);
    try std.testing.expect(reclaimed > 8000);
    try std.testing.expect(agent.approxTokens() < before_tokens);
    const pruned_openai = agent.messages.items[0].object.get("content").?.string;
    try std.testing.expect(std.mem.indexOf(u8, pruned_openai, "JSON object, top-level keys: status, alpha, beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, pruned_openai, "HEAD_MARKER_") != null);
    try std.testing.expect(std.mem.indexOf(u8, pruned_openai, "_TAIL_MARKER\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, pruned_openai, "[compaction-pruned: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, pruned_openai, " bytes -> preview; re-read if exact middle bytes needed]") != null);
    const pruned_anth = agent.messages.items[1].object.get("content").?.array.items[0].object.get("content").?.string;
    try std.testing.expectEqualStrings(pruned_openai, pruned_anth);
    try std.testing.expectEqual(@as(usize, 0), pruneOldToolResults(&agent, 6, 4096));
}
