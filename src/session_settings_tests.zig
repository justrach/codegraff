//! Guard against a `GRAFF_*` knob silently ceasing to exist.
//!
//! The failure this exists for actually happened, on 2026-08-06: #440 added
//! `GRAFF_TOOL_HANDLE_BYTES` to `setupSkillsAndTheme` while #429 batch 2 moved
//! that entire function into this module. Git merged both branches without a
//! conflict, both suites stayed green, and the knob simply stopped being
//! parsed. No error, no failing test — a shipped feature that quietly became
//! unreachable, and it was caught by eye during integration rather than by
//! anything automatic.
//!
//! The important test here is `every knob is actually read`. It does not check
//! what a knob DOES; it checks that `applyEnvKnobs` asks for the name at all.
//! A refactor that drops a parse makes the name go unqueried, and this goes
//! red. Checking the effect instead would not catch the case where a whole
//! block is dropped, because there would be nothing left to assert against.

const std = @import("std");
const session_settings = @import("session_settings.zig");
const main_mod = @import("main.zig");
const provider_mod = @import("provider.zig");
const tool_handle = @import("tool_handle.zig");
const no_local_tools = @import("no_local_tools.zig");
const http = @import("http.zig");
const ws = @import("ws.zig");
const agent_ws = @import("agent_ws.zig");
const plugins = @import("plugins.zig");

const Knob = struct { name: []const u8, value: []const u8 };

/// Every knob `applyEnvKnobs` is expected to honor. Adding a knob there without
/// adding it here is fine (this list is a floor, not a ceiling); REMOVING the
/// parse while the knob is still documented is what this catches.
const knobs = [_]Knob{
    .{ .name = "GRAFF_NO_CODEDB_GUARD", .value = "1" },
    .{ .name = "GRAFF_FORCE_STALL_ONCE", .value = "1" },
    .{ .name = "GRAFF_FORCE_DROP_ONCE", .value = "1" },
    .{ .name = "GRAFF_FORCE_STALL_ALWAYS", .value = "1" },
    .{ .name = "GRAFF_FORCE_DROP_ALWAYS", .value = "1" },
    .{ .name = "GRAFF_STREAM_STALL_SECS", .value = "7" },
    .{ .name = "GRAFF_STREAM_HEAD_STALL_SECS", .value = "9" },
    .{ .name = "GRAFF_POST_DEADLINE_SECS", .value = "90" },
    .{ .name = "GRAFF_CODEX_WS", .value = "off" },
    .{ .name = "GRAFF_CLOCK_SLEEP", .value = "1" },
    .{ .name = "GRAFF_RLM", .value = "1" },
    .{ .name = "GRAFF_NO_LOCAL_TOOLS", .value = "1" },
    .{ .name = "GRAFF_CODEX_WS_IDLE_SECS", .value = "11" },
    .{ .name = "GRAFF_CONTEXT", .value = "123456" },
    .{ .name = "GRAFF_TOOL_HANDLE_BYTES", .value = "8192" },
    .{ .name = "GRAFF_COMPACT_PCT", .value = "55" },
    .{ .name = "GRAFF_WS_DEBUG", .value = "1" },
    .{ .name = "GRAFF_WS_FORCE_FAIL_ONCE", .value = "1" },
    .{ .name = "GRAFF_WS_FORCE_FAIL_COUNT", .value = "3" },
    .{ .name = "GRAFF_NO_PLUGINS", .value = "1" },
    .{ .name = "GRAFF_VERCEL_URL", .value = "https://ai-gateway.vercel.sh/v1/chat/completions" },
};

/// A stand-in for the process environment that records which names were asked
/// for. Deliberately array-backed rather than a hash map: no allocator, and the
/// recording is what the test is actually about.
const RecordingEnv = struct {
    asked: *[knobs.len]bool,

    pub fn get(self: RecordingEnv, name: []const u8) ?[]const u8 {
        for (knobs, 0..) |k, i| {
            if (std.mem.eql(u8, k.name, name)) {
                self.asked[i] = true;
                return k.value;
            }
        }
        return null; // PATH and anything else: absent, as an empty env would be
    }
};

/// Save/restore for every global `applyEnvKnobs` writes. These are process
/// globals in a single test binary, so leaking one would corrupt whatever test
/// runs next — the exact failure mode that made #391's note store segfault
/// three unrelated tests during the same integration.
const Saved = struct {
    codedb_guard: bool,
    stall_once: bool,
    drop_once: bool,
    stall_always: bool,
    drop_always: bool,
    codex_ws: bool,
    clock_sleep: bool,
    rlm: bool,
    stream_stall_ms: u64,
    post_deadline_ms: u64,
    codex_ws_idle_ms: i64,
    context_override: ?u64,
    compact_pct_override: ?u8,
    threshold_bytes: usize,
    no_local: bool,
    ws_debug: bool,
    ws_fail_once: bool,
    ws_fail_count: u8,
    plugins_off: bool,

    fn capture() Saved {
        return .{
            .codedb_guard = main_mod.g_codedb_guard,
            .stall_once = main_mod.g_force_stall_once,
            .drop_once = main_mod.g_force_drop_once,
            .stall_always = main_mod.g_force_stall_always,
            .drop_always = main_mod.g_force_drop_always,
            .codex_ws = main_mod.g_codex_ws,
            .clock_sleep = main_mod.g_clock_sleep,
            .rlm = @import("rlm.zig").available,
            .stream_stall_ms = http.stream_stall_ms,
            .post_deadline_ms = http.post_deadline_ms,
            .codex_ws_idle_ms = agent_ws.codex_ws_idle_ms,
            .context_override = provider_mod.g_context_override,
            .compact_pct_override = provider_mod.g_compact_pct_override,
            .threshold_bytes = tool_handle.threshold_bytes,
            .no_local = no_local_tools.enabled,
            .ws_debug = ws.g_debug,
            .ws_fail_once = ws.g_force_connect_failure_once,
            .ws_fail_count = ws.g_force_connect_failure_count,
            .plugins_off = plugins.disabled,
        };
    }

    fn restore(s: Saved) void {
        main_mod.g_codedb_guard = s.codedb_guard;
        main_mod.g_force_stall_once = s.stall_once;
        main_mod.g_force_drop_once = s.drop_once;
        main_mod.g_force_stall_always = s.stall_always;
        main_mod.g_force_drop_always = s.drop_always;
        main_mod.g_codex_ws = s.codex_ws;
        main_mod.g_clock_sleep = s.clock_sleep;
        @import("rlm.zig").available = s.rlm;
        @import("rlm.zig").sync();
        http.stream_stall_ms = s.stream_stall_ms;
        http.post_deadline_ms = s.post_deadline_ms;
        agent_ws.codex_ws_idle_ms = s.codex_ws_idle_ms;
        provider_mod.g_context_override = s.context_override;
        provider_mod.g_compact_pct_override = s.compact_pct_override;
        tool_handle.threshold_bytes = s.threshold_bytes;
        no_local_tools.enabled = s.no_local;
        ws.g_debug = s.ws_debug;
        ws.g_force_connect_failure_once = s.ws_fail_once;
        ws.g_force_connect_failure_count = s.ws_fail_count;
        plugins.disabled = s.plugins_off;
    }
};

test "every GRAFF_ knob is actually read by applyEnvKnobs (a dropped parse is invisible otherwise)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const saved = Saved.capture();
    defer saved.restore();

    var asked: [knobs.len]bool = @splat(false);
    try session_settings.applyEnvKnobs(arena_state.allocator(), RecordingEnv{ .asked = &asked });

    for (knobs, 0..) |k, i| {
        if (!asked[i]) {
            std.debug.print("\nknob '{s}' is no longer read by applyEnvKnobs\n", .{k.name});
            return error.KnobNoLongerParsed;
        }
    }
}

test "applyEnvKnobs actually applies the values it reads" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const saved = Saved.capture();
    defer saved.restore();

    // Start from the opposite of every expected outcome, so a no-op parse
    // cannot pass by coincidence.
    main_mod.g_codedb_guard = true;
    main_mod.g_force_stall_once = false;
    main_mod.g_codex_ws = true;
    main_mod.g_clock_sleep = false;
    @import("rlm.zig").available = false;
    @import("rlm.zig").sync();
    no_local_tools.enabled = false;
    ws.g_debug = false;
    provider_mod.g_context_override = null;
    provider_mod.g_compact_pct_override = null;
    tool_handle.threshold_bytes = tool_handle.default_threshold_bytes;
    plugins.disabled = false;

    var asked: [knobs.len]bool = @splat(false);
    try session_settings.applyEnvKnobs(arena_state.allocator(), RecordingEnv{ .asked = &asked });

    try std.testing.expect(!main_mod.g_codedb_guard); // present ⇒ guard OFF
    try std.testing.expect(main_mod.g_force_stall_once);
    try std.testing.expect(!main_mod.g_codex_ws); // "off" disables the WS transport
    try std.testing.expect(main_mod.g_clock_sleep);
    try std.testing.expect(@import("rlm.zig").available);
    try std.testing.expect(no_local_tools.enabled);
    try std.testing.expect(ws.g_debug);
    try std.testing.expectEqual(@as(u64, 7_000), http.stream_stall_ms); // seconds → ms
    try std.testing.expectEqual(@as(u64, 90_000), http.post_deadline_ms); // #544: seconds → ms
    try std.testing.expectEqual(@as(i64, 11_000), agent_ws.codex_ws_idle_ms);
    try std.testing.expectEqual(@as(?u64, 123_456), provider_mod.g_context_override);
    try std.testing.expectEqual(@as(?u8, 55), provider_mod.g_compact_pct_override);
    try std.testing.expectEqual(@as(usize, 8192), tool_handle.threshold_bytes);
    try std.testing.expect(ws.g_force_connect_failure_once);
    try std.testing.expectEqual(@as(u8, 3), ws.g_force_connect_failure_count);
    try std.testing.expect(plugins.disabled);
}
