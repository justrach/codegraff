//! The layout cache is only allowed to be faster — never different. Every test
//! here pins it against scrollback.zig's uncached path, which stays in the tree
//! precisely as the oracle: it re-wraps the whole history on every call, so if
//! the two ever disagree the cache is wrong by definition.
//!
//! The last test is the benchmark. It runs a token-sized transcript by default
//! (Debug timings are meaningless, so it asserts REUSE there, not speed) and
//! the full 10k-display-line matrix with numbers when GRAFF_TUI_BENCH is set —
//! see scripts/bench-tui-layout.sh, which builds it ReleaseFast.

const std = @import("std");

const app = @import("app.zig");
const engine = @import("engine.zig");
const layout = @import("layout_cache.zig");
const render_mod = @import("render.zig");
const scrollback = @import("scrollback.zig");
const theme_mod = @import("theme.zig");
const Model = app.Model;
const testing = std.testing;

/// The whole transcript, read back out of the cache one display line at a time
/// and re-joined. Byte-identical to scrollback.render is the contract.
fn cachedAll(m: *Model, a: std.mem.Allocator, width: usize) ![]const u8 {
    const c = layout.ensure(m, width);
    const lines = try layout.window(c, a, 0, c.total);
    var out = std.array_list.Managed(u8).init(a);
    for (lines, 0..) |ln, i| {
        if (i > 0) try out.append('\n');
        try out.appendSlice(ln);
    }
    return out.items;
}

const prose = "a long explanation line that fills the scrollback with content and keeps wrapping at every narrow width the matrix below tests";

fn fixture(m: *Model) !void {
    try m.push(.user, "how do I frobnicate the widget? and keep the question long enough to wrap");
    try m.push(.assistant, prose);
    try m.pushTool(.{ .name = "bash", .detail = "printf hello | wc -c" });
    try m.pushTool(.{ .name = "bash", .detail = "6", .done = true });
    try m.pushTool(.{ .name = "mcp__codedbpro__faster_search", .detail = "needle" });
    try m.pushTool(.{ .name = "mcp__codedbpro__faster_search", .detail = "3 hits", .done = true });
    try m.push(.assistant, "## heading\n\n- one\n- two\n\n`code` and **bold** " ++ prose);
    try m.push(.system, "· a system notice");
    try m.push(.err, "something went wrong while doing the thing that went wrong");
    try m.push(.user, "second prompt");
    try m.pushTool(.{ .name = "read_file", .detail = "src/foo.zig" });
    try m.pushTool(.{ .name = "read_file", .detail = "const std = @import(\"std\");", .done = true });
    try m.push(.assistant, "done");
}

// 44/80/120 are the audited trio (narrow, default, wide); the rest surround
// them so an off-by-one in the wrap math cannot hide between two sampled
// widths.
const widths = [_]usize{ 28, 41, 44, 60, 80, 100, 120, 132 };

test "cached layout is byte-identical to the uncached render over widths, themes and folds" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    try fixture(&m);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Every phase mutates something the cache keys on, WITHOUT clearing it:
    // the point is that invalidation is derived, not announced.
    for (theme_mod.all) |tid| {
        m.theme_id = tid;
        for (widths) |w| {
            for (0..8) |phase| {
                switch (phase) {
                    1 => m.toggleToolGroup(2), // expand the bash run
                    2 => m.toggleToolGroup(4), // expand the search run
                    3 => {
                        m.focus = .scrollback;
                        m.selected = 5;
                    },
                    4 => m.selected = 1,
                    5 => m.toggleToolGroup(2), // fold it back under selection
                    6 => m.focus = .prompt,
                    7 => {
                        try m.push(.assistant, "an appended answer that arrives after everything was cached " ++ prose);
                        try m.push(.pending, "");
                        m.now_ms = 700; // past the ❙/❘ blink half-period
                    },
                    else => {},
                }
                _ = arena.reset(.retain_capacity);
                const a = arena.allocator();
                const want = try scrollback.render(&m, a, w, m.now_ms);
                const got = try cachedAll(&m, a, w);
                testing.expectEqualStrings(want, got) catch |e| {
                    std.debug.print("theme={s} width={d} phase={d}\n", .{ tid.label(), w, phase });
                    return e;
                };
            }
            // The pending row is a history entry, not chrome: it maps back to
            // its own index the way every other row does.
            const c = layout.ensure(&m, w);
            const last = m.history.items.len - 1;
            try testing.expectEqual(last, layout.indexAt(c, c.total - 1).?);
            // Unwind phase 7's pushes so the next width starts from the fixture.
            m.freeEntry(m.history.pop().?);
            m.freeEntry(m.history.pop().?);
            m.now_ms = 0;
        }
    }
}

test "cached virtual-Y agrees with the uncached row math entry for entry" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    try fixture(&m);
    for (widths) |w| {
        for (0..3) |phase| {
            if (phase == 1) m.toggleToolGroup(2);
            if (phase == 2) m.toggleToolGroup(4);
            const c = layout.ensure(&m, w);
            try testing.expectEqual(scrollback.totalVisualLines(&m, w), c.total);
            var idx: usize = 0;
            while (idx < m.history.items.len) : (idx += 1) {
                try testing.expectEqual(scrollback.visualOfIndex(&m, idx, w), layout.lineOf(c, idx));
            }
            var y: usize = 0;
            while (y < c.total + 3) : (y += 1) {
                try testing.expectEqual(scrollback.indexAtVisual(&m, y, w), layout.indexAt(c, y));
                try testing.expectEqual(scrollback.stickyUserAbove(&m, y, w), layout.stickyUserAbove(c, y));
            }
        }
        m.toggleToolGroup(2);
        m.toggleToolGroup(4);
    }
}

test "the live turn's streaming tail and steer notice stay in the layout" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    try fixture(&m);
    var sbuf: [256]u8 = undefined;
    var none: [0]engine.Turn = .{};
    var job: engine.Job = .{
        .gpa = testing.allocator,
        .history = &none,
        .params = .{},
        .stream = .{ .buf = &sbuf },
    };
    m.pending = &job;
    defer m.pending = null;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Nothing streamed yet, then prose arrives a chunk at a time: only the tail
    // may move, and the whole frame must still match the oracle.
    for ([_][]const u8{ "", "thinking about it", "\nand a second line", "\nthird" }) |chunk| {
        if (chunk.len > 0) job.stream.appendBytes(chunk);
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        try testing.expectEqualStrings(try scrollback.render(&m, a, 80, m.now_ms), try cachedAll(&m, a, 80));
    }
    const queued = try testing.allocator.dupe(u8, "next thing");
    try m.steer_queue.append(queued);
    _ = arena.reset(.retain_capacity);
    const a = arena.allocator();
    try testing.expectEqualStrings(try scrollback.render(&m, a, 80, m.now_ms), try cachedAll(&m, a, 80));
    // A live row belongs to no history entry — clicking it must select nothing.
    const c = layout.ensure(&m, 80);
    try testing.expect(layout.indexAt(c, c.total - 1) == null);
}

test "appending reuses the whole cached prefix; a fold or a width change does not" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    try fixture(&m);
    var i: usize = 0;
    while (i < 40) : (i += 1) try m.push(.assistant, prose);

    const first = layout.ensure(&m, 80);
    const blocks = first.blocks.items.len;
    try testing.expect(blocks > 10);
    try testing.expectEqual(blocks, first.misses);

    // A frame with nothing changed lays NOTHING out again.
    first.hits = 0;
    first.misses = 0;
    _ = layout.ensure(&m, 80);
    try testing.expectEqual(@as(u64, 0), first.misses);
    try testing.expectEqual(@as(u64, blocks), first.hits);

    // An append re-lays out exactly one block, and the prefix is reused.
    first.hits = 0;
    first.misses = 0;
    try m.push(.assistant, "one more");
    _ = layout.ensure(&m, 80);
    try testing.expectEqual(@as(u64, 1), first.misses);
    try testing.expectEqual(@as(u64, blocks), first.hits);

    // A fold touches its own block only.
    first.hits = 0;
    first.misses = 0;
    m.toggleToolGroup(2);
    _ = layout.ensure(&m, 80);
    try testing.expectEqual(@as(u64, 1), first.misses);

    // A width change is a cold rebuild; so is a theme change at the same width.
    const colds = first.colds;
    _ = layout.ensure(&m, 72);
    try testing.expectEqual(colds + 1, first.colds);
    m.theme_id = .day;
    _ = layout.ensure(&m, 72);
    try testing.expectEqual(colds + 2, first.colds);
}

test "a cleared history drops the layout with the entries it points into" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    try fixture(&m);
    const c = layout.ensure(&m, 80);
    try testing.expect(c.total > 0);
    m.clearHistory();
    try testing.expectEqual(@as(usize, 0), m.layout.blocks.items.len);
    try testing.expectEqual(@as(usize, 0), layout.ensure(&m, 80).total);
    // And the transcript comes back correctly after the reset.
    try fixture(&m);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(try scrollback.render(&m, a, 80, 0), try cachedAll(&m, a, 80));
}

// --- benchmark -------------------------------------------------------------

fn p95(v: []u64) u64 {
    std.mem.sort(u64, v, {}, std.sort.asc(u64));
    return v[(v.len * 95) / 100];
}

fn grow(m: *Model, target: usize, width: usize) !void {
    while (layout.totalVisualLines(m, width) < target) {
        try m.push(.user, "a user prompt that is long enough to wrap at the narrower widths in the matrix");
        try m.push(.assistant, prose ++ " " ++ prose);
        try m.pushTool(.{ .name = "bash", .detail = "printf hello | wc -c" });
        try m.pushTool(.{ .name = "bash", .detail = "6", .done = true });
        try m.push(.system, "· a system notice");
    }
}

test "layout cache benchmark: frame build while scrolling, and cold rebuild" {
    const full = std.c.getenv("GRAFF_TUI_BENCH") != null;
    const target: usize = if (full) 10_000 else 1_200;
    const frames: usize = if (full) 400 else 40;
    const gpa = testing.allocator;
    var m: Model = undefined;
    m.setup(gpa);
    defer m.deinit();
    try grow(&m, target, 100);
    m.follow = false;
    const total = layout.totalVisualLines(&m, 100);

    const scroll_ns = try gpa.alloc(u64, frames);
    defer gpa.free(scroll_ns);
    const io = std.Io.Threaded.global_single_threaded.io();
    // Warm the layout so the first sample is a scroll, not the cold build.
    gpa.free(try render_mod.render(&m, gpa, 100, 40, 0));
    m.layout.hits = 0;
    m.layout.misses = 0;
    for (scroll_ns, 0..) |*slot, i| {
        m.scroll = (i * 3) % (total - 20);
        const t0 = std.Io.Timestamp.now(io, .boot).nanoseconds;
        const frame = try render_mod.render(&m, gpa, 100, 40, @intCast(i));
        slot.* = @intCast(@max(0, std.Io.Timestamp.now(io, .boot).nanoseconds - t0));
        gpa.free(frame);
    }
    const scroll_p95 = p95(scroll_ns);
    // Snapshot before the cold loop: those rebuilds are the thing being timed
    // next, and folding them in here would hide the claim this makes.
    const scroll_hits = m.layout.hits;
    const scroll_misses = m.layout.misses;

    var cold_ns: [6]u64 = undefined;
    for (&cold_ns, 0..) |*slot, i| {
        const w = widths[i % widths.len];
        const t0 = std.Io.Timestamp.now(io, .boot).nanoseconds;
        const frame = try render_mod.render(&m, gpa, w, 40, 0);
        slot.* = @intCast(@max(0, std.Io.Timestamp.now(io, .boot).nanoseconds - t0));
        gpa.free(frame);
    }
    const cold_max = std.mem.max(u64, &cold_ns);
    for (cold_ns, 0..) |ns, i| std.debug.print(
        "[layout-bench]   cold rebuild at width {d:>4} = {d:.3} ms\n",
        .{ widths[i % widths.len], @as(f64, @floatFromInt(ns)) / 1e6 },
    );

    // The path this replaces, on the same transcript: one uncached full
    // layout, which is what every wheel tick used to cost.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var before: [8]u64 = undefined;
    for (&before) |*slot| {
        _ = arena.reset(.retain_capacity);
        const t0 = std.Io.Timestamp.now(io, .boot).nanoseconds;
        const text = try scrollback.render(&m, arena.allocator(), 100, 0);
        std.mem.doNotOptimizeAway(text.len);
        slot.* = @intCast(@max(0, std.Io.Timestamp.now(io, .boot).nanoseconds - t0));
    }
    const before_med = p95(before[0..4]);

    std.debug.print(
        "\n[layout-bench] mode={s} entries={d} display_lines={d} frames={d}\n" ++
            "  scroll frame build p95 = {d:.3} ms (max {d:.3} ms)\n" ++
            "  cold rebuild after width change, worst of {d} = {d:.3} ms\n" ++
            "  block layouts during the scroll run: {d} reused / {d} rebuilt\n" ++
            "  uncached full layout (the path this replaces) = {d:.3} ms\n",
        .{
            if (full) "full" else "smoke",             m.history.items.len,
            total,                                     frames,
            @as(f64, @floatFromInt(scroll_p95)) / 1e6, @as(f64, @floatFromInt(scroll_ns[scroll_ns.len - 1])) / 1e6,
            cold_ns.len,                               @as(f64, @floatFromInt(cold_max)) / 1e6,
            scroll_hits,                               scroll_misses,
            @as(f64, @floatFromInt(before_med)) / 1e6,
        },
    );

    // A scroll must never re-lay a block out: that is the whole claim.
    try testing.expectEqual(@as(u64, 0), scroll_misses);
    try testing.expect(scroll_hits > 0);
    if (full) {
        try testing.expect(total >= 10_000);
        try testing.expect(scroll_p95 < 1_000_000); // < 1 ms
        try testing.expect(cold_max < 10_000_000); // < 10 ms
    }
}
