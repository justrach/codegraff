//! Shared span resolution for `edit_file` (`edit_verify.zig` and `edit_batch.zig`):
//! exact byte match first, falling back to dominant-CRLF line-ending normalization
//! when the model supplies LF (`\n`) spans against a CRLF (`\r\n`) file.

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

/// Resolve `(old, new)` against `content`: exact match first, then CRLF-adapted
/// match when `content` is dominant-CRLF and `old` contains LF line breaks, then
/// unique multi-line uniform-indent / trailing-whitespace fallback.
pub fn resolveSpan(gpa: Allocator, content: []const u8, old: []const u8, new: []const u8) Allocator.Error!ResolvedSpan {
    const exact = std.mem.count(u8, content, old);
    if (exact > 0) return .{ .old = old, .new = new, .count = exact };
    if (std.mem.indexOfScalar(u8, old, '\n') != null and
        std.mem.indexOf(u8, old, "\r\n") == null and
        isDominantCrlf(content))
    {
        const old_crlf = try lfToCrlf(gpa, old);
        const crlf_count = std.mem.count(u8, content, old_crlf);
        if (crlf_count > 0) {
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

fn leadingSpaces(line: []const u8) ?usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') : (n += 1) {}
    if (n < line.len and line[n] == '\t') return null;
    return n;
}

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
    var match_delta: isize = 0;

    const max_start = file_lines.len - old_lines.len;
    var start: usize = 0;
    outer: while (start <= max_start) : (start += 1) {
        var delta_opt: ?isize = null;
        for (old_lines, 0..) |ol, k| {
            const fl = file_lines[start + k];
            const o_slice = std.mem.trimEnd(u8, old_body[ol.start..ol.end], " \t");
            const f_slice = std.mem.trimEnd(u8, content[fl.start..fl.end], " \t");
            if (o_slice.len == 0 and f_slice.len == 0) continue;
            const o_trim = std.mem.trimStart(u8, o_slice, " \t");
            const f_trim = std.mem.trimStart(u8, f_slice, " \t");
            if (!std.mem.eql(u8, o_trim, f_trim)) continue :outer;
            if (std.mem.eql(u8, o_slice, f_slice)) {
                if (delta_opt) |d| {
                    if (d != 0) continue :outer;
                } else delta_opt = 0;
                continue;
            }
            const o_sp = leadingSpaces(o_slice) orelse continue :outer;
            const f_sp = leadingSpaces(f_slice) orelse continue :outer;
            const d: isize = @as(isize, @intCast(f_sp)) - @as(isize, @intCast(o_sp));
            if (delta_opt) |prev_d| {
                if (prev_d != d) continue :outer;
            } else delta_opt = d;
        }
        if (match_idx != null) return null; // ambiguous: more than one window matches
        match_idx = start;
        match_delta = delta_opt orelse 0;
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

    const new_reindented = try reindentBlock(gpa, new, match_delta, isDominantCrlf(matched_old));
    return .{
        .old = matched_old,
        .new = new_reindented,
        .owned_new = new_reindented,
        .count = 1,
    };
}

fn reindentBlock(gpa: Allocator, new: []const u8, delta: isize, use_crlf: bool) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < new.len) {
        const nl = std.mem.indexOfScalarPos(u8, new, i, '\n');
        const raw_end = nl orelse new.len;
        const line_end = if (raw_end > i and new[raw_end - 1] == '\r') raw_end - 1 else raw_end;
        const line = new[i..line_end];
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) {
            try out.appendSlice(gpa, line);
        } else if (delta > 0) {
            try out.appendNTimes(gpa, ' ', @intCast(delta));
            try out.appendSlice(gpa, line);
        } else if (delta < 0) {
            const drop: usize = @intCast(-delta);
            var sp: usize = 0;
            while (sp < drop and sp < line.len and line[sp] == ' ') : (sp += 1) {}
            try out.appendSlice(gpa, line[sp..]);
        } else {
            try out.appendSlice(gpa, line);
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
