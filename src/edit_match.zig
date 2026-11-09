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
/// match when `content` is dominant-CRLF and `old` contains LF line breaks.
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
    return .{ .old = old, .new = new, .count = 0 };
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
