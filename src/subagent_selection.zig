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

const catalog_selection = @import("catalog_selection.zig");
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
///
/// GPT-6 roots keep their model: demoting Astra onto Sol is a SWE-bench
/// regression (Astra-low beats Sol-high). Unpinned workers inherit;
/// `tier: mid` / `tier: small` still seat Sol / Luna when asked.
fn defaultLadderModel(root: provider_mod.Provider) ?[]const u8 {
    const ladder = tier_ladder.forModel(root.id, root.model) orelse return null;
    if (std.mem.startsWith(u8, root.model, "gpt-6")) return null;
    if (ladder.small) |small| {
        if (pricing.modelAliasEquals(small, "mimo-v2.6-flash")) {
            if (!pricing.modelAliasEquals(root.model, small) and @import("subagent_pin.zig").rungAffordableOn(root, small)) return small;
            return null;
        }
    }
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
    const resolved = subagentProvider(keys, root, null, target, false) catch return null;
    g_default_from_ladder = true;
    return resolved;
}

/// #372 routing trace: true when the session's worker provider came from the
/// #291 default ladder descent rather than an explicit --subagent-model, so
/// an unpinned spawn can honestly report `source=ladder` vs
/// `source=session-default` instead of conflating the two.
pub var g_default_from_ladder: bool = false;

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
    const model = modelForProvider(requested_provider, requested_model) orelse explicit: {
        // Same rule as `--model <provider>/<model>`: a login-served router
        // (the codegraff gateway) serves what its live catalog lists, which
        // the baked table does not carry, so an explicitly named worker
        // provider takes the exact model name the way the root model does.
        if (provider_query != null) if (provider_mod.specFor(requested_provider)) |spec| {
            if (catalog_selection.acceptsExplicitModel(spec, requested_model)) break :explicit requested_model;
        };
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
    const root = try keys.providerById("codex", "gpt-6-astra");
    const luna = try subagentProvider(keys, root, null, "gpt-6-luna", false);
    try std.testing.expectEqualStrings("codex", luna.id);
    try std.testing.expectEqualStrings("gpt-6-luna", luna.model);
    try std.testing.expectError(
        error.CrossProviderConsentRequired,
        subagentProvider(keys, root, "kimi", "k3", false),
    );
    const kimi = try subagentProvider(keys, root, "kimi", "k3", true);
    try std.testing.expectEqualStrings("kimi", kimi.id);
    try std.testing.expectEqualStrings("k3", kimi.model);
    try std.testing.expectError(
        error.ModelNotOnProvider,
        subagentProvider(keys, root, null, "deepseek-v4-pro", false),
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

test "an explicit worker provider takes a gateway model the baked table lacks" {
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    for (provider_mod.provider_specs, &keys.values) |spec, *value| {
        if (std.mem.eql(u8, spec.id, "codex") or
            std.mem.eql(u8, spec.id, "codegraff")) value.* = "test-token";
    }
    const root = try keys.providerById("codex", "gpt-6.1-sol");
    const gateway_only = "gateway-only-model-not-in-the-baked-table";
    try std.testing.expect(modelForProvider("codegraff", gateway_only) == null);
    const worker = try subagentProvider(keys, root, "codegraff", gateway_only, true);
    try std.testing.expectEqualStrings("codegraff", worker.id);
    try std.testing.expectEqualStrings(gateway_only, worker.model);
    // Consent is still required to cross the provider boundary, and a bare
    // name with no provider still has to be a catalogued model.
    try std.testing.expectError(error.CrossProviderConsentRequired, subagentProvider(keys, root, "codegraff", gateway_only, false));
    try std.testing.expectError(error.UnknownModel, subagentProvider(keys, root, null, gateway_only, false));
}

test "defaultLadderModel: descends one rung per provider, bottom rung inherits" {
    const mk = struct {
        fn p(id: []const u8, model: []const u8) provider_mod.Provider {
            return .{ .id = id, .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = model, .context = 0 };
        }
    }.p;
    // codex / openai: GPT-6 roots keep their model (Astra-low beats Sol-high);
    // tier pins still reach Sol and Luna.
    for ([_][]const u8{ "codex", "openai" }) |id| {
        for ([_][]const u8{ "gpt-6-astra", "gpt-6-sol", "gpt-6-luna" }) |model|
            try std.testing.expect(defaultLadderModel(mk(id, model)) == null);
    }
    // anthropic: opus-5-5 -> sonnet-5-5 -> (bottom) (ADR 0219). #471: a rung
    // must be a cheaper seat, so older opus generations are not rungs, and a
    // root still on one is off-ladder and inherits.
    try std.testing.expectEqualStrings("claude-sonnet-5-5", defaultLadderModel(mk("anthropic", "claude-opus-5-5")).?);
    try std.testing.expect(defaultLadderModel(mk("anthropic", "claude-sonnet-5-5")) == null);
    try std.testing.expect(defaultLadderModel(mk("anthropic", "claude-opus-5")) == null);
    try std.testing.expect(defaultLadderModel(mk("anthropic", "claude-opus-4-8")) == null);
    // deepseek / codegraff: pro (the session default) descends to flash;
    // a flash root is already the cheap seat and inherits.
    try std.testing.expectEqualStrings("deepseek-v4-flash", defaultLadderModel(mk("deepseek", "deepseek-v4-pro")).?);
    try std.testing.expect(defaultLadderModel(mk("deepseek", "deepseek-v4-flash")) == null);
    try std.testing.expectEqualStrings("deepseek-v4-flash", defaultLadderModel(mk("codegraff", "deepseek-v4-pro")).?);
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
    const astra_root = try keys.providerById("codex", "gpt-6-astra");
    try std.testing.expect(resolveSubagentProvider(keys, astra_root, null, null, false, false) == null);

    const anthropic_root = try keys.providerById("anthropic", "claude-opus-5-5");
    const anthropic_worker = resolveSubagentProvider(keys, anthropic_root, null, null, false, false).?;
    try std.testing.expectEqualStrings("anthropic", anthropic_worker.id);
    try std.testing.expectEqualStrings("claude-sonnet-5-5", anthropic_worker.model);
}

test "default ladder: bottom-rung and off-ladder roots inherit (resolve to null)" {
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    for (provider_mod.provider_specs, &keys.values) |spec, *value| {
        if (std.mem.eql(u8, spec.id, "codex") or std.mem.eql(u8, spec.id, "xai"))
            value.* = "test-token";
    }
    const luna_root = try keys.providerById("codex", "gpt-6-luna");
    try std.testing.expect(resolveSubagentProvider(keys, luna_root, null, null, false, false) == null);

    const xai_root = try keys.providerById("xai", "grok-4.3"); // unlisted family, never guess
    try std.testing.expect(resolveSubagentProvider(keys, xai_root, null, null, false, false) == null);
}

test "--no-subagent-tier opts out of the default ladder back to plain inherit" {
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    for (provider_mod.provider_specs, &keys.values) |spec, *value| {
        if (std.mem.eql(u8, spec.id, "anthropic")) value.* = "test-token";
    }
    const root = try keys.providerById("anthropic", "claude-opus-5-5");
    try std.testing.expect(resolveSubagentProvider(keys, root, null, null, false, false) != null);
    try std.testing.expect(resolveSubagentProvider(keys, root, null, null, false, true) == null);
}

test "explicit --subagent-model still wins over the default ladder" {
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    for (provider_mod.provider_specs, &keys.values) |spec, *value| {
        if (std.mem.eql(u8, spec.id, "codex")) value.* = "test-token";
    }
    const root = try keys.providerById("codex", "gpt-6-astra");
    // The ladder default would inherit Astra; an explicit pin to luna wins.
    const pinned = resolveSubagentProvider(keys, root, null, "gpt-6-luna", false, false).?;
    try std.testing.expectEqualStrings("gpt-6-luna", pinned.model);
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
        .{ .id = "codex", .model = "gpt-6-sol" },
        .{ .id = "openai", .model = "gpt-6-astra" },
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
    // papering over it." The gpt family now agrees end-to-end with the
    // ladder, like claude: "sol"/"luna" are tier-distinct needles in
    // providerClass (as opus/sonnet/haiku are), so pullElites and fleet
    // propose events keyed on the class are no longer rung-blind — a sol
    // root pulls "mid" elites, not elites grown on astra.
    try std.testing.expectEqualStrings("frontier", @import("scoring.zig").providerClass("gpt-6-astra"));
    try std.testing.expectEqualStrings("mid", @import("scoring.zig").providerClass("gpt-6-sol")); // ladder rung: mid
    try std.testing.expectEqualStrings("small", @import("scoring.zig").providerClass("gpt-6-luna")); // ladder rung: small
    try std.testing.expectEqualStrings("frontier", @import("scoring.zig").providerClass("deepseek-v4-pro"));
    try std.testing.expectEqualStrings("small", @import("scoring.zig").providerClass("deepseek-v4-flash")); // ladder rung: small
    // Claude agrees end-to-end (opus/sonnet/haiku are tier-distinct needles
    // in providerClass, matching the ladder one-for-one).
    try std.testing.expectEqualStrings("frontier", @import("scoring.zig").providerClass("claude-opus-4-8"));
    try std.testing.expectEqualStrings("mid", @import("scoring.zig").providerClass("claude-sonnet-4-6"));
    try std.testing.expectEqualStrings("small", @import("scoring.zig").providerClass("claude-haiku-4-5"));
}
