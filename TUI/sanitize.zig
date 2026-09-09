//! History-entry sanitizer: drop terminal controls and citation PUA (#805).

const std = @import("std");
const theme_mod = @import("theme.zig");

fn citeSkip(text: []const u8, i: usize) usize {
    if (i + 2 >= text.len) return i;
    if (text[i] != 0xEE or text[i + 1] != 0x88) return i;
    const b = text[i + 2];
    if (b < 0x80 or b > 0x82) return i;
    if (b != 0x80) return i + 3;
    var j = i + 3;
    while (j + 2 < text.len) {
        if (text[j] == 0xEE and text[j + 1] == 0x88 and text[j + 2] == 0x81) return j + 3;
        j += 1;
    }
    return text.len;
}

fn citeContains(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (citeSkip(text, i) != i) return true;
    }
    return false;
}

/// History entries render verbatim inside the alt screen — drop escape
/// sequences, stray C0, and provider citation annotations a model may carry.
pub fn sanitized(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var dirty = citeContains(text);
    if (!dirty) {
        for (text) |c| {
            if (c == 0x1b or c == 0x7f or (c < 0x20 and c != '\n' and c != '\t')) {
                dirty = true;
                break;
            }
        }
    }
    if (!dirty) return alloc.dupe(u8, text);
    var out = std.array_list.Managed(u8).init(alloc);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < text.len) {
        const skipped = citeSkip(text, i);
        if (skipped != i) {
            i = skipped;
            continue;
        }
        const c = text[i];
        if (c == 0x1b) {
            i = theme_mod.skipEsc(text, i);
            continue;
        }
        if ((c < 0x20 and c != '\n' and c != '\t') or c == 0x7f) {
            i += 1;
            continue;
        }
        try out.append(c);
        i += 1;
    }
    return out.toOwnedSlice();
}

test "citation control markup is stripped from TUI history (#805)" {
    const a = std.testing.allocator;
    const raw = "hello\u{E200}cite\u{E202}turn0view0\u{E201} world";
    const got = try sanitized(a, raw);
    defer a.free(got);
    try std.testing.expectEqualStrings("hello world", got);
}

test "C0 still drops without touching letters" {
    const a = std.testing.allocator;
    const got = try sanitized(a, "safe\x07text\rhere");
    defer a.free(got);
    try std.testing.expectEqualStrings("safetexthere", got);
}
