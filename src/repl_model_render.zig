//! `graff repl` Model — pane rendering: spinner frame selection, the status
//! line, the full frame draw (conversation history + input box, clamped to
//! the terminal size), and mouse drag-selection copy. Split out of the
//! Model struct in repl.zig (#123, 600-line goal); reached through
//! repl.zig's member aliases, so both `self.render(...)` and
//! `Model.render(...)` resolve here unchanged.

const std = @import("std");
const zz = @import("zigzag");

const repl = @import("repl.zig");
const Model = repl.Model;

const util = @import("repl_util.zig");
const stripControl = util.stripControl;
const tailPreview = util.tailPreview;

pub fn spinnerFrame(self: *const Model, now_ms: u64) []const u8 {
    return switch (self.anim) {
        .braille => repl.braille_frames[(now_ms / 80) % repl.braille_frames.len],
        .dragon => repl.dragon_frames[(now_ms / 220) % repl.dragon_frames.len],
    };
}

pub fn statusLine(self: *const Model, a: std.mem.Allocator) ![]const u8 {
    var b = std.array_list.Managed(u8).init(a);
    if (self.scroll > 0) try b.appendSlice("↑ scrolled · PgDn to bottom  ·  ");
    if (self.chat and repl.g_model_name.len > 0) try b.appendSlice(repl.g_model_name) else try b.appendSlice("offline · arithmetic");
    try b.appendSlice(try std.fmt.allocPrint(a, "  ·  effort:{s}", .{@tagName(self.effort)}));
    if (self.fast) try b.appendSlice("  ·  ⚡fast");
    if (self.ultracode) try b.appendSlice("  ·  ✦ultracode");
    if (self.plan) try b.appendSlice("  ·  plan");
    if (self.yolo) try b.appendSlice("  ·  yolo");
    if (self.strict) try b.appendSlice("  ·  strict");
    if (self.thinking_show) try b.appendSlice("  ·  thinking");
    if (!self.keepcontext) try b.appendSlice("  ·  no-ctx");
    if (self.goal != null) try b.appendSlice("  ·  🎯goal");
    if (self.turns > 0) try b.appendSlice(try std.fmt.allocPrint(a, "  ·  {d}t", .{self.turns}));
    try b.appendSlice("  ·  /help");
    return b.items;
}

/// Render at `term_width` x `term_height`; `now_ms` drives animations. Input
/// box is pinned to the bottom; conversation fills from the top.
pub fn render(self: *Model, gpa: std.mem.Allocator, term_width: usize, term_height: usize, now_ms: u64) ![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const inner: u16 = @intCast(@max(@as(usize, 8), term_width) - 4);
    const border_color = if (self.ultracode) repl.rainbow[(now_ms / 90) % repl.rainbow.len] else zz.Color.brightBlack;
    const box = (zz.Style{}).borderAll(zz.Border.rounded)
        .borderForeground(border_color).paddingLeft(1).paddingRight(1).width(inner);

    var top = std.array_list.Managed(u8).init(a);
    for (self.history.items) |e| {
        switch (e.kind) {
            .welcome => {
                const star = try (zz.Style{}).fg(repl.accent).bold(true).render(a, "✻");
                const sub = if (self.chat) "Chat with the model — ask anything." else "i64 arithmetic — + - * / %, parens, unary minus.";
                const body = try std.fmt.allocPrint(a, "{s} Welcome to graff repl\n\n  {s}\n  /help for commands · ctrl-c to quit", .{ star, sub });
                try top.appendSlice(try box.render(a, body));
                try top.append('\n');
            },
            .input => {
                const g = try (zz.Style{}).fg(.brightBlack).render(a, ">");
                try top.appendSlice(try std.fmt.allocPrint(a, "{s} {s}\n", .{ g, e.text }));
            },
            .result => {
                const g = try (zz.Style{}).fg(.green).bold(true).render(a, "⏺");
                try top.appendSlice(try std.fmt.allocPrint(a, "{s} {s}\n", .{ g, e.text }));
            },
            .assistant => {
                const g = try (zz.Style{}).fg(repl.accent).bold(true).render(a, "⏺");
                try top.appendSlice(try std.fmt.allocPrint(a, "{s} {s}\n", .{ g, e.text }));
            },
            .pending => {
                const g = try (zz.Style{}).fg(repl.accent).bold(true).render(a, self.spinnerFrame(now_ms));
                const live = if (self.pending) |job| job.stream.snapshot(a) else null;
                if (live) |s| {
                    // Compact live activity: the last few lines of the
                    // agent's output, control-stripped + width-truncated,
                    // so tool chatter can't flood the pane.
                    try top.appendSlice(try std.fmt.allocPrint(a, "{s} working…\n", .{g}));
                    try top.appendSlice(try tailPreview(a, stripControl(a, s), term_width, 3));
                } else {
                    const t = try (zz.Style{}).dim(true).render(a, "thinking…");
                    try top.appendSlice(try std.fmt.allocPrint(a, "{s} {s}\n", .{ g, t }));
                }
                if (self.steer_queue.items.len > 0) {
                    try top.appendSlice(try (zz.Style{}).dim(true).render(a, try std.fmt.allocPrint(a, "  ↳ {d} steer queued · empty Enter runs now\n", .{self.steer_queue.items.len})));
                } else {
                    try top.appendSlice(try (zz.Style{}).dim(true).render(a, "  ↳ type to steer · Enter queues\n"));
                }
            },
            .err => {
                const g = try (zz.Style{}).fg(.red).bold(true).render(a, "⏺");
                const m = try (zz.Style{}).fg(.red).render(a, e.text);
                try top.appendSlice(try std.fmt.allocPrint(a, "{s} {s}\n", .{ g, m }));
            },
            .info => {
                try top.appendSlice(try (zz.Style{}).dim(true).render(a, e.text));
                try top.append('\n');
            },
        }
    }

    var bottom = std.array_list.Managed(u8).init(a);
    try bottom.appendSlice(try box.render(a, try self.input.view(a)));
    try bottom.append('\n');
    try bottom.appendSlice(try (zz.Style{}).dim(true).render(a, try self.statusLine(a)));

    // The conversation is a scrollable viewport above the pinned input box.
    // scroll = lines scrolled up from the bottom (0 = latest). Clamped here.
    const bottom_lines = std.mem.count(u8, bottom.items, "\n") + 1;
    const view_h = if (term_height > bottom_lines) term_height - bottom_lines else 1;

    var lines = std.array_list.Managed([]const u8).init(a);
    var it = std.mem.splitScalar(u8, top.items, '\n');
    while (it.next()) |ln| try lines.append(ln);
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();
    const n = lines.items.len;

    var out = std.array_list.Managed(u8).init(a);
    // Reset the per-frame visible-row snapshot (Model-owned plaintext, so a
    // mouse row can be mapped back to conversation text for copy — #91).
    for (self.visible_text.items) |l| self.alloc.free(l);
    self.visible_text.clearRetainingCapacity();
    self.view_start = 0;
    self.view_rows = 0;
    if (n <= view_h) {
        self.scroll = 0;
        try out.appendSlice(top.items);
        for (0..(view_h - n)) |_| try out.append('\n');
        self.view_rows = n;
        for (lines.items[0..n]) |ln| {
            self.visible_text.append(self.alloc.dupe(u8, stripControl(a, ln)) catch continue) catch {};
        }
    } else {
        const max_scroll = n - view_h;
        if (self.scroll > max_scroll) self.scroll = max_scroll;
        const start = max_scroll - self.scroll;
        self.view_start = start;
        self.view_rows = view_h;
        for (lines.items[start .. start + view_h]) |ln| {
            try out.appendSlice(ln);
            try out.append('\n');
            self.visible_text.append(self.alloc.dupe(u8, stripControl(a, ln)) catch continue) catch {};
        }
    }
    try out.appendSlice(bottom.items);
    if (self.dump_next) {
        std.debug.print("\n[repl-debug] ===== rendered frame ({d}x{d}) =====\n{s}\n[repl-debug] ===== end frame =====\n", .{ term_width, term_height, out.items });
        self.dump_next = false;
    }
    return gpa.dupe(u8, out.items);
}

/// Copy the conversation lines spanned by a drag-selection (screen rows
/// r0..r1 inclusive, 0-based) to the clipboard via OSC52. Line-granular —
/// restores copy after mouse mode disabled native terminal selection (#91).
pub fn copySelection(self: *Model, ctx: *zz.Context, r0: usize, r1: usize) void {
    if (self.view_rows == 0 or self.visible_text.items.len == 0) return;
    const lo = @min(r0, r1);
    var hi = @max(r0, r1);
    if (lo >= self.view_rows) return; // selection started below the conversation
    if (hi >= self.view_rows) hi = self.view_rows - 1;
    if (hi >= self.visible_text.items.len) hi = self.visible_text.items.len - 1;

    var buf = std.array_list.Managed(u8).init(self.alloc);
    defer buf.deinit();
    var r = lo;
    while (r <= hi) : (r += 1) {
        const ln = std.mem.trimEnd(u8, self.visible_text.items[r], " \t");
        buf.appendSlice(ln) catch return;
        if (r != hi) buf.append('\n') catch return;
    }
    const text = std.mem.trim(u8, buf.items, " \t\r\n");
    if (text.len == 0) return;
    _ = ctx.setClipboard(text) catch false;
    // render() is hash-gated and may skip its flush; push the OSC52 out now.
    if (ctx._terminal) |term| term.flush() catch {};
}
