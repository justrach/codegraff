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
    owned: bool = false,
    calls: usize = 0,

    fn call(ctx: ?*anyopaque, dest: []u8, owned: *bool) isize {
        const self: *Paste = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        owned.* = self.owned;
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

test "clipboard-owned attachment removal deletes the export but preserves an original" {
    const saved_fn = engine.g_paste_fn;
    const saved_ctx = engine.g_turn_ctx;
    defer {
        engine.g_paste_fn = saved_fn;
        engine.g_turn_ctx = saved_ctx;
    }
    engine.g_paste_fn = Paste.call;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "paste.png" });
    defer std.testing.allocator.free(path);
    for ([_]bool{ true, false }) |owned| {
        try tmp.dir.writeFile(io, .{ .sub_path = "paste.png", .data = "pixels" });
        var paste = Paste{ .payload = path, .owned = owned };
        engine.g_turn_ctx = &paste;
        var term: Term = undefined;
        term.init(std.testing.allocator, 100, 24);
        defer term.deinit();
        _ = term.feed("\x16");
        try std.testing.expectEqual(@as(usize, 1), term.model.images.items.len);
        _ = term.feed("\x7f");
        try std.testing.expectEqual(@as(usize, 0), term.model.images.items.len);
        if (owned) {
            try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "paste.png", .{}));
        } else {
            const original = try tmp.dir.openFile(io, "paste.png", .{});
            original.close(io);
        }
    }
}

test "sent clipboard export survives prompt recall and remains available for saved replay" {
    const saved_fn = engine.g_paste_fn;
    const saved_ctx = engine.g_turn_ctx;
    defer {
        engine.g_paste_fn = saved_fn;
        engine.g_turn_ctx = saved_ctx;
    }
    engine.g_paste_fn = Paste.call;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "paste.png", .data = "pixels" });
    const path = try tmp.dir.realPathFileAlloc(io, "paste.png", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var paste = Paste{ .payload = path, .owned = true };
    engine.g_turn_ctx = &paste;
    {
        var term: Term = undefined;
        term.init(std.testing.allocator, 100, 24);
        defer term.deinit();
        _ = term.feed("\x16");
        _ = term.typeText("describe this");
        _ = term.enter();
        @import("owned_images.zig").collect(&term.model);
        const retained = try tmp.dir.openFile(io, "paste.png", .{});
        retained.close(io);
        @import("prompt_history.zig").recallPrev(&term.model);
        try std.testing.expectEqualStrings(path, term.model.images.items[0]);
        @import("image.zig").clearAll(&term.model);
        const history = try tmp.dir.openFile(io, "paste.png", .{});
        history.close(io);
    }
    const replay = try tmp.dir.openFile(io, "paste.png", .{});
    replay.close(io);
}

test "queued clipboard exports remain readable until the queue releases them" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "paste.png", .data = "pixels" });
    const path = try tmp.dir.realPathFileAlloc(io, "paste.png", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var term: Term = undefined;
    term.init(std.testing.allocator, 100, 24);
    defer term.deinit();
    @import("owned_images.zig").attach(&term.model, path, true);
    @import("dispatch.zig").queueSteerLine(&term.model, "describe this");
    @import("owned_images.zig").collect(&term.model);
    const retained = try tmp.dir.openFile(io, "paste.png", .{});
    retained.close(io);
    term.model.alloc.free(term.model.steer_queue.pop().?);
    @import("owned_images.zig").collect(&term.model);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "paste.png", .{}));
}

test "closing an unsent clipboard draft releases only its owned export" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "paste.png", .data = "pixels" });
    const path = try tmp.dir.realPathFileAlloc(io, "paste.png", std.testing.allocator);
    defer std.testing.allocator.free(path);
    {
        var term: Term = undefined;
        term.init(std.testing.allocator, 100, 24);
        defer term.deinit();
        @import("owned_images.zig").attach(&term.model, path, true);
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "paste.png", .{}));
}

test "clipboard removal preserves a replacement file at the exported path" {
    try changedExport(false, false);
}

test "clipboard teardown preserves edited exports" {
    try changedExport(true, false);
}

test "clipboard removal preserves a symlink substituted for the export" {
    try changedExport(false, true);
}

fn changedExport(edited: bool, symlink: bool) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "paste.png", .data = "pixels" });
    const file_path = try tmp.dir.realPathFileAlloc(io, "paste.png", std.testing.allocator);
    defer std.testing.allocator.free(file_path);
    {
        var term: Term = undefined;
        term.init(std.testing.allocator, 100, 24);
        defer term.deinit();
        @import("owned_images.zig").attach(&term.model, file_path, true);
        if (!edited) try tmp.dir.rename("paste.png", tmp.dir, "old.png", io);
        if (symlink) {
            try tmp.dir.symLink(io, "old.png", "paste.png", .{});
        } else {
            try tmp.dir.writeFile(io, .{ .sub_path = "paste.png", .data = "user replacement pixels" });
        }
        if (!edited) _ = term.feed("\x7f");
    }
    const preserved = try tmp.dir.openFile(io, "paste.png", .{});
    defer preserved.close(io);
    var bytes: [64]u8 = undefined;
    const n = try preserved.readPositionalAll(io, &bytes, 0);
    try std.testing.expectEqualStrings(if (symlink) "pixels" else "user replacement pixels", bytes[0..n]);
}

test "sent clipboard exports survive clearing visible history and prompt recall" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "paste.png", .data = "pixels" });
    const file_path = try tmp.dir.realPathFileAlloc(io, "paste.png", std.testing.allocator);
    defer std.testing.allocator.free(file_path);
    {
        var term: Term = undefined;
        term.init(std.testing.allocator, 100, 24);
        defer term.deinit();
        @import("owned_images.zig").attach(&term.model, file_path, true);
        _ = term.typeText("describe this");
        _ = term.enter();
        term.model.clearHistory();
        @import("prompt_history.zig").deinit(&term.model);
        term.model.prompt_hist_images = std.array_list.Managed([]const []const u8).init(term.alloc);
        @import("owned_images.zig").collect(&term.model);
        const retained = try tmp.dir.openFile(io, "paste.png", .{});
        retained.close(io);
    }
    const replay = try tmp.dir.openFile(io, "paste.png", .{});
    replay.close(io);
}

test "completed model worker releases a removed unsent clipboard draft" {
    try workerReleasesDraft(false);
}

test "completed background worker releases a removed unsent clipboard draft" {
    try workerReleasesDraft(true);
}

fn workerReleasesDraft(background: bool) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "paste.png", .data = "pixels" });
    const file_path = try tmp.dir.realPathFileAlloc(io, "paste.png", gpa);
    defer gpa.free(file_path);
    var term: Term = undefined;
    term.init(gpa, 100, 24);
    defer term.deinit();
    @import("owned_images.zig").attach(&term.model, file_path, true);
    if (background) {
        const op = try gpa.create(engine.BgOp);
        op.* = .{ .kind = .files, .gpa = gpa, .threaded = false };
        term.model.bg = op;
    } else {
        const job = try gpa.create(engine.Job);
        job.* = .{ .gpa = gpa, .threaded = false, .history = try gpa.alloc(engine.Turn, 0), .params = .{}, .stream = .{} };
        term.model.pending = job;
    }
    @import("image.zig").clearAll(&term.model);
    const pending = try tmp.dir.openFile(io, "paste.png", .{});
    pending.close(io);
    if (background) {
        term.model.bg.?.done.store(true, .release);
        @import("bgop.zig").finish(&term.model);
    } else {
        term.model.pending.?.done.store(true, .release);
        @import("turn.zig").finishJob(&term.model);
    }
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "paste.png", .{}));
}
