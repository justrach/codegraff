//! Focused regressions for the public Esc scanner seam (#967).

const std = @import("std");
const interrupt = @import("agent_interrupt.zig");
const main_mod = @import("main.zig");

const page = std.heap.page_allocator;

const FakeInput = struct {
    chunks: []const []const u8,
    next_chunk: usize = 0,
    poll_calls: usize = 0,

    pub fn read(self: *FakeInput, buf: []u8) usize {
        if (self.next_chunk >= self.chunks.len) return 0;
        const chunk = self.chunks[self.next_chunk];
        self.next_chunk += 1;
        std.debug.assert(chunk.len <= buf.len);
        @memcpy(buf[0..chunk.len], chunk);
        return chunk.len;
    }

    pub fn poll(self: *FakeInput, timeout_ms: i32) bool {
        self.poll_calls += 1;
        return timeout_ms == 50 and self.next_chunk < self.chunks.len;
    }
};

fn resetGlobals() void {
    for (main_mod.g_steer_queue.items) |entry| page.free(entry.text);
    main_mod.g_steer_queue.clearRetainingCapacity();
    main_mod.g_steer_buf.clearRetainingCapacity();
    main_mod.g_steer_echoed = false;
    main_mod.g_steer_visible.store(false, .release);
    main_mod.g_force_interrupt = false;
    main_mod.g_thinking_fold_request = false;
    main_mod.g_thinking_open = false;
}

test "same-read ESC BS edits steering without interrupting" {
    resetGlobals();
    defer resetGlobals();

    try main_mod.g_steer_buf.appendSlice(page, "ab");
    var chunks = [_][]const u8{"\x1b\x08"};
    var input = FakeInput{ .chunks = &chunks };

    try std.testing.expect(!interrupt.escPressedFrom(&input, false));
    try std.testing.expectEqualStrings("a", main_mod.g_steer_buf.items);
    try std.testing.expectEqual(@as(usize, 0), input.poll_calls);
    try std.testing.expect(!main_mod.g_force_interrupt);
}

test "split-read ESC BS edits steering without interrupting" {
    resetGlobals();
    defer resetGlobals();

    try main_mod.g_steer_buf.appendSlice(page, "ab");
    var chunks = [_][]const u8{ "\x1b", "\x08" };
    var input = FakeInput{ .chunks = &chunks };

    try std.testing.expect(!interrupt.escPressedFrom(&input, false));
    try std.testing.expectEqualStrings("a", main_mod.g_steer_buf.items);
    try std.testing.expectEqual(@as(usize, 1), input.poll_calls);
    try std.testing.expect(!main_mod.g_force_interrupt);
}

test "complete CSI modified-delete does not interrupt" {
    resetGlobals();
    defer resetGlobals();

    try main_mod.g_steer_buf.appendSlice(page, "ab");
    var chunks = [_][]const u8{"\x1b[3;5~"};
    var input = FakeInput{ .chunks = &chunks };

    try std.testing.expect(!interrupt.escPressedFrom(&input, false));
    try std.testing.expectEqualStrings("ab", main_mod.g_steer_buf.items);
    try std.testing.expectEqual(@as(usize, 0), input.poll_calls);
}

test "split CSI modified-delete does not interrupt" {
    resetGlobals();
    defer resetGlobals();

    try main_mod.g_steer_buf.appendSlice(page, "ab");
    var chunks = [_][]const u8{ "\x1b[3;5", "~" };
    var input = FakeInput{ .chunks = &chunks };

    try std.testing.expect(!interrupt.escPressedFrom(&input, false));
    try std.testing.expectEqualStrings("ab", main_mod.g_steer_buf.items);
    try std.testing.expectEqual(@as(usize, 1), input.poll_calls);
}

test "split SS3 ESC O then final byte preserves following steering" {
    resetGlobals();
    defer resetGlobals();

    var chunks = [_][]const u8{ "\x1bO", "Atext" };
    var input = FakeInput{ .chunks = &chunks };

    try std.testing.expect(!interrupt.escPressedFrom(&input, false));
    try std.testing.expectEqualStrings("text", main_mod.g_steer_buf.items);
    try std.testing.expectEqual(@as(usize, 1), input.poll_calls);
    try std.testing.expect(!main_mod.g_force_interrupt);
}

test "split-read SS3 ESC O then final byte preserves following steering" {
    resetGlobals();
    defer resetGlobals();

    var chunks = [_][]const u8{ "\x1b", "O", "Atext" };
    var input = FakeInput{ .chunks = &chunks };

    try std.testing.expect(!interrupt.escPressedFrom(&input, false));
    try std.testing.expectEqualStrings("text", main_mod.g_steer_buf.items);
    try std.testing.expectEqual(@as(usize, 2), input.poll_calls);
    try std.testing.expect(!main_mod.g_force_interrupt);
}

test "split-read OSC ST preserves following steering" {
    resetGlobals();
    defer resetGlobals();

    var chunks = [_][]const u8{ "\x1b]0;reply", "\x1b", "\\text" };
    var input = FakeInput{ .chunks = &chunks };

    try std.testing.expect(!interrupt.escPressedFrom(&input, false));
    try std.testing.expectEqualStrings("text", main_mod.g_steer_buf.items);
    try std.testing.expectEqual(@as(usize, 2), input.poll_calls);
    try std.testing.expect(!main_mod.g_force_interrupt);
}

test "ESC plus printable byte interrupts and preserves the byte" {
    resetGlobals();
    defer resetGlobals();

    var chunks = [_][]const u8{"\x1bq"};
    var input = FakeInput{ .chunks = &chunks };

    try std.testing.expect(interrupt.escPressedFrom(&input, false));
    try std.testing.expectEqualStrings("q", main_mod.g_steer_buf.items);
    try std.testing.expectEqual(@as(usize, 0), input.poll_calls);
    try std.testing.expect(!main_mod.g_force_interrupt);
}
