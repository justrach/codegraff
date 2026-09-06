//! #737: no emulator, model calls or terminal spawn. Real read/batch seam.
const std = @import("std");
const sim = @import("sim.zig");
const engine = @import("engine.zig");
const key = @import("key.zig");

fn draft(term: *sim.Term, expected: []const u8, history_len: usize) !void {
    try std.testing.expectEqualStrings(expected, term.model.input.getValue());
    try std.testing.expectEqual(@as(usize, 0), term.model.steer_queue.items.len);
    try std.testing.expectEqual(history_len, term.model.history.items.len);
    try std.testing.expect(term.model.pending != null);
    try std.testing.expect(!term.model.cancel_requested);
    try std.testing.expect(!term.model.quit_requested);
}

test "#737 long bracketed single/LF/CRLF paste across reads and batches stays unsent until Enter" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "", "\n", "\r\n" }) |ending| {
        // Includes one-byte reads (every marker and CRLF split), batch-cap
        // boundaries, and actual 16KiB read boundaries. Each payload >32KiB.
        for ([_]usize{ 1, 63, 64, 65, 16384 }) |chunk| {
            var term: sim.Term = undefined;
            term.init(a, 80, 24);
            defer term.deinit();
            const job = try a.create(engine.Job);
            job.* = .{ .gpa = a, .history = &.{}, .params = .{}, .stream = .{}, .threaded = false };
            term.model.pending = job;
            defer {
                term.model.pending = null;
                a.destroy(job);
            }
            try term.model.push(.pending, "active turn");
            const history_len = term.model.history.items.len;
            var payload: std.ArrayList(u8) = .empty;
            defer payload.deinit(a);
            var expected: std.ArrayList(u8) = .empty;
            defer expected.deinit(a);
            const paragraph: [1023]u8 = @splat('p');
            for (0..33) |p| {
                if (p != 0) {
                    try payload.appendSlice(a, ending);
                    if (ending.len != 0) try expected.append(a, '\n');
                }
                try payload.appendSlice(a, &paragraph);
                try expected.appendSlice(a, &paragraph);
            }
            var wire: std.ArrayList(u8) = .empty;
            defer wire.deinit(a);
            try wire.appendSlice(a, "\x1b[200~");
            try wire.appendSlice(a, payload.items);
            try wire.appendSlice(a, "\x1b[201~");
            var offset: usize = 0;
            while (offset < wire.items.len) {
                const end = @min(offset + chunk, wire.items.len);
                try std.testing.expectEqual(.stay, term.feed(wire.items[offset..end]));
                try std.testing.expectEqual(@as(usize, 0), term.model.steer_queue.items.len);
                try std.testing.expectEqual(history_len, term.model.history.items.len);
                try std.testing.expect(!term.model.cancel_requested);
                offset = end;
            }
            try draft(&term, expected.items, history_len);
            try std.testing.expect(!term.model.pasting and !key.inPaste());
            // No synthetic delay: explicit termination must retire burst carry.
            _ = term.feed("\r");
            try std.testing.expectEqual(@as(usize, 1), term.model.steer_queue.items.len);
            try std.testing.expectEqualStrings(expected.items, term.model.steer_queue.items[0]);
            try std.testing.expectEqualStrings("", term.model.input.getValue());
            try std.testing.expect(!term.model.cancel_requested);
        }
    }
}

test "#737 Enter coalesced with bracketed terminator submits once, not a paste newline" {
    const a = std.testing.allocator;
    var term: sim.Term = undefined;
    term.init(a, 80, 24);
    defer term.deinit();
    const job = try a.create(engine.Job);
    job.* = .{ .gpa = a, .history = &.{}, .params = .{}, .stream = .{}, .threaded = false };
    term.model.pending = job;
    defer {
        term.model.pending = null;
        a.destroy(job);
    }
    try term.model.push(.pending, "active turn");
    // Includes embedded LF in the SAME read as the explicit Enter, so the
    // per-read heuristic must not reclassify that key after CSI 201~.
    _ = term.feed("\x1b[200~first\nsecond\x1b[201~\r");
    try std.testing.expectEqual(@as(usize, 1), term.model.steer_queue.items.len);
    try std.testing.expectEqualStrings("first\nsecond", term.model.steer_queue.items[0]);
    try std.testing.expectEqualStrings("", term.model.input.getValue());
    try std.testing.expect(!term.model.cancel_requested);
}

test "#737 delayed paste_end dispatch cannot reset a subsequent decoded paste" {
    const a = std.testing.allocator;
    var term: sim.Term = undefined;
    term.init(a, 80, 24);
    defer term.deinit();
    const job = try a.create(engine.Job);
    job.* = .{ .gpa = a, .history = &.{}, .params = .{}, .stream = .{}, .threaded = false };
    term.model.pending = job;
    defer {
        term.model.pending = null;
        a.destroy(job);
    }
    try term.model.push(.pending, "active turn");
    _ = term.feed("\x1b[200~first\x1b[201~\x1b[200~second");
    _ = term.feed("\r");
    _ = term.feed("\nthird\x1b[201~");
    const got = term.model.input.getValue();
    try std.testing.expect(std.mem.startsWith(u8, got, "firstsecond"));
    try std.testing.expect(std.mem.endsWith(u8, got, "third"));
    try std.testing.expectEqual(@as(usize, 0), term.model.steer_queue.items.len);
    try std.testing.expect(!term.model.cancel_requested);
}
