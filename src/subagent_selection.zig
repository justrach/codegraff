//! Startup-time routing for the optional worker model shape.
//!
//! A provider boundary is materially different from a model pin: prompts,
//! tool results, billing, and credentials move to another service. Cross-
//! provider workers therefore require both an explicit provider and an
//! explicit consent flag.
//!
//! Absent an explicit --subagent-model/--subagent-provider, a default worker
//! tier ladder (#291, tier_ladder.zig) descends one rung from wherever the
//! root model sits — same precedence-tail as the explicit pin's own
//! provider-local/cross-provider-consent rules, since the default is
//! resolved through the same subagentProvider() call with cross-provider
//! forced off. --no-subagent-tier (or GRAFF_NO_SUBAGENT_TIER) opts out and
//! restores today's plain inherit-root behavior.
const std = @import("std");

const pricing = @import("pricing.zig");
const provider_mod = @import("provider.zig");
const tier_ladder = @import("subagent_tier_ladder.zig");

pub const Error = error{
    UnknownModel,
    UnknownProvider,
    ModelNotOnProvider,
    CrossProviderConsentRequired,
    MissingKey,
};

fn knownProvider(id: []const u8) bool {
    return provider_mod.specFor(id) != null;
}

/// Resolve `query` to a catalogued model name served by `provider_id`: exact
/// match, then alias-equality, then a UNIQUE substring match (ambiguous →
/// null). Provider-local by construction — this is the one resolver both the
/// startup pins (--subagent-model, the #291 ladder) and the #292 per-persona /
/// per-spawn pins go through, so all three agree on what a model name means.
pub fn modelForProvider(provider_id: []const u8, query: []const u8) ?[]const u8 {
    for (pricing.models()) |model| {
        if (std.mem.eql(u8, model.provider, provider_id) and
            std.mem.eql(u8, model.name, query)) return model.name;
    }
    for (pricing.models()) |model| {
        if (std.mem.eql(u8, model.provider, provider_id) and
            pricing.modelAliasEquals(model.name, query)) return model.name;
    }
    var query_buf: [128]u8 = undefined;
    const normalized_query = pricing.normalizeModelAlias(&query_buf, query);
    var candidate: ?[]const u8 = null;
    for (pricing.models()) |model| {
        if (!std.mem.eql(u8, model.provider, provider_id)) continue;
        var name_buf: [128]u8 = undefined;
        const normalized_name = pricing.normalizeModelAlias(&name_buf, model.name);
        if (std.mem.indexOf(u8, normalized_name, normalized_query) == null) continue;
        if (candidate != null) return null;
        candidate = model.name;
    }
    return candidate;
}

/// Default worker sibling for `root` on its own ladder, descending exactly
/// one rung. `root.model` must exactly match a rung name (frontier or mid)
/// for this provider's ladder — an off-ladder or unrecognized root model
/// returns null rather than guessing at the nearest rung.
fn defaultLadderModel(root: provider_mod.Provider) ?[]const u8 {
    const ladder = tier_ladder.forProvider(root.id) orelse return null;
    if (std.mem.eql(u8, root.model, ladder.frontier)) return ladder.mid orelse ladder.small;
    if (ladder.mid) |mid| {
        if (std.mem.eql(u8, root.model, mid)) return ladder.small;
    }
    return null; // root is already the bottom rung, or isn't on this ladder
}

/// Resolves the default ladder sibling to an actual Provider, reusing
/// subagentProvider's exact/alias/key resolution so a ladder name a live
/// catalog refresh has since dropped fails soft into "inherit root" instead
/// of the fatal path an explicit --subagent-model takes. Always same-
/// provider — cross_provider is forced off, since ladder siblings never
/// cross a provider boundary implicitly (preserves the invariant explicit
/// pins already enforce).
fn defaultLadderProvider(keys: provider_mod.Keys, root: provider_mod.Provider) ?provider_mod.Provider {
    const target = defaultLadderModel(root) orelse return null;
    return subagentProvider(keys, root, null, target, false) catch null;
}

pub fn subagentProvider(
    keys: provider_mod.Keys,
    root: provider_mod.Provider,
    provider_query: ?[]const u8,
    model_query: []const u8,
    allow_cross_provider: bool,
) Error!provider_mod.Provider {
    const requested_provider = if (provider_query) |raw|
        std.mem.trim(u8, raw, " \t\r\n")
    else
        root.id;
    if (!knownProvider(requested_provider)) return error.UnknownProvider;
    if (!std.mem.eql(u8, requested_provider, root.id) and !allow_cross_provider)
        return error.CrossProviderConsentRequired;

    const requested_model = std.mem.trim(u8, model_query, " \t\r\n");
    const model = modelForProvider(requested_provider, requested_model) orelse {
        if (pricing.resolveModelName(keys, requested_model) != null)
            return error.ModelNotOnProvider;
        return error.UnknownModel;
    };
    return keys.providerById(requested_provider, model) catch error.MissingKey;
}

pub fn resolveSubagentProvider(
    keys: provider_mod.Keys,
    root: provider_mod.Provider,
    provider_query: ?[]const u8,
    model_query: ?[]const u8,
    allow_cross_provider: bool,
    disable_default_ladder: bool,
) ?provider_mod.Provider {
    const raw_provider = provider_query orelse "";
    const requested_provider = std.mem.trim(u8, raw_provider, " \t\r\n");
    const raw_model = model_query orelse {
        if (requested_provider.len != 0)
            std.process.fatal("--subagent-provider requires --subagent-model", .{});
        if (disable_default_ladder) return null;
        return defaultLadderProvider(keys, root);
    };
    const requested_model = std.mem.trim(u8, raw_model, " \t\r\n");
    if (requested_model.len == 0)
        std.process.fatal("--subagent-model/GRAFF_SUBAGENT_MODEL cannot be empty", .{});
    const provider_arg: ?[]const u8 = if (requested_provider.len == 0) null else requested_provider;
    return subagentProvider(keys, root, provider_arg, requested_model, allow_cross_provider) catch |err| switch (err) {
        error.UnknownModel => std.process.fatal("unknown subagent model '{s}' — run `graff models refresh` or see /models", .{requested_model}),
        error.UnknownProvider => std.process.fatal("unknown subagent provider '{s}' — run `graff models` to list providers", .{requested_provider}),
        error.ModelNotOnProvider => std.process.fatal("subagent model '{s}' is not available through provider '{s}'", .{ requested_model, if (provider_arg) |id| id else root.id }),
        error.CrossProviderConsentRequired => std.process.fatal("subagent provider '{s}' differs from root provider '{s}' — add --allow-cross-provider-subagents to confirm prompts and code may be sent to both providers", .{ requested_provider, root.id }),
        error.MissingKey => std.process.fatal("no key/login for subagent model '{s}' via '{s}'", .{ requested_model, if (provider_arg) |id| id else root.id }),
    };
}

test "worker selection stays provider-local unless explicitly allowed" {
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    for (provider_mod.provider_specs, &keys.values) |spec, *value| {
        if (std.mem.eql(u8, spec.id, "codex") or
            std.mem.eql(u8, spec.id, "kimi")) value.* = "test-token";
    }
    const root = try keys.providerById("codex", "gpt-5.6-sol");
    const terra = try subagentProvider(keys, root, null, "5.6-terra", false);
    try std.testing.expectEqualStrings("codex", terra.id);
    try std.testing.expectEqualStrings("gpt-5.6-terra", terra.model);
    try std.testing.expectError(
        error.CrossProviderConsentRequired,
        subagentProvider(keys, root, "kimi", "k3", false),
    );
    const kimi = try subagentProvider(keys, root, "kimi", "k3", true);
    try std.testing.expectEqualStrings("kimi", kimi.id);
    try std.testing.expectEqualStrings("k3", kimi.model);
    try std.testing.expectError(
        error.ModelNotOnProvider,
        subagentProvider(keys, root, null, "gpt-5.6", false),
    );
    try std.testing.expectError(
        error.UnknownModel,
        subagentProvider(keys, root, null, "not-a-real-model", false),
    );
    try std.testing.expectError(
        error.UnknownProvider,
        subagentProvider(keys, root, "not-a-provider", "k3", true),
    );
}

test "defaultLadderModel: descends one rung per provider, bottom rung inherits" {
    const mk = struct {
        fn p(id: []const u8, model: []const u8) provider_mod.Provider {
            return .{ .id = id, .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = model, .context = 0 };
        }
    }.p;
    // codex: sol -> terra -> luna -> (bottom, inherit)
    try std.testing.expectEqualStrings("gpt-5.6-terra", defaultLadderModel(mk("codex", "gpt-5.6-sol")).?);
    try std.testing.expectEqualStrings("gpt-5.6-luna", defaultLadderModel(mk("codex", "gpt-5.6-terra")).?);
    try std.testing.expect(defaultLadderModel(mk("codex", "gpt-5.6-luna")) == null);
    // openai: same shape, sibling names
    try std.testing.expectEqualStrings("gpt-5.6-terra", defaultLadderModel(mk("openai", "gpt-5.6")).?);
    // anthropic: opus -> sonnet -> haiku -> (bottom)
    try std.testing.expectEqualStrings("claude-sonnet-4-6", defaultLadderModel(mk("anthropic", "claude-opus-4-8")).?);
    try std.testing.expectEqualStrings("claude-haiku-4-5", defaultLadderModel(mk("anthropic", "claude-sonnet-4-6")).?);
    try std.testing.expect(defaultLadderModel(mk("anthropic", "claude-haiku-4-5")) == null);
    // deepseek: pro steps to its only cheaper rung (flash); flash has nowhere lower
    try std.testing.expectEqualStrings("deepseek-v4-flash", defaultLadderModel(mk("deepseek", "deepseek-v4-pro")).?);
    try std.testing.expect(defaultLadderModel(mk("deepseek", "deepseek-v4-flash")) == null);
    // unlisted provider -> no ladder at all
    try std.testing.expect(defaultLadderModel(mk("xai", "grok-4.3")) == null);
    // a real, catalogued model that just isn't a rung on its own provider's
    // ladder -> never guess at the nearest one
    try std.testing.expect(defaultLadderModel(mk("anthropic", "claude-opus-4-5")) == null);
}

test "default ladder: resolves the mid sibling when no flags are given" {
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    for (provider_mod.provider_specs, &keys.values) |spec, *value| {
        if (std.mem.eql(u8, spec.id, "codex") or std.mem.eql(u8, spec.id, "anthropic"))
            value.* = "test-token";
    }
    const codex_root = try keys.providerById("codex", "gpt-5.6-sol");
    const worker = resolveSubagentProvider(keys, codex_root, null, null, false, false).?;
    try std.testing.expectEqualStrings("codex", worker.id); // provider-local, unpinned
    try std.testing.expectEqualStrings("gpt-5.6-terra", worker.model);

    const anthropic_root = try keys.providerById("anthropic", "claude-opus-4-8");
    const anthropic_worker = resolveSubagentProvider(keys, anthropic_root, null, null, false, false).?;
    try std.testing.expectEqualStrings("anthropic", anthropic_worker.id);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", anthropic_worker.model);
}

test "default ladder: bottom-rung and off-ladder roots inherit (resolve to null)" {
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    for (provider_mod.provider_specs, &keys.values) |spec, *value| {
        if (std.mem.eql(u8, spec.id, "codex") or std.mem.eql(u8, spec.id, "xai"))
            value.* = "test-token";
    }
    const luna_root = try keys.providerById("codex", "gpt-5.6-luna");
    try std.testing.expect(resolveSubagentProvider(keys, luna_root, null, null, false, false) == null);

    const xai_root = try keys.providerById("xai", "grok-4.3"); // unlisted family, never guess
    try std.testing.expect(resolveSubagentProvider(keys, xai_root, null, null, false, false) == null);
}

test "--no-subagent-tier opts out of the default ladder back to plain inherit" {
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    for (provider_mod.provider_specs, &keys.values) |spec, *value| {
        if (std.mem.eql(u8, spec.id, "codex")) value.* = "test-token";
    }
    const root = try keys.providerById("codex", "gpt-5.6-sol");
    try std.testing.expect(resolveSubagentProvider(keys, root, null, null, false, true) == null);
}

test "explicit --subagent-model still wins over the default ladder" {
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    for (provider_mod.provider_specs, &keys.values) |spec, *value| {
        if (std.mem.eql(u8, spec.id, "codex")) value.* = "test-token";
    }
    const root = try keys.providerById("codex", "gpt-5.6-sol");
    // The ladder default would be terra; an explicit pin to luna wins.
    const pinned = resolveSubagentProvider(keys, root, null, "gpt-5.6-luna", false, false).?;
    try std.testing.expectEqualStrings("gpt-5.6-luna", pinned.model);
}

test "default ladder never crosses a provider boundary implicitly" {
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    for (provider_mod.provider_specs, &keys.values) |spec, *value| {
        if (std.mem.eql(u8, spec.id, "codex") or std.mem.eql(u8, spec.id, "openai") or
            std.mem.eql(u8, spec.id, "anthropic") or std.mem.eql(u8, spec.id, "deepseek"))
            value.* = "test-token";
    }
    const Case = struct { id: []const u8, model: []const u8 };
    for ([_]Case{
        .{ .id = "codex", .model = "gpt-5.6-sol" },
        .{ .id = "openai", .model = "gpt-5.6" },
        .{ .id = "anthropic", .model = "claude-opus-4-8" },
        .{ .id = "deepseek", .model = "deepseek-v4-pro" },
    }) |case| {
        const root = try keys.providerById(case.id, case.model);
        const worker = resolveSubagentProvider(keys, root, null, null, false, false) orelse continue;
        try std.testing.expectEqualStrings(case.id, worker.id); // same provider as root, always
    }
}

test "ladder rungs vs providerClass: documented, intentional disagreement (#291)" {
    // #291 requires ladder tier labels to match scoring.providerClass()
    // output for the same models, "or report the discrepancy rather than
    // papering over it." providerClass's needle table buckets the whole
    // gpt-5.x family (sol/terra/luna alike) as "frontier" — it has no
    // name-based way to split terra/luna out — and deepseek-v4-flash as
    // "small" via its "flash" needle, even though the ladder treats flash as
    // deepseek's only cheaper (mid) rung. This test pins that the mismatch
    // is real and known today, not a bug the ladder introduced; it is
    // reported rather than silently patched into scoring.zig's needle
    // table, which other, unrelated callers (DGM fitness scoring/fleet
    // niche gating) also depend on.
    try std.testing.expectEqualStrings("frontier", @import("scoring.zig").providerClass("gpt-5.6-sol"));
    try std.testing.expectEqualStrings("frontier", @import("scoring.zig").providerClass("gpt-5.6-terra")); // ladder rung: mid
    try std.testing.expectEqualStrings("frontier", @import("scoring.zig").providerClass("gpt-5.6-luna")); // ladder rung: small
    try std.testing.expectEqualStrings("frontier", @import("scoring.zig").providerClass("deepseek-v4-pro"));
    try std.testing.expectEqualStrings("small", @import("scoring.zig").providerClass("deepseek-v4-flash")); // ladder rung: mid
    // Claude already agrees end-to-end (opus/sonnet/haiku are tier-distinct
    // needles in providerClass, matching the ladder one-for-one).
    try std.testing.expectEqualStrings("frontier", @import("scoring.zig").providerClass("claude-opus-4-8"));
    try std.testing.expectEqualStrings("mid", @import("scoring.zig").providerClass("claude-sonnet-4-6"));
    try std.testing.expectEqualStrings("small", @import("scoring.zig").providerClass("claude-haiku-4-5"));
}
