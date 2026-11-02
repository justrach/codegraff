//! Human-facing live sessions: explicit groups, recent turn activity, readable fields.
const std = @import("std");
const Owner = @import("worktree_lease.zig").Owner;

fn lessThan(_: void, a: Owner, b: Owner) bool {
    const a_time = @max(0, a.last_activity_ms);
    const b_time = @max(0, b.last_activity_ms);
    if (a_time != b_time) return a_time > b_time;
    const id_order = std.mem.order(u8, a.session_id, b.session_id);
    if (id_order != .eq) return id_order == .lt;
    const tree_order = std.mem.order(u8, a.identity, b.identity);
    if (tree_order != .eq) return tree_order == .lt;
    if (a.pid != b.pid) return a.pid < b.pid;
    return a.start_id < b.start_id;
}

fn age(out: *std.Io.Writer, timestamp: i64, now: i64) !void {
    if (timestamp <= 0) return out.writeAll("unknown");
    const elapsed = @max(0, now -| timestamp);
    if (elapsed < std.time.ms_per_min)
        try out.writeAll("just now")
    else if (elapsed < std.time.ms_per_hour)
        try out.print("{d}m ago", .{@divTrunc(elapsed, std.time.ms_per_min)})
    else if (elapsed < std.time.ms_per_day)
        try out.print("{d}h ago", .{@divTrunc(elapsed, std.time.ms_per_hour)})
    else
        try out.print("{d}d ago", .{@divTrunc(elapsed, std.time.ms_per_day)});
}

// Preserve each field on one visual row even when a title or goal contains newlines.
fn field(out: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| try out.writeByte(if (c < 0x20 or c == 0x7f) ' ' else c);
}

pub fn write(arena: std.mem.Allocator, out: *std.Io.Writer, peers: []const Owner, mine: []const u8, now: i64) !void {
    const sorted = try arena.dupe(Owner, peers);
    defer arena.free(sorted);
    @import("stable_sort.zig").sort(Owner, sorted, {}, lessThan);
    for ([_]bool{ true, false }) |local_group| {
        var heading = false;
        for (sorted) |p| {
            const local = std.mem.eql(u8, p.identity, mine);
            if (local != local_group) continue;
            if (!heading) {
                try out.writeAll(if (local) "  live now in this worktree:\n" else "  live elsewhere on this device:\n");
                heading = true;
            }
            const shown = if (p.title.len > 0) p.title else if (p.session_id.len > 0) p.session_id else "untitled session";
            try out.writeAll("  ⚡ ");
            try field(out, shown);
            try out.writeAll("\n    status: ");
            try field(out, p.activity);
            try out.writeAll(" · last active: ");
            try age(out, p.last_activity_ms, now);
            try out.print(" · pid {d}\n", .{p.pid});
            if (p.session_id.len > 0 and !std.mem.eql(u8, shown, p.session_id)) {
                try out.writeAll("    session: ");
                try field(out, p.session_id);
                try out.writeAll("\n");
            }
            if (p.session_base.len > 0 and !std.mem.eql(u8, p.session_base, shown) and !std.mem.eql(u8, p.session_base, p.session_id)) {
                try out.writeAll("    saved as: ");
                try field(out, p.session_base);
                try out.writeAll("\n");
            }
            if (!local) {
                try out.writeAll("    worktree: ");
                try field(out, p.identity);
                try out.writeAll("\n");
            }
            try out.writeAll("    goal: ");
            try field(out, if (p.goal.len > 0) p.goal else "?");
            try out.writeAll("\n\n");
        }
    }
}

test "live sessions group before sorting activity and never use registry freshness" {
    const peers = [_]Owner{
        .{ .session_id = "remote-new", .identity = "elsewhere", .last_activity_ms = 3000 },
        .{ .session_id = "local-old", .identity = "here", .last_activity_ms = 1000, .last_seen_ms = 999999 },
        .{ .session_id = "remote-old", .identity = "elsewhere", .last_activity_ms = 1000 },
        .{ .session_id = "local-new", .identity = "here", .last_activity_ms = 2000 },
        .{ .session_id = "local-unknown", .identity = "here", .last_seen_ms = 9999999 },
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(std.testing.allocator, &out.writer, &peers, "here", 62000);
    const text = out.writer.buffered();
    var previous: usize = 0;
    for ([_][]const u8{ "live now in this worktree:", "⚡ local-new", "⚡ local-old", "⚡ local-unknown", "live elsewhere on this device:", "⚡ remote-new", "⚡ remote-old" }) |needle| {
        const index = std.mem.indexOf(u8, text, needle) orelse return error.MissingRow;
        try std.testing.expect(index >= previous);
        previous = index;
    }
    try std.testing.expect(std.mem.indexOf(u8, text, "last active: unknown") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "last active: 1m ago") != null);
}

test "live sessions stable ties and unknown times ignore directory order" {
    const a: Owner = .{ .session_id = "a", .identity = "here" };
    const b: Owner = .{ .session_id = "b", .identity = "here" };
    var first: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer first.deinit();
    var second: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer second.deinit();
    try write(std.testing.allocator, &first.writer, &.{ b, a }, "here", 100000);
    try write(std.testing.allocator, &second.writer, &.{ a, b }, "here", 100000);
    try std.testing.expectEqualStrings(first.writer.buffered(), second.writer.buffered());
}

test "live sessions indented fields separate rows without repeated fallback ids" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(std.testing.allocator, &out.writer, &.{
        .{ .session_id = "session-id", .session_base = "session-id", .identity = "here", .pid = 7 },
        .{ .session_id = "other-id", .title = "A title\nsecond line", .session_base = "a-slug", .identity = "elsewhere", .goal = "a goal\nnext", .pid = 8, .last_activity_ms = 200000 },
    }, "here", 100000);
    const text = out.writer.buffered();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "session-id"));
    try std.testing.expect(std.mem.indexOf(u8, text, "    goal: ?\n\n  live elsewhere") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "⚡ A title second line\n    status:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "    session: other-id\n    saved as: a-slug\n    worktree: elsewhere\n    goal: a goal next\n\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "last active: just now") != null);
}

test "live sessions empty registry emits no headings" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(std.testing.allocator, &out.writer, &.{}, "here", 0);
    try std.testing.expectEqual(@as(usize, 0), out.writer.buffered().len);
}
