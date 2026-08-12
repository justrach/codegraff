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
const Agent = agent_mod.Agent;

/// The interactive status line printed before each human turn: model,
/// mode/permission badges, cwd, and the live context/cache/cost meter.
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
        // The Fast badge is a `responses`-shaped concept; on any other wire
        // format the flag exists but means nothing, so no badge is offered.
        .fast = self.fast and self.provider.kind == .responses,
        .fallback = self.fallback_active,
        .plan = main_mod.plan_mode,
        .strict = self.strict,
        .ultracode = self.ultracode_mode,
    };
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
