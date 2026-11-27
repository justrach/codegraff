//! Native Same-Chat Plan -> Execute Baton Handoff ("Orchestrator Mode").
//!
//! Coordinates three runtime modes (`off` | `auto` | `on`), atomic project
//! settings persistence in `.harness/settings.json`, session-overlay specs for
//! `exit_plan_mode` / `enter_plan_mode`, same-provider/same-wire executor seat
//! selection, and auto-classification backed by `orchestration_policy`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const Agent = @import("agent.zig").Agent;
const provider_mod = @import("provider.zig");
const Provider = provider_mod.Provider;
const ReasoningEffort = main_mod.ReasoningEffort;
const tools = @import("tools.zig");
const pricing = @import("pricing.zig");
const tier_ladder = @import("subagent_tier_ladder.zig");
const subagent_pin = @import("subagent_pin.zig");
const model_maker = @import("model_maker.zig");
const no_local_tools = @import("no_local_tools.zig");
const shapes = @import("shapes.zig");
const task_intent = @import("task_intent.zig");
const route_policy = @import("route_policy.zig");
const orch = @import("orchestration_policy.zig");

pub const settings_path = ".harness/settings.json";
pub const settings_field = "orchestrator";
pub const exit_tool_name = "exit_plan_mode";
pub const enter_tool_name = "enter_plan_mode";

pub const Mode = enum {
    off,
    auto,
    on,

    pub fn parse(raw: []const u8) ?Mode {
        const s = std.mem.trim(u8, raw, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(s, "off") or std.mem.eql(u8, s, "0") or
            std.ascii.eqlIgnoreCase(s, "false") or std.ascii.eqlIgnoreCase(s, "no")) return .off;
        if (std.ascii.eqlIgnoreCase(s, "auto")) return .auto;
        if (std.ascii.eqlIgnoreCase(s, "on") or std.mem.eql(u8, s, "1") or
            std.ascii.eqlIgnoreCase(s, "true") or std.ascii.eqlIgnoreCase(s, "yes")) return .on;
        return null;
    }

    pub fn label(self: Mode) []const u8 {
        return @tagName(self);
    }

    pub fn displayLabel(self: Mode) []const u8 {
        return switch (self) {
            .off => "Off",
            .auto => "Auto",
            .on => "On",
        };
    }
};

pub const Phase = enum { none, planning, executing };

/// Compiled default; Step 5 benchmark updates this if another mode wins.
pub const default_mode: Mode = .auto;

pub var g_mode: Mode = default_mode;
pub var cli_set: bool = false;
pub var env_set: bool = false;
pub var g_phase: Phase = .none;
pub var handoff_active: bool = false;
pub var g_handoff_plan: ?[]const u8 = null;
pub var g_replan_reason: ?[]const u8 = null;
pub var g_replan_exhausted: bool = false;

pub fn setFromCli(mode: Mode) void {
    g_mode = mode;
    cli_set = true;
}

pub fn applyEnv(raw: ?[]const u8) void {
    if (cli_set) return;
    const v = raw orelse return;
    if (Mode.parse(v)) |m| {
        g_mode = m;
        env_set = true;
    }
}

pub fn loadSettings(io: Io, arena: Allocator) void {
    loadSettingsFrom(io, Io.Dir.cwd(), arena);
}

pub fn loadSettingsFrom(io: Io, dir: Io.Dir, arena: Allocator) void {
    if (cli_set or env_set) return;
    const text = dir.readFileAlloc(io, settings_path, arena, .limited(1024 * 1024)) catch return;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return;
    if (v != .object) return;
    const raw = v.object.get(settings_field) orelse return;
    if (raw != .string) return;
    if (Mode.parse(raw.string)) |m| g_mode = m;
}

pub fn saveSettings(io: Io, arena: Allocator, mode: Mode) !void {
    try saveSettingsAt(io, Io.Dir.cwd(), arena, mode);
}

pub fn saveSettingsAt(io: Io, dir: Io.Dir, arena: Allocator, mode: Mode) !void {
    const existing = dir.readFileAlloc(io, settings_path, arena, .limited(1024 * 1024)) catch "{}";
    var obj: std.json.ObjectMap = .empty;
    if (std.json.parseFromSliceLeaky(std.json.Value, arena, existing, .{})) |v| {
        if (v == .object) obj = v.object;
    } else |_| {}
    try obj.put(arena, settings_field, .{ .string = mode.label() });
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(std.json.Value{ .object = obj });
    aw.writer.writeByte('\n') catch {};
    if (std.fs.path.dirname(settings_path)) |sub| dir.createDirPath(io, sub) catch {};
    try @import("credential_store.zig").replaceFile(io, dir, settings_path, aw.writer.buffered(), .default_file);
    g_mode = mode;
}

pub const exit_tool_desc = "Hand off a completed read-only implementation plan to the executor model in this conversation. Call alone once you have inspected the relevant files and prepared concrete edits and verification steps; Phase 2 immediately runs on the executor seat.";
pub const exit_tool_schema =
    \\{"type":"object","properties":{"plan":{"type":"string","description":"Concrete step-by-step implementation plan naming target files, exact changes, and verification commands."}},"required":["plan"]}
;

pub const enter_tool_desc = "Escalate back to the planner model in this conversation when execution encounters a missing assumption, design choice, or repeated check failure that requires replanning. Call alone with the concrete blocker in reason.";
pub const enter_tool_schema =
    \\{"type":"object","properties":{"reason":{"type":"string","description":"Concrete blocker, mismatch, or failed verification output requiring planner review."}},"required":["reason"]}
;

pub fn isMetaTool(name: []const u8) bool {
    return std.mem.eql(u8, name, exit_tool_name) or std.mem.eql(u8, name, enter_tool_name);
}

/// Append both baton tools only while an orchestrator turn is active so the
/// base catalog cube stays untouched and Phase 1 -> Phase 2 share an identical
/// tool schema prefix for KV cache reuse.
pub fn maybeAppendSpecs(comptime Spec: type, arena: Allocator, specs: []const Spec) ![]const Spec {
    if (!handoff_active or no_local_tools.enabled) return specs;
    var has_exit = false;
    var has_enter = false;
    for (specs) |s| {
        if (std.mem.eql(u8, s.name, exit_tool_name)) has_exit = true;
        if (std.mem.eql(u8, s.name, enter_tool_name)) has_enter = true;
    }
    const add: usize = @as(usize, @intFromBool(!has_exit)) + @as(usize, @intFromBool(!has_enter));
    if (add == 0) return specs;
    const buf = try arena.alloc(Spec, specs.len + add);
    @memcpy(buf[0..specs.len], specs);
    var idx = specs.len;
    if (!has_exit) {
        buf[idx] = .{ .name = exit_tool_name, .desc = exit_tool_desc, .schema = exit_tool_schema };
        idx += 1;
    }
    if (!has_enter) {
        buf[idx] = .{ .name = enter_tool_name, .desc = enter_tool_desc, .schema = enter_tool_schema };
    }
    return buf;
}

pub fn rejectMixedBatch(self: *Agent, calls: []const tools.ToolCall, results: []tools.ExecResult) !bool {
    if (calls.len <= 1) return false;
    for (calls) |call| if (isMetaTool(call.name)) {
        const text = "orchestrator baton handoff tool must run alone; this batch was rejected";
        for (calls, results) |c, *r| {
            self.emitToolRejected(c, "handoff_boundary", text);
            r.* = .{ .text = text, .is_error = true };
        }
        return true;
    };
    return false;
}

pub fn handleMeta(self: *Agent, call: tools.ToolCall) !tools.ExecResult {
    if (std.mem.eql(u8, call.name, exit_tool_name)) {
        if (self.sub) return .{ .text = "exit_plan_mode is root-only", .is_error = true };
        if (!handoff_active or g_phase != .planning) {
            return .{ .text = "exit_plan_mode is only active during Phase 1 planning in orchestrator mode", .is_error = true };
        }
        const obj = tools.json_args.object(call.input) orelse return .{ .text = "exit_plan_mode requires a nonempty plan", .is_error = true };
        const raw = tools.json_args.str(obj, "plan") orelse return .{ .text = "exit_plan_mode requires a nonempty plan", .is_error = true };
        if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return .{ .text = "exit_plan_mode requires a nonempty plan", .is_error = true };
        const plan = try @import("cite_markup.zig").dupe(self.arena, raw);
        g_handoff_plan = plan;
        self.yielded = plan;
        return .{ .text = "plan recorded; switching to executor seat to implement and verify.", .is_error = false };
    }
    if (self.sub) return .{ .text = "enter_plan_mode is root-only", .is_error = true };
    if (!handoff_active or g_phase != .executing) {
        return .{ .text = "enter_plan_mode is only active during Phase 2 execution in orchestrator mode", .is_error = true };
    }
    if (g_replan_exhausted) {
        return .{ .text = "replan limit reached for this turn; finish or report exact blockers directly on this seat.", .is_error = true };
    }
    const obj = tools.json_args.object(call.input) orelse return .{ .text = "enter_plan_mode requires a nonempty reason", .is_error = true };
    const raw = tools.json_args.str(obj, "reason") orelse return .{ .text = "enter_plan_mode requires a nonempty reason", .is_error = true };
    if (std.mem.trim(u8, raw, " \t\r\n").len == 0) return .{ .text = "enter_plan_mode requires a nonempty reason", .is_error = true };
    const reason = try @import("cite_markup.zig").dupe(self.arena, raw);
    g_replan_reason = reason;
    self.yielded = reason;
    return .{ .text = "escalating back to planner for plan review.", .is_error = false };
}

fn acceptCandidate(planner: Provider, cand: []const u8) ?Provider {
    if (pricing.modelAliasEquals(planner.model, cand)) return null;
    const served = pricing.providerModelInTable(planner.id, cand) or subagent_pin.rungAffordableOn(planner, cand);
    if (!served) return null;
    if (!tier_ladder.cheaperSeat(planner.model, cand)) return null;
    const built = planner.withModel(cand);
    if (built.kind != planner.kind) return null;
    return built;
}

fn firstAccepted(planner: Provider, cands: []const []const u8) ?Provider {
    for (cands) |c| if (acceptCandidate(planner, c)) |p| return p;
    return null;
}

/// Resolve a strictly same-provider, same-wire executor 1 rung down so
/// Phase 1 -> Phase 2 keeps conversation shape and KV-cache prefix intact.
pub fn resolveExecutor(planner: Provider, reasoning: ReasoningEffort) ?Provider {
    _ = reasoning;
    if (std.mem.eql(u8, planner.id, "custom") or provider_mod.specFor(planner.id) == null) return null;
    if (tier_ladder.forModel(planner.id, planner.model)) |l| {
        const matches_ladder = l.isFrontier(planner.model) or
            pricing.modelAliasEquals(l.frontier, planner.model) or
            (l.mid != null and pricing.modelAliasEquals(l.mid.?, planner.model)) or
            (l.small != null and pricing.modelAliasEquals(l.small.?, planner.model));
        if (matches_ladder) {
            const cand: ?[]const u8 = if (l.isFrontier(planner.model) or pricing.modelAliasEquals(l.frontier, planner.model))
                l.mid orelse l.small
            else if (l.mid != null and pricing.modelAliasEquals(l.mid.?, planner.model))
                l.small
            else
                null;
            return if (cand) |c| acceptCandidate(planner, c) else null;
        }
    }
    const maker = model_maker.of(planner.id, planner.model) orelse return null;
    if (std.mem.eql(u8, maker, "anthropic")) {
        if (pricing.modelAliasEquals(planner.model, "claude-opus-5-5") or
            pricing.modelAliasEquals(planner.model, "claude-fable-5-2"))
            return acceptCandidate(planner, "claude-sonnet-5-5");
        if (pricing.modelAliasEquals(planner.model, "claude-sonnet-5-5"))
            return acceptCandidate(planner, "claude-haiku-5-5");
        return null;
    }
    if (std.mem.eql(u8, maker, "openai")) {
        if (pricing.modelAliasEquals(planner.model, "gpt-6.2-astra"))
            return firstAccepted(planner, &.{ "gpt-6.2-sol", "gpt-6.1-sol", "gpt-6-sol" });
        if (pricing.modelAliasEquals(planner.model, "gpt-6-astra"))
            return firstAccepted(planner, &.{ "gpt-6-sol", "gpt-6.1-sol", "gpt-6.2-sol" });
        if (pricing.modelAliasEquals(planner.model, "gpt-6-sol") or
            pricing.modelAliasEquals(planner.model, "gpt-6.1-sol") or
            pricing.modelAliasEquals(planner.model, "gpt-6.2-sol"))
            return acceptCandidate(planner, "gpt-6-luna");
        return null;
    }
    if (std.mem.eql(u8, maker, "google")) {
        if (pricing.modelAliasEquals(planner.model, "gemini-4-argon"))
            return firstAccepted(planner, &.{ "gemini-3.8-flash", "gemini-3.7-flash", "gemini-3-flash-preview" });
        if (std.mem.indexOf(u8, planner.model, "pro") != null)
            return firstAccepted(planner, &.{ "gemini-3-flash-preview", "gemini-3.8-flash", "gemini-3.7-flash" });
        return null;
    }
    if (std.mem.eql(u8, maker, "deepseek") and pricing.modelAliasEquals(planner.model, "deepseek-v4-pro")) {
        return acceptCandidate(planner, "deepseek-v4-flash");
    }
    if (std.mem.eql(u8, maker, "xiaomi") and pricing.modelAliasEquals(planner.model, "mimo-v2.6-pro")) {
        return acceptCandidate(planner, "mimo-v2.6-flash");
    }
    return null;
}

pub fn resolveTaskKey(root: *const Agent, user_text: []const u8) orch.Key {
    const remaining = if (root.run_budget) |b| b.remaining() else std.math.maxInt(u64);
    return .{
        .task_class = shapes.classOf(user_text),
        .budget_band = orch.BudgetBand.of(remaining),
        .stratum = route_policy.stratumOf(root.provider.model),
    };
}

fn containsFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn hasMultiStepCue(text: []const u8) bool {
    const cues = [_][]const u8{
        "across ",  "all ",    "refactor",   "architect",
        "pipeline", "feature", "end-to-end", "and then",
        "multiple",
    };
    for (cues) |c| if (containsFold(text, c)) return true;
    var dots: usize = 0;
    for ([_][]const u8{ ".zig", ".rs", ".ts", ".tsx", ".py", ".go", ".md", ".json" }) |ext| {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, text, pos, ext)) |hit| {
            dots += 1;
            pos = hit + ext.len;
            if (dots >= 2) return true;
        }
    }
    return false;
}

pub fn stripHarnessNotes(text: []const u8) []const u8 {
    var cut = text.len;
    const markers = [_][]const u8{
        "\n\n[standing state (",
        "\n\n[harness note:",
        "\n\n[pace:",
        "\n\nAttached images (",
        "\n\nAttached images:",
        "\n\nAttached files (",
        "\n\nAttached files:",
        "\n\nAttached documents (",
        "\n\nAttached documents:",
        "\n\nAttached PDFs (",
        "\n\nAttached PDFs:",
    };
    for (markers) |m| {
        if (std.mem.indexOf(u8, text, m)) |idx| cut = @min(cut, idx);
    }
    return text[0..cut];
}

pub fn shouldPlanAuto(root: *const Agent, user_text: []const u8) bool {
    const trimmed = std.mem.trim(u8, stripHarnessNotes(user_text), " \t\r\n");
    if (trimmed.len == 0) return false;
    // Never auto-enter a two-seat baton when history holds opaque server compaction
    // state: switching seats would expand the ciphertext back into raw history (#1906).
    if (@import("compaction_window.zig").latestBlob(root.messages.items) != null) return false;
    if (task_intent.classify(trimmed) == .informational) return false;
    const task_class = shapes.classOf(trimmed);
    if (!task_intent.requestsAction(trimmed) and task_class != .bugfix and task_class != .feature and task_class != .refactor) return false;
    const trivial = trimmed.len < 60 and !hasMultiStepCue(trimmed) and task_class != .refactor;
    const heuristic: orch.Rung = if (trivial and (task_class != .feature or !hasMultiStepCue(trimmed))) .R0 else .baton;
    const remaining = if (root.run_budget) |b| b.remaining() else std.math.maxInt(u64);
    const chosen = orch.learnedRung(resolveTaskKey(root, trimmed), heuristic, remaining, 2) orelse heuristic;
    return chosen == .baton;
}
