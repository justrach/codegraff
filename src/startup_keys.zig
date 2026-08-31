//! Credential discovery, live catalog loading, and startup model selection.
//! Split from startup.zig so the prompt/subcommand setup stays below the
//! repository's 600-line source ceiling.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const provider_mod = @import("provider.zig");
const keys_cli = @import("keys_cli.zig");
const oauth = @import("oauth.zig");
const credential_failover = @import("credential_failover.zig");
const pricing = @import("pricing.zig");
const models_cache = @import("models_cache.zig");
const catalog_selection = @import("catalog_selection.zig");
const router_catalog = @import("router_catalog.zig");
const subagent_selection = @import("subagent_selection.zig");
const serde = @import("serde.zig");

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
    return (try resolveKeysOptional(io, gpa, arena, environ_map, model_flag, worker_provider_hint)) orelse missingCredentials();
}

fn missingCredentials() noreturn {
    // `tui`/TTY `repl` claim the pager before credential resolution. Fatal
    // exits do not unwind defers, so release that claim before stderr prints.
    @import("tui").restore.releaseIfOwned();
    std.process.fatal(
        \\no API key found. quickest fixes:
        \\  graff login                         free codegraff key (device-code OAuth)
        \\  graff key set <provider> <key>      store a key (macOS Keychain, else 0600 file)
        \\  export ANTHROPIC_API_KEY=sk-ant-…   or CODEGRAFF/DEEPSEEK/OPENAI/MINIMAX/XIAOMI/KIMI/MOONSHOT/XAI/ZAI _API_KEY
        \\a Codex CLI login (~/.codex/auth.json) is also picked up automatically.
    , .{});
}

/// The ACP bootstrap needs to distinguish "no credential yet" from startup
/// failures without manufacturing a provider. All successful resolution and
/// model-selection behavior is shared with resolveKeys above.
pub fn resolveKeysOptional(io: Io, gpa: Allocator, arena: Allocator, environ_map: anytype, model_flag: ?[]const u8, worker_provider_hint: ?[]const u8) !?ResolvedKeys {
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
    // #471: the kimi/xAI device logins outrank their env keys, and the metered
    // key is parked rather than dropped — credential_failover.preferPlan owns
    // that policy. #274: the gate stays here because only startup knows what
    // this invocation selected; a login refresh is a synchronous network call
    // no provider outside the selection should pay for.
    if (keys_cli.homeEnv(environ_map)) |home| {
        for (provider_mod.provider_specs, &keys.values, &keys.sources) |spec, *value, *source| {
            if (!storedKeyMayAffectSelection(spec.id, model_flag, worker_provider_hint)) continue;
            credential_failover.preferPlan(io, gpa, arena, home, spec, value, source);
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
    router_catalog.ensureForStartup(io, gpa, arena, home, keys, model_flag, saved_model);
    if (home.len != 0) {
        // Apply the independent models.dev price/context overlay after routing
        // discovery. Provider-specific Codex windows remain authoritative.
        models_cache.loadOverlay(io, arena, home);
    }
    var default_provider = keys.defaultProvider() catch return null;
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
