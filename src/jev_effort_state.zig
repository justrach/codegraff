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
    /// ADR 0246: the selection in flight is jev_auto's turn pick, which applies
    /// for one turn and is never saved; the jev_effort tool's is the session's.
    turn_scoped: bool = false,
    /// #1320: true once the user explicitly chooses an effort (including medium).
    user_pinned: bool = false,
    /// ADR 0246: this agent's turn pick, owned by jev_auto.zig.
    auto: Auto = .{},

    pub const Auto = struct {
        future: ?Io.Future(void) = null,
        task: []u8 = &.{}, // gpa-owned summary the pick reads
        saved: ?ReasoningEffort = null, // the effort the turn started at
        applied: ?ReasoningEffort = null, // the pick a request boundary applied
        outcome: std.atomic.Value(u8) = .init(0), // 0 in flight, 1 picked, 2 unavailable
        picked: ReasoningEffort = .medium,
        ms: std.atomic.Value(u32) = .init(0),
    };

    pub const Taken = struct { effort: ReasoningEffort, turn: bool };

    pub fn begin(self: *Pending, io: Io, route: Provider) ?u64 {
        return self.beginScoped(io, route, false);
    }

    pub fn beginTurn(self: *Pending, io: Io, route: Provider) ?u64 {
        return self.beginScoped(io, route, true);
    }

    fn beginScoped(self: *Pending, io: Io, route: Provider, turn: bool) ?u64 {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        if (self.phase != .idle or route.id.len > self.provider.len or route.model.len > self.model.len) return null;
        self.turn_scoped = turn;
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
        return if (self.takeScoped(io, route)) |t| t.effort else null;
    }

    pub fn takeScoped(self: *Pending, io: Io, route: Provider) ?Taken {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        if (self.phase != .selected) return null;
        self.phase = .idle;
        if (!std.mem.eql(u8, route.id, self.provider[0..self.provider_len]) or
            !std.mem.eql(u8, route.model, self.model[0..self.model_len])) return null;
        return .{ .effort = self.effort, .turn = self.turn_scoped };
    }

    /// Drop a turn pick no request has applied: it is neither applied nor saved.
    pub fn dropTurn(self: *Pending, io: Io) void {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        if (!self.turn_scoped or self.phase == .idle) return;
        self.token +%= 1;
        self.phase = .idle;
    }

    pub fn invalidate(self: *Pending, io: Io) void {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        self.token +%= 1;
        self.phase = .idle;
    }

    pub fn pinUserEffort(self: *Pending, io: Io) void {
        self.invalidate(io);
        self.user_pinned = true;
        @import("prompt_cache_hud.zig").noteBust(.effort);
    }
};

pub fn applyToState(agent: anytype) bool {
    return applyTaken(agent) != null;
}

fn applyTaken(agent: anytype) ?Pending.Taken {
    const t = agent.jev_effort_pending.takeScoped(agent.io, agent.provider) orelse return null;
    if (!@import("effort_route.zig").allows(agent.provider.id, agent.provider.model, @tagName(t.effort))) return null;
    if (!agent.sub and agent.reasoning != t.effort) @import("prompt_cache_hud.zig").noteBust(.effort);
    agent.reasoning = t.effort;
    return t;
}

pub fn apply(agent: anytype) void {
    const t = applyTaken(agent) orelse return;
    if (t.turn) {
        agent.jev_effort_pending.auto.applied = t.effort; // ADR 0246: a turn pick holds for this turn, never saved
        return;
    }
    if (agent.sub) return; // ADR 0232: a child's selection is its own; the saved effort is the root's
    _ = @import("repl_glue.zig").saveThinkingSettings(agent.io, agent.gpa, agent.reasoning, agent.fast, agent.ultracode_mode, agent.show_thinking, agent.ai_title);
}

pub fn finishTurn(agent: anytype) void {
    @import("jev_auto.zig").endTurn(agent); // ADR 0246: before apply(), so a turn's pick is never saved
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
