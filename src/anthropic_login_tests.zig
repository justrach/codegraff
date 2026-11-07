//! Native Anthropic login shares routing, reload and billing across clients.
//! Console profiles stay metered with ordinary Messages formatting.
const std = @import("std");
const Io = std.Io;
const provider = @import("provider.zig");
const billing = @import("billing.zig");
const store = @import("credential_store.zig");
const failover = @import("credential_failover.zig");
const policy = @import("agent_request_policy.zig");
const Agent = @import("agent.zig").Agent;

fn fixtureAgent(io: Io, arena: std.mem.Allocator, home: []const u8, seat: provider.Provider) Agent {
    var agent: Agent = undefined;
    agent.io = io;
    agent.gpa = std.testing.allocator;
    agent.arena = arena;
    agent.scratch_arena = null;
    agent.tracer = null;
    agent.sub = false;
    agent.out = null;
    agent.label = "root";
    agent.home = home;
    agent.model_catalog = null;
    agent.codex_ws = null;
    agent.codex_prev_id = null;
    agent.provider = seat;
    return agent;
}

fn testHome(io: Io, arena: std.mem.Allocator, dir: Io.Dir) ![]const u8 {
    var path: [std.fs.max_path_bytes]u8 = undefined;
    return arena.dupe(u8, path[0..try dir.realPath(io, &path)]);
}

test "Anthropic OAuth routing preserves Bearer on model pins but API keys stay metered" {
    var keys: provider.Keys = .{ .values = @splat(null) };
    try std.testing.expect(keys.set("anthropic", "oauth-test", .login));
    const plan = try keys.providerById("anthropic", "claude-opus-5-5");
    try std.testing.expectEqual(provider.Provider.Auth.bearer, plan.auth);
    try std.testing.expectEqual(billing.Billing.sub, billing.forProvider(plan));
    const pinned = provider.Provider.withModel(plan, "claude-sonnet-5-5");
    try std.testing.expectEqual(provider.Provider.Auth.bearer, pinned.auth);
    try std.testing.expectEqualStrings(plan.api_key, pinned.api_key);
    try std.testing.expectEqual(provider.Keys.CredentialSource.login, pinned.source);
    try std.testing.expect(keys.set("anthropic", "console-test", .profile));
    const console = try keys.providerById("anthropic", "claude-opus-5-5");
    try std.testing.expectEqual(provider.Provider.Auth.bearer, console.auth);
    try std.testing.expect(billing.forProvider(console) != .sub);
    const console_pin = provider.Provider.withModel(console, "claude-sonnet-5-5");
    try std.testing.expectEqual(provider.Provider.Auth.bearer, console_pin.auth);
    try std.testing.expectEqual(provider.Keys.CredentialSource.profile, console_pin.source);
    try std.testing.expect(keys.set("anthropic", "api-test", .environment));
    const metered = try keys.providerById("anthropic", "claude-opus-5-5");
    try std.testing.expectEqual(provider.Provider.Auth.x_api_key, metered.auth);
    try std.testing.expect(billing.forProvider(metered) != .sub);
    try std.testing.expectEqual(provider.Provider.Auth.x_api_key, provider.Provider.withModel(metered, "claude-sonnet-5-5").auth);
}

test "Anthropic OAuth stored plan outranks env key and quota handoff restores API-key auth" {
    const io = std.testing.io;
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testHome(io, arena, tmp.dir);
    try store.writeOAuth(io, arena, home, ".anthropic", "oauth-test", "refresh-test", @divTrunc(@import("util.zig").unixMs(io), 1000) + 3600);
    failover.resetForTest();
    defer failover.resetForTest();
    var key: ?[]const u8 = "api-test";
    var source: provider.Keys.CredentialSource = .environment;
    failover.preferPlan(io, std.testing.allocator, arena, home, provider.specFor("anthropic").?, &key, &source);
    try std.testing.expectEqualStrings("oauth-test", key.?);
    try std.testing.expectEqual(provider.Keys.CredentialSource.login, source);
    try std.testing.expect(failover.standingBy("anthropic"));
    var keys: provider.Keys = .{ .values = @splat(null) };
    _ = keys.set("anthropic", key.?, source);
    var agent = fixtureAgent(io, arena, home, try keys.providerById("anthropic", "claude-opus-5-5"));
    try std.testing.expect(policy.handOffExhaustedPlan(&agent));
    try std.testing.expectEqualStrings("api-test", agent.provider.api_key);
    try std.testing.expectEqual(provider.Keys.CredentialSource.environment, agent.provider.source);
    try std.testing.expectEqual(provider.Provider.Auth.x_api_key, agent.provider.auth);
    try std.testing.expect(billing.forProvider(agent.provider) != .sub);
    try std.testing.expect(!policy.handOffExhaustedPlan(&agent));
}

test "Anthropic OAuth in-session login reloads active auth and refresh dispatcher adopts disk token" {
    failover.resetForTest();
    defer failover.resetForTest();
    const io = std.testing.io;
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try testHome(io, arena, tmp.dir);
    const expiry = @divTrunc(@import("util.zig").unixMs(io), 1000) + 3600;
    try store.writeOAuth(io, arena, home, ".anthropic", "oauth-test", "refresh-test", expiry);
    var keys: provider.Keys = .{ .values = @splat(null) };
    _ = keys.set("anthropic", "api-test", .environment);
    var agent = fixtureAgent(io, arena, home, try keys.providerById("anthropic", "claude-opus-5-5"));
    @import("picker_auth.zig").reloadLoginKey(&agent, &keys, arena, "anthropic");
    try std.testing.expect(failover.standingBy("anthropic"));
    try std.testing.expectEqualStrings("oauth-test", agent.provider.api_key);
    try std.testing.expectEqual(provider.Provider.Auth.bearer, agent.provider.auth);
    try std.testing.expectEqual(provider.Keys.CredentialSource.login, agent.provider.source);
    try store.writeOAuth(io, arena, home, ".anthropic", "new-oauth-test", "new-refresh-test", expiry);
    const fresh = @import("oauth.zig").refreshOAuthKey(io, std.testing.allocator, arena, home, "anthropic", true, "oauth-test", "").?;
    try std.testing.expectEqualStrings("new-oauth-test", fresh.key);
}

test "Anthropic OAuth catalog uses Bearer and beta while API-key catalog stays unchanged" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var headers: [4]std.http.Header = undefined;
    const catalog = @import("router_catalog.zig");
    const spec = provider.specFor("anthropic").?;
    const plan = catalog.catalogHeaders(state.allocator(), spec, "oauth-test", .login, &headers).?;
    try std.testing.expectEqual(@as(usize, 4), plan.len);
    try std.testing.expectEqualStrings("Authorization", plan[1].name);
    try std.testing.expectEqualStrings("Bearer oauth-test", plan[1].value);
    try std.testing.expect(std.mem.indexOf(u8, plan[3].value, "oauth-2025-04-20") != null);
    const console = catalog.catalogHeaders(state.allocator(), spec, "console-test", .profile, &headers).?;
    try std.testing.expectEqual(@as(usize, 3), console.len);
    try std.testing.expectEqualStrings("Authorization", console[1].name);
    try std.testing.expectEqualStrings("Bearer console-test", console[1].value);
    const metered = catalog.catalogHeaders(state.allocator(), spec, "api-test", .environment, &headers).?;
    try std.testing.expectEqual(@as(usize, 3), metered.len);
    try std.testing.expectEqualStrings("x-api-key", metered[1].name);
    try std.testing.expectEqualStrings("api-test", metered[1].value);
}

test "Anthropic Console profiles stay metered with ordinary formatting unlike native login" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const wire = @import("anthropic_oauth_wire.zig");
    const tools = "[{\"name\":\"bAsH\",\"description\":\"shell\",\"input_schema\":{\"type\":\"object\"}}]";
    const messages = try std.json.parseFromSliceLeaky(std.json.Value, arena, "[{\"role\":\"user\",\"content\":\"hello\"}]", .{ .allocate = .alloc_always });
    var keys: provider.Keys = .{ .values = @splat(null) };
    for ([_]provider.Keys.CredentialSource{ .profile, .login, .environment }) |source| {
        try std.testing.expect(keys.set("anthropic", "synthetic-token", source));
        var agent: Agent = .{
            .gpa = std.testing.allocator,
            .arena = arena,
            .io = std.testing.io,
            .client = undefined,
            .provider = try keys.providerById("anthropic", "claude-opus-5-5"),
            .messages = messages.array,
            .sub = false,
            .label = "",
            .out = null,
            .sys_normal = "Ordinary Graff instructions.",
            .tools_anthropic = tools,
        };
        const subscription = source == .login;
        try std.testing.expectEqual(subscription, wire.active(agent.provider));
        try std.testing.expectEqual(subscription, billing.forProvider(agent.provider) == .sub);
        try std.testing.expectEqual(if (subscription) billing.CostClass.plan else .api, billing.costFor("anthropic", source));
        try std.testing.expectEqual(if (source == .environment) provider.Provider.Auth.x_api_key else .bearer, agent.provider.auth);
        var headers: [12]std.http.Header = undefined;
        const hs = @import("http_headers.zig").providerHeaders(std.testing.io, agent.provider, "Bearer synthetic-token", &headers);
        var identity = false;
        var bearer = false;
        for (hs) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "x-app")) identity = true;
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) bearer = true;
            if (std.ascii.eqlIgnoreCase(header.name, "anthropic-beta"))
                try std.testing.expectEqual(subscription, std.mem.indexOf(u8, header.value, "oauth-2025-04-20") != null);
        }
        try std.testing.expectEqual(subscription, identity);
        try std.testing.expectEqual(source != .environment, bearer);
        const body = try agent.buildBody(tools, false, true, true);
        defer std.testing.allocator.free(body);
        const root = (try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{ .allocate = .alloc_always })).object;
        const system = root.get("system").?.array.items;
        try std.testing.expectEqual(@as(usize, if (subscription) 2 else 1), system.len);
        try std.testing.expectEqualStrings(agent.sys_normal, system[system.len - 1].object.get("text").?.string);
        try std.testing.expectEqual(subscription, std.mem.indexOf(u8, body, wire.system_prefix) != null);
        try std.testing.expectEqualStrings(if (subscription) "Bash" else "bAsH", root.get("tools").?.array.items[0].object.get("name").?.string);
    }
}
