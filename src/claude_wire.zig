//! Per-model rules for the Claude Messages API (ADR 0219). A Claude model id
//! is `claude-<family>-<major>[-<minor>][-<date>]`; the rules below turn on
//! by family and version, so a later release inherits them.
//!
//! - Forced tool use: Claude Opus 5.5, Sonnet 5.5 and Fable 5.1 reject
//!   `tool_choice` any/tool with a 400. graff forces only older models.
//! - Thinking prefix binding: from Fable 5.1 (and Opus 5.5, Sonnet 5.5) a
//!   replayed thinking block is checked against the prefix it was produced
//!   under. graff edits that prefix mid-session (tools change when an MCP
//!   server joins; compaction rewrites history), which new accounts see as a
//!   400. `drop_block` has the API drop stale blocks instead.
//! - Effort: `output_config.effort`, on models that take it. A 5.5-era model
//!   gets graff's level as shown, medium included (ADR 0220); an older one
//!   keeps its own default at graff's default. Titles and recaps run at low.
//! - max_tokens covers thinking plus text on always-thinking models: 64K, and
//!   the 128K maximum at the top efforts, as Anthropic measured and advises.

const std = @import("std");
const ReasoningEffort = @import("main.zig").ReasoningEffort;
const CallKind = @import("run_budget.zig").CallKind;

pub const Family = enum { opus, sonnet, haiku, fable, mythos };
pub const Version = struct { family: Family, major: u16, minor: u16 };

/// The beta that enables `thinking.block_binding`.
pub const binding_beta = "thinking-binding-controls-2026-08-01";

/// Requests that speak the real Anthropic Messages API: the direct anthropic
/// provider, and Claude models on the codegraff gateway (native /v1/messages).
/// Other Anthropic-format providers (minimax, kimi) keep their own quirks.
pub fn isClaudeApi(provider_id: []const u8, model: []const u8) bool {
    return std.mem.eql(u8, provider_id, "anthropic") or
        @import("provider_codegraff.zig").usesMessages(provider_id, model);
}

/// Parse `claude-opus-5-5`, `claude-sonnet-4-6-20260101`, `claude-fable-5`.
pub fn version(model: []const u8) ?Version {
    const rest = if (std.mem.startsWith(u8, model, "claude-")) model["claude-".len..] else return null;
    var it = std.mem.splitScalar(u8, rest, '-');
    const family = std.meta.stringToEnum(Family, it.next() orelse return null) orelse return null;
    const major = std.fmt.parseInt(u16, it.next() orelse return null, 10) catch return null;
    // A minor is one or two digits; an 8-digit date is not a minor.
    const minor: u16 = if (it.next()) |part|
        (if (part.len <= 2) std.fmt.parseInt(u16, part, 10) catch 0 else 0)
    else
        0;
    return .{ .family = family, .major = major, .minor = minor };
}

fn atLeast(v: Version, major: u16, minor: u16) bool {
    return v.major > major or (v.major == major and v.minor >= minor);
}

/// The 5.5-era contract: no forced tool use, prefix-bound thinking.
fn fiveFiveEra(model: []const u8) bool {
    const v = version(model) orelse return false;
    return switch (v.family) {
        .opus, .sonnet => atLeast(v, 5, 5),
        .fable, .mythos => atLeast(v, 5, 1),
        .haiku => false,
    };
}

/// Haiku 5.5 thinks adaptively and takes effort and the binding field like the
/// 5.5-era models, but still accepts a forced tool (probed against the API).
fn haikuFiveFive(model: []const u8) bool {
    const v = version(model) orelse return false;
    return v.family == .haiku and atLeast(v, 5, 5);
}

/// `tool_choice` any/tool returns a 400 on this model.
pub fn rejectsForcedTools(model: []const u8) bool {
    return fiveFiveEra(model);
}

/// The API checks replayed thinking against its prefix on this model.
/// Mythos 5.1 does not run the check, but takes the field.
pub fn bindsThinking(model: []const u8) bool {
    return fiveFiveEra(model) or haikuFiveFive(model);
}

/// Whether `output_config.effort` is accepted (Opus 4.5 and later, Sonnet
/// 4.6 and later, every Fable and Mythos, Haiku 5.5 and later).
pub fn takesEffort(model: []const u8) bool {
    const v = version(model) orelse return false;
    return switch (v.family) {
        .opus => atLeast(v, 4, 5),
        .sonnet => atLeast(v, 4, 6),
        .fable, .mythos => true,
        .haiku => atLeast(v, 5, 5),
    };
}

/// graff's effort on the wire. A 5.5-era model gets the level graff shows,
/// medium included: Sonnet 5.5 and Fable 5.1 default to high, so leaving it
/// off ran them a level above the one on screen (ADR 0220). On Opus 5.5
/// medium is the default, which the API treats as unset. An older model keeps
/// its own default at graff's default, so a session that never ran /effort
/// does not move. `ultra` asks for the most there is.
pub fn effortWire(model: []const u8, effort: ReasoningEffort) ?[]const u8 {
    return switch (effort) {
        .none => null,
        .medium => if (fiveFiveEra(model) or haikuFiveFive(model)) "medium" else null,
        .low => "low",
        .high => "high",
        .xhigh => "xhigh",
        .max, .ultra => "max",
    };
}

/// A title or a recap is one line: it runs at low effort whatever the
/// session's level. Every other call keeps the session's effort, which the
/// prompt cache is keyed on (a compaction fork or /btw shares its prefix).
pub fn effortFor(model: []const u8, effort: ReasoningEffort, kind: CallKind) ?[]const u8 {
    if (kind == .title or kind == .recap) return "low";
    return effortWire(model, effort);
}

/// Thinking is on by default (Opus and Sonnet 5 and later, Haiku 5.5, Fable, Mythos):
/// max_tokens is spent on thinking before the answer.
pub fn thinksByDefault(model: []const u8) bool {
    const v = version(model) orelse return false;
    return switch (v.family) {
        .opus, .sonnet => atLeast(v, 5, 0),
        .fable, .mythos => true,
        .haiku => atLeast(v, 5, 5),
    };
}

/// Output budget, thinking included. Anthropic measured a 16K cap ending
/// about a quarter of Opus 5.5's agentic attempts and 43% of Fable 5.1's, at
/// no saving per solved task; it recommends 64K for agentic work and the
/// 128K maximum where a cut-off attempt is costly (the top efforts think
/// longest). graff always streams, which responses this size need.
/// Models without a 128K ceiling keep graff's default.
pub fn maxTokens(model: []const u8, effort: ReasoningEffort, default: u32) u32 {
    if (!thinksByDefault(model)) return default; // the 128K-output lineup
    return switch (effort) {
        .xhigh, .max, .ultra => 128_000,
        else => @max(default, 64_000),
    };
}

/// The `thinking` object for the Anthropic API. The summarized display keeps
/// the live Thinking panel readable (current models default to an empty
/// one); binding models also drop stale blocks instead of failing.
pub fn thinkingObject(model: []const u8) []const u8 {
    return if (bindsThinking(model))
        "{\"type\":\"adaptive\",\"display\":\"summarized\",\"block_binding\":{\"prefix_mismatch_behavior\":\"drop_block\"}}"
    else
        "{\"type\":\"adaptive\",\"display\":\"summarized\"}";
}

test "Claude model ids parse by family and version; dates are not minors" {
    const t = std.testing;
    try t.expectEqual(Version{ .family = .opus, .major = 5, .minor = 5 }, version("claude-opus-5-5").?);
    try t.expectEqual(Version{ .family = .opus, .major = 5, .minor = 0 }, version("claude-opus-5").?);
    try t.expectEqual(Version{ .family = .sonnet, .major = 4, .minor = 6 }, version("claude-sonnet-4-6-20260101").?);
    try t.expectEqual(Version{ .family = .sonnet, .major = 4, .minor = 0 }, version("claude-sonnet-4-20250514").?);
    try t.expectEqual(Version{ .family = .fable, .major = 5, .minor = 1 }, version("claude-fable-5-1").?);
    try t.expect(version("gpt-5.5") == null);
    try t.expect(version("claude-3-5-sonnet") == null);
}

test "5.5-era models are never forced to a tool and bind their thinking" {
    const t = std.testing;
    for ([_][]const u8{ "claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-opus-6" }) |m| {
        try t.expect(rejectsForcedTools(m));
        try t.expect(bindsThinking(m));
        try t.expect(std.mem.indexOf(u8, thinkingObject(m), "\"prefix_mismatch_behavior\":\"drop_block\"") != null);
    }
    for ([_][]const u8{ "claude-opus-5", "claude-sonnet-5", "claude-fable-5", "claude-opus-4-8", "claude-haiku-4-5" }) |m| {
        try t.expect(!rejectsForcedTools(m));
        try t.expect(!bindsThinking(m));
        try t.expect(std.mem.indexOf(u8, thinkingObject(m), "block_binding") == null);
    }
}

test "Haiku 5.5 binds its thinking but may still be forced to a tool" {
    const t = std.testing;
    try t.expect(bindsThinking("claude-haiku-5-5"));
    try t.expect(!rejectsForcedTools("claude-haiku-5-5"));
    try t.expect(thinksByDefault("claude-haiku-5-5"));
    try t.expect(!thinksByDefault("claude-haiku-4-5"));
}

test "effort goes on the wire only where it is taken; 5.5-era models get graff's level as shown" {
    const t = std.testing;
    try t.expect(takesEffort("claude-opus-5-5") and takesEffort("claude-sonnet-5-5") and takesEffort("claude-fable-5-1"));
    try t.expect(takesEffort("claude-opus-4-5") and takesEffort("claude-sonnet-4-6"));
    try t.expect(!takesEffort("claude-haiku-4-5") and !takesEffort("claude-sonnet-4-5") and !takesEffort("claude-opus-4-1"));
    try t.expect(takesEffort("claude-haiku-5-5"));
    try t.expectEqualStrings("medium", effortWire("claude-haiku-5-5", .medium).?);
    // ADR 0220: medium is sent to the models whose default is not medium.
    try t.expectEqualStrings("medium", effortWire("claude-sonnet-5-5", .medium).?);
    try t.expectEqualStrings("medium", effortWire("claude-opus-5-5", .medium).?);
    try t.expect(effortWire("claude-opus-5", .medium) == null);
    try t.expect(effortWire("claude-opus-4-8", .medium) == null);
    try t.expectEqualStrings("high", effortWire("claude-opus-4-8", .high).?);
    try t.expectEqualStrings("xhigh", effortWire("claude-sonnet-5-5", .xhigh).?);
    try t.expectEqualStrings("max", effortWire("claude-opus-5-5", .ultra).?);
    // Titles and recaps run at low; every other call keeps the session's level.
    try t.expectEqualStrings("low", effortFor("claude-sonnet-5-5", .xhigh, .title).?);
    try t.expectEqualStrings("low", effortFor("claude-opus-4-8", .medium, .recap).?);
    try t.expectEqualStrings("xhigh", effortFor("claude-sonnet-5-5", .xhigh, .judge).?);
    try t.expectEqualStrings("medium", effortFor("claude-sonnet-5-5", .medium, .compaction).?);
}

test "max_tokens leaves room for thinking on 128K-output models" {
    const t = std.testing;
    try t.expectEqual(@as(u32, 64_000), maxTokens("claude-opus-5-5", .medium, 16_000));
    try t.expectEqual(@as(u32, 128_000), maxTokens("claude-opus-5-5", .max, 16_000));
    try t.expectEqual(@as(u32, 128_000), maxTokens("claude-fable-5-1", .xhigh, 16_000));
    try t.expectEqual(@as(u32, 16_000), maxTokens("claude-haiku-4-5", .max, 16_000));
    try t.expectEqual(@as(u32, 128_000), maxTokens("claude-haiku-5-5", .max, 16_000));
    try t.expectEqual(@as(u32, 16_000), maxTokens("claude-opus-4-8", .high, 16_000));
    try t.expectEqual(@as(u32, 16_000), maxTokens("minimax-m3", .high, 16_000));
}
