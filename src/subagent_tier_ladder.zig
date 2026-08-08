//! Default worker-model tier ladder (#291): a provider-local sibling to fall
//! back on for subagents/workflow-workers/judges when no explicit
//! --subagent-model is given. Kept as its own module (rather than folded
//! into pricing.zig, which is already at the 600-line split ceiling) — pure
//! data + a model_table membership test, no key/provider wiring.
//!
//! Resolution (subagent_selection.zig) descends one rung from wherever the
//! root model sits: a frontier root steps to mid (or straight to small when
//! the family has no mid rung), a mid root steps to small, and a small root
//! has nowhere cheaper and inherits root unchanged.
//!
//! `frontier`/`mid`/`small` here are the ladder's OWN rung labels; they are
//! NOT guaranteed to equal scoring.providerClass(name) for that literal
//! model string — see the "ladder rungs vs providerClass" pinned test in
//! subagent_selection.zig: the gpt-5.6 family now agrees end-to-end, leaving
//! deepseek-v4-flash as the documented (intentional, not papered over)
//! disagreement.
const std = @import("std");

const pricing = @import("pricing.zig");

/// The ladder's rung vocabulary, shared by #292's persona frontmatter
/// (`tier: mid`) and the `subagent` tool's `tier` parameter. Spelled the same
/// way in both places on purpose: a tier survives a root-model change, an
/// exact `model:` pin does not.
pub const Tier = enum {
    frontier,
    mid,
    small,

    /// Exact, case-sensitive, closed vocabulary — mirroring
    /// fleet.Isolation.parse. Anything else is "no opinion" (null), never a
    /// nearest-rung guess.
    pub fn parse(s: []const u8) ?Tier {
        if (std.mem.eql(u8, s, "frontier")) return .frontier;
        if (std.mem.eql(u8, s, "mid")) return .mid;
        if (std.mem.eql(u8, s, "small")) return .small;
        return null;
    }

    pub fn label(self: Tier) []const u8 {
        return @tagName(self);
    }
};

pub const TierLadder = struct {
    provider: []const u8,
    frontier: []const u8,
    mid: ?[]const u8 = null,
    small: ?[]const u8 = null,

    /// The model this provider serves at `tier`, or null when the family has
    /// no such rung (deepseek has no `small`). Never falls through to a
    /// neighbouring rung — an absent rung means "no opinion", which the
    /// caller turns into the session default rather than a guess.
    pub fn modelFor(self: TierLadder, tier: Tier) ?[]const u8 {
        return switch (tier) {
            .frontier => self.frontier,
            .mid => self.mid,
            .small => self.small,
        };
    }
};

pub const ladders = [_]TierLadder{
    .{ .provider = "codex", .frontier = "gpt-5.6-sol", .mid = "gpt-5.6-terra", .small = "gpt-5.6-luna" },
    .{ .provider = "openai", .frontier = "gpt-5.6", .mid = "gpt-5.6-terra", .small = "gpt-5.6-luna" },
    // #471: opus-5 and sonnet-5 are the current lineup, and the rungs below
    // frontier must be cheaper SEATS. Every opus generation bills the same
    // $5/$25 per MTok, so "descend from opus-5 to opus-4-8" saves nothing —
    // it is the same seat, one generation older. sonnet-5 at $2/$10 is the
    // real cheap rung, 2.5x under opus on both halves of the bill.
    .{ .provider = "anthropic", .frontier = "claude-opus-5", .small = "claude-sonnet-5" },
    // deepseek-v4-flash overtook pro: better AND $0.14/$0.28 against pro's
    // $0.435/$0.87. Pro is dominated on both axes, so it is not a rung under
    // flash — it is just worse. One seat, no descent.
    .{ .provider = "deepseek", .frontier = "deepseek-v4-flash" },
    // Kimi's plan is one flagship. k3 is the MID-tier subscription seat —
    // sub-first routing sends `tier:"mid"` here (codex has no mid rung) while
    // `tier:"small"` still lands on codex's luna, which is what the cheap
    // mechanical work (code search, greps, extraction) actually wants. Giving
    // k3 a `small` rung too would let it outscore luna and swallow that tier.
    .{ .provider = "kimi", .frontier = "k3", .mid = "k3" },
};

/// Is `rung` a genuinely cheaper SEAT than `frontier` — strictly less $/MTok
/// on the real price sheet? Unknown on either side answers true: an unpriced
/// model cannot be disproved (codex's `gpt-5.6-sol` has no row at all), and
/// #291's descent must keep working there.
///
/// #471: the bench sheet ranks by $/TASK, which folds the seat's rate together
/// with how many tokens a model burns, so a terser model of the same price
/// reads as "cheaper". That is how `claude-opus-4-8` came to sit under
/// `claude-opus-5` as anthropic's cheap rung while billing the identical
/// $5/$25 per MTok — a descent that saves literally nothing.
pub fn cheaperSeat(frontier: []const u8, rung: []const u8) bool {
    // The SAME model at a lower rung is a one-seat plan describing itself, not
    // a fake descent: Kimi's subscription serves only k3, so k3 is both its
    // frontier and its mid. What the check forbids is a DIFFERENT model that
    // costs the same or more — opus-4-8 under opus-5 — because that trades
    // capability away for nothing.
    if (std.mem.eql(u8, frontier, rung)) return true;
    const fp = pricing.priceFor(frontier) orelse return true;
    const rp = pricing.priceFor(rung) orelse return true;
    return rp.in + rp.out < fp.in + fp.out;
}

/// Drop any rung that is not a cheaper seat than the ladder's own frontier.
fn seatChecked(l: TierLadder) TierLadder {
    var out = l;
    if (out.mid) |m| if (!cheaperSeat(out.frontier, m)) {
        out.mid = null;
    };
    if (out.small) |s| if (!cheaperSeat(out.frontier, s)) {
        out.small = null;
    };
    return out;
}

/// The ladder row for a provider, if any. A bench-derived ladder (a
/// .harness/bench.json score/cost sheet — see bench_priors.zig) outranks the
/// compiled table: measured capability+cost beats a hand-picked default. A
/// provider absent from both has no default tiering — roots on it inherit.
///
/// #471: a derived ladder is seat-checked first, and one left with NO cheaper
/// rung at all is not a ladder — it offers no descent — so the compiled row
/// takes over rather than the provider losing its tiering entirely. Measured
/// data still outranks the default whenever it names a real cheaper seat.
pub fn forProvider(provider_id: []const u8) ?TierLadder {
    for (@import("bench_priors.zig").g_ladders) |l| if (std.mem.eql(u8, l.provider, provider_id)) {
        const checked = seatChecked(l);
        if (checked.mid != null or checked.small != null) return checked;
        break;
    };
    for (ladders) |l| if (std.mem.eql(u8, l.provider, provider_id)) return seatChecked(l);
    return null;
}

test "subagent tier ladder: every rung is a real model on its own provider (#291)" {
    // Every non-null name must be verified against the shipped model_table
    // before it's usable as a default worker pin — a typo/renamed model here
    // would silently fail every ladder resolution for that provider. Checked
    // against the comptime table, not models(): other tests (and their
    // background work) swap the runtime-active table, and this invariant is
    // about what the binary ships, not what a previous test left active.
    for (ladders) |l| {
        try std.testing.expect(inShippedTable(l.provider, l.frontier));
        if (l.mid) |m| try std.testing.expect(inShippedTable(l.provider, m));
        if (l.small) |s| try std.testing.expect(inShippedTable(l.provider, s));
    }
}

fn inShippedTable(provider_id: []const u8, model: []const u8) bool {
    for (pricing.model_table) |m| {
        if (std.mem.eql(u8, m.provider, provider_id) and std.mem.eql(u8, m.name, model)) return true;
    }
    return false;
}

test "forProvider: known providers found, others null" {
    try std.testing.expectEqualStrings("gpt-5.6-sol", forProvider("codex").?.frontier);
    try std.testing.expect(forProvider("deepseek").?.small == null);
    try std.testing.expect(forProvider("xai") == null);
}

test "Tier.parse/modelFor: the rung vocabulary #292 pins against (#291 names)" {
    try std.testing.expectEqual(Tier.frontier, Tier.parse("frontier").?);
    try std.testing.expectEqual(Tier.mid, Tier.parse("mid").?);
    try std.testing.expectEqual(Tier.small, Tier.parse("small").?);
    // Case-sensitive and closed: anything off-vocabulary is "no opinion", not
    // a guess — a persona typo must fall through to the session default.
    try std.testing.expect(Tier.parse("Mid") == null);
    try std.testing.expect(Tier.parse("cheap") == null);
    try std.testing.expect(Tier.parse("") == null);
    try std.testing.expectEqualStrings("small", Tier.small.label());

    const codex = forProvider("codex").?;
    try std.testing.expectEqualStrings("gpt-5.6-sol", codex.modelFor(.frontier).?);
    try std.testing.expectEqualStrings("gpt-5.6-terra", codex.modelFor(.mid).?);
    try std.testing.expectEqualStrings("gpt-5.6-luna", codex.modelFor(.small).?);
    // A family with no such rung answers null rather than the nearest rung.
    try std.testing.expect(forProvider("deepseek").?.modelFor(.small) == null);
}

test "#471 a rung must be a cheaper SEAT, not merely a terser one" {
    // The bug: `claude-opus-4-8` sat under `claude-opus-5` as anthropic's
    // cheap rung because the bench sheet rates it $2.9/task against opus-5's
    // $12.0 — but both bill the identical $5/$25 per MTok, so descending to it
    // saves nothing whatsoever. It is the same seat, one generation older.
    try std.testing.expect(!cheaperSeat("claude-opus-5", "claude-opus-4-8"));
    // Nor may a "rung" cost MORE than the frontier it hangs under.
    try std.testing.expect(!cheaperSeat("claude-opus-5", "claude-fable-5"));
    // sonnet-5 is the real thing: $2/$10 against $5/$25, cheaper on both halves.
    try std.testing.expect(cheaperSeat("claude-opus-5", "claude-sonnet-5"));
    // Unknown on either side cannot be disproved, and #291's descent has to
    // keep working on providers whose models carry no price row at all
    // (codex's gpt-5.6-sol is the live example).
    try std.testing.expect(cheaperSeat("gpt-5.6-sol", "gpt-5.6-luna"));
    try std.testing.expect(cheaperSeat("claude-opus-5", "no-such-model"));
}

test "#471 a derived ladder offering no real descent yields to the compiled row" {
    const bench = @import("bench_priors.zig");
    const saved = bench.g_ladders;
    defer bench.g_ladders = saved;

    // What the builtin sheet actually derives for anthropic today. Both rungs
    // fail the seat check — fable-5 is pricier than the frontier, opus-4-8 is
    // the same price — so this is not a ladder: it offers no descent at all.
    const derived = [_]TierLadder{
        .{ .provider = "anthropic", .frontier = "claude-opus-5", .mid = "claude-fable-5", .small = "claude-opus-4-8" },
    };
    bench.g_ladders = &derived;
    const l = forProvider("anthropic").?;
    try std.testing.expectEqualStrings("claude-opus-5", l.frontier);
    try std.testing.expect(l.mid == null);
    try std.testing.expectEqualStrings("claude-sonnet-5", l.small.?); // from the compiled row

    // A derived ladder that DOES name a genuinely cheaper seat still wins:
    // measured data outranks the hand-picked default, which is the whole
    // point of #373. Only the empty-after-checking case yields.
    const real = [_]TierLadder{
        .{ .provider = "anthropic", .frontier = "claude-opus-5", .small = "claude-haiku-4-5" },
    };
    bench.g_ladders = &real;
    try std.testing.expectEqualStrings("claude-haiku-4-5", forProvider("anthropic").?.small.?);
}
