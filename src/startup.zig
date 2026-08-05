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
const pricing = @import("pricing.zig");
const models_cache = @import("models_cache.zig");
const kimi_catalog = @import("kimi_catalog.zig");
const catalog_selection = @import("catalog_selection.zig");
const router_config = @import("router_config.zig");
const router_catalog = @import("router_catalog.zig");
const subagent_selection = @import("subagent_selection.zig");
const serde = @import("serde.zig");
const skills = @import("skills.zig");
const skill_docs = @import("skill_docs.zig");
const fleet = @import("fleet.zig"); // g_home: resolved before any prompt build (session_run.initApprovalsHooksFleet)
const prompts = @import("prompts.zig");
const learn_store = @import("learn_store.zig");
const learn_bootstrap = @import("learn_bootstrap.zig");
const learn_auto = @import("learn_auto.zig");
const imagegen = @import("imagegen.zig"); // #352: codex-skill detection + the personal-tier skill mirror

pub const ResolvedKeys = struct {
    keys: provider_mod.Keys,
    default_provider: provider_mod.Provider,
    stale_saved_model: ?[]const u8,
    preferred_provider: ?[]const u8,
    codex_account: ?[]const u8,
    model_catalog: models_cache.LazyCodexCatalog,
    stored_keys_loaded: bool,
};

fn explicitProvider(model_flag: ?[]const u8) ?[]const u8 {
    return catalog_selection.explicitProvider(model_flag orelse return null);
}

/// Whether one stored credential can affect an explicit startup selection:
/// provider ids need one key; exact catalog models need only providers that
/// serve them (aliases/fuzzy retain the full scan); --subagent-provider (worker_hint) is
/// equally explicit — that provider WILL be used. pub only for startup_tests.zig (at cap).
pub fn storedKeyMayAffectSelection(provider_id: []const u8, model_flag: ?[]const u8, worker_hint: ?[]const u8) bool {
    const query = model_flag orelse return true;
    if (worker_hint) |h| if (std.mem.eql(u8, provider_id, h)) return true;
    if (explicitProvider(query)) |id| return std.mem.eql(u8, provider_id, id);
    if (pricing.modelInTable(query)) return pricing.providerModelInTable(provider_id, query);
    return true;
}

fn hasSelectiveStoredKeyScope(model_flag: ?[]const u8) bool {
    return if (model_flag) |query| explicitProvider(query) != null or pricing.modelInTable(query) else false;
}

pub fn startupStoredKeyScope(model_flag: ?[]const u8, selective: bool, worker_hint: ?[]const u8) keys_cli.StoredKeyScope {
    if (!selective) return .all;
    if (worker_hint == null) if (explicitProvider(model_flag)) |id| return .{ .provider = id };
    var mask: [provider_mod.provider_specs.len]bool = @splat(false);
    for (provider_mod.provider_specs, 0..) |spec, i|
        mask[i] = storedKeyMayAffectSelection(spec.id, model_flag, worker_hint);
    return .{ .mask = mask };
}

pub const resolveSubagentProvider = subagent_selection.resolveSubagentProvider;

test "Codex catalog loads at startup only when selection can observe it" {
    try std.testing.expectEqualStrings("deepseek", explicitProvider("deepseek").?);
    try std.testing.expect(explicitProvider("deepseek-v4-pro") == null);
    try std.testing.expect(explicitProvider(null) == null);
    try std.testing.expect(hasSelectiveStoredKeyScope("deepseek-v4-pro"));
    try std.testing.expect(storedKeyMayAffectSelection("codegraff", "deepseek-v4-pro", null));
    try std.testing.expect(storedKeyMayAffectSelection("deepseek", "deepseek-v4-pro", null));
    try std.testing.expect(!storedKeyMayAffectSelection("anthropic", "deepseek-v4-pro", null));
    try std.testing.expect(storedKeyMayAffectSelection("anthropic", "opus", null));
    try std.testing.expect(storedKeyMayAffectSelection("openai", null, null));
    const exact_scope = startupStoredKeyScope("deepseek-v4-pro", true, null);
    try std.testing.expect(exact_scope.includes(1, "codegraff"));
    try std.testing.expect(exact_scope.includes(2, "deepseek"));
    try std.testing.expect(!exact_scope.includes(0, "anthropic"));

    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    for (provider_mod.provider_specs, &keys.values) |spec, *value| {
        if (std.mem.eql(u8, spec.id, "deepseek") or std.mem.eql(u8, spec.id, "codex")) value.* = "test";
    }
    keys.codex_account = "account";

    try std.testing.expect(!catalog_selection.startupMayUse(keys, "codex", "deepseek", null));
    try std.testing.expect(catalog_selection.startupMayUse(keys, "codex", "codex", null));
    try std.testing.expect(catalog_selection.startupMayUse(keys, "codex", "future-account-rollout", null));
    try std.testing.expect(!catalog_selection.startupMayUse(keys, "codex", null, .{ .pid = "deepseek", .model = "deepseek-v4-pro" }));
    try std.testing.expect(!catalog_selection.startupMayUse(keys, "codex", null, null));

    for (provider_mod.provider_specs, &keys.values) |spec, *value| {
        if (std.mem.eql(u8, spec.id, "deepseek")) value.* = null;
    }
    try std.testing.expect(catalog_selection.startupMayUse(keys, "codex", null, null));
    try std.testing.expect(catalog_selection.startupMayUse(keys, "codex", null, .{ .pid = "deepseek", .model = "deepseek-v4-pro" }));

    for (provider_mod.provider_specs, &keys.values) |spec, *value| {
        if (std.mem.eql(u8, spec.id, "codex")) value.* = null;
    }
    try std.testing.expect(!catalog_selection.startupMayUse(keys, "codex", "codex", null));
}

test "Kimi catalog loads at startup only when selection can observe it" {
    var keys: provider_mod.Keys = .{ .values = @splat(null) };
    for (provider_mod.provider_specs, &keys.values) |spec, *value| {
        if (std.mem.eql(u8, spec.id, "kimi") or std.mem.eql(u8, spec.id, "codegraff")) value.* = "token";
    }
    try std.testing.expect(!catalog_selection.startupMayUse(keys, "kimi", "codegraff", null));
    try std.testing.expect(catalog_selection.startupMayUse(keys, "kimi", "kimi", null));
    try std.testing.expect(catalog_selection.startupMayUse(keys, "kimi", "k3", null));
    try std.testing.expect(catalog_selection.startupMayUse(keys, "kimi", "future-kimi-rollout", null));
    try std.testing.expect(!catalog_selection.startupMayUse(keys, "kimi", null, .{ .pid = "codegraff", .model = "deepseek-v4-pro" }));
    try std.testing.expect(catalog_selection.startupMayUse(keys, "kimi", null, .{ .pid = "kimi", .model = "k3" }));
}

/// Resolves API keys/credentials (env vars → codegraff/codex/kimi on-disk
/// logins → the `harness key set` store, env always wins — same precedence
/// as before) and picks the startup model (--model flag, else the
/// last-saved model if it's still in the catalog). Carved out of main()'s
/// former inline credential-loading block verbatim; fatals via
/// std.process.fatal exactly as that block did (no key found, or a bad
/// --model value).
pub fn resolveKeys(io: Io, gpa: Allocator, arena: Allocator, environ_map: anytype, model_flag: ?[]const u8, worker_provider_hint: ?[]const u8) !ResolvedKeys {
    var keys: provider_mod.Keys = .{ .values = undefined };
    for (provider_mod.provider_specs, &keys.values, &keys.sources) |spec, *value, *source| {
        value.* = environ_map.get(spec.env_key);
        source.* = if (value.* != null) .environment else .none;
    }
    if (provider_mod.additional_router) |spec| {
        keys.router_value = environ_map.get(spec.env_key);
        keys.router_source = if (keys.router_value != null) .environment else .none;
    }
    // Codegraff "login": if CODEGRAFF_API_KEY isn't set, pick up a key from
    // `harness login codegraff` (~/.simple-harness-codegraff.json) or graff's
    // own store (~/forge/.credentials.json) — read-only, env always wins.
    if (keys_cli.homeEnv(environ_map)) |home| {
        for (provider_mod.provider_specs, &keys.values, &keys.sources) |spec, *value, *source| {
            if (std.mem.eql(u8, spec.id, "codegraff") and value.* == null) {
                if (oauth.loadCodegraffKey(io, arena, home)) |key| {
                    value.* = key;
                    source.* = .login;
                }
            }
        }
    }
    // Codex "login": read the ChatGPT OAuth token from CODEX_HOME/auth.json
    // (default ~/.codex/auth.json, written by the Codex CLI) instead of an env
    // var. The same directory is used for native model-catalog discovery.
    var codex_account: ?[]const u8 = null;
    if (keys_cli.homeEnv(environ_map)) |home| {
        if (oauth.loadCodexAuthFrom(io, arena, oauth.codexHomeDir(arena, home) orelse "")) |auth| {
            for (provider_mod.provider_specs, &keys.values, &keys.sources) |spec, *value, *source| {
                if (std.mem.eql(u8, spec.id, "codex")) {
                    value.* = auth.token;
                    source.* = .login;
                }
            }
            keys.codex_account = auth.account;
            codex_account = auth.account;
        }
    }
    // Kimi "login": OAuth device-flow token from `graff login kimi`
    // (~/.kimi/credentials/graff-oauth.json), refreshed in place when near
    // expiry. Same on-disk-credential pattern as codex/codegraff; env wins.
    // #274: refreshing is a synchronous network round-trip, so an explicit
    // provider/exact-model selection that cannot route to kimi/xai must skip
    // it entirely rather than pay for it on every startup — same selective-
    // scope discipline as the stored-key load a few lines below.
    if (keys_cli.homeEnv(environ_map)) |home| {
        for (provider_mod.provider_specs, &keys.values, &keys.sources) |spec, *value, *source| {
            if (std.mem.eql(u8, spec.id, "kimi") and value.* == null and storedKeyMayAffectSelection(spec.id, model_flag, worker_provider_hint)) {
                if (oauth.loadKimiOAuth(io, gpa, arena, home, false, null)) |key| {
                    value.* = key;
                    source.* = .login;
                }
            }
            if (std.mem.eql(u8, spec.id, "xai") and value.* == null and storedKeyMayAffectSelection(spec.id, model_flag, worker_provider_hint)) {
                if (oauth.loadXaiOAuth(io, gpa, arena, home, false, null)) |key| {
                    value.* = key;
                    source.* = .login;
                }
            }
        }
    }
    // An explicit provider or exact catalog model can observe only its
    // candidate providers. Load those stored keys now; model/fallback/resume
    // surfaces fill the rest on demand. Aliases/default startup still need all
    // keys because availability participates in their routing tie-break.
    const selective_stored_keys = hasSelectiveStoredKeyScope(model_flag);
    var stored_keys_loaded = !selective_stored_keys;
    if (keys_cli.homeEnv(environ_map)) |home| {
        if (selective_stored_keys) {
            keys_cli.loadMissingStoredKeys(io, gpa, arena, home, &keys, startupStoredKeyScope(model_flag, true, worker_provider_hint));
            // Preserve the old diagnostics/fallback behavior when none of the
            // selective candidates has any credential: only failed launches
            // pay for the exhaustive scan.
            if (keys.defaultProvider()) |_| {} else |_| {
                keys_cli.loadMissingStoredKeys(io, gpa, arena, home, &keys, .all);
                stored_keys_loaded = true;
            }
        } else keys_cli.loadMissingStoredKeys(io, gpa, arena, home, &keys, .all);
    }
    const home = keys_cli.homeEnv(environ_map) orelse "";
    var model_catalog: models_cache.LazyCodexCatalog = .{ .codex_home = oauth.codexHomeDir(arena, home) orelse "" };
    const saved_model: ?serde.SavedModel = if (model_flag == null) serde.loadModel(io, arena, home) else null;
    // Dynamic Codex discovery is observable only when startup may select
    // Codex. Explicit/saved non-Codex launches defer the version subprocess,
    // native-cache parse, and possible refresh until a model surface needs it.
    // Codex-observable launches accept the local snapshot (even stale) without
    // network I/O; model surfaces go online via ensure() when they need it.
    if (catalog_selection.startupMayUse(keys, "codex", model_flag, saved_model))
        model_catalog.ensureCached(io, gpa, arena, home, keys.get("codex") orelse "", keys.codex_account);
    if (catalog_selection.startupMayUse(keys, "kimi", model_flag, saved_model))
        kimi_catalog.ensure(io, gpa, arena, home, keys.get("kimi") orelse "");
    router_catalog.ensureForStartup(io, gpa, arena, home, keys, model_flag, saved_model);
    if (home.len != 0) {
        // Apply the independent models.dev price/context overlay after routing
        // discovery. Provider-specific Codex windows remain authoritative.
        models_cache.loadOverlay(io, arena, home);
    }
    var default_provider = keys.defaultProvider() catch {
        std.process.fatal(
            \\no API key found. quickest fixes:
            \\  graff login                         free codegraff key (device-code OAuth)
            \\  graff key set <provider> <key>      store a key (macOS Keychain, else 0600 file)
            \\  export ANTHROPIC_API_KEY=sk-ant-…   or CODEGRAFF/DEEPSEEK/OPENAI/MINIMAX/XIAOMI/KIMI/MOONSHOT/XAI/ZAI _API_KEY
            \\a Codex CLI login (~/.codex/auth.json) is also picked up automatically.
        , .{});
    };
    var stale_saved_model: ?[]const u8 = null;
    var preferred_provider: ?[]const u8 = null;
    // `--model <name|provider>` pins the startup model (same resolution as /model).
    if (model_flag) |mname| pick: {
        if (provider_mod.specFor(mname)) |spec| {
            const model = pricing.providerDefaultModel(spec.id, spec.default_model);
            if (keys.providerById(spec.id, model)) |p| {
                default_provider = p;
                break :pick;
            } else |_| std.process.fatal("no key/login for provider '{s}' (--model)", .{mname});
        }
        const nm = pricing.resolveModelName(keys, mname) orelse std.process.fatal("unknown --model '{s}' — run `graff models refresh` or see /models", .{mname});
        default_provider = keys.providerFor(nm) catch {
            // #294: name the credential that actually needs repair. A Codex-only
            // model with an expired ~/.codex/auth.json used to be rerouted to the
            // gateway and surface as a CodeGraff error; now it fails here, so the
            // message must point at the right login rather than "see /models".
            var pbuf: [provider_mod.provider_specs.len + 1][]const u8 = undefined;
            const serving = provider_mod.catalogProvidersFor(&pbuf, nm);
            if (serving.len > 0) std.process.fatal(
                "'{s}' is served by {s}, which has no valid credential — run `graff login {s}` or `graff key set {s} <key>`",
                .{ nm, serving[0], serving[0], serving[0] },
            );
            std.process.fatal("no key/login for --model '{s}' — see /models", .{mname});
        };
    } else if (saved_model) |saved| {
        preferred_provider = saved.pid;
        // No --model flag: resume the model chosen last session only if that
        // exact provider/model pair is still in the catalog; model names can be
        // shared by providers with different support.
        if (pricing.providerModelInTable(saved.pid, saved.model)) {
            if (keys.providerById(saved.pid, saved.model)) |p| {
                default_provider = p;
            } else |_| {
                stale_saved_model = std.fmt.allocPrint(arena, "{s}/{s}", .{ saved.pid, saved.model }) catch saved.model;
            }
        } else {
            stale_saved_model = std.fmt.allocPrint(arena, "{s}/{s}", .{ saved.pid, saved.model }) catch saved.model;
            // A rollout may remove only this model while the provider login is
            // still healthy. Prefer that provider's current dynamic default
            // before crossing provider/account boundaries.
            if (provider_mod.specFor(saved.pid)) |spec| {
                const replacement = pricing.providerDefaultModel(spec.id, spec.default_model);
                if (keys.providerById(spec.id, replacement)) |p| default_provider = p else |_| {}
            }
        }
    }
    return .{ .keys = @import("bench_priors.zig").noteKeysAtStartup(keys, io, arena, keys_cli.homeEnv(environ_map)), .default_provider = default_provider, .stale_saved_model = stale_saved_model, .preferred_provider = preferred_provider, .codex_account = codex_account, .model_catalog = model_catalog, .stored_keys_loaded = stored_keys_loaded };
}

/// Root system-prompt layering, frozen at startup so it stays
/// KV-cache-friendly: built-in base (or its --system-prompt replacement),
/// then project instructions from the first of AGENTS.md/HARNESS.md/
/// CLAUDE.md found in the cwd, then --append-system-prompt text, then one
/// capability line per active optional skill, then one usage note per
/// connected MCP server. `quiet` suppresses the "loaded project
/// instructions..." status line (set by callers the same way main() used
/// to gate it: json_mode or a one-shot prompt). Carved out of main()'s
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
    mcp_tools: []const mcp.Tool,
    codedbpro_licensed: bool,
    learned_policy_env: ?[]const u8,
    environ: anytype,
) ![]const u8 {
    // A learned policy is used unless this session opted out of it.
    const learned: ?learn_store.ActiveAgent = if (system_prompt_flag == null and learn_auto.enabled(learned_policy_env)) learnedRootPolicy(io, arena) else null;
    if (learned) |policy| if (!quiet) {
        try out.print("root policy: learned generation {d} ({s})\n", .{ policy.generation, policy.genome_id[0..12] });
        try out.flush();
    };
    const base_prompt: []const u8 = system_prompt_flag orelse
        if (learned) |policy| policy.prompt else prompts.main_system_prompt;
    var sys_normal: []const u8 = base_prompt;
    for ([_][]const u8{ "AGENTS.md", "HARNESS.md", "CLAUDE.md" }) |fname| {
        const body = Io.Dir.cwd().readFileAlloc(io, fname, arena, .limited(64 * 1024)) catch continue;
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (trimmed.len == 0) continue;
        sys_normal = try std.fmt.allocPrint(arena, "{s}\n\n# Project instructions (from {s})\n{s}", .{ base_prompt, fname, trimmed });
        if (!quiet) {
            try out.print("loaded project instructions from {s} ({d} bytes)\n", .{ fname, trimmed.len });
            try out.flush();
        }
        break;
    }
    if (append_system_flag) |extra| {
        sys_normal = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ sys_normal, extra });
    }
    // Codex-style skills: one capability line per installed optional
    // companion (skills_registry) — metadata in context, --help on demand.
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
    // #352: mirror the Codex imagegen skill into ~/.harness/skills BEFORE the
    // scan below, so the copied playbook is in this session's catalog. The same
    // call decides whether `imagegen` is advertised (tool_gates.zig) and which
    // of its two engines this machine can actually run.
    imagegen.detect(io, arena, .{ .codex_home = environ.get("CODEX_HOME"), .home = fleet.g_home, .openai_api_key = environ.get("OPENAI_API_KEY"), .tmp_dir = environ.get("TMPDIR") });
    if (imagegen.available and !quiet) {
        try out.print("imagegen: Codex skill found — tool enabled ({s}), playbook at {s}\n", .{ imagegen.engineSummary(), imagegen.skill_dir });
        try out.flush();
    }
    // Markdown skills (skill_docs.zig): names + trigger descriptions only. The
    // bodies stay on disk until the model calls the `skill` tool, so a large
    // installed skill set costs a line each rather than its full text. Loaded
    // here rather than in session_run so every prompt rebuild rescans the tiers.
    skill_docs.g_skills = skill_docs.load(io, arena, fleet.g_home);
    const skill_catalog = skill_docs.promptCatalog(arena, skill_docs.g_skills);
    if (skill_catalog.len > 0) {
        sys_normal = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ sys_normal, skill_catalog });
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
        try mcp_cli.mcpCommand(io, gpa, arena, home, init.environ_map, flags.positionals.items[1..]);
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
        for (provider_mod.provider_specs, &router_keys.values) |spec, *value| {
            if (spec.catalog != .openai) continue;
            const login_key = if (spec.login == .codegraff_device) oauth.loadCodegraffKey(io, arena, home) else null;
            value.* = init.environ_map.get(spec.env_key) orelse
                login_key orelse keys_cli.loadStoredKey(io, arena, home, spec.id);
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
