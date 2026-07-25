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
