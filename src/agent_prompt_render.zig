//! The terminal half of the interactive status line (#422/#429): everything
//! about how `.prompt_ready` is DRAWN — the palette, the badge frame, and the
//! #209 width budget. Reached only from engine_sink's TuiSink, the same shape
//! agent_stream_render.zig and agent_tool_render.zig have for their clusters;
//! this is one of the few files down here that may touch ansi/term.
//!
//! Every function is the old inline agent_prompt.zig code path, gate for gate,
//! and the layout is asserted byte-for-byte by the tests at the bottom. The one
//! deliberate difference from the pre-#429 path: a write error is swallowed
//! rather than propagated, because a sink emit returns void. Every other
//! TuiSink branch already behaves that way, and the only way to reach it is a
//! terminal that has gone away mid-prompt.

const std = @import("std");
const Io = std.Io;

const style = &@import("ansi.zig").style;
const terminal = @import("term.zig");
const engine_events = @import("engine_events.zig");
const util = @import("util.zig");
const PromptStatus = engine_events.PromptStatus;

pub fn reasoningLabel(effort: anytype) []const u8 {
    return switch (effort) {
        .low => "Low",
        .medium => "Medium",
        .high => "High",
        .xhigh => "Extra high",
        .max => "Max",
        .ultra => "Ultra",
    };
}

pub fn reasoningColor(effort: anytype) []const u8 {
    return switch (effort) {
        .low => style.green,
        .medium => style.accent,
        .high => style.yellow,
        .xhigh => style.accent,
        .max => style.red,
        .ultra => style.accent,
    };
}

/// Include a status-line segment only if its width still fits the remaining
/// budget, charging it against `used` when it does. Lets the status line drop
/// low-priority metadata (cwd, context meter, cache/cost) instead of letting
/// the terminal soft-wrap the line mid-badge in a narrow pane — e.g. splitting
/// `codex` across the edge and stranding the cursor inside the label (#209).
pub fn fitsSegment(used: *usize, avail: usize, seg_width: usize) bool {
    if (used.* + seg_width <= avail) {
        used.* += seg_width;
        return true;
    }
    return false;
}

pub fn compactTokenCount(buf: []u8, tokens: u64) []const u8 {
    return if (tokens >= 1000)
        std.fmt.bufPrint(buf, "{d}k", .{tokens / 1000}) catch "?"
    else
        std.fmt.bufPrint(buf, "{d}", .{tokens}) catch "?";
}

pub fn contextPercent(tokens: u64, window: u64) u64 {
    if (window == 0) return 0;
    return @min((tokens *| 100) / window, 100);
}

/// Draw the status line for one `.prompt_ready`. Width-budgeted against the
/// terminal so a narrow pane never soft-wraps mid-badge (splitting e.g.
/// `codex`) and strands the cursor inside a label (#209); low-priority
/// metadata (cwd, context, cache, cost) is the first to drop when it no longer
/// fits. See fitsSegment's doc comment for the rest.
pub fn promptLine(w: *Io.Writer, st: PromptStatus) void {
    // The one environment read in this file, kept at the edge so the layout
    // below is a pure function of (status, width) and can be pinned by tests.
    line(w, st, terminal.termCols()) catch return;
}

fn workingActive(sw: engine_events.StandingWork) bool {
    return sw.goal.len > 0 or sw.todos_total > 0;
}

fn writeRule(w: *Io.Writer, cols: usize) !void {
    const n = @min(if (cols > 2) cols else 2, 64);
    try w.writeAll(style.dim);
    var i: usize = 0;
    while (i < n) : (i += 1) try w.writeAll("─");
    try w.print("{s}\n", .{style.reset});
}

/// Git-style WORKING block: the goal and checklist live here, not in the
/// agent narration and not mixed into the `›` prompt (variations 4+5).
fn workingBlock(w: *Io.Writer, sw: engine_events.StandingWork, cols: usize) !void {
    if (!workingActive(sw)) return;
    try writeRule(w, cols);
    try w.print("{s}WORKING", .{style.dim});
    if (sw.goal_status.len > 0) try w.print(" ({s})", .{sw.goal_status});
    try w.print("{s}\n", .{style.reset});
    if (sw.goal.len > 0) {
        const clip = util.utf8Prefix(sw.goal, if (cols > 8) cols - 2 else 40);
        try w.print("{s}{s}{s}\n", .{ style.accent, clip, style.reset });
    }
    if (sw.todos_total > 0) {
        try w.print("{s}{d} of {d}{s}\n", .{ style.dim, sw.todos_done, sw.todos_total, style.reset });
        for (sw.todos) |t| {
            if (t.done) {
                try w.print("{s}✓{s} {s}\n", .{ style.green, style.reset, t.content });
            } else {
                try w.print("{s}○{s} {s}\n", .{ style.dim, style.reset, t.content });
            }
        }
    }
    try writeRule(w, cols);
}

fn line(w: *Io.Writer, st: PromptStatus, cols: usize) !void {
    try w.writeByte('\n');
    try workingBlock(w, st.standing, cols);

    var cbuf: [24]u8 = undefined;
    const cost: []const u8 = switch (st.cost) {
        .hidden => "",
        .subscription => "sub",
        .unpriced => "$?",
        .usd => |usd| std.fmt.bufPrint(&cbuf, "${d:.2}", .{usd}) catch "",
    };
    var ctxbuf: [24]u8 = undefined;
    const ctx: []const u8 = if (st.context) |meter|
        (std.fmt.bufPrint(&ctxbuf, "ctx {d}%", .{contextPercent(meter.tokens, meter.window)}) catch "")
    else
        "";
    var resumebuf: [24]u8 = undefined;
    const resume_hint: []const u8 = if (st.saved_sessions > 0)
        (std.fmt.bufPrint(&resumebuf, "/resume {d}", .{st.saved_sessions}) catch "")
    else
        "";

    // Dim meter above a bare `›`. Operational badges (Fast/Plan/Strict)
    // stay; cwd and the old bracket frame do not — they competed with input.
    // #209: drop from the right so a narrow pane never splits a label.
    const avail = cols -| 1;
    var used: usize = st.model.len;
    const show_fast = st.fast and fitsSegment(&used, avail, 3 + "Fast".len);
    const show_effort = st.effort != null and
        fitsSegment(&used, avail, 3 + reasoningLabel(st.effort.?).len);
    const show_fallback = st.fallback and
        fitsSegment(&used, avail, 3 + "Fallback".len);
    const show_plan = st.plan and fitsSegment(&used, avail, 3 + "Plan".len);
    const show_strict = st.strict and fitsSegment(&used, avail, 3 + "Strict".len);
    const show_ultra = st.ultracode and fitsSegment(&used, avail, 3 + "Ultracode".len);
    const show_ctx = ctx.len > 0 and fitsSegment(&used, avail, 3 + ctx.len);
    const show_cost = cost.len > 0 and fitsSegment(&used, avail, 3 + cost.len);
    const show_resume = resume_hint.len > 0 and fitsSegment(&used, avail, 3 + resume_hint.len);
    const show_image = st.standing.image and fitsSegment(&used, avail, 3 + "image".len);
    const show_session = st.standing.session.len > 0 and
        fitsSegment(&used, avail, 3 + st.standing.session.len);

    try w.print("{s}{s}", .{ style.dim, st.model });
    if (show_fast) try w.print(" · Fast", .{});
    if (show_effort) try w.print(" · {s}", .{reasoningLabel(st.effort.?)});
    if (show_fallback) try w.print(" · Fallback", .{});
    if (show_plan) try w.print(" · Plan", .{});
    if (show_strict) try w.print(" · Strict", .{});
    if (show_ultra) try w.print(" · Ultracode", .{});
    if (show_ctx) try w.print(" · {s}", .{ctx});
    if (show_cost) try w.print(" · {s}", .{cost});
    if (show_resume) try w.print(" · {s}", .{resume_hint});
    if (show_image) try w.print(" · image", .{});
    if (show_session) try w.print(" · {s}", .{st.standing.session});
    try w.print("{s}\n{s}{s}›{s} ", .{ style.reset, style.bold, style.accent, style.reset });
    try w.flush();
}

test "reasoning prompt label uses picker wording" {
    const Effort = enum { low, medium, high, xhigh, max, ultra };
    try std.testing.expectEqualStrings("Low", reasoningLabel(Effort.low));
    try std.testing.expectEqualStrings("Medium", reasoningLabel(Effort.medium));
    try std.testing.expectEqualStrings("High", reasoningLabel(Effort.high));
    try std.testing.expectEqualStrings("Extra high", reasoningLabel(Effort.xhigh));
    try std.testing.expectEqualStrings("Max", reasoningLabel(Effort.max));
    try std.testing.expectEqualStrings("Ultra", reasoningLabel(Effort.ultra));
}

test "compact token counts keep prompt usage readable" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("999", compactTokenCount(&buf, 999));
    try std.testing.expectEqualStrings("138k", compactTokenCount(&buf, 138_082));
}

test "context percent saturates malformed or over-window server meters" {
    try std.testing.expectEqual(@as(u64, 0), contextPercent(100, 0));
    try std.testing.expectEqual(@as(u64, 50), contextPercent(50_000, 100_000));
    try std.testing.expectEqual(@as(u64, 100), contextPercent(150_000, 100_000));
    try std.testing.expectEqual(@as(u64, 100), contextPercent(std.math.maxInt(u64), 100_000));
}

test "fitsSegment charges the budget only on a fit, #209" {
    var used: usize = 10;
    try std.testing.expect(fitsSegment(&used, 20, 5)); // 10 + 5 <= 20
    try std.testing.expectEqual(@as(usize, 15), used);
    try std.testing.expect(!fitsSegment(&used, 20, 10)); // 15 + 10 > 20: rejected
    try std.testing.expectEqual(@as(usize, 15), used); // unchanged on rejection
    try std.testing.expect(fitsSegment(&used, 20, 5)); // exact fit still counts
    try std.testing.expectEqual(@as(usize, 20), used);
}

test "narrow pane drops cwd/context but keeps model+mode badges whole, #209" {
    // Reproduces the issue's 28-col tmux repro: `[gpt-5.6-sol · High · codex`
    // used to soft-wrap mid-badge because the status line never budgeted
    // against termCols(). Budgeting the same segment widths here must keep the
    // high-priority model/effort/provider badges intact and never let the
    // running total exceed the pane, while cwd/context (low priority) give way.
    const cols: usize = 28;
    const avail = cols -| 6; // fixed frame ('[' + '] › ') + 1 col slack
    var used: usize = "gpt-5.6-sol".len;
    const show_effort = fitsSegment(&used, avail, 3 + "High".len);
    const show_provider = fitsSegment(&used, avail, 3 + "codex".len);
    const show_cwd = fitsSegment(&used, avail, 7 + "/path/to/project".len);
    const show_ctx = fitsSegment(&used, avail, " · 12k/100k ctx (12% · compact@80k)".len);
    try std.testing.expect(show_effort);
    try std.testing.expect(used <= avail); // never overflows the pane itself
    _ = show_provider; // may or may not fit at this extreme width; never split either way
    try std.testing.expect(!show_cwd); // low-priority metadata is the first to go
    try std.testing.expect(!show_ctx);
}

test "wide pane keeps every segment, matching the pre-#209 behaviour" {
    // A generous pane must still show everything, proving the budget is real
    // width-awareness and not an unconditional strip of metadata.
    const cols: usize = 200;
    const avail = cols -| 6;
    var used: usize = "gpt-5.6-sol".len;
    try std.testing.expect(fitsSegment(&used, avail, 3 + "High".len));
    try std.testing.expect(fitsSegment(&used, avail, 3 + "codex".len));
    try std.testing.expect(fitsSegment(&used, avail, 7 + "/path/to/project".len));
    try std.testing.expect(fitsSegment(&used, avail, " · 12k/100k ctx (12% · compact@80k)".len));
}

/// The status line as a plain-terminal reader sees it. Pins the exact bytes the
/// pre-#429 inline path produced, so the move behind the sink cannot quietly
/// reword, reorder or re-space a segment.
fn renderPlain(buf: *Io.Writer.Allocating, st: PromptStatus) []const u8 {
    line(&buf.writer, st, 400) catch unreachable; // a pane wide enough to keep everything
    return buf.writer.buffered();
}

test "batch 3: every status-line segment renders exactly as it did inline" {
    const saved = style.*;
    style.* = .{}; // assert the text, not the palette
    defer style.* = saved;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    // A wide pane keeps everything: model, every badge, cwd, meter, cache, cost.
    const full: PromptStatus = .{
        .model = "gpt-5.6",
        .provider_id = "codex",
        .cwd = "~/src/graff",
        .privacy_label = "Privacy:Aggregate",
        .privacy = .aggregate,
        .effort = .high,
        .context = .{ .tokens = 12_345, .window = 200_000, .compact_at = 160_000 },
        .cache_read = 2048,
        .cost = .{ .usd = 0.5 },
        .fast = true,
        .fallback = true,
        .plan = true,
        .strict = true,
        .ultracode = true,
    };
    try std.testing.expectEqualStrings(
        "\ngpt-5.6 · Fast · High · Fallback · Plan · Strict · Ultracode · ctx 6% · $0.50\n› ",
        renderPlain(&aw, full),
    );

    // The bare line: no usage yet, meter off, no optional badge.
    aw.clearRetainingCapacity();
    try std.testing.expectEqualStrings(
        "\nlmstudio\n› ",
        renderPlain(&aw, .{
            .model = "lmstudio",
            .provider_id = "lmstudio",
            .cwd = "/w",
            .privacy_label = "Privacy:Local",
            .privacy = .local,
        }),
    );

    // A flat-rate provider says so instead of showing a figure, and an
    // unpriced model admits it rather than printing a fabricated 0.0000.
    aw.clearRetainingCapacity();
    try std.testing.expectEqualStrings(
        "\nm · sub\n› ",
        renderPlain(&aw, .{
            .model = "m",
            .provider_id = "p",
            .cwd = "/w",
            .privacy_label = "Privacy:Local",
            .privacy = .local,
            .cost = .subscription,
        }),
    );
    aw.clearRetainingCapacity();
    try std.testing.expectEqualStrings(
        "\nm · $?\n› ",
        renderPlain(&aw, .{
            .model = "m",
            .provider_id = "p",
            .cwd = "/w",
            .privacy_label = "Privacy:Local",
            .privacy = .local,
            .cost = .unpriced,
        }),
    );
}

test "batch 3: a shrinking pane sheds segments in the #209 priority order" {
    // The budget is what a narrow tmux pane actually exercises, and it is the
    // part of this move most able to drift silently: assert the WHOLE line at
    // three widths rather than the fitsSegment arithmetic alone.
    const saved = style.*;
    style.* = .{};
    defer style.* = saved;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const st: PromptStatus = .{
        .model = "gpt-5.6",
        .provider_id = "codex",
        .cwd = "~/src/graff",
        .privacy_label = "Privacy:Local",
        .privacy = .local,
        .effort = .high,
        .context = .{ .tokens = 12_345, .window = 200_000, .compact_at = 160_000 },
        .cache_read = 2048,
        .cost = .unpriced,
    };
    const cases = [_]struct { cols: usize, want: []const u8 }{
        .{ .cols = 80, .want = "\ngpt-5.6 · High · ctx 6% · $?\n› " },
        .{ .cols = 28, .want = "\ngpt-5.6 · High · ctx 6%\n› " },
        .{ .cols = 18, .want = "\ngpt-5.6 · High\n› " },
    };
    for (cases) |c| {
        aw.clearRetainingCapacity();
        try line(&aw.writer, st, c.cols);
        try std.testing.expectEqualStrings(c.want, aw.writer.buffered());
    }
}

test "batch 3: the cache badge rides with the context meter, never alone" {
    // Both come from the same response's usage payload, and the pre-#209
    // layout never showed one without the other — a rule that lived in the
    // `show_ctx and …` gate and has to survive the move.
    const saved = style.*;
    style.* = .{};
    defer style.* = saved;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const out = renderPlain(&aw, .{
        .model = "m",
        .provider_id = "p",
        .cwd = "/w",
        .privacy_label = "Privacy:Local",
        .privacy = .local,
        .cache_read = 4096, // reported, but no context meter to ride with
    });
    try std.testing.expect(std.mem.indexOf(u8, out, "cached") == null);
}

test "WORKING block sits above a bare prompt and is skipped when empty" {
    const saved = style.*;
    style.* = .{};
    defer style.* = saved;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const bare: PromptStatus = .{
        .model = "m",
        .provider_id = "p",
        .cwd = "/w",
        .privacy_label = "Privacy:Local",
        .privacy = .local,
    };
    try std.testing.expectEqualStrings(
        "\nm\n› ",
        renderPlain(&aw, bare),
    );

    aw.clearRetainingCapacity();
    const items = [_]engine_events.StandingTodo{
        .{ .content = "inspect current prompt", .done = true },
        .{ .content = "update implementation", .done = false },
    };
    const full: PromptStatus = .{
        .model = "m",
        .provider_id = "p",
        .cwd = "/w",
        .privacy_label = "Privacy:Local",
        .privacy = .local,
        .standing = .{
            .session = "login-fix",
            .goal = "ship the repl standing line",
            .goal_status = "paused",
            .todos_done = 1,
            .todos_total = 2,
            .todos = &items,
            .image = true,
        },
    };
    try line(&aw.writer, full, 32);
    const rule = "────────────────────────────────";
    try std.testing.expectEqualStrings(
        "\n" ++ rule ++ "\nWORKING (paused)\nship the repl standing line\n1 of 2\n✓ inspect current prompt\n○ update implementation\n" ++
            rule ++ "\nm · image · login-fix\n› ",
        aw.writer.buffered(),
    );
}
