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

fn privacyColor(tier: engine_events.PrivacyTier) []const u8 {
    return switch (tier) {
        .local, .aggregate => style.green,
        .templates => style.yellow,
        .examples => style.red,
    };
}

pub fn writeBadge(writer: *Io.Writer, color: []const u8, label: []const u8) !void {
    try writer.print("{s} · {s}{s}{s}{s}", .{ style.dim, style.reset, color, label, style.reset });
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

fn standingActive(sw: engine_events.StandingWork) bool {
    return sw.goal.len > 0 or sw.todos_total > 0 or sw.image or sw.session.len > 0;
}

/// Dim row above `[model] ›` when the session has standing work. Drops from
/// the right on a narrow pane (same #209 rule as the badges): Goal first,
/// then the checklist, then the staged-image hint, then the session name.
fn standingLine(w: *Io.Writer, sw: engine_events.StandingWork, cols: usize) !void {
    if (!standingActive(sw)) return;
    var parts: [4][]const u8 = undefined;
    var n: usize = 0;
    var goal_buf: [80]u8 = undefined;
    if (sw.goal.len > 0) {
        const clip = util.utf8Prefix(sw.goal, 40);
        parts[n] = if (sw.goal_status.len > 0)
            (std.fmt.bufPrint(&goal_buf, "Goal ({s})  {s}", .{ sw.goal_status, clip }) catch "Goal")
        else
            (std.fmt.bufPrint(&goal_buf, "Goal  {s}", .{clip}) catch "Goal");
        n += 1;
    }
    var todo_buf: [24]u8 = undefined;
    if (sw.todos_total > 0) {
        parts[n] = std.fmt.bufPrint(&todo_buf, "{d}/{d} todos", .{ sw.todos_done, sw.todos_total }) catch "";
        n += 1;
    }
    if (sw.image) {
        parts[n] = "image ready";
        n += 1;
    }
    if (sw.session.len > 0) {
        parts[n] = sw.session;
        n += 1;
    }

    // Two-space indent + the first segment, then ` · ` between survivors.
    const avail = if (cols > 2) cols - 2 else 0;
    var used: usize = 0;
    var show: usize = 0;
    while (show < n) : (show += 1) {
        const extra = if (show == 0) parts[show].len else 3 + parts[show].len;
        if (used + extra > avail) break;
        used += extra;
    }
    if (show == 0) return; // even the Goal clip will not fit — skip the row

    try w.print("{s}  ", .{style.dim});
    var i: usize = 0;
    while (i < show) : (i += 1) {
        if (i > 0) try w.writeAll(" · ");
        if (i == 0 and sw.goal.len > 0) {
            try w.print("{s}{s}{s}{s}", .{ style.reset, style.accent, parts[i], style.dim });
        } else {
            try w.writeAll(parts[i]);
        }
    }
    try w.print("{s}\n", .{style.reset});
}

fn line(w: *Io.Writer, st: PromptStatus, cols: usize) !void {
    try w.writeByte('\n');
    try standingLine(w, st.standing, cols);
    var cbuf: [40]u8 = undefined;
    const cost: []const u8 = switch (st.cost) {
        .hidden => "",
        .subscription => " · sub",
        .unpriced => " · $?",
        .usd => |usd| std.fmt.bufPrint(&cbuf, " · ${d:.4}", .{usd}) catch "",
    };
    // Prompt-cache hit from the last response — proof caching is working.
    var kbuf: [32]u8 = undefined;
    var kval: [24]u8 = undefined;
    const cached: []const u8 = if (st.cache_read > 0)
        (std.fmt.bufPrint(&kbuf, " · ⚡{s} cached", .{compactTokenCount(&kval, st.cache_read)}) catch "")
    else
        "";
    var ctxbuf: [80]u8 = undefined;
    var used_buf: [24]u8 = undefined;
    const ctx: []const u8 = if (st.context) |meter|
        (std.fmt.bufPrint(&ctxbuf, " · {s}/{d}k ctx ({d}% · compact@{d}k)", .{
            compactTokenCount(&used_buf, meter.tokens),
            meter.window / 1000,
            contextPercent(meter.tokens, meter.window),
            meter.compact_at / 1000,
        }) catch "")
    else
        "";

    // Budget the status line against terminal width so a narrow pane never
    // soft-wraps mid-badge (splitting e.g. `codex`) and strands the cursor
    // inside a label (#209). The model plus the badges that disambiguate the
    // cursor (effort/provider/mode/privacy) are offered first; cwd/context/
    // cache/cost are the first to drop when they no longer fit. readline.zig
    // still gives the input its own row if what remains is cramped. Byte
    // length (not display-column width) is used as the budget metric: for
    // UTF-8 it is always >= true display width, so the estimate only ever
    // errs conservative and can't itself cause an overflow/wrap.
    //
    // Reserve the fixed frame ('[' + '] › ' = 5 cols) plus 1 column of slack
    // so a width miscount can't tip the line into a wrap.
    const avail = cols -| 6;
    var used: usize = st.model.len;
    const show_fast = st.fast and fitsSegment(&used, avail, 3 + "Fast".len);
    const show_effort = st.effort != null and
        fitsSegment(&used, avail, 3 + reasoningLabel(st.effort.?).len);
    const show_provider = fitsSegment(&used, avail, 3 + st.provider_id.len);
    const show_fallback = st.fallback and
        fitsSegment(&used, avail, 3 + "Fallback".len);
    const show_plan = st.plan and fitsSegment(&used, avail, 3 + "Plan".len);
    const show_strict = st.strict and fitsSegment(&used, avail, 3 + "Strict".len);
    const show_ultra = st.ultracode and fitsSegment(&used, avail, 3 + "Ultracode".len);
    const show_privacy = fitsSegment(&used, avail, 3 + st.privacy_label.len);
    // The context meter outranks cwd for the budget (it is the urgent,
    // changing signal near the compaction threshold) but still renders after
    // cwd below, preserving the familiar order when both fit.
    const show_ctx = ctx.len > 0 and fitsSegment(&used, avail, ctx.len);
    const show_cwd = fitsSegment(&used, avail, 7 + st.cwd.len);
    // cached only ever accompanies the context meter (both come from the
    // same response's usage payload), matching the pre-#209 layout.
    const show_cached = show_ctx and cached.len > 0 and fitsSegment(&used, avail, cached.len);
    const show_cost = cost.len > 0 and fitsSegment(&used, avail, cost.len);

    try w.print("{s}[{s}{s}{s}{s}", .{ style.dim, style.reset, style.accent, st.model, style.reset });
    // Fast is the most operationally important model setting, so keep it
    // immediately beside the model instead of letting permission modes push
    // it deeper into the status line.
    if (show_fast) try writeBadge(w, style.green, "Fast");
    if (show_effort) try writeBadge(w, reasoningColor(st.effort.?), reasoningLabel(st.effort.?));
    if (show_provider) try writeBadge(w, style.accent, st.provider_id);
    if (show_fallback) try writeBadge(w, style.yellow, "Fallback");
    if (show_plan) try writeBadge(w, style.yellow, "Plan");
    if (show_strict) try writeBadge(w, style.red, "Strict");
    if (show_ultra) try writeBadge(w, style.accent, "Ultracode");
    if (show_privacy) try writeBadge(w, privacyColor(st.privacy), st.privacy_label);
    try w.print("{s}", .{style.dim});
    if (show_cwd) try w.print(" · cwd {s}{s}{s}", .{ style.reset, st.cwd, style.dim });
    if (show_ctx) try w.print("{s}", .{ctx});
    if (show_cached) try w.print("{s}", .{cached});
    if (show_cost) try w.print("{s}", .{cost});
    try w.print("{s}]{s} {s}{s}›{s} ", .{ style.reset, style.reset, style.bold, style.accent, style.reset });
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
        "\n[gpt-5.6 · Fast · High · codex · Fallback · Plan · Strict · Ultracode · Privacy:Aggregate" ++
            " · cwd ~/src/graff · 12k/200k ctx (6% · compact@160k) · ⚡2k cached · $0.5000] › ",
        renderPlain(&aw, full),
    );

    // The bare line: no usage yet, no cache, meter off, no optional badge.
    aw.clearRetainingCapacity();
    try std.testing.expectEqualStrings(
        "\n[lmstudio · lmstudio · Privacy:Local · cwd /w] › ",
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
        "\n[m · p · Privacy:Local · cwd /w · sub] › ",
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
        "\n[m · p · Privacy:Local · cwd /w · $?] › ",
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
        // Roomy: everything, in the familiar order (cwd before the meter).
        .{ .cols = 130, .want = "\n[gpt-5.6 · High · codex · Privacy:Local · cwd ~/src/graff · 12k/200k ctx (6% · compact@160k) · ⚡2k cached · $?] › " },
        // Tighter: cwd is the first to go, but the meter it outranks stays.
        .{ .cols = 90, .want = "\n[gpt-5.6 · High · codex · Privacy:Local · 12k/200k ctx (6% · compact@160k) · $?] › " },
        // Cramped: the meter goes too, and the cache badge goes with it
        // rather than floating free of the usage it came from.
        .{ .cols = 50, .want = "\n[gpt-5.6 · High · codex · Privacy:Local · $?] › " },
        // Pathological: only the badges that disambiguate the cursor survive,
        // and never a half-drawn one.
        .{ .cols = 28, .want = "\n[gpt-5.6 · High · codex] › " },
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

test "standing row sits above the model prompt and is skipped when empty" {
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
        "\n[m · p · Privacy:Local · cwd /w] › ",
        renderPlain(&aw, bare),
    );

    aw.clearRetainingCapacity();
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
            .image = true,
        },
    };
    try line(&aw.writer, full, 100);
    try std.testing.expectEqualStrings(
        "\n  Goal (paused)  ship the repl standing line · 1/2 todos · image ready · login-fix\n" ++
            "[m · p · Privacy:Local · cwd /w] › ",
        aw.writer.buffered(),
    );
}

test "standing row drops session then image then todos on a narrow pane" {
    const saved = style.*;
    style.* = .{};
    defer style.* = saved;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const st: PromptStatus = .{
        .model = "m",
        .provider_id = "p",
        .cwd = "/w",
        .privacy_label = "Privacy:Local",
        .privacy = .local,
        .standing = .{
            .session = "login-fix",
            .goal = "ship it",
            .todos_done = 1,
            .todos_total = 2,
            .image = true,
        },
    };
    // Room for Goal + checklist only (image + session drop). The model
    // badges still keep privacy at this width; cwd is the first to go.
    try line(&aw.writer, st, 36);
    try std.testing.expectEqualStrings(
        "\n  Goal  ship it · 1/2 todos\n[m · p · Privacy:Local · cwd /w] › ",
        aw.writer.buffered(),
    );
    aw.clearRetainingCapacity();
    try line(&aw.writer, st, 26);
    try std.testing.expectEqualStrings(
        "\n  Goal  ship it\n[m · p · cwd /w] › ",
        aw.writer.buffered(),
    );
}
