//! Peer speech in the model's history is a working set, not the conversation
//! (ADR 0004 / #563 slice F).
//!
//! The JSONL room in presence_chan.zig is the log. deliverInbound copies a
//! short tail into a user-role note so the model can coordinate *this step*.
//! Those notes are perishable: they are not a human turn, they must not fence
//! compaction or emergency trim, and compact drops every spent one (a later
//! turn already followed it) while keeping a trailing unreplied inject so a
//! compact between drain and reply cannot swallow inbound.
//!
//! Detection is prefix-based because that is how the inject is serialized
//! today. Slice C can replace the fake user role; until then every compact
//! and peek path has to agree on the same prefixes, including the #469-era
//! strings still sitting in resumed transcripts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Io = std.Io;

const presence = @import("presence.zig");

/// First-drain lines that actually ride every later request. The room still
/// keeps the rest; the REPL show-count (2) is a display cap, not this.
pub const history_tail_max: usize = 3;

/// Hard ceiling on one deliverInbound blob, so a long roster plus a few
/// clipped lines cannot become another uncapped tool output.
pub const inject_byte_cap: usize = 800;

/// Per-line clip inside that blob. The tool already asks for one or two
/// sentences; the receiver enforces it.
pub const line_clip: usize = 200;

pub fn isPeerInjectContent(s: []const u8) bool {
    const t = std.mem.trimStart(u8, s, " \t\r\n");
    if (std.mem.startsWith(u8, t, "[peer message")) return true;
    if (std.mem.startsWith(u8, t, "[presence]")) return true;
    if (std.mem.startsWith(u8, t, "[#469 presence]")) return true;
    if (std.mem.startsWith(u8, t, "[#469 channel")) return true;
    if (std.mem.startsWith(u8, t, "[#469 device room")) return true;
    if (std.mem.startsWith(u8, t, "[peer channel")) return true;
    return false;
}

pub fn isPeerInject(m: Value) bool {
    if (m != .object) return false;
    const role = m.object.get("role") orelse return false;
    if (role != .string or !std.mem.eql(u8, role.string, "user")) return false;
    const content = m.object.get("content") orelse return false;
    switch (content) {
        .string => |s| return isPeerInjectContent(s),
        .array => |arr| {
            for (arr.items) |blk| {
                if (blk != .object) continue;
                const t = blk.object.get("type") orelse continue;
                if (!(t == .string and std.mem.eql(u8, t.string, "text"))) continue;
                if (blk.object.get("text")) |v| {
                    if (v == .string and isPeerInjectContent(v.string)) return true;
                }
            }
            return false;
        },
        else => return false,
    }
}

pub fn clip(text: []const u8, max: usize) []const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    return if (t.len <= max) t else t[0..max];
}

pub fn capInject(text: []const u8) []const u8 {
    if (text.len <= inject_byte_cap) return text;
    const tail = text[text.len - inject_byte_cap ..];
    if (std.mem.indexOfScalar(u8, tail, '\n')) |nl| return tail[nl + 1 ..];
    return tail;
}

/// First-drain history window: same shape as the REPL display window, but
/// capped at `history_tail_max` so the model does not eat the whole room.
pub const TailWindow = struct { start: usize, hidden: usize };

pub fn historyWindow(is_backlog: bool, count: usize) TailWindow {
    if (!is_backlog or count <= history_tail_max) return .{ .start = 0, .hidden = 0 };
    return .{ .start = count - history_tail_max, .hidden = count - history_tail_max };
}

/// Copy `kept` into `dest`, dropping peer injects a later turn already
/// followed. If `kept` is empty (the whole history was summarized) and the
/// original tail is still an unreplied inject, keep that one — compact must
/// not eat inbound the model has not seen.
pub fn appendWorkingSet(dest: *std.json.Array, kept: []const Value, original: []const Value) !void {
    for (kept, 0..) |m, i| {
        if (isPeerInject(m) and i + 1 < kept.len) continue;
        try dest.append(m);
    }
    if (kept.len == 0 and original.len > 0) {
        const last = original[original.len - 1];
        if (isPeerInject(last)) try dest.append(last);
    }
}

/// One durable-state line naming who is live *now*. Speech stays in the
/// JSONL room; quoting it here would just survive compact as another leak.
pub fn durableRosterLine(arena: Allocator, io: Io) !?[]const u8 {
    const peers = presence.liveAllPeers(io, arena);
    if (peers.len == 0) return null;
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "- live co-resident sessions (working set; speech is in the worktree channel, not this summary): ");
    for (peers, 0..) |p, i| {
        if (i > 0) try buf.appendSlice(arena, "; ");
        const goal = if (p.goal.len > 0) clip(p.goal, 40) else "?";
        const piece = try std.fmt.allocPrint(arena, "{s} ({s})", .{ p.session_id, goal });
        try buf.appendSlice(arena, piece);
        if (buf.items.len > 240) {
            try buf.appendSlice(arena, "; …");
            break;
        }
    }
    return buf.items;
}

const testing = std.testing;

fn userText(arena: Allocator, s: []const u8) !Value {
    const raw = try std.fmt.allocPrint(arena, "{{\"role\":\"user\",\"content\":\"{s}\"}}", .{s});
    return std.json.parseFromSliceLeaky(Value, arena, raw, .{});
}

fn asstText(arena: Allocator, s: []const u8) !Value {
    const raw = try std.fmt.allocPrint(arena, "{{\"role\":\"assistant\",\"content\":\"{s}\"}}", .{s});
    return std.json.parseFromSliceLeaky(Value, arena, raw, .{});
}

test "isPeerInjectContent: live prefixes and the #469-era strings in old transcripts" {
    try testing.expect(isPeerInjectContent("[peer message from s-2]: hold off"));
    try testing.expect(isPeerInjectContent("  [presence] 1 other live graff session(s)"));
    try testing.expect(isPeerInjectContent("[#469 presence] 1 other live graff session(s)"));
    try testing.expect(isPeerInjectContent("[#469 channel: 8 older message(s) predating this session omitted]"));
    try testing.expect(isPeerInjectContent("[peer channel: 8 older message(s) predating this session omitted]"));
    try testing.expect(isPeerInjectContent("[#469 device room: 2 message(s) not addressed to this session skipped]"));
    try testing.expect(!isPeerInjectContent("refactor the digest job"));
    try testing.expect(!isPeerInjectContent(""));
}

test "isPeerInject: user-role string or text block; assistant and tool_result are not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expect(isPeerInject(try userText(a, "[peer message from a]: hold gui/src")));
    try testing.expect(!isPeerInject(try userText(a, "please finish the retry ladder")));
    try testing.expect(!isPeerInject(try asstText(a, "[peer message from a]: hold gui/src")));
    const block = try std.json.parseFromSliceLeaky(Value, a, "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"[presence] 1 other live session\"}]}", .{});
    try testing.expect(isPeerInject(block));
    const tr = try std.json.parseFromSliceLeaky(Value, a, "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"ok\"}]}", .{});
    try testing.expect(!isPeerInject(tr));
}

test "historyWindow: live drains are uncapped; a first-drain backlog keeps only the tail" {
    try testing.expectEqualDeep(TailWindow{ .start = 0, .hidden = 0 }, historyWindow(false, 25));
    try testing.expectEqualDeep(TailWindow{ .start = 0, .hidden = 0 }, historyWindow(true, history_tail_max));
    try testing.expectEqualDeep(TailWindow{ .start = 7, .hidden = 7 }, historyWindow(true, 10));
}

test "appendWorkingSet: drops spent injects, keeps a trailing unreplied one, salvages when the suffix is empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const peer = try userText(a, "[peer message from a]: locking src/foo.zig");
    const human = try userText(a, "keep going");
    const asst = try asstText(a, "on it");
    const later = try userText(a, "[peer message from b]: your turn");

    var kept = std.json.Array.init(a);
    try kept.append(human);
    try kept.append(asst);
    try kept.append(peer);
    try kept.append(asst);
    try kept.append(later);
    var dest = std.json.Array.init(a);
    try appendWorkingSet(&dest, kept.items, kept.items);
    try testing.expectEqual(@as(usize, 4), dest.items.len); // spent `peer` dropped; trailing `later` kept
    try testing.expectEqualStrings("keep going", dest.items[0].object.get("content").?.string);
    try testing.expect(isPeerInject(dest.items[3]));

    dest = std.json.Array.init(a);
    var original = std.json.Array.init(a);
    try original.append(human);
    try original.append(later);
    try appendWorkingSet(&dest, &.{}, original.items);
    try testing.expectEqual(@as(usize, 1), dest.items.len);
    try testing.expect(isPeerInject(dest.items[0]));

    dest = std.json.Array.init(a);
    original = std.json.Array.init(a);
    try original.append(later);
    try original.append(human);
    try appendWorkingSet(&dest, &.{}, original.items);
    try testing.expectEqual(@as(usize, 0), dest.items.len); // last was the human; nothing to salvage
}

test "durableRosterLine: nothing live means no line (honesty rule)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqual(@as(?[]const u8, null), try durableRosterLine(a, testing.io));
}

test "capInject: the working-set blob cannot outgrow inject_byte_cap; overflow keeps the tail" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const pad = try a.alloc(u8, 2000);
    @memset(pad, 'x');
    const long = try std.fmt.allocPrint(a, "[peer message from a]: {s}\n[peer message from b]: newest\n", .{pad});
    const out = capInject(long);
    try testing.expect(out.len <= inject_byte_cap);
    try testing.expect(std.mem.indexOf(u8, out, "newest") != null);
}
