//! Tests carved out of pricing.zig, which sits against the 600-line cap.

const std = @import("std");
const pricing = @import("pricing.zig");
const provider_mod = @import("provider.zig");

test "CostTally token and call counters saturate" {
    var tally: pricing.CostTally = .{
        .in_tokens = std.math.maxInt(u64) - 1,
        .cache_tokens = std.math.maxInt(u64),
        .out_tokens = std.math.maxInt(u64) - 2,
        .api_calls = std.math.maxInt(u64),
        .sub_calls = std.math.maxInt(u64),
    };
    tally.add(std.testing.io, .sub, "gpt-5.5", 10, 10, 10);
    try std.testing.expectEqual(std.math.maxInt(u64), tally.in_tokens);
    try std.testing.expectEqual(std.math.maxInt(u64), tally.cache_tokens);
    try std.testing.expectEqual(std.math.maxInt(u64), tally.out_tokens);
    try std.testing.expectEqual(std.math.maxInt(u64), tally.api_calls);
    try std.testing.expectEqual(std.math.maxInt(u64), tally.sub_calls);
}

test "modelInTable: known models present, unknown absent" {
    try std.testing.expect(pricing.modelInTable("gpt-5.5"));
    try std.testing.expect(pricing.modelInTable("claude-opus-4-8"));
    try std.testing.expect(!pricing.modelInTable("not-a-real-model"));
}

test "priceFor: known model priced, unknown is null" {
    try std.testing.expect(pricing.priceFor("gpt-5.5") != null);
    try std.testing.expect(pricing.priceFor("claude-opus-4-8") != null);
    try std.testing.expect(pricing.priceFor("no-such-model") == null);
}

test "resolveModelName exact aliases and miss" {
    const keys = provider_mod.Keys{ .values = @splat(null) };
    try std.testing.expect(pricing.resolveModelName(keys, "gpt-5.5") != null); // exact name
    try std.testing.expectEqualStrings("glm-5.2", pricing.resolveModelName(keys, "glm5.2").?); // natural alias
    try std.testing.expect(pricing.resolveModelName(keys, "totally-unknown-zzz") == null);
}

test "resolveModelName (#377): family-prefixed spelling resolves to the provider's native row" {
    const keys = provider_mod.Keys{ .values = @splat(null) };
    // Works from the COMPILED table alone — no gateway catalog cache needed,
    // so a fresh machine with only a kimi login can type `--model kimi-k3`.
    try std.testing.expectEqualStrings("k3", pricing.resolveModelName(keys, "kimi-k3").?);
    try std.testing.expect(pricing.familyAliasEquals("kimi", "k3", "kimi-k3"));
    try std.testing.expect(pricing.familyAliasEquals("kimi", "k3", "kimi_k3"));
    try std.testing.expect(!pricing.familyAliasEquals("kimi", "k3", "kimi-k30"));
    try std.testing.expect(!pricing.familyAliasEquals("codex", "k3", "kimi-k3"));
}
