//! Agent.prompt(): the engine half of the interactive status line (#209, #429).
//!
//! It reads the session's state and emits ONE `.prompt_ready` event; how that
//! is drawn — palette, badge frame, the width budget that decides which
//! segments survive a narrow pane — belongs to agent_prompt_render.zig behind
//! the sink. Split out of agent.zig (600-line goal); agent_mod is only imported
//! for the `Agent` type the moved method's `self` parameter needs — see
//! agent_table.zig for the same self-contained-sibling pattern.

const std = @import("std");
const main_mod = @import("main.zig");
const pricing = @import("pricing.zig");
const learning_privacy = @import("learning_privacy.zig");
const engine_events = @import("engine_events.zig");
const engine_sink = @import("engine_sink.zig");
const agent_mod = @import("agent.zig");
const goal_state = @import("goal_state.zig");
const session_index = @import("session_index.zig");
const util = @import("util.zig");
const Agent = agent_mod.Agent;

/// The interactive status line printed before each human turn: model,
/// mode/permission badges, cwd, the live context/cache/cost meter, and
/// (when present) a standing-work row for goal / todos / image / session.
pub fn prompt(self: *Agent) !void {
    if (main_mod.json_mode) return; // SDK drives turns; no human prompt
    if (self.out == null) return; // nothing to draw on
    engine_sink.forAgent(self).emit(self.io, .{ .prompt_ready = status(self) });
}

/// Snapshot the session as the status line describes it. Every field is
/// semantic: no widths, no colors, no assembled segments.
fn status(self: *Agent) engine_events.PromptStatus {
    return .{
        .model = self.provider.model,
        .provider_id = self.provider.id,
        .cwd = main_mod.g_cwd_display,
        .privacy_label = learning_privacy.current().badge(),
        .privacy = privacyTier(learning_privacy.current()),
        .effort = effectiveEffort(self),
        // The meter appears only once a response has reported usage, but the
        // count it shows is the EFFECTIVE one (local estimates carry it
        // between turns) — two different questions, as it has always been.
        .context = if (self.last_context_tokens > 0) .{
            .tokens = self.effectiveContextTokens(),
            .window = self.provider.context,
            .compact_at = self.provider.compactAt(),
        } else null,
        .cache_read = self.last_cache_read,
        .cost = cost(self),
        // Fast priority is exclusive to the ChatGPT/Codex route; the official
        // OpenAI Platform Responses provider does not inherit that contract.
        .fast = self.fast and std.mem.eql(u8, self.provider.id, "codex"),
        .fallback = self.fallback_active,
        .plan = main_mod.plan_mode,
        .strict = self.strict,
        .ultracode = self.ultracode_mode,
        .standing = standing(self),
        .saved_sessions = @intCast(@min(session_index.countSavedSessions(self.io), std.math.maxInt(u32))),
    };
}

/// Facts the prompt row itself never carried: a standing goal, its
/// checklist, a staged image, a named session. Empty means skip the row.
fn standing(self: *const Agent) engine_events.StandingWork {
    var out: engine_events.StandingWork = .{};
    if (self.session_title) |t| {
        if (t.len > 0) out.session = t;
    }
    if (out.session.len == 0 and self.session_name.len > 0 and
        !std.mem.eql(u8, self.session_name, "last"))
        out.session = self.session_name;
    if (self.goal) |g| {
        if (g.status != .complete and g.objective.len > 0) {
            out.goal = g.objective;
            out.goal_status = switch (g.status) {
                .active => "",
                .paused => "paused",
                .blocked => "blocked",
                .complete => "",
            };
        }
    }
    const epoch = goal_state.currentEpoch(self.goal);
    var items: std.ArrayList(engine_events.StandingTodo) = .empty;
    for (self.todos.items) |t| {
        if (t.epoch != epoch or t.retired) continue;
        out.todos_total += 1;
        const done = std.mem.eql(u8, t.status, "completed");
        const active = std.mem.eql(u8, t.status, "in_progress");
        if (done) out.todos_done += 1;
        if (items.items.len < 8) {
            items.append(self.arena, .{
                .content = util.utf8Prefix(t.content, 48),
                .done = done,
                .active = active,
            }) catch {};
        }
    }
    out.todos = items.items;
    out.image = self.pending_image != null;
    return out;
}

/// Same order of questions the inline meter asked: off, then flat-rate, then
/// unpriced, and only then is a real figure snapshotted.
fn cost(self: *Agent) engine_events.CostMeter {
    if (!main_mod.show_cost) return .hidden;
    if (std.mem.eql(u8, self.provider.id, "codex")) return .subscription;
    if (pricing.priceFor(self.provider.model) == null) return .unpriced;
    return .{ .usd = pricing.g_cost.snap(self.io).usd };
}

// Both maps are exhaustive on purpose: a new tier upstream becomes a compile
// error here rather than a silently mistranslated badge.

fn effortTier(effort: main_mod.ReasoningEffort) engine_events.ReasoningEffort {
    return switch (effort) {
        .low => .low,
        .medium => .medium,
        .high => .high,
        .xhigh => .xhigh,
        .max => .max,
        .ultra => .ultra,
    };
}

/// The badge names the effort that will actually go on the wire. Kimi
/// normalizes the session knob against the catalog's allow-list (k3 allows
/// low/high/max with default max, so a Medium session sends "max"); showing
/// the raw knob would badge "Medium" over a request that runs at "max".
fn effectiveEffort(self: *Agent) ?engine_events.ReasoningEffort {
    if (std.mem.eql(u8, self.provider.id, "kimi")) {
        const wire = pricing.kimiThinkingEffort(self.provider.model, @tagName(self.reasoning)) orelse
            return null;
        inline for (std.meta.tags(main_mod.ReasoningEffort)) |tag| {
            if (std.mem.eql(u8, @tagName(tag), wire)) return effortTier(tag);
        }
        return null;
    }
    return if (self.effortApplies()) effortTier(self.reasoning) else null;
}

fn privacyTier(mode: learning_privacy.Mode) engine_events.PrivacyTier {
    return switch (mode) {
        .local => .local,
        .aggregate => .aggregate,
        .templates => .templates,
        .examples => .examples,
    };
}

test "the vocabulary's tiers stay in step with the engine's own enums" {
    // effortTier/privacyTier exist so engine_events.zig owns its value types
    // without importing main.zig. That only holds while the two sets agree:
    // a tier added on one side and not the other would render as the wrong
    // badge, which no test of either enum alone would catch.
    try std.testing.expectEqual(
        std.meta.tags(main_mod.ReasoningEffort).len,
        std.meta.tags(engine_events.ReasoningEffort).len,
    );
    try std.testing.expectEqual(
        std.meta.tags(learning_privacy.Mode).len,
        std.meta.tags(engine_events.PrivacyTier).len,
    );
    inline for (std.meta.tags(main_mod.ReasoningEffort)) |e| {
        try std.testing.expectEqualStrings(@tagName(e), @tagName(effortTier(e)));
    }
    inline for (std.meta.tags(learning_privacy.Mode)) |m| {
        try std.testing.expectEqualStrings(@tagName(m), @tagName(privacyTier(m)));
    }
}

test "kimi effort badge names the normalized wire effort, not the raw knob" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const messages = std.json.Array.init(arena);
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "kimi", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "k3", .context = 1_048_576 },
        .messages = messages,
        .sub = false,
        .label = "",
        .out = null,
        .sys_normal = "",
    };
    // k3 allows low/high/max with default high: a Medium session runs at the
    // catalog default, while an allowed effort passes through untouched.
    agent.reasoning = .medium;
    try std.testing.expectEqual(engine_events.ReasoningEffort.high, effectiveEffort(&agent).?);
    agent.reasoning = .max;
    try std.testing.expectEqual(engine_events.ReasoningEffort.max, effectiveEffort(&agent).?);
    // No catalog row, no wire effort, no badge.
    agent.provider.model = "unknown-xyz";
    try std.testing.expectEqual(@as(?engine_events.ReasoningEffort, null), effectiveEffort(&agent));
}

test "standing work snapshots goal, checklist, session, and a staged image" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "xai", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "grok-4", .context = 200_000 },
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "",
        .out = null,
        .sys_normal = "",
    };
    defer agent.todos.deinit(agent.gpa);

    // Default session `last` and no goal: the standing row stays empty.
    var sw = standing(&agent);
    try std.testing.expectEqualStrings("", sw.session);
    try std.testing.expectEqualStrings("", sw.goal);
    try std.testing.expectEqual(@as(u32, 0), sw.todos_total);
    try std.testing.expect(!sw.image);

    agent.session_name = "login-fix";
    agent.session_title = "fix the login flash";
    agent.goal = .{ .objective = "ship the repl standing line", .status = .paused, .epoch = 1 };
    try agent.todos.append(agent.gpa, .{ .content = "done item", .status = "completed", .epoch = 1 });
    try agent.todos.append(agent.gpa, .{ .content = "open item", .status = "pending", .epoch = 1 });
    try agent.todos.append(agent.gpa, .{ .content = "parked other goal", .status = "pending", .epoch = 0 });
    try agent.todos.append(agent.gpa, .{ .content = "retired", .status = "completed", .epoch = 1, .retired = true });
    agent.pending_image = .{ .media_type = "image/png", .b64 = "xx", .label = "shot.png" };

    sw = standing(&agent);
    try std.testing.expectEqualStrings("fix the login flash", sw.session);
    try std.testing.expectEqualStrings("ship the repl standing line", sw.goal);
    try std.testing.expectEqualStrings("paused", sw.goal_status);
    try std.testing.expectEqual(@as(u32, 2), sw.todos_total);
    try std.testing.expectEqual(@as(u32, 1), sw.todos_done);
    try std.testing.expectEqual(@as(usize, 2), sw.todos.len);
    try std.testing.expectEqualStrings("done item", sw.todos[0].content);
    try std.testing.expect(sw.todos[0].done);
    try std.testing.expectEqualStrings("open item", sw.todos[1].content);
    try std.testing.expect(!sw.todos[1].done);
    try std.testing.expect(sw.image);

    // A completed goal is not standing work; the default session name stays hidden.
    agent.goal.?.status = .complete;
    agent.session_title = null;
    agent.session_name = "last";
    agent.pending_image = null;
    sw = standing(&agent);
    try std.testing.expectEqualStrings("", sw.goal);
    try std.testing.expectEqualStrings("", sw.session);
    try std.testing.expect(!sw.image);
}
