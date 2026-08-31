//! Escape-sequence debris recovery, parked out of key.zig under the 600-line
//! ceiling.
//!
//! Two halves of one problem: the read loop gives up on a truncated escape
//! head once the terminal goes quiet (an ssh/tmux hiccup mid-sequence), and
//! that sequence's tail can still land on a LATER read with its introducer
//! gone.
//!
//!   * `stashHead`/`joinHead` keep the abandoned head for the next read and
//!     re-attach it when the new bytes really do complete it. A dropped
//!     non-lone head keeps that exact framing for the full recovery interval;
//!     a delivered Escape keeps its shorter, ambiguity-limited carry. The tail
//!     then parses as the thing it always was, with no shape guessing
//!     (#530/#531).
//!   * `take` is the fallback once that exact carry is gone. After a genuine
//!     Escape it accepts only bodies distinguishable from prose (mouse, kitty,
//!     paste, terminated OSC); short CSI/SS3 spellings remain text (#537).

const std = @import("std");
const key = @import("key.zig");
const recover = @import("key_recover.zig");
const Key = key.Key;

/// Set by the read loop when it abandons a truncated escape head: the NEXT
/// read may legitimately open with that sequence's orphaned tail.
pub var armed: bool = false;
/// Narrow arm used after a lone ESC was delivered as a genuine key. Its late
/// body must retain a CSI/SS3/OSC introducer; accepting headless parameter runs
/// here would eat ordinary text such as `3u apples` after a real Escape.
pub var escape_armed: bool = false;

/// End offset of the last fragment consumed from the buffer currently being
/// parsed, so back-to-back debris keeps being eaten while a digit run that
/// follows real input never is. `maxInt` = no run in progress.
pub var end: usize = std.math.maxInt(usize);

/// Longest head worth carrying. Real CSI/OSC heads are far shorter; anything
/// bigger is a parser wedge, not a sequence.
const max_head = 64;
var head: [max_head]u8 = undefined;
var head_len: usize = 0;
const RecoveredPaste = enum { start, end };
var recovered_event: ?Key = null;

pub fn reset() void {
    disarm();
    end = std.math.maxInt(usize);
    head_len = 0;
    recovered_event = null;
}

pub fn armDropped() void {
    armed = true;
    escape_armed = false;
}

pub fn armEscape() void {
    armed = false;
    escape_armed = true;
}

pub fn disarm() void {
    armed = false;
    escape_armed = false;
    head_len = 0;
    recovered_event = null;
}

/// Expire only the short exact carry used after a genuine Escape. A non-lone
/// sequence that the loop actually dropped is stronger evidence, so its exact
/// framing remains until the broad recovery interval expires or the next read
/// spends it.
pub fn expireHead() void {
    if (!armed) head_len = 0;
}

/// Keep the head the loop just gave up on. `joinHead` may extend it with valid
/// partial tails, but any mismatch spends it before fresh input is parsed.
pub fn stashHead(bytes: []const u8) void {
    head_len = 0;
    recovered_event = null;
    if (bytes.len == 0 or bytes.len > max_head) return;
    @memcpy(head[0..bytes.len], bytes);
    head_len = bytes.len;
}

const PasteProgress = union(enum) {
    partial,
    complete: struct { kind: RecoveredPaste, tail_len: usize },
};

fn pasteProgress(h: []const u8, t: []const u8) ?PasteProgress {
    const markers = [_]struct { bytes: []const u8, kind: RecoveredPaste }{
        .{ .bytes = "\x1b[200~", .kind = .start },
        .{ .bytes = "\x1b[201~", .kind = .end },
    };
    const n = h.len + t.len;
    for (markers) |marker| {
        if (h.len >= marker.bytes.len) continue;
        var k: usize = 0;
        while (k < @min(n, marker.bytes.len) and at(h, t, k) == marker.bytes[k]) : (k += 1) {}
        if (k != @min(n, marker.bytes.len)) continue;
        if (n < marker.bytes.len) return .partial;
        return .{ .complete = .{ .kind = marker.kind, .tail_len = marker.bytes.len - h.len } };
    }
    return null;
}

/// A dropped exact head may itself be split over several late reads. Retain
/// only prefixes that can still become the same framed sequence, under the
/// same 64-byte and one-second bounds as the original head.
fn validPartial(h: []const u8, t: []const u8) bool {
    const n = h.len + t.len;
    if (n == 0 or n > max_head or at(h, t, 0) != 0x1b) return false;
    if (n == 1) return true;
    switch (at(h, t, 1)) {
        0x1b => return recover.legacyCsiPrefix(h, t, n),
        'O' => return n < 3,
        '[' => {
            var k: usize = 2;
            while (k < n) : (k += 1) {
                const c = at(h, t, k);
                if (c >= 0x20 and c <= 0x3f) continue;
                if (k == 2 and c == 'M') {
                    if (n >= 6) return false;
                    for (k + 1..n) |payload| if (at(h, t, payload) == 0x1b) return false;
                    return true;
                }
                return false; // a final is complete or invalid, never partial
            }
            return true;
        },
        ']', 'P', '_', '^', 'X' => {
            var k: usize = 2;
            while (k < n) : (k += 1) {
                const c = at(h, t, k);
                if (c == 0x07 or c == '\r' or c == '\n') return false;
                if (c == 0x1b) return k + 1 == n;
            }
            return true;
        },
        else => return false,
    }
}

/// A full read leaves no room to prepend a saved head. Return the event decoded
/// from that head and the exact leading tail bytes `joinHead` removed.
pub fn takeRecoveredEvent() ?Key {
    const event = recovered_event orelse return null;
    recovered_event = null;
    return event;
}

/// Re-attach a stashed head when a later read completes it. Valid dropped-head
/// prefixes accumulate across reads; an invalid or oversized tail disarms and
/// is processed as fresh input, so recovery remains bounded and fails closed.
pub fn joinHead(buf: []u8, n: usize) usize {
    const h = head_len;
    if (h == 0 or n == 0) return n;
    const dropped = armed;
    if (recover.legacyCsiProse(head[0..h], buf[0..n], h + n)) |prefix_len| {
        if (prefix_len + n <= buf.len) {
            std.mem.copyBackwards(u8, buf[prefix_len .. prefix_len + n], buf[0..n]);
            @memcpy(buf[0..prefix_len], head[2..h]);
            disarm();
            return prefix_len + n;
        }
    }
    const progress = if (dropped) pasteProgress(head[0..h], buf[0..n]) else null;
    if (completesWithEvidence(head[0..h], buf[0..n], dropped)) {
        if (h + n <= buf.len) {
            std.mem.copyBackwards(u8, buf[h .. h + n], buf[0..n]);
            @memcpy(buf[0..h], head[0..h]);
            disarm();
            return n + h;
        }
        if (recover.completed(head[0..h], buf[0..n])) |recovered| {
            std.mem.copyForwards(u8, buf[0 .. n - recovered.tail_len], buf[recovered.tail_len..n]);
            disarm();
            recovered_event = recovered.event;
            return n - recovered.tail_len;
        }
    } else if (dropped and ((if (progress) |p| switch (p) {
        .partial => true,
        .complete => false,
    } else false) or validPartial(head[0..h], buf[0..n]))) {
        if (h + n <= max_head) {
            @memcpy(head[h .. h + n], buf[0..n]);
            head_len = h + n;
            return 0;
        }
    }
    // These bytes do not finish the saved head. They are fresh input: broad
    // recovery must not reinterpret byte-at-a-time prose as a cursor key.
    head_len = 0;
    if (dropped) disarm();
    return n;
}

fn at(h: []const u8, t: []const u8, k: usize) u8 {
    return if (k < h.len) h[k] else t[k - h.len];
}

fn alignedFields(h: []const u8, t: []const u8, start: usize, end_at: usize, semicolons: ?usize, colon: bool) bool {
    var semis: usize = 0;
    var need_digit = true;
    for (start..end_at) |k| {
        const c = at(h, t, k);
        if (c >= '0' and c <= '9') {
            need_digit = false;
        } else if (!need_digit and (c == ';' or (colon and c == ':'))) {
            if (c == ';') semis += 1;
            need_digit = true;
        } else return false;
    }
    return !need_digit and (semicolons == null or semis == semicolons.?);
}

fn framedDroppedSuffix(h: []const u8, t: []const u8, final_at: usize, final: u8) bool {
    if ((final == 'M' or final == 'm') and final_at > 3 and at(h, t, 2) == '<')
        return alignedFields(h, t, 3, final_at, 2, false);
    if (final == 'u') return alignedFields(h, t, 2, final_at, null, true);
    if (final != '~' or final_at != 5) return false;
    return at(h, t, 2) == '2' and at(h, t, 3) == '0' and
        (at(h, t, 4) == '0' or at(h, t, 4) == '1');
}

/// Does `t` finish the truncated escape `h`? Only a join that yields a
/// COMPLETE sequence is worth making: after a give-up stall the next bytes are
/// just as likely to be a human resuming typing, and gluing a stale head onto
/// those would eat a keystroke.
pub fn completes(h: []const u8, t: []const u8) bool {
    return completesWithEvidence(h, t, false);
}

fn completesWithEvidence(h: []const u8, t: []const u8, dropped: bool) bool {
    const n = h.len + t.len;
    if (h.len == 0 or t.len == 0 or h[0] != 0x1b or n < 2) return false;
    // The first ESC was already delivered by the bounded genuine-Escape path;
    // do not turn its late second ESC into a new double-Escape candidate.
    if (!dropped and h.len == 1 and t[0] == 0x1b) return false;
    switch (at(h, t, 1)) {
        0x1b => return if (n > 2 and at(h, t, 2) == '[') recover.legacyCsiComplete(h, t, n, dropped) else true,
        'O' => return n >= 3 and isSs3Final(at(h, t, 2)) and
            (n == 3 or at(h, t, 3) < 0x20 or at(h, t, 3) == 0x7f),
        '[' => {
            var k: usize = 2;
            while (k < n) : (k += 1) {
                const c = at(h, t, k);
                if (c >= 0x20 and c <= 0x3f) continue; // params + intermediates
                if (!isInputFinal(c)) return false;
                if (k == 2 and c == 'M') {
                    if (n < 6) return false; // X10 is CSI M plus three bytes
                    for (3..6) |payload| if (at(h, t, payload) == 0x1b) return false;
                    return true;
                }
                // A complete cursor key followed by printable bytes is also
                // ordinary text (`[Alice]`, `[Home]`). Favor that reading.
                // Bracketed-paste start is the exception: suffix bytes are its
                // payload and must be parsed with paste mode already latched.
                const next_is_control = k + 1 < n and
                    (at(h, t, k + 1) < 0x20 or at(h, t, k + 1) == 0x7f);
                return k + 1 == n or next_is_control or (dropped and framedDroppedSuffix(h, t, k, c)) or
                    (k == 5 and c == '~' and at(h, t, 2) == '2' and at(h, t, 3) == '0' and at(h, t, 4) == '0');
            }
            return false;
        },
        ']', 'P', '_', '^', 'X' => {
            var k: usize = 2;
            while (k < n) : (k += 1) {
                const c = at(h, t, k);
                if (c == 0x07) return true; // BEL
                if (c == 0x1b) return k + 1 < n and at(h, t, k + 1) == '\\'; // ST
                if (c == 0x0d or c == 0x0a) return false; // typed text, not a reply
            }
            return false;
        },
        // A lone ESC in front of ordinary text is an Alt chord, and joining it
        // would SWALLOW that character. Typing it is the lesser harm.
        else => return false,
    }
}

/// CSI finals a terminal actually sends on stdin. Deliberately narrow: the
/// whole 0x40..0x7e range would let a stale head glue itself onto the first
/// letter a human types after the stall.
fn isInputFinal(c: u8) bool {
    return switch (c) {
        'A'...'F', 'H', 'M', 'P'...'S', 'Z', 'm', 'u', '~' => true,
        else => false,
    };
}

/// Finals that count only while `armed`. Cursor/mode replies (`[2A`, `[H`,
/// `[?1003l`) reach the sweeper when an oversized head could not be retained;
/// typing `2A` into the composer is exactly the debris this file exists to eat.
/// Unarmed they stay ordinary text — `2A`, `3H` and `1F`
/// are all things people write, and the suite pins them.
fn isArmedFinal(c: u8) bool {
    return switch (c) {
        'A'...'D', 'F', 'H', 'Z', 'h', 'l' => true,
        else => false,
    };
}

fn isFinal(c: u8, armed_now: bool) bool {
    return c == 'M' or c == 'm' or c == 'u' or c == '~' or (armed_now and isArmedFinal(c));
}

fn isSs3Final(c: u8) bool {
    return switch (c) {
        'A'...'D', 'F', 'H', 'M', 'P'...'S' => true,
        else => false,
    };
}

fn delimitedDecimal(bytes: []const u8, colon: bool) bool {
    var separators: usize = 0;
    var need_digit = true;
    for (bytes) |c| {
        if (c >= '0' and c <= '9') {
            need_digit = false;
            continue;
        }
        if (need_digit or (c != ';' and (!colon or c != ':'))) return false;
        separators += 1;
        need_digit = true;
    }
    return !need_digit and separators > 0;
}

/// Shapes specific enough to recover after the exact ESC carry is gone.
/// `[A`, `[H`, `[3~`, and every SS3 token are intentionally absent: at a read
/// boundary they are indistinguishable from prefixes of human prose.
fn unambiguousLateCsi(params: []const u8, final: u8) bool {
    if (final == '~') return std.mem.eql(u8, params, "200") or std.mem.eql(u8, params, "201");
    if ((final == 'M' or final == 'm') and params.len > 1 and params[0] == '<')
        return std.mem.count(u8, params[1..], ";") == 2 and delimitedDecimal(params[1..], false);
    return final == 'u' and delimitedDecimal(params, true);
}

/// Recover the unambiguous body of a sequence whose lone ESC was already
/// delivered as a genuine key. Ambiguous short CSI stays ordinary text.
fn takeLateCsi(bytes: []const u8, i: *usize, dropped_head: bool) Orphan {
    const start = i.*; // bytes[start] is '['
    var k = start + 1;
    while (k < bytes.len) : (k += 1) {
        const c = bytes[k];
        if (c == 0x1b) {
            i.* = k;
            key.abandonSequence("", .none);
            return .{ .took = .ignore };
        }
        if (c >= 0x20 and c <= 0x3f) continue;
        if (!isInputFinal(c)) return .none;
        const params = bytes[start + 1 .. k];
        if (c == 'M' and params.len == 0) return takeLateX10(bytes, i, k);
        if (!unambiguousLateCsi(params, c)) {
            if (!dropped_head) return .none;
            const printable_suffix = k + 1 < bytes.len and bytes[k + 1] >= 0x20 and bytes[k + 1] != 0x7f;
            if (printable_suffix) return .none;
        }
        i.* = k + 1;
        return .{ .took = key.decodeCsi(params, c) };
    }
    return if (bytes.len - start <= max_head) .partial else .none;
}

fn takeLateX10(bytes: []const u8, i: *usize, final_at: usize) Orphan {
    const payload = final_at + 1;
    const available_end = @min(payload + 3, bytes.len);
    if (std.mem.indexOfScalar(u8, bytes[payload..available_end], 0x1b)) |offset| {
        i.* = payload + offset;
        key.abandonSequence("", .none);
        return .{ .took = .ignore };
    }
    if (payload + 3 > bytes.len) return .partial;
    i.* = payload + 3;
    return .{ .took = key.decodeX10(bytes[payload .. payload + 3]) };
}

fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// Only the OSC reply this TUI solicits may remain pending across another read.
/// A complete BEL/ST-terminated OSC is exact and can always be discarded.
fn osc11Prefix(body: []const u8) bool {
    const lead = "11;rgb:";
    if (body.len <= lead.len) return std.mem.startsWith(u8, lead, body);
    if (!std.mem.startsWith(u8, body, lead)) return false;
    var digits: usize = 0;
    var slashes: usize = 0;
    for (body[lead.len..]) |c| {
        if (isHex(c)) {
            digits += 1;
            if (digits > 4) return false;
        } else if (c == '/' and (digits == 2 or digits == 4) and slashes < 2) {
            digits = 0;
            slashes += 1;
        } else return false;
    }
    return true;
}

fn takeLateOsc(bytes: []const u8, i: *usize) Orphan {
    const start = i.*; // bytes[start] is ']'
    var j = start + 1;
    while (j < bytes.len) : (j += 1) {
        if (bytes[j] == 0x07) {
            i.* = j + 1;
            return .{ .took = key.oscReply(']', bytes[start + 1 .. j]) };
        }
        if (bytes[j] == 0x1b) {
            if (j + 1 < bytes.len) {
                if (bytes[j + 1] != '\\') {
                    i.* = j;
                    key.abandonSequence("", .none);
                    return .{ .took = .ignore };
                }
                i.* = j + 2;
                return .{ .took = key.oscReply(']', bytes[start + 1 .. j]) };
            }
            return if (osc11Prefix(bytes[start + 1 .. j])) .partial else .none;
        }
        if (bytes[j] == '\r' or bytes[j] == '\n') return .none;
    }
    return if (bytes.len - start <= 128 and osc11Prefix(bytes[start + 1 ..])) .partial else .none;
}

fn takeEscapeBody(bytes: []const u8, i: *usize) Orphan {
    return switch (bytes[i.*]) {
        '[' => takeLateCsi(bytes, i, false),
        ']' => takeLateOsc(bytes, i),
        else => .none, // every short SS3 body is prose-ambiguous without ESC
    };
}

pub const Orphan = union(enum) {
    /// Not debris — hand the bytes to the normal parser (typed text).
    none,
    /// Debris shape, cut short by the read boundary: hold, do not type it.
    partial,
    took: Key,
};

/// CSI debris after a lost ESC (`7444;9u`, `39;33;23M`, `<35;80;24M`). Never a
/// letter and never Escape/Ctrl-C — those cancel or kill the turn.
///
/// Strictly shaped, because this runs against text a human may have typed: an
/// optional `<`, then digits with `;`/`:` separators, then a MOUSE or CSI-u
/// final (`M`/`m`/`u`/`~`). Any other terminator is text — accepting the whole
/// 0x40..0x7e range ate `0x1f` (final `x`), `[12]` (final `]`) and `1e5`
/// (final `e`). A run with neither `<` nor a separator (`3u`) is debris only
/// while `armed` says the loop really did drop a truncated sequence.
///
/// `armed` also widens the shape, because it means the loop REALLY lost a head
/// whose exact bytes were unavailable: an orphaned `[` introducer counts, as do
/// cursor/mode finals (`2A`, `[H`, `[200~`) and a
/// bare `~` whose parameters went with the head. Unarmed none of that moves —
/// every one of those strings is something a human types.
pub fn take(bytes: []const u8, i: *usize) Orphan {
    const start = i.*;
    if (start >= bytes.len) return .none;
    if (escape_armed) return takeEscapeBody(bytes, i);
    // A dropped parser head is stronger evidence than a genuine Escape key:
    // retain its bounded exact-tail recovery, while a same-read printable
    // suffix still makes `[Alice]` prose.
    if (armed and bytes[start] == '[') return takeLateCsi(bytes, i, true);
    var j = start;
    const lt = bytes[j] == '<';
    if (lt) j += 1;
    var sep = false;
    // A dropped head can split ON a separator (`\x1b[<35;80` + `;24M`), so the
    // tail opens with `;`/`:`. That is never typed text at the head of a read,
    // but it is only debris once the loop has told us a head was lost (#546).
    var headless = false;
    if (j < bytes.len and (bytes[j] == ';' or bytes[j] == ':') and armed) {
        sep = true;
        headless = true;
        j += 1;
    }
    if (j >= bytes.len) return if (headless) .partial else .none;
    if (bytes[j] < '0' or bytes[j] > '9') {
        // With all parameters lost, only `~` is distinctive enough to drop.
        // A bare letter is human text, even while recovery is armed.
        if (armed and bytes[j] == '~') {
            i.* = j + 1;
            return .{ .took = .ignore };
        }
        return .none;
    }
    var k = j;
    while (k < bytes.len) : (k += 1) {
        const c = bytes[k];
        if (c >= '0' and c <= '9') continue;
        if (c == ';' or c == ':') {
            sep = true;
            continue;
        }
        if (isFinal(c, armed)) {
            if (!lt and !sep and !armed) return .none;
            i.* = k + 1;
            // Only `<` proves that this tail starts at SGR field zero. A
            // digit/separator-led tail may start at button, x, or y; decoding
            // it would fabricate a click or wheel direction. Drop unless all
            // three framed fields are present and aligned.
            if (lt and (c == 'M' or c == 'm')) {
                const body = bytes[j..k];
                if (std.mem.count(u8, body, ";") != 2 or !delimitedDecimal(body, false))
                    return .{ .took = .ignore };
                var it = std.mem.splitScalar(u8, body, ';');
                const btn = key.leadingInt(it.next().?);
                const x = key.leadingInt(it.next().?);
                const y = key.leadingInt(it.next().?);
                return .{ .took = .{ .mouse = .{
                    .btn = @intCast(@min(btn, 255)),
                    .x = @intCast(@min(x, 999)),
                    .y = @intCast(@min(y, 999)),
                    .down = c == 'M',
                } } };
            }
            return .{ .took = .ignore };
        }
        if (c == 0x1b and armed) {
            i.* = k;
            key.abandonSequence("", .none);
            return .{ .took = .ignore };
        }
        return .none;
    }
    // A bare unarmed digit run is somebody typing, not a partial sequence.
    return if (lt or sep or armed) .partial else .none;
}

test "a join only happens when the tail really completes the head" {
    // The shapes run.zig drops mid-flight, rejoined.
    try std.testing.expect(completes("\x1b", "[<35;80;24M"));
    try std.testing.expect(completes("\x1b", "[M !!"));
    try std.testing.expect(completes("\x1b[M ", "!!"));
    try std.testing.expect(completes("\x1b", "[A"));
    try std.testing.expect(completes("\x1b", "[3~"));
    try std.testing.expect(completes("\x1b", "OA"));
    try std.testing.expect(completes("\x1b", "]11;rgb:14/14/14\x07"));
    try std.testing.expect(completes("\x1b", "[200~payload"));
    try std.testing.expect(completes("\x1b[<35;80", ";24M"));
    try std.testing.expect(completes("\x1b[201", "~"));
    try std.testing.expect(completes("\x1b]11;rgb:1c", "1c/1c1c/1c1c\x07"));
    // ...and never onto a human who simply resumed typing.
    try std.testing.expect(!completes("\x1b", "hello"));
    try std.testing.expect(!completes("\x1b", "[M"));
    try std.testing.expect(!completes("\x1b", "[M \x1b[A"));
    try std.testing.expect(!completes("\x1b", "[Alice]"));
    try std.testing.expect(!completes("\x1b", "[Home]"));
    try std.testing.expect(!completes("\x1b", "[Down]"));
    try std.testing.expect(!completes("\x1b", "Orange"));
    try std.testing.expect(!completes("\x1b", ""));
    try std.testing.expect(!completes("\x1b[<35;80", "hello"));
    try std.testing.expect(!completes("\x1b[", "3")); // still incomplete
    try std.testing.expect(!completes("\x1b]11;rgb:1c", "fix it\r"));
    try std.testing.expect(!completes("", "[A"));
    try std.testing.expect(!completes("39;7", ";32M")); // headless debris is take()'s job
}

test "joinHead spends the head on the next read either way" {
    reset();
    var buf: [32]u8 = undefined;
    stashHead("\x1b[<35;80");
    @memcpy(buf[0..4], ";24M");
    try std.testing.expectEqual(@as(usize, 12), joinHead(&buf, 4));
    try std.testing.expectEqualStrings("\x1b[<35;80;24M", buf[0..12]);
    // Second read: the head is spent, nothing is glued on.
    @memcpy(buf[0..4], ";24M");
    try std.testing.expectEqual(@as(usize, 4), joinHead(&buf, 4));
    // A head whose tail never came never corrupts the keystroke that follows.
    stashHead("\x1b[<35;80");
    @memcpy(buf[0..5], "hello");
    try std.testing.expectEqual(@as(usize, 5), joinHead(&buf, 5));
    try std.testing.expectEqualStrings("hello", buf[0..5]);
    reset();
}
