//! Post-credential session bootstrap, split out of startup.zig (600-line
//! goal — startup.zig itself crossed the line-goal once this content grew,
//! so it lives in its own sibling file). Covers everything that happens
//! AFTER credentials/model are resolved and the http.Client exists: the
//! `graff title` subcommand, terminal-color/`-w`-worktree/banner setup,
//! opening the run-scoped trace/trajectory files + telemetry + score-signing, the MCP
//! registry connect (consent prompt + companion auto-activation), and the
//! `graff repl`/one-shot-prompt early-exit paths.
//!
//! Engine side of the #422 boundary: the banner, the worktree line, the config
//! reports and the consent question are typed events (engine_events.zig) that a
//! sink renders — this file names no colors and holds no key hints. The consent
//! ANSWER is still read inline; that half belongs to input inversion (#430).
//!
//! Same dangling-pointer discipline as startup.zig: `openTraceFile`,
//! `openBehaviorFile`, and `openTrajFile` return a plain
//! (non-self-referential) File.Writer by value — main() assigns it to its OWN
//! stable local, and only THEN takes
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
const mcp = @import("mcp.zig");
const mcp_cli = @import("mcp_cli.zig");
const mcp_config = @import("mcp_config.zig");
const mcp_schema_gate = @import("mcp_schema_gate.zig"); // #416: the eager-vs-deferred policy for MCP tool schemas
const jobs = @import("jobs.zig");
const tool_spill = @import("tool_spill.zig"); // #409: where an over-cap tool output's full bytes go
const trace = @import("trace.zig");
const scoring = @import("scoring.zig");
const telemetry = @import("telemetry.zig");
const util = @import("util.zig");
const engine_sink = @import("engine_sink.zig"); // #429: startup's lines are typed events, not prints
const engine_events = @import("engine_events.zig");
const title_mod = @import("title.zig");
const fallback_config = @import("fallback_config.zig");
const repl = @import("repl.zig");
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
    // Color only on an interactive terminal, and honor NO_COLOR. The palette
    // itself is a sink concern (#429); this only decides whether there is one.
    if (environ_map.get("NO_COLOR") == null and (Io.File.stdout().isTty(io) catch false)) {
        main_mod.use_color = true;
        engine_sink.enableColor();
    }
    const sink = engine_sink.writerSink(out);
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
            if (!main_mod.json_mode) sink.emit(io, .{ .worktree_entered = .{
                .path = wt_path,
                .branch = wt_branch,
                .autocommit = main_mod.g_worktree_autocommit,
            } });
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
    // #409: the oversized-tool-output cap spills the full bytes into this
    // workspace before eliding them. Wired here because this is where the cwd
    // (post `-w` chdir) is first known absolutely, and the marker hands the
    // model an ABSOLUTE path. Left unwired in tests, where the cap stays the
    // pre-#409 plain truncation.
    tool_spill.enable(.{ .io = io, .dir = .cwd(), .base_abs = main_mod.g_cwd_display });

    if (!main_mod.json_mode and flags.oneshot_prompt == null) {
        sink.emit(io, .{ .session_banner = .{ .cwd = main_mod.g_cwd_display, .trace_path = trace_path } });
        if (codex_account) |acct| sink.emit(io, .{ .session_notice = .{
            .text = try std.fmt.allocPrint(arena, "logged into Codex (ChatGPT account {s}…) — /model codex", .{acct[0..@min(acct.len, 8)]}),
        } });
        if (flags.effectiveYolo()) sink.emit(io, .{ .session_notice = .{
            .lead = "⚠ YOLO",
            .text = if (flags.yolo_flag) " mode (--yolo): all bash/tool/MCP permission prompts are skipped" else " mode (-p implies --yolo; --safe opts out): all bash/tool/MCP permission prompts are skipped",
            .tone = .alert,
        } });
        if (stale_saved_model) |nm| {
            const allowed = fallback_config.load(io, arena);
            const cross_provider = preferred_provider != null and !std.mem.eql(u8, preferred_provider.?, default_provider.id);
            sink.emit(io, .{ .saved_model_unavailable = .{
                .saved = nm,
                .model = default_provider.model,
                .provider = default_provider.id,
                .blocked = cross_provider and !fallback_config.contains(allowed, default_provider.id),
            } });
        }
        if (main_mod.show_timing or main_mod.show_cost) sink.emit(io, .{ .session_notice = .{
            .text = try std.fmt.allocPrint(arena, "displays on:{s}{s}", .{
                if (main_mod.show_timing) " per-tool timing" else "",
                if (main_mod.show_cost) " session cost" else "",
            }),
            .tone = .dim,
        } });
    }
}

/// A best-effort log-file result shared by operational traces, behavioral
/// traces, and the legacy trajectory archive: the opened file handle (null on
/// a failed open) plus the File.Writer wrapping it. The caller
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

fn validBehaviorDirComponent(component: []const u8) bool {
    if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    for (component) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    }
    return true;
}

/// Opens one exclusive behavioral trace file. Every directory component is
/// created and reopened relative to a verified no-follow parent handle, so a
/// workspace symlink cannot redirect plaintext traces outside `base`. The
/// filename itself comes from a validated hex run ID. POSIX directories use
/// 0700 and files request a maximum mode of 0600 because task adapters may
/// deliberately record sensitive state.
pub fn openBehaviorFile(io: Io, base: Io.Dir, dir: []const u8, run_id: []const u8, buf: []u8) FileWriterOpen {
    if (run_id.len == 0 or run_id.len > 64) return .{ .file = null, .writer = undefined };
    for (run_id) |c| if (!std.ascii.isHex(c)) return .{ .file = null, .writer = undefined };

    const dir_permissions: Io.File.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
    var current = base;
    var current_owned = false;
    defer if (current_owned) current.close(io);
    var components = std.mem.splitScalar(u8, dir, '/');
    var saw_component = false;
    while (components.next()) |component| {
        if (!validBehaviorDirComponent(component)) return .{ .file = null, .writer = undefined };
        saw_component = true;
        current.createDir(io, component, dir_permissions) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return .{ .file = null, .writer = undefined },
        };
        const next = current.openDir(io, component, .{ .iterate = true, .follow_symlinks = false }) catch return .{ .file = null, .writer = undefined };
        if (current_owned) current.close(io);
        current = next;
        current_owned = true;
    }
    if (!saw_component) return .{ .file = null, .writer = undefined };
    if (builtin.os.tag != .windows) current.setPermissions(io, dir_permissions) catch return .{ .file = null, .writer = undefined };

    var name_buf: [72]u8 = undefined;
    const file_name = std.fmt.bufPrint(&name_buf, "{s}.jsonl", .{run_id}) catch return .{ .file = null, .writer = undefined };
    const file_permissions: Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
    const file: ?Io.File = current.createFile(io, file_name, .{
        .exclusive = true,
        .permissions = file_permissions,
    }) catch null;
    const writer = if (file) |f| f.writer(io, buf) else undefined;
    return .{ .file = file, .writer = writer };
}

test "openBehaviorFile: confines names, creates exclusively, and uses private POSIX modes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var first_buf: [256]u8 = undefined;
    const first = openBehaviorFile(io, tmp.dir, "trajectories", "0123456789abcdef", &first_buf);
    try std.testing.expect(first.file != null);
    defer if (first.file) |file| file.close(io);

    var duplicate_buf: [256]u8 = undefined;
    const duplicate = openBehaviorFile(io, tmp.dir, "trajectories", "0123456789abcdef", &duplicate_buf);
    try std.testing.expect(duplicate.file == null);

    var invalid_buf: [256]u8 = undefined;
    const invalid = openBehaviorFile(io, tmp.dir, "trajectories", "../escape", &invalid_buf);
    try std.testing.expect(invalid.file == null);

    if (builtin.os.tag != .windows) {
        const dir_stat = try tmp.dir.statFile(io, "trajectories", .{});
        const file_stat = try tmp.dir.statFile(io, "trajectories/0123456789abcdef.jsonl", .{});
        try std.testing.expectEqual(@as(u32, 0o700), @as(u32, @intCast(dir_stat.permissions.toMode() & 0o777)));
        const file_mode: u32 = @intCast(file_stat.permissions.toMode() & 0o777);
        try std.testing.expectEqual(@as(u32, 0), file_mode & 0o177);
    }
}

test "openBehaviorFile: rejects symlinked path components" {
    if (builtin.os.tag == .windows) return;
    const io = std.testing.io;

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDir(io, "outside", .default_dir);
        try tmp.dir.symLink(io, "outside", ".graff", .{ .is_directory = true });
        var buf: [256]u8 = undefined;
        const opened = openBehaviorFile(io, tmp.dir, ".graff/trajectories", "0123456789abcdef", &buf);
        try std.testing.expect(opened.file == null);
    }

    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDir(io, ".graff", .default_dir);
        try tmp.dir.createDir(io, "outside", .default_dir);
        const graff = try tmp.dir.openDir(io, ".graff", .{});
        defer graff.close(io);
        try graff.symLink(io, "../outside", "trajectories", .{ .is_directory = true });
        var buf: [256]u8 = undefined;
        const opened = openBehaviorFile(io, tmp.dir, ".graff/trajectories", "fedcba9876543210", &buf);
        try std.testing.expect(opened.file == null);
    }
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
        .auth_key = telemetry.validatedAuthKey(environ_map.get("GRAFF_TELEMETRY_KEY")),
        .install_id = if (telem_endpoint.len > 0) keys_cli.loadOrCreateId(io, gpa, telem_home, ".simple-harness-install-id") else @splat('0'),
        .client_name = environ_map.get("HARNESS_CLIENT") orelse "harness",
        .sdk_install_id = environ_map.get("HARNESS_SDK_INSTALL_ID") orelse "",
        .start = Io.Timestamp.now(io, .awake),
        .start_unix_ms = util.unixMs(io),
    };
}

/// MCP servers from the workspace .mcp.json merged with the user-level
/// ~/.codegraff/mcp.json (#345). SECURITY: either file launches arbitrary local
/// commands, so opening an untrusted repo could run them — and a global entry
/// is no safer, it just follows the user everywhere. Auto-connect only with
/// --yolo (trusted) or explicit per-session consent (prompted here); otherwise
/// starts with an empty (but live) registry so `/mcp add` still works. Moved
/// out of main() (600-line goal). Returns the Registry by value — mcp.Registry
/// holds no self-references (its storage is ArrayList/HashMap-backed), so
/// returning it is safe.
/// --lean / GRAFF_LEAN=1: skip MCP connection entirely. Connected servers pay
/// their tool schemas into the prefix of EVERY model turn — measured ~6k
/// tokens for a licensed codedbpro alone against a ~7.4k native baseline, so
/// an MCP-heavy config roughly doubles the context bill of a one-shot. Lean
/// is the one-shot/CI answer; interactive sessions keep the consent flow.
pub fn leanSkipsMcp(lean_flag: bool, environ_map: anytype) bool {
    return lean_flag or environ_map.get("GRAFF_LEAN") != null;
}

pub fn initRegistryConsent(io: Io, gpa: Allocator, arena: Allocator, out: *Io.Writer, in: *Io.Reader, flags: args.Flags, mcp_config_path: []const u8, home: []const u8, use_color: bool, json_mode: bool, environ_map: anytype) !mcp.Registry {
    const global_path = mcp_config.globalPath(arena, home, environ_map);
    const sink = engine_sink.writerSink(out);
    // --json's stdout is a JSONL stream and a one-shot's is the answer; neither
    // can carry chatter. With a global config `mcp_count > 0` in every project,
    // so an unguarded line here would corrupt the head of every --json run.
    const quiet = json_mode or flags.oneshot_prompt != null;
    const merged = mcp_config.load(io, arena, Io.Dir.cwd(), mcp_config_path, global_path);
    // #416: resolve eager-vs-deferred BEFORE anything connects, so the first
    // catalog render already knows which servers pay their schemas up front.
    mcp_schema_gate.configure(arena, merged, environ_map);
    if (!quiet) {
        // Reported here rather than in `Registry.init`, which never runs when
        // consent is declined — a config that does not parse must be named
        // either way.
        if (merged.invalid_project) sink.emit(io, dimNotice(try std.fmt.allocPrint(arena, "{s}" ++ mcp_config.invalid_complaint, .{mcp_config_path})));
        if (merged.invalid_global) sink.emit(io, dimNotice(try std.fmt.allocPrint(arena, "{s}" ++ mcp_config.invalid_complaint, .{global_path orelse ""})));
        // A config graff does not read is worse than no config: say so once.
        if (mcp_config.unsupportedConfigPresent(io, arena, home))
            sink.emit(io, dimNotice(try std.fmt.allocPrint(arena, "ignoring ~/" ++ mcp_config.unsupported_rel_path ++ ": unsupported path — use ~/" ++ mcp_config.global_rel_path ++ " (global) or {s} (project)", .{mcp_config_path})));
    }
    const mcp_count = mcp_cli.countMcpServers(merged);
    const lean = leanSkipsMcp(flags.lean_flag, environ_map);
    var connect_mcp = !lean and (flags.yolo_flag or mcp_count == 0);
    if (mcp_count > 0 and !lean and !flags.yolo_flag and !json_mode and use_color) {
        sink.emit(io, .{ .mcp_consent_prompt = .{ .count = mcp_count } });
        // Still an inline read: only the QUESTION is inverted here, and the
        // answer becomes a typed command in #430 (input inversion).
        const ans = in.takeDelimiter('\n') catch null;
        connect_mcp = ans != null and ans.?.len > 0 and (ans.?[0] == 'y' or ans.?[0] == 'Y');
    }
    var registry: mcp.Registry = if (connect_mcp) ((mcp.Registry.init(gpa, io, mcp_config_path, global_path, home, environ_map) catch |err| inner: {
        sink.emit(io, .{ .session_notice = .{ .text = try std.fmt.allocPrint(arena, "[mcp] init failed: {t} — continuing without MCP", .{err}) } });
        if (telemetry.g_telem) |t| t.errorEvent("mcp", @errorName(err));
        break :inner null;
    }) orelse mcp.Registry.emptyWithOAuthHome(gpa, io, home)) else outer: {
        if (mcp_count > 0 and !quiet)
            sink.emit(io, dimNotice(try std.fmt.allocPrint(arena, "skipped {d} MCP server(s) — /mcp trust to connect them now (or re-run with --yolo)", .{mcp_count})));
        break :outer mcp.Registry.emptyWithOAuthHome(gpa, io, home);
    };
    // Set on every path, not just `init`'s: `/mcp trust` has to find the global
    // file precisely when consent was declined and no `init` ever ran. `arena`
    // is the session arena, so the path outlives the registry.
    registry.global_config_path = global_path;
    return registry;
}

/// Licensed startup path (main.zig): probe the companion's license, and when
/// paid ALSO pin the server eager in the #416 schema gate — a licensed user
/// pays for these tools, so their full schemas belong in every request rather
/// than behind a per-session load_tool_schemas toll that steers the model
/// back to the native defaults. Runs before the first catalog render.
pub fn probeLicensedPinEager(gpa: Allocator, arena: Allocator, io: Io) bool {
    if (!skills.probeCodedbproLicensed(gpa, io)) return false;
    mcp_schema_gate.pinEagerRuntime(arena, "codedbpro");
    return true;
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
pub fn connectCompanion(io: Io, arena: Allocator, registry: *mcp.Registry, flags: args.Flags, out: *Io.Writer, json_mode: bool, environ_map: anytype) !void {
    // --lean / GRAFF_LEAN=1 skips ALL MCP, the auto-companion and the bundled
    // Smolify registration included — lean means no MCP tool schemas at all.
    if (leanSkipsMcp(flags.lean_flag, environ_map)) return;
    const sink = engine_sink.writerSink(out);
    const speak = !json_mode and flags.oneshot_prompt == null;
    connect: {
        for (skills.companion_servers) |c| if (skills.mcpServerConnected(registry.tools, c.server)) break :connect;
        for (skills.companion_servers) |c| {
            if (skills.companionDisabled(c.server) or !skills.binOnPath(io, c.bin)) continue;
            if (registry.addServer(c.server, c.bin, &.{"--mcp"})) |_| {
                break;
            } else |err| {
                if (speak) sink.emit(io, dimNotice(try std.fmt.allocPrint(arena, "[mcp:{s}] auto-connect failed ({t}) — native tools only", .{ c.server, err })));
            }
        }
    }

    // Smolify schemas are bundled and its hosted transport stays offline until
    // an approved call. Full/authenticated/write tools require explicit opt-in.
    if (environ_map.get("GRAFF_NO_SMOLIFY") != null) return;
    const access = environ_map.get("GRAFF_SMOLIFY_ACCESS") orelse "public";
    const full_access = std.ascii.eqlIgnoreCase(access, "full") or std.ascii.eqlIgnoreCase(access, "authenticated");
    const added = registry.connectSmolify(full_access) catch |err| {
        if (speak) sink.emit(io, dimNotice(try std.fmt.allocPrint(arena, "[mcp:smolify] auto-connect failed ({t}) — continuing offline", .{err})));
        return;
    };
    if (added > 0 and speak)
        sink.emit(io, dimNotice(try std.fmt.allocPrint(arena, "[mcp:smolify] available on demand — {d} {s} tool(s)", .{ added, if (full_access) "full-access" else "anonymous public-read" })));
}

/// The startup cluster's most common line: dim, no badge. A helper rather than
/// a variant — the tone is the only thing these share and the only thing a
/// sink needs from them.
fn dimNotice(text: []const u8) engine_events.EngineEvent {
    return .{ .session_notice = .{ .text = text, .tone = .dim } };
}

test "lean skips MCP: flag or GRAFF_LEAN env, never the default" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(!leanSkipsMcp(false, env)); // default: consent flow decides
    try std.testing.expect(leanSkipsMcp(true, env)); // --lean wins alone
    try env.put("GRAFF_LEAN", "1");
    try std.testing.expect(leanSkipsMcp(false, env)); // env wins alone
    try std.testing.expect(leanSkipsMcp(true, env));
}

test "core Smolify registration is offline and lazy" {
    var registry = mcp.Registry.empty(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 8), try registry.connectSmolify(false));
    try std.testing.expectEqual(@as(usize, 1), registry.servers.len);
    try std.testing.expectEqualStrings("on-demand", registry.servers[0].protocol_version);
    try std.testing.expectEqual(@as(usize, 8), registry.tools.len);
    try std.testing.expect(registry.servers[0].transport.http.oauth_home == null);
    try std.testing.expectEqual(@as(usize, 0), try registry.connectSmolify(false));

    var full = mcp.Registry.emptyWithOAuthHome(std.testing.allocator, std.testing.io, "/not-read-during-registration");
    defer full.deinit();
    try std.testing.expectEqual(@as(usize, 13), try full.connectSmolify(true));
    try std.testing.expectEqualStrings("/not-read-during-registration", full.servers[0].transport.http.oauth_home.?);
}
