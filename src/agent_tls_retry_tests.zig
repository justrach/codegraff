//! Offline production request-loop coverage for the construction-only TLS outage budget.
const std = @import("std");
const Io = std.Io;
const Agent = @import("agent.zig").Agent;
const http = @import("http.zig");
const clients = @import("http_client.zig");
const transport = @import("http_client_integration_tests.zig");
const trace = @import("trace.zig");

// Replace only this test owner's backoff sleeps, not concurrent HTTP watchdogs.
// All other I/O keeps the real testing Io and its original userdata.
var current_probe: ?*SleepProbe = null;
const SleepProbe = struct {
    owner: std.Thread.Id,
    runtime: *clients.Runtime,
    waited_ms: u64 = 0,
    cancel_generation: u64 = 0,
    cancel_io: bool = false,

    fn sleep(ctx: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
        const probe = current_probe.?;
        if (std.Thread.getCurrentId() != probe.owner)
            return std.testing.io.vtable.sleep(ctx, timeout);
        probe.waited_ms += @intCast(timeout.duration.raw.toMilliseconds());
        if (probe.cancel_generation > 0 and probe.runtime.recovery.stats().active_id >= probe.cancel_generation) {
            if (probe.cancel_io) return error.Canceled;
            Agent.esc_cancel.store(true, .release);
        }
    }
};

const Fixture = struct {
    runtime: clients.Runtime,
    arena: std.heap.ArenaAllocator,
    server: std.Io.net.Server,
    server_future: ?Io.Future(void),
    accepted: std.atomic.Value(usize),
    url: [64]u8,
    vtable: Io.VTable,
    probe: SleepProbe,
    agent: Agent,
    trace_output: Io.Writer.Allocating,
    tracer: trace.Tracer,
    previous_cancel: bool,

    fn init(self: *Fixture) !void {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        self.runtime.init(gpa, io);
        errdefer self.runtime.deinit(io);
        http.waitForClientReady(io);
        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        var address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:0");
        self.server = try std.Io.net.IpAddress.listen(&address, io, .{});
        self.server_future = null;
        self.accepted = .init(0);
        self.vtable = io.vtable.*;
        self.vtable.sleep = SleepProbe.sleep;
        self.probe = .{ .owner = std.Thread.getCurrentId(), .runtime = &self.runtime };
        current_probe = &self.probe;
        self.previous_cancel = Agent.esc_cancel.swap(false, .acq_rel);
        self.trace_output = .init(gpa);
        const agent_io: Io = .{ .userdata = io.userdata, .vtable = &self.vtable };
        self.tracer = .{ .io = agent_io, .gpa = gpa, .out = &self.trace_output.writer, .start = .now(io, .awake) };
        const url = try std.fmt.bufPrint(&self.url, "http://127.0.0.1:{d}/v1/test", .{self.server.socket.address.getPort()});
        self.agent = .{
            .gpa = gpa,
            .arena = self.arena.allocator(),
            .io = agent_io,
            .client = &self.runtime.client,
            .provider = transport.provider(url),
            .messages = std.json.Array.init(self.arena.allocator()),
            .sub = true,
            .label = "tls-budget-test",
            .tracer = &self.tracer,
            .out = null,
        };
    }

    fn serve(self: *Fixture, replies: []const transport.Reply) void {
        self.server_future = std.testing.io.async(transport.serveReplies, .{ std.testing.io, &self.server, replies, &self.accepted });
    }

    fn deinit(self: *Fixture) void {
        const io = std.testing.io;
        if (self.server_future) |*future| {
            transport.releaseAccept(io, &self.server);
            future.await(io);
        }
        self.server.deinit(io);
        @import("agent_render.zig").deinitMarkdown(&self.agent);
        self.trace_output.deinit();
        self.runtime.deinit(io);
        self.arena.deinit();
        Agent.esc_cancel.store(self.previous_cancel, .release);
        current_probe = null;
    }

    fn expectReleased(self: *Fixture) !void {
        try std.testing.expectEqual(@as(usize, 0), self.runtime.recovery.stats().total_refs);
        try std.testing.expectEqual(@as(usize, 0), self.runtime.recovery.stats().retired);
    }

    fn tlsNotes(self: *Fixture) usize {
        return std.mem.count(u8, self.trace_output.written(), "\"ev\":\"tls_request_construction\"");
    }
};

test "TLS outage budget: eight constructor failures recover in the same production request" {
    for ([_]bool{ false, true }) |sub| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        fixture.agent.sub = sub;
        const replies = [_]transport.Reply{.{ .body = transport.chat_body }};
        fixture.serve(&replies);
        clients.injectConstructionTlsThroughGenerationForTest(7);
        clients.injectReplacementCaWarmFailureForTest();

        const response = try fixture.agent.request(null);
        const content = response.get("choices").?.array.items[0].object.get("message").?.object.get("content").?.string;
        try std.testing.expectEqualStrings("child-ok", content);
        try std.testing.expectEqual(@as(u64, 8), fixture.runtime.recovery.stats().active_id);
        try std.testing.expectEqual(@as(usize, 8), fixture.tlsNotes());
        try std.testing.expectEqual(@as(usize, 1), fixture.accepted.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, fixture.trace_output.written(), "replacement CA prewarm failed"));
        // Eight retry waits cross the old six-attempt window, with real policy jitter.
        try std.testing.expect(fixture.probe.waited_ms >= 19_750);
        try std.testing.expect(fixture.probe.waited_ms <= 24_688);
        try fixture.expectReleased();
    }
}

test "TLS outage budget: permanent failure is bounded and preserves recovery for a later request" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const limit = http.RetryPlan.tls_construction_attempts;
    clients.injectConstructionTlsThroughGenerationForTest(limit - 1);

    try std.testing.expectError(error.ApiError, fixture.agent.request(null));
    try std.testing.expectEqual(@as(u64, limit), fixture.runtime.recovery.stats().active_id);
    try std.testing.expectEqual(limit, fixture.tlsNotes());
    try std.testing.expectEqual(@as(usize, 0), fixture.accepted.load(.acquire));
    try std.testing.expect(std.mem.indexOf(u8, fixture.agent.last_api_error.?, "gave up after 16 attempts") != null);
    try std.testing.expect(fixture.probe.waited_ms >= 47_750);
    try std.testing.expect(fixture.probe.waited_ms <= 59_688);
    try fixture.expectReleased();

    const replies = [_]transport.Reply{.{ .body = transport.chat_body }};
    fixture.serve(&replies);
    _ = try fixture.agent.request(null);
    try std.testing.expectEqual(@as(usize, 1), fixture.accepted.load(.acquire));
    try fixture.expectReleased();
}

test "TLS outage budget: request rebuild cannot reset the construction failure counter" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const replies = [_]transport.Reply{.{
        .status = "400 Bad Request",
        .body = "{\"error\":{\"message\":\"unsupported stream_options\"}}",
        // First eight TLS failures recover; the parsed rejection then rebuilds
        // the request with stream_options dropped while TLS starts failing again.
        .fail_tls_through_generation = 1000,
    }};
    fixture.serve(&replies);
    clients.injectConstructionTlsThroughGenerationForTest(7);

    try std.testing.expectError(error.ApiError, fixture.agent.request(null));
    try std.testing.expectEqual(@as(u64, 16), fixture.runtime.recovery.stats().active_id);
    try std.testing.expectEqual(@as(usize, 16), fixture.tlsNotes());
    try std.testing.expectEqual(@as(usize, 1), fixture.accepted.load(.acquire));
    try std.testing.expect(fixture.probe.waited_ms >= 47_750);
    try std.testing.expect(fixture.probe.waited_ms <= 59_688);
    try fixture.expectReleased();
}

test "TLS outage budget: Esc and I/O cancellation stop the extended ladder without a replacement attempt" {
    for ([_]bool{ false, true }) |cancel_io| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        fixture.probe.cancel_generation = 9;
        fixture.probe.cancel_io = cancel_io;
        clients.injectConstructionTlsThroughGenerationForTest(1000);

        try std.testing.expectError(error.Interrupted, fixture.agent.request(null));
        try std.testing.expectEqual(@as(u64, 9), fixture.runtime.recovery.stats().active_id);
        try std.testing.expectEqual(@as(usize, 9), fixture.tlsNotes());
        try std.testing.expectEqual(@as(usize, 0), fixture.accepted.load(.acquire));
        // Cancellation at the first chunk of wait nine, rather than its full 4–5 seconds.
        try std.testing.expect(fixture.probe.waited_ms <= 24_788);
        try fixture.expectReleased();
    }
}

test "TLS outage budget: ordinary transport still gets exactly six attempts after TLS recovery" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    // URI construction fails deterministically, without a network call, after the injected TLS failures.
    fixture.agent.provider.url = ":invalid";
    clients.injectConstructionTlsThroughGenerationForTest(7);

    try std.testing.expectError(error.ApiError, fixture.agent.request(null));
    try std.testing.expectEqual(@as(usize, 8), fixture.tlsNotes());
    try std.testing.expect(std.mem.indexOf(u8, fixture.agent.last_api_error.?, "gave up after 6 attempts") != null);
    // Eight TLS retries plus five ordinary retries, not a new 16-attempt transport budget.
    try std.testing.expectEqual(@as(usize, 13), std.mem.count(u8, fixture.trace_output.written(), "\"ev\":\"retry\""));
    try fixture.expectReleased();
}

test "TLS outage budget: throttles still get exactly five attempts after TLS recovery" {
    for ([_][]const u8{ "429 Too Many Requests", "503 Service Unavailable" }) |status| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const reply: transport.Reply = .{ .status = status, .body = "{\"error\":{\"message\":\"try later\"}}" };
        const replies = [_]transport.Reply{ reply, reply, reply, reply, reply };
        fixture.serve(&replies);
        clients.injectConstructionTlsThroughGenerationForTest(7);

        try std.testing.expectError(error.ApiError, fixture.agent.request(null));
        try std.testing.expectEqual(@as(usize, 8), fixture.tlsNotes());
        try std.testing.expectEqual(@as(usize, 5), fixture.accepted.load(.acquire));
        try std.testing.expect(std.mem.indexOf(u8, fixture.agent.last_api_error.?, "gave up after 5 attempts") != null);
        try fixture.expectReleased();
    }
}

test "TLS outage budget: terminal authentication and quota remain fail-fast after TLS recovery" {
    const cases = [_]struct { reply: transport.Reply, err: anyerror }{
        .{ .reply = .{ .status = "401 Unauthorized", .body = "{}" }, .err = error.ProviderAuthenticationFailed },
        .{ .reply = .{ .status = "429 Too Many Requests", .body = "{\"error\":{\"code\":\"insufficient_quota\"}}" }, .err = error.ProviderQuotaExceeded },
    };
    for (cases) |case| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const replies = [_]transport.Reply{case.reply};
        fixture.serve(&replies);
        clients.injectConstructionTlsThroughGenerationForTest(7);

        try std.testing.expectError(case.err, fixture.agent.request(null));
        try std.testing.expectEqual(@as(usize, 8), fixture.tlsNotes());
        try std.testing.expectEqual(@as(usize, 1), fixture.accepted.load(.acquire));
        try fixture.expectReleased();
    }
}
