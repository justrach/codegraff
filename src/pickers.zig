//! Interactive fuzzy pickers (the /model picker + the generic listPicker
//! used by /resume, /login, the bare "/" command menu, etc.), the fuzzy
//! match/score/sort primitives behind them, ultracode steering + its on/off
//! toggle picker, and the slash-command menu. The model picker's provider
//! authentication flow lives in picker_auth.zig. Split out of main.zig
//! (600-line goal).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const ansi = @import("ansi.zig");
const style = &ansi.style;

const term = @import("term.zig");
const tty = term.tty;

const pricing = @import("pricing.zig");
const billing = @import("billing.zig");
const models_rank = @import("models_rank");

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const Agent = agent_mod.Agent;
const Keys = provider_mod.Keys;
const command_catalog = @import("command_catalog.zig");
const picker_auth = @import("picker_auth.zig");
const util = @import("util.zig");
const shapes = @import("shapes.zig");
const editByte = @import("input_util.zig").editByte; // #396: job-control-aware key reads

/// Case-insensitive subsequence match (fzf-style): every char of `needle`
/// appears in `hay` in order, gaps allowed — so "gpt5.5" matches "gpt-5.5".
fn fuzzySubseq(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var ni: usize = 0;
    for (hay) |hc| {
        if (std.ascii.toLower(hc) == std.ascii.toLower(needle[ni])) {
            ni += 1;
            if (ni == needle.len) return true;
        }
    }
    return false;
}

/// Rank a fuzzy match (higher = better). Prefix > substring > subsequence.
/// Separators fold so "5.6 sol" matches `gpt-5.6-sol`.
fn fuzzyScore(hay: []const u8, needle: []const u8) ?i32 {
    if (needle.len == 0) return 0;
    if (scoreFolded(hay, needle)) |s| return s;
    var hb: [256]u8 = undefined;
    var nb: [128]u8 = undefined;
    return scoreFolded(foldSeps(&hb, hay), foldSeps(&nb, needle));
}

fn foldSeps(dst: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |c| {
        if (c == '-' or c == '_' or c == ' ' or c == '.' or c == '/' or n >= dst.len) continue;
        dst[n] = std.ascii.toLower(c);
        n += 1;
    }
    return dst[0..n];
}

fn scoreFolded(hay: []const u8, needle: []const u8) ?i32 {
    if (needle.len == 0) return 0;
    if (needle.len > hay.len) return null;
    const len_pen: i32 = @intCast(@min(hay.len, 200));
    const base = if (std.mem.lastIndexOfScalar(u8, hay, '/')) |sl| sl + 1 else 0;
    if (std.ascii.startsWithIgnoreCase(hay[base..], needle) or
        std.ascii.startsWithIgnoreCase(hay, needle)) return 300_000 - len_pen;
    if (util.indexOfIgnoreCase(hay, needle)) |p| {
        const pos_pen: i32 = @intCast(@min(p, 1000));
        return 200_000 - pos_pen * 10 - len_pen;
    }
    if (fuzzySubseq(hay, needle)) return 100_000 - len_pen;
    return null;
}

/// Score a PickItem against a query: a name match always outranks a
/// desc-only match (the +1_000_000 tier gap dominates any name score).
fn pickScore(item: PickItem, q: []const u8) ?i32 {
    if (fuzzyScore(item.name, q)) |s| return s + 1_000_000;
    return fuzzyScore(item.desc, q);
}

/// Picker ranking entry: original item index + its pickScore/fuzzyScore.
const Scored = struct { idx: usize, score: i32 };

/// Sort order for picker results: best score first, ties keep item order.
fn scoredLess(_: void, a: Scored, b: Scored) bool {
    if (a.score != b.score) return a.score > b.score;
    return a.idx < b.idx;
}

const ModelPickerLayout = struct {
    visible: usize,
    name_width: usize,
    provider_width: usize,
    context_width: usize,
    show_context: bool,
    compact_context: bool,
};

const ListPickerLayout = struct {
    visible: usize,
    name_width: usize,
    desc_width: usize,
    show_desc: bool,
};

/// Leave room for the picker title/counter/header/footer instead of painting a
/// fixed 18 rows past the bottom of short terminals.
fn visibleRows(rows: usize, chrome_rows: usize) usize {
    if (rows <= chrome_rows) return 1;
    return @min(@as(usize, 18), rows - chrome_rows);
}

fn modelPickerLayout(rows: usize, cols: usize) ModelPickerLayout {
    // Avoid the terminal's rightmost column: many terminals defer an automatic
    // wrap there, which makes the following newline consume an extra row.
    const budget = if (cols > 1) cols - 1 else 1;
    const show_context = budget >= 34;
    const compact_context = budget < 52;
    const provider_width = @min(@as(usize, 11), @max(@as(usize, 3), budget / 4));
    const context_width: usize = if (!show_context) 0 else if (compact_context) 7 else 13;
    const fixed = 2 + provider_width + (if (show_context) context_width + 2 else 3);
    const name_width = @min(@as(usize, 26), if (budget > fixed) budget - fixed else 1);
    return .{
        .visible = visibleRows(rows, 4),
        .name_width = name_width,
        .provider_width = provider_width,
        .context_width = context_width,
        .show_context = show_context,
        .compact_context = compact_context,
    };
}

fn listPickerLayout(rows: usize, cols: usize) ListPickerLayout {
    const budget = if (cols > 1) cols - 1 else 1;
    const show_desc = budget >= 32;
    const name_width = if (show_desc)
        @min(@as(usize, 24), @max(@as(usize, 12), budget / 3))
    else if (budget > 1)
        budget - 1
    else
        1;
    return .{
        .visible = visibleRows(rows, 3),
        .name_width = name_width,
        .desc_width = if (show_desc and budget > name_width + 2) budget - name_width - 2 else 0,
        .show_desc = show_desc,
    };
}

fn visibleLen(text: []const u8) usize {
    var columns: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (columns += 1) {
        i += std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
    }
    return columns;
}

fn prefixBytes(text: []const u8, columns: usize) usize {
    var seen: usize = 0;
    var i: usize = 0;
    while (i < text.len and seen < columns) : (seen += 1) {
        i += std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
    }
    return @min(i, text.len);
}

/// Write one plain-text table cell at exactly `width` visible columns,
/// truncating by UTF-8 codepoint and reserving the final column for an ellipsis.
fn writeCell(out: *Io.Writer, text: []const u8, width: usize) void {
    if (width == 0) return;
    const len = visibleLen(text);
    if (len <= width) {
        out.writeAll(text) catch return;
        for (len..width) |_| out.writeByte(' ') catch return;
        return;
    }
    if (width > 1) out.writeAll(text[0..prefixBytes(text, width - 1)]) catch return;
    out.writeAll("…") catch return;
}

/// Byte index where the last `columns` visible columns begin — the
/// forward-scan mirror of prefixBytes, so the slice keeps whole codepoints.
fn tailBytes(text: []const u8, columns: usize) usize {
    const total = visibleLen(text);
    if (total <= columns) return 0;
    var seen: usize = 0;
    var i: usize = 0;
    const skip = total - columns;
    while (i < text.len and seen < skip) : (seen += 1) {
        i += std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
    }
    return i;
}

/// writeCell for identifiers whose distinguishing part is the TAIL — model
/// ids like `accounts/fireworks/models/deepseek-v4-pro`, which right-
/// truncation renders identical (`accounts/fireworks/models…`) for every
/// model a provider serves. Over-long text keeps its last width-1 columns
/// behind the ellipsis: `…s/deepseek-v4-pro`.
fn writeCellTail(out: *Io.Writer, text: []const u8, width: usize) void {
    if (width == 0) return;
    if (visibleLen(text) <= width) {
        writeCell(out, text, width);
        return;
    }
    if (width > 1) {
        out.writeAll("…") catch return;
        out.writeAll(text[tailBytes(text, width - 1)..]) catch return;
    } else out.writeAll("…") catch return;
}

fn writeClipped(out: *Io.Writer, text: []const u8, width: usize) void {
    if (visibleLen(text) <= width) {
        out.writeAll(text) catch {};
    } else if (width > 0) {
        if (width > 1) out.writeAll(text[0..prefixBytes(text, width - 1)]) catch return;
        out.writeAll("…") catch {};
    }
}

/// Interactive fuzzy model picker for a bare `/model` (codegraff-style). Opens
/// a full-screen alternate buffer: type to filter, ↑/↓ to move, Enter to pick,
/// Ctrl-C to cancel. Returns the chosen model_table index, or null.
pub fn modelPicker(root: *Agent, keys: *Keys, arena: Allocator, out: *Io.Writer) ?usize {
    const model_table = pricing.models();
    const in = root.in orelse return null;
    const raw_state = tty.enterRaw(true) orelse return null;
    defer tty.restore(raw_state);
    out.writeAll("\x1b[?1049h") catch {}; // alternate screen
    defer {
        out.writeAll("\x1b[?1049l") catch {};
        out.flush() catch {};
    }

    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(arena);
    var scored: std.ArrayList(Scored) = .empty;
    defer scored.deinit(arena);
    var filtered: std.ArrayList(usize) = .empty;
    defer filtered.deinit(arena);
    var sel: usize = 0;
    var select_current = true;

    while (true) {
        const layout = modelPickerLayout(term.termRows(), term.termCols());
        filtered.clearRetainingCapacity();
        scored.clearRetainingCapacity();
        // Same election as the TUI overlay and `/models` (models_rank.zig):
        // keyed plan, then local, then credits, then api; keyless rows trail.
        for (model_table, 0..) |m, i| {
            if (pickScore(.{ .name = m.name, .desc = m.provider }, query.items)) |s| {
                const has_key = keys.get(m.provider) != null;
                const seat = billing.costFor(m.provider, keys.source(m.provider));
                scored.append(arena, .{ .idx = i, .score = s + models_rank.electionRank(has_key, seat) }) catch {};
            }
        }
        std.mem.sort(Scored, scored.items, {}, scoredLess);
        for (scored.items) |s| filtered.append(arena, s.idx) catch {};
        if (filtered.items.len == 0) sel = 0 else if (sel >= filtered.items.len) sel = filtered.items.len - 1;
        if (select_current) {
            for (filtered.items, 0..) |model_idx, row| {
                const m = model_table[model_idx];
                if (std.mem.eql(u8, m.name, root.provider.model) and std.mem.eql(u8, m.provider, root.provider.id)) {
                    sel = row;
                    break;
                }
            }
            select_current = false;
        }

        out.writeAll("\x1b[2J\x1b[H") catch {};
        out.print("{s}Model ›{s} {s}\n", .{ style.accent, style.reset, query.items }) catch {};
        out.print("{s}{d}/{d}{s}\n", .{ style.dim, filtered.items.len, model_table.len, style.reset }) catch {};
        out.writeAll(style.dim) catch {};
        out.writeAll("  ") catch {};
        writeCell(out, "MODEL", layout.name_width);
        out.writeByte(' ') catch {};
        writeCell(out, "PROVIDER", layout.provider_width);
        if (layout.show_context) {
            out.writeByte(' ') catch {};
            writeCell(out, if (layout.compact_context) "CTX/KEY" else "CTX", layout.context_width);
        }
        out.print("{s}\n", .{style.reset}) catch {};
        const off = if (sel >= layout.visible) sel - layout.visible + 1 else 0;
        var row = off;
        while (row < filtered.items.len and row < off + layout.visible) : (row += 1) {
            const m = model_table[filtered.items[row]];
            const cur = std.mem.eql(u8, m.name, root.provider.model) and std.mem.eql(u8, m.provider, root.provider.id);
            const keyed = keys.get(m.provider) != null;
            const context = pricing.contextFor(m.provider, m.name);
            if (row == sel) out.writeAll(style.accent) catch {};
            out.print("{s} ", .{if (row == sel) "›" else if (cur) "▌" else " "}) catch {};
            writeCellTail(out, m.name, layout.name_width); // path-like ids (fireworks) differ only at the tail
            out.writeByte(' ') catch {};
            writeCell(out, m.provider, layout.provider_width);
            if (layout.show_context) {
                out.writeByte(' ') catch {};
                var context_buf: [32]u8 = undefined;
                const context_text = if (layout.compact_context)
                    std.fmt.bufPrint(&context_buf, "{d}k{s}", .{ context / 1000, if (keyed) "" else " !" }) catch "?"
                else
                    std.fmt.bufPrint(&context_buf, "{d}k{s}", .{ context / 1000, if (keyed) "" else " ·no key" }) catch "?";
                writeCell(out, context_text, layout.context_width);
            } else if (!keyed) {
                // Preserve the keyless warning even when CTX is hidden.
                out.writeAll(" !") catch {};
            }
            if (row == sel) out.writeAll(style.reset) catch {};
            out.writeByte('\n') catch {};
        }
        out.writeAll(style.dim) catch {};
        writeClipped(out, "↑/↓ move · type to filter · Enter switch · Ctrl-C cancel", if (term.termCols() > 1) term.termCols() - 1 else 1);
        out.writeAll(style.reset) catch {};
        out.flush() catch {};

        const ch = editByte(in) orelse return null;
        switch (ch) {
            '\r', '\n' => return if (filtered.items.len > 0) filtered.items[sel] else null,
            0x03, 0x07 => return null, // Ctrl-C / Ctrl-G
            0x7f, 0x08 => if (query.items.len > 0) {
                query.shrinkRetainingCapacity(query.items.len - 1);
                sel = 0;
            },
            0x1b => {
                if ((editByte(in) orelse return null) != '[') continue;
                switch (editByte(in) orelse return null) {
                    'A' => if (sel > 0) {
                        sel -= 1;
                    },
                    'B' => if (sel + 1 < filtered.items.len) {
                        sel += 1;
                    },
                    else => {},
                }
            },
            else => if (ch >= 0x20) {
                query.append(arena, ch) catch {};
                sel = 0;
            },
        }
    }
}

pub const PickItem = command_catalog.Item;

/// Generic full-screen fuzzy picker (same UI as the /model picker): type to
/// filter on name or description, ↑/↓ to move, Enter picks, Ctrl-C cancels.
/// Returns the index into `items`, or null.
pub fn listPicker(root: *Agent, arena: Allocator, out: *Io.Writer, title: []const u8, items: []const PickItem) ?usize {
    return listPickerAt(root, arena, out, title, items, 0);
}

/// listPicker with an initially selected row (used by settings pickers to
/// highlight the current value while retaining the canonical list order).
pub fn listPickerAt(root: *Agent, arena: Allocator, out: *Io.Writer, title: []const u8, items: []const PickItem, initial: usize) ?usize {
    const in = root.in orelse return null;
    if (items.len == 0) return null;
    const raw_state = tty.enterRaw(true) orelse return null;
    defer tty.restore(raw_state);
    out.writeAll("\x1b[?1049h") catch {}; // alternate screen
    defer {
        out.writeAll("\x1b[?1049l") catch {};
        out.flush() catch {};
    }

    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(arena);
    var scored: std.ArrayList(Scored) = .empty;
    defer scored.deinit(arena);
    var filtered: std.ArrayList(usize) = .empty;
    defer filtered.deinit(arena);
    var sel: usize = @min(initial, items.len - 1);

    while (true) {
        const layout = listPickerLayout(term.termRows(), term.termCols());
        // Score every item against the query and rank: best match on top
        // (ties keep the original item order). An empty query scores all
        // items 0, so the list stays in its given order.
        scored.clearRetainingCapacity();
        for (items, 0..) |item, i| {
            if (pickScore(item, query.items)) |s|
                scored.append(arena, .{ .idx = i, .score = s }) catch {};
        }
        std.mem.sort(Scored, scored.items, {}, scoredLess);
        filtered.clearRetainingCapacity();
        for (scored.items) |s| filtered.append(arena, s.idx) catch {};
        if (filtered.items.len == 0) sel = 0 else if (sel >= filtered.items.len) sel = filtered.items.len - 1;

        out.writeAll("\x1b[2J\x1b[H") catch {};
        out.print("{s}{s}{s} {s}\n", .{ style.accent, title, style.reset, query.items }) catch {};
        out.print("{s}{d}/{d}{s}\n", .{ style.dim, filtered.items.len, items.len, style.reset }) catch {};
        const off = if (sel >= layout.visible) sel - layout.visible + 1 else 0;
        var row = off;
        while (row < filtered.items.len and row < off + layout.visible) : (row += 1) {
            const item = items[filtered.items[row]];
            if (row == sel) out.writeAll(style.accent) catch {};
            out.print("{s} ", .{if (row == sel) "›" else " "}) catch {};
            writeCell(out, item.name, if (layout.name_width > 1) layout.name_width - 1 else 1);
            if (row == sel) out.writeAll(style.reset) catch {};
            if (layout.show_desc) {
                out.print(" {s}", .{style.dim}) catch {};
                writeCell(out, item.desc, layout.desc_width);
                out.writeAll(style.reset) catch {};
            }
            out.writeByte('\n') catch {};
        }
        out.writeAll(style.dim) catch {};
        writeClipped(out, "↑/↓ move · type to filter · Enter pick · Ctrl-C cancel", if (term.termCols() > 1) term.termCols() - 1 else 1);
        out.writeAll(style.reset) catch {};
        out.flush() catch {};

        const ch = editByte(in) orelse return null;
        switch (ch) {
            '\r', '\n' => return if (filtered.items.len > 0) filtered.items[sel] else null,
            0x03, 0x07 => return null, // Ctrl-C / Ctrl-G
            0x7f, 0x08 => if (query.items.len > 0) {
                query.shrinkRetainingCapacity(query.items.len - 1);
                sel = 0;
            },
            0x1b => {
                if ((editByte(in) orelse return null) != '[') return null; // bare Esc cancels
                switch (editByte(in) orelse return null) {
                    'A' => if (sel > 0) {
                        sel -= 1;
                    },
                    'B' => if (sel + 1 < filtered.items.len) {
                        sel += 1;
                    },
                    else => {},
                }
            },
            else => if (ch >= 0x20) {
                query.append(arena, ch) catch {};
                sel = 0;
            },
        }
    }
}

// applyUltracodeSteering()/UltracodeMessage moved to shapes.zig (#326: the
// steering notes are a shape-catalog concern, and pickers.zig is at cap).
pub const UltracodeMessage = shapes.UltracodeMessage;
pub const applyUltracodeSteering = shapes.applyUltracodeSteering;

const ultracode_on_first = [_]PickItem{
    .{ .name = "on", .desc = "Enable ultracode orchestration" },
    .{ .name = "off", .desc = "Disable ultracode orchestration" },
};
const ultracode_off_first = [_]PickItem{
    .{ .name = "off", .desc = "Disable ultracode orchestration" },
    .{ .name = "on", .desc = "Enable ultracode orchestration" },
};

fn ultracodeToggleItems(enabled: bool) []const PickItem {
    return if (enabled) &ultracode_off_first else &ultracode_on_first;
}

pub fn pickUltracodeMode(root: *Agent, arena: Allocator, out: *Io.Writer) ?bool {
    const items = ultracodeToggleItems(root.ultracode_mode);
    const idx = listPicker(root, arena, out, "Ultracode ›", items) orelse return null;
    return std.mem.eql(u8, items[idx].name, "on");
}

/// The slash-command menu shown for a bare "/": every REPL command with a
/// one-line description, picked via listPicker. Returns the command to run.
pub const command_menu = command_catalog.commands;

pub const reloadLoginKey = picker_auth.reloadLoginKey;

/// When a model's provider has no key, offer OAuth login or key entry and then
/// switch to that model. The helper owns authentication while this module owns
/// the picker callback and the live color/TTY mode.
pub fn offerProviderAuth(root: *Agent, keys: *Keys, arena: Allocator, out: *Io.Writer, pid: []const u8, model: []const u8, default_selection: bool) !void {
    try picker_auth.offerProviderAuth(root, keys, arena, out, pid, model, default_selection, main_mod.use_color, listPicker);
}

// Tests moved from main.zig alongside the functions they cover (#123 split).

test "fuzzySubseq matches across punctuation gaps" {
    try std.testing.expect(fuzzySubseq("gpt-5.5", "gpt5.5"));
    try std.testing.expect(fuzzySubseq("claude-opus-4-8", "opus"));
    try std.testing.expect(fuzzySubseq("anything", "")); // empty needle matches
    try std.testing.expect(!fuzzySubseq("gpt-5.5", "xyz"));
    try std.testing.expect(!fuzzySubseq("abc", "abcd")); // needle longer
}

test "fuzzyScore ranks basename prefix above substring above subsequence" {
    // "dem" → demo.py (basename prefix) must beat README.md (subsequence only).
    const demo = fuzzyScore("sdk/py/demo.py", "dem").?;
    const readme = fuzzyScore("README.md", "dem").?;
    try std.testing.expect(demo > readme);
    // substring beats subsequence
    const sub = fuzzyScore(".graff/traces/run.jsonl", "trace").?;
    const seq = fuzzyScore("t-r-a-c-e.txt", "trace").?;
    try std.testing.expect(sub > seq);
    // basename prefix beats mid-path substring
    const base_pre = fuzzyScore("src/main.zig", "main").?;
    const mid = fuzzyScore("domain.zig", "main").?;
    try std.testing.expect(base_pre > mid);
    // whole-string prefix counts even with directories in the hay
    try std.testing.expect(fuzzyScore("sdk/ts/harness.ts", "sdk").? >= 300_000 - 200);
    // no match at all → null; empty needle → 0
    try std.testing.expect(fuzzyScore("gpt-5.6-sol", "5.6 sol").? > fuzzyScore("gpt-5.6", "5.6").?);
    try std.testing.expect(fuzzyScore("abc", "xyz") == null);
    try std.testing.expectEqual(@as(?i32, 0), fuzzyScore("abc", ""));
}

test "writeCellTail keeps the distinguishing tail of path-like model ids" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(arena);
    writeCellTail(&aw.writer, "accounts/fireworks/models/deepseek-v4-pro", 18);
    try std.testing.expectEqualStrings("…s/deepseek-v4-pro", aw.writer.buffered()); // not accounts/fireworks/models…
    var aw2: std.Io.Writer.Allocating = .init(arena);
    writeCellTail(&aw2.writer, "deepseek-v4-pro", 18);
    try std.testing.expectEqualStrings("deepseek-v4-pro   ", aw2.writer.buffered()); // fits: padded like writeCell
    var aw3: std.Io.Writer.Allocating = .init(arena);
    writeCellTail(&aw3.writer, "claude-opus-4.8", 4);
    try std.testing.expectEqualStrings("…4.8", aw3.writer.buffered());
}

test "picker layouts honor terminal row and column budgets" {
    try std.testing.expectEqual(@as(usize, 8), visibleRows(12, 4));
    try std.testing.expectEqual(@as(usize, 18), visibleRows(80, 4));
    try std.testing.expectEqual(@as(usize, 1), visibleRows(3, 4));

    const model = modelPickerLayout(12, 44);
    try std.testing.expectEqual(@as(usize, 8), model.visible);
    try std.testing.expect(model.show_context);
    const model_columns = 2 + model.name_width + 1 + model.provider_width + 1 + model.context_width;
    try std.testing.expect(model_columns <= 43);

    const narrow_model = modelPickerLayout(10, 28);
    try std.testing.expect(!narrow_model.show_context);
    const narrow_columns = 2 + narrow_model.name_width + 1 + narrow_model.provider_width + 2;
    try std.testing.expect(narrow_columns <= 27);

    const list = listPickerLayout(16, 44);
    try std.testing.expectEqual(@as(usize, 13), list.visible);
    try std.testing.expect(list.show_desc);
    try std.testing.expect(1 + list.name_width + 1 + list.desc_width <= 43);
    try std.testing.expect(!listPickerLayout(10, 24).show_desc);
}

test "pickScore prefers name matches over desc matches" {
    const by_name = pickScore(.{ .name = "/model", .desc = "switch model" }, "model").?;
    const by_desc = pickScore(.{ .name = "/quit", .desc = "model goodbye" }, "model").?;
    try std.testing.expect(by_name > by_desc);
}

test "ultracode toggle choices put the opposite state first" {
    try std.testing.expectEqualStrings("on", ultracodeToggleItems(false)[0].name);
    try std.testing.expectEqualStrings("off", ultracodeToggleItems(false)[1].name);
    try std.testing.expectEqualStrings("off", ultracodeToggleItems(true)[0].name);
    try std.testing.expectEqualStrings("on", ultracodeToggleItems(true)[1].name);
}

test "applyUltracodeSteering handles explicit and persistent modes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const plain = try applyUltracodeSteering(a, "fix this", "fix this", false);
    try std.testing.expect(!plain.explicit);
    try std.testing.expectEqualStrings("fix this", plain.text);

    const persistent = try applyUltracodeSteering(a, "fix this", "fix this", true);
    try std.testing.expect(!persistent.explicit);
    try std.testing.expect(std.mem.indexOf(u8, persistent.text, "ultracode mode is enabled") != null);

    const explicit = try applyUltracodeSteering(a, "ultracode fix this", "ultracode fix this", true);
    try std.testing.expect(explicit.explicit);
    try std.testing.expect(std.mem.indexOf(u8, explicit.text, "user invoked the \"ultracode\" codeword") != null);
    try std.testing.expect(std.mem.indexOf(u8, explicit.text, "ultracode mode is enabled") == null);

    // #293: the explicit codeword note carries the shape catalog. Slot word +
    // closing bracket catches a dropped/unterminated concatenation.
    try std.testing.expect(std.mem.indexOf(u8, explicit.text, "Pick ONE shape") != null);
    try std.testing.expect(std.mem.indexOf(u8, explicit.text, "synthesize") != null);
    try std.testing.expect(std.mem.endsWith(u8, explicit.text, "]"));
    // #326: the PERSISTENT note must NOT carry the catalog — that re-paste is
    // exactly what this fix removes. setSystemPrompts() puts the catalog in
    // sys_ultra/sys_ultra_strict once instead.
    try std.testing.expect(std.mem.indexOf(u8, persistent.text, "Pick ONE shape") == null);
}
