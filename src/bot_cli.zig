//! `graff bot` (ADR 0333): Bots for any surface with a shell. A Bot is a
//! standing role in `.graff/bots/<name>/` (bot_store.zig); a run is one
//! headless graff turn with the bot's job, memory and recent log added to the
//! system prompt.
//!
//! Routines fire only when something ticks: `graff bot tick` from cron or
//! launchd, or a client that calls `graff bot due --claim --json` and runs
//! each one where the user can see it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const store = @import("bot_store.zig");
const runner = @import("process_runner.zig");
const util = @import("util.zig");

pub const usage =
    \\usage: graff bot <command> [options]
    \\  list [--json]                          the bots in this folder
    \\  create NAME [--model M] [--yolo] JOB   a new bot and the one job it holds
    \\  show NAME [--json]                     its job, memory, routines and recent log
    \\  rm NAME                                delete the bot and everything it remembers
    \\  run NAME MESSAGE                       one turn as the bot; the result is logged
    \\  prompt NAME                            the standing text for a client that runs the bot in its own chat
    \\  log NAME [TEXT]                        show the work log, or add a line to it
    \\  routine add NAME WHEN INSTRUCTION      WHEN is 5m (once) or "@every 2h" (s, m, h, d)
    \\  routine list [NAME] [--json]           routines and when each runs next
    \\  routine pause|resume|rm NAME ID
    \\  routine test NAME ID                   run it now; its schedule does not move
    \\  trigger NAME ID [PAYLOAD]              run it now for an event (PAYLOAD or stdin)
    \\  due [--claim] [--json]                 routines that are due; --claim moves them on
    \\  tick [--json]                          run every due routine once, then exit
    \\  --timeout SECONDS                      limit for one run (default 1800)
    \\
;

/// A bot run can start another bot's run; this stops a loop.
pub const max_depth: u32 = 3;
pub const depth_env = "GRAFF_BOT_DEPTH";

pub const Opts = struct {
    words: []const []const u8 = &.{},
    json: bool = false,
    yolo: bool = false,
    claim: bool = false,
    model: []const u8 = "",
    timeout_s: u64 = 1800,
    /// Piped stdin, for `trigger` without a PAYLOAD.
    stdin_text: []const u8 = "",
};

pub fn parseOpts(arena: Allocator, args: []const []const u8) error{ Usage, OutOfMemory }!Opts {
    var o: Opts = .{};
    var words: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--json")) {
            o.json = true;
        } else if (std.mem.eql(u8, a, "--yolo")) {
            o.yolo = true;
        } else if (std.mem.eql(u8, a, "--claim")) {
            o.claim = true;
        } else if (std.mem.eql(u8, a, "--model") or std.mem.eql(u8, a, "--timeout")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            if (a[2] == 'm') o.model = args[i] else o.timeout_s = std.fmt.parseInt(u64, args[i], 10) catch return error.Usage;
        } else if (std.mem.startsWith(u8, a, "--")) {
            return error.Usage;
        } else try words.append(arena, a);
    }
    if (words.items.len == 0 or o.timeout_s == 0) return error.Usage;
    o.words = words.items;
    return o;
}

pub const RunResult = struct {
    ok: bool,
    /// The run's answer.
    text: []const u8 = "",
    /// Why it failed, for the terminal.
    note: []const u8 = "",
    /// What the reply's `remember:` and `forget:` lines changed.
    memory: store.MemoryChange = .{},
};

/// A run an event started reads text nobody here wrote, so it cannot change
/// what the bot remembers.
const Memory = enum { apply, ignore };

/// How a turn is run. The real one starts a graff child; tests record argv.
pub const Runner = struct {
    ctx: ?*anyopaque = null,
    run: *const fn (ctx: ?*anyopaque, arena: Allocator, argv: []const []const u8, timeout_s: u64) RunResult,
};

pub const Ctx = struct {
    io: Io,
    /// The folder the bots live in: the project root.
    dir: Io.Dir,
    arena: Allocator,
    now_ms: i64,
    exe: []const u8,
    runner: Runner,
};

/// Arguments of one bot turn. Approvals stay graff's headless default unless
/// the bot was created with `--yolo`.
pub fn turnArgv(arena: Allocator, exe: []const u8, bot: store.Bot, system: []const u8, message: []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ exe, "--no-resume" });
    if (bot.yolo) try argv.append(arena, "--yolo");
    if (bot.model.len > 0) try argv.appendSlice(arena, &.{ "--model", bot.model });
    try argv.appendSlice(arena, &.{ "--append-system-prompt", system, "-p", message });
    return argv.items;
}

fn runTurn(ctx: Ctx, opts: Opts, bot: store.Bot, source: []const u8, message: []const u8, memory: Memory) !RunResult {
    const a = ctx.arena;
    const system = try store.preamble(a, bot, store.readMemory(ctx.io, ctx.dir, a, bot.name), store.logTail(ctx.io, ctx.dir, a, bot.name, store.log_tail_lines), .headless);
    var res = ctx.runner.run(ctx.runner.ctx, a, try turnArgv(a, ctx.exe, bot, system, message), opts.timeout_s);
    if (res.ok) {
        const edits = try store.memoryEdits(a, res.text);
        res.text = edits.reply;
        if (memory == .apply) res.memory = store.applyMemory(ctx.io, ctx.dir, a, bot.name, edits) catch .{};
    }
    const logged = if (res.text.len > 0) res.text else if (!res.ok) res.note else if (res.memory.added + res.memory.removed > 0) "updated memory" else "";
    store.appendLog(ctx.io, ctx.dir, a, bot.name, ctx.now_ms, source, logged, res.ok) catch {};
    return res;
}

fn printRun(out: *Io.Writer, res: RunResult) !u8 {
    if (res.text.len > 0) try out.print("{s}\n", .{std.mem.trimEnd(u8, res.text, "\r\n")});
    if (res.memory.added + res.memory.removed > 0) try out.print("\xe2\x9c\x93 memory: {d} added, {d} removed\n", .{ res.memory.added, res.memory.removed });
    if (res.ok) return 0;
    try out.print("\xe2\x9c\x97 the run failed{s}{s}\n", .{ if (res.note.len > 0) ": " else "", res.note });
    return 1;
}

fn fail(out: *Io.Writer, comptime fmt: []const u8, args: anytype) !u8 {
    try out.print("graff bot: " ++ fmt ++ "\n", args);
    return 2;
}

/// Print one JSON value and a newline; the exit code of a command that
/// only reports.
fn writeJson(out: *Io.Writer, value: anytype) !u8 {
    var s: std.json.Stringify = .{ .writer = out };
    try s.write(value);
    try out.writeAll("\n");
    return 0;
}

const RoutineRow = struct {
    bot: []const u8,
    id: []const u8,
    instruction: []const u8,
    when: []const u8,
    at_ms: i64,
    interval_ms: i64,
    paused: bool,
    done: bool,
    runs: u32,
    last_run_ms: i64,
    /// The turn a client sends to run it now, without moving its schedule.
    message: []const u8,
};

fn row(arena: Allocator, bot: []const u8, r: store.Routine) !RoutineRow {
    return .{ .bot = bot, .id = r.id, .instruction = r.instruction, .when = try store.describe(arena, r), .at_ms = r.at_ms, .interval_ms = r.interval_ms, .paused = r.paused, .done = r.done, .runs = r.runs, .last_run_ms = r.last_run_ms, .message = try store.routineMessage(arena, r, "") };
}

fn rows(ctx: Ctx, only: ?[]const u8) ![]const RoutineRow {
    var out: std.ArrayList(RoutineRow) = .empty;
    for (store.list(ctx.io, ctx.dir, ctx.arena)) |bot| {
        if (only) |name| if (!std.mem.eql(u8, name, bot.name)) continue;
        for (store.routines(ctx.io, ctx.dir, ctx.arena, bot.name)) |r| try out.append(ctx.arena, try row(ctx.arena, bot.name, r));
    }
    return out.items;
}

fn printRows(out: *Io.Writer, list: []const RoutineRow, show_bot: bool) !void {
    for (list) |r| {
        if (show_bot) try out.print("{s}/", .{r.bot});
        try out.print("{s}  {s}  {s}\n", .{ r.id, r.when, r.instruction });
    }
}

/// Run one command. The result is the process exit code.
pub fn dispatch(ctx: Ctx, opts: Opts, out: *Io.Writer) !u8 {
    const a = ctx.arena;
    const w = opts.words;
    const action = w[0];
    if (std.mem.eql(u8, action, "list") or std.mem.eql(u8, action, "ls")) {
        const bots = store.list(ctx.io, ctx.dir, a);
        if (opts.json) return writeJson(out, bots);
        if (bots.len == 0) try out.writeAll("no bots here yet: graff bot create NAME \"the one job it holds\"\n");
        for (bots) |b| try out.print("{s}  {s}\n", .{ b.name, store.summary(b.job) });
        return 0;
    }
    if (std.mem.eql(u8, action, "due")) return dueCommand(ctx, opts, out);
    if (std.mem.eql(u8, action, "tick")) return tick(ctx, opts, out);
    if (std.mem.eql(u8, action, "routine")) return routineCommand(ctx, opts, out);
    if (w.len < 2) return error.Usage;
    const name = w[1];
    const rest = try std.mem.join(a, " ", w[2..]);
    if (std.mem.eql(u8, action, "create")) {
        store.create(ctx.io, ctx.dir, a, .{ .name = name, .job = rest, .model = opts.model, .yolo = opts.yolo, .created_ms = ctx.now_ms }) catch |err| return switch (err) {
            error.BadName => fail(out, "'{s}' is not a bot name: use a-z, 0-9, - and _ (32 at most)", .{name}),
            error.NoJob => fail(out, "say the job: graff bot create {s} \"what it does\"", .{name}),
            error.Exists => fail(out, "a bot named '{s}' already exists", .{name}),
            error.StoreUnavailable => fail(out, "could not write {s}", .{store.store_rel}),
            error.OutOfMemory => error.OutOfMemory,
        };
        try out.print("\xe2\x9c\x93 created {s} in {s}/{s}\n", .{ name, store.store_rel, name });
        return 0;
    }
    const bot = store.load(ctx.io, ctx.dir, a, name) orelse return fail(out, "no bot named '{s}' in this folder (graff bot list)", .{name});
    if (std.mem.eql(u8, action, "rm")) {
        try store.remove(ctx.io, ctx.dir, a, name);
        try out.print("\xe2\x9c\x93 deleted {s}\n", .{name});
        return 0;
    }
    if (std.mem.eql(u8, action, "show")) return show(ctx, opts, bot, out);
    if (std.mem.eql(u8, action, "prompt")) {
        try out.print("{s}\n", .{try store.preamble(a, bot, store.readMemory(ctx.io, ctx.dir, a, name), store.logTail(ctx.io, ctx.dir, a, name, store.log_tail_lines), .chat)});
        return 0;
    }
    if (std.mem.eql(u8, action, "log")) {
        if (rest.len > 0) {
            try store.appendLog(ctx.io, ctx.dir, a, name, ctx.now_ms, "note", rest, true);
            return 0;
        }
        const tail = store.logTail(ctx.io, ctx.dir, a, name, 200);
        try out.print("{s}\n", .{if (tail.len > 0) tail else "(no runs yet)"});
        return 0;
    }
    if (std.mem.eql(u8, action, "run")) {
        if (rest.len == 0) return fail(out, "say what to do: graff bot run {s} \"message\"", .{name});
        return printRun(out, try runTurn(ctx, opts, bot, "chat", rest, .apply));
    }
    if (std.mem.eql(u8, action, "trigger")) {
        if (w.len < 3) return error.Usage;
        const r = store.loadRoutine(ctx.io, ctx.dir, a, name, w[2]) orelse return fail(out, "{s} has no routine {s}", .{ name, w[2] });
        if (r.paused) return fail(out, "routine {s} is paused: graff bot routine resume {s} {s}", .{ r.id, name, r.id });
        const typed = try std.mem.join(a, " ", w[3..]);
        const message = try store.routineMessage(a, r, if (typed.len > 0) typed else opts.stdin_text);
        return printRun(out, try runTurn(ctx, opts, bot, try std.fmt.allocPrint(a, "routine {s} (event)", .{r.id}), message, .ignore));
    }
    return error.Usage;
}

fn show(ctx: Ctx, opts: Opts, bot: store.Bot, out: *Io.Writer) !u8 {
    const a = ctx.arena;
    const memory = store.readMemory(ctx.io, ctx.dir, a, bot.name);
    const tail = store.logTail(ctx.io, ctx.dir, a, bot.name, store.log_tail_lines);
    const list = try rows(ctx, bot.name);
    if (opts.json) return writeJson(out, .{ .bot = bot, .memory = memory, .log = tail, .routines = list });
    try out.print("{s}\n  job: {s}\n", .{ bot.name, std.mem.trim(u8, bot.job, " \t\r\n") });
    if (bot.model.len > 0) try out.print("  model: {s}\n", .{bot.model});
    try out.print("  approvals: {s}\n", .{if (bot.yolo) "skipped (--yolo)" else "graff's headless default"});
    try out.print("\nmemory ({s}/{s}/memory.md)\n{s}\n", .{ store.store_rel, bot.name, if (memory.len > 0) memory else "(nothing yet)" });
    try out.writeAll("\nroutines\n");
    if (list.len == 0) try out.writeAll("(none)\n") else try printRows(out, list, false);
    try out.print("\nrecent log\n{s}\n", .{if (tail.len > 0) tail else "(no runs yet)"});
    return 0;
}

fn routineCommand(ctx: Ctx, opts: Opts, out: *Io.Writer) !u8 {
    const a = ctx.arena;
    const w = opts.words;
    if (w.len < 2) return error.Usage;
    const verb = w[1];
    if (std.mem.eql(u8, verb, "list") or std.mem.eql(u8, verb, "ls")) {
        const list = try rows(ctx, if (w.len > 2) w[2] else null);
        if (opts.json) return writeJson(out, list);
        if (list.len == 0) try out.writeAll("no routines\n");
        try printRows(out, list, w.len <= 2);
        return 0;
    }
    if (w.len < 4) return error.Usage;
    const name = w[2];
    const bot = store.load(ctx.io, ctx.dir, a, name) orelse return fail(out, "no bot named '{s}' in this folder (graff bot list)", .{name});
    if (std.mem.eql(u8, verb, "add")) {
        const when = store.parseWhen(w[3..]) orelse return fail(out, "'{s}' is not a time: use 5m (once) or \"@every 2h\" (s, m, h, d; a repeat is a minute or more)", .{w[3]});
        const r = store.addRoutine(ctx.io, ctx.dir, a, name, when, try std.mem.join(a, " ", w[3 + when.used ..]), ctx.now_ms) catch |err| return switch (err) {
            error.NoInstruction => fail(out, "say what the routine does after the time", .{}),
            else => err,
        };
        try out.print("\xe2\x9c\x93 {s}/{s}: {s}\n", .{ name, r.id, try store.describe(a, r) });
        return 0;
    }
    var r = store.loadRoutine(ctx.io, ctx.dir, a, name, w[3]) orelse return fail(out, "{s} has no routine {s}", .{ name, w[3] });
    const deleted = std.mem.eql(u8, verb, "rm");
    if (deleted) {
        try store.removeRoutine(ctx.io, ctx.dir, a, name, r.id);
    } else if (std.mem.eql(u8, verb, "pause") or std.mem.eql(u8, verb, "resume")) {
        r.paused = verb[0] == 'p';
        // A resumed routine waits for its next slot instead of running the
        // ones that passed while it was paused.
        if (!r.paused and r.interval_ms > 0 and r.at_ms <= ctx.now_ms)
            r.at_ms = @import("schedule.zig").nextGridSlot(r.at_ms, r.interval_ms, ctx.now_ms).next_at_ms;
        try store.saveRoutine(ctx.io, ctx.dir, a, name, r);
    } else if (std.mem.eql(u8, verb, "test")) {
        return printRun(out, try runTurn(ctx, opts, bot, try std.fmt.allocPrint(a, "routine {s} (test)", .{r.id}), try store.routineMessage(a, r, ""), .apply));
    } else return error.Usage;
    try out.print("\xe2\x9c\x93 {s}/{s}: {s}\n", .{ name, r.id, if (deleted) "deleted" else try store.describe(a, r) });
    return 0;
}

const DueRow = struct {
    bot: []const u8,
    id: []const u8,
    instruction: []const u8,
    at_ms: i64,
    /// What a client needs to run it itself: the system text and the turn.
    system: []const u8,
    message: []const u8,
};

fn dueCommand(ctx: Ctx, opts: Opts, out: *Io.Writer) !u8 {
    const a = ctx.arena;
    const list = store.due(ctx.io, ctx.dir, a, ctx.now_ms, opts.claim);
    if (!opts.json) {
        if (list.len == 0) try out.writeAll("nothing is due\n");
        for (list) |d| try out.print("{s}/{s}  {s}\n", .{ d.bot.name, d.routine.id, d.routine.instruction });
        return 0;
    }
    var out_rows: std.ArrayList(DueRow) = .empty;
    for (list) |d| try out_rows.append(a, .{
        .bot = d.bot.name,
        .id = d.routine.id,
        .instruction = d.routine.instruction,
        .at_ms = d.routine.at_ms,
        .system = try store.preamble(a, d.bot, store.readMemory(ctx.io, ctx.dir, a, d.bot.name), store.logTail(ctx.io, ctx.dir, a, d.bot.name, store.log_tail_lines), .chat),
        .message = try store.routineMessage(a, d.routine, ""),
    });
    return writeJson(out, out_rows.items);
}

const TickRow = struct { bot: []const u8, id: []const u8, ok: bool, summary: []const u8 };

fn tick(ctx: Ctx, opts: Opts, out: *Io.Writer) !u8 {
    const a = ctx.arena;
    var done: std.ArrayList(TickRow) = .empty;
    var code: u8 = 0;
    for (store.due(ctx.io, ctx.dir, a, ctx.now_ms, true)) |d| {
        const res = try runTurn(ctx, opts, d.bot, try std.fmt.allocPrint(a, "routine {s}", .{d.routine.id}), try store.routineMessage(a, d.routine, ""), .apply);
        if (!res.ok) code = 1;
        const what = store.summary(if (res.ok or res.text.len > 0) res.text else res.note);
        try done.append(a, .{ .bot = d.bot.name, .id = d.routine.id, .ok = res.ok, .summary = what });
        if (!opts.json) {
            try out.print("{s} {s}/{s}: {s}\n", .{ if (res.ok) "\xe2\x9c\x93" else "\xe2\x9c\x97", d.bot.name, d.routine.id, what });
            try out.flush();
        }
    }
    if (opts.json) {
        _ = try writeJson(out, done.items);
    } else if (done.items.len == 0) try out.writeAll("nothing is due\n");
    return code;
}

// ------------------------------------------------------------ real process

const Real = struct { io: Io, env: *const std.process.Environ.Map };

fn realRun(c: ?*anyopaque, arena: Allocator, argv: []const []const u8, timeout_s: u64) RunResult {
    const real: *Real = @ptrCast(@alignCast(c.?));
    const r = runner.runCappedWithOptions(arena, real.io, argv, 256 * 1024, 16 * 1024, timeout_s * std.time.ms_per_s, .{ .environ_map = real.env, .kill_process_tree = true }) catch |err|
        return .{ .ok = false, .note = @errorName(err) };
    const text = std.mem.trim(u8, r.stdout, " \t\r\n");
    if (runner.ranOk(r) and !r.timed_out and !r.cancelled) return .{ .ok = true, .text = text };
    return .{ .ok = false, .text = text, .note = if (r.timed_out) "it ran past its time limit" else if (r.cancelled) "it was cancelled" else std.mem.trim(u8, r.stderr, " \t\r\n") };
}

fn readStdin(io: Io, arena: Allocator) []const u8 {
    if (Io.File.stdin().isTty(io) catch true) return "";
    var buf: [4096]u8 = undefined;
    var r = Io.File.stdin().reader(io, &buf);
    return r.interface.allocRemaining(arena, .limited(256 * 1024)) catch "";
}

fn startsRun(words: []const []const u8) bool {
    const a = words[0];
    if (std.mem.eql(u8, a, "run") or std.mem.eql(u8, a, "tick") or std.mem.eql(u8, a, "trigger")) return true;
    return std.mem.eql(u8, a, "routine") and words.len > 1 and std.mem.eql(u8, words[1], "test");
}

pub fn command(gpa: Allocator, io: Io, arena: Allocator, environ: *const std.process.Environ.Map, args: []const []const u8) !void {
    var obuf: [4096]u8 = undefined;
    var w = Io.File.stdout().writerStreaming(io, &obuf);
    const out = &w.interface;
    var opts = parseOpts(arena, args) catch {
        try out.writeAll(usage);
        try out.flush();
        return;
    };
    const depth = std.fmt.parseInt(u32, environ.get(depth_env) orelse "0", 10) catch 0;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    if (startsRun(opts.words)) {
        if (depth >= max_depth) std.process.fatal("graff bot: {d} bot runs are already nested; a bot cannot start another one from here", .{depth});
        for (environ.keys(), environ.values()) |key, value| try env.put(key, value);
        try env.put(depth_env, try std.fmt.allocPrint(arena, "{d}", .{depth + 1}));
        if (std.mem.eql(u8, opts.words[0], "trigger")) opts.stdin_text = readStdin(io, arena);
    }
    var real: Real = .{ .io = io, .env = &env };
    const ctx: Ctx = .{
        .io = io,
        .dir = Io.Dir.cwd(),
        .arena = arena,
        .now_ms = util.unixMs(io),
        .exe = try std.process.executablePathAlloc(io, arena),
        .runner = .{ .ctx = &real, .run = realRun },
    };
    const code = dispatch(ctx, opts, out) catch |err| switch (err) {
        error.Usage => blk: {
            try out.writeAll(usage);
            break :blk @as(u8, 2);
        },
        else => return err,
    };
    try out.flush();
    if (code != 0) std.process.exit(code);
}
