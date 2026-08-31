//! Decode a proven escape sequence split between a saved head and a full read.
//! Kept separate so key_orphan.zig remains below the 600-line ceiling.

const key = @import("key.zig");
const Key = key.Key;

pub const Event = struct { event: Key, tail_len: usize };
const max_body = 128;

pub fn legacyCsiPrefix(head: []const u8, tail: []const u8, n: usize) bool {
    if (n == 2) return true;
    if (n < 3 or at(head, tail, 2) != '[') return false;
    for (3..n) |i| {
        const c = at(head, tail, i);
        if (c < 0x20 or c > 0x3f) return false;
    }
    return true;
}

pub fn legacyCsiNavigation(params: []const u8, final: u8) bool {
    if (final < 'A' or final > 'D') return false;
    if (params.len == 0) return true;
    var semicolon = false;
    var field: u32 = 0;
    var need_digit = true;
    for (params) |c| {
        if (c >= '0' and c <= '9') {
            field = field *| 10 +| (c - '0');
            need_digit = false;
        } else if (c == ';' and !need_digit) {
            semicolon = true;
            field = 0;
            need_digit = true;
        } else return false;
    }
    return !need_digit and (!semicolon or field == 3);
}

fn legacyNavigation(head: []const u8, tail: []const u8, start: usize, end: usize, final: u8) bool {
    var params_buf: [max_body]u8 = undefined;
    const params = combinedSlice(head, tail, start, end, &params_buf) orelse return false;
    return legacyCsiNavigation(params, final);
}

pub fn legacyCsiBoundary(params: []const u8, final: u8, bytes: []const u8, after: usize) bool {
    if (!legacyCsiNavigation(params, final)) return true;
    // A complete navigation may share a read with the next printable key.
    // Reject only recognizable bracketed prose, not every printable suffix.
    var i = after;
    while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x7e) : (i += 1) {
        if (bytes[i] == ']') return false;
    }
    return true;
}

/// A recovered double-ESC prefix that was followed by bracketed prose. Return
/// the literal CSI prefix so the recovery path can preserve the human text.
pub fn legacyCsiProse(head: []const u8, tail: []const u8, n: usize) ?usize {
    if (head.len < 3 or at(head, tail, 0) != 0x1b or at(head, tail, 1) != 0x1b or at(head, tail, 2) != '[') return null;
    var i: usize = 3;
    while (i < n and at(head, tail, i) >= 0x20 and at(head, tail, i) <= 0x3f) : (i += 1) {}
    if (i >= n or !legacyNavigation(head, tail, 3, i, at(head, tail, i))) return null;
    if (i + 1 >= n or at(head, tail, i + 1) < 0x20 or at(head, tail, i + 1) == 0x7f) return null;
    while (i < n and at(head, tail, i) >= 0x20 and at(head, tail, i) <= 0x7e) : (i += 1) {
        if (at(head, tail, i) == ']') return head.len - 2;
    }
    return null;
}

pub fn legacyDoubleEscape(i: *usize, start: usize) Key {
    i.* = start - 1;
    return .escape;
}

pub fn legacyCsiComplete(head: []const u8, tail: []const u8, n: usize, dropped: bool) bool {
    var i: usize = 3;
    while (i < n) : (i += 1) {
        const c = at(head, tail, i);
        if (c >= 0x20 and c <= 0x3f) continue;
        if (!legacyNavigation(head, tail, 3, i, c)) return false;
        if (legacyCsiProse(head, tail, n) != null) return false;
        const control = i + 1 < n and (at(head, tail, i + 1) < 0x20 or at(head, tail, i + 1) == 0x7f);
        return i + 1 == n or control or (dropped and legacyNavigation(head, tail, 3, i, c));
    }
    return false;
}

fn at(head: []const u8, tail: []const u8, i: usize) u8 {
    return if (i < head.len) head[i] else tail[i - head.len];
}

fn combinedSlice(head: []const u8, tail: []const u8, start: usize, end: usize, out: *[max_body]u8) ?[]const u8 {
    const len = end - start;
    if (len > out.len) return null;
    for (start..end, 0..) |i, j| out[j] = at(head, tail, i);
    return out[0..len];
}

/// Decode one sequence key_orphan has already proved. Unsupported framed
/// strings become ignore, but their exact completing bytes are still consumed.
pub fn completed(head: []const u8, tail: []const u8) ?Event {
    const n = head.len + tail.len;
    switch (at(head, tail, 1)) {
        0x1b => {
            if (n <= 2 or at(head, tail, 2) != '[') return .{ .event = .escape, .tail_len = 0 };
            var final_at: usize = 3;
            while (final_at < n and at(head, tail, final_at) >= 0x20 and at(head, tail, final_at) <= 0x3f) : (final_at += 1) {}
            if (final_at >= n) return null;
            var params_buf: [max_body]u8 = undefined;
            const params = combinedSlice(head, tail, 3, final_at, &params_buf) orelse return null;
            const event_end = final_at + 1;
            if (event_end < head.len) return null;
            return .{ .event = key.decodeCsi(params, at(head, tail, final_at)), .tail_len = event_end - head.len };
        },
        'O' => {
            if (head.len > 3) return null;
            return .{ .event = key.decodeSs3(at(head, tail, 2)), .tail_len = 3 - head.len };
        },
        '[' => {
            var final_at: usize = 2;
            while (final_at < n and at(head, tail, final_at) >= 0x20 and at(head, tail, final_at) <= 0x3f) : (final_at += 1) {}
            if (final_at >= n) return null;
            const final = at(head, tail, final_at);
            var event: Key = .ignore;
            var event_end = final_at + 1;
            if (final == 'M' and final_at == 2) {
                event_end = 6;
                var payload: [3]u8 = undefined;
                for (3..6, 0..) |i, j| payload[j] = at(head, tail, i);
                event = key.decodeX10(&payload);
            } else {
                var params_buf: [max_body]u8 = undefined;
                if (combinedSlice(head, tail, 2, final_at, &params_buf)) |params|
                    event = key.decodeCsi(params, final);
            }
            if (event_end < head.len) return null;
            return .{ .event = event, .tail_len = event_end - head.len };
        },
        ']', 'P', '_', '^', 'X' => {
            var body_end: usize = 2;
            var event_end: usize = 0;
            while (body_end < n) : (body_end += 1) {
                const c = at(head, tail, body_end);
                if (c == 0x07) {
                    event_end = body_end + 1;
                    break;
                }
                if (c == 0x1b and body_end + 1 < n and at(head, tail, body_end + 1) == '\\') {
                    event_end = body_end + 2;
                    break;
                }
            }
            if (event_end == 0 or event_end < head.len) return null;
            var event: Key = .ignore;
            if (at(head, tail, 1) == ']') {
                var body_buf: [max_body]u8 = undefined;
                if (combinedSlice(head, tail, 2, body_end, &body_buf)) |body|
                    event = key.oscReply(']', body);
            }
            return .{ .event = event, .tail_len = event_end - head.len };
        },
        else => return null,
    }
}
