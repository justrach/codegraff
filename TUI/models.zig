//! Searchable model picker (same fuzzy feel as the line-REPL `/model`).

const std = @import("std");

const app = @import("app.zig");
const engine = @import("engine.zig");
const panel = @import("panel.zig");
const theme_mod = @import("theme.zig");
const Model = app.Model;

pub const max_models = 256;
/// Rows the picker draws at once. Public so the click map (overlays.rowSpan)
/// reads the same window the renderer draws rather than a second copy of it.
pub const visible_rows = 14;

/// Case-insensitive substring, else fzf-style subsequence ("gpt56" -> gpt-5.6).
pub fn modelMatch(name: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (containsIgnoreCase(name, query)) return true;
    var qi: usize = 0;
    for (name) |c| {
        if (qi < query.len and std.ascii.toLower(c) == std.ascii.toLower(query[qi])) qi += 1;
    }
    return qi == query.len;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Match one catalog row. The provider is searchable too: typing "codex"
/// narrows to the codex seats, which is the only way to answer "show me what
/// my plan serves" now that the same names appear under several providers.
pub fn entryMatch(e: engine.ModelEntry, query: []const u8) bool {
    return modelMatch(e.name, query) or containsIgnoreCase(e.provider, query);
}

/// Keep the catalog rows matching `query`, in catalog order.
pub fn filterModels(list: []const engine.ModelEntry, query: []const u8, out: []engine.ModelEntry) usize {
    var n: usize = 0;
    for (list) |e| {
        if (e.name.len == 0) continue;
        if (!entryMatch(e, query)) continue;
        if (n >= out.len) break;
        out[n] = e;
        n += 1;
    }
    return n;
}

/// The row that is live right now: name AND provider, because the same name
/// under two providers is two different seats and only one of them is current.
fn isCurrent(e: engine.ModelEntry) bool {
    if (!std.mem.eql(u8, e.name, engine.g_model_name)) return false;
    if (engine.g_model_provider.len == 0 or e.provider.len == 0) return true;
    return std.mem.eql(u8, e.provider, engine.g_model_provider);
}

/// Display columns, not bytes - model ids are ASCII today, but a padded byte
/// count would silently skew the provider column the day one is not.
fn cellWidth(text: []const u8) usize {
    var n: usize = 0;
    for (text) |c| {
        if (c & 0xC0 != 0x80) n += 1;
    }
    return n;
}

/// Column width for the model names in the visible window: wide enough that
/// the provider column lines up, never wider than the pane can hold.
fn nameColumn(rows: []const engine.ModelEntry, term_width: usize) usize {
    const cap = if (term_width > 46) @min(term_width - 34, 40) else 12;
    var w: usize = 12;
    for (rows) |e| w = @max(w, cellWidth(tailId(e.name)));
    return @min(w, cap);
}

/// What the panel's top edge says: the live filter, and how much of the
/// catalogue survives it. The picker owns these strings; the frame only places
/// them (overlaypane.zig).
pub fn head(self: *const Model, a: std.mem.Allocator) !panel.Head {
    var rows: [max_models]engine.ModelEntry = undefined;
    const all = engine.g_model_entries;
    const total = @min(all.len, max_models);
    const n = filterModels(all, self.overlay_filter, &rows);
    return .{
        .title = try std.fmt.allocPrint(a, "Model \u{203A} {s}\u{258B}", .{self.overlay_filter}),
        .note = try std.fmt.allocPrint(a, "{d}/{d}", .{ n, total }),
    };
}

pub const hint = "type to search (name or provider) \u{B7} \u{2191}\u{2193} move \u{B7} click or Enter picks \u{B7} Esc \u{B7} \u{2014} no key";

/// The ROWS only. Title, tally and keys ride in the panel's edges.
///
/// One catalog row is exactly one LINE: the panel clips each to its inner
/// width rather than wrapping, so the click map (overlays.rowSpan) can stay
/// arithmetic. A wrapped row would slide every row below it off its own line.
pub fn render(self: *const Model, a: std.mem.Allocator) ![]const u8 {
    const th = self.theme();
    var rows: [max_models]engine.ModelEntry = undefined;
    const n = filterModels(engine.g_model_entries, self.overlay_filter, &rows);
    var out = std.array_list.Managed(u8).init(a);

    if (n == 0) {
        try out.appendSlice(try theme_mod.paint(a, th.muted, "  no matches \u{2014} type to filter"));
        try out.append('\n');
        return out.items;
    }

    const sel = self.overlay_sel % n;
    const vis = @min(visible_rows, n);
    const off = if (sel >= vis) sel - vis + 1 else 0;
    const col = nameColumn(rows[off..@min(n, off + vis)], self.last_term_width);
    var i = off;
    while (i < n and i < off + vis) : (i += 1) {
        const e = rows[i];
        try out.appendSlice(if (i == sel) "\u{203A} " else "  ");
        const shown = tailId(e.name);
        // A seat with no credential keeps its row - the catalog is the map -
        // but reads as unavailable rather than as one more thing to pick.
        const dim: []const u8 = if (e.has_key) "" else theme_mod.dim;
        const name_sgr = try std.fmt.allocPrint(a, "{s}{s}", .{ dim, if (i == sel) th.accent else th.text });
        try out.appendSlice(try theme_mod.paint(a, name_sgr, shown));
        try out.appendNTimes(' ', col -| cellWidth(shown));
        // provider - cost - key: the three facts a bare name hid.
        const meta = try std.fmt.allocPrint(a, "  {s} \u{B7} {s} {s}{s}", .{
            e.provider,
            e.cost.badge(),
            if (e.has_key) "\u{2713}" else "\u{2014}",
            if (isCurrent(e)) "  (current)" else "",
        });
        try out.appendSlice(try theme_mod.paint(a, try std.fmt.allocPrint(a, "{s}{s}", .{ dim, th.muted }), meta));
        try out.append('\n');
    }
    if (n > vis) try out.appendSlice(try panel.windowRow(a, th, off, vis, n));
    return out.items;
}

/// Fireworks ids share a long prefix; show the distinguishing tail.
fn tailId(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |sl| {
        if (sl + 1 < name.len) return name[sl + 1 ..];
    }
    return name;
}

test "modelMatch: substring and subsequence" {
    try std.testing.expect(modelMatch("gpt-5.6", "gpt"));
    try std.testing.expect(modelMatch("gpt-5.6", "gpt56"));
    try std.testing.expect(modelMatch("accounts/fireworks/models/deepseek-v4-pro", "deepseek"));
    try std.testing.expect(!modelMatch("gpt-5.6", "claude"));
}

const sample = [_]engine.ModelEntry{
    .{ .name = "aaa", .provider = "openai", .has_key = true, .cost = .api },
    .{ .name = "bbb", .provider = "codegraff", .has_key = true, .cost = .credits },
    .{ .name = "ccc", .provider = "codex", .cost = .plan },
    .{ .name = "accounts/fireworks/models/deepseek-v4-pro", .provider = "fireworks", .has_key = true, .cost = .api },
    .{ .name = "gpt-5.6", .provider = "codex", .has_key = true, .cost = .plan },
};

test "filterModels keeps whole catalog rows, not names" {
    var buf: [8]engine.ModelEntry = undefined;
    const n = filterModels(&sample, "deepseek", &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("accounts/fireworks/models/deepseek-v4-pro", buf[0].name);
    try std.testing.expectEqualStrings("fireworks", buf[0].provider);
    try std.testing.expectEqual(@as(usize, 5), filterModels(&sample, "", &buf));
}

test "the query searches the provider column too" {
    // "show me what my plan serves" - impossible while rows were name-only.
    var buf: [8]engine.ModelEntry = undefined;
    const n = filterModels(&sample, "codex", &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("ccc", buf[0].name);
    try std.testing.expectEqualStrings("gpt-5.6", buf[1].name);
    try std.testing.expectEqual(@as(usize, 1), filterModels(&sample, "codegraff", &buf));
    try std.testing.expectEqual(@as(usize, 0), filterModels(&sample, "anthropic", &buf));
}

test "model overlay typed query is a filtered list, not the dump" {
    engine.g_model_entries = &sample;
    engine.g_model_name = "aaa";
    defer {
        engine.g_model_entries = &.{};
        engine.g_model_name = "";
    }
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.openOverlay(.model);
    for ("deepseek") |c| m.typeOverlayFilter(c);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try render(&m, arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, text, "deepseek-v4-pro") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "gpt-5.6") == null);
    // The tally and the live filter moved into the panel's top edge.
    const hd = try head(&m, arena.allocator());
    try std.testing.expectEqualStrings("1/5", hd.note);
    try std.testing.expect(std.mem.indexOf(u8, hd.title, "Model \u{203A} deepseek") != null);
}

test "picker rows carry the provider, a cost badge and a key marker" {
    // The reported bug: two seats for the same model rendered identically, so
    // "codex (free) vs codegraff (paid) vs openai (paid)" was invisible.
    const dupes = [_]engine.ModelEntry{
        .{ .name = "gpt-5.6", .provider = "codex", .has_key = true, .cost = .plan },
        .{ .name = "gpt-5.6", .provider = "openai", .has_key = true, .cost = .api },
        .{ .name = "gpt-5.6", .provider = "codegraff", .cost = .credits },
    };
    engine.g_model_entries = &dupes;
    engine.g_model_name = "gpt-5.6";
    engine.g_model_provider = "openai";
    defer {
        engine.g_model_entries = &.{};
        engine.g_model_name = "";
        engine.g_model_provider = "";
    }
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.openOverlay(.model);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try render(&m, arena.allocator());
    // provider, cost and key per row - the keyless seat is marked, not hidden.
    for ([_][]const u8{ "codex \u{B7} plan \u{2713}", "openai \u{B7} api \u{2713}", "codegraff \u{B7} credits \u{2014}" }) |want|
        try std.testing.expect(std.mem.indexOf(u8, text, want) != null);
    // Exactly one row is current, and it is the one whose PROVIDER matches -
    // by name alone all three would have claimed it.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "(current)"));
    const cur = std.mem.indexOf(u8, text, "(current)").?;
    const openai = std.mem.indexOf(u8, text, "openai \u{B7} api").?;
    try std.testing.expect(openai < cur and cur - openai < 24);
    // ...and that row is the only dimmed one.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, text, theme_mod.dim));
}

test "the provider column lines up under ragged model names" {
    const ragged = [_]engine.ModelEntry{
        .{ .name = "k3", .provider = "kimi", .has_key = true, .cost = .plan },
        .{ .name = "claude-opus-4-8", .provider = "anthropic", .has_key = true, .cost = .api },
    };
    engine.g_model_entries = &ragged;
    defer engine.g_model_entries = &.{};
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.openOverlay(.model);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try render(&m, arena.allocator());
    var col: ?usize = null;
    var seen: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    var buf: [512]u8 = undefined;
    while (it.next()) |line| {
        const plain = strip(line, &buf);
        // Only the catalog rows: they alone open with the selection gutter.
        if (!std.mem.startsWith(u8, plain, "  ") and !std.mem.startsWith(u8, plain, "\u{203A} ")) continue;
        const sep = std.mem.indexOf(u8, plain, " \u{B7} ") orelse continue;
        var start = sep;
        while (start > 0 and plain[start - 1] != ' ') start -= 1;
        const at = cellWidth(plain[0..start]);
        if (col) |c| try std.testing.expectEqual(c, at) else col = at;
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
}

/// `line` with its SGR sequences removed, written into `buf`. The padding is
/// what is under test and an escape sequence is zero cells wide.
fn strip(line: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < line.len and n < buf.len) {
        if (line[i] == 0x1b) {
            while (i < line.len and line[i] != 'm') i += 1;
            i += 1;
            continue;
        }
        buf[n] = line[i];
        n += 1;
        i += 1;
    }
    return buf[0..n];
}
