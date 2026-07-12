//! Interactive fuzzy pickers (the /model picker + the generic listPicker
//! used by /resume, /login, the bare "/" command menu, etc.), the fuzzy
//! match/score/sort primitives behind them, ultracode steering + its on/off
//! toggle picker, the slash-command menu, and the "no key for this
//! provider" login/paste-a-key flow. Split out of main.zig (600-line goal).
//! Back-imports switchProvider from providers.zig (offerProviderAuth's
//! final step) and main (as main_mod, since several params are named
//! `root`) for Agent, Keys, provider_specs, storeKey, and the live
//! use_color toggle.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const ansi = @import("ansi.zig");
const style = &ansi.style;

const term = @import("term.zig");
const tty = term.tty;

const pricing = @import("pricing.zig");

const oauth = @import("oauth.zig");

const providers = @import("providers.zig");
const switchProvider = providers.switchProvider;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const keys_cli = @import("keys_cli.zig");
const Agent = agent_mod.Agent;
const Keys = provider_mod.Keys;
const provider_specs = provider_mod.provider_specs;
const storeKey = keys_cli.storeKey;
const command_catalog = @import("command_catalog.zig");

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
    if (std.ascii.indexOfIgnoreCase(hay, needle)) |p| {
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
        out.print("{s}Model ›{s} {s}\n", .{ style.cyan, style.reset, query.items }) catch {};
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
            if (row == sel) out.writeAll("\x1b[7m") catch {};
            out.print("{s} ", .{if (cur) "▌" else " "}) catch {};
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
            if (row == sel) out.writeAll("\x1b[0m") catch {};
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
        out.print("{s}{s}{s} {s}\n", .{ style.cyan, title, style.reset, query.items }) catch {};
        out.print("{s}{d}/{d}{s}\n", .{ style.dim, filtered.items.len, items.len, style.reset }) catch {};
        const off = if (sel >= layout.visible) sel - layout.visible + 1 else 0;
        var row = off;
        while (row < filtered.items.len and row < off + layout.visible) : (row += 1) {
            const item = items[filtered.items[row]];
            if (row == sel) out.writeAll("\x1b[7m") catch {};
            out.writeByte(' ') catch {};
            writeCell(out, item.name, layout.name_width);
            if (row == sel) out.writeAll("\x1b[0m") catch {};
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

const ultracode_explicit_note =
    \\[harness note: the user invoked the "ultracode" codeword, opting
    \\this turn into multi-agent orchestration. Fulfill the request with
    \\the workflow tool: decompose it into sequential phases of parallel
    \\subagents — fan out for coverage first, then a synthesis phase.
    \\Tell code-exploration subagents to go through the repo with the
    \\codedb tool (search / symbol / callers / outline / context) before
    \\reaching for bash grep — it is indexed and structural.
    \\Use the workflow even if you could do the work solo; skip it only
    \\if the message needs a purely conversational reply.]
;

const ultracode_persistent_note =
    \\[harness note: ultracode mode is enabled for this session. Use the
    \\workflow tool for coding tasks: decompose the work into sequential
    \\phases with parallel subagents for exploration/review where helpful,
    \\then synthesize and implement. Tell code-exploration subagents to go
    \\through the repo with the codedb tool (search / symbol / callers /
    \\outline / context) before reaching for bash grep — it is indexed and
    \\structural.]
;

/// `raw` is what the user actually typed this turn; `msg` is the assembled
/// turn message (goal/eval/loop/plan notes may already be appended). The
/// explicit-codeword scan runs ONLY on `raw`: harness-assembled notes replay
/// prior context — a /goal set during an ultracode task, a todo echoed
/// through the goal note — and scanning them made the codeword sticky, so
/// every turn after /clear bannered as explicit even though the user never
/// typed the word (#178).
pub fn applyUltracodeSteering(arena: Allocator, msg: []const u8, raw: []const u8, persistent_enabled: bool) !UltracodeMessage {
    const explicit = std.ascii.indexOfIgnoreCase(raw, "ultracode") != null;
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

/// After an in-session `/login` writes its credential file, pull the fresh key
/// (and the Codex account id) into the live Keys so the current conversation
/// uses it without a restart — the in-session twin of the startup loaders.
pub fn reloadLoginKey(root: *Agent, keys: *Keys, arena: Allocator, provider_id: []const u8) void {
    const home = root.home;
    for (provider_specs, &keys.values, &keys.sources) |spec, *value, *source| {
        if (!std.mem.eql(u8, spec.id, provider_id)) continue;
        if (std.mem.eql(u8, provider_id, "codegraff")) {
            if (oauth.loadCodegraffKey(root.io, arena, home)) |k| {
                value.* = k;
                source.* = .login;
            }
        } else if (std.mem.eql(u8, provider_id, "kimi")) {
            if (oauth.loadKimiOAuth(root.io, root.gpa, arena, home, false)) |k| {
                value.* = k;
                source.* = .login;
            }
        } else if (std.mem.eql(u8, provider_id, "xai")) {
            if (oauth.loadXaiOAuth(root.io, root.gpa, arena, home, false)) |k| {
                value.* = k;
                source.* = .login;
            }
        } else if (std.mem.eql(u8, provider_id, "codex")) {
            if (oauth.loadCodexAuth(root.io, arena, home)) |auth| {
                value.* = auth.token;
                source.* = .login;
                keys.codex_account = auth.account;
            }
        }
    }
}

/// Read an API key without terminal echo or history persistence. The ordinary
/// REPL line editor masks `/key provider secret`; this covers the model
/// picker's separate "paste an API key" flow too.
fn readSecret(root: *Agent, arena: Allocator, out: *Io.Writer) ?[]const u8 {
    const in = root.in orelse return null;
    const raw_state = tty.enterRaw(true) orelse return null;
    defer tty.restore(raw_state);
    var secret: std.ArrayList(u8) = .empty;
    while (true) {
        const byte = in.takeByte() catch return null;
        switch (byte) {
            '\r', '\n' => {
                out.writeByte('\n') catch {};
                out.flush() catch {};
                return secret.toOwnedSlice(arena) catch secret.items;
            },
            0x03, 0x07 => {
                out.writeByte('\n') catch {};
                out.flush() catch {};
                return null;
            },
            0x7f, 0x08 => if (secret.items.len > 0) {
                _ = secret.pop();
                out.writeAll("\x08 \x08") catch {};
                out.flush() catch {};
            },
            else => if (byte >= 0x20) {
                secret.append(arena, byte) catch return null;
                out.writeByte('*') catch {};
                out.flush() catch {};
            },
        }
    }
}

/// Better UX when /model targets a provider with no key: instead of a flat
/// "no key" dead-end, offer to log in (OAuth, for providers that have a flow)
/// or paste an API key, then switch to pid/model. Esc/blank/"keep" stays on the
/// current model. Non-TTY just prints the actionable one-liner. Best-effort.
pub fn offerProviderAuth(root: *Agent, keys: *Keys, arena: Allocator, out: *Io.Writer, pid: []const u8, model: []const u8) !void {
    var spec_idx: ?usize = null;
    for (provider_specs, 0..) |spec, i| if (std.mem.eql(u8, spec.id, pid)) {
        spec_idx = i;
    };
    const si = spec_idx orelse {
        try out.print("unknown provider '{s}' — see /model for the list\n", .{pid});
        try out.flush();
        return;
    };
    const can_login = std.mem.eql(u8, pid, "codegraff") or std.mem.eql(u8, pid, "codex") or std.mem.eql(u8, pid, "kimi") or std.mem.eql(u8, pid, "xai");

    // Non-interactive (one-shot / no TTY): no picker — print the hint and bail.
    if (!main_mod.use_color or root.in == null) {
        if (can_login)
            try out.print("no key for {s} — /login {s} (OAuth) or /key {s} <key>\n", .{ pid, pid, pid })
        else
            try out.print("no key for {s} — /key {s} <key> (or set {s})\n", .{ pid, pid, provider_specs[si].env_key });
        try out.flush();
        return;
    }

    // Choice menu — login row only when the provider actually has an OAuth flow.
    var items: [3]PickItem = undefined;
    var n: usize = 0;
    if (can_login) {
        items[n] = .{ .name = "log in (OAuth)", .desc = "device/browser sign-in — no key to paste" };
        n += 1;
    }
    items[n] = .{ .name = "paste an API key", .desc = "enter a key now (used live + saved)" };
    n += 1;
    items[n] = .{ .name = "keep current model", .desc = "cancel — stay on the current model" };
    n += 1;

    const title = std.fmt.allocPrint(arena, "No key for {s} \xe2\x80\xba", .{pid}) catch "No key \xe2\x80\xba";
    const choice = listPicker(root, arena, out, title, items[0..n]) orelse {
        try out.print("kept {s}{s}{s}\n", .{ style.cyan, root.provider.model, style.reset });
        try out.flush();
        return;
    };
    const picked = items[choice].name;

    if (std.mem.eql(u8, picked, "keep current model")) {
        try out.print("kept {s}{s}{s}\n", .{ style.cyan, root.provider.model, style.reset });
        try out.flush();
        return;
    }

    if (std.mem.eql(u8, picked, "log in (OAuth)")) {
        const home = root.home;
        try out.flush(); // hand stdout to the login flow's own writer
        if (std.mem.eql(u8, pid, "codegraff")) {
            oauth.codegraffLogin(root.io, root.gpa, arena, home) catch |err| {
                try out.print("\xe2\x9c\x97 codegraff login failed: {t}\n", .{err});
                try out.flush();
                return;
            };
        } else if (std.mem.eql(u8, pid, "codex")) {
            oauth.codexLogin(root.io, root.gpa, arena, home, false) catch |err| {
                try out.print("\xe2\x9c\x97 codex login failed: {t}\n", .{err});
                try out.flush();
                return;
            };
        } else if (std.mem.eql(u8, pid, "kimi")) {
            oauth.kimiLogin(root.io, root.gpa, arena, home) catch |err| {
                try out.print("\xe2\x9c\x97 kimi login failed: {t}\n", .{err});
                try out.flush();
                return;
            };
        } else if (std.mem.eql(u8, pid, "xai")) {
            oauth.xaiLogin(root.io, root.gpa, arena, home) catch |err| {
                try out.print("\xe2\x9c\x97 xai login failed: {t}\n", .{err});
                try out.flush();
                return;
            };
        }
        reloadLoginKey(root, keys, arena, pid);
    } else {
        try out.print("paste your {s} API key, then Enter (input is hidden; blank cancels): ", .{pid});
        try out.flush();
        const key = readSecret(root, arena, out) orelse "";
        if (key.len == 0) {
            try out.print("cancelled — kept {s}{s}{s}\n", .{ style.cyan, root.provider.model, style.reset });
            try out.flush();
            return;
        }
        const dup = arena.dupe(u8, key) catch key;
        keys.values[si] = dup;
        const saved = storeKey(root.io, root.gpa, arena, root.home, pid, dup);
        keys.sources[si] = if (saved) .stored else .session;
        try out.print("\xe2\x9c\x93 {s} key set (live{s})\n", .{ pid, if (saved) " + Keychain" else "" });
    }

    // Auth done — switch now if the key/login took, else keep the current model.
    const provider = keys.providerById(pid, model) catch {
        try out.print("still no usable key for {s} — kept {s}{s}{s}\n", .{ pid, style.cyan, root.provider.model, style.reset });
        try out.flush();
        return;
    };
    try switchProvider(root, arena, provider, out);
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
    const sub = fuzzyScore("harness.trace.jsonl", "trace").?;
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
}
