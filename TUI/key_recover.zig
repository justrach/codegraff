//! Decode a proven escape sequence split between a saved head and a full read.
//! Kept separate so key_orphan.zig remains below the 600-line ceiling.

const key = @import("key.zig");
const Key = key.Key;

pub const Event = struct { event: Key, tail_len: usize };
const max_body = 128;

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
            const total = head.len + tail.len;
            if (total <= 2) return .{ .event = .escape, .tail_len = 0 };
            if (head.len >= 2) {
                var buf: [max_body]u8 = undefined;
                const rest = head[2..];
                if (1 + rest.len > buf.len) return null;
                buf[0] = head[0];
                @memcpy(buf[1..][0..rest.len], rest);
                return completed(buf[0 .. 1 + rest.len], tail);
            }
            return if (completed(head, tail[1..])) |ev|
                .{ .event = ev.event, .tail_len = ev.tail_len + 1 }
            else
                null;
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
