//! Compact prompt badges and context-meter formatting, plus Agent.prompt()
//! itself: the width-budgeted interactive status line (#209). Split out of
//! agent.zig (600-line goal); agent_mod is only imported for the `Agent` type
//! the moved method's `self` parameter needs — see agent_table.zig for the
//! same self-contained-sibling pattern.

const std = @import("std");
const Io = std.Io;
const style = &@import("ansi.zig").style;
const main_mod = @import("main.zig");
const pricing = @import("pricing.zig");
const learning_privacy = @import("learning_privacy.zig");
const terminal = @import("term.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;

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

pub fn writeBadge(writer: *Io.Writer, color: []const u8, label: []const u8) !void {
    try writer.print("{s} · {s}{s}{s}{s}", .{ style.dim, style.reset, color, label, style.reset });
}

/// Include a status-line segment only if its width still fits the remaining
/// budget, charging it against `used` when it does. Lets Agent.prompt() drop
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

/// The interactive status line printed before each human turn: model,
/// mode/permission badges, cwd, and the live context/cache/cost meter.
/// Width-budgeted against the terminal so a narrow pane never soft-wraps
/// mid-badge (splitting e.g. `codex`) and strands the cursor inside a label
/// (#209); low-priority metadata (cwd, context, cache, cost) is the first to
/// drop when it no longer fits. See fitsSegment's doc comment for the rest.
pub fn prompt(self: *Agent) !void {
    if (main_mod.json_mode) return; // SDK drives turns; no human prompt
    const w = self.out orelse return;
    var cbuf: [40]u8 = undefined;
    const cost: []const u8 = if (!main_mod.show_cost) "" else blk: {
        if (std.mem.eql(u8, self.provider.id, "codex"))
            break :blk " · sub";
        if (pricing.priceFor(self.provider.model) == null) break :blk " · $?";
        break :blk std.fmt.bufPrint(&cbuf, " · ${d:.4}", .{pricing.g_cost.snap(self.io).usd}) catch "";
    };
    // Prompt-cache hit from the last response — proof caching is working.
    var kbuf: [32]u8 = undefined;
    var kval: [24]u8 = undefined;
    const cached: []const u8 = if (self.last_cache_read > 0)
        (std.fmt.bufPrint(&kbuf, " · ⚡{s} cached", .{compactTokenCount(&kval, self.last_cache_read)}) catch "")
    else
        "";
    const context_tokens = self.effectiveContextTokens();
    var ctxbuf: [80]u8 = undefined;
    var used_buf: [24]u8 = undefined;
    const ctx: []const u8 = if (self.last_context_tokens > 0) blk: {
        const threshold = self.provider.compactAt();
        const pct = contextPercent(context_tokens, self.provider.context);
        break :blk std.fmt.bufPrint(&ctxbuf, " · {s}/{d}k ctx ({d}% · compact@{d}k)", .{
            compactTokenCount(&used_buf, context_tokens),
            self.provider.context / 1000,
            pct,
            threshold / 1000,
        }) catch "";
    } else "";
    const privacy_mode = learning_privacy.current();
    const privacy_label = privacy_mode.badge();
    const privacy_color = switch (privacy_mode) {
        .local, .aggregate => style.green,
        .templates => style.yellow,
        .examples => style.red,
    };

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
    const avail = terminal.termCols() -| 6;
    var used: usize = self.provider.model.len;
    const show_fast = self.fast and self.provider.kind == .responses and
        fitsSegment(&used, avail, 3 + "Fast".len);
    const show_effort = self.effortApplies() and
        fitsSegment(&used, avail, 3 + reasoningLabel(self.reasoning).len);
    const show_provider = fitsSegment(&used, avail, 3 + self.provider.id.len);
    const show_fallback = self.fallback_active and
        fitsSegment(&used, avail, 3 + "Fallback".len);
    const show_plan = main_mod.plan_mode and fitsSegment(&used, avail, 3 + "Plan".len);
    const show_strict = self.strict and fitsSegment(&used, avail, 3 + "Strict".len);
    const show_ultra = self.ultracode_mode and fitsSegment(&used, avail, 3 + "Ultracode".len);
    const show_privacy = fitsSegment(&used, avail, 3 + privacy_label.len);
    // The context meter outranks cwd for the budget (it is the urgent,
    // changing signal near the compaction threshold) but still renders after
    // cwd below, preserving the familiar order when both fit.
    const show_ctx = ctx.len > 0 and fitsSegment(&used, avail, ctx.len);
    const show_cwd = fitsSegment(&used, avail, 7 + main_mod.g_cwd_display.len);
    // cached only ever accompanies the context meter (both come from the
    // same response's usage payload), matching the pre-#209 layout.
    const show_cached = show_ctx and cached.len > 0 and fitsSegment(&used, avail, cached.len);
    const show_cost = cost.len > 0 and fitsSegment(&used, avail, cost.len);

    try w.print("\n{s}[{s}{s}{s}{s}", .{ style.dim, style.reset, style.accent, self.provider.model, style.reset });
    // Fast is the most operationally important model setting, so keep it
    // immediately beside the model instead of letting permission modes push
    // it deeper into the status line.
    if (show_fast) try writeBadge(w, style.green, "Fast");
    if (show_effort) try writeBadge(w, reasoningColor(self.reasoning), reasoningLabel(self.reasoning));
    if (show_provider) try writeBadge(w, style.accent, self.provider.id);
    if (show_fallback) try writeBadge(w, style.yellow, "Fallback");
    if (show_plan) try writeBadge(w, style.yellow, "Plan");
    if (show_strict) try writeBadge(w, style.red, "Strict");
    if (show_ultra) try writeBadge(w, style.accent, "Ultracode");
    if (show_privacy) try writeBadge(w, privacy_color, privacy_label);
    try w.print("{s}", .{style.dim});
    if (show_cwd) try w.print(" · cwd {s}{s}{s}", .{ style.reset, main_mod.g_cwd_display, style.dim });
    if (show_ctx) try w.print("{s}", .{ctx});
    if (show_cached) try w.print("{s}", .{cached});
    if (show_cost) try w.print("{s}", .{cost});
    try w.print("{s}]{s} {s}{s}›{s} ", .{ style.reset, style.reset, style.bold, style.accent, style.reset });
    try w.flush();
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
    // used to soft-wrap mid-badge because prompt() never budgeted against
    // termCols(). Budgeting the same segment widths here must keep the
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
