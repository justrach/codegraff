//! Standing WORK block: the user's mental model of the task, not the
//! harness's todo_write dump. Printed when the checklist changes and again
//! as chrome above `›` (ADR 0021). Raw `[x]/[~]/[ ]` lines stay in the
//! tool result the model sees; they are not conversational.

const std = @import("std");
const Io = std.Io;

const engine_events = @import("engine_events.zig");
const util = @import("util.zig");

pub const Item = struct {
    content: []const u8,
    done: bool = false,
    active: bool = false,
};

const title_clip: usize = 40;
const item_clip: usize = 48;
const max_items: usize = 8;

fn clip(s: []const u8, n: usize) []const u8 {
    return util.utf8Prefix(std.mem.trim(u8, s, " \t\r"), n);
}

/// `WORKING  {title}  done/total` plus a `├`/`└` checklist. Empty input is
/// a no-op so a sink can call this on every prompt without a gate.
pub fn write(w: *Io.Writer, title: []const u8, items: []const Item) void {
    if (items.len == 0 and title.len == 0) return;
    const shown = if (title.len > 0) clip(title, title_clip) else "work";
    var done: usize = 0;
    for (items) |it| {
        if (it.done) done += 1;
    }
    w.print("WORKING  {s}", .{shown}) catch return;
    if (items.len > 0) w.print("  {d}/{d}", .{ done, items.len }) catch return;
    w.writeByte('\n') catch return;
    const n = @min(items.len, max_items);
    for (items[0..n], 0..) |it, i| {
        const branch: []const u8 = if (i + 1 == n) "└ " else "├ ";
        const mark: []const u8 = if (it.done) "✓" else if (it.active) "◌" else "○";
        w.print("{s}{s} {s}\n", .{ branch, mark, clip(it.content, item_clip) }) catch return;
    }
}

pub fn writeFromStanding(w: *Io.Writer, st: engine_events.StandingWork) void {
    var buf: [max_items]Item = undefined;
    const n = @min(st.todos.len, buf.len);
    for (st.todos[0..n], 0..) |t, i| {
        buf[i] = .{ .content = t.content, .done = t.done, .active = t.active };
    }
    write(w, st.goal, buf[0..n]);
}

/// Parse the model's todo_write dump (`[x]` / `[~]` / `[ ]` lines) into the
/// same block. Unknown lines are ignored so a stray sentence cannot appear.
pub fn writeFromTodoText(w: *Io.Writer, title: []const u8, text: []const u8) void {
    var buf: [max_items]Item = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        if (n >= buf.len) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len < 4) continue;
        const mark = line[0..3];
        const rest = std.mem.trim(u8, line[3..], " \t");
        if (std.mem.eql(u8, mark, "[x]") or std.mem.eql(u8, mark, "[X]")) {
            buf[n] = .{ .content = rest, .done = true };
            n += 1;
        } else if (std.mem.eql(u8, mark, "[~]")) {
            buf[n] = .{ .content = rest, .active = true };
            n += 1;
        } else if (std.mem.eql(u8, mark, "[ ]")) {
            buf[n] = .{ .content = rest };
            n += 1;
        }
    }
    if (n == 0) return;
    write(w, title, buf[0..n]);
}

test "empty standing work draws nothing" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    write(&aw.writer, "", &.{});
    try std.testing.expectEqualStrings("", aw.writer.buffered());
}

test "a checklist is WORKING plus a tree, not [~] dump lines" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    writeFromTodoText(&aw.writer, "full Meld test deployment", "[x] inspect\n[~] configure Cloudflare\n[ ] build + validate\n[ ] deploy + verify\n[ ] commit + push\n");
    try std.testing.expectEqualStrings(
        "WORKING  full Meld test deployment  1/5\n" ++
            "├ ✓ inspect\n" ++
            "├ ◌ configure Cloudflare\n" ++
            "├ ○ build + validate\n" ++
            "├ ○ deploy + verify\n" ++
            "└ ○ commit + push\n",
        aw.writer.buffered(),
    );
}

test "writeFromStanding uses the goal title and active/done marks" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const items = [_]engine_events.StandingTodo{
        .{ .content = "inspect", .done = true },
        .{ .content = "configure", .active = true },
        .{ .content = "deploy" },
    };
    writeFromStanding(&aw.writer, .{ .goal = "ship it", .todos = &items, .todos_done = 1, .todos_total = 3 });
    try std.testing.expectEqualStrings(
        "WORKING  ship it  1/3\n" ++
            "├ ✓ inspect\n" ++
            "├ ◌ configure\n" ++
            "└ ○ deploy\n",
        aw.writer.buffered(),
    );
}
