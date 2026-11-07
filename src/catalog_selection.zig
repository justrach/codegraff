//! Shared routing predicates for demand-loaded model catalogs.
//!
//! Catalog implementations differ (Codex account data, Kimi metadata, generic
//! OpenAI-compatible routers), but deciding whether a user selection can see a
//! provider is identical. Keeping that rule provider-id-driven means a new
//! dynamic router does not need another startup or `/model` special case.

const std = @import("std");
const pricing = @import("pricing.zig");
const provider = @import("provider.zig");
const serde = @import("serde.zig");

/// Account-backed catalogs are discovery snapshots, not availability gates.
/// Like a saved selection, an explicit model must reach the selected backend;
/// credentials are still checked by providerById. API-key-only providers keep
/// exact-row validation; callers retain their local-server exceptions.
pub fn acceptsExplicitModel(spec: provider.ProviderSpec, model: []const u8) bool {
    if (std.mem.trim(u8, model, " \t").len == 0) return false;
    return spec.login != .api_key or pricing.providerModelInTable(spec.id, model);
}

pub fn explicitProvider(query: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, query, " \t");
    const end = std.mem.indexOfAny(u8, trimmed, " /\t") orelse trimmed.len;
    const id = trimmed[0..end];
    return if (provider.specFor(id)) |spec| spec.id else null;
}

/// Empty and unknown/fuzzy model queries may observe a provider's newly
/// discovered rows. An explicit provider or exact baked model narrows the load.
pub fn queryMayUse(provider_id: []const u8, query: []const u8) bool {
    const trimmed = std.mem.trim(u8, query, " \t");
    if (trimmed.len == 0) return true;
    if (explicitProvider(trimmed)) |id| return std.mem.eql(u8, id, provider_id);
    if (pricing.modelInTable(trimmed)) return pricing.providerModelInTable(provider_id, trimmed);
    return true;
}

/// startupMayUse, plus the providers workers may be seated on: the explicit
/// --subagent-provider, and, once the session consented to cross-provider
/// workers, any provider with a login (a persona may name it as
/// `<provider>/<model>`). Loading their catalogs is what lets those workers'
/// models resolve and their calls be priced.
pub fn startupLoads(keys: provider.Keys, provider_id: []const u8, model_flag: ?[]const u8, saved: ?serde.SavedModel, worker_hint: ?[]const u8) bool {
    if (startupMayUse(keys, provider_id, model_flag, saved)) return true;
    if (keys.get(provider_id) == null) return false;
    if (worker_hint) |h| if (std.mem.eql(u8, std.mem.trim(u8, h, " \t"), provider_id)) return true;
    return @import("subagent_selection.zig").g_cross_provider_consent;
}

pub fn startupMayUse(keys: provider.Keys, provider_id: []const u8, model_flag: ?[]const u8, saved: ?serde.SavedModel) bool {
    if (keys.get(provider_id) == null) return false;
    if (model_flag) |query| return queryMayUse(provider_id, query);
    if (saved) |selection| {
        if (std.mem.eql(u8, selection.pid, provider_id)) return true;
        if (pricing.providerModelInTable(selection.pid, selection.model) and keys.get(selection.pid) != null) return false;
        return true;
    }
    const fallback = keys.defaultProvider() catch return false;
    return std.mem.eql(u8, fallback.id, provider_id);
}

/// Structured `set_model` has separate provider/model fields. Return the part
/// whose routing reachability should decide which catalogs are demand-loaded.
pub fn controlQuery(provider_query: []const u8, model_query: []const u8, legacy_name: []const u8) []const u8 {
    if (std.mem.trim(u8, provider_query, " \t").len != 0) return provider_query;
    if (std.mem.trim(u8, model_query, " \t").len != 0) return model_query;
    return legacy_name;
}

test "catalog selection is provider-driven rather than catalog-specific" {
    try std.testing.expect(queryMayUse("codegraff", ""));
    try std.testing.expect(queryMayUse("codegraff", "codegraff"));
    try std.testing.expect(!queryMayUse("codegraff", "kimi"));
    try std.testing.expect(queryMayUse("kimi", "k3"));
    try std.testing.expect(!queryMayUse("codegraff", "k3"));
    try std.testing.expect(queryMayUse("codegraff", "future-router-rollout"));

    var keys: provider.Keys = .{ .values = @splat(null) };
    for (provider.provider_specs, &keys.values) |spec, *value| {
        if (std.mem.eql(u8, spec.id, "kimi") or std.mem.eql(u8, spec.id, "codegraff")) value.* = "token";
    }
    try std.testing.expect(startupMayUse(keys, "codegraff", "codegraff", null));
    try std.testing.expect(!startupMayUse(keys, "codegraff", "kimi", null));
    try std.testing.expect(startupMayUse(keys, "codegraff", null, .{ .pid = "codegraff", .model = "deepseek-v4-pro" }));
    try std.testing.expect(!startupMayUse(keys, "codegraff", null, .{ .pid = "kimi", .model = "k3" }));
}

test "startup loads the catalog of a provider workers may be seated on" {
    const selection = @import("subagent_selection.zig");
    const saved_consent = selection.g_cross_provider_consent;
    defer selection.g_cross_provider_consent = saved_consent;
    var keys: provider.Keys = .{ .values = @splat(null) };
    for (provider.provider_specs, &keys.values) |spec, *value| {
        if (std.mem.eql(u8, spec.id, "codex") or std.mem.eql(u8, spec.id, "codegraff")) value.* = "test-token";
    }
    selection.g_cross_provider_consent = false;
    try std.testing.expect(!startupLoads(keys, "codegraff", "codex", null, null));
    try std.testing.expect(startupLoads(keys, "codegraff", "codex", null, "codegraff"));
    selection.g_cross_provider_consent = true;
    try std.testing.expect(startupLoads(keys, "codegraff", "codex", null, null));
    // A provider with no login is never loaded for workers.
    try std.testing.expect(!startupLoads(keys, "openrouter", "codex", null, null));
}
