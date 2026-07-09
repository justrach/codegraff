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

const mcp = @import("mcp.zig");
const provider_mod = @import("provider.zig");
const keys_cli = @import("keys_cli.zig");
const oauth = @import("oauth.zig");
const pricing = @import("pricing.zig");
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
