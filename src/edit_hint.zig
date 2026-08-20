//! Nearest-match hint when `edit_file` cannot find `old_string`.
//!
//! Same recovery grok-build's `search_replace` uses on a miss: take the
//! longest whitespace token on the first `old_string` line, find the first
//! file line that contains it, and name that line. The splice stays
//! byte-exact (ADR 0014) — this is only the error text.

const std = @import("std");
const Allocator = std.mem.Allocator;

const stem = "old_string not found in {s} — read_file it and match the existing text exactly";

/// Caller owns the slice.
pub fn notFound(gpa: Allocator, path: []const u8, file: []const u8, old: []const u8) ![]u8 {
    const hint = try nearestSuffix(gpa, file, old);
    defer gpa.free(hint);
    if (hint.len == 0) return std.fmt.allocPrint(gpa, stem, .{path});
    return std.fmt.allocPrint(gpa, stem ++ "{s}", .{ path, hint });
}

fn firstLine(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\n')) |i| {
        const line = s[0..i];
        return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
    }
    return s;
}

fn longestToken(line: []const u8) []const u8 {
    var best: []const u8 = "";
    var it = std.mem.tokenizeAny(u8, line, " \t");
    while (it.next()) |w| {
        if (w.len > best.len) best = w;
    }
    return best;
}

fn displayLine(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

/// `"\n\nNearest match: line N: …"` or empty. Caller owns the slice.
fn nearestSuffix(gpa: Allocator, file: []const u8, old: []const u8) ![]u8 {
    const keyword = longestToken(firstLine(old));
    if (keyword.len == 0) return gpa.dupe(u8, "");
    var line_no: usize = 1;
    var rest = file;
    while (true) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const raw = if (nl) |i| rest[0..i] else rest;
        const shown = displayLine(raw);
        if (std.mem.indexOf(u8, shown, keyword) != null) {
            const cap = 160;
            const clip = if (shown.len > cap) shown[0..cap] else shown;
            const dots: []const u8 = if (shown.len > cap) "..." else "";
            return std.fmt.allocPrint(gpa, "\n\nNearest match: line {d}: {s}{s}", .{ line_no, clip, dots });
        }
        if (nl) |i| {
            rest = rest[i + 1 ..];
            line_no += 1;
        } else break;
    }
    return gpa.dupe(u8, "");
}

test "nearest match names the first line holding the longest first-line token" {
    const gpa = std.testing.allocator;
    const file = "alpha\nfn parseHeader() void {\n}\n";
    const msg = try notFound(gpa, "src/a.zig", file, "fn parseHeader() i32 {");
    defer gpa.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Nearest match: line 2: fn parseHeader() void {") != null);
}

test "nearest match stays quiet when no token from old_string appears" {
    const gpa = std.testing.allocator;
    const msg = try notFound(gpa, "f.txt", "hello world\n", "xyz");
    defer gpa.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "Nearest match") == null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "read_file") != null);
}
