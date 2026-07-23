//! CLI flag parsing for `graff`/`harness`, split out of main() (600-line
//! goal, #123 follow-up — the last file over the line goal). `Flags` bundles
//! every CLI-flag local main() used to declare at the top of its body (the
//! ~27 `var foo_flag = ...` locals), plus `positionals` and the two values
//! the old code derived from them right after the parse loop
//! (`is_subcommand`, `oneshot_prompt`).
//!
//! `parse` moves main()'s former ~130-line flag loop VERBATIM: same flag
//! names, same precedence (the `mcp` positional's "everything after this is
//! a raw positional, not a flag" special case included), same
//! `std.process.fatal` messages on a bad/unknown flag or missing value.
//! Locals just became struct-field writes.
//!
//! Back-imports main (as main_mod, the established convention — see
//! mainloop.zig/tools.zig/etc.) for the handful of globals that STAY in
//! main.zig and were only ever *set* (never read) by the parse loop itself:
//! show_timing/show_cost/json_mode/max_tool_calls/max_model_calls/dedupe_tool_calls (`--timing`
//! /`--cost`/`--json`/`--max-tool-calls`/`--max-model-calls`/`--dedupe-tool-calls`) and
//! g_worktree_autocommit (`--no-autocommit`). These are mutable globals, so
//! per the mod-prefix rule they are written through `main_mod.` — never
//! aliased (aliasing a `var` freezes its value at import time).
const std = @import("std");
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const learning_privacy = @import("learning_privacy.zig");

/// Every CLI-flag local main() used to declare, plus the resolved
/// positionals/subcommand-detection/one-shot-prompt outputs computed right
/// after the parse loop. One field per former local, same default.
pub const Flags = struct {
    yolo_flag: bool = false,
    no_telemetry_flag: bool = false,
    learning_privacy_flag: ?learning_privacy.Mode = null,
    schema_flag: bool = false,
    login_flag: bool = false,
    refresh_flag: bool = false,
    codex_login: bool = false,
    kimi_login: bool = false,
    xai_login: bool = false,
    help_flag: bool = false,
    version_flag: bool = false,
    print_flag: bool = false,
    update_force: bool = false, // graff update --force
    selftest_spinner_flag: bool = false, // --selftest-spinner: headless spinner render for the PTY anti-stealth test
    selftest_markdown_flag: bool = false, // --selftest-markdown: render the real streaming markdown fixture in a PTY
    update_check: bool = false, // graff update --check
    model_flag: ?[]const u8 = null,
    subagent_provider_flag: ?[]const u8 = null,
    subagent_model_flag: ?[]const u8 = null,
    allow_cross_provider_subagents_flag: bool = false,
    system_prompt_flag: ?[]const u8 = null,
    append_system_flag: ?[]const u8 = null,
    host_flag: []const u8 = "127.0.0.1", // harness serve
    port_flag: u16 = 8787, // harness serve
    token_flag: ?[]const u8 = null, // harness serve
    resume_flag: ?[]const u8 = null, // restore/save this named session
    goal_flag: ?[]const u8 = null, // --goal: standing objective (todos) every turn gets, incl. --json/-p
    eval_cmd_flag: ?[]const u8 = null, // --eval: scoring command for the eval-driven loop
    worktree_flag: ?[]const u8 = null, // --worktree/-w: isolate this session in a git worktree (parallel agents, no file collisions)
    eval_target_flag: ?u8 = null, // --until: target score 0-100 for the eval loop
    eval_niche_flag: ?[]const u8 = null, // --niche: fleet niche this eval-driven session optimizes (tags submitted scores)
    no_resume_flag: bool = false, // start without auto-loading last.session.json
    new_session_flag: bool = false, // start a fresh autosaved session
    positionals: std.ArrayList([]const u8) = .empty,
    /// True when positionals[0] is a known subcommand (login/key/mcp/serve/
    /// update/title/repl/worktree/sandboxes/cube) — those aren't a one-shot
    /// prompt even with no --print/-p flag.
    is_subcommand: bool = false,
    /// The joined positional args as a one-shot prompt (`harness "say hi"`
    /// or `harness -p "..."`), or null when positionals[0] is a subcommand.
    oneshot_prompt: ?[]const u8 = null,
};

/// Parses argv (via init.minimal.args) into a `Flags`. Fatals via
/// std.process.fatal on a bad/unknown flag or a missing required value —
/// identical behavior to main()'s former inline loop.
pub fn parse(init: std.process.Init) !Flags {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    var flags: Flags = .{};
    {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
        defer it.deinit();
        _ = it.next(); // argv[0]
        while (it.next()) |arg| {
            if (flags.positionals.items.len > 0 and
                (std.mem.eql(u8, flags.positionals.items[0], "mcp") or std.mem.eql(u8, flags.positionals.items[0], "learn")))
            {
                try flags.positionals.append(arena, try arena.dupe(u8, arg));
            } else if (std.mem.startsWith(u8, arg, "-")) {
                if (std.mem.eql(u8, arg, "--yolo")) {
                    flags.yolo_flag = true;
                } else if (std.mem.eql(u8, arg, "--worktree") or std.mem.eql(u8, arg, "-w")) {
                    flags.worktree_flag = it.next() orelse std.process.fatal("--worktree needs a name (e.g. --worktree agent1)", .{});
                } else if (std.mem.eql(u8, arg, "--goal")) {
                    flags.goal_flag = it.next() orelse std.process.fatal("--goal needs an objective", .{});
                } else if (std.mem.eql(u8, arg, "--eval")) {
                    flags.eval_cmd_flag = it.next() orelse std.process.fatal("--eval needs a scoring command", .{});
                } else if (std.mem.eql(u8, arg, "--until")) {
                    const uv = it.next() orelse std.process.fatal("--until needs a score 0-100", .{});
                    flags.eval_target_flag = std.fmt.parseInt(u8, uv, 10) catch std.process.fatal("--until must be a number 0-100", .{});
                } else if (std.mem.eql(u8, arg, "--niche")) {
                    flags.eval_niche_flag = it.next() orelse std.process.fatal("--niche needs a name (e.g. --niche reviewer)", .{});
                } else if (std.mem.eql(u8, arg, "--no-telemetry")) {
                    flags.no_telemetry_flag = true;
                } else if (std.mem.eql(u8, arg, "--learning-privacy")) {
                    const value = it.next() orelse std.process.fatal("--learning-privacy needs local|aggregate|templates|examples", .{});
                    flags.learning_privacy_flag = learning_privacy.parse(value) orelse std.process.fatal("invalid learning privacy mode '{s}' — use local|aggregate|templates|examples", .{value});
                } else if (std.mem.eql(u8, arg, "--timing")) {
                    main_mod.show_timing = true;
                } else if (std.mem.eql(u8, arg, "--cost")) {
                    main_mod.show_cost = true;
                } else if (std.mem.eql(u8, arg, "--json")) {
                    main_mod.json_mode = true;
                } else if (std.mem.eql(u8, arg, "--max-tool-calls")) {
                    const mv = it.next() orelse std.process.fatal("--max-tool-calls needs a non-negative integer — harness --help", .{});
                    main_mod.max_tool_calls = std.fmt.parseInt(u64, mv, 10) catch std.process.fatal("--max-tool-calls needs a non-negative integer, got '{s}'", .{mv});
                } else if (std.mem.eql(u8, arg, "--max-model-calls")) {
                    const mv = it.next() orelse std.process.fatal("--max-model-calls needs a non-negative integer — graff --help", .{});
                    main_mod.max_model_calls = std.fmt.parseInt(u64, mv, 10) catch std.process.fatal("--max-model-calls needs a non-negative integer, got '{s}'", .{mv});
                } else if (std.mem.eql(u8, arg, "--dedupe-tool-calls")) {
                    main_mod.dedupe_tool_calls = true;
                } else if (std.mem.eql(u8, arg, "--clock-sleep")) {
                    main_mod.g_clock_sleep = true; // #225: opt in to the root-only clock_sleep meta tool (also GRAFF_CLOCK_SLEEP=1)
                } else if (std.mem.eql(u8, arg, "--no-autocommit")) {
                    main_mod.g_worktree_autocommit = false;
                } else if (std.mem.eql(u8, arg, "--schema")) {
                    flags.schema_flag = true;
                } else if (std.mem.eql(u8, arg, "--refresh")) {
                    flags.refresh_flag = true;
                } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                    flags.help_flag = true;
                } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
                    flags.version_flag = true;
                } else if (std.mem.eql(u8, arg, "--selftest-spinner")) {
                    flags.selftest_spinner_flag = true;
                } else if (std.mem.eql(u8, arg, "--selftest-markdown")) {
                    flags.selftest_markdown_flag = true;
                } else if (std.mem.eql(u8, arg, "--print") or std.mem.eql(u8, arg, "-p")) {
                    flags.print_flag = true;
                } else if (std.mem.eql(u8, arg, "--force")) {
                    flags.update_force = true;
                } else if (std.mem.eql(u8, arg, "--check")) {
                    flags.update_check = true;
                } else if (std.mem.eql(u8, arg, "--resume")) {
                    const rv = it.next() orelse std.process.fatal("--resume needs a session name — harness --help", .{});
                    flags.resume_flag = try arena.dupe(u8, rv);
                } else if (std.mem.eql(u8, arg, "--no-resume")) {
                    flags.no_resume_flag = true;
                } else if (std.mem.eql(u8, arg, "--new")) {
                    flags.new_session_flag = true;
                } else if (std.mem.eql(u8, arg, "--model")) {
                    const mv = it.next() orelse std.process.fatal("--model needs a value — harness --help", .{});
                    flags.model_flag = try arena.dupe(u8, mv);
                } else if (std.mem.eql(u8, arg, "--subagent-provider")) {
                    const pv = it.next() orelse std.process.fatal("--subagent-provider needs a value — harness --help", .{});
                    flags.subagent_provider_flag = try arena.dupe(u8, pv);
                } else if (std.mem.eql(u8, arg, "--subagent-model")) {
                    const mv = it.next() orelse std.process.fatal("--subagent-model needs a value — harness --help", .{});
                    flags.subagent_model_flag = try arena.dupe(u8, mv);
                } else if (std.mem.eql(u8, arg, "--allow-cross-provider-subagents")) {
                    flags.allow_cross_provider_subagents_flag = true;
                } else if (std.mem.eql(u8, arg, "--system-prompt")) {
                    const sv = it.next() orelse std.process.fatal("--system-prompt needs a value — harness --help", .{});
                    flags.system_prompt_flag = try arena.dupe(u8, sv);
                } else if (std.mem.eql(u8, arg, "--append-system-prompt")) {
                    const av = it.next() orelse std.process.fatal("--append-system-prompt needs a value — harness --help", .{});
                    flags.append_system_flag = try arena.dupe(u8, av);
                } else if (std.mem.eql(u8, arg, "--host")) {
                    const hv = it.next() orelse std.process.fatal("--host needs a value — harness --help", .{});
                    flags.host_flag = try arena.dupe(u8, hv);
                } else if (std.mem.eql(u8, arg, "--port")) {
                    const pv = it.next() orelse std.process.fatal("--port needs a value — harness --help", .{});
                    flags.port_flag = std.fmt.parseInt(u16, pv, 10) catch std.process.fatal("--port needs a number 1-65535, got '{s}'", .{pv});
                } else if (std.mem.eql(u8, arg, "--token")) {
                    const tv = it.next() orelse std.process.fatal("--token needs a value — harness --help", .{});
                    flags.token_flag = try arena.dupe(u8, tv);
                } else {
                    std.process.fatal("unknown flag '{s}' — harness --help lists them", .{arg});
                }
            } else {
                try flags.positionals.append(arena, try arena.dupe(u8, arg));
            }
        }
        if (flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "login")) flags.login_flag = true;
        if (flags.positionals.items.len > 1 and std.mem.eql(u8, flags.positionals.items[1], "codex")) flags.codex_login = true;
        if (flags.positionals.items.len > 1 and std.mem.eql(u8, flags.positionals.items[1], "kimi")) flags.kimi_login = true;
        if (flags.positionals.items.len > 1 and std.mem.eql(u8, flags.positionals.items[1], "xai")) flags.xai_login = true;
    }

    // One-shot print mode: `harness -p "prompt"` or a bare positional prompt
    // (`harness "say hi"`). Subcommands (login/key) are not prompts.
    flags.is_subcommand = flags.positionals.items.len > 0 and
        (std.mem.eql(u8, flags.positionals.items[0], "login") or std.mem.eql(u8, flags.positionals.items[0], "key") or std.mem.eql(u8, flags.positionals.items[0], "mcp") or std.mem.eql(u8, flags.positionals.items[0], "learn") or
            std.mem.eql(u8, flags.positionals.items[0], "serve") or std.mem.eql(u8, flags.positionals.items[0], "update") or std.mem.eql(u8, flags.positionals.items[0], "title") or std.mem.eql(u8, flags.positionals.items[0], "repl") or
            std.mem.eql(u8, flags.positionals.items[0], "worktree") or std.mem.eql(u8, flags.positionals.items[0], "sandboxes") or std.mem.eql(u8, flags.positionals.items[0], "cube") or std.mem.eql(u8, flags.positionals.items[0], "models"));
    if (!flags.is_subcommand and flags.positionals.items.len > 0) {
        flags.oneshot_prompt = try std.mem.join(arena, " ", flags.positionals.items);
    }
    if (flags.print_flag and flags.oneshot_prompt == null) std.process.fatal("-p needs a prompt: harness -p \"do something\"", .{});

    return flags;
}
