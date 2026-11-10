//! Shared span resolution for `edit_file` (`edit_verify.zig` and `edit_batch.zig`):
//! exact byte match first (repairing stripped line-1 indentation when unambiguous),
//! falling back to dominant-CRLF line-ending normalization and unique multi-line
//! uniform-indent / line-1-stripped / trailing-whitespace resolution.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ResolvedSpan = struct {
    old: []const u8,
    new: []const u8,
    owned_old: ?[]u8 = null,
    owned_new: ?[]u8 = null,
    count: usize,

    pub fn deinit(self: ResolvedSpan, gpa: Allocator) void {
        if (self.owned_old) |b| gpa.free(b);
        if (self.owned_new) |b| gpa.free(b);
    }
};

/// True when `text` has at least one `\r\n` and at least half of all `\n`
/// line breaks are preceded by `\r`.
pub fn isDominantCrlf(text: []const u8) bool {
    var lf_total: usize = 0;
    var crlf_total: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '\n') {
            lf_total += 1;
            if (i > 0 and text[i - 1] == '\r') crlf_total += 1;
        }
    }
    return crlf_total > 0 and crlf_total * 2 >= lf_total;
}

/// Convert bare `\n` line breaks into `\r\n`, preserving any existing `\r\n`.
pub fn lfToCrlf(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    var bare_lf: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '\n' and (i == 0 or s[i - 1] != '\r')) bare_lf += 1;
    }
    const out = try gpa.alloc(u8, s.len + bare_lf);
    var w: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '\n' and (i == 0 or s[i - 1] != '\r')) {
            out[w] = '\r';
            w += 1;
        }
        out[w] = c;
        w += 1;
    }
    return out;
}

/// Resolve `(old, new)` against `content`: exact match first (expanding stripped
/// line-1 indentation when `old` matched mid-line after leading whitespace), then
/// CRLF-adapted match when `content` is dominant-CRLF and `old` contains LF line
/// breaks, then unique multi-line indent / trailing-whitespace fallback.
pub fn resolveSpan(gpa: Allocator, content: []const u8, old: []const u8, new: []const u8) Allocator.Error!ResolvedSpan {
    const exact = std.mem.count(u8, content, old);
    if (exact > 0) {
        if (exact == 1) {
            if (try resolveExactLine1Stripped(gpa, content, old, new)) |span| return span;
        }
        return .{ .old = old, .new = new, .count = exact };
    }
    if (std.mem.indexOfScalar(u8, old, '\n') != null and
        std.mem.indexOf(u8, old, "\r\n") == null and
        isDominantCrlf(content))
    {
        const old_crlf = try lfToCrlf(gpa, old);
        const crlf_count = std.mem.count(u8, content, old_crlf);
        if (crlf_count > 0) {
            if (crlf_count == 1) {
                if (try resolveExactLine1Stripped(gpa, content, old_crlf, new)) |span| {
                    gpa.free(old_crlf);
                    return span;
                }
            }
            const new_crlf = lfToCrlf(gpa, new) catch |err| {
                gpa.free(old_crlf);
                return err;
            };
            return .{
                .old = old_crlf,
                .new = new_crlf,
                .owned_old = old_crlf,
                .owned_new = new_crlf,
                .count = crlf_count,
            };
        }
        gpa.free(old_crlf);
    }
    if (try resolveUniqueIndentSpan(gpa, content, old, new)) |span| return span;
    return .{ .old = old, .new = new, .count = 0 };
}

fn isHorizontalWs(s: []const u8) bool {
    for (s) |c| if (c != ' ' and c != '\t') return false;
    return true;
}

fn leadingWsSlice(line: []const u8) []const u8 {
    var n: usize = 0;
    while (n < line.len and (line[n] == ' ' or line[n] == '\t')) : (n += 1) {}
    return line[0..n];
}

fn wsCols(ws: []const u8) usize {
    var cols: usize = 0;
    for (ws) |c| cols += if (c == '\t') 4 else 1;
    return cols;
}

fn restOfLineIsWs(content: []const u8, pos: usize) bool {
    var i = pos;
    while (i < content.len and content[i] != '\n' and content[i] != '\r') : (i += 1) {
        if (content[i] != ' ' and content[i] != '\t') return false;
    }
    return true;
}

/// True when a stripped line opens an indented block on the next line (e.g. Python
/// `:`, brace/bracket/paren block `{`, `(`, `[`, or line continuation `\`).
fn lineOpensBlock(raw_line: []const u8) bool {
    var s = std.mem.trim(u8, raw_line, " \t\r");
    if (s.len == 0) return false;
    if (std.mem.indexOfScalar(u8, s, '#')) |hash| {
        const before = std.mem.trimEnd(u8, s[0..hash], " \t");
        if (before.len > 0) s = before;
    }
    const last = s[s.len - 1];
    return last == ':' or last == '{' or last == '(' or last == '[' or last == '\\';
}

/// Repair an `exact == 1` match where the model stripped leading horizontal
/// whitespace from line 1 of `old` (either a multi-line `old` whose tail lines
/// kept file indentation, or a full-line single-line `old` replaced by a
/// multi-line `new` starting at column 0).
fn resolveExactLine1Stripped(gpa: Allocator, content: []const u8, old: []const u8, new: []const u8) Allocator.Error!?ResolvedSpan {
    if (old.len == 0 or old[0] == ' ' or old[0] == '\t' or old[0] == '\r' or old[0] == '\n') return null;
    const pos = std.mem.indexOf(u8, content, old) orelse return null;
    const line_start = if (std.mem.lastIndexOfScalar(u8, content[0..pos], '\n')) |nl| nl + 1 else 0;
    if (pos == line_start) return null;
    const prefix_ws = content[line_start..pos];
    if (!isHorizontalWs(prefix_ws)) return null;

    const old_multiline = std.mem.indexOfScalar(u8, old, '\n') != null;
    const new_multiline = std.mem.indexOfScalar(u8, new, '\n') != null;
    if (!old_multiline) {
        if (!new_multiline) return null;
        if (new.len == 0 or new[0] == ' ' or new[0] == '\t') return null;
        if (!restOfLineIsWs(content, pos + old.len)) return null;
    }

    const matched_old = content[line_start .. pos + old.len];
    if (std.mem.count(u8, content, matched_old) != 1) return null;
    const new_reindented = try reindentLine1Stripped(gpa, old, new, prefix_ws, isDominantCrlf(matched_old));
    return .{
        .old = matched_old,
        .new = new_reindented,
        .owned_new = new_reindented,
        .count = 1,
    };
}

fn reindentLine1Stripped(gpa: Allocator, old: []const u8, new: []const u8, prefix_ws: []const u8, use_crlf: bool) Allocator.Error![]u8 {
    const old_lines = try collectLines(gpa, old);
    defer gpa.free(old_lines);
    const new_lines = try collectLines(gpa, new);
    defer gpa.free(new_lines);

    var min_old_tail_cols: ?usize = null;
    if (old_lines.len > 1) {
        for (old_lines[1..]) |ol| {
            const line = old[ol.start..ol.end];
            if (std.mem.trim(u8, line, " \t").len == 0) continue;
            const c = wsCols(leadingWsSlice(line));
            min_old_tail_cols = if (min_old_tail_cols) |m| @min(m, c) else c;
        }
    }

    var min_new_indented_cols: ?usize = null;
    const p_cols = wsCols(prefix_ws);
    var col0_opener_needs_shift = false;
    for (new_lines, 0..) |nl_slice, idx| {
        const line = new[nl_slice.start..nl_slice.end];
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        const c = wsCols(leadingWsSlice(line));
        if (c > 0) {
            min_new_indented_cols = if (min_new_indented_cols) |m| @min(m, c) else c;
        } else if (lineOpensBlock(line)) {
            var next_idx = idx + 1;
            while (next_idx < new_lines.len) : (next_idx += 1) {
                const next_line = new[new_lines[next_idx].start..new_lines[next_idx].end];
                if (std.mem.trim(u8, next_line, " \t").len == 0) continue;
                const next_c = wsCols(leadingWsSlice(next_line));
                if (next_c > 0 and next_c <= p_cols) col0_opener_needs_shift = true;
                break;
            }
        }
    }

    const only_col_zero = if (col0_opener_needs_shift) false else if (min_new_indented_cols) |mnw| blk: {
        if (min_old_tail_cols) |motw| {
            if (motw > 0) break :blk mnw >= motw;
        }
        break :blk mnw >= p_cols;
    } else true;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (new_lines, 0..) |nl_slice, idx| {
        const line = new[nl_slice.start..nl_slice.end];
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) {
            try out.appendSlice(gpa, line);
        } else if (!only_col_zero or leadingWsSlice(line).len == 0) {
            try out.appendSlice(gpa, prefix_ws);
            try out.appendSlice(gpa, line);
        } else {
            try out.appendSlice(gpa, line);
        }
        if (idx + 1 < new_lines.len) {
            if (use_crlf) try out.appendSlice(gpa, "\r\n") else try out.append(gpa, '\n');
        }
    }
    return out.toOwnedSlice(gpa);
}

const LineSlice = struct {
    start: usize,
    end: usize, // excludes '\n' and preceding '\r'
    raw_end: usize, // includes line break in `content` if not last line
};

fn collectLines(gpa: Allocator, text: []const u8) Allocator.Error![]LineSlice {
    var list: std.ArrayList(LineSlice) = .empty;
    errdefer list.deinit(gpa);
    var i: usize = 0;
    while (i <= text.len) {
        const next_nl = std.mem.indexOfScalarPos(u8, text, i, '\n');
        const raw_end = next_nl orelse text.len;
        const end = if (raw_end > i and text[raw_end - 1] == '\r') raw_end - 1 else raw_end;
        try list.append(gpa, .{ .start = i, .end = end, .raw_end = raw_end });
        if (next_nl) |nl| i = nl + 1 else break;
    }
    return list.toOwnedSlice(gpa);
}

const IndentMode = union(enum) {
    none,
    add_prefix: []const u8,
    drop_prefix: []const u8,
    line1_stripped: []const u8,

    fn eql(a: IndentMode, b: IndentMode) bool {
        return switch (a) {
            .none => b == .none,
            .add_prefix => |ap| b == .add_prefix and std.mem.eql(u8, ap, b.add_prefix),
            .drop_prefix => |dp| b == .drop_prefix and std.mem.eql(u8, dp, b.drop_prefix),
            .line1_stripped => |lp| b == .line1_stripped and std.mem.eql(u8, lp, b.line1_stripped),
        };
    }
};

fn resolveUniqueIndentSpan(gpa: Allocator, content: []const u8, old: []const u8, new: []const u8) Allocator.Error!?ResolvedSpan {
    if (std.mem.indexOfScalar(u8, old, '\n') == null) return null;
    const old_trimmed_nl = std.mem.endsWith(u8, old, "\n");
    const old_body = if (old_trimmed_nl) old[0 .. old.len - (if (std.mem.endsWith(u8, old, "\r\n")) @as(usize, 2) else 1)] else old;
    if (std.mem.indexOfScalar(u8, old_body, '\n') == null) return null;

    const old_lines = try collectLines(gpa, old_body);
    defer gpa.free(old_lines);
    const file_lines = try collectLines(gpa, content);
    defer gpa.free(file_lines);
    if (old_lines.len < 2 or file_lines.len < old_lines.len) return null;

    var match_idx: ?usize = null;
    var match_mode: IndentMode = .none;

    const max_start = file_lines.len - old_lines.len;
    var start: usize = 0;
    outer: while (start <= max_start) : (start += 1) {
        var mode_opt: ?IndentMode = null;
        var line0_f_ws: ?[]const u8 = null;
        var tail_nonempty: usize = 0;
        for (old_lines, 0..) |ol, k| {
            const fl = file_lines[start + k];
            const o_slice = std.mem.trimEnd(u8, old_body[ol.start..ol.end], " \t");
            const f_slice = std.mem.trimEnd(u8, content[fl.start..fl.end], " \t");
            if (o_slice.len == 0 and f_slice.len == 0) continue;
            const o_ws = leadingWsSlice(o_slice);
            const f_ws = leadingWsSlice(f_slice);
            const o_trim = o_slice[o_ws.len..];
            const f_trim = f_slice[f_ws.len..];
            if (!std.mem.eql(u8, o_trim, f_trim)) continue :outer;

            if (k > 0) tail_nonempty += 1;
            const line_mode: IndentMode = if (std.mem.eql(u8, o_ws, f_ws))
                .none
            else if (f_ws.len > o_ws.len and std.mem.endsWith(u8, f_ws, o_ws))
                .{ .add_prefix = f_ws[0 .. f_ws.len - o_ws.len] }
            else if (o_ws.len > f_ws.len and std.mem.endsWith(u8, o_ws, f_ws))
                .{ .drop_prefix = o_ws[0 .. o_ws.len - f_ws.len] }
            else
                continue :outer;

            if (k == 0 and o_ws.len == 0 and f_ws.len > 0) line0_f_ws = f_ws;

            if (mode_opt) |prev| {
                if (!prev.eql(line_mode)) {
                    if (line0_f_ws != null and prev.eql(.{ .add_prefix = line0_f_ws.? }) and line_mode == .none) {
                        mode_opt = .{ .line1_stripped = line0_f_ws.? };
                    } else if (prev == .line1_stripped and line_mode == .none) {
                        // still consistent with line-1-only stripped indent
                    } else continue :outer;
                }
            } else mode_opt = line_mode;
        }
        const resolved_mode = mode_opt orelse .none;
        if (resolved_mode == .line1_stripped and tail_nonempty == 0) continue :outer;
        if (match_idx != null) return null; // ambiguous: more than one window matches
        match_idx = start;
        match_mode = resolved_mode;
    }

    const win_start = match_idx orelse return null;
    const first_line = file_lines[win_start];
    const last_line = file_lines[win_start + old_lines.len - 1];
    const span_end = if (old_trimmed_nl and last_line.raw_end < content.len and content[last_line.raw_end] == '\n')
        last_line.raw_end + 1
    else
        last_line.end;
    const matched_old = content[first_line.start..span_end];
    if (std.mem.count(u8, content, matched_old) != 1) return null;

    const use_crlf = isDominantCrlf(matched_old);
    const new_reindented = switch (match_mode) {
        .line1_stripped => |lp| try reindentLine1Stripped(gpa, old, new, lp, use_crlf),
        else => try reindentPrefixMode(gpa, new, match_mode, use_crlf),
    };
    return .{
        .old = matched_old,
        .new = new_reindented,
        .owned_new = new_reindented,
        .count = 1,
    };
}

fn reindentPrefixMode(gpa: Allocator, new: []const u8, mode: IndentMode, use_crlf: bool) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i <= new.len) {
        const nl = std.mem.indexOfScalarPos(u8, new, i, '\n');
        const raw_end = nl orelse new.len;
        const line_end = if (raw_end > i and new[raw_end - 1] == '\r') raw_end - 1 else raw_end;
        const line = new[i..line_end];
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) {
            try out.appendSlice(gpa, line);
        } else switch (mode) {
            .add_prefix => |ap| {
                try out.appendSlice(gpa, ap);
                try out.appendSlice(gpa, line);
            },
            .drop_prefix => |dp| {
                var drop: usize = 0;
                while (drop < dp.len and drop < line.len and line[drop] == dp[drop]) : (drop += 1) {}
                try out.appendSlice(gpa, line[drop..]);
            },
            .none, .line1_stripped => try out.appendSlice(gpa, line),
        }
        if (nl) |n| {
            if (use_crlf) try out.appendSlice(gpa, "\r\n") else try out.append(gpa, '\n');
            i = n + 1;
        } else break;
    }
    return out.toOwnedSlice(gpa);
}

test "edit_match: resolveSpan matches LF spans against a CRLF file and preserves CRLF in new_string" {
    const gpa = std.testing.allocator;
    const content = "fn main() {\r\n    const x = 1;\r\n    return x;\r\n}\r\n";
    const span = try resolveSpan(gpa, content, "    const x = 1;\n    return x;", "    const x = 42;\n    return x;");
    defer span.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), span.count);
    try std.testing.expectEqualStrings("    const x = 1;\r\n    return x;", span.old);
    try std.testing.expectEqualStrings("    const x = 42;\r\n    return x;", span.new);
}

test "edit_match: unique uniform-indent and trailing-whitespace fallback shifts new_string and refuses ambiguous matches" {
    const gpa = std.testing.allocator;
    const content =
        "fn compute() usize {\n" ++
        "    const alpha = 10;   \n" ++
        "    const beta = 20;\n" ++
        "    return alpha + beta;\n" ++
        "}\n";
    // Model supplies 2-space indent instead of 4-space indent and omits trailing spaces on line 1.
    const span = try resolveSpan(
        gpa,
        content,
        "  const alpha = 10;\n  const beta = 20;",
        "  const alpha = 100;\n  const beta = 200;",
    );
    defer span.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), span.count);
    try std.testing.expectEqualStrings("    const alpha = 10;   \n    const beta = 20;", span.old);
    try std.testing.expectEqualStrings("    const alpha = 100;\n    const beta = 200;", span.new);

    // Ambiguous duplicate block must not match via fallback.
    const dup_content = content ++ content;
    const dup_span = try resolveSpan(
        gpa,
        dup_content,
        "  const alpha = 10;\n  const beta = 20;",
        "  const alpha = 100;\n  const beta = 200;",
    );
    defer dup_span.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), dup_span.count);
}

test "edit_match: #1880 repairs stripped line-1 indent on exact and fallback spans without breaking Python or inline calls" {
    const gpa = std.testing.allocator;
    const py_file =
        "class Stream:\n" ++
        "    def iter_json(self):\n" ++
        "        return self._rows\n";

    // Decorator + method added when line 1 stripped its 4-space class indent, body kept 8-space indent.
    {
        const span = try resolveSpan(
            gpa,
            py_file,
            "def iter_json(self):\n        return self._rows",
            "@cached\ndef iter_json(self):\n        if not self._rows:\n            return []\n        return self._rows",
        );
        defer span.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), span.count);
        try std.testing.expectEqualStrings("    def iter_json(self):\n        return self._rows", span.old);
        try std.testing.expectEqualStrings(
            "    @cached\n    def iter_json(self):\n        if not self._rows:\n            return []\n        return self._rows",
            span.new,
        );
    }

    // Whole replacement written relative to column 0 when line 1 stripped its 4-space class indent.
    {
        const span = try resolveSpan(
            gpa,
            py_file,
            "def iter_json(self):\n        return self._rows",
            "def iter_json(self):\n    return list(self._rows)",
        );
        defer span.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), span.count);
        try std.testing.expectEqualStrings("    def iter_json(self):\n        return list(self._rows)", span.new);
    }

    // Single-line old_string stripped of leading indent replaced by multi-line new_string.
    {
        const span = try resolveSpan(
            gpa,
            py_file,
            "return self._rows",
            "if self._rows is None:\n    return []\nreturn self._rows",
        );
        defer span.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), span.count);
        try std.testing.expectEqualStrings("        return self._rows", span.old);
        try std.testing.expectEqualStrings(
            "        if self._rows is None:\n            return []\n        return self._rows",
            span.new,
        );
    }

    // Fallback path (exact == 0 due to trailing whitespace on line 1) + stripped line-1 indent + tabs.
    {
        const tabbed = "func run() {\n\tif ready() {   \n\t\twork()\n\t}\n}\n";
        const span = try resolveSpan(
            gpa,
            tabbed,
            "if ready() {\n\t\twork()\n\t}",
            "if ready() && active() {\n\t\twork()\n\t}",
        );
        defer span.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), span.count);
        try std.testing.expectEqualStrings("\tif ready() {   \n\t\twork()\n\t}", span.old);
        try std.testing.expectEqualStrings("\tif ready() && active() {\n\t\twork()\n\t}", span.new);
    }

    // Mid-line non-whitespace prefix (inline call) must stay exact and never steal `"    x = "`.
    {
        const call_file = "    x = compute(\n        1,\n    )\n";
        const span = try resolveSpan(gpa, call_file, "compute(\n        1,\n    )", "compute(\n        2,\n    )");
        defer span.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), span.count);
        try std.testing.expectEqualStrings("compute(\n        1,\n    )", span.old);
        try std.testing.expectEqualStrings("compute(\n        2,\n    )", span.new);
    }
}
