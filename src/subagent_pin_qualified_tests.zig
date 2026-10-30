//! A role persona naming its own provider (`model: codegraff/mercury-3`):
//! seated on that provider only with the session's cross-provider consent
//! and a login for it.

const std = @import("std");
const pin_mod = @import("subagent_pin.zig");
const provider_mod = @import("provider.zig");
const Provider = provider_mod.Provider;

fn codexBase() Provider {
    return .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "https://example.invalid", .api_key = "k", .model = "gpt-6-astra", .context = 272_000 };
}

test "a <provider>/<model> pin seats a role on another provider only with consent and a login" {
    const selection = @import("subagent_selection.zig");
    const bench_priors = @import("bench_priors.zig");
    const saved_consent = selection.g_cross_provider_consent;
    const saved_keys = bench_priors.g_keys;
    defer selection.g_cross_provider_consent = saved_consent;
    defer bench_priors.g_keys = saved_keys;
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    for (provider_mod.provider_specs, &keys.values) |spec, *value| {
        if (std.mem.eql(u8, spec.id, "codex") or std.mem.eql(u8, spec.id, "codegraff")) value.* = "test-token";
    }
    bench_priors.g_keys = &keys;
    const scout: pin_mod.Pin = .{ .model = "codegraff/gateway-only-scout-model", .from_persona = true };

    selection.g_cross_provider_consent = false;
    const refused = pin_mod.resolve(codexBase(), scout);
    try std.testing.expectEqual(pin_mod.Outcome.cross_provider_unconsented, refused.outcome);
    try std.testing.expect(refused.provider == null);

    selection.g_cross_provider_consent = true;
    const seated = pin_mod.resolve(codexBase(), scout);
    try std.testing.expectEqual(pin_mod.Outcome.pinned, seated.outcome);
    try std.testing.expectEqualStrings("codegraff", seated.provider.?.id);
    try std.testing.expectEqualStrings("gateway-only-scout-model", seated.provider.?.model);

    // Naming the child's own provider just drops the prefix.
    const local = pin_mod.resolve(codexBase(), .{ .model = "codex/gpt-6-luna" });
    try std.testing.expectEqualStrings("codex", local.provider.?.id);
    try std.testing.expectEqualStrings("gpt-6-luna", local.provider.?.model);

    // No login for the named provider keeps the session default.
    keys.values = @splat(null);
    try std.testing.expectEqual(pin_mod.Outcome.no_login, pin_mod.resolve(codexBase(), scout).outcome);
}
