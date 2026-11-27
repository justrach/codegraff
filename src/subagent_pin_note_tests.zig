//! An ignored `subagent` model/tier pin is named to the parent, and a model
//! name written the way people write it ("opus 5.5") resolves the way `/model`
//! resolves it. Resolver tests first, then the text the parent receives.

const std = @import("std");
const Allocator = std.mem.Allocator;

const bench = @import("bench_priors.zig");
const fleet = @import("fleet.zig");
const pricing = @import("pricing.zig");
const provider_mod = @import("provider.zig");
const Provider = provider_mod.Provider;
const selection = @import("subagent_selection.zig");
const pin_mod = @import("subagent_pin.zig");
const vision_ask = @import("vision_ask.zig");

fn obj(a: Allocator, json: []const u8) std.json.ObjectMap {
    return (std.json.parseFromSliceLeaky(std.json.Value, a, json, .{ .allocate = .alloc_always }) catch unreachable).object;
}

fn seat(id: []const u8, kind: Provider.Kind, model: []const u8) Provider {
    return .{ .id = id, .kind = kind, .auth = .bearer, .url = "", .api_key = "k", .model = model, .context = 200_000 };
}

/// The cheapest anthropic rung: what an unpinned worker under a mid-tier root
/// runs on once the session ladder has descended.
fn haikuWorker() Provider {
    return seat("anthropic", .anthropic, "claude-haiku-5-5");
}

/// The tool result the parent would read for `args`, as flagText renders it.
fn reportFor(gpa: Allocator, a: Allocator, base: Provider, args: []const u8) ![]u8 {
    const ask = vision_ask.forSpawn(base, obj(a, args), false, .{}, "Summarize the fixture notes.");
    return vision_ask.flagText(gpa, try gpa.dupe(u8, "child report"), ask);
}

fn firstLine(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
}

test "model pin: space and dot separators resolve to the one catalogue id" {
    const Case = struct { provider: []const u8, query: []const u8, want: []const u8 };
    for ([_]Case{
        .{ .provider = "anthropic", .query = "opus 5.5", .want = "claude-opus-5-5" },
        .{ .provider = "anthropic", .query = "Fable 5.2", .want = "claude-fable-5-2" },
        .{ .provider = "anthropic", .query = "Claude Opus 5.5", .want = "claude-opus-5-5" },
        .{ .provider = "anthropic", .query = "claude-opus-5.5", .want = "claude-opus-5-5" },
        .{ .provider = "anthropic", .query = "anthropic claude opus 5.5", .want = "claude-opus-5-5" },
        .{ .provider = "claude-agent", .query = "sonnet 5.5", .want = "claude-sonnet-5-5" },
        // The other direction: a hyphenated spelling of a dotted catalogue id.
        .{ .provider = "codex", .query = "gpt-6-1-sol", .want = "gpt-6.1-sol" },
    }) |case| {
        const got = selection.modelForProvider(case.provider, case.query) orelse {
            std.debug.print("modelForProvider({s}, \"{s}\") resolved to nothing\n", .{ case.provider, case.query });
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqualStrings(case.want, got);
    }
    // Spellings that already resolved keep their answers.
    try std.testing.expectEqualStrings("claude-opus-5-5", selection.modelForProvider("anthropic", "claude-opus-5-5").?);
    try std.testing.expectEqualStrings("gpt-6.1-sol", selection.modelForProvider("codex", " 6.1-sol ").?);
}

test "model pin: an ambiguous family name and an unknown name still resolve to nothing" {
    for ([_][]const u8{ "opus", "claude", "sonnet 5", "fable", "5.5" }) |query| {
        try std.testing.expect(selection.modelForProvider("anthropic", query) == null);
    }
    for ([_][]const u8{ "opus 9.9", "not-a-real-model", "anthropic" }) |query| {
        try std.testing.expect(selection.modelForProvider("anthropic", query) == null);
    }
    try std.testing.expect(selection.modelForProvider("codex", "gpt") == null);
}

test "/model and a spawn pin give the same answer for a spaced, dotted name" {
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    _ = keys.set("anthropic", "test-token", .environment);
    try std.testing.expectEqualStrings("claude-opus-5-5", pricing.resolveModelName(keys, "opus 5.5").?);
    try std.testing.expectEqualStrings("claude-fable-5-2", pricing.resolveModelName(keys, "Fable 5.2").?);
    try std.testing.expect(pricing.resolveModelName(keys, "totally-unknown-zzz") == null);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const saved_keys = bench.g_keys;
    defer bench.g_keys = saved_keys;
    bench.g_keys = null;
    const got = pin_mod.forSpawn(haikuWorker(), obj(arena.allocator(), "{\"model\":\"opus 5.5\"}"), true);
    try std.testing.expectEqual(pin_mod.Outcome.pinned, got.outcome);
    try std.testing.expectEqualStrings("claude-opus-5-5", got.provider.?.model);
}

test "an unresolved model pin starts the parent's result with the reason, the model that ran, and exact ids" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const saved_keys = bench.g_keys;
    defer bench.g_keys = saved_keys;
    bench.g_keys = null;

    // Ambiguous: the family names six generations, so the pin names none.
    const ambiguous = try reportFor(gpa, a, haikuWorker(), "{\"model\":\"opus\"}");
    defer gpa.free(ambiguous);
    const line = firstLine(ambiguous);
    try std.testing.expect(std.mem.startsWith(u8, line, "[model pin \"opus\" ignored: "));
    try std.testing.expect(std.mem.endsWith(u8, line, "]"));
    try std.testing.expect(std.mem.indexOf(u8, line, "ran on claude-haiku-5-5") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "claude-opus-5-5") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "claude-opus-4-5") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "kept the session default") == null);
    try std.testing.expect(std.mem.endsWith(u8, ambiguous, "\n\nchild report"));

    // Unknown version of a known family: the family's exact ids are offered.
    const unknown = try reportFor(gpa, a, haikuWorker(), "{\"model\":\"opus 9.9\"}");
    defer gpa.free(unknown);
    try std.testing.expect(std.mem.startsWith(u8, unknown, "[model pin \"opus 9.9\" ignored: "));
    try std.testing.expect(std.mem.indexOf(u8, firstLine(unknown), "claude-opus-5-5") != null);
    try std.testing.expect(std.mem.indexOf(u8, firstLine(unknown), "claude-sonnet-5-5") == null);

    // Nothing like it: the provider's own ids, bounded.
    const nothing = try reportFor(gpa, a, haikuWorker(), "{\"model\":\"totally-unknown-zzz\"}");
    defer gpa.free(nothing);
    const nl = firstLine(nothing);
    try std.testing.expect(std.mem.startsWith(u8, nl, "[model pin \"totally-unknown-zzz\" ignored: "));
    try std.testing.expect(std.mem.indexOf(u8, nl, "ran on claude-haiku-5-5") != null);
    try std.testing.expect(std.mem.indexOf(u8, nl, "claude-opus-5-5") != null);
    try std.testing.expect(std.mem.indexOf(u8, nl, "more") != null);
    try std.testing.expect(std.mem.count(u8, nl, "claude-") <= 7); // ≤6 candidates + the model that ran
}

test "every ignored tier pin names the reason and the model that ran" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const saved_keys = bench.g_keys;
    defer bench.g_keys = saved_keys;
    bench.g_keys = null;

    const Case = struct { base: Provider, args: []const u8, prefix: []const u8, hint: []const u8 };
    for ([_]Case{
        // unknown_tier
        .{ .base = seat("codex", .responses, "gpt-6-astra"), .args = "{\"tier\":\"cheap\"}", .prefix = "[tier pin \"cheap\" ignored: ", .hint = "frontier, mid or small" },
        // no_ladder
        .{ .base = seat("groq", .openai, "openai/gpt-oss-120b"), .args = "{\"tier\":\"small\"}", .prefix = "[tier pin \"small\" ignored: ", .hint = "groq has no tier ladder" },
        // no_rung
        .{ .base = seat("deepseek", .openai, "deepseek-v4-flash"), .args = "{\"tier\":\"mid\"}", .prefix = "[tier pin \"mid\" ignored: ", .hint = "no mid model" },
        // rung_pricier: escalation stays possible by naming the rung's model
        .{ .base = seat("anthropic", .anthropic, "claude-sonnet-5"), .args = "{\"tier\":\"frontier\"}", .prefix = "[tier pin \"frontier\" ignored: ", .hint = "model \"claude-opus-5-5\"" },
    }) |case| {
        const report = try reportFor(gpa, a, case.base, case.args);
        defer gpa.free(report);
        const line = firstLine(report);
        try std.testing.expect(std.mem.startsWith(u8, line, case.prefix));
        try std.testing.expect(std.mem.indexOf(u8, line, case.base.model) != null);
        try std.testing.expect(std.mem.indexOf(u8, line, case.hint) != null);
        try std.testing.expect(std.mem.endsWith(u8, report, "\n\nchild report"));
    }
}

test "a cross-provider pin without consent or login names the model that ran" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const saved_keys = bench.g_keys;
    defer bench.g_keys = saved_keys;
    const saved_consent = selection.g_cross_provider_consent;
    defer selection.g_cross_provider_consent = saved_consent;
    const saved_types = fleet.g_agent_types;
    defer fleet.g_agent_types = saved_types;
    fleet.g_agent_types = &.{.{ .name = "scout", .desc = "", .prompt = "x", .model = "codegraff/gateway-only-scout-model" }};
    bench.g_keys = null;
    const base = seat("codex", .responses, "gpt-6-astra");

    selection.g_cross_provider_consent = false;
    const refused = try reportFor(gpa, a, base, "{\"agent\":\"scout\"}");
    defer gpa.free(refused);
    try std.testing.expect(std.mem.startsWith(u8, refused, "[model pin \"codegraff/gateway-only-scout-model\" ignored: "));
    try std.testing.expect(std.mem.indexOf(u8, firstLine(refused), "--allow-cross-provider-subagents") != null);
    try std.testing.expect(std.mem.indexOf(u8, firstLine(refused), "ran on gpt-6-astra") != null);

    selection.g_cross_provider_consent = true;
    const no_login = try reportFor(gpa, a, base, "{\"agent\":\"scout\"}");
    defer gpa.free(no_login);
    try std.testing.expect(std.mem.startsWith(u8, no_login, "[model pin \"codegraff/gateway-only-scout-model\" ignored: "));
    try std.testing.expect(std.mem.indexOf(u8, firstLine(no_login), "ran on gpt-6-astra") != null);
}

test "honoured pins and unpinned spawns add nothing to the parent's result" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const saved_keys = bench.g_keys;
    defer bench.g_keys = saved_keys;
    bench.g_keys = null;
    for ([_][]const u8{
        "{}",
        "{\"model\":\"claude-opus-5-5\"}",
        "{\"model\":\"claude-haiku-5-5\"}", // same as the seat it already had
        "{\"tier\":\"small\"}",
        "{\"effort\":\"high\"}",
    }) |args| {
        const report = try reportFor(gpa, a, haikuWorker(), args);
        defer gpa.free(report);
        try std.testing.expectEqualStrings("child report", report);
    }
}

test "the pin note and a vision warning both reach the parent, pin note first" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const saved_keys = bench.g_keys;
    defer bench.g_keys = saved_keys;
    bench.g_keys = null;
    // A human pin the harness could not honour, on a vision ask the seat can
    // see: the vision half only fires on a disclaimer.
    const ask = vision_ask.forSpawn(haikuWorker(), obj(arena.allocator(), "{\"model\":\"opus\"}"), true, .{}, "Describe shots/palette.png in one line.");
    const report = vision_ask.flagText(gpa, try gpa.dupe(u8, "I couldn't open the image."), ask);
    defer gpa.free(report);
    try std.testing.expect(std.mem.startsWith(u8, report, "[model pin \"opus\" ignored: "));
    try std.testing.expect(std.mem.indexOf(u8, report, vision_ask.disclaimer_warning) != null);
    try std.testing.expect(std.mem.indexOf(u8, report, vision_ask.disclaimer_warning).? > std.mem.indexOf(u8, report, "]").?);
}

test "the route trace line records what a pin asked for beside what ran" {
    const route_trace = @import("route_trace.zig");
    const policy = @import("route_policy.zig");
    const pin_note = @import("subagent_pin_note.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d: policy.Decision = .{ .tier = .small, .resolved_model = "claude-haiku-5-5", .source = .ladder, .policy_id = "ladder:anthropic" };
    var buf: [1024]u8 = undefined;
    var plain: [320]u8 = undefined;
    // No request: byte-for-byte the line #372 specifies.
    try std.testing.expectEqualStrings(policy.formatDecision(&plain, d), route_trace.formatRequested(&buf, d, .{}));
    // A spaced name stays one JSON-quoted field.
    const req = pin_note.traced(obj(a, "{\"model\":\"opus \\\"9.9\\\"\"}"), .unknown_model);
    const line = route_trace.formatRequested(&buf, d, req);
    try std.testing.expect(std.mem.startsWith(u8, line, policy.formatDecision(&plain, d)));
    try std.testing.expect(std.mem.endsWith(u8, line, " requested_model=\"opus \\\"9.9\\\"\" requested_tier=\"\" pin=unknown_model"));
    const tier_req = pin_note.traced(obj(a, "{\"tier\":\"cheap\"}"), .unknown_tier);
    try std.testing.expectEqualStrings("cheap", tier_req.tier);
    // A model-authored name is bounded.
    const xs: [400]u8 = @splat('x');
    const long = try std.fmt.allocPrint(a, "{{\"model\":\"{s}\"}}", .{&xs});
    try std.testing.expect(pin_note.traced(obj(a, long), .unknown_model).model.len <= 64);
    try std.testing.expect(pin_note.traced(obj(a, "{}"), .none).isEmpty());
}
