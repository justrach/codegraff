//! Display-column math (wcwidth-style) for the fullscreen TUI (#518).
//! Same table as src/repl_markdown.zig codepointWidth — the REPL build can't
//! import the tui module, so the table lives twice; change both together.

const std = @import("std");

/// Display columns for one codepoint: 0 for combining / zero-width marks,
/// 2 for East-Asian wide + emoji, 1 otherwise.
pub fn codepointWidth(cp: u21) usize {
    if (cp < 0x300) return 1; // ASCII + Latin-1 (control bytes stay 1)
    if ((cp >= 0x300 and cp <= 0x36F) or // combining diacritical marks
        (cp >= 0x200B and cp <= 0x200F) or // ZWSP..RLM
        (cp >= 0xFE00 and cp <= 0xFE0F) or // variation selectors
        cp == 0xFEFF) return 0; // BOM / ZWNBSP
    if ((cp >= 0x1100 and cp <= 0x115F) or // Hangul Jamo
        (cp >= 0x2E80 and cp <= 0x303E) or // CJK radicals .. symbols
        (cp >= 0x3041 and cp <= 0x33FF) or // kana .. CJK compat
        (cp >= 0x3400 and cp <= 0x4DBF) or // CJK ext A
        (cp >= 0x4E00 and cp <= 0x9FFF) or // CJK unified
        (cp >= 0xA000 and cp <= 0xA4CF) or // Yi
        (cp >= 0xAC00 and cp <= 0xD7A3) or // Hangul syllables
        (cp >= 0xF900 and cp <= 0xFAFF) or // CJK compat ideographs
        (cp >= 0xFE30 and cp <= 0xFE4F) or // CJK compat forms
        (cp >= 0xFF00 and cp <= 0xFF60) or // fullwidth forms
        (cp >= 0xFFE0 and cp <= 0xFFE6) or // fullwidth signs
        (cp >= 0x1F000 and cp <= 0x1F02F) or // mahjong tiles
        (cp >= 0x1F0A0 and cp <= 0x1F0FF) or // playing cards
        (cp >= 0x1F100 and cp <= 0x1F1FF) or // enclosed alphanumeric / regional
        (cp >= 0x1F300 and cp <= 0x1FAFF) or // emoji & pictographs
        (cp >= 0x20000 and cp <= 0x3FFFD)) return 2; // CJK ext B+
    return 1;
}

pub const Glyph = struct { step: usize, cols: usize };

/// One UTF-8 codepoint at s[i]: its byte length and display columns.
/// Invalid bytes advance 1 byte / 1 column so malformed input cannot loop.
pub fn glyph(s: []const u8, i: usize) Glyph {
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .step = 1, .cols = 1 };
    const end = @min(i + len, s.len);
    const cols = if (std.unicode.utf8Decode(s[i..end])) |cp| codepointWidth(cp) else |_| 1;
    return .{ .step = end - i, .cols = cols };
}

test "codepointWidth: ASCII 1, CJK/emoji 2, combining 0" {
    try std.testing.expectEqual(@as(usize, 1), codepointWidth('a'));
    try std.testing.expectEqual(@as(usize, 2), codepointWidth('日'));
    try std.testing.expectEqual(@as(usize, 2), codepointWidth(0x1F409)); // 🐉
    try std.testing.expectEqual(@as(usize, 0), codepointWidth(0x0301)); // combining acute
}
