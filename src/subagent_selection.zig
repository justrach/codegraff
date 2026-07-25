//! Startup-time routing for the optional worker model shape.
//!
//! A provider boundary is materially different from a model pin: prompts,
//! tool results, billing, and credentials move to another service. Cross-
//! provider workers therefore require both an explicit provider and an
//! explicit consent flag.
const std = @import("std");

const pricing = @import("pricing.zig");
const provider_mod = @import("provider.zig");

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

fn modelForProvider(provider_id: []const u8, query: []const u8) ?[]const u8 {
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
) ?provider_mod.Provider {
    const raw_provider = provider_query orelse "";
    const requested_provider = std.mem.trim(u8, raw_provider, " \t\r\n");
    const raw_model = model_query orelse {
        if (requested_provider.len != 0)
            std.process.fatal("--subagent-provider requires --subagent-model", .{});
        return null;
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
