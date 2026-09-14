//! #883: exercise Ctrl-V dispatch without a terminal or clipboard access.
//! PasteFn exposes only image paths (>0), errors (<0), and no image (0).
//! Text fallback and image/text precedence require a seam inside pasteCb;
//! these tests deliberately make no claims about those backend decisions.

const std = @import("std");
const engine = @import("engine.zig");
const Term = @import("sim.zig").Term;

const Paste = struct {
    payload: []const u8,
    failed: bool = false,
    calls: usize = 0,

    fn call(ctx: ?*anyopaque, dest: []u8) isize {
        const self: *Paste = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        const n = @min(self.payload.len, dest.len);
        @memcpy(dest[0..n], self.payload[0..n]);
        const result: isize = @intCast(n);
        return if (self.failed) -result else result;
    }
};

fn expectVisible(term: *Term, text: []const u8) !void {
    const screen = try term.screen();
    defer term.alloc.free(screen);
    try std.testing.expect(std.mem.indexOf(u8, screen, text) != null);
}

test "#883 Ctrl-V callback failures remain visible and preserve the prompt and attachments" {
    const saved_fn = engine.g_paste_fn;
    const saved_ctx = engine.g_turn_ctx;
    defer {
        engine.g_paste_fn = saved_fn;
        engine.g_turn_ctx = saved_ctx;
    }
    engine.g_paste_fn = Paste.call;

    // Synthetic backend errors: dispatch must display, not reinterpret them.
    for ([_][]const u8{ "clipboard read failed", "clipboard image export failed", "clipboard text read failed" }) |message| {
        var paste = Paste{ .payload = message, .failed = true };
        engine.g_turn_ctx = &paste;
        var term: Term = undefined;
        term.init(std.testing.allocator, 100, 24);
        defer term.deinit();
        _ = term.typeText("keep this prompt");
        _ = term.feed("\x1b[D");
        const cursor = term.model.input.cursor;
        term.model.attachImage("/synthetic/existing.png");

        _ = term.feed("\x16");

        try std.testing.expectEqual(@as(usize, 1), paste.calls);
        try std.testing.expectEqualStrings("keep this prompt", term.model.input.getValue());
        try std.testing.expectEqual(cursor, term.model.input.cursor);
        try std.testing.expectEqual(@as(usize, 1), term.model.images.items.len);
        try std.testing.expectEqualStrings("/synthetic/existing.png", term.model.images.items[0]);
        try expectVisible(&term, message);
    }
}

test "#883 Ctrl-V image result attaches without replacing prompt text" {
    const saved_fn = engine.g_paste_fn;
    const saved_ctx = engine.g_turn_ctx;
    defer {
        engine.g_paste_fn = saved_fn;
        engine.g_turn_ctx = saved_ctx;
    }
    var paste = Paste{ .payload = "/synthetic/clipboard.png" };
    engine.g_paste_fn = Paste.call;
    engine.g_turn_ctx = &paste;
    var term: Term = undefined;
    term.init(std.testing.allocator, 100, 24);
    defer term.deinit();
    _ = term.typeText("describe this");
    _ = term.feed("\x1b[D");
    const cursor = term.model.input.cursor;

    _ = term.feed("\x1b[118;5u");

    try std.testing.expectEqual(@as(usize, 1), paste.calls);
    try std.testing.expectEqualStrings("describe this", term.model.input.getValue());
    try std.testing.expectEqual(cursor, term.model.input.cursor);
    try std.testing.expectEqual(@as(usize, 1), term.model.images.items.len);
    try std.testing.expectEqualStrings(paste.payload, term.model.images.items[0]);
    try expectVisible(&term, "[Image #1] attached");
}

test "#883 Ctrl-V empty callback result is visible without changing the prompt" {
    const saved_fn = engine.g_paste_fn;
    const saved_ctx = engine.g_turn_ctx;
    defer {
        engine.g_paste_fn = saved_fn;
        engine.g_turn_ctx = saved_ctx;
    }
    var paste = Paste{ .payload = "" };
    engine.g_paste_fn = Paste.call;
    engine.g_turn_ctx = &paste;
    var term: Term = undefined;
    term.init(std.testing.allocator, 100, 24);
    defer term.deinit();
    _ = term.typeText("keep this prompt");
    const cursor = term.model.input.cursor;

    _ = term.feed("\x16");

    try std.testing.expectEqual(@as(usize, 1), paste.calls);
    try std.testing.expectEqualStrings("keep this prompt", term.model.input.getValue());
    try std.testing.expectEqual(cursor, term.model.input.cursor);
    try std.testing.expectEqual(@as(usize, 0), term.model.images.items.len);
    try expectVisible(&term, "no image on the clipboard");
}
