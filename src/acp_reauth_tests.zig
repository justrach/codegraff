//! Production terminal-auth handling through transport/Responses fixtures and ACP.
const std = @import("std");
const Io = std.Io;
const Agent = @import("agent.zig").Agent;
const provider = @import("provider.zig");
const recovery = @import("auth_recovery.zig");
const quota = @import("agent_request_quota.zig");
const engine = @import("acp_engine.zig");
const LiveTurn = @import("acp_live_turn.zig").LiveTurn;
const v2 = @import("acp_v2.zig");

fn route(id: []const u8) provider.Provider {
    return .{ .id = id, .kind = .responses, .auth = .bearer, .url = "", .api_key = "fixture", .model = "fixture", .context = 1000, .source = .login };
}

fn root(a: std.mem.Allocator) Agent {
    return .{ .gpa = std.testing.allocator, .arena = a, .io = std.testing.io, .client = undefined, .provider = route("chatgpt-new"), .messages = std.json.Array.init(a), .sub = false, .label = "test", .out = null };
}

fn parsedFailure(ctx: *anyopaque, a: std.mem.Allocator, text: []const u8) anyerror![]const u8 {
    const live: *LiveTurn = @ptrCast(@alignCast(ctx));
    if (std.mem.eql(u8, text, "ok")) return "recovered";
    // Model the terminal boundary after the request's one refresh was spent.
    // No OAuth, credential-store access or network is needed by this fixture.
    var refreshed = true;
    if (std.mem.startsWith(u8, text, "http:")) {
        const status = try std.fmt.parseInt(u16, text[5..], 10);
        const err = quota.httpError(status) orelse return error.UnexpectedFixtureStatus;
        if (try quota.handle(live.root, "", quota.transportCode(err), "", &refreshed)) return error.UnexpectedFixtureRetry;
        return err;
    }
    const parsed = try live.root.parseResponses(text);
    const failure = parsed.err;
    if (try quota.handle(live.root, "", failure.code, failure.message, &refreshed)) return error.UnexpectedFixtureRetry;
    live.root.last_api_error = try @import("agent_responses.zig").failureDiagnostic(a, live.root.provider.id, failure);
    return error.ApiError;
}

const invalid_token = "{\"detail\":{\"error_code\":\"invalid_token\"}}";
const auth_bodies = [_][]const u8{
    "http:401",
    "{\"error\":{\"code\":401,\"message\":\"rejected\"}}",
    invalid_token,
    "{\"error\":{\"code\":\"token_expired\",\"message\":\"Provided authentication token is expired. Please try signing in again.\"}}",
    "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"token_expired\",\"message\":\"Provided authentication token is expired. Please try signing in again.\"}}}\n",
    "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_invalid_user\",\"message\":\"User cannot be verified\"}}}\n",
};
const non_auth_bodies = [_][]const u8{
    "http:402",
    "http:403",
    "{\"error\":{\"code\":403,\"message\":\"route not eligible\"}}",
    "{\"error\":{\"code\":\"server_error\",\"message\":\"upstream unavailable\"}}",
    "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"insufficient_quota\",\"message\":\"invalid_token\"}}}\n",
    "{\"error\":{\"code\":\"server_error\",\"message\":\"authentication service unavailable\"}}",
    "{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\",\"message\":\"authentication service unavailable\"}}",
};

fn prompt(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var w: Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &w.writer };
    try s.write(.{ .id = 3, .method = "session/prompt", .params = .{ .prompt = text } });
    return w.writer.buffered();
}

fn dispatch(live: *LiveTurn) engine.Dispatch {
    return .{ .turn = parsedFailure, .ctx = live, .bind_session = LiveTurn.bindSession, .error_message = LiveTurn.errorMessage, .error_recovery = LiveTurn.errorRecovery };
}

fn assertLogin(data: std.json.ObjectMap, id: []const u8, command: []const u8) !void {
    try std.testing.expectEqualStrings("reauth_required", data.get("kind").?.string);
    try std.testing.expectEqualStrings(id, data.get("provider").?.string);
    const login = data.get("login").?.object;
    try std.testing.expectEqualStrings(command, login.get("command").?.string);
    const args = login.get("args").?.array.items;
    try std.testing.expectEqualStrings("login", args[0].string);
    try std.testing.expectEqual(@as(usize, if (std.mem.eql(u8, id, "codex")) 1 else 2), args.len);
    if (args.len == 2) try std.testing.expectEqualStrings("chatgpt-new", args[1].string);
    try std.testing.expectEqual(@as(usize, 3), data.count());
}

fn assertKeyRejected(a: std.mem.Allocator, output: []const u8, id: []const u8, suffix: []const u8) !void {
    const result = try std.json.parseFromSliceLeaky(std.json.Value, a, std.mem.sliceTo(output, '\n'), .{});
    const err = result.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32603), err.get("code").?.integer);
    const data = err.get("data").?.object;
    try std.testing.expectEqualStrings("api_key_rejected", data.get("kind").?.string);
    try std.testing.expectEqualStrings(id, data.get("provider").?.string);
    try std.testing.expectEqual(@as(usize, 2), data.count());
    const message = err.get("message").?.string;
    try std.testing.expect(std.mem.endsWith(u8, message, suffix));
    for (recovery.signed_out_phrases) |phrase| try std.testing.expect(@import("util.zig").indexOfIgnoreCase(message, phrase) == null);
}

const V2Expect = union(enum) { none, reauth: []const u8, key_rejected: []const u8 };

fn assertV2Failure(a: std.mem.Allocator, output: []const u8, expect: V2Expect) !void {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    var accepted: usize = 0;
    var failures: usize = 0;
    while (lines.next()) |line| {
        const value = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
        try std.testing.expect(value.object.get("error") == null);
        if (value.object.get("result")) |result| {
            try std.testing.expect(result.object.get("messageId") != null);
            accepted += 1;
        }
        const params = value.object.get("params") orelse continue;
        const update = params.object.get("update") orelse continue;
        const meta = update.object.get("_meta") orelse continue;
        if (meta.object.get("graff/error") == null) continue;
        try std.testing.expectEqualStrings("idle", update.object.get("state").?.string);
        try std.testing.expectEqualStrings("_error", update.object.get("stopReason").?.string);
        switch (expect) {
            .reauth => |expected| {
                try assertLogin(meta.object.get("graff/reauth").?.object, expected, if (std.mem.eql(u8, expected, "codex")) "codex" else "graff");
                try std.testing.expect(meta.object.get("graff/recovery") == null);
            },
            .key_rejected => |expected| {
                // Never on `graff/reauth`: clients read that as signed out.
                try std.testing.expect(meta.object.get("graff/reauth") == null);
                const data = meta.object.get("graff/recovery").?.object;
                try std.testing.expectEqualStrings("api_key_rejected", data.get("kind").?.string);
                try std.testing.expectEqualStrings(expected, data.get("provider").?.string);
                try std.testing.expectEqual(@as(usize, 2), data.count());
                const message = meta.object.get("graff/error").?.string;
                try std.testing.expect(std.mem.indexOf(u8, message, recovery.api_key_rejected_phrase) != null);
            },
            .none => {
                try std.testing.expect(meta.object.get("graff/reauth") == null);
                try std.testing.expect(meta.object.get("graff/recovery") == null);
            },
        }
        failures += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), accepted);
    try std.testing.expectEqual(@as(usize, 1), failures);
}

test "typed reauth: route and credential source gate the action; non-auth codes win" {
    var p = route("chatgpt-new");
    for ([_][]const u8{ "401", "invalid_token", "invalid_api_key", "authentication_error", "token_expired", "subscription_sharing_invalid_user", "subscription_sharing_v2_invalid_user" }) |code| {
        try std.testing.expect(recovery.forFailure(p, code, "User cannot be verified") != null);
    }
    try std.testing.expect(recovery.forFailure(p, null, "Provided authentication token is expired.") != null);
    for ([_][]const u8{ "402", "403", "server_error", "rate_limit_exceeded", "subscription_sharing_usage_limit_exceeded", "subscription_sharing_v2_usage_limit_exceeded", "context_length_exceeded" }) |code| {
        try std.testing.expect(recovery.forFailure(p, code, "authentication service unavailable") == null);
    }
    try std.testing.expect(recovery.forFailure(p, null, "request id expired") == null);
    try std.testing.expect(recovery.forFailure(p, null, "connection refused") == null);
    p.source = .environment;
    try std.testing.expect(recovery.forFailure(p, "invalid_token", "Unauthorized") == null);
    p = route("openai");
    try std.testing.expect(recovery.forFailure(p, "invalid_api_key", "Unauthorized") == null);
}

test "typed reauth: production terminal handler gates actions and clears stale metadata" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var agent = root(state.allocator());
    const cases = [_]struct { etype: []const u8 = "", code: ?[]const u8 = null, msg: []const u8 = "", err: anyerror, action: bool = false }{
        .{ .code = "401", .err = error.ProviderAuthenticationFailed, .action = true },
        .{ .etype = "authentication_error", .err = error.ProviderAuthenticationFailed, .action = true },
        .{ .code = "invalid_token", .msg = "rejected", .err = error.ProviderAuthenticationFailed, .action = true },
        .{ .msg = "token has expired", .err = error.ProviderAuthenticationFailed, .action = true },
        .{ .code = "402", .msg = "authentication required", .err = error.ProviderQuotaExceeded },
        .{ .code = "403", .msg = "route not eligible", .err = error.ProviderAccessDenied },
        .{ .code = "403", .msg = "authentication service unavailable", .err = error.ProviderAuthenticationFailed },
        .{ .code = "server_error", .msg = "Unauthorized", .err = error.ProviderAuthenticationFailed },
        .{ .code = "insufficient_quota", .msg = "invalid_token", .err = error.ProviderQuotaExceeded },
    };
    const failover = @import("credential_failover.zig");
    failover.resetForTest();
    defer failover.resetForTest();
    for ([_][]const u8{ "chatgpt-new", "codex", "openai" }) |id| {
        for ([_]provider.Keys.CredentialSource{ .login, .environment, .stored, .session }) |source| {
            agent.provider = route(id);
            agent.provider.source = source;
            for (cases) |case| {
                agent.last_api_reauth = recovery.forFailure(route("codex"), "401", "");
                // Already spent: the common boundary must not attempt refresh again.
                var refreshed = true;
                try std.testing.expectError(case.err, quota.handle(&agent, case.etype, case.code, case.msg, &refreshed));
                try std.testing.expect(refreshed);
                const action = case.action and source == .login and !std.mem.eql(u8, id, "openai");
                // ADR 0310: a metered seat names the rejected key, never a login.
                const key_rejected = case.action and source != .login;
                try std.testing.expectEqual(action or key_rejected, agent.last_api_reauth != null);
                if (agent.last_api_reauth) |data| {
                    try std.testing.expectEqualStrings(id, data.provider);
                    if (key_rejected) {
                        try std.testing.expectEqualStrings("api_key_rejected", data.kind);
                        try std.testing.expect(data.login == null);
                    } else try std.testing.expectEqualStrings(if (std.mem.eql(u8, id, "codex")) "codex" else "graff", data.login.?.command);
                }
                if (case.err == error.ProviderAuthenticationFailed) {
                    const text = agent.last_api_error.?;
                    if (source == .login) {
                        try std.testing.expect(std.mem.indexOf(u8, text, "sign-in was rejected: sign in again") != null);
                    } else {
                        try std.testing.expect(std.mem.indexOf(u8, text, recovery.api_key_rejected_phrase) != null);
                        for (recovery.signed_out_phrases) |phrase| try std.testing.expect(@import("util.zig").indexOfIgnoreCase(text, phrase) == null);
                    }
                }
            }
            agent.last_api_reauth = recovery.forFailure(route("codex"), "401", "");
            var refreshed = false;
            try std.testing.expect(!try quota.handle(&agent, "server_error", null, "temporarily unavailable", &refreshed));
            try std.testing.expect(agent.last_api_reauth == null);
            try std.testing.expect(!refreshed);
        }
    }
}

test "typed reauth: v1 parsed HTTP and stream auth errors carry route-specific login; next prompt recovers" {
    defer v2.resetForTest();
    v2.gate = false;
    const failover = @import("credential_failover.zig");
    failover.resetForTest();
    defer failover.resetForTest();
    const cancelled = engine.cancel_flag.swap(false, .acq_rel);
    defer engine.cancel_flag.store(cancelled, .release);
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var agent = root(a);
    var keys: provider.Keys = .{ .values = @splat(null) };
    var out: Io.Writer.Allocating = .init(a);
    var live: LiveTurn = .{ .root = &agent, .keys = &keys, .out = &out.writer };
    var d = dispatch(&live);
    for ([_][]const u8{ "chatgpt-new", "codex" }) |id| {
        agent.provider = route(id);
        for (auth_bodies) |body| {
            out.clearRetainingCapacity();
            try engine.handleLine(&d, a, &out.writer, try prompt(a, body));
            const result = try std.json.parseFromSliceLeaky(std.json.Value, a, std.mem.sliceTo(out.writer.buffered(), '\n'), .{});
            const err = result.object.get("error").?.object;
            try std.testing.expectEqual(@as(i64, -32000), err.get("code").?.integer);
            try assertLogin(err.get("data").?.object, id, if (std.mem.eql(u8, id, "codex")) "codex" else "graff");
            try std.testing.expect(result.object.get("result") == null);
            try std.testing.expectEqualStrings(if (std.mem.eql(u8, id, "codex"))
                "Codex (ChatGPT) sign-in was rejected: sign in again (codex login)"
            else
                "ChatGPT plan (new sign-in) sign-in was rejected: sign in again (graff login chatgpt-new)", err.get("message").?.string);
            try std.testing.expect(LiveTurn.errorRecovery(&live, error.StreamDropped) == null);
            try std.testing.expect(LiveTurn.errorRecovery(&live, error.ProviderQuotaExceeded) == null);
            try std.testing.expect(LiveTurn.errorRecovery(&live, error.ProviderAccessDenied) == null);
        }
    }
    // A subsequent server/quota rejection must not reuse the previous action.
    for ([_][]const u8{ "chatgpt-new", "codex" }) |id| {
        agent.provider = route(id);
        for (non_auth_bodies) |body| {
            out.clearRetainingCapacity();
            agent.last_api_reauth = recovery.forFailure(agent.provider, "401", "");
            try engine.handleLine(&d, a, &out.writer, try prompt(a, body));
            const result = try std.json.parseFromSliceLeaky(std.json.Value, a, std.mem.sliceTo(out.writer.buffered(), '\n'), .{});
            const err = result.object.get("error").?.object;
            try std.testing.expectEqual(@as(i64, -32603), err.get("code").?.integer);
            try std.testing.expect(err.get("data") == null);
        }
        // ADR 0310: a metered seat stays an internal error, with data naming
        // the rejected key and no login action.
        agent.provider.source = .environment;
        for (auth_bodies) |body| {
            out.clearRetainingCapacity();
            try engine.handleLine(&d, a, &out.writer, try prompt(a, body));
            try assertKeyRejected(a, out.writer.buffered(), id, "API key was rejected (environment): replace or remove the key. Your sign-in is not affected.");
        }
    }
    // A key a spent plan handed over to says so.
    failover.park("anthropic", "metered", .profile);
    _ = failover.promote("anthropic").?;
    agent.provider = route("anthropic");
    agent.provider.source = .profile;
    out.clearRetainingCapacity();
    try engine.handleLine(&d, a, &out.writer, try prompt(a, "http:401"));
    try assertKeyRejected(a, out.writer.buffered(), "anthropic", "plan is out of usage, and the fallback API key was rejected (Console profile): replace or remove the key, or wait for the plan to reset.");
    out.clearRetainingCapacity();
    agent.last_api_reauth = recovery.forFailure(route("codex"), "invalid_token", "Unauthorized");
    try engine.handleLine(&d, a, &out.writer, try prompt(a, "ok"));
    try std.testing.expect(agent.last_api_reauth == null);
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "end_turn") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "reauth_required") == null);
}

test "typed reauth: v2 accepted prompt carries the same action on the failed idle update" {
    defer v2.resetForTest();
    v2.gate = true;
    const failover = @import("credential_failover.zig");
    failover.resetForTest();
    defer failover.resetForTest();
    const cancelled = engine.cancel_flag.swap(false, .acq_rel);
    defer engine.cancel_flag.store(cancelled, .release);
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var agent = root(a);
    var keys: provider.Keys = .{ .values = @splat(null) };
    var out: Io.Writer.Allocating = .init(a);
    var live: LiveTurn = .{ .root = &agent, .keys = &keys, .out = &out.writer };
    var d = dispatch(&live);
    try engine.handleLine(&d, a, &out.writer, "{\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":2}}");
    out.clearRetainingCapacity();
    for ([_][]const u8{ "chatgpt-new", "codex" }) |id| {
        agent.provider = route(id);
        for (auth_bodies) |body| {
            out.clearRetainingCapacity();
            try engine.handleLine(&d, a, &out.writer, try prompt(a, body));
            try assertV2Failure(a, out.writer.buffered(), .{ .reauth = id });
        }
        for (non_auth_bodies) |body| {
            out.clearRetainingCapacity();
            agent.last_api_reauth = recovery.forFailure(agent.provider, "401", "");
            try engine.handleLine(&d, a, &out.writer, try prompt(a, body));
            try assertV2Failure(a, out.writer.buffered(), .none);
        }
        agent.provider.source = .environment;
        for (auth_bodies) |body| {
            out.clearRetainingCapacity();
            try engine.handleLine(&d, a, &out.writer, try prompt(a, body));
            try assertV2Failure(a, out.writer.buffered(), .{ .key_rejected = id });
        }
    }
    out.clearRetainingCapacity();
    agent.last_api_reauth = recovery.forFailure(route("codex"), "401", "");
    try engine.handleLine(&d, a, &out.writer, try prompt(a, "ok"));
    try std.testing.expect(agent.last_api_reauth == null);
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "end_turn") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "reauth_required") == null);
}

test "typed reauth: a failure after async tools started names the rejected credential too" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    var agent = root(state.allocator());
    agent.provider = route("openai");
    agent.provider.source = .stored;
    try quota.afterToolsStarted(&agent, "invalid_api_key", "Incorrect API key provided", "raw provider diagnostic");
    try std.testing.expectEqualStrings("OpenAI API key was rejected (secure store): replace or remove the key. Your sign-in is not affected.", agent.last_api_error.?);
    try std.testing.expectEqualStrings("api_key_rejected", agent.last_api_reauth.?.kind);
    agent.provider = route("chatgpt-new");
    try quota.afterToolsStarted(&agent, "token_expired", "Provided authentication token is expired.", "raw provider diagnostic");
    try std.testing.expectEqualStrings("ChatGPT plan (new sign-in) sign-in was rejected: sign in again (graff login chatgpt-new)", agent.last_api_error.?);
    try std.testing.expectEqualStrings("reauth_required", agent.last_api_reauth.?.kind);
    // A non-auth failure keeps the provider's own diagnostic and no metadata.
    try quota.afterToolsStarted(&agent, "server_error", "upstream unavailable", "raw provider diagnostic");
    try std.testing.expectEqualStrings("raw provider diagnostic", agent.last_api_error.?);
    try std.testing.expect(agent.last_api_reauth == null);
}
