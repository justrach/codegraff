//! Interactive /never retire picker (#638).
//!
//! Bare `/never` on a TTY uses the same fuzzy `listPicker` as `/model`:
//! constraint text is the row, the id is secondary, type-to-filter, then
//! two confirmations before a tombstone. ACP, pipes, and tests have no
//! raw stdin, so `playbook_glue` falls back to the text list. The model
//! never reaches this path.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const playbook = @import("playbook.zig");
const pickers = @import("pickers.zig");
const tty = @import("term.zig").tty;

pub const Result = union(enum) {
    /// No TTY / no stdin / empty ledger — caller should print the text list.
    fallback,
    /// Picker ran and the user backed out; ledger unchanged.
    handled,
    /// Two confirms accepted; caller tombstones this live id.
    retire: []const u8,
};

/// Keep-it is index 0 so an accidental Enter leaves the ledger alone.
pub const keep_idx: usize = 0;
pub const retire_idx: usize = 1;

const first_confirm = [_]pickers.PickItem{
    .{ .name = "Keep it", .desc = "Leave this constraint live" },
    .{ .name = "Retire it", .desc = "Ask once more, then stop applying it" },
};

const second_confirm = [_]pickers.PickItem{
    .{ .name = "Keep it", .desc = "Leave this constraint live" },
    .{ .name = "Retire it", .desc = "Stop applying it to root, subagents, workflows, and pipelines" },
};

pub fn wantsRetire(choice: ?usize) bool {
    return choice == retire_idx;
}

/// Both confirmations must pick "Retire it". Cancel / Keep at either stage
/// leaves the ledger untouched.
pub fn confirmed(first: ?usize, second: ?usize) bool {
    return wantsRetire(first) and wantsRetire(second);
}

/// Text prominent, id secondary — matches the #638 row contract and the
/// generic picker's name-outranks-desc scoring.
pub fn pickRows(arena: Allocator, items: []const playbook.Item) ![]pickers.PickItem {
    const rows = try arena.alloc(pickers.PickItem, items.len);
    for (items, rows) |item, *row| {
        row.* = .{
            .name = item.text,
            .desc = try std.fmt.allocPrint(arena, "{s} · {s}", .{ item.id, @tagName(item.source) }),
        };
    }
    return rows;
}

fn cancelled(out: *Io.Writer) !Result {
    try out.print("cancelled — playbook unchanged\n", .{});
    try out.flush();
    return .handled;
}

/// Opens the picker when stdin is a TTY. Returns `.fallback` so a pipe,
/// ACP prompt, or empty ledger still gets the text list.
pub fn interactive(root: *Agent, arena: Allocator, out: *Io.Writer) !Result {
    if (root.in == null) return .fallback;
    const probe = tty.enterRaw(true) orelse return .fallback;
    tty.restore(probe);

    const items = playbook.load(root.io, arena);
    if (items.len == 0) return .fallback;

    const rows = try pickRows(arena, items);
    const pick = pickers.listPicker(root, arena, out, "Constraint ›", rows) orelse return cancelled(out);
    const item = items[pick];

    const t1 = try std.fmt.allocPrint(arena, "Retire › {s}", .{item.text});
    if (!wantsRetire(pickers.listPicker(root, arena, out, t1, &first_confirm))) return cancelled(out);

    const t2 = try std.fmt.allocPrint(arena, "Stop applying to root, subagents, workflows, and pipelines? › {s}", .{item.text});
    if (!confirmed(retire_idx, pickers.listPicker(root, arena, out, t2, &second_confirm))) return cancelled(out);

    return .{ .retire = item.id };
}

test "pickRows: text is the name, id is secondary" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const items = [_]playbook.Item{
        .{ .id = "pb-aaaaaaaa", .text = "never add scroll hints", .source = .user },
        .{ .id = "pb-bbbbbbbb", .text = "prefer codedb outline first", .source = .learned },
    };
    const rows = try pickRows(arena, &items);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("never add scroll hints", rows[0].name);
    try std.testing.expect(std.mem.indexOf(u8, rows[0].desc, "pb-aaaaaaaa") != null);
    try std.testing.expect(std.mem.indexOf(u8, rows[0].desc, "user") != null);
    try std.testing.expectEqualStrings("prefer codedb outline first", rows[1].name);
    try std.testing.expect(std.mem.indexOf(u8, rows[1].desc, "pb-bbbbbbbb") != null);
}

test "double confirm: both Retire it, or the ledger stays" {
    try std.testing.expect(confirmed(retire_idx, retire_idx));
    try std.testing.expect(!confirmed(keep_idx, retire_idx));
    try std.testing.expect(!confirmed(retire_idx, keep_idx));
    try std.testing.expect(!confirmed(null, retire_idx));
    try std.testing.expect(!confirmed(retire_idx, null));
    try std.testing.expect(!wantsRetire(null));
    try std.testing.expect(!wantsRetire(keep_idx));
    try std.testing.expect(wantsRetire(retire_idx));
}

test "interactive /never is skipped without a TTY" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var aw: Io.Writer.Allocating = .init(arena);
    var root: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = &aw.writer,
        .session_name = "",
    };
    try std.testing.expect((try interactive(&root, arena, &aw.writer)) == .fallback);
}
