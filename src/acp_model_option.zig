//! The `model` config option for T3 Code's model picker (acp_t3.zig): the
//! models this install can reach, in the `graff/models` election order.
//! Values are `<provider>/<model>`; choosing one runs `/model <provider> <model>`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const engine = @import("acp_engine.zig");
const pricing = @import("pricing.zig");
const billing = @import("billing.zig");
const models_rank = @import("models_rank");
const LiveTurn = @import("acp_live_turn.zig").LiveTurn;

/// Whether two option lists offer and select the same values.
pub fn same(before: []const engine.ConfigOption, after: []const engine.ConfigOption) bool {
    if (before.len != after.len) return false;
    for (before, after) |a, b| {
        if (!std.mem.eql(u8, a.currentValue, b.currentValue) or a.options.len != b.options.len) return false;
        for (a.options, b.options) |av, bv| if (!std.mem.eql(u8, av.value, bv.value)) return false;
    }
    return true;
}

/// T3 shows at most 64 choices per option.
const max_choices = 48;

/// Local catalog state only: stored keys, cached provider lists. No network.
pub fn hydrate(live: *LiveTurn) void {
    const root = live.root;
    root.ensureStoredKeys(live.keys);
    if (root.model_catalog) |*cached|
        cached.ensureCached(root.io, root.gpa, root.arena, root.home, live.keys.get("codex") orelse "", live.keys.codex_account);
    if (!live.local_catalog_loaded) {
        if (root.home.len > 0) @import("router_catalog.zig").loadCachedAll(root.io, root.arena, root.home);
        live.local_catalog_loaded = true;
    }
    // A catalog boot detached with no cache may have landed since this
    // session's first beat: activate it here, as the REPL picker does at its
    // `ensureForQuery` beat (ADR 0340). One atomic load per slot when nothing
    // landed; never a fetch.
    @import("router_catalog_boot.zig").activateLanded(root.io, root.arena, root.home);
}

pub const Choice = struct { provider: []const u8, model: []const u8 };

/// Reachable models, best first, with the current one always present.
pub fn choices(arena: Allocator, catalog: []const pricing.ModelInfo, keys: anytype, current: Choice) ![]const Choice {
    const ranked = try arena.alloc(models_rank.Scored, catalog.len);
    for (catalog, 0..) |m, i| ranked[i] = .{
        .idx = i,
        .score = models_rank.electionRank(keys.get(m.provider) != null, billing.costFor(m.provider, keys.source(m.provider))),
    };
    @import("stable_sort.zig").sort(models_rank.Scored, ranked, {}, models_rank.scoredLess);
    var out: std.ArrayList(Choice) = .empty;
    try out.append(arena, current);
    for (ranked) |r| {
        if (out.items.len == max_choices) break;
        const m = catalog[r.idx];
        if (keys.get(m.provider) == null) continue;
        if (std.mem.eql(u8, m.provider, current.provider) and std.mem.eql(u8, m.name, current.model)) continue;
        try out.append(arena, .{ .provider = m.provider, .model = m.name });
    }
    return out.items;
}

pub fn option(ctx: *anyopaque, arena: Allocator) anyerror!?engine.ConfigOption {
    if (!@import("acp_t3.zig").active()) return null;
    const live: *LiveTurn = @ptrCast(@alignCast(ctx));
    hydrate(live);
    const root = live.root;
    const list = try choices(arena, pricing.models(), live.keys, .{ .provider = root.provider.id, .model = root.provider.model });
    const values = try arena.alloc(engine.ConfigValue, list.len);
    for (list, values) |c, *v| v.* = .{
        .value = try std.fmt.allocPrint(arena, "{s}/{s}", .{ c.provider, c.model }),
        .name = try std.fmt.allocPrint(arena, "{s} · {s}", .{ c.model, c.provider }),
    };
    return .{ .id = "model", .name = "Model", .category = "model", .currentValue = values[0].value, .options = values };
}

pub fn set(ctx: *anyopaque, value: []const u8) anyerror!bool {
    if (!@import("acp_t3.zig").active()) return false;
    const live: *LiveTurn = @ptrCast(@alignCast(ctx));
    const root = live.root;
    const cut = std.mem.indexOfScalar(u8, value, '/') orelse return false;
    const provider = value[0..cut];
    const model = value[cut + 1 ..];
    if (provider.len == 0 or model.len == 0 or std.mem.indexOfAny(u8, value, " \t\r\n") != null) return false;
    if (std.mem.eql(u8, provider, root.provider.id) and std.mem.eql(u8, model, root.provider.model)) return true;
    // The switched provider keeps slices of this line: allocate where the agent lives.
    const arena = root.arena;
    var sink: Io.Writer.Allocating = .init(root.gpa);
    defer sink.deinit();
    const line = try std.fmt.allocPrint(arena, "/model {s} {s}", .{ provider, model });
    try @import("main.zig").handleCommand(root, live.keys, arena, line, &sink.writer);
    return std.mem.eql(u8, root.provider.id, provider) and std.mem.eql(u8, root.provider.model, model);
}

test "model choices: reachable models only, current first, capped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Keys = struct {
        fn get(_: @This(), provider: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, provider, "codex") or std.mem.eql(u8, provider, "codegraff")) "k" else null;
        }
        fn source(_: @This(), _: []const u8) @import("provider.zig").Keys.CredentialSource {
            return .login;
        }
    };
    const catalog = [_]pricing.ModelInfo{
        .{ .provider = "anthropic", .name = "opus", .context = 1 },
        .{ .provider = "codex", .name = "gpt-a", .context = 1 },
        .{ .provider = "codegraff", .name = "kimi", .context = 1 },
        .{ .provider = "codex", .name = "gpt-b", .context = 1 },
    };
    const list = try choices(a, &catalog, Keys{}, .{ .provider = "codex", .model = "gpt-b" });
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualStrings("gpt-b", list[0].model);
    for (list) |c| try std.testing.expect(!std.mem.eql(u8, c.provider, "anthropic"));
}

test "hydrate activates a boot-detached catalog that landed after the session's first beat" {
    // ADR 0340: a first-ever ACP session can hydrate before a cold boot's
    // detached catalog fetch lands; the next beat must activate the landed
    // rows, as the REPL picker's `ensureForQuery` beat does.
    const landing = @import("catalog_landing.zig");
    const provider_mod = @import("provider.zig");
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    var root = try @import("agent_request_body_responses.zig").testAgentFor(a, "zai", .openai, "glm-5.3");
    root.home = home;
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    var live: LiveTurn = .{ .root = &root, .keys = &keys, .out = undefined };
    const saved_table = pricing.active_model_table;
    defer pricing.active_model_table = saved_table;
    landing.reset();
    defer landing.reset();

    // First beat on a fresh HOME: nothing on disk yet, the baked rows serve.
    hydrate(&live);
    try std.testing.expect(!pricing.providerModelInTable("zai", "glm-landed-test"));

    // The detached worker lands: its cache is on disk and its slot reports.
    const spec = provider_mod.specFor("zai").?;
    try tmp.dir.createDirPath(io, ".codegraff");
    const document = try std.fmt.allocPrint(a, "{{\"source\":\"{s}\",\"fetched_at_ms\":1,\"models\":[{{\"name\":\"glm-landed-test\"}}]}}\n", .{spec.models_url});
    const path = try std.fmt.allocPrint(a, "{s}/.codegraff/zai-models.json", .{home});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = document });
    const job: @import("catalog_bounded.zig").Job = .{ .router = .{ .spec = spec, .source = .environment } };
    landing.expect(job);
    landing.settle(job, true);

    // The session's next beat activates the landed rows, no /model needed.
    hydrate(&live);
    try std.testing.expect(pricing.providerModelInTable("zai", "glm-landed-test"));
    try std.testing.expect(!landing.take(landing.slotOf(job)));
}
