//! Tests for #292's per-persona / per-spawn worker model pins. Split out of
//! subagent_pin.zig so the module itself stays comfortably under the 600-line
//! cap; wired into the test root by test_hooks.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const fleet = @import("fleet.zig");
const pin_mod = @import("subagent_pin.zig");
const provider_mod = @import("provider.zig");
const Provider = provider_mod.Provider;
const Tier = pin_mod.Tier;

fn obj(a: Allocator, s: []const u8) std.json.ObjectMap {
    return (std.json.parseFromSliceLeaky(Value, a, s, .{}) catch unreachable).object;
}

/// A codex-provider child on the flagship rung — the base a pin resolves
/// against. Built by hand rather than through Keys so the tests need no
/// credentials; withModel only ever reads `id`/`api_key`/`account`/`source`
/// off it.
fn codexBase() Provider {
    return .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "https://example.invalid", .api_key = "k", .model = "gpt-5.6-sol", .context = 272_000 };
}

test "persona frontmatter parse: model/tier land on AgentType, a bad tier is dropped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // This is exactly the shape loadAgentDir produces; parsing itself is
    // covered end-to-end by the loader, so what is pinned here is the
    // contract the loader must satisfy: an unknown tier is "no opinion", not
    // a load failure, and an exact model rides through unvalidated.
    const saved = fleet.g_agent_types;
    defer fleet.g_agent_types = saved;
    fleet.g_agent_types = &.{
        .{ .name = "implementer", .desc = "", .prompt = "x", .tier = Tier.parse("mid") },
        .{ .name = "reviewer", .desc = "", .prompt = "x", .model = "gpt-5.6-terra" },
        .{ .name = "typo", .desc = "", .prompt = "x", .tier = Tier.parse("cheap") }, // off-vocabulary
        .{ .name = "plain", .desc = "", .prompt = "x" },
    };

    try std.testing.expectEqual(Tier.mid, pin_mod.personaPin("implementer").tier.?);
    try std.testing.expect(pin_mod.personaPin("implementer").model == null);
    try std.testing.expectEqualStrings("gpt-5.6-terra", pin_mod.personaPin("reviewer").model.?);
    // A persona whose `tier:` did not parse contributes nothing at all — the
    // spawn keeps the session default rather than inheriting a guess.
    try std.testing.expect(pin_mod.personaPin("typo").isNone());
    try std.testing.expect(pin_mod.personaPin("plain").isNone());
    // An unknown persona name is never an error (matches resolveIsolation).
    try std.testing.expect(pin_mod.personaPin("not-a-persona").isNone());
    try std.testing.expect(pin_mod.personaPin("").isNone());

    // …and the pin reaches a spawn that only names the persona.
    try std.testing.expectEqualStrings("gpt-5.6-terra", pin_mod.forSpawn(codexBase(), obj(a, "{\"agent\":\"implementer\"}")).provider.?.model);
    try std.testing.expectEqualStrings("gpt-5.6-terra", pin_mod.forSpawn(codexBase(), obj(a, "{\"agent\":\"reviewer\"}")).provider.?.model);
    try std.testing.expect(pin_mod.forSpawn(codexBase(), obj(a, "{\"agent\":\"typo\"}")).provider == null);
    try std.testing.expect(pin_mod.forSpawn(codexBase(), obj(a, "{\"agent\":\"plain\"}")).provider == null);
}

test "spawn override resolution: exact name, alias, ladder rung, and no-op" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = codexBase();

    // Exact catalog name.
    const exact = pin_mod.forSpawn(base, obj(a, "{\"model\":\"gpt-5.6-luna\"}"));
    try std.testing.expectEqual(pin_mod.Outcome.pinned, exact.outcome);
    try std.testing.expectEqualStrings("gpt-5.6-luna", exact.provider.?.model);
    try std.testing.expectEqualStrings("codex", exact.provider.?.id); // provider-local, always
    try std.testing.expectEqualStrings("k", exact.provider.?.api_key); // same credential
    // The context window is re-derived for the new model, not inherited.
    try std.testing.expect(exact.provider.?.context != 0);

    // Abbreviation: the same resolver --subagent-model uses (unique substring).
    const alias = pin_mod.forSpawn(base, obj(a, "{\"model\":\" 5.6-terra \"}")); // whitespace trimmed
    try std.testing.expectEqualStrings("gpt-5.6-terra", alias.provider.?.model);

    // Ladder rung instead of a name.
    const rung = pin_mod.forSpawn(base, obj(a, "{\"tier\":\"small\"}"));
    try std.testing.expectEqual(pin_mod.Outcome.pinned, rung.outcome);
    try std.testing.expectEqualStrings("gpt-5.6-luna", rung.provider.?.model);
    try std.testing.expectEqualStrings("gpt-5.6-terra", pin_mod.forSpawn(base, obj(a, "{\"tier\":\"mid\"}")).provider.?.model);

    // A pin naming the model the child already has changes nothing, and says so.
    const same = pin_mod.forSpawn(base, obj(a, "{\"tier\":\"frontier\"}"));
    try std.testing.expectEqual(pin_mod.Outcome.same, same.outcome);
    try std.testing.expect(same.provider == null);

    // No pin at all: untouched, and cheap — nothing is resolved.
    const none = pin_mod.forSpawn(base, obj(a, "{\"description\":\"x\",\"prompt\":\"y\"}"));
    try std.testing.expectEqual(pin_mod.Outcome.none, none.outcome);
    try std.testing.expect(none.provider == null);
}

test "precedence: spawn param > persona pin > session default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const saved = fleet.g_agent_types;
    defer fleet.g_agent_types = saved;
    fleet.g_agent_types = &.{
        .{ .name = "pinned-frontier", .desc = "", .prompt = "x", .model = "gpt-5.6-sol" },
        .{ .name = "pinned-mid", .desc = "", .prompt = "x", .tier = .mid },
        .{ .name = "both", .desc = "", .prompt = "x", .model = "gpt-5.6-terra", .tier = .small },
    };
    // The session default is whatever the caller already resolved — here the
    // #291 ladder's answer for a sol root, i.e. terra.
    const session_default: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "k", .model = "gpt-5.6-terra", .context = 272_000 };

    // 1. An explicit spawn param beats the persona, in BOTH directions —
    //    including lowering a persona that pinned itself to the flagship,
    //    which is the case a merge-instead-of-replace rule would break.
    try std.testing.expectEqualStrings(
        "gpt-5.6-luna",
        pin_mod.forSpawn(session_default, obj(a, "{\"agent\":\"pinned-frontier\",\"tier\":\"small\"}")).provider.?.model,
    );
    try std.testing.expectEqualStrings(
        "gpt-5.6-sol",
        pin_mod.forSpawn(session_default, obj(a, "{\"agent\":\"pinned-mid\",\"model\":\"gpt-5.6-sol\"}")).provider.?.model,
    );
    // 2. No spawn param → the persona's pin applies over the session default.
    try std.testing.expectEqualStrings(
        "gpt-5.6-sol",
        pin_mod.forSpawn(session_default, obj(a, "{\"agent\":\"pinned-frontier\"}")).provider.?.model,
    );
    // 3. Neither → the session default is kept untouched.
    try std.testing.expect(pin_mod.forSpawn(session_default, obj(a, "{\"prompt\":\"y\"}")).provider == null);
    // Within one level, an exact model beats a tier (both on the call…
    try std.testing.expectEqualStrings(
        "gpt-5.6-sol",
        pin_mod.forSpawn(session_default, obj(a, "{\"model\":\"gpt-5.6-sol\",\"tier\":\"small\"}")).provider.?.model,
    );
    // …and both on the persona).
    try std.testing.expectEqual(pin_mod.Outcome.same, pin_mod.forSpawn(session_default, obj(a, "{\"agent\":\"both\"}")).outcome);
}

test "graceful fallback: every unhonorable pin keeps the session default, never fails" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = codexBase();

    const Case = struct { args: []const u8, want: pin_mod.Outcome };
    for ([_]Case{
        // A name no catalog knows.
        .{ .args = "{\"model\":\"not-a-real-model\"}", .want = .unknown_model },
        // A real model this provider does not serve (anthropic's, on codex).
        .{ .args = "{\"model\":\"claude-opus-4-8\"}", .want = .unknown_model },
        // An abbreviation matching more than one row is ambiguous, not a coin flip.
        .{ .args = "{\"model\":\"gpt\"}", .want = .unknown_model },
        // An off-vocabulary tier is reported, and does NOT silently fall
        // through to the persona the caller was trying to override.
        .{ .args = "{\"tier\":\"cheap\"}", .want = .unknown_tier },
        .{ .args = "{\"tier\":\"Mid\"}", .want = .unknown_tier },
        // Non-string values are simply not a pin.
        .{ .args = "{\"model\":42}", .want = .none },
        .{ .args = "{\"model\":\"   \"}", .want = .none },
    }) |case| {
        const got = pin_mod.forSpawn(base, obj(a, case.args));
        try std.testing.expectEqual(case.want, got.outcome);
        try std.testing.expect(got.provider == null); // the spawn still runs
        // Every non-honored outcome carries a reason for the trace.
        if (case.want != .none) try std.testing.expect(got.outcome.describe().len > 0);
    }

    // A provider with no ladder at all: a tier pin is a no-op, not a crash.
    const xai: Provider = .{ .id = "xai", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "grok-4.3", .context = 256_000 };
    try std.testing.expectEqual(pin_mod.Outcome.no_ladder, pin_mod.forSpawn(xai, obj(a, "{\"tier\":\"small\"}")).outcome);
    // A ladder without that rung (deepseek has no `small`) — never rounds to
    // the nearest rung.
    const deepseek: Provider = .{ .id = "deepseek", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "deepseek-v4-pro", .context = 128_000 };
    try std.testing.expectEqual(pin_mod.Outcome.no_rung, pin_mod.forSpawn(deepseek, obj(a, "{\"tier\":\"small\"}")).outcome);
    try std.testing.expectEqualStrings("deepseek-v4-flash", pin_mod.forSpawn(deepseek, obj(a, "{\"tier\":\"mid\"}")).provider.?.model);
}

test "a pin never crosses a provider boundary" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Whatever the base provider is, the answer is that same provider — the
    // cross-provider decision stays with --subagent-provider and its consent
    // flag, which resolved `base` before a pin was ever consulted.
    const bases = [_]Provider{
        codexBase(),
        .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "k", .model = "claude-opus-4-8", .context = 200_000 },
        .{ .id = "deepseek", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "deepseek-v4-pro", .context = 128_000 },
    };
    for (bases) |base| {
        for ([_][]const u8{ "{\"tier\":\"mid\"}", "{\"tier\":\"small\"}", "{\"model\":\"gpt-5.6-luna\"}", "{\"model\":\"claude-haiku-4-5\"}" }) |args| {
            const got = pin_mod.forSpawn(base, obj(a, args));
            const p = got.provider orelse continue;
            try std.testing.expectEqualStrings(base.id, p.id);
            try std.testing.expectEqualStrings(base.api_key, p.api_key);
        }
    }
}

test "promotion carries a persona's model/tier policy, and it round-trips" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const saved = fleet.g_agent_types;
    defer fleet.g_agent_types = saved;
    fleet.g_agent_types = &.{
        .{ .name = "worker", .desc = "", .prompt = "old genome", .isolation = .worktree, .tier = .mid },
        .{ .name = "exact", .desc = "", .prompt = "old genome", .model = "gpt-5.6-luna" },
        .{ .name = "bare", .desc = "", .prompt = "old genome" },
    };

    // A persona with no policy contributes no lines at all (the frontmatter
    // promoteAgents wrote before #292 is byte-identical for these).
    try std.testing.expectEqualStrings("", pin_mod.personaPolicyFrontmatter(a, "bare"));
    try std.testing.expectEqualStrings("", pin_mod.personaPolicyFrontmatter(a, "not-a-persona"));

    const policy = pin_mod.personaPolicyFrontmatter(a, "worker");
    try std.testing.expectEqualStrings("isolation: worktree\ntier: mid\n", policy);
    try std.testing.expectEqualStrings("model: gpt-5.6-luna\n", pin_mod.personaPolicyFrontmatter(a, "exact"));

    // The emitted lines are exactly what the loader parses back — spliced
    // into a promoted file, `tier: mid` must survive as Tier.mid, so a
    // promote does not silently un-pin the niche it just rewrote.
    const promoted = try std.fmt.allocPrint(a, "---\nname: worker\nscore: 0.9\n{s}---\nnew genome\n", .{policy});
    var round_tripped: ?Tier = null;
    var round_iso: ?fleet.Isolation = null;
    var lines = std.mem.tokenizeScalar(u8, promoted, '\n');
    while (lines.next()) |ln| {
        const sep = std.mem.indexOfScalar(u8, ln, ':') orelse continue;
        const key = std.mem.trim(u8, ln[0..sep], " \t");
        const val = std.mem.trim(u8, ln[sep + 1 ..], " \t\"");
        if (std.mem.eql(u8, key, "tier")) round_tripped = Tier.parse(val);
        if (std.mem.eql(u8, key, "isolation")) round_iso = fleet.Isolation.parse(val);
    }
    try std.testing.expectEqual(Tier.mid, round_tripped.?);
    try std.testing.expectEqual(fleet.Isolation.worktree, round_iso.?);
}

test "withModel: rebuilds the model-derived fields, keeps the credential (#292)" {
    const base = codexBase();
    const luna = base.withModel("gpt-5.6-luna");
    try std.testing.expectEqualStrings("gpt-5.6-luna", luna.model);
    try std.testing.expectEqualStrings("codex", luna.id);
    try std.testing.expectEqualStrings("k", luna.api_key);
    try std.testing.expectEqual(base.kind, luna.kind);

    // kimi routes anthropic-protocol models to a different wire format and
    // endpoint; withModel must re-derive those, not inherit the old ones.
    const kimi_native: Provider = .{ .id = "kimi", .kind = .openai, .auth = .bearer, .url = provider_mod.kimi_native_url, .api_key = "k", .model = "k3", .context = 256_000 };
    const kimi_anth = kimi_native.withModel("kimi-k3-thinking-turbo");
    if (kimi_anth.kind == .anthropic) {
        try std.testing.expectEqualStrings(provider_mod.kimi_anthropic_url, kimi_anth.url);
        try std.testing.expectEqual(Provider.Auth.x_api_key, kimi_anth.auth);
    }

    // An unknown provider id still yields a usable Provider (no crash), just
    // without a spec to re-derive from.
    const alien: Provider = .{ .id = "not-a-provider", .kind = .openai, .auth = .bearer, .url = "u", .api_key = "k", .model = "m", .context = 1234 };
    try std.testing.expectEqualStrings("m2", alien.withModel("m2").model);
    try std.testing.expectEqualStrings("u", alien.withModel("m2").url);
}
