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

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const Agent = agent_mod.Agent;
const Keys = provider_mod.Keys;
const command_catalog = @import("command_catalog.zig");
const picker_auth = @import("picker_auth.zig");
const util = @import("util.zig");
const shapes = @import("shapes.zig");

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

/// Rank a fuzzy match for the pickers (higher = better, null = no match).
/// Tiers: basename/whole-string prefix > substring (earlier and shorter is
/// better) > bare subsequence — so "dem" puts demo.py above README.md, which
/// only matches as a d…e…m subsequence.
fn fuzzyScore(hay: []const u8, needle: []const u8) ?i32 {
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
        // Two passes: models whose provider has a key/login first, so the
        // initial selection (and Enter) lands on something usable; keyless
        // rows trail with their ·no key tag. Within each pass the best
        // fuzzy match ranks first (ties keep table order).
        for ([2]bool{ true, false }) |want_keyed| {
            scored.clearRetainingCapacity();
            for (model_table, 0..) |m, i| {
                if ((keys.get(m.provider) != null) != want_keyed) continue;
                if (pickScore(.{ .name = m.name, .desc = m.provider }, query.items)) |s|
                    scored.append(arena, .{ .idx = i, .score = s }) catch {};
            }
            std.mem.sort(Scored, scored.items, {}, scoredLess);
            for (scored.items) |s| filtered.append(arena, s.idx) catch {};
        }
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
            writeCell(out, m.name, layout.name_width);
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

        const ch = in.takeByte() catch return null;
        switch (ch) {
            '\r', '\n' => return if (filtered.items.len > 0) filtered.items[sel] else null,
            0x03, 0x07 => return null, // Ctrl-C / Ctrl-G
            0x7f, 0x08 => if (query.items.len > 0) {
                query.shrinkRetainingCapacity(query.items.len - 1);
                sel = 0;
            },
            0x1b => {
                if ((in.takeByte() catch return null) != '[') continue;
                switch (in.takeByte() catch return null) {
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

        const ch = in.takeByte() catch return null;
        switch (ch) {
            '\r', '\n' => return if (filtered.items.len > 0) filtered.items[sel] else null,
            0x03, 0x07 => return null, // Ctrl-C / Ctrl-G
            0x7f, 0x08 => if (query.items.len > 0) {
                query.shrinkRetainingCapacity(query.items.len - 1);
                sel = 0;
            },
            0x1b => {
                if ((in.takeByte() catch return null) != '[') return null; // bare Esc cancels
                switch (in.takeByte() catch return null) {
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

pub const UltracodeMessage = struct {
    text: []const u8,
    explicit: bool,
};

const ultracode_explicit_head =
    \\[harness note: the user invoked the "ultracode" codeword, opting
    \\this turn into multi-agent orchestration. Fulfill the request with
    \\the workflow tool.
    \\Tell code-exploration subagents to go through the repo with the
    \\codedb tool (search / symbol / callers / outline / context) before
    \\reaching for bash grep — it is indexed and structural.
    \\Use the workflow even if you could do the work solo; skip it only
    \\if the message needs a purely conversational reply.
;

const ultracode_persistent_head =
    \\[harness note: ultracode mode is enabled for this session. Use the
    \\workflow tool for coding tasks. Tell code-exploration subagents to go
    \\through the repo with the codedb tool (search / symbol / callers /
    \\outline / context) before reaching for bash grep — it is indexed and
    \\structural.
;

// Both steering notes carry the shape catalog (#293), so an ultracode turn
// instantiates one of the five known shapes under canonical slot names instead
// of inventing a fresh structure each run — scores from differently-shaped runs
// are not comparable, which is what kept the fleet from accruing real fitness.
const ultracode_explicit_note = ultracode_explicit_head ++ "\n\n" ++ shapes.shape_catalog_note ++ "]";
const ultracode_persistent_note = ultracode_persistent_head ++ "\n\n" ++ shapes.shape_catalog_note ++ "]";

/// `raw` is what the user actually typed this turn; `msg` is the assembled
/// turn message (goal/eval/loop/plan notes may already be appended). The
/// explicit-codeword scan runs ONLY on `raw`: harness-assembled notes replay
/// prior context — a /goal set during an ultracode task, a todo echoed
/// through the goal note — and scanning them made the codeword sticky, so
/// every turn after /clear bannered as explicit even though the user never
/// typed the word (#178).
pub fn applyUltracodeSteering(arena: Allocator, msg: []const u8, raw: []const u8, persistent_enabled: bool) !UltracodeMessage {
    const explicit = util.indexOfIgnoreCase(raw, "ultracode") != null;
    if (explicit) {
        return .{ .text = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ msg, ultracode_explicit_note }), .explicit = true };
    }
    if (persistent_enabled) {
        return .{ .text = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ msg, ultracode_persistent_note }), .explicit = false };
    }
    return .{ .text = msg, .explicit = false };
}

test "applyUltracodeSteering (#178): the codeword scan runs on the raw typed text, not the assembled msg" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The word arriving via an appended harness note (e.g. a standing goal)
    // must NOT count as an invocation — and with persistent mode off, the
    // message passes through untouched.
    const assembled = "write the report\n\n[harness note: goal — ultracode the pipeline]";
    const via_note = try applyUltracodeSteering(a, assembled, "write the report", false);
    try std.testing.expect(!via_note.explicit);
    try std.testing.expectEqualStrings(assembled, via_note.text);
    // The user actually typing it does (case-insensitive) and appends the note.
    const typed = try applyUltracodeSteering(a, "ULTRACODE fix the bug", "ULTRACODE fix the bug", false);
    try std.testing.expect(typed.explicit);
    try std.testing.expect(std.mem.indexOf(u8, typed.text, "codeword") != null);
    // Persistent mode still applies its note without ever claiming explicit.
    const persistent = try applyUltracodeSteering(a, assembled, "write the report", true);
    try std.testing.expect(!persistent.explicit);
    try std.testing.expect(std.mem.indexOf(u8, persistent.text, "ultracode mode is enabled") != null);
}

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
    try std.testing.expect(fuzzyScore("abc", "xyz") == null);
    try std.testing.expectEqual(@as(?i32, 0), fuzzyScore("abc", ""));
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

    // #293: BOTH steering paths must carry the shape catalog — a turn steered
    // into orchestration without it is exactly the free-form case the catalog
    // exists to remove. Check a slot word and the closing bracket, so a broken
    // concatenation (dropped catalog, or a note left unterminated) fails here.
    for ([_][]const u8{ explicit.text, persistent.text }) |steered| {
        try std.testing.expect(std.mem.indexOf(u8, steered, "Pick ONE shape") != null);
        try std.testing.expect(std.mem.indexOf(u8, steered, "synthesize") != null);
        try std.testing.expect(std.mem.endsWith(u8, steered, "]"));
    }
}
