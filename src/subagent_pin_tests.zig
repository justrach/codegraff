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
    try std.testing.expectEqualStrings("gpt-5.6-terra", pin_mod.forSpawn(codexBase(), obj(a, "{\"agent\":\"implementer\"}"), true).provider.?.model);
    try std.testing.expectEqualStrings("gpt-5.6-terra", pin_mod.forSpawn(codexBase(), obj(a, "{\"agent\":\"reviewer\"}"), true).provider.?.model);
    try std.testing.expect(pin_mod.forSpawn(codexBase(), obj(a, "{\"agent\":\"typo\"}"), true).provider == null);
    try std.testing.expect(pin_mod.forSpawn(codexBase(), obj(a, "{\"agent\":\"plain\"}"), true).provider == null);
}

test "spawn override resolution: exact name, alias, ladder rung, and no-op" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = codexBase();

    // Exact catalog name.
    const exact = pin_mod.forSpawn(base, obj(a, "{\"model\":\"gpt-5.6-luna\"}"), true);
    try std.testing.expectEqual(pin_mod.Outcome.pinned, exact.outcome);
    try std.testing.expectEqualStrings("gpt-5.6-luna", exact.provider.?.model);
    try std.testing.expectEqualStrings("codex", exact.provider.?.id); // provider-local, always
    try std.testing.expectEqualStrings("k", exact.provider.?.api_key); // same credential
    // The context window is re-derived for the new model, not inherited.
    try std.testing.expect(exact.provider.?.context != 0);

    // Abbreviation: the same resolver --subagent-model uses (unique substring).
    const alias = pin_mod.forSpawn(base, obj(a, "{\"model\":\" 5.6-terra \"}"), true); // whitespace trimmed
    try std.testing.expectEqualStrings("gpt-5.6-terra", alias.provider.?.model);

    // Ladder rung instead of a name.
    const rung = pin_mod.forSpawn(base, obj(a, "{\"tier\":\"small\"}"), true);
    try std.testing.expectEqual(pin_mod.Outcome.pinned, rung.outcome);
    try std.testing.expectEqualStrings("gpt-5.6-luna", rung.provider.?.model);
    try std.testing.expectEqualStrings("gpt-5.6-terra", pin_mod.forSpawn(base, obj(a, "{\"tier\":\"mid\"}"), true).provider.?.model);

    // A pin naming the model the child already has changes nothing, and says so.
    const same = pin_mod.forSpawn(base, obj(a, "{\"tier\":\"frontier\"}"), true);
    try std.testing.expectEqual(pin_mod.Outcome.same, same.outcome);
    try std.testing.expect(same.provider == null);

    // No pin at all: untouched, and cheap — nothing is resolved.
    const none = pin_mod.forSpawn(base, obj(a, "{\"description\":\"x\",\"prompt\":\"y\"}"), true);
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
        pin_mod.forSpawn(session_default, obj(a, "{\"agent\":\"pinned-frontier\",\"tier\":\"small\"}"), true).provider.?.model,
    );
    try std.testing.expectEqualStrings(
        "gpt-5.6-sol",
        pin_mod.forSpawn(session_default, obj(a, "{\"agent\":\"pinned-mid\",\"model\":\"gpt-5.6-sol\"}"), true).provider.?.model,
    );
    // 2. No spawn param → the persona's pin applies over the session default.
    try std.testing.expectEqualStrings(
        "gpt-5.6-sol",
        pin_mod.forSpawn(session_default, obj(a, "{\"agent\":\"pinned-frontier\"}"), true).provider.?.model,
    );
    // 3. Neither → the session default is kept untouched.
    try std.testing.expect(pin_mod.forSpawn(session_default, obj(a, "{\"prompt\":\"y\"}"), true).provider == null);
    // Within one level, an exact model beats a tier (both on the call…
    try std.testing.expectEqualStrings(
        "gpt-5.6-sol",
        pin_mod.forSpawn(session_default, obj(a, "{\"model\":\"gpt-5.6-sol\",\"tier\":\"small\"}"), true).provider.?.model,
    );
    // …and both on the persona).
    try std.testing.expectEqual(pin_mod.Outcome.same, pin_mod.forSpawn(session_default, obj(a, "{\"agent\":\"both\"}"), true).outcome);
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
        const got = pin_mod.forSpawn(base, obj(a, case.args), true);
        try std.testing.expectEqual(case.want, got.outcome);
        try std.testing.expect(got.provider == null); // the spawn still runs
        // Every non-honored outcome carries a reason for the trace.
        if (case.want != .none) try std.testing.expect(got.outcome.describe().len > 0);
    }

    // A provider with no ladder at all: a tier pin is a no-op, not a crash.
    const xai: Provider = .{ .id = "xai", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "grok-4.3", .context = 256_000 };
    try std.testing.expectEqual(pin_mod.Outcome.no_ladder, pin_mod.forSpawn(xai, obj(a, "{\"tier\":\"small\"}"), true).outcome);
    // A ladder without that rung (deepseek has no mid) — never rounds to
    // the nearest rung.
    const deepseek: Provider = .{ .id = "deepseek", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "deepseek-v4-flash", .context = 128_000 };
    try std.testing.expectEqual(pin_mod.Outcome.no_rung, pin_mod.forSpawn(deepseek, obj(a, "{\"tier\":\"mid\"}"), true).outcome);
    const opus: Provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "k", .model = "claude-opus-5", .context = 1_000_000 };
    try std.testing.expectEqual(pin_mod.Outcome.no_rung, pin_mod.forSpawn(opus, obj(a, "{\"tier\":\"mid\"}"), true).outcome);
    try std.testing.expectEqualStrings("claude-sonnet-5", pin_mod.forSpawn(opus, obj(a, "{\"tier\":\"small\"}"), true).provider.?.model);
}

test "cost ceiling: a tier rung may descend price but never raise it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // anthropic's compiled ladder: frontier claude-opus-5 ($5/25), small
    // claude-sonnet-5 ($2/10). Descending is fine…
    const opus: Provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "k", .model = "claude-opus-5", .context = 1_000_000 };
    try std.testing.expectEqualStrings("claude-sonnet-5", pin_mod.forSpawn(opus, obj(a, "{\"tier\":\"small\"}"), true).provider.?.model);
    // …but a sonnet-5 root asking for the frontier rung would RAISE cost —
    // blocked with a reason, spawn keeps the session default. Naming the
    // model explicitly still escalates: that is the visible, consented path.
    const sonnet: Provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "k", .model = "claude-sonnet-5", .context = 1_000_000 };
    const blocked = pin_mod.forSpawn(sonnet, obj(a, "{\"tier\":\"frontier\"}"), true);
    try std.testing.expectEqual(pin_mod.Outcome.rung_pricier, blocked.outcome);
    try std.testing.expect(blocked.provider == null);
    try std.testing.expect(blocked.outcome.describe().len > 0);
    try std.testing.expectEqualStrings("claude-opus-5", pin_mod.forSpawn(sonnet, obj(a, "{\"model\":\"claude-opus-5\"}"), true).provider.?.model);
    // The affordability rule itself: unpriced base has no ceiling; a priced
    // base blocks an unpriced rung (it cannot prove it is not an escalation).
    try std.testing.expect(pin_mod.rungAffordable("model-with-no-price-anywhere", "deepseek-v4-pro"));
    try std.testing.expect(!pin_mod.rungAffordable("deepseek-v4-flash", "model-with-no-price-anywhere"));
}

test "sub-first routing: a logged-in flat-rate sub outranks metered for explicit tier asks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bench = @import("bench_priors.zig");
    const saved = bench.g_keys;
    defer bench.g_keys = saved;
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    for (provider_mod.provider_specs, 0..) |spec, i| {
        if (std.mem.eql(u8, spec.id, "codex")) keys.values[i] = "tok";
    }
    bench.g_keys = &keys;
    // A DeepSeek session asking tier:"small" stays on DeepSeek flash even
    // when Codex is logged in — luna is the worse seat, not a free upgrade.
    const dsv: Provider = .{ .id = "deepseek", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "deepseek-v4-pro", .context = 128_000 };
    const routed = pin_mod.forSpawn(dsv, obj(a, "{\"tier\":\"small\"}"), true);
    try std.testing.expectEqual(pin_mod.Outcome.pinned, routed.outcome);
    try std.testing.expectEqualStrings("deepseek", routed.provider.?.id);
    try std.testing.expectEqualStrings("deepseek-v4-flash", routed.provider.?.model);
    // An explicit --subagent-provider (sub_ok=false) is a human choice no
    // auto-route may override: the provider-local flash rung still applies.
    const local = pin_mod.forSpawn(dsv, obj(a, "{\"tier\":\"small\"}"), false);
    try std.testing.expectEqual(pin_mod.Outcome.pinned, local.outcome);
    try std.testing.expectEqualStrings("deepseek-v4-flash", local.provider.?.model);
    // Exact model pins: provider-local first, but a name the child's provider
    // does not serve falls through to a logged-in sub that serves it exactly
    // — the same standing consent as the tier path, rescuing a pin that used
    // to silently no-op.
    const mrouted = pin_mod.forSpawn(dsv, obj(a, "{\"model\":\"gpt-5.6-luna\"}"), true);
    try std.testing.expectEqual(pin_mod.Outcome.model_sub_routed, mrouted.outcome);
    try std.testing.expectEqualStrings("codex", mrouted.provider.?.id);
    try std.testing.expectEqualStrings("gpt-5.6-luna", mrouted.provider.?.model);
    try std.testing.expect(mrouted.outcome.describe().len > 0);
    // …under the identical gates: an explicit --subagent-provider
    // (sub_ok=false) forbids the hop…
    try std.testing.expectEqual(pin_mod.Outcome.unknown_model, pin_mod.forSpawn(dsv, obj(a, "{\"model\":\"gpt-5.6-luna\"}"), false).outcome);
    // …and the match is strictly exact/alias — a substring must NOT cross a
    // provider boundary to find a model the pin did not name.
    try std.testing.expectEqual(pin_mod.Outcome.unknown_model, pin_mod.forSpawn(dsv, obj(a, "{\"model\":\"luna\"}"), true).outcome);
    // No login (g_keys null) → no subscription hop; DeepSeek still has a
    // local flash rung. An exact luna pin with no login stays unknown.
    bench.g_keys = null;
    const nologin = pin_mod.forSpawn(dsv, obj(a, "{\"tier\":\"small\"}"), true);
    try std.testing.expectEqual(pin_mod.Outcome.pinned, nologin.outcome);
    try std.testing.expectEqualStrings("deepseek-v4-flash", nologin.provider.?.model);
    try std.testing.expectEqual(pin_mod.Outcome.unknown_model, pin_mod.forSpawn(dsv, obj(a, "{\"model\":\"gpt-5.6-luna\"}"), true).outcome);

    // Same family through a codegraff login: stay on gateway flash, not luna.
    bench.g_keys = &keys;
    const cg: Provider = .{ .id = "codegraff", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "deepseek-v4-pro", .context = 1_000_000 };
    const cg_small = pin_mod.forSpawn(cg, obj(a, "{\"tier\":\"small\"}"), true);
    try std.testing.expectEqual(pin_mod.Outcome.pinned, cg_small.outcome);
    try std.testing.expectEqualStrings("codegraff", cg_small.provider.?.id);
    try std.testing.expectEqualStrings("deepseek-v4-flash", cg_small.provider.?.model);
}

test "exact pin: the child's own provider wins over a logged-in sub serving the same name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bench = @import("bench_priors.zig");
    const saved = bench.g_keys;
    defer bench.g_keys = saved;
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    for (provider_mod.provider_specs, 0..) |spec, i| {
        if (std.mem.eql(u8, spec.id, "codex")) keys.values[i] = "tok";
    }
    bench.g_keys = &keys;
    // openai's own catalog serves gpt-5.6-luna — the pin resolves locally
    // (.pinned), never hopping to the codex sub that serves the same name:
    // a locally-served pin crosses no boundary and moves no billing.
    const oai: Provider = .{ .id = "openai", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "gpt-5.6", .context = 1_050_000 };
    const got = pin_mod.forSpawn(oai, obj(a, "{\"model\":\"gpt-5.6-luna\"}"), true);
    try std.testing.expectEqual(pin_mod.Outcome.pinned, got.outcome);
    try std.testing.expectEqualStrings("openai", got.provider.?.id);
    try std.testing.expectEqualStrings("gpt-5.6-luna", got.provider.?.model);
}

test "two logins split the tiers: k3 is mid, luna is the mechanical rung (#471)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bench = @import("bench_priors.zig");
    const saved = bench.g_keys;
    defer bench.g_keys = saved;
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    for (provider_mod.provider_specs, 0..) |spec, i| {
        if (std.mem.eql(u8, spec.id, "kimi") or std.mem.eql(u8, spec.id, "codex")) keys.values[i] = "tok";
    }
    bench.g_keys = &keys;

    // Both plans logged in, metered anthropic root. The three tiers land on
    // three different paid-for seats, and none of them costs a cent extra:
    //   frontier -> codex sol   (73 beats k3's 68 on the bench sheet)
    //   mid      -> kimi k3     (codex has no mid rung; terra is dominated)
    //   small    -> codex luna  (kimi declares no small rung, so k3's higher
    //                            score cannot swallow the mechanical tier —
    //                            code search and greps stay on the cheap seat)
    const claude: Provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "k", .model = "claude-opus-5", .context = 1_000_000 };
    const want = [_]struct { tier: []const u8, pid: []const u8, model: []const u8 }{
        .{ .tier = "frontier", .pid = "codex", .model = "gpt-5.6-sol" },
        .{ .tier = "mid", .pid = "kimi", .model = "k3" },
        .{ .tier = "small", .pid = "codex", .model = "gpt-5.6-luna" },
    };
    for (want) |w| {
        const body = std.fmt.allocPrint(a, "{{\"tier\":\"{s}\"}}", .{w.tier}) catch unreachable;
        const routed = pin_mod.forSpawn(claude, obj(a, body), true);
        try std.testing.expectEqual(pin_mod.Outcome.sub_routed, routed.outcome);
        try std.testing.expectEqualStrings(w.pid, routed.provider.?.id);
        try std.testing.expectEqualStrings(w.model, routed.provider.?.model);
    }

    // The regression this guards: kimi used to have no ladder row at all, so
    // sub-first routing skipped it and tier:"mid" fell through to a METERED
    // anthropic rung — paying for work a logged-in plan already covers.
    // The candidate list is derived from the specs' sub_login declaration.
    var saw_kimi = false;
    for (pin_mod.subscription_providers) |sid| {
        try std.testing.expect(!std.mem.eql(u8, sid, "zai"));
        try std.testing.expect(!std.mem.eql(u8, sid, "codegraff"));
        if (std.mem.eql(u8, sid, "kimi")) saw_kimi = true;
    }
    try std.testing.expect(saw_kimi);
}

test "a kimi root borrows codex's cheap rung: small -> luna when it is logged in (#471)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bench = @import("bench_priors.zig");
    const sl = bench.g_ladders;
    const sk = bench.g_keys;
    defer {
        bench.g_ladders = sl;
        bench.g_keys = sk;
    }
    // A REAL session's ladders, not the compiled fallbacks: the shipped bench
    // sheet dominates codex's terra out of existence, so codex has no mid rung
    // and kimi's k3 is the only mid seat either plan offers.
    bench.g_ladders = bench.derive(a, &bench.builtin_entries);

    const kimi_root: Provider = .{ .id = "kimi", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "k3", .context = 1_048_576 };
    var both: provider_mod.Keys = .{ .values = @splat(null) };
    for (provider_mod.provider_specs, 0..) |spec, i| {
        if (std.mem.eql(u8, spec.id, "kimi") or std.mem.eql(u8, spec.id, "codex")) both.values[i] = "tok";
    }
    bench.g_keys = &both;

    // The point of sub-first routing seen from the other side: sitting ON the
    // kimi plan, mechanical work still goes to codex's luna, because kimi's
    // plan has no cheap rung and the codex login is already paid for. Neither
    // hop costs a cent, so crossing is free — and the login IS the consent.
    const small = pin_mod.forSpawn(kimi_root, obj(a, "{\"tier\":\"small\"}"), true);
    try std.testing.expectEqual(pin_mod.Outcome.sub_routed, small.outcome);
    try std.testing.expectEqualStrings("codex", small.provider.?.id);
    try std.testing.expectEqualStrings("gpt-5.6-luna", small.provider.?.model);

    // Escalating works the same way: sol outscores k3 on the bench sheet.
    const top = pin_mod.forSpawn(kimi_root, obj(a, "{\"tier\":\"frontier\"}"), true);
    try std.testing.expectEqual(pin_mod.Outcome.sub_routed, top.outcome);
    try std.testing.expectEqualStrings("gpt-5.6-sol", top.provider.?.model);

    // …and asking for mid while already seated on the mid model is a no-op,
    // not a pointless re-seat: k3 IS kimi's mid rung.
    try std.testing.expectEqual(pin_mod.Outcome.same, pin_mod.forSpawn(kimi_root, obj(a, "{\"tier\":\"mid\"}"), true).outcome);

    // Kimi alone: nothing to borrow, so the cheap tier has no rung and the
    // spawn keeps the session default rather than silently escalating to k3.
    var solo: provider_mod.Keys = .{ .values = @splat(null) };
    for (provider_mod.provider_specs, 0..) |spec, i| {
        if (std.mem.eql(u8, spec.id, "kimi")) solo.values[i] = "tok";
    }
    bench.g_keys = &solo;
    try std.testing.expectEqual(pin_mod.Outcome.no_rung, pin_mod.forSpawn(kimi_root, obj(a, "{\"tier\":\"small\"}"), true).outcome);
    try std.testing.expectEqual(pin_mod.Outcome.same, pin_mod.forSpawn(kimi_root, obj(a, "{\"tier\":\"frontier\"}"), true).outcome);
}

test "without a login, a pin never crosses a provider boundary" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Self-sufficient about login state: sub-first/model sub routing only
    // ever crosses to a LOGGED-IN flat-rate sub, so with g_keys null every
    // pin answer stays on the base provider. The metered cross-provider
    // decision stays with --subagent-provider and its consent flag, which
    // resolved `base` before a pin was ever consulted.
    const bench = @import("bench_priors.zig");
    const saved = bench.g_keys;
    defer bench.g_keys = saved;
    bench.g_keys = null;
    const bases = [_]Provider{
        codexBase(),
        .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "k", .model = "claude-opus-4-8", .context = 200_000 },
        .{ .id = "deepseek", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "deepseek-v4-pro", .context = 128_000 },
    };
    for (bases) |base| {
        for ([_][]const u8{ "{\"tier\":\"mid\"}", "{\"tier\":\"small\"}", "{\"model\":\"gpt-5.6-luna\"}", "{\"model\":\"claude-haiku-4-5\"}" }) |args| {
            const got = pin_mod.forSpawn(base, obj(a, args), true);
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
        .{ .name = "luna-max", .desc = "", .prompt = "old genome", .model = "gpt-5.6-luna", .effort = .max },
        .{ .name = "bare", .desc = "", .prompt = "old genome" },
    };

    // A persona with no policy contributes no lines at all (the frontmatter
    // promoteAgents wrote before #292 is byte-identical for these).
    try std.testing.expectEqualStrings("", pin_mod.personaPolicyFrontmatter(a, "bare"));
    try std.testing.expectEqualStrings("", pin_mod.personaPolicyFrontmatter(a, "not-a-persona"));

    const policy = pin_mod.personaPolicyFrontmatter(a, "worker");
    try std.testing.expectEqualStrings("isolation: worktree\ntier: mid\n", policy);
    try std.testing.expectEqualStrings("model: gpt-5.6-luna\n", pin_mod.personaPolicyFrontmatter(a, "exact"));
    // #292 follow-up: the effort pin is policy too — promote must not un-pin
    // it, and the emitted line round-trips through the loader's parse.
    try std.testing.expectEqualStrings("model: gpt-5.6-luna\neffort: max\n", pin_mod.personaPolicyFrontmatter(a, "luna-max"));
    var round_eff: ?pin_mod.Effort = null;
    var eff_lines = std.mem.tokenizeScalar(u8, pin_mod.personaPolicyFrontmatter(a, "luna-max"), '\n');
    while (eff_lines.next()) |ln| {
        const sep = std.mem.indexOfScalar(u8, ln, ':') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, ln[0..sep], " \t"), "effort")) round_eff = pin_mod.parseEffort(std.mem.trim(u8, ln[sep + 1 ..], " \t\""));
    }
    try std.testing.expectEqual(pin_mod.Effort.max, round_eff.?);

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

test "effort pin: spawn param, persona frontmatter, and axis independence (#292 follow-up)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = codexBase();

    const saved = fleet.g_agent_types;
    defer fleet.g_agent_types = saved;
    fleet.g_agent_types = &.{
        // The tweet-shaped persona: an exact model AND a depth — "Luna Max".
        .{ .name = "luna-worker", .desc = "", .prompt = "x", .model = "gpt-5.6-luna", .effort = .max },
        .{ .name = "thinker", .desc = "", .prompt = "x", .effort = .xhigh },
    };

    // Persona effort reaches a spawn that only names the persona, riding
    // alongside the persona's model pin.
    const luna = pin_mod.forSpawn(base, obj(a, "{\"agent\":\"luna-worker\"}"), true);
    try std.testing.expectEqualStrings("gpt-5.6-luna", luna.provider.?.model);
    try std.testing.expectEqual(pin_mod.Effort.max, luna.effort.?);
    try std.testing.expectEqual(pin_mod.EffortOutcome.pinned, luna.effort_outcome);

    // A spawn's effort beats the persona's, in BOTH directions.
    try std.testing.expectEqual(pin_mod.Effort.low, pin_mod.forSpawn(base, obj(a, "{\"agent\":\"thinker\",\"effort\":\"low\"}"), true).effort.?);
    try std.testing.expectEqual(pin_mod.Effort.max, pin_mod.forSpawn(base, obj(a, "{\"agent\":\"thinker\",\"effort\":\"max\"}"), true).effort.?);

    // AXIS INDEPENDENCE — an effort-only call keeps the persona's model pin…
    const eff_only = pin_mod.forSpawn(base, obj(a, "{\"agent\":\"luna-worker\",\"effort\":\"high\"}"), true);
    try std.testing.expectEqualStrings("gpt-5.6-luna", eff_only.provider.?.model);
    try std.testing.expectEqual(pin_mod.Effort.high, eff_only.effort.?);
    // …and a model-only call keeps the persona's effort.
    const mdl_only = pin_mod.forSpawn(base, obj(a, "{\"agent\":\"luna-worker\",\"model\":\"gpt-5.6-terra\"}"), true);
    try std.testing.expectEqualStrings("gpt-5.6-terra", mdl_only.provider.?.model);
    try std.testing.expectEqual(pin_mod.Effort.max, mdl_only.effort.?);

    // An effort pin alone never touches the model: provider stays null.
    const bare = pin_mod.forSpawn(base, obj(a, "{\"effort\":\"xhigh\"}"), true);
    try std.testing.expect(bare.provider == null);
    try std.testing.expectEqual(pin_mod.Outcome.none, bare.outcome);
    try std.testing.expectEqual(pin_mod.Effort.xhigh, bare.effort.?);
}

test "effort pin: off-vocabulary (incl. ultra) is reported and never guessed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = codexBase();

    // `ultra` is /effort's ultracode prompt switch, not a worker depth — a
    // persona/spawn cannot pin it; the vocabulary is case-exact like tier's.
    for ([_][]const u8{ "{\"effort\":\"ultra\"}", "{\"effort\":\"Max\"}", "{\"effort\":\"extreme\"}" }) |args| {
        const got = pin_mod.forSpawn(base, obj(a, args), true);
        try std.testing.expectEqual(pin_mod.EffortOutcome.unknown_effort, got.effort_outcome);
        try std.testing.expect(got.effort == null); // the spawn still runs, at the default
        try std.testing.expect(got.effort_outcome.describe().len > 0);
    }

    // A stated typo does NOT fall through to the persona's effort — the
    // caller was overriding, and a silent substitution would hide the typo.
    const saved = fleet.g_agent_types;
    defer fleet.g_agent_types = saved;
    fleet.g_agent_types = &.{.{ .name = "thinker", .desc = "", .prompt = "x", .effort = .xhigh }};
    const typo = pin_mod.forSpawn(base, obj(a, "{\"agent\":\"thinker\",\"effort\":\"woops\"}"), true);
    try std.testing.expect(typo.effort == null);
    try std.testing.expectEqual(pin_mod.EffortOutcome.unknown_effort, typo.effort_outcome);

    // Non-string / blank values are simply not a pin.
    try std.testing.expectEqual(pin_mod.EffortOutcome.none, pin_mod.forSpawn(base, obj(a, "{\"effort\":42}"), true).effort_outcome);
    try std.testing.expectEqual(pin_mod.EffortOutcome.none, pin_mod.forSpawn(base, obj(a, "{\"effort\":\"  \"}"), true).effort_outcome);

    // The parse contract loadAgentDir relies on.
    try std.testing.expectEqual(pin_mod.Effort.max, pin_mod.parseEffort("max").?);
    try std.testing.expectEqual(pin_mod.Effort.xhigh, pin_mod.parseEffort("xhigh").?);
    try std.testing.expect(pin_mod.parseEffort("ultra") == null);
    try std.testing.expect(pin_mod.parseEffort("") == null);
}
