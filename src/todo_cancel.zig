//! todo_write's "cancelled" status (#1545, #1520): work the user withdrew or
//! handed to someone else. A cancelled item stays on the list as a record and
//! no longer blocks completion, but it never counts as verified
//! (goal_verify.taskVerified), so cancelling is not a quiet way to finish.
//!
//! Two rules keep it honest:
//! - Every cancelled item carries a short reason (who withdrew the work, or
//!   where it went). A write that cancels without one is rejected whole, so
//!   the reason is always on the record and the UI never shows a cancel that
//!   did not happen.
//! - A verification item is the #844 obligation, so only the user can lift
//!   it: a newer user message, or an ask_user answer, must have arrived since
//!   the item was first written.

const std = @import("std");
const Value = std.json.Value;
const Agent = @import("agent.zig").Agent;
const TodoItem = @import("agent.zig").TodoItem;
const goal_verify_kind = @import("goal_verify_kind.zig");
const util = @import("util.zig");

pub const status = "cancelled";
/// Longest reason kept, in bytes. A reason is a label, not a report.
pub const max_reason: usize = 160;

pub fn isCancel(s: []const u8) bool {
    return std.mem.eql(u8, s, status);
}

pub fn contentOf(item: Value) ?[]const u8 {
    if (item != .object) return null;
    const c = item.object.get("content") orelse return null;
    if (c != .string) return null;
    return c.string;
}

pub fn statusOf(item: Value) []const u8 {
    const st = item.object.get("status") orelse return "pending";
    return if (st == .string) st.string else "pending";
}

/// The item's reason: its first line, trimmed and capped. A re-listed item
/// that was already cancelled keeps its recorded reason when it sends none.
pub fn reasonOf(item: Value, prior: ?TodoItem) []const u8 {
    const raw = if (item.object.get("reason")) |r| (if (r == .string) r.string else "") else "";
    const line = raw[0 .. std.mem.indexOfAny(u8, raw, "\r\n") orelse raw.len];
    const got = util.utf8Prefix(std.mem.trim(u8, line, " \t"), max_reason);
    if (got.len > 0) return got;
    const p = prior orelse return "";
    return if (isCancel(p.status)) p.reason else "";
}

/// The rejection for a write that cancels an item without a reason, or null
/// when every cancelled item has one. `priors` is aligned with the usable
/// items (those with a content string), as applyTodoWrite builds it.
pub fn missingReason(arena: std.mem.Allocator, items: []const Value, priors: []const ?TodoItem) !?[]const u8 {
    var k: usize = 0;
    for (items) |item| {
        const content = contentOf(item) orelse continue;
        const prior = priors[k];
        k += 1;
        if (!isCancel(statusOf(item)) or reasonOf(item, prior).len > 0) continue;
        return try std.fmt.allocPrint(arena, "todo_write rejected; the list is unchanged. The cancelled item \"{s}\" needs a short \"reason\" saying who withdrew the work or where it went (for example \"user withdrew publication\" or \"delegated to the release session\"). Resend the full list with a reason on every cancelled item.", .{content});
    }
    return null;
}

/// Cancelling ordinary work is always allowed (omitting it drops it anyway).
/// A verification item needs a user scope change since it was first written:
/// its request fingerprint must differ from the current one. A brand-new item
/// has nothing to cancel.
pub fn allowed(s: []const u8, content: []const u8, prior: ?TodoItem, ask_now: u64) bool {
    if (!isCancel(s)) return true;
    if (!goal_verify_kind.isVerification(content)) return true;
    const p = prior orelse return false;
    return p.ask_fp != ask_now;
}

/// Fingerprint of the user's latest word on the task: the latest real user
/// request (notices excluded) plus how many ask_user answers have arrived.
/// Compaction keeps the current turn's opening message verbatim, so it is
/// stable within a request and changes when the user sends a new message,
/// steers mid-run, or answers a question (#1520).
pub fn askFingerprint(root: *const Agent) u64 {
    const t = @import("messages.zig").latestUserText(root.messages.items);
    const answers = @import("ask_user_answers.zig").answeredCount();
    return std.hash.Wyhash.hash(0x1545 ^ answers, t) | 1; // never 0: 0 marks a legacy item
}

fn parse(arena: std.mem.Allocator, json: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, json, .{ .allocate = .alloc_always });
}

test "#1520 a cancel reason is one trimmed, capped line; a re-list keeps the recorded one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const given = try parse(ar, "{\"content\":\"publish\",\"status\":\"cancelled\",\"reason\":\"  delegated to the release session \\nmore\"}");
    try std.testing.expectEqualStrings("delegated to the release session", reasonOf(given, null));
    const long_reason: [400]u8 = @splat('a');
    const long = try parse(ar, try std.fmt.allocPrint(ar, "{{\"content\":\"x\",\"status\":\"cancelled\",\"reason\":\"{s}\"}}", .{&long_reason}));
    try std.testing.expectEqual(max_reason, reasonOf(long, null).len);
    const bare = try parse(ar, "{\"content\":\"publish\",\"status\":\"cancelled\"}");
    try std.testing.expectEqualStrings("", reasonOf(bare, null));
    const kept: TodoItem = .{ .content = "publish", .status = "cancelled", .reason = "user withdrew it" };
    try std.testing.expectEqualStrings("user withdrew it", reasonOf(bare, kept));
    const reopened: TodoItem = .{ .content = "publish", .status = "pending", .reason = "stale" };
    try std.testing.expectEqualStrings("", reasonOf(bare, reopened));
}

test "#1520 missingReason names the first cancelled item without a reason" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const list = try parse(ar,
        \\[{"content":"done","status":"completed"},{"status":"pending"},
        \\ {"content":"publish","status":"cancelled","reason":"delegated"},
        \\ {"content":"tag the release","status":"cancelled","reason":"   "}]
    );
    const priors = [_]?TodoItem{ null, null, null };
    const msg = (try missingReason(ar, list.array.items, &priors)).?;
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"tag the release\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "unchanged") != null);
    try std.testing.expect((try missingReason(ar, list.array.items[0..3], priors[0..2])) == null);
}

test "#1520 an ask_user answer changes the request fingerprint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var root: Agent = undefined;
    root.messages = std.json.Array.init(arena_state.allocator());
    const answers = @import("ask_user_answers.zig");
    defer answers.reset();
    const before = askFingerprint(&root);
    try std.testing.expectEqual(before, askFingerprint(&root)); // stable while nothing new arrives
    answers.record(0, "yes, the other session publishes");
    try std.testing.expect(before != askFingerprint(&root));
}
