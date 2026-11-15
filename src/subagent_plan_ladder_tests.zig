//! Dual-frontier Claude routing (opus-5-5 / fable-5-2 + separate quota pool),
//! xAI grok-4.7-only ladder, chatgpt-new ladder, dynamic live-catalog fallback,
//! and metered-vs-plan credential gating for sub-first/vision routing.

const std = @import("std");
const Io = std.Io;

const acp = @import("acp.zig");
const engine = @import("acp_engine.zig");
const LiveTurn = @import("acp_live_turn.zig").LiveTurn;
const agent_quota = @import("agent_request_quota.zig");
const bench = @import("bench_priors.zig");
const billing = @import("billing.zig");
const claude_agent = @import("claude_agent.zig");
const failover = @import("credential_failover.zig");
const models_table = @import("models_table.zig");
const pricing = @import("pricing.zig");
const provider_mod = @import("provider.zig");
const Provider = provider_mod.Provider;
const route_phase = @import("route_phase.zig");
const route_policy = @import("route_policy.zig");
const scoring = @import("scoring.zig");
const selection = @import("subagent_selection.zig");
const pin_mod = @import("subagent_pin.zig");
const tier_ladder = @import("subagent_tier_ladder.zig");
const vision_ask = @import("vision_ask.zig");

fn obj(a: std.mem.Allocator, json: []const u8) std.json.ObjectMap {
    return (std.json.parseFromSliceLeaky(std.json.Value, a, json, .{ .allocate = .alloc_always }) catch unreachable).object;
}

fn keysFor(entries: []const struct { id: []const u8, val: []const u8, src: provider_mod.Keys.CredentialSource }) provider_mod.Keys {
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    for (entries) |e| _ = keys.set(e.id, e.val, e.src);
    return keys;
}

test "Claude dual frontier (opus-5-5 normal, fable-5-2 at xhigh/max) and metered wallet guard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const saved_keys = bench.g_keys;
    defer bench.g_keys = saved_keys;
    bench.g_keys = null;

    // On a flat-rate subscription login, frontier stays on opus-5-5 for normal
    // tasks and promotes to fable-5-2 for xhigh/max hard tasks.
    for ([_][]const u8{ "anthropic", "claude-agent" }) |pid| {
        const base: Provider = .{ .id = pid, .kind = .anthropic, .auth = .bearer, .url = "", .api_key = "tok", .model = "claude-opus-5-5", .context = 1_000_000, .source = .login };
        try std.testing.expectEqual(pin_mod.Outcome.same, pin_mod.forSpawn(base, obj(a, "{\"tier\":\"frontier\"}"), true).outcome);
        try std.testing.expectEqual(pin_mod.Outcome.same, pin_mod.forSpawn(base, obj(a, "{\"tier\":\"frontier\",\"effort\":\"high\"}"), true).outcome);
        for ([_][]const u8{ "{\"tier\":\"frontier\",\"effort\":\"xhigh\"}", "{\"tier\":\"frontier\",\"effort\":\"max\"}" }) |raw| {
            const hard = pin_mod.forSpawn(base, obj(a, raw), true);
            try std.testing.expectEqual(pin_mod.Outcome.pinned, hard.outcome);
            try std.testing.expectEqualStrings("claude-fable-5-2", hard.provider.?.model);
        }
        try std.testing.expectEqualStrings("claude-sonnet-5-5", pin_mod.forSpawn(base, obj(a, "{\"tier\":\"mid\"}"), true).provider.?.model);
        try std.testing.expectEqualStrings("claude-haiku-5-5", pin_mod.forSpawn(base, obj(a, "{\"tier\":\"small\"}"), true).provider.?.model);
    }

    // Metered opus-5-5 ($4/$20): cost ceiling refuses auto-escalation to Fable ($8/$40),
    // falling back cleanly to opus-5-5 rather than failing the spawn.
    const metered: Provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "sk", .model = "claude-opus-5-5", .context = 1_000_000, .source = .environment };
    try std.testing.expectEqual(pin_mod.Outcome.same, pin_mod.forSpawn(metered, obj(a, "{\"tier\":\"frontier\",\"effort\":\"max\"}"), true).outcome);

    // Search-role phases descend automatic sonnet-5-5 workers to haiku-5-5; both
    // frontier seats map cleanly to .frontier and providerClass == "frontier"/"small".
    const saved_cells = route_policy.g_cells;
    const saved_ladder = selection.g_default_from_ladder;
    defer {
        route_policy.g_cells = saved_cells;
        selection.g_default_from_ladder = saved_ladder;
    }
    route_policy.g_cells = &.{};
    selection.g_default_from_ladder = true;
    const claude_mid: Provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .bearer, .url = "", .api_key = "tok", .model = "claude-sonnet-5-5", .context = 1_000_000, .source = .login };
    try std.testing.expectEqualStrings("claude-haiku-5-5", route_phase.forPhase(claude_mid, .review, "find callers", &.{}, true).provider.model);
    try std.testing.expectEqual(tier_ladder.Tier.frontier, route_policy.tierOf("anthropic", "claude-fable-5-2").?);
    try std.testing.expectEqualStrings("frontier", scoring.providerClass("claude-fable-5-2"));
    try std.testing.expectEqualStrings("small", scoring.providerClass("claude-haiku-5-5"));
}

test "Fable separate quota pool: REPL/ACP identification, intra-plan stepdown, and claude-agent hint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Billing pool classification & picker badges across plan vs metered credentials.
    try std.testing.expectEqual(billing.QuotaPool.separate, billing.quotaPoolFor("anthropic", "claude-fable-5-2", .login));
    try std.testing.expectEqual(billing.QuotaPool.separate, billing.quotaPoolFor("claude-agent", "claude-fable-5-2[1m]", .login));
    try std.testing.expectEqual(billing.QuotaPool.shared, billing.quotaPoolFor("anthropic", "claude-opus-5-5", .login));
    try std.testing.expectEqual(billing.QuotaPool.none, billing.quotaPoolFor("anthropic", "claude-fable-5-2", .environment));
    try std.testing.expectEqualStrings("plan*", billing.seatBadge("anthropic", "claude-fable-5-2", .login));
    try std.testing.expectEqualStrings("plan", billing.seatBadge("anthropic", "claude-opus-5-5", .login));
    try std.testing.expectEqualStrings("api", billing.seatBadge("anthropic", "claude-fable-5-2", .environment));

    // REPL /models renders `plan*` badge cleanly; ACP graff/models exposes `separateQuota: true`.
    const keys = keysFor(&.{.{ .id = "anthropic", .val = "tok", .src = .login }});
    const sample_models = [_]pricing.ModelInfo{
        .{ .provider = "anthropic", .name = "claude-fable-5-2", .context = 1_000_000 },
        .{ .provider = "anthropic", .name = "claude-opus-5-5", .context = 1_000_000 },
    };
    var table_aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer table_aw.deinit();
    try models_table.writeRows(&table_aw.writer, a, &sample_models, keys, "", "", struct {
        fn v(_: []const u8) bool {
            return true;
        }
    }.v);
    try std.testing.expect(std.mem.indexOf(u8, table_aw.writer.buffered(), "plan*") != null);

    var acp_root = try @import("agent_request_body_responses.zig").testAgentFor(a, "anthropic", .anthropic, "claude-opus-5-5");
    var keys_mut = keys;
    var acp_aw: Io.Writer.Allocating = .init(a);
    var live: LiveTurn = .{ .root = &acp_root, .keys = &keys_mut, .out = &acp_aw.writer };
    var d: engine.Dispatch = .{ .turn = struct {
        fn r(_: *anyopaque, al: std.mem.Allocator, t: []const u8) anyerror![]const u8 {
            return al.dupe(u8, t);
        }
    }.r, .ctx = &live, .extra = acp.liveModels };
    try acp.handleLine(&d, a, &acp_aw.writer, "{\"id\":1,\"method\":\"graff/models\"}");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, acp_aw.writer.buffered(), .{});
    var saw_fable = false;
    var saw_opus = false;
    for (parsed.object.get("result").?.object.get("models").?.array.items) |row| {
        const o = row.object;
        if (!std.mem.eql(u8, o.get("provider").?.string, "anthropic")) continue;
        if (std.mem.eql(u8, o.get("name").?.string, "claude-fable-5-2")) {
            saw_fable = true;
            try std.testing.expect(o.get("separateQuota").?.bool);
        } else if (std.mem.eql(u8, o.get("name").?.string, "claude-opus-5-5")) {
            saw_opus = true;
            try std.testing.expect(!o.get("separateQuota").?.bool);
        }
    }
    try std.testing.expect(saw_fable and saw_opus);

    // Intra-plan stepdown: Fable quota cap steps to opus-5-5 WITHOUT burning a parked metered key;
    // a second cap on opus-5-5 then promotes the parked key.
    failover.resetForTest();
    defer failover.resetForTest();
    failover.park("anthropic", "sk-metered-reserve", .environment);
    var agent = try @import("agent_request_body_responses.zig").testAgentFor(a, "anthropic", .anthropic, "claude-fable-5-2");
    agent.provider.source = .login;
    var notice_aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer notice_aw.deinit();
    agent.out = &notice_aw.writer;
    var refreshed = false;
    try std.testing.expect(try agent_quota.handle(&agent, "invalid_request_error", null, "You're out of extra usage.", &refreshed));
    try std.testing.expectEqualStrings("claude-opus-5-5", agent.provider.model);
    try std.testing.expectEqual(provider_mod.Keys.CredentialSource.login, agent.provider.source);
    try std.testing.expect(failover.standingBy("anthropic"));
    try std.testing.expect(std.mem.indexOf(u8, notice_aw.writer.buffered(), "separate plan limit") != null);

    try std.testing.expect(try agent_quota.handle(&agent, "invalid_request_error", null, "You're out of extra usage.", &refreshed));
    try std.testing.expectEqual(provider_mod.Keys.CredentialSource.environment, agent.provider.source);
    try std.testing.expectEqualStrings("sk-metered-reserve", agent.provider.api_key);

    // claude-agent failure copy appends separate-limit hint only on Fable usage limits.
    const hint = try claude_agent.problemForModel(a, "claude-fable-5-2", "You've reached your usage limit");
    try std.testing.expect(std.mem.indexOf(u8, hint, "/model claude-opus-5-5") != null);
    const plain = try claude_agent.problemForModel(a, "claude-opus-5-5", "You've reached your usage limit");
    try std.testing.expect(std.mem.indexOf(u8, plain, "separate plan limit") == null);
}

test "xAI grok-4.7-only ladder, chatgpt-new ladder, and metered-vs-login sub-first guard" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const saved_ladders = bench.g_ladders;
    const saved_keys = bench.g_keys;
    defer {
        bench.g_ladders = saved_ladders;
        bench.g_keys = saved_keys;
    }

    // Even if bench_priors tries to downgrade xAI onto legacy grok-4.6, forProvider stays grok-4.7-only.
    const stale_priors = [_]tier_ladder.TierLadder{
        .{ .provider = "xai", .frontier = "grok-4.6", .mid = "grok-4.3", .small = "grok-build" },
    };
    bench.g_ladders = &stale_priors;
    const xl = tier_ladder.forProvider("xai").?;
    try std.testing.expectEqualStrings("grok-4.7", xl.frontier);
    try std.testing.expectEqualStrings("grok-4.7", xl.mid.?);
    try std.testing.expect(xl.small == null);

    // Solo SuperGrok: frontier/mid stay grok-4.7, small has no local rung.
    var solo_xai = keysFor(&.{.{ .id = "xai", .val = "tok", .src = .login }});
    bench.g_keys = &solo_xai;
    const xai_plan: Provider = .{ .id = "xai", .kind = .openai, .auth = .bearer, .url = "", .api_key = "tok", .model = "grok-4.7", .context = 500_000, .source = .login };
    try std.testing.expectEqual(pin_mod.Outcome.same, pin_mod.forSpawn(xai_plan, obj(a, "{\"tier\":\"mid\"}"), true).outcome);
    try std.testing.expectEqual(pin_mod.Outcome.no_rung, pin_mod.forSpawn(xai_plan, obj(a, "{\"tier\":\"small\"}"), true).outcome);

    // chatgpt-new mirrors Codex tiers (mid = gpt-6.1-sol) while unpinned GPT-6 roots inherit.
    bench.g_keys = null;
    const cgtn: Provider = .{ .id = "chatgpt-new", .kind = .responses, .auth = .bearer, .url = "", .api_key = "tok", .model = "gpt-6.1-sol", .context = 500_000, .source = .login };
    try std.testing.expectEqualStrings("gpt-6-astra", pin_mod.forSpawn(cgtn, obj(a, "{\"tier\":\"frontier\"}"), true).provider.?.model);
    try std.testing.expectEqual(pin_mod.Outcome.same, pin_mod.forSpawn(cgtn, obj(a, "{\"tier\":\"mid\"}"), true).outcome);
    try std.testing.expectEqualStrings("gpt-6-luna", pin_mod.forSpawn(cgtn, obj(a, "{\"tier\":\"small\"}"), true).provider.?.model);

    // When chatgpt-new is also signed in, SuperGrok borrows chatgpt-new's small rung (gpt-6-luna),
    // while chatgpt-new keeps its own frontier/mid seats rather than being hijacked by xAI's grok-4.7.
    var with_gpt = keysFor(&.{
        .{ .id = "xai", .val = "tok", .src = .login },
        .{ .id = "chatgpt-new", .val = "tok2", .src = .login },
    });
    bench.g_keys = &with_gpt;
    const borrowed = pin_mod.forSpawn(xai_plan, obj(a, "{\"tier\":\"small\"}"), true);
    try std.testing.expectEqual(pin_mod.Outcome.sub_routed, borrowed.outcome);
    try std.testing.expectEqualStrings("chatgpt-new", borrowed.provider.?.id);
    try std.testing.expectEqualStrings("gpt-6-luna", borrowed.provider.?.model);
    const stay_cgtn = pin_mod.forSpawn(cgtn, obj(a, "{\"tier\":\"frontier\"}"), true);
    try std.testing.expectEqual(pin_mod.Outcome.pinned, stay_cgtn.outcome);
    try std.testing.expectEqualStrings("chatgpt-new", stay_cgtn.provider.?.id);
    try std.testing.expectEqualStrings("gpt-6-astra", stay_cgtn.provider.?.model);
    try std.testing.expectEqual(pin_mod.Outcome.same, pin_mod.forSpawn(cgtn, obj(a, "{\"tier\":\"mid\"}"), true).outcome);

    // Metered XAI_API_KEY and ANTHROPIC_API_KEY (.environment) must NOT be treated as flat-rate
    // subscriptions by subagent_pin or vision_ask; only `.login` qualifies. Use a non-deepseek
    // metered base (groq has no ladder and no vision) so subscriptionRung/visionSeat are actually consulted.
    var metered_keys = keysFor(&.{
        .{ .id = "xai", .val = "xai-key", .src = .environment },
        .{ .id = "anthropic", .val = "ant-key", .src = .environment },
    });
    bench.g_keys = &metered_keys;
    const groq_base: Provider = .{ .id = "groq", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "openai/gpt-oss-120b", .context = 131_072, .source = .environment };
    try std.testing.expectEqual(pin_mod.Outcome.no_ladder, pin_mod.forSpawn(groq_base, obj(a, "{\"tier\":\"mid\"}"), true).outcome);
    try std.testing.expectEqual(pin_mod.Outcome.unknown_model, pin_mod.forSpawn(groq_base, obj(a, "{\"model\":\"grok-4.7\"}"), true).outcome);
    try std.testing.expect(vision_ask.visionSeat(groq_base) == null);

    var login_keys = keysFor(&.{.{ .id = "anthropic", .val = "ant-oauth", .src = .login }});
    bench.g_keys = &login_keys;
    const hard_sub = pin_mod.forSpawn(groq_base, obj(a, "{\"tier\":\"frontier\",\"effort\":\"max\"}"), true);
    try std.testing.expectEqual(pin_mod.Outcome.sub_routed, hard_sub.outcome);
    try std.testing.expectEqualStrings("anthropic", hard_sub.provider.?.id);
    try std.testing.expectEqualStrings("claude-fable-5-2", hard_sub.provider.?.model);
    const vseat = vision_ask.visionSeat(groq_base).?;
    try std.testing.expectEqualStrings("anthropic", vseat.id);
    try std.testing.expectEqualStrings("claude-haiku-5-5", vseat.model);
}

test "dynamic live-catalog ladder fallback follows rotated Claude/GPT families, never xAI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const saved_table = pricing.active_model_table;
    const saved_keys = bench.g_keys;
    defer {
        pricing.active_model_table = saved_table;
        bench.g_keys = saved_keys;
    }
    bench.g_keys = null;

    try std.testing.expect(pricing.activateProviderModels(a, "anthropic", &.{
        .{ .provider = "anthropic", .name = "claude-opus-5-6", .context = 1_000_000 },
        .{ .provider = "anthropic", .name = "claude-fable-5-3", .context = 1_000_000 },
        .{ .provider = "anthropic", .name = "claude-sonnet-5-6", .context = 1_000_000 },
        .{ .provider = "anthropic", .name = "claude-haiku-5-6", .context = 1_000_000 },
    }));
    try std.testing.expect(pricing.activateProviderModels(a, "codex", &.{
        .{ .provider = "codex", .name = "gpt-6.2-astra", .context = 272_000 },
        .{ .provider = "codex", .name = "gpt-6.2-sol", .context = 272_000 },
        .{ .provider = "codex", .name = "gpt-6.2-luna", .context = 272_000 },
    }));
    try std.testing.expect(pricing.activateProviderModels(a, "xai", &.{
        .{ .provider = "xai", .name = "grok-4.6", .context = 500_000 },
    }));

    const ant_plan: Provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .bearer, .url = "", .api_key = "tok", .model = "claude-opus-5-6", .context = 1_000_000, .source = .login };
    try std.testing.expectEqualStrings("claude-sonnet-5-6", pin_mod.forSpawn(ant_plan, obj(a, "{\"tier\":\"mid\"}"), true).provider.?.model);
    try std.testing.expectEqualStrings("claude-haiku-5-6", pin_mod.forSpawn(ant_plan, obj(a, "{\"tier\":\"small\"}"), true).provider.?.model);
    try std.testing.expectEqualStrings("claude-fable-5-3", pin_mod.forSpawn(ant_plan, obj(a, "{\"tier\":\"frontier\",\"effort\":\"max\"}"), true).provider.?.model);
    try std.testing.expectEqual(tier_ladder.Tier.frontier, route_policy.tierOf("anthropic", "claude-fable-5-3").?);

    const codex_plan: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "tok", .model = "gpt-6.2-astra", .context = 272_000, .source = .login };
    try std.testing.expectEqualStrings("gpt-6.2-luna", pin_mod.forSpawn(codex_plan, obj(a, "{\"tier\":\"small\"}"), true).provider.?.model);

    // xAI never substitutes grok-4.6 when grok-4.7 is absent from the catalog.
    try std.testing.expect(selection.liveLadderModel("xai", "grok-4.7") == null);
    const xai_plan: Provider = .{ .id = "xai", .kind = .openai, .auth = .bearer, .url = "", .api_key = "tok", .model = "grok-4.7", .context = 500_000, .source = .login };
    try std.testing.expectEqual(pin_mod.Outcome.unknown_model, pin_mod.forSpawn(xai_plan, obj(a, "{\"tier\":\"frontier\"}"), true).outcome);
}

test "live rate-limit rejection on Fable proactively steps subagent_pin hard_frontier to opus-5-5" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const saved_table = pricing.active_model_table;
    const saved_keys = bench.g_keys;
    defer {
        pricing.active_model_table = saved_table;
        bench.g_keys = saved_keys;
    }
    pricing.active_model_table = pricing.model_table[0..];
    bench.g_keys = null;

    const live_usage = @import("plan_usage_live.zig");
    live_usage.resetForTest();
    defer live_usage.resetForTest();

    const ant_plan: Provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .bearer, .url = "", .api_key = "tok", .model = "claude-opus-5-5", .context = 1_000_000, .source = .login };
    try std.testing.expectEqualStrings("claude-fable-5-2", pin_mod.forSpawn(ant_plan, obj(a, "{\"tier\":\"frontier\",\"effort\":\"max\"}"), true).provider.?.model);

    live_usage.noteHeaderList(std.testing.io, "anthropic", "claude-fable-5-2", 429, &.{
        .{ .name = "anthropic-ratelimit-unified-status", .value = "rejected" },
        .{ .name = "anthropic-ratelimit-unified-representative-claim", .value = "fable" },
    });
    const stepped = pin_mod.forSpawn(ant_plan, obj(a, "{\"tier\":\"frontier\",\"effort\":\"max\"}"), true);
    try std.testing.expectEqual(pin_mod.Outcome.same, stepped.outcome);
    try std.testing.expectEqualStrings("claude-opus-5-5", (stepped.provider orelse ant_plan).model);

    const ant_sonnet = ant_plan.withModel("claude-sonnet-5-5");
    const stepped_pinned = pin_mod.forSpawn(ant_sonnet, obj(a, "{\"tier\":\"frontier\",\"effort\":\"max\"}"), true);
    try std.testing.expectEqual(pin_mod.Outcome.pinned, stepped_pinned.outcome);
    try std.testing.expectEqualStrings("claude-opus-5-5", stepped_pinned.provider.?.model);

    // Same proactive stepdown on claude-agent after rate_limit_event rejection.
    live_usage.noteClaudeRateLimit(std.testing.io, "claude-fable-5-2", .{ .status = "rejected", .rate_limit_type = "fable", .utilization = 1.0, .overage_status = "rejected" });
    var ca_keys = keysFor(&.{.{ .id = "claude-agent", .val = "claude-agent", .src = .login }});
    bench.g_keys = &ca_keys;
    const groq_base: Provider = .{ .id = "groq", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "openai/gpt-oss-120b", .context = 131_072, .source = .environment };
    const sub_ca = pin_mod.forSpawn(groq_base, obj(a, "{\"tier\":\"frontier\",\"effort\":\"max\"}"), true);
    try std.testing.expectEqualStrings("claude-agent", sub_ca.provider.?.id);
    try std.testing.expectEqualStrings("claude-opus-5-5", sub_ca.provider.?.model);
}
