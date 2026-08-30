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
/// Mutable ONLY so a test can exercise the two regimes apart without sleeping
/// through a real 15s floor; production never writes it. A test that shrinks it
/// must restore it (process-wide, shared with every later test in the binary).
pub var idle_floor_ms: u64 = 15 * 1000;

/// How long a stream read may sit silent before the watchdog calls it dead.
/// `base_ms` is the configured budget (http.stream_stall_ms); `tokens_flowing`
/// says whether THIS stream has already emitted tokens.
/// Pre-first-token ceiling. The full budget used to stand before the first
/// byte "because a reasoning model can be silent for minutes" — but with
/// thinking STREAMED (kimi keep:"all", codex reasoning deltas) a healthy
/// request emits its first token in seconds, and a totally silent socket is
/// dead, not thinking: the k3 benchmark watched a stalled first call burn
/// 127s before the watchdog retried, after which it completed in 6s.
/// GRAFF_STREAM_STALL_SECS (or GRAFF_STREAM_HEAD_STALL_SECS) still overrides
/// for a provider that genuinely buffers in silence. Mutable for tests, like
/// idle_floor_ms; production writes it only from session_settings.
pub var head_ceiling_ms: u64 = 45 * 1000;

/// Per-request reconnect state the SSE and WS readers consult (#680). Owned by
/// the Agent, reset at the top of every request(), advanced by each stall
/// reconnect.
pub const State = struct {
    /// Stall reconnects this request has already made. Each one widens the
    /// between-lines budget (budgetMsWidened): a stream that stalled at the
    /// same point twice is a model pausing mid-response — composing a large
    /// tool call, say — not a dead socket, and re-sending the identical
    /// request into the identical budget only re-pays the generation.
    widen: u8 = 0,
    /// The budget (ms) of the read that last tripped, so the turn-ending
    /// message reports what was actually waited rather than the configured
    /// total. 0 until a watchdog fires.
    tripped_ms: u64 = 0,
};

pub fn budgetMs(base_ms: u64, tokens_flowing: bool) u64 {
    return budgetMsWidened(base_ms, tokens_flowing, 0);
}

/// budgetMs with the reconnect ladder applied (#680): `widen` is how many
/// stall reconnects this request has made. The between-lines divisor halves
/// each time — a quarter, a half, then the full configured budget — and the
/// floor and the configured total still bound it. The pre-first-token
/// ceiling is NOT widened: a socket that never answered is dead on arrival
/// (#401), and that regime has its own retry ladder (HungRequest).
pub fn budgetMsWidened(base_ms: u64, tokens_flowing: bool, widen: u8) u64 {
    if (!tokens_flowing) return @min(base_ms, head_ceiling_ms);
    const divisor = idle_divisor >> @intCast(@min(widen, 2));
    return @min(base_ms, @max(idle_floor_ms, base_ms / divisor));
}

/// Inter-frame wait. No bytes yet is a dead socket (head ceiling). Protocol
/// frames without prose is a reasoning model (full `base_ms` — gpt-5.6-sol
/// high/max often encrypts thinking and emits nothing for well over 45s).
/// Visible prose tightens to the between-lines budget, widened per reconnect.
pub fn interFrameBudgetMs(base_ms: u64, saw_protocol: bool, tokens_flowing: bool, widen: u8) u64 {
    if (tokens_flowing) return budgetMsWidened(base_ms, true, widen);
    if (saw_protocol) return base_ms;
    return budgetMsWidened(base_ms, false, widen);
}

/// True once a silent read has outlasted its budget — the watchdog loop's only
/// decision, split out so it can be exercised at the boundary in a unit test.
pub fn expired(waited_ms: u64, base_ms: u64, tokens_flowing: bool) bool {
    return waited_ms >= budgetMs(base_ms, tokens_flowing);
}

test "stall budget (#56): between-lines silence trips sooner than a pre-first-token pause" {
    const base: u64 = 120 * 1000; // the shipped http.stream_stall_ms default

    // Before the first token the head ceiling applies: with thinking streamed,
    // a silent socket past it is dead, not reasoning.
    try std.testing.expectEqual(head_ceiling_ms, budgetMs(base, false));
    try std.testing.expect(!expired(head_ceiling_ms - 1, base, false));
    try std.testing.expect(expired(head_ceiling_ms, base, false));

    // Tokens already flowed: a quarter of it (30s), so a dead stream is given
    // up on 4x sooner instead of holding the turn for another 90s of silence.
    try std.testing.expectEqual(@as(u64, 30 * 1000), budgetMs(base, true));
    try std.testing.expect(!expired(30 * 1000 - 1, base, true));
    try std.testing.expect(expired(30 * 1000, base, true));
    // The whole point of the split: at 30s of silence the between-lines regime
    // is done and the pre-first-token one is still waiting.
    try std.testing.expect(expired(30 * 1000, base, true) and !expired(30 * 1000, base, false));

    // GRAFF_STREAM_STALL_SECS (session_settings writes http.stream_stall_ms,
    // which arrives here as base_ms) still wins BOTH regimes when set high —
    // simulated by raising the ceiling the way the env knob does.
    const saved_ceiling = head_ceiling_ms;
    head_ceiling_ms = 600 * 1000;
    defer head_ceiling_ms = saved_ceiling;
    try std.testing.expectEqual(@as(u64, 600 * 1000), budgetMs(600 * 1000, false));
    try std.testing.expectEqual(@as(u64, 150 * 1000), budgetMs(600 * 1000, true));

    // A short override floors the between-lines budget instead of shrinking it
    // to seconds, and never outlasts the configured total.
    try std.testing.expectEqual(idle_floor_ms, budgetMs(20 * 1000, true));
    try std.testing.expectEqual(@as(u64, 5 * 1000), budgetMs(5 * 1000, true));
    try std.testing.expect(expired(5 * 1000, 5 * 1000, true));
}

test "stall budget: protocol-seen thinking keeps the full wait, not the 45s ceiling" {
    const base: u64 = 120 * 1000;
    try std.testing.expectEqual(head_ceiling_ms, interFrameBudgetMs(base, false, false, 0));
    try std.testing.expectEqual(base, interFrameBudgetMs(base, true, false, 0));
    try std.testing.expectEqual(@as(u64, 30 * 1000), interFrameBudgetMs(base, true, true, 0));
}

// The #680 signature: reasoning streamed, one line of prose, then >30s of
// silence while the model composed a large tool call. The old ladder armed the
// same 30s on every reconnect, so all three attempts died at the same point
// and the turn ended claiming "no data for 120s".
test "stall budget (#680): each reconnect widens the between-lines wait — a quarter, a half, then all of it" {
    const base: u64 = 120 * 1000;
    try std.testing.expectEqual(@as(u64, 30 * 1000), budgetMsWidened(base, true, 0));
    try std.testing.expectEqual(@as(u64, 60 * 1000), budgetMsWidened(base, true, 1));
    try std.testing.expectEqual(base, budgetMsWidened(base, true, 2));
    try std.testing.expectEqual(base, budgetMsWidened(base, true, 7)); // past the ladder: still the configured total
    // Through the reader's entry point, and only for the prose regime.
    try std.testing.expectEqual(@as(u64, 60 * 1000), interFrameBudgetMs(base, true, true, 1));
    try std.testing.expectEqual(base, interFrameBudgetMs(base, true, false, 1)); // protocol-only: already the full wait
    try std.testing.expectEqual(head_ceiling_ms, interFrameBudgetMs(base, false, false, 2)); // dead on arrival is not widened
    // The floor and the total still bound a short GRAFF_STREAM_STALL_SECS.
    try std.testing.expectEqual(idle_floor_ms, budgetMsWidened(20 * 1000, true, 1)); // 10s < floor
    try std.testing.expectEqual(@as(u64, 20 * 1000), budgetMsWidened(20 * 1000, true, 2));
    try std.testing.expectEqual(@as(u64, 5 * 1000), budgetMsWidened(5 * 1000, true, 1));
}
