//! The settings phase of startup, split out of session_run.zig (600-line goal,
//! #429): per-skill/companion opt-outs, the env knobs that tune transports and
//! budgets, the animation + terminal-theme preferences, the headless PTY render
//! self-tests, and the yxlyx-birthday cosmetic theme.
//!
//! It lives here rather than in session_run because it is the one part of that
//! file that legitimately DRAWS — theme escape sequences, spinner frames, a
//! markdown probe — so it belongs on the terminal side of the #422 boundary
//! with agent_stream_render.zig and session_render.zig, not on the engine side.
//! session_run re-exports both names, so main() is unchanged.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const args = @import("args.zig");
const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const http = @import("http.zig");
const http_stall = @import("http_stall.zig");
const plugins = @import("plugins.zig");
const job_idle = @import("job_idle.zig"); // #199: GRAFF_JOB_IDLE_WARN_MINS / GRAFF_JOB_IDLE_STOP_MINS
const ws = @import("ws.zig");
const agent_ws = @import("agent_ws.zig"); // codex_ws_idle_ms override (#codex-ws)
const agent_request = @import("agent_request.zig"); // GRAFF_REQ_STATS → g_req_stats (token-diet measurement)
const native_fold = @import("native_fold.zig"); // GRAFF_NO_NATIVE_FOLD → enabled
const mcp_schema_gate = @import("mcp_schema_gate.zig"); // GRAFF_STABLE_CATALOG → g_stable_catalog
const no_local_tools = @import("no_local_tools.zig"); // #330: GRAFF_NO_LOCAL_TOOLS
const tool_handle = @import("tool_handle.zig"); // #440: GRAFF_TOOL_HANDLE_BYTES
const server_compact = @import("agent_server_compact.zig"); // GRAFF_SERVER_COMPACT + #compact-ab assignment
const provider_mod = @import("provider.zig");
const xai_hosted = @import("xai_hosted.zig"); // GRAFF_XAI_X_SEARCH
const skills = @import("skills.zig");
const anim = @import("anim.zig");

pub const ThemeSetup = struct {
    theme_on: bool,
    limyuxi_glam: bool,
    /// True when a PTY self-test already ran + printed its render — main()
    /// should return immediately (but AFTER registering the theme/limyuxi
    /// reset defers below, exactly like the original inline code did).
    should_exit: bool,
};

/// Per-skill/companion opt-outs, animation + terminal-theme settings, the
/// headless PTY render self-tests, and the
/// yxlyx-birthday cosmetic theme. Moved out of main() verbatim (600-line
/// goal). Returns which reset defers main() needs to register — the
/// escape-code RESETS must fire when main() itself returns (not when this
/// helper returns), so the `defer`s stay in main(), gated on the booleans
/// this returns; main() registers them in the same order as the original
/// inline code so LIFO defer-firing order is unchanged.
/// Every `GRAFF_*` environment knob this binary honors, in one place.
///
/// Extracted from setupSkillsAndTheme so it can be driven directly by a test.
/// The reason is concrete: #440 added GRAFF_TOOL_HANDLE_BYTES here while #429
/// batch 2 moved this whole function to another file. Git merged both without
/// a conflict and the knob simply stopped being parsed — no error, no failing
/// test, a feature that silently ceased to exist. `envKnobsAreParsed` below
/// now fails if that happens to any knob in this list.
pub fn applyEnvKnobs(arena: Allocator, environ_map: anytype) !void {
    // Companion auto-activation: if the metered code-intelligence companion
    // (codedb-pro, formerly muonry) is installed but nothing connected it (no
    // workspace .mcp.json entry, or consent declined), spawn it directly — a
    // user-installed companion at the same trust level as the skills
    // auto-detection above it, NOT arbitrary workspace config.
    main_mod.g_path_env = try arena.dupe(u8, environ_map.get("PATH") orelse "");
    plugins.applyEnv(environ_map);
    main_mod.g_codedb_guard = environ_map.get("GRAFF_NO_CODEDB_GUARD") == null; // issue #626 guard, opt-out via env
    job_idle.applyEnv(environ_map); // #199: background-job idle warn/stop, minutes (0 = off)
    main_mod.g_force_stall_once = environ_map.get("GRAFF_FORCE_STALL_ONCE") != null; // #134 test seam
    main_mod.g_force_drop_once = environ_map.get("GRAFF_FORCE_DROP_ONCE") != null; // #132/#133 test seam
    main_mod.g_force_stall_always = environ_map.get("GRAFF_FORCE_STALL_ALWAYS") != null; // #56 test seam (exhaust the reconnect budget)
    main_mod.g_force_drop_always = environ_map.get("GRAFF_FORCE_DROP_ALWAYS") != null; // #56 test seam
    // #134: let a provider that buffers a long reasoning phase in total silence
    // raise the mid-stream idle-stall cutoff (default 120s). Seconds; ignored if
    // unparseable or 0. A stall is never a user interrupt regardless of the value.
    if (environ_map.get("GRAFF_STREAM_STALL_SECS")) |v| {
        if (std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t"), 10)) |secs| {
            if (secs > 0) {
                http.stream_stall_ms = @min(secs, 86_400) * 1000; // clamp: <=1 day, no u64 overflow
                http_stall.head_ceiling_ms = http.stream_stall_ms; // an explicit budget wins both regimes
            }
        } else |_| {}
    }
    // The pre-first-token ceiling alone (http_stall.head_ceiling_ms): for a
    // provider that buffers a long reasoning phase in total silence BEFORE
    // the first token. Seconds; ignored if unparseable or 0.
    if (environ_map.get("GRAFF_STREAM_HEAD_STALL_SECS")) |v| {
        if (std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t"), 10)) |secs| {
            if (secs > 0) http_stall.head_ceiling_ms = @min(secs, 86_400) * 1000;
        } else |_| {}
    }
    // #544: the non-streaming request deadline (default 5 min). One-shots and
    // subagents run non-streamed, so this is their only hang detector; a
    // harness with a tighter per-task budget lowers it so a wedged request
    // retries inside that budget. Seconds; ignored if unparseable or 0.
    if (environ_map.get("GRAFF_POST_DEADLINE_SECS")) |v| {
        if (std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t"), 10)) |secs| {
            if (secs > 0) http.post_deadline_ms = @min(secs, 86_400) * 1000;
        } else |_| {}
    }
    // #codex-ws: GRAFF_CODEX_WS=off|0|false|no (case-insensitive, the
    // GRAFF_FLEET predicate) forces the SSE transport for codex;
    // GRAFF_WS_DEBUG=1 dumps the ws handshake + frames to stderr. This is the
    // SOLE parse site for the codex transport knobs — a copy in main() would
    // be silently overwritten here, since setupSkillsAndTheme runs later.
    if (environ_map.get("GRAFF_CODEX_WS")) |v| {
        main_mod.g_codex_ws = !(std.ascii.eqlIgnoreCase(v, "off") or std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "false") or std.ascii.eqlIgnoreCase(v, "no"));
    }
    // #225 GRAFF_CLOCK_SLEEP (root-only clock_sleep meta tool) and #330
    // GRAFF_NO_LOCAL_TOOLS (the hard local-execution gate): both are
    // affirmative-only (1|true|on|yes), like GRAFF_WS_FORCE_FAIL_ONCE below,
    // and both are OR'd onto their CLI flag so a conflicting or absent env
    // value can never silently turn --clock-sleep / --no-local-tools back off.
    if (environ_map.get("GRAFF_CLOCK_SLEEP")) |v| {
        main_mod.g_clock_sleep = main_mod.g_clock_sleep or std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "on") or std.ascii.eqlIgnoreCase(v, "yes");
    }
    {
        // Always query so session_settings_tests can catch a dropped parse.
        // CLI (`--rlm` / `--old`) wins: env must not clobber an explicit flag.
        const rlm = @import("rlm.zig");
        const old_v = environ_map.get("GRAFF_OLD");
        const rlm_v = environ_map.get("GRAFF_RLM");
        if (!rlm.cli_set) {
            if (old_v) |v| {
                if (std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "on") or std.ascii.eqlIgnoreCase(v, "yes"))
                    rlm.available = false;
            }
            if (rlm_v) |v| {
                const off = std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "false") or std.ascii.eqlIgnoreCase(v, "off") or std.ascii.eqlIgnoreCase(v, "no");
                const on = std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "on") or std.ascii.eqlIgnoreCase(v, "yes");
                if (off) rlm.available = false;
                if (on) rlm.available = true; // GRAFF_RLM=1 wins over GRAFF_OLD=1
            }
            rlm.sync();
        }
        if (environ_map.get("GRAFF_RLM_MCP")) |v| {
            const off = std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "false") or std.ascii.eqlIgnoreCase(v, "off") or std.ascii.eqlIgnoreCase(v, "no");
            @import("rlm_mcp.zig").host_enabled = !off;
        }
        if (environ_map.get("GRAFF_RLM_CONTEXT")) |v| native_fold.applyContextEnv(v);
    }
    if (environ_map.get("GRAFF_NO_LOCAL_TOOLS")) |v| no_local_tools.enabled = no_local_tools.enabled or no_local_tools.envEnables(v);
    // GRAFF_LEAN: presence-based, matching session_start.leanMode
    // (the MCP half of the same switch) — a "0" still means lean, by design.
    if (environ_map.get("GRAFF_LEAN") != null) no_local_tools.lean = true;
    // GRAFF_REQ_STATS: presence-based request-anatomy print (req_stats).
    @import("req_stats.zig").g_armed = environ_map.get("GRAFF_REQ_STATS") != null;
    // GRAFF_CODEX_FULL_RESEND: presence-based — never chain previous_response_id
    // (codex_chain); the opencode-shape experiment for cache-hit measurement.
    if (environ_map.get("GRAFF_CODEX_FULL_RESEND") != null) @import("codex_chain.zig").g_force_full_resend = true;
    // GRAFF_NO_NATIVE_FOLD: presence-based — restore full power-tool schemas
    // in every request (the pre-fold interactive surface).
    if (environ_map.get("GRAFF_NO_NATIVE_FOLD") != null) native_fold.enabled = false;
    // GRAFF_STABLE_CATALOG is on by default (ADR 0011). Always query so a
    // dropped parse is visible. GRAFF_NO_STABLE_CATALOG=1 or
    // GRAFF_STABLE_CATALOG=0|off|false|no restores the mutating catalog;
    // GRAFF_STABLE_CATALOG=1 wins if both are set.
    {
        const no_sc = environ_map.get("GRAFF_NO_STABLE_CATALOG");
        const sc = environ_map.get("GRAFF_STABLE_CATALOG");
        if (no_sc) |v| {
            if (std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "on") or std.ascii.eqlIgnoreCase(v, "yes"))
                mcp_schema_gate.g_stable_catalog = false;
        }
        if (sc) |v| {
            const off = std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "false") or std.ascii.eqlIgnoreCase(v, "off") or std.ascii.eqlIgnoreCase(v, "no");
            const on = std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "on") or std.ascii.eqlIgnoreCase(v, "yes");
            if (off) mcp_schema_gate.g_stable_catalog = false;
            if (on) mcp_schema_gate.g_stable_catalog = true;
        }
    }
    // (#codex-ws) GRAFF_CODEX_WS_IDLE_SECS raises/lowers the held-WS idle limit
    // (default 4 min — the backend killed ours within 8.5 min idle; opencode
    // pools at 5). Mirrors GRAFF_STREAM_STALL_SECS above: seconds, ignored if
    // unparseable or 0, clamped to <=1 day.
    if (environ_map.get("GRAFF_CODEX_WS_IDLE_SECS")) |v| {
        if (std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t"), 10)) |secs| {
            if (secs > 0) agent_ws.codex_ws_idle_ms = @intCast(@min(secs, 86_400) * 1000);
        } else |_| {}
    }
    // #203: GRAFF_CONTEXT / GRAFF_CONTEXT_WINDOW declares the context window (in
    // tokens) for an unknown/local model whose real window graff can't look up,
    // replacing the conservative 200k fallback so the compaction gate + per-output
    // cap are sized correctly. Only affects models that fall back to the default
    // (see provider.contextWindowFor). Ignored if unparseable or 0.
    if (environ_map.get("GRAFF_CONTEXT") orelse environ_map.get("GRAFF_CONTEXT_WINDOW")) |v| {
        if (std.fmt.parseInt(u64, std.mem.trim(u8, v, " \t"), 10)) |n| {
            if (n > 0) provider_mod.g_context_override = n;
        } else |_| {}
    }
    if (environ_map.get("GRAFF_TOOL_HANDLE_BYTES")) |v| tool_handle.applyEnv(v); // #440: bytes at which a tool result becomes preview + handle
    if (environ_map.get("GRAFF_CONTEXT_LIMIT")) |v| @import("context_limits.zig").applyEnv(v);
    // #204: GRAFF_COMPACT_PCT overrides the auto-compaction threshold as a percent
    // of the window (default 80). Clamped to 1..100; ignored if unparseable or 0.
    if (environ_map.get("GRAFF_COMPACT_PCT")) |v| {
        if (std.fmt.parseInt(u8, std.mem.trim(u8, v, " \t"), 10)) |pct| {
            if (pct > 0) provider_mod.g_compact_pct_override = @min(pct, 100);
        } else |_| {}
    }
    // GRAFF_SERVER_COMPACT=0/false/off: force the client arm; =1/true/on:
    // force the server arm. Unset → #compact-ab assignment decides.
    if (environ_map.get("GRAFF_SERVER_COMPACT")) |v| {
        const off = std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "false") or std.ascii.eqlIgnoreCase(v, "off");
        server_compact.g_server_compact_override = !off;
    }
    // #502: xAI defaults to the Responses wire (api.x.ai/v1/responses) —
    // first-party server compaction + WS turns. GRAFF_XAI_WIRE=chat (anything
    // but "responses") moves it back to chat completions; unset keeps the default.
    if (environ_map.get("GRAFF_XAI_WIRE")) |v| {
        provider_mod.g_xai_responses = std.ascii.eqlIgnoreCase(std.mem.trim(u8, v, " \t"), "responses");
    }
    if (environ_map.get("GRAFF_XAI_X_SEARCH")) |v| {
        const off = std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "false") or std.ascii.eqlIgnoreCase(v, "off") or std.ascii.eqlIgnoreCase(v, "no");
        xai_hosted.enabled = !off;
    }
    if (environ_map.get("GRAFF_XAI_URL")) |v| {
        if (v.len > 0) provider_mod.g_xai_url_override = v;
    }
    // Pay-go stays on /api/paas/v4/. Coding Plan keys need /api/coding/paas/v4
    // (docs.z.ai). GRAFF_ZAI_URL wins; ZAI_CODING=1 picks the coding host.
    if (environ_map.get("GRAFF_ZAI_URL")) |v| {
        if (v.len > 0) provider_mod.g_zai_url_override = v;
    } else if (environ_map.get("ZAI_CODING")) |v| {
        const on = std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "on") or std.ascii.eqlIgnoreCase(v, "yes");
        if (on) provider_mod.g_zai_url_override = provider_mod.zai_coding_url;
    }
    // Vercel AI Gateway defaults to the coding-agent surface. GRAFF_VERCEL_URL
    // rewrites the chat URL (docs also accept the generic /v1 host).
    if (environ_map.get("GRAFF_VERCEL_URL")) |v| {
        if (v.len > 0) provider_mod.g_vercel_url_override = v;
    }
    ws.g_debug = environ_map.get("GRAFF_WS_DEBUG") != null;
    // #502 follow-up: opt-in xAI on-socket chaining (see codex_chain.g_xai_ws_chain).
    if (environ_map.get("GRAFF_XAI_WS_CHAIN")) |v|
        @import("codex_chain.zig").g_xai_ws_chain = std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "on") or std.ascii.eqlIgnoreCase(v, "true");
    // GRAFF_WS_FORCE_FAIL_ONCE proves a clean retry; the counted sibling proves
    // that two consecutive failures latch the SSE fallback. Test seams only.
    if (environ_map.get("GRAFF_WS_FORCE_FAIL_ONCE")) |v| {
        ws.g_force_connect_failure_once = std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "on") or std.ascii.eqlIgnoreCase(v, "yes");
    }
    if (environ_map.get("GRAFF_WS_FORCE_FAIL_COUNT")) |v| {
        ws.g_force_connect_failure_count = std.fmt.parseInt(u8, std.mem.trim(u8, v, " \t"), 10) catch 0;
    }
    if (environ_map.get("GRAFF_MAX_TURN_MODEL_CALLS")) |v| {
        @import("turn_chrome.zig").max_turn_model_calls = @import("turn_chrome.zig").parseMaxTurnCalls(v);
    }
}

pub fn setupSkillsAndTheme(io: Io, arena: Allocator, environ_map: anytype, out: *Io.Writer, flags: args.Flags, use_color: bool, json_mode: bool, cwd_display: []const u8) !ThemeSetup {
    try applyEnvKnobs(arena, environ_map);
    skills.loadSkillSettings(io, arena); // per-skill opt-outs, also gates the auto-connect
    anim.loadAnimationSetting(io, arena); // {"animation": "..."} → thinking spinner choice
    anim.loadThemeSetting(io, arena); // {"theme": "<name>"} → opt-in terminal color theme
    const theme_on = anim.g_theme != null and use_color and !json_mode;
    if (theme_on) {
        out.writeAll(anim.themes[anim.g_theme.?].seq) catch {};
        out.flush() catch {};
    }
    // 🎂 yxlyx's birthday glam — when graff runs from her home dir, dress her
    // Ghostty in the pastel-pink theme (limyuxi_theme: light pink bg, dark plum
    // text, pink-leaning palette) and switch the spinner to glittery sparkles.
    // Cosmetic, flagged, gated to her cwd; resets everything on exit.
    const limyuxi_glam = anim.limyuxi_birthday_white and use_color and !json_mode and
        (std.mem.eql(u8, cwd_display, "/Users/limyuxi") or std.mem.startsWith(u8, cwd_display, "/Users/limyuxi/"));
    if (limyuxi_glam) {
        out.writeAll(anim.limyuxi_theme) catch {};
        out.flush() catch {};
        if (anim.animIndex("dragon")) |gi| {
            anim.g_anim_index = gi;
            anim.g_anim_off = false;
            anim.g_anim_random = false;
        }
    }
    if (flags.selftest_spinner_flag) {
        // Headless render of the real thinking-spinner pool for the PTY anti-stealth
        // test (scripts/test-pty-spinner.py): runs the real selection (so a cwd-gated
        // pick surfaces) and prints every frame fn's output to stdout, where the test
        // scans for the U+1F4A9 / supplementary-plane glyph class the poop hid in.
        anim.selectSpinner(io);
        out.print("selected: {s}\n", .{anim.anims[anim.g_anim_current].name}) catch {};
        for (anim.anims) |a| {
            var i: usize = 0;
            while (i < 48) : (i += 1) {
                a.frame(out, i) catch {};
                out.writeByte('\n') catch {};
            }
        }
        out.flush() catch {};
        return .{ .theme_on = theme_on, .limyuxi_glam = limyuxi_glam, .should_exit = true };
    }
    if (flags.selftest_markdown_flag) {
        var probe: agent_mod.Agent = .{
            .gpa = arena,
            .arena = arena,
            .io = io,
            .client = undefined,
            .provider = undefined,
            .messages = undefined,
            .sub = false,
            .label = "markdown-selftest",
            .out = out,
        };
        probe.streamMarkdown(
            \\## Gaps
            \\- No bot-specific route tests exist.
            \\- Pin `install.sh` and verify its checksum.
            \\
            \\## Recommended implementation order
            \\1. **Immediately:** require collaborator permission.
            \\2) **Next:** deduplicate `X-GitHub-Delivery`.
            \\- [ ] Add a Daytona credential preflight.
            \\- [x] Sanitize public errors.
            \\  - Preserve private incident detail.
            \\> Public errors must never expose secrets.
            \\- Wrapped: *https://example.test/a* **https://example.test/b**
            \\- Wrapped: _https://example.test/c_ __https://example.test/d__
            \\- Wrapped: ~~https://example.test/e~~ `https://example.test/f`
            \\- URL data: https://example.test/glob/** https://example.test/path/__
            \\- URL data: https://example.test/path/~~ https://example.test/a**b
            \\- Link: **https://github.com/justrach/codegraff/issues/728**
        );
        probe.flushStreamTail();
        out.writeByte('\n') catch {};
        out.flush() catch {};
        return .{ .theme_on = theme_on, .limyuxi_glam = limyuxi_glam, .should_exit = true };
    }
    anim.loadDevSpinnerOptOut(io, arena, environ_map);
    return .{ .theme_on = theme_on, .limyuxi_glam = limyuxi_glam, .should_exit = false };
}
