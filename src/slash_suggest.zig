//! Nearest-spelling lookup for a mistyped slash command (#1275).
//!
//! Its own module so the line REPL / ACP catalog (src/command_catalog.zig) and
//! the fullscreen TUI catalog (TUI/catalog.zig) share one implementation: a
//! file import from both modules is illegal in Zig 0.17 (see models_rank).
//! Tests live with the callers, which the test roots reach.

const std = @import("std");

/// No command is this long, so nothing longer is a typo of one.
pub const max_len = 64;

/// Optimal-string-alignment distance: Levenshtein plus one adjacent
/// transposition (`resuem` -> `resume` is 1), ASCII case-insensitive.
/// null when either side is longer than max_len.
pub fn distance(a: []const u8, b: []const u8) ?usize {
    if (a.len > max_len or b.len > max_len) return null;
    var prev2: [max_len + 1]usize = undefined;
    var prev: [max_len + 1]usize = undefined;
    var cur: [max_len + 1]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 1..) |ca, i| {
        cur[0] = i;
        for (b, 1..) |cb, j| {
            const cost: usize = if (eq(ca, cb)) 0 else 1;
            var d = @min(@min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
            if (i > 1 and j > 1 and eq(ca, b[j - 2]) and eq(a[i - 2], cb)) d = @min(d, prev2[j - 2] + 1);
            cur[j] = d;
        }
        prev2 = prev;
        prev = cur;
    }
    return prev[b.len];
}

fn eq(x: u8, y: u8) bool {
    return std.ascii.toLower(x) == std.ascii.toLower(y);
}

/// Edits tolerated for a word of `len` letters: none under 3 (too many
/// two-letter commands to guess between), 1 up to 5, then 2.
pub fn threshold(len: usize) usize {
    return @min(2, len / 3);
}

/// The candidate `word` most likely misspells, or null when none is within
/// threshold. Both sides may carry the leading `/`; ties keep list order.
pub fn nearest(word: []const u8, candidates: []const []const u8) ?[]const u8 {
    const w = std.mem.trimStart(u8, word, "/");
    if (w.len == 0) return null;
    const limit = threshold(w.len);
    var best: ?[]const u8 = null;
    var best_d: usize = limit + 1;
    for (candidates) |c| {
        const d = distance(w, std.mem.trimStart(u8, c, "/")) orelse continue;
        if (d < best_d) {
            best = c;
            best_d = d;
        }
    }
    return best;
}
