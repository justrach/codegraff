//! Bounded retry jitter (#1274).
//!
//! Every retry ladder here (http.RetryPlan's 1·2·4·8 s throttle and
//! .25·.5·1·2·4 s flake steps, the gateway-flake ladder, the subagent re-ask,
//! the remote-control reconnect) used to be deterministic, so parallel
//! subagents or workflow items that hit the same rate limit slept the same
//! amount and retried in lockstep, colliding again. Each backoff now passes
//! through here once before it is slept.
//!
//! The rule: jitter only ADDS time, never more than `max_extra_pct` of the
//! base. A server-provided Retry-After / "try again in N" hint is passed in as
//! the base, so the jittered wait is always >= what the server asked for.
//! Worst case is 1.25x the old wait; the ladders' own caps are unchanged.

const std = @import("std");
const Io = std.Io;

/// Upper bound of the added wait, as a percentage of the base.
pub const max_extra_pct: u64 = 25;

/// Pure seam: `base_ms` plus a uniform extra in [0, base_ms * max_extra_pct / 100],
/// drawn from the caller's random word `r`. Never returns less than `base_ms`.
pub fn withJitter(base_ms: u64, r: u64) u64 {
    const span = base_ms / 100 * max_extra_pct + base_ms % 100 * max_extra_pct / 100;
    if (span == 0) return base_ms;
    return base_ms +| r % (span + 1);
}

/// Seeded-RNG form for tests and any caller that owns a std.Random.
pub fn withRandom(rand: std.Random, base_ms: u64) u64 {
    return withJitter(base_ms, rand.int(u64));
}

/// Production: jitter `base_ms` from the process entropy source.
pub fn ms(io: Io, base_ms: u64) u64 {
    var raw: [8]u8 = undefined;
    io.random(&raw);
    return withJitter(base_ms, std.mem.readInt(u64, &raw, .little));
}

test "withJitter (#1274): only adds, at most max_extra_pct of the base" {
    var prng = std.Random.DefaultPrng.init(0x1274);
    const rand = prng.random();
    for ([_]u64{ 250, 500, 750, 1000, 2000, 4000, 8000, 30_000 }) |base| {
        var i: usize = 0;
        while (i < 200) : (i += 1) {
            const d = withRandom(rand, base);
            try std.testing.expect(d >= base);
            try std.testing.expect(d <= base + base * max_extra_pct / 100);
        }
    }
    // The extremes of the random word land on the two bounds.
    try std.testing.expectEqual(@as(u64, 1000), withJitter(1000, 0));
    try std.testing.expectEqual(@as(u64, 1250), withJitter(1000, 250));
    // Nothing to spread: a zero or tiny base passes through untouched.
    try std.testing.expectEqual(@as(u64, 0), withJitter(0, 12345));
    try std.testing.expectEqual(@as(u64, 3), withJitter(3, 12345));
    // No overflow at the top of the range.
    try std.testing.expect(withJitter(std.math.maxInt(u64), std.math.maxInt(u64)) == std.math.maxInt(u64));
}

test "withJitter (#1274): a server Retry-After is a floor, never shortened" {
    var prng = std.Random.DefaultPrng.init(7);
    const rand = prng.random();
    // The call sites pass the server hint as the base (e.g. 3 s from
    // "try again in 3 seconds", or a capped Retry-After header).
    for ([_]u64{ 1000, 3000, 30_000 }) |server_ms| {
        var i: usize = 0;
        while (i < 200) : (i += 1) try std.testing.expect(withRandom(rand, server_ms) >= server_ms);
    }
}

test "withJitter (#1274): seeded draws are deterministic and actually spread" {
    var a = std.Random.DefaultPrng.init(42);
    var b = std.Random.DefaultPrng.init(42);
    var seen_min: u64 = std.math.maxInt(u64);
    var seen_max: u64 = 0;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const x = withRandom(a.random(), 4000);
        try std.testing.expectEqual(x, withRandom(b.random(), 4000));
        seen_min = @min(seen_min, x);
        seen_max = @max(seen_max, x);
    }
    // Two callers retrying the same step must not wait the same amount: the
    // lockstep this fixes. 64 draws over a 1000 ms span spread well past 100 ms.
    try std.testing.expect(seen_max - seen_min > 100);
}
