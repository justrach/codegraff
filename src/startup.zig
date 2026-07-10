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
const serde = @import("serde.zig");
const skills = @import("skills.zig");
const prompts = @import("prompts.zig");

pub const ResolvedKeys = struct {
    keys: provider_mod.Keys,
    default_provider: provider_mod.Provider,
    stale_saved_model: ?[]const u8,
    codex_account: ?[]const u8,
};

/// Resolves API keys/credentials (env vars → codegraff/codex/kimi on-disk
/// logins → the `harness key set` store, env always wins — same precedence
/// as before) and picks the startup model (--model flag, else the
/// last-saved model if it's still in the catalog). Carved out of main()'s
/// former inline credential-loading block verbatim; fatals via
/// std.process.fatal exactly as that block did (no key found, or a bad
/// --model value).
pub fn resolveKeys(io: Io, gpa: Allocator, arena: Allocator, environ_map: anytype, model_flag: ?[]const u8) !ResolvedKeys {
    var keys: provider_mod.Keys = .{ .values = undefined };
    for (provider_mod.provider_specs, &keys.values) |spec, *value| {
        value.* = environ_map.get(spec.env_key);
    }
    // Codegraff "login": if CODEGRAFF_API_KEY isn't set, pick up a key from
    // `harness login codegraff` (~/.simple-harness-codegraff.json) or graff's
    // own store (~/forge/.credentials.json) — read-only, env always wins.
    if (keys_cli.homeEnv(environ_map)) |home| {
        for (provider_mod.provider_specs, &keys.values) |spec, *value| {
            if (std.mem.eql(u8, spec.id, "codegraff") and value.* == null)
                value.* = oauth.loadCodegraffKey(io, arena, home);
        }
    }
    // Codex "login": read the ChatGPT OAuth token from ~/.codex/auth.json
    // (written by the Codex CLI) instead of an env var — same on-disk
    // credential pattern as the codegraff key in ~/forge/.credentials.json.
    var codex_account: ?[]const u8 = null;
    if (keys_cli.homeEnv(environ_map)) |home| {
        if (oauth.loadCodexAuth(io, arena, home)) |auth| {
            for (provider_mod.provider_specs, &keys.values) |spec, *value| {
                if (std.mem.eql(u8, spec.id, "codex")) value.* = auth.token;
            }
            keys.codex_account = auth.account;
            codex_account = auth.account;
        }
    }
    // Kimi "login": OAuth device-flow token from `graff login kimi`
    // (~/.kimi/credentials/graff-oauth.json), refreshed in place when near
    // expiry. Same on-disk-credential pattern as codex/codegraff; env wins.
    if (keys_cli.homeEnv(environ_map)) |home| {
        for (provider_mod.provider_specs, &keys.values) |spec, *value| {
            if (std.mem.eql(u8, spec.id, "kimi") and value.* == null)
                value.* = oauth.loadKimiOAuth(io, gpa, arena, home);
        }
    }
    // Stored keys (macOS Keychain / 0600 file via `harness key set`): fill any
    // provider slot still empty after env + the login loaders. env always wins.
    if (keys_cli.homeEnv(environ_map)) |home| {
        for (provider_mod.provider_specs, &keys.values) |spec, *value| {
            if (value.* == null) value.* = keys_cli.loadStoredKey(io, arena, home, spec.id);
        }
    }
    // Apply the models.dev refresh cache (if `graff models refresh` ever ran)
    // before any Provider is built, so contextFor()/priceFor() use the fresh
    // window/price. No cache → a no-op; the baked catalog stays authoritative.
    if (keys_cli.homeEnv(environ_map)) |home| models_cache.loadOverlay(io, arena, home);
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
    // `--model <name|provider>` pins the startup model (same resolution as /model).
    if (model_flag) |mname| pick: {
        for (provider_mod.provider_specs) |spec| if (std.mem.eql(u8, spec.id, mname)) {
            if (keys.providerById(spec.id, spec.default_model)) |p| {
                default_provider = p;
                break :pick;
            } else |_| std.process.fatal("no key/login for provider '{s}' (--model)", .{mname});
        };
        const nm = pricing.resolveModelName(keys, mname) orelse mname;
        default_provider = keys.providerFor(nm) catch std.process.fatal("no key/login for --model '{s}' — see /models", .{mname});
    } else if (serde.loadModel(io, arena, keys_cli.homeEnv(environ_map) orelse "")) |saved| {
        // No --model flag: resume the model chosen last session only if that
        // exact provider/model pair is still in the catalog; model names can be
        // shared by providers with different support.
        if (pricing.providerModelInTable(saved.pid, saved.model)) {
            if (keys.providerById(saved.pid, saved.model)) |p| default_provider = p else |_| {}
        } else stale_saved_model = saved.model;
    }
    return .{ .keys = keys, .default_provider = default_provider, .stale_saved_model = stale_saved_model, .codex_account = codex_account };
}

pub const SystemPrompt = struct {
    sys_normal: []const u8,
    sys_strict: []const u8,
};

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
pub fn buildSystemPrompt(
    io: Io,
    arena: Allocator,
    out: *Io.Writer,
    system_prompt_flag: ?[]const u8,
    append_system_flag: ?[]const u8,
    quiet: bool,
    mcp_tools: []const mcp.Tool,
    codedbpro_licensed: bool,
) !SystemPrompt {
    const base_prompt: []const u8 = system_prompt_flag orelse prompts.main_system_prompt;
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
    const sys_strict: []const u8 = try std.fmt.allocPrint(arena, "{s}{s}", .{ sys_normal, prompts.strict_note });
    return .{ .sys_normal = sys_normal, .sys_strict = sys_strict };
}

const args = @import("args.zig");
const mcp_cli = @import("mcp_cli.zig");
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

    // `harness key set <provider> <key>` / `harness key list`: safe key store
    // (macOS Keychain, else a 0600 file). Exits after.
    if (flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "key")) {
        const home = keys_cli.homeEnv(init.environ_map) orelse std.process.fatal("no HOME/USERPROFILE", .{});
        try keys_cli.keyCommand(io, gpa, arena, home, flags.positionals.items[1..]);
        return true;
    }

    // `harness mcp add <name> -- <command> [args...]`: write workspace MCP config.
    if (flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "mcp")) {
        try mcp_cli.mcpCommand(io, arena, flags.positionals.items[1..]);
        return true;
    }

    // `harness login [codex] [--refresh]`: OAuth login. Default target is
    // codegraff (device-code flow, writes ~/.simple-harness-codegraff.json);
    // `codex` (or --refresh) runs the ChatGPT PKCE/refresh flow → ~/.codex/auth.json.
    if (flags.login_flag) {
        const home = keys_cli.homeEnv(init.environ_map) orelse std.process.fatal("no HOME/USERPROFILE", .{});
        if (flags.kimi_login) try oauth.kimiLogin(io, gpa, arena, home) else if (flags.codex_login or flags.refresh_flag) try oauth.codexLogin(io, gpa, arena, home, flags.refresh_flag) else try oauth.codegraffLogin(io, gpa, arena, home);
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
            .system_prompt = flags.system_prompt_flag,
            .append_system_prompt = flags.append_system_flag,
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

    // `graff models [refresh]`: print the effective model catalog, or pull
    // fresh window/price metadata from models.dev into the local cache.
    if (flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "models")) {
        const home = keys_cli.homeEnv(init.environ_map) orelse std.process.fatal("no HOME/USERPROFILE", .{});
        try models_cache.command(io, gpa, arena, home, flags.positionals.items[1..]);
        return true;
    }

    // `--schema`: print the machine-readable interface and exit. No keys,
    // network, or MCP — so it works anywhere (CI codegen calls this).
    if (flags.schema_flag) {
        var sbuf: [8 * 1024]u8 = undefined;
        var sw = Io.File.stdout().writer(io, &sbuf);
        try schema.emitSchema(&sw.interface);
        return true;
    }
    return false;
}
