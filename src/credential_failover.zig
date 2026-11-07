//! A flat-rate plan outranks a metered key on the same provider — until the
//! plan runs out (#471).
//!
//! kimi and xai (and codex, via ChatGPT) can hold BOTH credentials at once: an
//! API key you are billed for per token, and a subscription you have already
//! paid for. Before this, startup.resolveKeys filled the single `Keys` slot
//! from the environment first and only reached for a login `if (value ==
//! null)`, so the metered key won silently and every call was billed twice
//! over — once to the plan's monthly fee, once to the token meter.
//!
//! The plan wins now. The metered credential is not discarded, though: it is
//! parked here, because "the plan is better" stops being true the moment the
//! plan is exhausted, and a session that dies on a quota wall when a working
//! key is sitting right there would be a worse bug than the one being fixed.
//!
//! HANDOFF IS ONE-WAY AND ANNOUNCED. A quota cap (agent_request's
//! isQuotaExceeded path, not a transient 429) promotes the parked key for the
//! rest of the session and says so. It never silently drifts back: re-testing
//! an exhausted plan mid-run would spend real money discovering that it is
//! still exhausted, and the user needs to know their billing changed anyway.

const std = @import("std");

const provider_mod = @import("provider.zig");
const Keys = provider_mod.Keys;
const n_providers = provider_mod.provider_specs.len;

fn indexOf(provider_id: []const u8) ?usize {
    for (provider_mod.provider_specs, 0..) |spec, i|
        if (std.mem.eql(u8, spec.id, provider_id)) return i;
    return null;
}

var g_value: [n_providers]?[]const u8 = @splat(null);
var g_source: [n_providers]Keys.CredentialSource = @splat(.none);
var g_promoted: [n_providers]bool = @splat(false);

/// Park the metered credential a plan is being preferred over.
pub fn park(provider_id: []const u8, value: []const u8, source: Keys.CredentialSource) void {
    const i = indexOf(provider_id) orelse return;
    g_value[i] = value;
    g_source[i] = source;
    g_promoted[i] = false;
}

/// A metered credential read only after a plan took the slot (Anthropic's
/// Console profile loads after preferPlan): park it so the plan can still hand
/// over. Never displaces a credential already parked or a non-plan seat.
pub fn parkBehindPlan(provider_id: []const u8, seated: Keys.CredentialSource, value: []const u8, source: Keys.CredentialSource) void {
    if (seated != .login or standingBy(provider_id) or promoted(provider_id)) return;
    park(provider_id, value, source);
}

/// Is a metered credential standing by for this provider, unused so far?
pub fn standingBy(provider_id: []const u8) bool {
    const i = indexOf(provider_id) orelse return false;
    return g_value[i] != null and !g_promoted[i];
}

pub fn promoted(provider_id: []const u8) bool {
    const i = indexOf(provider_id) orelse return false;
    return g_promoted[i];
}

pub fn parkedSource(provider_id: []const u8) Keys.CredentialSource {
    const i = indexOf(provider_id) orelse return .none;
    return g_source[i];
}

pub const Promotion = struct { key: []const u8, source: Keys.CredentialSource };

/// Hand this provider over to its parked metered credential, once. Returns
/// null when there is nothing parked or the handoff already happened, so the
/// caller falls through to its normal error path rather than looping.
pub fn promote(provider_id: []const u8) ?Promotion {
    const i = indexOf(provider_id) orelse return null;
    if (g_promoted[i]) return null;
    const key = g_value[i] orelse return null;
    g_promoted[i] = true;
    return .{ .key = key, .source = g_source[i] };
}

/// Seat `spec` on its PLAN when one exists, parking whatever metered
/// credential already held the slot. Called per provider from
/// startup.resolveKeys, which owns the "is this provider even in play"
/// gate (#274 — a login refresh is a synchronous network call).
///
/// Only kimi, xai, and zai reach the load here: codegraff's device login is
/// not a flat-rate plan (`sub_login = false`), and codex is resolved earlier
/// because its `env_key` is the CODEX_DISABLED sentinel, so it has no metered
/// key to outrank in the first place.
pub fn preferPlan(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    home: []const u8,
    spec: provider_mod.ProviderSpec,
    value: *?[]const u8,
    source: *Keys.CredentialSource,
) void {
    if (!spec.sub_login) return;
    const oauth = @import("oauth.zig");
    const token = switch (spec.login) {
        .kimi_device => oauth.loadKimiOAuth(io, gpa, arena, home, false, null),
        .xai_device => oauth.loadXaiOAuth(io, gpa, arena, home, false, null),
        .zai_cli => oauth.loadZaiOAuth(io, gpa, arena, home, false, null),
        .chatgpt_browser => @import("oauth_chatgpt.zig").loadChatgptOAuth(io, gpa, arena, home, false, null),
        .anthropic_browser => @import("oauth_anthropic.zig").loadAnthropicOAuth(io, gpa, arena, home, false, null),
        else => null,
    } orelse return;
    if (value.*) |metered| park(spec.id, metered, source.*);
    value.* = token;
    source.* = .login;
}

/// #1556: startup seats plans only for the providers its `--model` selection
/// can observe. A restored session observes its saved provider too, so seat
/// that one plan on demand, as an unscoped startup would have: before the
/// stored-key fill, which only takes empty slots. No-op once it holds a login.
pub fn preferPlanFor(io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, home: []const u8, keys: *Keys, provider_id: []const u8) void {
    if (home.len == 0) return;
    const i = indexOf(provider_id) orelse return;
    if (keys.sources[i] == .login) return;
    preferPlan(io, gpa, arena, home, provider_mod.provider_specs[i], &keys.values[i], &keys.sources[i]);
}

test {
    _ = @import("session_load_plan_tests.zig"); // #1556
}

/// Test-only: the table is process-global, like the key store it mirrors.
pub fn resetForTest() void {
    g_value = @splat(null);
    g_source = @splat(.none);
    g_promoted = @splat(false);
}

test "#471 a parked metered key is handed over once, and only once" {
    resetForTest();
    defer resetForTest();

    try std.testing.expect(!standingBy("kimi"));
    try std.testing.expect(promote("kimi") == null); // nothing parked: no handoff

    park("kimi", "sk-metered", .environment);
    try std.testing.expect(standingBy("kimi"));
    try std.testing.expect(!promoted("kimi"));
    try std.testing.expectEqual(Keys.CredentialSource.environment, parkedSource("kimi"));

    const first = promote("kimi").?;
    try std.testing.expectEqualStrings("sk-metered", first.key);
    try std.testing.expectEqual(Keys.CredentialSource.environment, first.source);
    try std.testing.expect(promoted("kimi"));
    // Standing by is now false: it is in use, not in reserve.
    try std.testing.expect(!standingBy("kimi"));

    // One-way: a second quota wall on the SAME provider must not re-promote
    // and re-announce, it must fall through to the normal error path.
    try std.testing.expect(promote("kimi") == null);

    // Providers are independent, and an unknown id is inert rather than fatal.
    try std.testing.expect(promote("xai") == null);
    try std.testing.expect(promote("no-such-provider") == null);
    try std.testing.expect(!standingBy("no-such-provider"));
}

test "a Console profile read after the Claude plan seated is parked behind it" {
    resetForTest();
    defer resetForTest();

    // Only a plan seat gets a reserve.
    parkBehindPlan("anthropic", .stored, "sk-ant-oat01-console", .profile);
    try std.testing.expect(!standingBy("anthropic"));

    parkBehindPlan("anthropic", .login, "sk-ant-oat01-console", .profile);
    try std.testing.expect(standingBy("anthropic"));
    // An earlier reserve (an env key parked by preferPlan) is kept.
    parkBehindPlan("anthropic", .login, "other", .stored);
    const p = promote("anthropic").?;
    try std.testing.expectEqualStrings("sk-ant-oat01-console", p.key);
    try std.testing.expectEqual(Keys.CredentialSource.profile, p.source);
}
