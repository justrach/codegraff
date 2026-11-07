//! #1665: JSON model-call lifecycle. Every `model_call_started` pairs with one
//! `model_call_finished`. A request rebuilt before its response (a WebSocket
//! reanchor, a stream reconnect, a steer, a recovered overflow) closes the
//! attempt with ok=false and retried=true before the next one starts; an
//! attempt that ends the request with an error closes with ok=false.

const main_mod = @import("main.zig");
const Agent = @import("agent.zig").Agent;

pub const Call = struct {
    open: bool = false,

    fn on(self: *Agent) bool {
        return main_mod.json_mode and !self.sub;
    }

    pub fn start(c: *Call, self: *Agent) void {
        if (!on(self)) return;
        if (c.open) c.fail(self, true);
        self.emit(.{ .type = "model_call_started", .provider = self.provider.id, .model = self.provider.model });
        c.open = true;
    }

    pub fn finish(c: *Call, self: *Agent, ms: i64) void {
        if (!c.open) return;
        c.open = false;
        self.emit(.{ .type = "model_call_finished", .provider = self.provider.id, .model = self.provider.model, .ok = true, .ms = ms });
    }

    /// The attempt ended without a usable response. `retried`: the request
    /// goes out again as a new attempt.
    pub fn fail(c: *Call, self: *Agent, retried: bool) void {
        if (!c.open) return;
        c.open = false;
        const ms: i64 = if (self.request_started) |t0| t0.untilNow(self.io, .awake).toMilliseconds() else 0;
        self.emit(.{ .type = "model_call_finished", .provider = self.provider.id, .model = self.provider.model, .ok = false, .ms = ms, .retried = retried });
    }
};

test "every started model call pairs with one finished event" {
    const std = @import("std");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var agent = try @import("agent_request_body_responses.zig").testAgentFor(arena_state.allocator(), "codex", .responses, "gpt-5");
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    agent.out = &w;
    const was_json = main_mod.json_mode;
    main_mod.json_mode = true;
    defer main_mod.json_mode = was_json;

    var call: Call = .{};
    call.start(&agent); // first attempt
    call.start(&agent); // rebuilt after a reanchor: closes the first
    call.finish(&agent, 12);
    call.finish(&agent, 12); // already closed: no second event
    call.start(&agent);
    call.fail(&agent, false); // the request ended with an error
    call.fail(&agent, false);

    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "\"model_call_started\""));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "\"model_call_finished\""));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\"retried\":true"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\"retried\":false"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\"ok\":true"));
}
