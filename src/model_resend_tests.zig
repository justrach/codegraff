//! Model request-policy regressions that count real POSTs or injected DNS lookups.

const std = @import("std");
const Io = std.Io;
const Agent = @import("agent.zig").Agent;
const Provider = @import("provider.zig").Provider;
const budget_mod = @import("run_budget.zig");
const transport = @import("http_client_integration_tests.zig");
const RetryPlan = @import("http.zig").RetryPlan;

fn agentFor(arena: std.mem.Allocator, client: *std.http.Client, provider: Provider, budget: *budget_mod.RunBudget) Agent {
    return .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = client.io,
        .client = client,
        .provider = provider,
        .messages = std.json.Array.init(arena),
        .sub = true,
        .text_only = true,
        .run_budget = budget,
        .label = "request-fixture",
        .out = null,
    };
}

test "#1932: a logical permit includes retries unless model resends are disabled" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const previous = RetryPlan.no_model_resends;
    defer RetryPlan.no_model_resends = previous;
    // HTTP 503 takes the transport retry ladder. A 200 with a transient
    // provider-error envelope takes the independent request-rebuild ladder.
    const failures = [_]transport.Reply{
        .{ .status = "503 Service Unavailable", .body = "{}" },
        .{ .body = "{\"error\":{\"type\":\"server_error\",\"message\":\"internal server error\"}}" },
    };
    for (failures) |failure| {
        for ([_]bool{ false, true }) |strict| {
            RetryPlan.no_model_resends = strict;
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var address = try Io.net.IpAddress.parseLiteral("127.0.0.1:0");
            var server = try Io.net.IpAddress.listen(&address, io, .{});
            defer server.deinit(io);
            var accepted: std.atomic.Value(usize) = .init(0);
            const replies = [_]transport.Reply{ failure, .{ .body = transport.chat_body } };
            var peer = try io.concurrent(transport.serveReplies, .{ io, &server, &replies, &accepted });
            defer peer.await(io);
            defer transport.releaseAccept(io, &server);
            const url = try std.fmt.allocPrint(arena.allocator(), "http://127.0.0.1:{d}/v1/chat/completions", .{server.socket.address.getPort()});
            var client: std.http.Client = .{ .allocator = gpa, .io = io };
            defer client.deinit();
            var budget: budget_mod.RunBudget = .{ .max_model_calls = 1 };
            var agent = agentFor(arena.allocator(), &client, transport.provider(url), &budget);
            if (strict) {
                try std.testing.expectError(error.ApiError, agent.request(null));
                try std.testing.expectEqual(@as(usize, 1), agent.last_api_error_detail.?.attempts);
            } else {
                _ = try agent.request(null);
            }
            try std.testing.expectEqual(@as(usize, if (strict) 1 else 2), accepted.load(.acquire));
            try std.testing.expectEqual(@as(u64, 1), budget.used());
        }
    }
}

var lookups: std.atomic.Value(usize) = .init(0);
fn failLookup(_: ?*anyopaque, host: Io.net.HostName, queue: *Io.Queue(Io.net.HostName.LookupResult), _: Io.net.HostName.LookupOptions) Io.net.HostName.LookupError!void {
    std.debug.assert(std.mem.eql(u8, host.bytes, "resolver-test.invalid"));
    queue.close(std.testing.io);
    _ = lookups.fetchAdd(1, .acq_rel);
    return error.UnknownHostName;
}

test "#1930: terminal DNS failure during server compaction ends the turn without fresh retries" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const compact = @import("agent_server_compact.zig");
    const prior_override = compact.g_server_compact_override;
    compact.g_server_compact_override = true;
    defer compact.g_server_compact_override = prior_override;
    const prior_delay = RetryPlan.flake_base_ms;
    RetryPlan.flake_base_ms = 1;
    defer RetryPlan.flake_base_ms = prior_delay;

    for ([_][]const u8{ "codex", "openai" }) |id| {
        lookups.store(0, .release);
        var io_vtable = io.vtable.*;
        io_vtable.netLookup = failLookup;
        const resolver_io: Io = .{ .userdata = io.userdata, .vtable = &io_vtable };
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var client: std.http.Client = .{ .allocator = gpa, .io = resolver_io };
        defer client.deinit();
        var budget: budget_mod.RunBudget = .{ .max_model_calls = 4 };
        var provider = transport.provider("http://resolver-test.invalid/v1/responses");
        provider.id = id;
        provider.kind = .responses;
        var agent = agentFor(arena.allocator(), &client, provider, &budget);
        agent.last_context_tokens = 96_000;
        const history = try @import("messages.zig").userNote(agent.arena, .responses, "Keep this active prompt");
        try agent.messages.append(history);

        try std.testing.expectError(error.ApiError, agent.runTurn());
        const expected_lookups = if (compact.manualRoute(provider) == .in_stream) RetryPlan.maxAttempts(false) else 1;
        try std.testing.expectEqual(expected_lookups, lookups.load(.acquire));
        try std.testing.expectEqual(@as(u64, 1), budget.used());
        try std.testing.expectEqual(expected_lookups, agent.last_api_error_detail.?.attempts);
        try std.testing.expect(std.mem.indexOf(u8, agent.last_api_error_detail.?.technical, "UnknownHostName") != null);
        try std.testing.expectEqual(@as(u32, 0), agent.history_rewrites);
        try std.testing.expectEqual(@as(usize, 2), agent.messages.items.len);
        const row = try std.json.Stringify.valueAlloc(agent.arena, agent.messages.items[0], .{});
        try std.testing.expect(std.mem.indexOf(u8, row, "Keep this active prompt") != null);
    }
}

test "#1932: standalone server compaction consumes the logical model-call permit" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const compact = @import("agent_server_compact.zig");
    const prior_override = compact.g_server_compact_override;
    compact.g_server_compact_override = true;
    defer compact.g_server_compact_override = prior_override;
    const previous = RetryPlan.no_model_resends;
    RetryPlan.no_model_resends = true;
    defer RetryPlan.no_model_resends = previous;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var address = try Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);
    var accepted: std.atomic.Value(usize) = .init(0);
    const replies = [_]transport.Reply{
        .{ .body = "{\"output\":[{\"type\":\"compaction\",\"encrypted_content\":\"state\"}]}" },
        .{ .body = transport.chat_body },
    };
    var peer = try io.concurrent(transport.serveReplies, .{ io, &server, &replies, &accepted });
    defer peer.await(io);
    defer transport.releaseAccept(io, &server);
    const url = try std.fmt.allocPrint(arena.allocator(), "http://127.0.0.1:{d}/v1/responses", .{server.socket.address.getPort()});
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var budget: budget_mod.RunBudget = .{ .max_model_calls = 1 };
    var provider = transport.provider(url);
    provider.id = "openai";
    provider.kind = .responses;
    var agent = agentFor(arena.allocator(), &client, provider, &budget);
    agent.last_context_tokens = 96_000;
    try agent.messages.append(try @import("messages.zig").userNote(agent.arena, .responses, "Active prompt"));

    try std.testing.expectError(error.RunBudgetExhausted, agent.runTurn());
    try std.testing.expectEqual(@as(usize, 1), accepted.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), budget.used());
    try std.testing.expectEqual(@as(u32, 0), budget.active.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), agent.history_rewrites);
}
