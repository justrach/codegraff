const std = @import("std");

pub const Unwrapped = struct {
    url: []const u8,
    suffix: []const u8,
    removed: usize,
};

const Pair = struct { open: []const u8, close: []const u8 };
const pairs = [_]Pair{
    .{ .open = "**", .close = "**" },
    .{ .open = "__", .close = "__" },
    .{ .open = "~~", .close = "~~" },
    .{ .open = "*", .close = "*" },
    .{ .open = "_", .close = "_" },
    .{ .open = "`", .close = "`" },
};

fn isSentencePunctuation(b: u8) bool {
    return std.mem.indexOfScalar(u8, ".,;!?:", b) != null;
}

fn unwrapCore(core: []const u8, suffix: []const u8) ?Unwrapped {
    var value = core;
    var removed: usize = 0;
    while (true) {
        var matched = false;
        for (pairs) |pair| {
            if (value.len <= pair.open.len + pair.close.len or
                !std.mem.startsWith(u8, value, pair.open) or
                !std.mem.endsWith(u8, value, pair.close)) continue;
            value = value[pair.open.len .. value.len - pair.close.len];
            removed += pair.open.len + pair.close.len;
            matched = true;
            break;
        }
        if (!matched) break;
    }
    if (removed == 0 or !(std.mem.startsWith(u8, value, "http://") or std.mem.startsWith(u8, value, "https://"))) return null;
    return .{ .url = value, .suffix = suffix, .removed = removed };
}

/// Remove balanced Markdown wrappers from a complete whitespace-delimited URL
/// token. The same marker bytes remain untouched when the token itself starts
/// with HTTP, so legal URL tails and interior marker runs are never guessed at.
pub fn unwrapToken(token: []const u8) ?Unwrapped {
    if (unwrapCore(token, "")) |match| return match;
    var core_end = token.len;
    while (core_end > 0 and isSentencePunctuation(token[core_end - 1])) {
        core_end -= 1;
        if (unwrapCore(token[0..core_end], token[core_end..])) |match| return match;
    }
    return null;
}

pub fn containsHttp(value: []const u8) bool {
    return std.mem.indexOf(u8, value, "http://") != null or std.mem.indexOf(u8, value, "https://") != null;
}

pub fn codepointCount(s: []const u8) usize {
    var count: usize = 0;
    for (s) |b| {
        if ((b & 0xC0) != 0x80) count += 1;
    }
    return count;
}

pub fn inlineVisibleLen(s: []const u8) usize {
    var i: usize = 0;
    var count: usize = 0;
    while (i < s.len) {
        if (s[i] == '*' or s[i] == '_' or s[i] == '~' or s[i] == '`' or s[i] == 'h') {
            var token_end = i;
            while (token_end < s.len and s[token_end] != ' ') token_end += 1;
            if (unwrapToken(s[i..token_end])) |match| {
                count += codepointCount(match.url) + codepointCount(match.suffix);
                i = token_end;
                continue;
            }
            if (std.mem.startsWith(u8, s[i..], "http://") or std.mem.startsWith(u8, s[i..], "https://")) {
                count += codepointCount(s[i..token_end]);
                i = token_end;
                continue;
            }
        }
        if (i + 1 < s.len and s[i] == '*' and s[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, s, i + 2, "**")) |end| {
                count += codepointCount(s[i + 2 .. end]);
                i = end + 2;
                continue;
            }
        }
        if (s[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, s, i + 1, '`')) |end| {
                count += codepointCount(s[i + 1 .. end]);
                i = end + 1;
                continue;
            }
        }
        if ((s[i] & 0xC0) != 0x80) count += 1;
        i += 1;
    }
    return count;
}

test "unwraps supported wrappers and preserves URL markers" {
    const url = "https://example.test/a";
    inline for (.{ "*", "**", "_", "__", "~~", "`" }) |pair| {
        const match = unwrapToken(pair ++ url ++ pair ++ ".").?;
        try std.testing.expectEqualStrings(url, match.url);
        try std.testing.expectEqualStrings(".", match.suffix);
    }
    try std.testing.expect(unwrapToken("https://example.test/glob/**") == null);
    try std.testing.expect(unwrapToken("https://example.test/a**b") == null);
}
