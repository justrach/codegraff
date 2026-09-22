const std = @import("std");
const pricing = @import("pricing.zig");
const provider = @import("provider.zig");
const Keys = provider.Keys;
const provider_specs = provider.provider_specs;

test "providerFor (#294): a catalogued model with no keyed provider fails instead of routing to the gateway" {
    const saved = pricing.active_model_table;
    defer pricing.active_model_table = saved;
    pricing.active_model_table = &.{.{ .provider = "codex", .name = "native-only-fixture", .context = 270_000 }};
    // The reported symptom: an expired ~/.codex/auth.json made a Codex-only
    // model resolve to the CodeGraff gateway, so the user saw a balance/credits
    // error while trying to use Codex. native-only-fixture is catalogued ONLY under
    // provider `codex`, which makes it the exact reproduction.
    try std.testing.expect(pricing.providerModelInTable("codex", "native-only-fixture"));
    try std.testing.expect(!pricing.providerModelInTable("openai", "native-only-fixture"));
    try std.testing.expect(!pricing.providerModelInTable("codegraff", "native-only-fixture"));

    // Everything keyed EXCEPT codex — i.e. the login expired mid-session.
    var values: [provider_specs.len]?[]const u8 = @splat("k");
    for (provider_specs, 0..) |spec, i| {
        if (std.mem.eql(u8, spec.id, "codex")) values[i] = null;
    }
    const no_codex = Keys{ .values = values };
    // Before the fix this returned the codegraff gateway carrying native-only-fixture.
    try std.testing.expectError(error.MissingKey, no_codex.providerFor("native-only-fixture"));

    // With the codex credential present it still routes to codex, unchanged.
    const all = Keys{ .values = @splat("k") };
    try std.testing.expectEqualStrings("codex", (try all.providerFor("native-only-fixture")).id);

    pricing.active_model_table = saved;

    // A model served by several providers still falls through to whichever is
    // keyed — losing one credential must not break a model another can serve.
    try std.testing.expectEqualStrings("openai", (try no_codex.providerFor("gpt-5.6-terra")).id);

    // The gateway fallback survives for genuinely UNCATALOGUED models, which is
    // all it was ever meant to cover.
    try std.testing.expect(!pricing.modelInTable("totally-made-up-model"));
    try std.testing.expectEqualStrings("codegraff", (try no_codex.providerFor("totally-made-up-model")).id);
    try std.testing.expectEqualStrings("anthropic", (try no_codex.providerFor("claude-does-not-exist")).id);
}
