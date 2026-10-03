//! Focused regression on parsed Responses failures and both ACP dispatch paths.
const std = @import("std");
const Io = std.Io;
const Agent = @import("agent.zig").Agent;
const provider = @import("provider.zig");
const recovery = @import("auth_recovery.zig");
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
    const parsed = try live.root.parseResponses(text);
    const failure = parsed.err;
    live.root.last_api_reauth = recovery.forFailure(live.root.provider, failure.code, failure.message);
    live.root.last_api_error = try @import("agent_responses.zig").failureDiagnostic(a, live.root.provider.id, failure);
    return error.ApiError;
}

const invalid_token = "{\"detail\":{\"error_code\":\"invalid_token\"}}";

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

test "typed reauth: route and credential source gate the action; non-auth codes win" {
    var p = route("chatgpt-new");
    for ([_][]const u8{ "invalid_token", "invalid_api_key", "authentication_error", "token_expired", "subscription_sharing_invalid_user", "subscription_sharing_v2_invalid_user" }) |code| {
        try std.testing.expect(recovery.forFailure(p, code, "User cannot be verified") != null);
    }
    try std.testing.expect(recovery.forFailure(p, null, "Provided authentication token is expired.") != null);
    for ([_][]const u8{ "server_error", "rate_limit_exceeded", "subscription_sharing_usage_limit_exceeded", "subscription_sharing_v2_usage_limit_exceeded", "context_length_exceeded" }) |code| {
        try std.testing.expect(recovery.forFailure(p, code, "authentication service unavailable") == null);
    }
    try std.testing.expect(recovery.forFailure(p, null, "request id expired") == null);
    try std.testing.expect(recovery.forFailure(p, null, "connection refused") == null);
    p.source = .environment;
    try std.testing.expect(recovery.forFailure(p, "invalid_token", "Unauthorized") == null);
    p = route("openai");
    try std.testing.expect(recovery.forFailure(p, "invalid_api_key", "Unauthorized") == null);
}

test "typed reauth: v1 parsed HTTP and stream auth errors carry route-specific login; next prompt recovers" {
    defer v2.resetForTest();
    v2.gate = false;
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
    const bodies = [_][]const u8{
        invalid_token,
        "{\"error\":{\"code\":\"token_expired\",\"message\":\"Provided authentication token is expired. Please try signing in again.\"}}",
        "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"token_expired\",\"message\":\"Provided authentication token is expired. Please try signing in again.\"}}}\n",
        "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_invalid_user\",\"message\":\"User cannot be verified\"}}}\n",
    };
    for ([_][]const u8{ "chatgpt-new", "codex" }) |id| {
        agent.provider = route(id);
        for (bodies) |body| {
            out.clearRetainingCapacity();
            try engine.handleLine(&d, a, &out.writer, try prompt(a, body));
            const result = try std.json.parseFromSliceLeaky(std.json.Value, a, std.mem.sliceTo(out.writer.buffered(), '\n'), .{});
            const err = result.object.get("error").?.object;
            try std.testing.expectEqual(@as(i64, -32000), err.get("code").?.integer);
            try assertLogin(err.get("data").?.object, id, if (std.mem.eql(u8, id, "codex")) "codex" else "graff");
            try std.testing.expect(result.object.get("result") == null);
            try std.testing.expect(LiveTurn.errorRecovery(&live, error.StreamDropped) == null);
        }
    }
    // A subsequent server/quota rejection must not reuse the previous action.
    for ([_][]const u8{ "server_error", "subscription_sharing_usage_limit_exceeded" }) |code| {
        out.clearRetainingCapacity();
        const body = try std.fmt.allocPrint(a, "{{\"error\":{{\"code\":\"{s}\",\"message\":\"authentication service unavailable\"}}}}", .{code});
        try engine.handleLine(&d, a, &out.writer, try prompt(a, body));
        const result = try std.json.parseFromSliceLeaky(std.json.Value, a, std.mem.sliceTo(out.writer.buffered(), '\n'), .{});
        const err = result.object.get("error").?.object;
        try std.testing.expectEqual(@as(i64, -32603), err.get("code").?.integer);
        try std.testing.expect(err.get("data") == null);
    }
    out.clearRetainingCapacity();
    agent.last_api_reauth = recovery.forFailure(agent.provider, "invalid_token", "Unauthorized");
    try engine.handleLine(&d, a, &out.writer, try prompt(a, "ok"));
    try std.testing.expect(agent.last_api_reauth == null);
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "end_turn") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "reauth_required") == null);
}

test "typed reauth: v2 accepted prompt carries the same action on the failed idle update" {
    defer v2.resetForTest();
    v2.gate = true;
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
    try engine.handleLine(&d, a, &out.writer, try prompt(a, invalid_token));
    var lines = std.mem.tokenizeScalar(u8, out.writer.buffered(), '\n');
    var actions: usize = 0;
    while (lines.next()) |line| {
        const value = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
        try std.testing.expect(value.object.get("error") == null);
        const params = value.object.get("params") orelse continue;
        const update = params.object.get("update") orelse continue;
        const meta = update.object.get("_meta") orelse continue;
        const data = meta.object.get("graff/reauth") orelse continue;
        try std.testing.expectEqualStrings("_error", update.object.get("stopReason").?.string);
        try assertLogin(data.object, "chatgpt-new", "graff");
        actions += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), actions);
}
