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
//! subagent_selection.zig for the documented (intentional, not papered
//! over) disagreement on the gpt-5.6 family and deepseek-v4-flash.
const std = @import("std");

const pricing = @import("pricing.zig");

pub const TierLadder = struct {
    provider: []const u8,
    frontier: []const u8,
    mid: ?[]const u8 = null,
    small: ?[]const u8 = null,
};

pub const ladders = [_]TierLadder{
    .{ .provider = "codex", .frontier = "gpt-5.6-sol", .mid = "gpt-5.6-terra", .small = "gpt-5.6-luna" },
    .{ .provider = "openai", .frontier = "gpt-5.6", .mid = "gpt-5.6-terra", .small = "gpt-5.6-luna" },
    .{ .provider = "anthropic", .frontier = "claude-opus-4-8", .mid = "claude-sonnet-4-6", .small = "claude-haiku-4-5" },
    .{ .provider = "deepseek", .frontier = "deepseek-v4-pro", .mid = "deepseek-v4-flash" },
};

/// The ladder row for a provider, if any. A provider absent from `ladders`
/// has no default tiering — every root on it always inherits.
pub fn forProvider(provider_id: []const u8) ?TierLadder {
    for (ladders) |l| if (std.mem.eql(u8, l.provider, provider_id)) return l;
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
