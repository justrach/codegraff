//! Regression coverage for issue 788: wrapped composer URLs keep one safe OSC 8
//! target without leaking hyperlink state into row padding, borders, or footer.

const std = @import("std");
const render_mod = @import("render.zig");
const sim = @import("sim.zig");
const theme = @import("theme.zig");

const open_prefix = "\x1b]8;id=graff-composer-";
const close = "\x1b]8;;\x07";

fn expectTargetRows(a: std.mem.Allocator, frame: []const u8, target: []const u8, minimum: usize) !usize {
    const target_end = try std.fmt.allocPrint(a, ";{s}\x07", .{target});
    defer a.free(target_end);
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, frame, '\n');
    while (it.next()) |row| {
        const opens = std.mem.count(u8, row, open_prefix);
        const closes = std.mem.count(u8, row, close);
        if (opens == 0) {
            try std.testing.expectEqual(@as(usize, 0), closes);
            continue;
        }
        const target_at = std.mem.indexOf(u8, row, target_end) orelse return error.WrongLinkTarget;
        count += 1;
        const open_at = std.mem.lastIndexOf(u8, row[0 .. target_at + 1], open_prefix) orelse return error.MissingLinkOpen;
        const linked_at = target_at + target_end.len;
        const close_at = std.mem.indexOfPos(u8, row, linked_at, close) orelse return error.MissingLinkClose;
        const border_at = std.mem.lastIndexOf(u8, row, "│") orelse return error.MissingComposerBorder;
        try std.testing.expect(open_at < target_at);
        try std.testing.expect(theme.visibleLen(row[linked_at..close_at]) > 0);
        try std.testing.expect(close_at < border_at);
        try std.testing.expectEqual(opens, closes);
    }
    try std.testing.expect(count >= minimum);
    return count;
}

fn renderTerm(term: *sim.Term) ![]const u8 {
    return render_mod.render(&term.model, term.alloc, term.cols, term.rows, term.now_ms);
}

test "headless composer preserves wrapped http https and www targets" {
    const cases = [_]struct { visible: []const u8, target: []const u8 }{
        .{
            .visible = "http://example.test/one/two/three/four/five/six/seven/eight/nine",
            .target = "http://example.test/one/two/three/four/five/six/seven/eight/nine",
        },
        .{
            .visible = "https://example.test/one/two/three/four/five/six/seven/eight/nine",
            .target = "https://example.test/one/two/three/four/five/six/seven/eight/nine",
        },
        .{
            .visible = "www.example.test/one/two/three/four/five/six/seven/eight/nine",
            .target = "https://www.example.test/one/two/three/four/five/six/seven/eight/nine",
        },
    };
    for (cases) |case| {
        var term: sim.Term = undefined;
        term.init(std.testing.allocator, 40, 24);
        defer term.deinit();
        _ = term.typeText(case.visible);
        const narrow = try renderTerm(&term);
        defer std.testing.allocator.free(narrow);
        _ = try expectTargetRows(std.testing.allocator, narrow, case.target, 2);

        term.cols = 57;
        const resized = try renderTerm(&term);
        defer std.testing.allocator.free(resized);
        _ = try expectTargetRows(std.testing.allocator, resized, case.target, 2);
    }
}

test "headless composer starts a truncated eight-row link window balanced" {
    const target = "https://example.test/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    var term: sim.Term = undefined;
    term.init(std.testing.allocator, 40, 24);
    defer term.deinit();
    _ = term.typeText(target);
    const frame = try renderTerm(&term);
    defer std.testing.allocator.free(frame);
    const rows = try expectTargetRows(std.testing.allocator, frame, target, 8);
    try std.testing.expectEqual(@as(usize, 8), rows);
}

test "headless composer edits non-ASCII links only at scalar boundaries" {
    const original = "https://example.test/é";
    var term: sim.Term = undefined;
    term.init(std.testing.allocator, 40, 24);
    defer term.deinit();
    _ = term.typeText(original);
    _ = term.press(.left);
    _ = term.typeText("x");
    try std.testing.expectEqualStrings("https://example.test/xé", term.model.input.getValue());
    const frame = try renderTerm(&term);
    defer std.testing.allocator.free(frame);
    _ = try expectTargetRows(std.testing.allocator, frame, "https://example.test/xé", 1);
}

test "headless composer does not emit links for unsafe or embedded forms" {
    const cases = [_][]const u8{
        "javascript:alert(1)",
        "data:text/html,hello",
        "file:///tmp/a",
        "mailto:user@example.test",
        "ssh://example.test/path",
        "javascript:https://example.test/path",
        "user@www.example.test/path",
        "https://a.-b.example/path",
        "https://[:::]/path",
        "www.example.test:bad/path",
    };
    for (cases) |value| {
        var term: sim.Term = undefined;
        term.init(std.testing.allocator, 40, 24);
        defer term.deinit();
        _ = term.typeText(value);
        const frame = try renderTerm(&term);
        defer std.testing.allocator.free(frame);
        try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, frame, open_prefix));
    }
}
