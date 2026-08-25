//! Post-arg-parse setup helpers carved out of main() (600-line goal, #123
//! follow-up — the last file over the line goal). Only the setup that is
//! SAFELY separable lives here: pure computations over env/disk/arena that
//! return plain values, with no stack-address capture.
//!
//! DANGLING-POINTER TRAP (why the rest of main()'s setup stays in main()):
//! `tracer`/`traj`/`telem` are stack-allocated in main() and hold pointers
//! into OTHER main()-stack-allocated storage (`trace_writer`/`traj_writer`,
//! which themselves wrap stack buffers, and `&client`). A helper that
//! constructed those structs itself would return a value whose pointer
//! fields point into the HELPER's own stack frame — invalid the instant the
//! helper returns. So that construction (and the MCP-registry/approvals/
//! hooks/theme block, which is additionally tangled with several `defer`s
//! and a mid-block early `return` for --selftest-spinner) is intentionally
//! left inline in main(), per the split's own guidance: don't force an
//! extraction that can't be done without an address-capture or defer-order
//! hazard.
//!
//! Back-imports main (as main_mod, the established convention) only where a
//! helper's signature needs main.zig's own re-exported types (Provider is
//! provider.zig-resident and imported directly below instead). Sibling-
//! imports provider/keys_cli/oauth/pricing/serde/skills/prompts directly —
//! all already `pub` for their existing cross-module callers — so nothing
//! needed a fresh pub-flip for this split.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const mcp = @import("mcp.zig");
const provider_mod = @import("provider.zig");
const keys_cli = @import("keys_cli.zig");
const oauth = @import("oauth.zig");
const models_cache = @import("models_cache.zig");
const pricing_db = @import("pricing_db.zig");
const kimi_catalog = @import("kimi_catalog.zig");
const router_config = @import("router_config.zig");
const router_catalog = @import("router_catalog.zig");
const serde = @import("serde.zig");
const skills = @import("skills.zig");
const skill_docs = @import("skill_docs.zig");
const fleet = @import("fleet.zig"); // g_home: resolved before any prompt build (session_run.initApprovalsHooksFleet)
const prompts = @import("prompts.zig");
const learn_store = @import("learn_store.zig");
const learn_bootstrap = @import("learn_bootstrap.zig");
const learn_auto = @import("learn_auto.zig");
const imagegen = @import("imagegen.zig"); // #352: codex-skill detection + the personal-tier skill mirror

const plugins = @import("plugins.zig");
const startup_keys = @import("startup_keys.zig");
pub const ResolvedKeys = startup_keys.ResolvedKeys;
pub const storedKeyMayAffectSelection = startup_keys.storedKeyMayAffectSelection;
pub const startupStoredKeyScope = startup_keys.startupStoredKeyScope;
pub const resolveSubagentProvider = startup_keys.resolveSubagentProvider;
pub const resolveKeys = startup_keys.resolveKeys;

/// Root system-prompt layering, frozen at startup so it stays
/// KV-cache-friendly: built-in base (or its --system-prompt replacement),
/// then project instructions from the first of AGENTS.md/HARNESS.md/
/// CLAUDE.md found in the cwd, then --append-system-prompt text, then one
/// capability line per active optional skill, then one usage note per
/// connected MCP server. `quiet` suppresses startup diagnostics; interactive
/// callers clear it only for GRAFF_REPL_DEBUG, while JSON and one-shot modes
/// always keep stdout clean. Carved out of main()'s
/// former inline block verbatim — pure over io/arena, returns everything by
/// value, so it's safe to call from outside main()'s own stack frame.
/// The last edge of the learning loop: a genome this workspace actually
/// promoted becomes the root prompt, not just a subagent persona. Generation 0
/// is the unmodified snapshot of some build's own prompt, so only a promoted
/// generation takes over — otherwise a freshly initialized store would pin an
/// older build's wording forever. Corrupt or foreign state fails closed.
fn learnedRootPolicy(io: Io, arena: Allocator) ?learn_store.ActiveAgent {
    const learned = learn_store.loadActiveAgent(io, arena) orelse return null;
    if (learned.generation == 0) return null;
    if (!std.mem.eql(u8, learned.name, learn_bootstrap.root_policy_agent)) return null;
    if (std.mem.trim(u8, learned.prompt, " \t\r\n").len == 0) return null;
    if (!learn_store.validId(learned.genome_id)) return null;
    return learned;
}

pub fn buildSystemPrompt(
    io: Io,
    arena: Allocator,
    out: *Io.Writer,
    system_prompt_flag: ?[]const u8,
    append_system_flag: ?[]const u8,
    quiet: bool,
    unattended: bool,
    mcp_tools: []const mcp.Tool,
    codedbpro_licensed: bool,
    learned_policy_env: ?[]const u8,
    environ: anytype,
) ![]const u8 {
    // #421: settle the git_repo gate before the base composes — commit/PR
    // authoring guidance is only sent where a repository exists to act on.
    prompts.probeGitRepo(io);
    // A learned policy is used unless this session opted out of it.
    const learned: ?learn_store.ActiveAgent = if (system_prompt_flag == null and learn_auto.enabled(learned_policy_env)) learnedRootPolicy(io, arena) else null;
    if (learned) |policy| if (!quiet) {
        try out.print("root policy: learned generation {d} ({s})\n", .{ policy.generation, policy.genome_id[0..12] });
        try out.flush();
    };
    const base_prompt: []const u8 = system_prompt_flag orelse
        if (learned) |policy| policy.prompt else try prompts.baseForSession(arena); // #421: built-in base minus the segments whose capability this process lacks
    var sys_normal: []const u8 = base_prompt;
    for ([_][]const u8{ "AGENTS.md", "HARNESS.md", "CLAUDE.md" }) |fname| {
        const body = Io.Dir.cwd().readFileAlloc(io, fname, arena, .limited(64 * 1024)) catch continue;
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (trimmed.len == 0) continue;
        const capped = @import("context_limits.zig").applyAlloc(arena, trimmed, @import("context_limits.zig").agents_md_bytes);
        sys_normal = try std.fmt.allocPrint(arena, "{s}\n\n# Project instructions (from {s})\n{s}", .{ base_prompt, fname, capped });
        if (!quiet) {
            try out.print("loaded project instructions from {s} ({d} bytes)\n", .{ fname, trimmed.len });
            try out.flush();
        }
        break;
    }
    if (append_system_flag) |extra| {
        sys_normal = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ sys_normal, extra });
    }
    // Repo map (repo_map.zig): the top of the working tree, so the model reads
    // the files it needs instead of spending opening turns on ls/find.
    // Lean one-shots name their files; the map is an interactive opener
    // and was prefix bytes on every -p turn (ADR 0024).
    if (environ.get("GRAFF_NO_REPO_MAP") == null and !@import("no_local_tools.zig").lean) {
        if (@import("repo_map.zig").segment(io, arena)) |map| sys_normal = try std.fmt.allocPrint(arena, "{s}{s}", .{ sys_normal, map });
    }
    if (unattended) sys_normal = try std.fmt.allocPrint(arena, "{s}{s}", .{ sys_normal, prompts.unattended_note });
    // ADR 0030 / 0011: do not splice rlm_spec.system_note onto the always-on
    // prefix. Small turns must not advertise rlm/sPTC; discovery is the
    // catalog tail after showcase (--rlm, a wide native batch, or context
    // ≥50% of compactAt).
    // Codex-style skills: one capability line per installed optional
    // companion (skills_registry) — metadata in context, --help on demand.
    // Lean one-shots do not need companion essays (ADR 0024 prefix tax).
    const lean = @import("no_local_tools.zig").lean;
    if (!lean) {
        for (skills.skills_registry) |sk| {
            if (sk.note.len == 0 or !skills.skillActive(io, sk)) continue;
            sys_normal = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ sys_normal, sk.note });
        }
        // Same idea for known MCP servers: a usage note enters the context only
        // when the server actually connected this session (consent given, spawn
        // succeeded). Native tools remain the fallback either way.
        for (skills.mcp_notes) |mn| {
            if (!skills.mcpServerConnected(mcp_tools, mn.server)) continue;
            const note = skills.codedbproNote(mn.server, codedbpro_licensed, mn.note);
            sys_normal = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ sys_normal, note });
        }
    }
    // #352: mirror the Codex imagegen skill into ~/.harness/skills BEFORE the
    // scan below, so the copied playbook is in this session's catalog. The same
    // call decides whether `imagegen` is advertised (tool_gates.zig) and which
    // of its two engines this machine can actually run.
    imagegen.detect(io, arena, .{ .codex_home = environ.get("CODEX_HOME"), .home = fleet.g_home, .openai_api_key = environ.get("OPENAI_API_KEY"), .tmp_dir = environ.get("TMPDIR") });
    if (imagegen.available and !quiet) {
        try out.print("imagegen: Codex skill found — tool enabled ({s}), playbook at {s}\n", .{ imagegen.engineSummary(), imagegen.skill_dir });
        try out.flush();
    }
    // Markdown skills (skill_docs.zig): names + trigger descriptions only.
    // Pinned once into the system-prompt prefix so later turns hit the
    // prompt cache (Codex: old prompt is an exact prefix of the new one).
    // The `skill` tool rescans without rewriting this prefix.
    if (!lean) {
        skill_docs.g_skills = skill_docs.load(io, arena, fleet.g_home);
        const skill_catalog = skill_docs.promptCatalog(arena, skill_docs.g_skills);
        if (skill_catalog.len > 0) {
            sys_normal = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ sys_normal, skill_catalog });
        }
    }
    // #326: this returns the composed BASE only. prompts.setSystemPrompts()
    // (called once by buildRootAgent, the sole consumer) derives
    // sys_normal/sys_strict/sys_ultra/sys_ultra_strict from it — the single
    // funnel every later mutation (repl, set_agent, set_system_prompt) must
    // also go through, so none of the four ever go stale independently.
    return sys_normal;
}

const args = @import("args.zig");
const mcp_cli = @import("mcp_cli.zig");
const learn_cli = @import("learn_cli.zig");
const cli = @import("cli.zig");
const jobs = @import("jobs.zig");
const cube = @import("cube.zig");
const schema = @import("schema.zig");
const serve = @import("serve.zig");
const main_mod = @import("main.zig");

/// The early subcommand/flag branches that exit before any credential
/// resolution or Agent construction happens — `--help`/`--version`, `key`,
/// `mcp add`, `login`, `serve`, `update`, `worktree` (list/merge), `sandboxes`,
/// `cube`, and `--schema`. Moved verbatim out of main() (600-line goal,
/// #123 follow-up). Returns true when a branch handled the run and main()
/// should return immediately without going any further (credential
/// resolution, Agent construction, the REPL/turn loop, ...).
pub fn runSubcommand(io: Io, gpa: Allocator, arena: Allocator, init: std.process.Init, flags: args.Flags) !bool {
    // `--help` / `--version`: handled before any subcommand dispatch, so
    // `harness login --help` prints usage instead of starting an OAuth flow.
    if (flags.help_flag or flags.version_flag) {
        var hbuf: [4096]u8 = undefined;
        var hw = Io.File.stdout().writer(io, &hbuf);
        if (flags.help_flag) try hw.interface.writeAll(cli.usage_text) else try hw.interface.print("graff {s}\n\n{s}", .{ main_mod.harness_version, cli.changelog_text });
        try hw.interface.flush();
        return true;
    }
    router_config.load(io, arena) catch |err|
        std.process.fatal("invalid {s}: {s}", .{ router_config.path, @errorName(err) });
    // #402: pin THE codex credential directory ($CODEX_HOME, else ~/.codex) before
    // anything can read or write auth.json — `graff login` is dispatched below,
    // and every later reader (startup, /login, the mid-turn refresh, subagents)
    // resolves through this one answer instead of guessing.
    oauth.initCodexHome(arena, init.environ_map.get("CODEX_HOME"), keys_cli.homeEnv(init.environ_map));
    // #477: same pin for the kimi/xai credential files, so home-less side
    // agents (the pre-compaction note, title, reflect) resolve the ONE file
    // the login flow writes instead of "/.kimi/...".
    oauth.initHome(keys_cli.homeEnv(init.environ_map) orelse "");
    // #557: same pin for GRAFF_PRICES_PATH, before `graff models` is dispatched
    // below — the hydration points (router_catalog, models_cache) all sit well
    // under the last call that still holds the environment.
    pricing_db.initOverride(init.environ_map.get("GRAFF_PRICES_PATH"));

    // `harness key set <provider> <key>` / `harness key list`: safe key store
    // (macOS Keychain, else a 0600 file). Exits after.
    if (flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "key")) {
        const home = keys_cli.homeEnv(init.environ_map) orelse std.process.fatal("no HOME/USERPROFILE", .{});
        try keys_cli.keyCommand(io, gpa, arena, home, flags.positionals.items[1..]);
        return true;
    }

    // MCP list/login read the workspace config merged with the user-level
    // ~/.codegraff/mcp.json (hence environ_map, for the GRAFF_MCP_CONFIG
    // override); add still writes workspace-only. OAuth login validates HOME itself.
    if (flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "mcp")) {
        const home = keys_cli.homeEnv(init.environ_map) orelse "";
        // CLI never reaches session_settings.applyEnvKnobs; honor the same
        // GRAFF_NO_PLUGINS gate the REPL / --json session uses.
        plugins.applyEnv(init.environ_map);
        try mcp_cli.mcpCommand(io, gpa, arena, home, init.environ_map, flags.positionals.items[1..]);
        return true;
    }

    if (flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "plugins")) {
        const home = keys_cli.homeEnv(init.environ_map) orelse "";
        plugins.applyEnv(init.environ_map);
        try plugins.command(io, arena, home, flags.positionals.items[1..]);
        return true;
    }

    // `graff learn ...`: local immutable policy learning. It runs before key
    // resolution and normal session construction; configured child tools get
    // only their explicitly allowlisted environment.
    if (flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "learn")) {
        learn_cli.command(io, gpa, arena, init, flags.positionals.items[1..]) catch |err|
            std.process.fatal("learn: {s}", .{@errorName(err)});
        return true;
    }

    // `harness login [codex] [--refresh]`: OAuth login. Default target is
    // codegraff (device-code flow, writes ~/.simple-harness-codegraff.json);
    // `codex` (or --refresh) runs the ChatGPT PKCE/refresh flow → ~/.codex/auth.json.
    if (flags.login_flag) {
        const home = keys_cli.homeEnv(init.environ_map) orelse std.process.fatal("no HOME/USERPROFILE", .{});
        if (flags.xai_login) try oauth.xaiLogin(io, gpa, arena, home) else if (flags.kimi_login) try oauth.kimiLogin(io, gpa, arena, home) else if (flags.codex_login or flags.refresh_flag) try oauth.codexLogin(io, gpa, arena, home, flags.refresh_flag) else try oauth.codegraffLogin(io, gpa, arena, home);
        return true;
    }

    // `harness serve`: HTTP/NDJSON bridge over the --json protocol — each
    // session is a `harness --json` child of this same binary. Keys are
    // loaded by the children, not here.
    if (flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "serve")) {
        const token = flags.token_flag orelse init.environ_map.get("HARNESS_SERVE_TOKEN") orelse init.environ_map.get("GRAFF_SERVE_TOKEN");
        const exe = std.process.executablePathAlloc(io, arena) catch
            std.process.fatal("serve: cannot resolve own executable path", .{});
        try serve.serveMain(gpa, io, .{
            .host = flags.host_flag,
            .port = flags.port_flag,
            .token = token,
            .yolo = flags.yolo_flag,
            .model = flags.model_flag,
            .subagent_provider = flags.subagent_provider_flag,
            .subagent_model = flags.subagent_model_flag,
            .allow_cross_provider_subagents = flags.allow_cross_provider_subagents_flag,
            .no_subagent_tier = flags.no_subagent_tier_flag,
            .system_prompt = flags.system_prompt_flag,
            .append_system_prompt = flags.append_system_flag,
            .max_tool_calls = main_mod.max_tool_calls,
            .max_model_calls = main_mod.max_model_calls,
            .dedupe_tool_calls = main_mod.dedupe_tool_calls,
        }, exe);
        return true;
    }

    // `harness update [--force|--check]`: self-update to the latest GitHub
    // release. Version-checked (skips if already current), reuses install.sh
    // for the actual download/codesign/atomic swap. Exits after.
    if (flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "update")) {
        // --check never installs, so --force has no effect on it — reject the
        // contradictory combination up front rather than silently ignoring one.
        if (flags.update_force and flags.update_check)
            std.process.fatal("--force and --check are mutually exclusive — use `graff update` (without --check) to install", .{});
        try cli.updateCommand(io, gpa, arena, init.environ_map, flags.update_force, flags.update_check);
        return true;
    }

    // `graff worktree list` / `graff worktree merge <name>`: manage the per-tab
    // scratch worktrees that -w creates. merge squash-lands a tab's work as one
    // clean commit on the current branch, then removes the worktree + branch.
    if (flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "worktree")) {
        try jobs.worktreeCommand(gpa, io, arena, flags.positionals.items[1..]);
        return true;
    }

    // `graff sandboxes [stop <id>]`: list the account's gateway sandboxes or
    // spin one down. Key resolution mirrors a normal run: CODEGRAFF_API_KEY
    // env first, else the `graff login` file via loadCodegraffKey.
    if (flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "sandboxes")) {
        const cg_key = init.environ_map.get("CODEGRAFF_API_KEY") orelse
            (if (keys_cli.homeEnv(init.environ_map)) |home| oauth.loadCodegraffKey(io, arena, home) else null) orelse
            std.process.fatal("sandboxes: no codegraff key — run `graff login` first", .{});
        try cube.sandboxesCommand(io, gpa, arena, cg_key, flags.positionals.items[1..]);
        return true;
    }

    // `graff cube [new|status|stop]`: a personal cloud graff — a gateway
    // sandbox running `graff serve` behind a Daytona preview URL. This is the
    // broker the iOS app mirrors; any serve client can attach with the
    // printed base + token.
    if (flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "cube")) {
        const cg_key = init.environ_map.get("CODEGRAFF_API_KEY") orelse
            (if (keys_cli.homeEnv(init.environ_map)) |home| oauth.loadCodegraffKey(io, arena, home) else null) orelse
            std.process.fatal("cube: no codegraff key — run `graff login` first", .{});
        try cube.cubeCommand(io, gpa, arena, cg_key, flags.positionals.items[1..]);
        return true;
    }

    // `graff models [refresh]` / `graff route <model>…`: print the catalog or
    // pull fresh metadata; route dry-runs provider seating on the same caches.
    if (flags.positionals.items.len > 0 and (std.mem.eql(u8, flags.positionals.items[0], "models") or std.mem.eql(u8, flags.positionals.items[0], "route"))) {
        const home = keys_cli.homeEnv(init.environ_map) orelse std.process.fatal("no HOME/USERPROFILE", .{});
        const codex_home = oauth.codexHomeDir(arena, home) orelse "";
        const codex_auth = oauth.loadCodexAuthFrom(io, arena, codex_home);
        const refreshing = flags.positionals.items.len > 1 and
            (std.mem.eql(u8, flags.positionals.items[1], "refresh") or
                std.mem.eql(u8, flags.positionals.items[1], "--refresh") or
                std.mem.eql(u8, flags.positionals.items[1], "update"));
        models_cache.loadCodexCatalog(
            io,
            gpa,
            arena,
            home,
            codex_home,
            if (codex_auth) |auth| auth.token else "",
            if (codex_auth) |auth| auth.account else "",
            refreshing,
            true,
        );
        const kimi_token = init.environ_map.get("KIMI_API_KEY") orelse oauth.loadKimiOAuth(io, gpa, arena, home, false, null) orelse "";
        _ = kimi_catalog.load(io, gpa, arena, home, kimi_token);
        var router_keys: provider_mod.Keys = .{ .values = @splat(null) };
        for (provider_mod.provider_specs, &router_keys.values, &router_keys.sources) |spec, *value, *source| {
            if (!router_catalog.dynamic(spec)) continue;
            // Prefer flat-rate device logins over env keys so `graff models`
            // sees the same SuperGrok/Kimi session the REPL would, and so
            // always-live xAI catalog GETs send X-XAI-Token-Auth.
            if (spec.login == .xai_device) {
                if (oauth.loadXaiOAuth(io, gpa, arena, home, false, null)) |tok| {
                    value.* = tok;
                    source.* = .login;
                    continue;
                }
            } else if (spec.login == .kimi_device) {
                if (oauth.loadKimiOAuth(io, gpa, arena, home, false, null)) |tok| {
                    value.* = tok;
                    source.* = .login;
                    continue;
                }
            } else if (spec.login == .codegraff_device) {
                if (oauth.loadCodegraffKey(io, arena, home)) |tok| {
                    value.* = tok;
                    source.* = .login;
                    continue;
                }
            }
            if (init.environ_map.get(spec.env_key)) |env_key| {
                value.* = env_key;
                source.* = .environment;
            } else if (keys_cli.loadStoredKey(io, arena, home, spec.id)) |stored| {
                value.* = stored;
                source.* = .stored;
            }
        }
        if (provider_mod.additional_router) |spec| {
            router_keys.router_value = init.environ_map.get(spec.env_key) orelse
                keys_cli.loadStoredKey(io, arena, home, spec.id);
            router_keys.router_source = if (router_keys.router_value != null) .stored else .none;
        }
        router_catalog.loadAll(io, gpa, arena, home, router_keys, refreshing);
        if (std.mem.eql(u8, flags.positionals.items[0], "route")) try @import("route_check.zig").command(io, gpa, arena, init.environ_map, flags.positionals.items[1..]) else try models_cache.command(io, gpa, arena, home, flags.positionals.items[1..]);
        return true;
    }

    // `--schema`: print the machine-readable interface and exit. Still no keys,
    // network, or MCP — so it works anywhere (CI codegen calls this). The one
    // reads are router catalog caches a normal run already wrote: the GUI
    // builds its model picker from this output, so without it the picker shows
    // a release-old snapshot of a list the gateway changes on its own schedule.
    // No cache (CI, fresh install) → the baked table, byte-identical to before.
    if (flags.schema_flag) {
        router_catalog.loadCachedAll(io, arena, keys_cli.homeEnv(init.environ_map) orelse "");
        var sbuf: [8 * 1024]u8 = undefined;
        var sw = Io.File.stdout().writer(io, &sbuf);
        try schema.emitSchema(&sw.interface);
        return true;
    }
    return false;
}
