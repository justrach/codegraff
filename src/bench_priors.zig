//! Bench-derived worker priors: `.harness/bench.json` (project, else
//! personal ~/.harness/bench.json) is a benchmark score/cost sheet — one
//! entry per (model, effort) config, e.g. a DeepSWE leaderboard export — and
//! this module turns it into per-provider tier ladders so worker assignment
//! starts from measured capability and cost instead of the compiled-in hand
//! table in subagent_tier_ladder.zig (which stays as the fallback for
//! providers the sheet cannot cover).
//!
//! Derivation, per provider, over the sheet models that RESOLVE on that
//! provider's live catalog (subagent_selection.modelForProvider — so one
//! sheet feeds every provider serving any of its models, and an unknown or
//! renamed model is skipped, never a load failure):
//!
//!   frontier = best score            (capability ceiling)
//!   small    = best score-per-dollar among the other models (the efficiency
//!              knee the sheet's power-law tail points at)
//!   mid      = best score among the rest (nullable)
//!
//! A provider needs at least two resolved models to earn a derived ladder.
//! Scores accept [0,1] or percent (0,100]; a non-positive cost contributes
//! capability but no efficiency. Loaded by fleet.loadAgentTypes, so the
//! session registry and auto-promote's hot-reload refresh it together.
//!
//! PRECEDENCE: project ./.harness/bench.json > personal ~/.harness/bench.json
//! > the BUILTIN sheet below — a shipped community leaderboard snapshot, so
//! every install starts with a measured cost/capability power law rather
//! than a blank. The intended refresher for the builtin is aggregated fleet
//! telemetry (users who opt into data sharing already submit signed
//! niche-tagged scores); serving that aggregate back is backend work — the
//! seam here is just "a sheet from anywhere, highest tier wins".

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const tier_ladder = @import("subagent_tier_ladder.zig");
const selection = @import("subagent_selection.zig");
const provider_mod = @import("provider.zig");

pub const bench_path = ".harness/bench.json";

/// Bench-derived ladders, consulted by tier_ladder.forProvider ahead of the
/// compiled table. Session-arena strings; empty when no sheet is present.
pub var g_ladders: []const tier_ladder.TierLadder = &.{};

/// Which providers the user is actually logged into / keyed for, snapshotted
/// when startup resolves credentials (noteAvailability, spec-table order).
/// Derivation skips the rest: priors describe YOUR available fleet, not the
/// whole catalog. null (tests, pre-startup) = no opinion, derive everything.
/// A mid-session /login is picked up on next start, like persona files —
/// until then the compiled ladder covers the newly added provider.
pub var g_available: ?[provider_mod.provider_specs.len]bool = null;

/// By VALUE in, by value out — written to ride resolveKeys' return statement
/// (a pointer into its stack Keys would dangle) without costing the capped
/// file a line.
pub fn noteAvailability(keys: provider_mod.Keys) provider_mod.Keys {
    var av: [provider_mod.provider_specs.len]bool = undefined;
    for (keys.values, 0..) |v, i| av[i] = v != null;
    g_available = av;
    return keys;
}

pub const Entry = struct {
    model: []const u8,
    effort: ?[]const u8 = null, // recorded for provenance; ladders name models
    score: f64,
    cost: f64 = 0, // avg $ per task; <= 0 = unknown (no efficiency signal)
};

pub const Sheet = struct {
    suite: []const u8 = "",
    updated: []const u8 = "",
    entries: []Entry = &.{},
};

/// The shipped default sheet: DeepSWE v1.1 (113 tasks, updated 2026-07-25),
/// avg $ per task. Chart-read values (±~2% score, ±~$0.5 cost) — plenty for
/// rung ORDERING, which is all derivation consumes. Models no provider
/// serves (gemini, muse-spark) still belong here: they resolve nowhere today
/// but start working the day a catalog serves them.
pub const builtin_entries = [_]Entry{
    .{ .model = "claude-opus-5", .effort = "max", .score = 74, .cost = 12.0 },
    .{ .model = "claude-fable-5", .effort = "high", .score = 70, .cost = 9.0 },
    .{ .model = "claude-sonnet-5", .effort = "high", .score = 49, .cost = 10.5 },
    .{ .model = "claude-opus-4-8", .effort = "high", .score = 41, .cost = 2.9 },
    .{ .model = "claude-sonnet-4-6", .effort = "high", .score = 31, .cost = 6.5 },
    .{ .model = "k3", .effort = "max", .score = 68, .cost = 4.6 },
    .{ .model = "kimi-k2.7-code", .score = 30, .cost = 2.6 },
    .{ .model = "gpt-5.6-sol", .effort = "max", .score = 73, .cost = 5.5 },
    .{ .model = "gpt-5.6-sol", .effort = "medium", .score = 61, .cost = 1.86 },
    .{ .model = "gpt-5.6-terra", .effort = "medium", .score = 35, .cost = 0.9 },
    .{ .model = "gpt-5.6-luna", .effort = "max", .score = 67, .cost = 0.61 },
    .{ .model = "gpt-5.6-luna", .effort = "medium", .score = 11, .cost = 0.15 },
    .{ .model = "gpt-5.5", .effort = "medium", .score = 54, .cost = 3.2 },
    .{ .model = "gpt-5.4", .effort = "xhigh", .score = 53, .cost = 5.2 },
    .{ .model = "grok-4.5", .effort = "high", .score = 53, .cost = 3.0 },
    .{ .model = "glm-5.2", .effort = "max", .score = 44, .cost = 3.9 },
    .{ .model = "muse-spark-1.1", .effort = "xhigh", .score = 50, .cost = 3.0 },
    .{ .model = "gemini-3.6-flash", .effort = "high", .score = 54, .cost = 3.5 },
    .{ .model = "gemini-3.5-flash", .effort = "medium", .score = 38, .cost = 7.0 },
    .{ .model = "gemini-3.1-pro", .effort = "high", .score = 12, .cost = 9.5 },
};

pub fn loadInto(io: Io, arena: Allocator, home: ?[]const u8) void {
    var sheet = readSheet(io, arena, bench_path);
    if (sheet == null) if (home) |h| {
        const p = std.fmt.allocPrint(arena, "{s}/{s}", .{ h, bench_path }) catch return;
        sheet = readSheet(io, arena, p);
    };
    g_entries = if (sheet) |s| s.entries else &builtin_entries;
    g_ladders = derive(arena, g_entries);
}

fn readSheet(io: Io, arena: Allocator, path: []const u8) ?Sheet {
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return null;
    return std.json.parseFromSliceLeaky(Sheet, arena, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

/// [0,1] passes; (1,100] reads as percent; anything else is not a score.
fn normalScore(s: f64) ?f64 {
    if (!(s >= 0)) return null;
    if (s <= 1) return s;
    if (s <= 100) return s / 100.0;
    return null;
}

/// The current sheet's entries (file else builtin) — the score authority
/// subscription-rung ranking consults (subagent_pin.subscriptionRung).
pub var g_entries: []const Entry = &builtin_entries;

/// The session Keys, captured where main() builds its loop context (the
/// pointer targets main's stack frame, alive for the whole loop). Lets the
/// spawn path build a Provider for a logged-in subscription — null in tests
/// and before startup, which reads as "no subscriptions reachable".
pub var g_keys: ?*const provider_mod.Keys = null;

pub fn noteKeys(keys: *provider_mod.Keys) *provider_mod.Keys {
    g_keys = keys;
    return keys;
}

/// Startup composition, riding resolveKeys' return: snapshot availability,
/// then load/derive the sheet — so the #291 worker default (resolved moments
/// later in main) sees the SAME bench ladders as every later /model
/// re-derivation (#371). Without this, startup derived workers from the
/// compiled table while a switch re-derived from the bench one, and the two
/// disagreed (terra vs the data-blessed gpt-5.5 on codex).
pub fn noteKeysAtStartup(keys: provider_mod.Keys, io: Io, arena: Allocator, home: ?[]const u8) provider_mod.Keys {
    const kept = noteAvailability(keys);
    loadInto(io, arena, home);
    return kept;
}

/// Best sheet score for `model` as served by `provider_id`; null when the
/// sheet has no opinion.
pub fn scoreFor(provider_id: []const u8, model: []const u8) ?f64 {
    var best: ?f64 = null;
    for (g_entries) |e| {
        const s = normalScore(e.score) orelse continue;
        const r = selection.modelForProvider(provider_id, e.model) orelse continue;
        if (!std.mem.eql(u8, r, model)) continue;
        if (best == null or s > best.?) best = s;
    }
    return best;
}

const Best = struct { name: []const u8, score: f64 = -1, spd: f64 = -1 };

/// One provider's per-model bests: the max score over that model's configs
/// and the max score-per-dollar, folded across every sheet entry that
/// resolves to it (several efforts of one model collapse into one candidate).
fn foldProvider(arena: Allocator, provider_id: []const u8, entries: []const Entry) []Best {
    var models: std.ArrayList(Best) = .empty;
    for (entries) |e| {
        const score = normalScore(e.score) orelse continue;
        const resolved = selection.modelForProvider(provider_id, e.model) orelse continue;
        const slot = blk: {
            for (models.items) |*m| if (std.mem.eql(u8, m.name, resolved)) break :blk m;
            models.append(arena, .{ .name = resolved }) catch return models.items;
            break :blk &models.items[models.items.len - 1];
        };
        if (score > slot.score) slot.score = score;
        if (e.cost > 0 and score / e.cost > slot.spd) slot.spd = score / e.cost;
    }
    return models.items;
}

fn derive(arena: Allocator, entries: []const Entry) []const tier_ladder.TierLadder {
    var out: std.ArrayList(tier_ladder.TierLadder) = .empty;
    for (provider_mod.provider_specs, 0..) |spec, i| {
        if (g_available) |av| if (!av[i]) continue;
        const models = foldProvider(arena, spec.id, entries);
        if (models.len < 2) continue;
        var frontier: *const Best = &models[0];
        for (models) |*m| if (m.score > frontier.score) {
            frontier = m;
        };
        var small: ?*const Best = null;
        for (models) |*m| {
            if (m == frontier or m.spd < 0) continue;
            if (small == null or m.spd > small.?.spd) small = m;
        }
        const sm = small orelse continue; // capability alone cannot rank efficiency
        var mid: ?*const Best = null;
        for (models) |*m| {
            if (m == frontier or m == sm) continue;
            if (mid == null or m.score > mid.?.score) mid = m;
        }
        out.append(arena, .{
            .provider = spec.id,
            .frontier = frontier.name,
            .mid = if (mid) |m| m.name else null,
            .small = sm.name,
        }) catch return out.items;
    }
    return out.items;
}

test "bench sheet: score normalization accepts unit and percent, rejects junk" {
    try std.testing.expectEqual(@as(f64, 0.67), normalScore(0.67).?);
    try std.testing.expectEqual(@as(f64, 0.67), normalScore(67).?);
    try std.testing.expect(normalScore(-1) == null);
    try std.testing.expect(normalScore(101) == null);
}

test "derive: frontier by score, small by score-per-dollar, mid from the rest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Another test (or startup_tests' resolveKeys) may have snapshotted THIS
    // process's credentials; pin "no opinion" so derivation sees all specs.
    const saved = g_available;
    defer g_available = saved;
    g_available = null;
    // openai serves gpt-5.6 / gpt-5.6-terra / gpt-5.6-luna in the shipped
    // table, so this exercises real catalog resolution — including two
    // configs of one model collapsing into one candidate.
    const entries = [_]Entry{
        .{ .model = "gpt-5.6", .effort = "max", .score = 73, .cost = 5.5 },
        .{ .model = "gpt-5.6", .effort = "medium", .score = 61, .cost = 1.86 },
        .{ .model = "gpt-5.6-terra", .effort = "medium", .score = 35, .cost = 0.9 },
        .{ .model = "gpt-5.6-luna", .effort = "max", .score = 0.67, .cost = 0.61 },
        .{ .model = "not-a-model-anywhere", .score = 99, .cost = 0.01 }, // skipped, never a failure
    };
    const ladders = derive(a, &entries);
    var openai: ?tier_ladder.TierLadder = null;
    for (ladders) |l| if (std.mem.eql(u8, l.provider, "openai")) {
        openai = l;
    };
    try std.testing.expectEqualStrings("gpt-5.6", openai.?.frontier);
    try std.testing.expectEqualStrings("gpt-5.6-luna", openai.?.small.?); // 0.67/0.61 ≈ 1.10 beats terra's 0.39
    try std.testing.expectEqualStrings("gpt-5.6-terra", openai.?.mid.?);
}

test "builtin sheet: every install derives a codex ladder from the shipped leaderboard" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const saved = g_available;
    defer g_available = saved;
    g_available = null;
    const ladders = derive(a, &builtin_entries);
    var codex: ?tier_ladder.TierLadder = null;
    for (ladders) |l| if (std.mem.eql(u8, l.provider, "codex")) {
        codex = l;
    };
    // sol tops capability; luna-max tops score-per-dollar (the leaderboard's
    // "most efficient" config); the data promotes gpt-5.5 over the hand
    // table's terra for the mid rung (54% vs 35%).
    try std.testing.expectEqualStrings("gpt-5.6-sol", codex.?.frontier);
    try std.testing.expectEqualStrings("gpt-5.6-luna", codex.?.small.?);
    try std.testing.expectEqualStrings("gpt-5.5", codex.?.mid.?);
}

test "derive: fewer than two resolved models yields no ladder for a provider" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const saved = g_available;
    defer g_available = saved;
    g_available = null;
    const entries = [_]Entry{.{ .model = "grok-4.3", .score = 0.5, .cost = 3.0 }};
    for (derive(a, &entries)) |l| try std.testing.expect(!std.mem.eql(u8, l.provider, "xai"));
}

test "scoreFor: the sheet ranks a provider's models for subscription routing" {
    // Luna's best config (max, 67%) outranks terra's (medium, 35%) on codex.
    try std.testing.expect(scoreFor("codex", "gpt-5.6-luna").? > scoreFor("codex", "gpt-5.6-terra").?);
    try std.testing.expect(scoreFor("codex", "model-nobody-benched") == null);
}

test "derive: availability gate — priors describe only logged-in services" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const saved = g_available;
    defer g_available = saved;
    var av: [provider_mod.provider_specs.len]bool = @splat(false);
    for (provider_mod.provider_specs, 0..) |spec, i| av[i] = std.mem.eql(u8, spec.id, "openai");
    g_available = av;
    // The full builtin sheet, but only one service logged in → exactly one
    // ladder: the sheet never speaks for a provider the user cannot reach.
    const ladders = derive(a, &builtin_entries);
    try std.testing.expectEqual(@as(usize, 1), ladders.len);
    try std.testing.expectEqualStrings("openai", ladders[0].provider);
}
