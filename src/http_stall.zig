//! Stall-budget arithmetic for the streaming watchdogs (#56). Pure: no Io, no
//! globals, so both regimes are testable at their boundary without sleeping
//! through a real 120s stall. Lives beside http.zig (which is at the 600-line
//! cap) the way http_headers.zig does; http.zig owns the watchdog loops and
//! the configured budget, this owns the decision they make each tick.

const std = @import("std");

/// Once tokens are flowing, a stream gets this fraction of the pre-first-token
/// budget: bytes were arriving and stopped, which is a dead socket rather than
/// a model thinking, and the next token was milliseconds away. A fraction of
/// the configured budget rather than a second env knob, so
/// GRAFF_STREAM_STALL_SECS still scales BOTH regimes for a slow provider.
const idle_divisor: u64 = 4;

/// ...but never below this, so a small GRAFF_STREAM_STALL_SECS cannot shrink
/// the between-lines budget to a couple of seconds and start killing healthy
/// streams. Clamped to the configured budget, which always wins when smaller.
const idle_floor_ms: u64 = 15 * 1000;

/// How long a stream read may sit silent before the watchdog calls it dead.
/// `base_ms` is the configured budget (http.stream_stall_ms); `tokens_flowing`
/// says whether THIS stream has already emitted tokens.
pub fn budgetMs(base_ms: u64, tokens_flowing: bool) u64 {
    if (!tokens_flowing) return base_ms; // pre-first-token: a legit long reasoning pause
    return @min(base_ms, @max(idle_floor_ms, base_ms / idle_divisor));
}

/// True once a silent read has outlasted its budget — the watchdog loop's only
/// decision, split out so it can be exercised at the boundary in a unit test.
pub fn expired(waited_ms: u64, base_ms: u64, tokens_flowing: bool) bool {
    return waited_ms >= budgetMs(base_ms, tokens_flowing);
}

test "stall budget (#56): between-lines silence trips sooner than a pre-first-token pause" {
    const base: u64 = 120 * 1000; // the shipped http.stream_stall_ms default

    // Before the first token the full budget stands: a reasoning model can be
    // silent for minutes before it emits anything, so nothing shorter is safe.
    try std.testing.expectEqual(base, budgetMs(base, false));
    try std.testing.expect(!expired(base - 1, base, false));
    try std.testing.expect(expired(base, base, false));

    // Tokens already flowed: a quarter of it (30s), so a dead stream is given
    // up on 4x sooner instead of holding the turn for another 90s of silence.
    try std.testing.expectEqual(@as(u64, 30 * 1000), budgetMs(base, true));
    try std.testing.expect(!expired(30 * 1000 - 1, base, true));
    try std.testing.expect(expired(30 * 1000, base, true));
    // The whole point of the split: at 30s of silence the between-lines regime
    // is done and the pre-first-token one is still waiting.
    try std.testing.expect(expired(30 * 1000, base, true) and !expired(30 * 1000, base, false));

    // GRAFF_STREAM_STALL_SECS (session_run writes http.stream_stall_ms, which
    // arrives here as base_ms) keeps scaling both regimes.
    try std.testing.expectEqual(@as(u64, 600 * 1000), budgetMs(600 * 1000, false));
    try std.testing.expectEqual(@as(u64, 150 * 1000), budgetMs(600 * 1000, true));

    // A short override floors the between-lines budget instead of shrinking it
    // to seconds, and never outlasts the configured total.
    try std.testing.expectEqual(idle_floor_ms, budgetMs(20 * 1000, true));
    try std.testing.expectEqual(@as(u64, 5 * 1000), budgetMs(5 * 1000, true));
    try std.testing.expect(expired(5 * 1000, 5 * 1000, true));
}
