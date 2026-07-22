//! Post-credential session bootstrap, split out of startup.zig (600-line
//! goal — startup.zig itself crossed the line-goal once this content grew,
//! so it lives in its own sibling file). Covers everything that happens
//! AFTER credentials/model are resolved and the http.Client exists: the
//! `graff title` subcommand, terminal-color/`-w`-worktree/banner setup,
//! opening the run-scoped trace/trajectory files + telemetry + score-signing, the MCP
//! registry connect (consent prompt + companion auto-activation), and the
//! `graff repl`/one-shot-prompt early-exit paths.
//!
//! Same dangling-pointer discipline as startup.zig: `openTraceFile`/
//! `openTrajFile` return a plain (non-self-referential) File.Writer by
//! value — main() assigns it to its OWN stable local, and only THEN takes
//! `&writer.interface` for Tracer/Trajectory's `.out` pointer, so nothing
//! points at a soon-to-be-freed stack frame. `runReplCommand`/
//! `runOneshotPrompt` take `root: *main_mod.Agent` — by this point in
//! main(), `root` is already a fully-constructed, stable main()-owned
//! value, so passing its address around is ordinary pointer-passing, not a
//! new dangling-pointer risk.
//!
//! Back-imports main (as main_mod) for Agent/the mutable globals it
//! sets (unattended/use_color/json_mode/g_cwd_display/g_worktree_branch/
//! show_timing/show_cost — mod-prefixed, never aliased). Sibling-imports
//! everything else directly.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const args = @import("args.zig");
const main_mod = @import("main.zig");
const provider_mod = @import("provider.zig");
const keys_cli = @import("keys_cli.zig");
const pricing = @import("pricing.zig");
const skills = @import("skills.zig");
const anim = @import("anim.zig");
const mcp = @import("mcp.zig");
const mcp_cli = @import("mcp_cli.zig");
const jobs = @import("jobs.zig");
const trace = @import("trace.zig");
const scoring = @import("scoring.zig");
const telemetry = @import("telemetry.zig");
const util = @import("util.zig");
const ansi = @import("ansi.zig");
const title_mod = @import("title.zig");
const fallback_config = @import("fallback_config.zig");
const repl = @import("repl.zig");
const pickers = @import("pickers.zig");
const repl_glue = @import("repl_glue.zig");
const messages_mod = @import("messages.zig");
const session = @import("session.zig");

/// `graff title <prompt>` — print the tab-title the model would generate for
/// that prompt (one title call, no session). For A/B-ing title prompts/styles.
/// Moved out of main() (600-line goal). Returns true when handled (main()
/// should return immediately without going any further).
pub fn runTitleCommand(io: Io, gpa: Allocator, arena: Allocator, client: *std.http.Client, default_provider: provider_mod.Provider, out: *Io.Writer, flags: args.Flags, run_budget: ?*@import("run_budget.zig").RunBudget) !bool {
    if (!(flags.positionals.items.len > 0 and std.mem.eql(u8, flags.positionals.items[0], "title"))) return false;
    if (flags.positionals.items.len < 2) std.process.fatal("usage: graff title <prompt>", .{});
    const tprompt = try std.mem.join(arena, " ", flags.positionals.items[1..]);
    if (title_mod.titleTask(gpa, io, client, default_provider, tprompt, run_budget, null)) |t| {
        defer gpa.free(t);
        try out.print("{s}\n", .{t});
    } else try out.writeAll("(title generation failed — check your model/key)\n");
    try out.flush();
    return true;
}

/// Terminal color detection, `--worktree`/`-w` isolation (chdir into a scratch
/// git worktree + auto-commit branch), the human-facing cwd display, and the
/// interactive startup banner. Moved out of main() verbatim (600-line goal).
/// Mutates the `use_color`/`g_cwd_display`/`g_worktree_branch` globals in
/// main.zig directly (mod-prefixed, never aliased — see the campaign's
/// mutable-global rule).
pub fn setupWorktreeAndBanner(
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    environ_map: anytype,
    flags: args.Flags,
    out: *Io.Writer,
    trace_path: []const u8,
    codex_account: ?[]const u8,
    stale_saved_model: ?[]const u8,
    preferred_provider: ?[]const u8,
    default_provider: provider_mod.Provider,
) !void {
    // Color only on an interactive terminal, and honor NO_COLOR.
    if (environ_map.get("NO_COLOR") == null and (Io.File.stdout().isTty(io) catch false)) {
        ansi.style = ansi.Style.ansi;
        main_mod.use_color = true;
    }
    const style = &ansi.style;
    // --worktree/-w: run this session in an isolated git worktree so parallel
    // agents don't collide on files. Creates .graff/worktrees/<name> on branch
    // worktree-<name> (from HEAD) and enters it; reuses it if it already exists.
    if (flags.worktree_flag) |wt| {
        // POSIX-only: the chdir below goes through libc's `chdir`, which Windows
        // builds don't link. -w is a parallel-agent dev workflow (mac/linux); on
        // Windows we bail with a clear message rather than break the cross-build.
        // The comptime `if` elides the chdir branch entirely on Windows.
        if (builtin.os.tag == .windows) {
            std.process.fatal("--worktree is not yet supported on Windows (POSIX-only chdir) — run without -w", .{});
        } else {
            const wt_path = try std.fmt.allocPrint(arena, ".graff/worktrees/{s}", .{wt});
            const wt_branch = try std.fmt.allocPrint(arena, "worktree-{s}", .{wt});
            if (jobs.runCapped(gpa, io, &.{ "git", "worktree", "add", wt_path, "-b", wt_branch }, 8192, 8192, 60_000)) |r| {
                gpa.free(r.stdout);
                gpa.free(r.stderr);
            } else |_| {}
            const wt_z = arena.dupeSentinel(u8, wt_path, 0) catch std.process.fatal("--worktree: out of memory", .{});
            if (std.posix.system.chdir(wt_z.ptr) != 0)
                std.process.fatal("--worktree '{s}': could not enter {s} (is this a git repository?)", .{ wt, wt_path });
            main_mod.g_worktree_branch = wt_branch; // non-null = auto-commit each turn to this scratch branch
            if (!main_mod.json_mode) {
                const ac: []const u8 = if (main_mod.g_worktree_autocommit) " · auto-committing each turn (`graff worktree merge` to land it)" else "";
                out.print("{s}worktree:{s} {s}{s}{s} (branch {s}) — edits isolated from the main checkout{s}\n", .{ style.dim, style.reset, style.accent, wt_path, style.reset, wt_branch, ac }) catch {};
                out.flush() catch {};
            }
        }
    }
    var cwd_buf: [4096]u8 = undefined;
    main_mod.g_cwd_display = if (flags.worktree_flag) |wt|
        // After chdir into the worktree, realPath(AT_FDCWD) is unreliable; derive from the launch dir.
        std.fmt.allocPrint(arena, "{s}/.graff/worktrees/{s}", .{ environ_map.get("PWD") orelse ".", wt }) catch try arena.dupe(u8, environ_map.get("PWD") orelse ".")
    else if (Io.Dir.cwd().realPath(io, &cwd_buf)) |n|
        try arena.dupe(u8, cwd_buf[0..n])
    else |_|
        try arena.dupe(u8, environ_map.get("PWD") orelse ".");

    if (!main_mod.json_mode and flags.oneshot_prompt == null) {
        try out.print("{s}codegraff{s} · folder: {s}{s}{s} · / for commands · @ picks a file · esc interrupts · ↑/↓ history · tab completes · ctrl-d quits · trace → {s}\n", .{ style.bold, style.reset, style.accent, main_mod.g_cwd_display, style.reset, trace_path });
        try out.flush();
        if (codex_account) |acct| {
            try out.print("logged into Codex (ChatGPT account {s}…) — /model codex\n", .{acct[0..@min(acct.len, 8)]});
            try out.flush();
        }
        if (flags.yolo_flag) {
            try out.print("{s}⚠ YOLO{s} mode (--yolo): all bash/tool/MCP permission prompts are skipped\n", .{ style.red, style.reset });
            try out.flush();
        }
        if (stale_saved_model) |nm| {
            const allowed = fallback_config.load(io, arena);
            const cross_provider = preferred_provider != null and !std.mem.eql(u8, preferred_provider.?, default_provider.id);
            const blocked = cross_provider and !fallback_config.contains(allowed, default_provider.id);
            try out.print("{s}note: saved model '{s}' is unavailable — selected {s} via {s} for this session; saved preference kept{s}{s}\n", .{
                style.dim,
                nm,
                default_provider.model,
                default_provider.id,
                if (blocked) ". Cross-provider use is blocked until /fallback allow " else "",
                if (blocked) default_provider.id else "",
            });
            try out.writeAll(style.reset);
            try out.flush();
        }
        if (main_mod.show_timing or main_mod.show_cost) {
            try out.print("{s}displays on:{s}{s}{s}\n", .{
                style.dim,
                if (main_mod.show_timing) " per-tool timing" else "",
                if (main_mod.show_cost) " session cost" else "",
                style.reset,
            });
            try out.flush();
        }
    }
}

/// A best-effort run-local JSONL file: the opened file handle (null on a
/// failed open — tracing/trajectory just stays off) plus the File.Writer. The caller
/// owns `buf`'s storage (a stack array in main()) and must keep it alive as
/// long as the returned writer is used; the writer itself is safe to copy by
/// value (see startup.zig's header) since nothing takes `&writer.interface`
/// until the caller's copy has settled into its own final, stable location.
pub const FileWriterOpen = struct {
    file: ?Io.File,
    writer: Io.File.Writer,
};

fn openRunFile(io: Io, dir_path: []const u8, path: []const u8, buf: []u8) FileWriterOpen {
    Io.Dir.cwd().createDir(io, ".graff", .default_dir) catch {};
    Io.Dir.cwd().createDir(io, dir_path, .default_dir) catch {};
    // A random run id makes collision vanishingly unlikely; exclusive creation
    // turns even that case into a disabled writer instead of truncating another
    // process's file.
    const file: ?Io.File = Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch null;
    const writer = if (file) |f| f.writer(io, buf) else undefined;
    return .{ .file = file, .writer = writer };
}

/// Opens `.graff/traces/<run-id>.jsonl` exclusively.
pub fn openTraceFile(io: Io, path: []const u8, buf: []u8) FileWriterOpen {
    return openRunFile(io, trace.traces_dir, path, buf);
}

/// Opens `.graff/trajectories/<run-id>.jsonl` exclusively. The aggregate
/// archive is the directory, not a shared append cursor.
pub fn openTrajFile(io: Io, path: []const u8, buf: []u8) FileWriterOpen {
    return openRunFile(io, trace.trajectories_dir, path, buf);
}

/// Generate the run id before worktree setup so the banner can show the exact
/// run-scoped trace path.
pub fn initScoreRunId(io: Io) void {
    var raw: [8]u8 = undefined;
    io.random(&raw);
    scoring.g_run_id = std.fmt.bytesToHex(raw, .lower);
}

/// Load the optional signing key after worktree setup, preserving the prior
/// meaning of relative GRAFF_SCORE_KEY_FILE paths.
pub fn loadScoreSigningKey(io: Io, arena: Allocator, environ_map: anytype) void {
    scoring.g_score_key = scoring.loadScoreKey(io, arena, environ_map);
}

/// Telemetry endpoint precedence: opt-out always wins → else an
/// env-configured endpoint (dev / override) → else the release build's
/// baked-in default. Returns the Telemetry sink by value — plain data plus
/// one external pointer (`client`, already stable in main()'s frame), so
/// returning it is safe (no self-reference to invalidate on the copy).
/// Moved out of main() (600-line goal).
pub fn initTelemetry(io: Io, gpa: Allocator, client: *std.http.Client, environ_map: anytype, flags: args.Flags, default_telemetry_endpoint: []const u8) telemetry.Telemetry {
    const telem_endpoint: []const u8 = if (flags.no_telemetry_flag or environ_map.get("GRAFF_NO_TELEMETRY") != null)
        ""
    else
        environ_map.get("OTEL_EXPORTER_OTLP_ENDPOINT") orelse
            environ_map.get("GRAFF_OTEL_ENDPOINT") orelse
            default_telemetry_endpoint;
    const telem_home = keys_cli.homeEnv(environ_map) orelse "";
    return .{
        .io = io,
        .gpa = gpa,
        .client = client,
        .endpoint = telem_endpoint,
        .install_id = if (telem_endpoint.len > 0) keys_cli.loadOrCreateId(io, gpa, telem_home, ".simple-harness-install-id") else @splat('0'),
        .client_name = environ_map.get("HARNESS_CLIENT") orelse "harness",
        .sdk_install_id = environ_map.get("HARNESS_SDK_INSTALL_ID") orelse "",
        .start = Io.Timestamp.now(io, .awake),
        .start_unix_ms = util.unixMs(io),
    };
}

/// MCP servers from .mcp.json. SECURITY: a workspace .mcp.json launches
/// arbitrary local commands, so opening an untrusted repo could run them.
/// Auto-connect only with --yolo (trusted) or explicit per-session consent
/// (prompted here); otherwise starts with an empty (but live) registry so
/// `/mcp add` still works. Moved out of main() (600-line goal). Returns the
/// Registry by value — mcp.Registry holds no self-references (its storage
/// is ArrayList/HashMap-backed), so returning it is safe.
pub fn initRegistryConsent(io: Io, gpa: Allocator, arena: Allocator, out: *Io.Writer, in: *Io.Reader, flags: args.Flags, mcp_config_path: []const u8, home: []const u8, use_color: bool, json_mode: bool) !mcp.Registry {
    const mcp_count = mcp_cli.countMcpServers(io, arena);
    var connect_mcp = flags.yolo_flag or mcp_count == 0;
    if (mcp_count > 0 and !flags.yolo_flag and !json_mode and use_color) {
        try out.print("{s}⚠ this workspace's .mcp.json defines {d} untrusted MCP server(s). They may run local commands or receive data over the network. Connect them this session? [y/N] {s}", .{ ansi.style.bold, mcp_count, ansi.style.reset });
        try out.flush();
        const ans = in.takeDelimiter('\n') catch null;
        connect_mcp = ans != null and ans.?.len > 0 and (ans.?[0] == 'y' or ans.?[0] == 'Y');
    }
    return if (connect_mcp) ((mcp.Registry.init(gpa, io, mcp_config_path, home) catch |err| inner: {
        try out.print("[mcp] init failed: {t} — continuing without MCP\n", .{err});
        if (telemetry.g_telem) |t| t.errorEvent("mcp", @errorName(err));
        break :inner null;
    }) orelse mcp.Registry.emptyWithOAuthHome(gpa, io, home)) else outer: {
        if (mcp_count > 0) try out.print("{s}skipped {d} workspace MCP server(s) — /mcp trust to connect them now (or re-run with --yolo){s}\n", .{ ansi.style.dim, mcp_count, ansi.style.reset });
        break :outer mcp.Registry.emptyWithOAuthHome(gpa, io, home);
    };
}

/// Companion auto-activation: if the metered code-intelligence companion
/// (codedb-pro, formerly muonry) is installed but nothing connected it (no
/// workspace .mcp.json entry, or consent declined), spawn it directly — a
/// user-installed companion at the same trust level as the skills
/// auto-detection, NOT arbitrary workspace config. Failure just falls back
/// to native tools. Opt out like a skill: {"skills": {"codedbpro": false}}.
/// Moved out of main() (600-line goal); mutates `registry` in place (it's
/// already main()-owned and stable by the time this is called, so a pointer
/// is all that's needed — no return-by-value trickery here).
pub fn connectCompanion(io: Io, registry: *mcp.Registry, flags: args.Flags, out: *Io.Writer, json_mode: bool, smolify_enabled: bool) !void {
    connect: {
        for (skills.companion_servers) |c| if (skills.mcpServerConnected(registry.tools, c.server)) break :connect;
        for (skills.companion_servers) |c| {
            if (skills.companionDisabled(c.server) or !skills.binOnPath(io, c.bin)) continue;
            if (registry.addServer(c.server, c.bin, &.{"--mcp"})) |_| {
                break;
            } else |err| {
                if (!json_mode and flags.oneshot_prompt == null) {
                    try out.print("{s}[mcp:{s}] auto-connect failed ({t}) — native tools only{s}\n", .{ ansi.style.dim, c.server, err, ansi.style.reset });
                    try out.flush();
                }
            }
        }
    }

    // Smolify is a core, hosted Streamable HTTP MCP. It can be disabled with
    // GRAFF_NO_SMOLIFY=1 for offline or privacy-sensitive sessions.
    if (!smolify_enabled) return;
    _ = registry.connectSmolify() catch |err| {
        if (!json_mode and flags.oneshot_prompt == null) {
            try out.print("{s}[mcp:smolify] auto-connect failed ({t}) — continuing offline{s}\n", .{ ansi.style.dim, err, ansi.style.reset });
            try out.flush();
        }
    };
}
