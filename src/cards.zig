//! Subagent cards (#51): the parallel-subagent launch/done cards (sprite +
//! stable id + label + one-line activity), the box-drawing helpers, whitespace
//! collapse, and the per-subagent inspect-report writer (.graff/subagents/
//! <id>.md). Split out of main.zig (600-line goal). Imports ansi (palette) +
//! term (termCols); back-imports main for utf8Prefix and the live
//! use_color/json_mode toggles. main aliases the 5 renderers back and
//! mod-qualifies g_subagent_seq.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const ansi = @import("ansi.zig");
const style = &ansi.style;

const term = @import("term.zig");
const termCols = term.termCols;

const root = @import("main.zig");
const util = @import("util.zig");
const utf8Prefix = util.utf8Prefix;

// #tui-tick: cards go through the line-boundary gate, not straight to stderr.
const tick_gate = @import("tick_gate.zig");

// ── Subagent cards (#51) ───────────────────────────────────────────────────
//
// When the model fans out parallel subagents (several `subagent` calls in one
// response, or a `workflow` phase), each child runs on a pool thread with no
// stdout of its own (Agent.out == null). Instead of the old bare
// "[label] started/done" lines, every subagent now renders a compact card —
// a sprite, a stable id, the agent label, and a one-line activity — and on
// completion persists its full report under .graff/subagents/<id>.md so the
// run can be inspected from the terminal (the card prints the inspect: path).
//
// The cards are append-only and each card is built as one string then handed
// to tick_gate.workerLine — one std.debug.print (std serializes the stderr
// mutex) so parallel children never interleave mid-card, deferred until the
// foreground stream's last published position is a line boundary (flush
// granularity — see tick_gate.zig's module doc for what that does and does not
// guarantee, #tui-tick). Box width is clamped to the terminal so narrow
// terminals degrade to a readable column. Execution is unchanged.

/// Monotonic counter feeding the per-subagent ordinal in its stable id.
pub var g_subagent_seq: std.atomic.Value(u32) = .init(0);

const subagents_dir = ".graff/subagents";

/// A short pool of distinct sprites, picked by id hash so sibling subagents in
/// a fan-out tend to get different faces. Plain text when color is off (no
/// emoji width games to lose in a redirected/CI log).
pub fn subagentSprite(id_seq: u32) []const u8 {
    if (!root.use_color) return "*";
    const faces = [_][]const u8{ "🐢", "🦊", "🐙", "🦉", "🐝", "🦀", "🐬", "🦫" };
    return faces[id_seq % faces.len];
}

/// Stable identifier for a subagent run: "sa-<ordinal>-<8 hex of label+prompt>".
/// Stable across a session for a given (label, prompt) at a given ordinal, and
/// unique because the ordinal is monotonic — usable as the detail filename.
pub fn subagentId(buf: []u8, ordinal: u32, label: []const u8, prompt: []const u8) []const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(label);
    h.update("\x00");
    h.update(prompt);
    var d: [32]u8 = undefined;
    h.final(&d);
    const hex = std.fmt.bytesToHex(d[0..4].*, .lower);
    return std.fmt.bufPrint(buf, "sa-{d:0>3}-{s}", .{ ordinal, hex }) catch buf[0..0];
}

/// Render the launch card for a subagent to stderr as one block. `kind` is
/// "subagent" or "workflow_task"; `activity` is the one-line task preview.
pub fn subagentLaunchCard(arena: Allocator, id: []const u8, sprite: []const u8, label: []const u8, kind: []const u8, activity: []const u8) void {
    if (root.json_mode) return; // SDK consumers get structured events, not TUI cards
    const cols = termCols();
    // Inner width: clamp to the terminal, but keep cards readable and never
    // wider than a comfortable card. -2 leaves room for the box borders.
    const inner: usize = @min(@max(cols, 24) - 2, 58);
    const tag = if (std.mem.eql(u8, kind, "workflow_task")) "workflow" else "subagent";
    var aw: Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    // Header line carries the sprite (kept outside the box so emoji width can't
    // skew the borders) plus the agent label and its stable id.
    const sep = if (root.use_color) "·" else "-";
    w.print("  {s} {s}{s}{s} {s}{s} {s} [{s}]{s}\n", .{
        sprite, style.bold, label, style.reset, style.dim, sep, tag, id, style.reset,
    }) catch return;
    boxRule(w, inner, .top);
    boxLine(w, inner, if (root.use_color) "▸ " else "> ", activity);
    boxRule(w, inner, .bottom);
    tick_gate.workerLine(aw.writer.buffered());
}

/// Render the completion card: status, elapsed, tools, and the inspect: path.
pub fn subagentDoneCard(arena: Allocator, id: []const u8, sprite: []const u8, label: []const u8, ok: bool, run_ms: i64, tools: []const u8, detail_path: ?[]const u8) void {
    if (root.json_mode) return;
    const cols = termCols();
    const inner: usize = @min(@max(cols, 24) - 2, 58);
    const mark = if (ok) (if (root.use_color) "✓ done" else "done") else (if (root.use_color) "✗ failed" else "failed");
    const mark_style = if (ok) style.green else style.red;
    var aw: Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    const sep = if (root.use_color) "·" else "-";
    w.print("  {s} {s}{s}{s} {s}{s}{s} {s}{s} {d}ms [{s}]{s}\n", .{
        sprite,     style.bold, label,       style.reset,
        mark_style, mark,       style.reset, style.dim,
        sep,        run_ms,     id,          style.reset,
    }) catch return;
    boxRule(w, inner, .top);
    const tool_line = if (tools.len > 0)
        std.fmt.allocPrint(arena, "tools: {s}", .{tools}) catch "tools: (n/a)"
    else
        "tools: (none)";
    const bullet = if (root.use_color) "· " else "- ";
    boxLine(w, inner, bullet, tool_line);
    if (detail_path) |p|
        boxLine(w, inner, bullet, std.fmt.allocPrint(arena, "inspect: {s}", .{p}) catch p);
    boxRule(w, inner, .bottom);
    tick_gate.workerLine(aw.writer.buffered());
}

const BoxEdge = enum { top, bottom };

/// One horizontal box rule of `inner` light box-drawing dashes. ASCII '+---+'
/// when color (and thus likely Unicode-friendly rendering) is off.
fn boxRule(w: *Io.Writer, inner: usize, edge: BoxEdge) void {
    const corners = if (root.use_color)
        (if (edge == .top) [2][]const u8{ "╭", "╮" } else [2][]const u8{ "╰", "╯" })
    else
        [2][]const u8{ "+", "+" };
    const dash = if (root.use_color) "─" else "-";
    w.print("  {s}{s}", .{ style.dim, corners[0] }) catch return;
    var i: usize = 0;
    while (i < inner) : (i += 1) w.writeAll(dash) catch return;
    w.print("{s}{s}\n", .{ corners[1], style.reset }) catch return;
}

/// One box content row: "│ <prefix><text…> │", text clamped (UTF-8 safe) to the
/// inner width so the right border lands in the same column every row. The
/// closing border is omitted when the text was truncated (a trailing ellipsis
/// reads cleaner than a misaligned border under variable-width glyphs).
fn boxLine(w: *Io.Writer, inner: usize, prefix: []const u8, text: []const u8) void {
    const bar = if (root.use_color) "│" else "|";
    // One column of padding inside each border.
    const budget = if (inner >= 2) inner - 2 else 0;
    const flat = collapseWs(text);
    const want = if (prefix.len + flat.len <= budget) flat else utf8Prefix(flat, if (budget > prefix.len + 1) budget - prefix.len - 1 else 0);
    const truncated = want.len != flat.len;
    w.print("  {s}{s}{s} {s}{s}", .{ style.dim, bar, style.reset, prefix, want }) catch return;
    if (truncated) w.writeAll(if (root.use_color) "…" else "~") catch return;
    // Pad to the right border using the byte length as an approximation; the
    // border is decorative, so a few off columns under wide glyphs are benign.
    const used = prefix.len + want.len + (if (truncated) @as(usize, 1) else 0);
    if (used < budget) {
        var i: usize = used;
        while (i < budget) : (i += 1) w.writeByte(' ') catch return;
    }
    w.print(" {s}{s}{s}\n", .{ style.dim, bar, style.reset }) catch return;
}

/// Collapse every run of whitespace (spaces, newlines, tabs) to a single space
/// and trim the ends, for a tidy one-line activity preview. Copies into a small
/// thread-local buffer (activity lines are short, and each subagent renders on
/// its own pool thread, so the threadlocal keeps siblings from racing).
fn collapseWs(s: []const u8) []const u8 {
    const S = struct {
        threadlocal var buf: [512]u8 = undefined;
    };
    var n: usize = 0;
    var prev_space = false;
    for (s) |c| {
        const is_ws = c == ' ' or c == '\n' or c == '\r' or c == '\t';
        if (is_ws) {
            if (!prev_space and n > 0 and n < S.buf.len) {
                S.buf[n] = ' ';
                n += 1;
            }
            prev_space = true;
        } else {
            if (n < S.buf.len) {
                S.buf[n] = c;
                n += 1;
            }
            prev_space = false;
        }
    }
    return std.mem.trimEnd(u8, S.buf[0..n], " ");
}

/// Persist a subagent's final report + metadata under .graff/subagents/<id>.md
/// and return the relative path (arena-owned) for the inspect: link, or null
/// if the write failed (best-effort — never blocks the run).
pub fn writeSubagentDetail(
    io: Io,
    arena: Allocator,
    id: []const u8,
    label: []const u8,
    kind: []const u8,
    prompt: []const u8,
    report: []const u8,
    ok: bool,
    run_ms: i64,
    tools: []const u8,
) ?[]const u8 {
    Io.Dir.cwd().createDir(io, ".graff", .default_dir) catch {}; // exists is fine
    Io.Dir.cwd().createDir(io, subagents_dir, .default_dir) catch {};
    const path = std.fmt.allocPrint(arena, "{s}/{s}.md", .{ subagents_dir, id }) catch return null;
    var aw: Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.print("# subagent {s}\n\n", .{id}) catch return null;
    w.print("- label: {s}\n", .{label}) catch return null;
    w.print("- kind: {s}\n", .{kind}) catch return null;
    w.print("- status: {s}\n", .{if (ok) "ok" else "failed"}) catch return null;
    w.print("- elapsed_ms: {d}\n", .{run_ms}) catch return null;
    w.print("- tools: {s}\n", .{if (tools.len > 0) tools else "(none)"}) catch return null;
    w.writeAll("\n## task\n\n") catch return null;
    w.writeAll(prompt) catch return null;
    w.writeAll("\n\n## report\n\n") catch return null;
    w.writeAll(report) catch return null;
    w.writeByte('\n') catch return null;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.writer.buffered() }) catch return null;
    return path;
}
test { // the gate's own tests only run when something references the module
    _ = tick_gate;
}
test "subagentId: stable shape, ordinal-prefixed, hash-suffixed (#51)" {
    var a: [40]u8 = undefined;
    var b: [40]u8 = undefined;
    const id1 = subagentId(&a, 0, "review auth", "look at the login flow");
    // sa-<3-digit ordinal>-<8 hex>
    try std.testing.expectEqualStrings("sa-000-", id1[0..7]);
    try std.testing.expectEqual(@as(usize, 15), id1.len); // 7 prefix + 8 hex
    // Same label+prompt+ordinal → identical id (stable for inspection).
    const id1b = subagentId(&b, 0, "review auth", "look at the login flow");
    try std.testing.expectEqualStrings(id1, id1b);
    // Different ordinal → different id even with the same task.
    const id2 = subagentId(&b, 7, "review auth", "look at the login flow");
    try std.testing.expectEqualStrings("sa-007-", id2[0..7]);
    try std.testing.expect(!std.mem.eql(u8, id1, id2));
    // Hex suffix is lowercase hex only.
    for (id2[7..]) |c| try std.testing.expect(std.ascii.isHex(c) and !std.ascii.isUpper(c));
}
test "collapseWs flattens newlines/tabs to single spaces (#51)" {
    try std.testing.expectEqualStrings("a b c", collapseWs("a b c")); // unchanged
    try std.testing.expectEqualStrings("hello world", collapseWs("  hello   world  ")); // trimmed + interior run collapsed
    try std.testing.expectEqualStrings("line one line two", collapseWs("line one\n\nline two"));
    try std.testing.expectEqualStrings("a b", collapseWs("a\t \n b\n"));
}
