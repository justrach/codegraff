//! Per-agent, one-at-a-time effort changes selected by the optional Jev tool.
//! Pool threads only queue a selection; the owning Agent applies it at a
//! request boundary. An admission token prevents canceled work from reviving
//! a cleared selection or racing a later tool call.
const std = @import("std");
const Io = std.Io;
const Provider = @import("provider.zig").Provider;
const ReasoningEffort = @import("main.zig").ReasoningEffort;

pub const Pending = struct {
    mu: Io.Mutex = .init,
    phase: enum { idle, in_flight, selected } = .idle,
    token: u64 = 0,
    provider_len: usize = 0,
    model_len: usize = 0,
    provider: [64]u8 = undefined,
    model: [256]u8 = undefined,
    effort: ReasoningEffort = .medium,

    pub fn begin(self: *Pending, io: Io, route: Provider) ?u64 {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        if (self.phase != .idle or route.id.len > self.provider.len or route.model.len > self.model.len) return null;
        self.token +%= 1;
        @memcpy(self.provider[0..route.id.len], route.id);
        @memcpy(self.model[0..route.model.len], route.model);
        self.provider_len = route.id.len;
        self.model_len = route.model.len;
        self.phase = .in_flight;
        return self.token;
    }

    pub fn commit(self: *Pending, io: Io, token: u64, effort: ReasoningEffort) bool {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        if (self.phase != .in_flight or self.token != token) return false;
        self.effort = effort;
        self.phase = .selected;
        return true;
    }

    pub fn abort(self: *Pending, io: Io, token: u64) void {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        if (self.phase == .in_flight and self.token == token) self.phase = .idle;
    }

    pub fn take(self: *Pending, io: Io, route: Provider) ?ReasoningEffort {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        if (self.phase != .selected) return null;
        self.phase = .idle;
        if (!std.mem.eql(u8, route.id, self.provider[0..self.provider_len]) or
            !std.mem.eql(u8, route.model, self.model[0..self.model_len])) return null;
        return self.effort;
    }

    pub fn invalidate(self: *Pending, io: Io) void {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        self.token +%= 1;
        self.phase = .idle;
    }
};

pub fn applyToState(agent: anytype) bool {
    const effort = agent.jev_effort_pending.take(agent.io, agent.provider) orelse return false;
    if (!@import("effort_route.zig").allows(agent.provider.id, agent.provider.model, @tagName(effort))) return false;
    agent.reasoning = effort;
    return true;
}

pub fn apply(agent: anytype) void {
    if (!applyToState(agent)) return;
    _ = @import("repl_glue.zig").saveThinkingSettings(agent.io, agent.gpa, agent.reasoning, agent.fast, agent.ultracode_mode, agent.show_thinking, agent.ai_title);
}

pub fn finishTurn(agent: anytype) void {
    if (@TypeOf(agent.*).esc_cancel.load(.acquire) or @import("acp_engine.zig").cancel_flag.load(.acquire))
        agent.jev_effort_pending.invalidate(agent.io)
    else
        apply(agent);
}

test "pending effort is per agent, first admission wins, and stale routes or tokens do not apply" {
    const p: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-6-sol", .context = 100_000 };
    var a: Pending = .{};
    var b: Pending = .{};
    const first = a.begin(std.testing.io, p).?;
    try std.testing.expect(a.begin(std.testing.io, p) == null);
    const other = b.begin(std.testing.io, p).?;
    a.abort(std.testing.io, first);
    const second = a.begin(std.testing.io, p).?;
    try std.testing.expect(!a.commit(std.testing.io, first, .high));
    try std.testing.expect(a.commit(std.testing.io, second, .high));
    try std.testing.expect(b.commit(std.testing.io, other, .low));
    try std.testing.expectEqual(ReasoningEffort.low, b.take(std.testing.io, p).?);
    var changed = p;
    changed.model = "gpt-6-luna";
    try std.testing.expect(a.take(std.testing.io, changed) == null);
    try std.testing.expect(a.take(std.testing.io, p) == null);
    const canceled = a.begin(std.testing.io, p).?;
    a.invalidate(std.testing.io);
    try std.testing.expect(!a.commit(std.testing.io, canceled, .none));
}
