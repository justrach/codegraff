//! The automatic half of the learning loop.
//!
//! `graff learn` shipped as a complete engine that nothing ever called: every
//! trial needed a human to type it, so no workspace ever produced a second
//! generation. This module is the missing edge. When a session that did real
//! model work ends in a workspace with a configured learning store, it counts
//! the session and — on cadence — starts one detached trial in the background.
//!
//! Deliberate limits, because a trial spends real model calls:
//!   * it never runs without a configured store (`graff learn init` is the
//!     opt-in),
//!   * automatic promotion still needs `auto.enabled` in the immutable
//!     configuration plus every statistical gate,
//!   * one trial per cadence window, never two at once, and
//!   * `GRAFF_LEARN_AUTO=off` disables the trigger outright.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const posix_process_groups = switch (builtin.os.tag) {
    .windows, .wasi => false,
    else => true,
};

const store_mod = @import("learn_store.zig");
const checkpoint = @import("learn_checkpoint.zig");
const scoring = @import("scoring.zig");
const util = @import("util.zig");

pub const schema = "codegraff.learn.auto.v1";
pub const file_name = "auto.json";
pub const log_name = "auto.log";

/// Sessions between trials, and the floor on wall-clock between them. A busy
/// day of short sessions should not queue up a trial per session.
pub const default_every_sessions: u64 = 5;
pub const default_minimum_interval_ms: i64 = 6 * 60 * 60 * 1000;

pub const Record = struct {
    schema: []const u8 = schema,
    sessions_since_trial: u64 = 0,
    trials_started: u64 = 0,
    last_started_unix_ms: i64 = 0,
};

pub const Skip = enum {
    /// GRAFF_LEARN_AUTO said no.
    disabled,
    /// Nothing to learn from: the session made no model calls.
    idle_session,
    /// This workspace has no learning store (`graff learn init`).
    unconfigured,
    /// The configuration keeps promotion manual, so a background trial would
    /// only pile up evidence nobody reads.
    manual_only,
    /// Another learning operation holds the engine lock.
    busy,
    /// Cadence not reached yet.
    not_due,
};

pub const Outcome = union(enum) {
    skipped: Skip,
    started: struct { resumed: bool, contribute: bool },
    /// This workspace does real work but has no learning store yet. Said once
    /// per workspace — a loop nobody knows about is not on by default.
    suggest,
};

/// Marker for the one-time `learn init` hint.
const hint_file = ".graff/learn-hint";
/// Enough model calls that this is a working repository, not a one-liner.
const hint_minimum_calls: u64 = 5;

fn suggestOnce(io: Io, model_calls: u64) Outcome {
    if (model_calls < hint_minimum_calls) return .{ .skipped = .unconfigured };
    const file = Io.Dir.cwd().createFile(io, hint_file, .{ .exclusive = true }) catch
        return .{ .skipped = .unconfigured };
    file.close(io);
    return .suggest;
}

pub const Options = struct {
    /// Model calls this session made; zero means there is nothing new to learn
    /// from and the trigger stays quiet.
    model_calls: u64,
    /// Fleet + learning-privacy allow publishing prompt-free aggregate grades.
    contribute: bool,
    every_sessions: u64 = default_every_sessions,
    minimum_interval_ms: i64 = default_minimum_interval_ms,
};

/// Off only when explicitly turned off: the loop is on by default in a
/// workspace that has already opted into learning by initializing a store.
pub fn enabled(value: ?[]const u8) bool {
    const raw = value orelse return true;
    if (std.ascii.eqlIgnoreCase(raw, "off") or std.mem.eql(u8, raw, "0") or
        std.ascii.eqlIgnoreCase(raw, "false") or std.ascii.eqlIgnoreCase(raw, "no")) return false;
    return true;
}

pub fn due(record: Record, now_unix_ms: i64, options: Options) bool {
    if (record.sessions_since_trial < options.every_sessions) return false;
    // A never-run store is due as soon as the session count says so; a clock
    // that jumped backwards must not make a trial unreachable forever.
    if (record.last_started_unix_ms <= 0) return true;
    const elapsed = now_unix_ms -| record.last_started_unix_ms;
    return elapsed < 0 or elapsed >= options.minimum_interval_ms;
}

pub fn load(arena: Allocator, store: *store_mod.Store) Record {
    const bytes = store_mod.readFileNoFollow(store.io, store.refs, file_name, arena, 4096) catch return .{};
    const record = std.json.parseFromSliceLeaky(Record, arena, bytes, .{}) catch return .{};
    if (!std.mem.eql(u8, record.schema, schema)) return .{};
    return record;
}

pub fn save(gpa: Allocator, store: *store_mod.Store, record: Record) !void {
    const bytes = try store_mod.jsonBytes(gpa, record);
    defer gpa.free(bytes);
    try store.writeAtomicReplace(store.refs, file_name, bytes);
}

fn hasPendingTrial(store: *store_mod.Store) bool {
    const file = store.refs.openFile(store.io, checkpoint.file_name, .{ .follow_symlinks = false, .resolve_beneath = true }) catch return false;
    file.close(store.io);
    return true;
}

/// Build the trial command. Kept separate from spawning so the shape of an
/// automatic trial is testable without starting one.
pub fn trialArgv(argv: *[8][]const u8, exe_path: []const u8, resumed: bool, contribute: bool) []const []const u8 {
    var argc: usize = 0;
    for ([_][]const u8{ exe_path, "--learning-privacy", if (contribute) "aggregate" else "local", "learn", "run", "--auto" }) |arg| {
        argv[argc] = arg;
        argc += 1;
    }
    // A checkpointed tournament must continue, not restart: restarting would
    // re-expose the holdout it already reserved.
    if (resumed) {
        argv[argc] = "--resume";
        argc += 1;
    }
    if (contribute) {
        argv[argc] = "--submit";
        argc += 1;
    }
    return argv[0..argc];
}

fn openLog(store: *store_mod.Store) ?Io.File {
    return store.root.createFile(store.io, log_name, .{ .truncate = true }) catch null;
}

/// Count this session and, when due, start one detached trial. Never fails the
/// session: every error path is a skip.
pub fn maybeStart(gpa: Allocator, arena: Allocator, io: Io, environ: *const std.process.Environ.Map, options: Options) Outcome {
    if (!enabled(environ.get("GRAFF_LEARN_AUTO"))) return .{ .skipped = .disabled };
    if (options.model_calls == 0) return .{ .skipped = .idle_session };
    var store = store_mod.Store.openAt(io, Io.Dir.cwd()) catch return suggestOnce(io, options.model_calls);
    defer store.deinit();
    var lock = store.acquireLock(0) catch return .{ .skipped = .busy };
    var lock_held = true;
    defer if (lock_held) lock.deinit();

    const config = store.loadConfig(arena) catch return .{ .skipped = .unconfigured };
    if (!config.value.auto.enabled) return .{ .skipped = .manual_only };

    var record = load(arena, &store);
    record.sessions_since_trial +|= 1;
    const now = util.unixMs(io);
    if (!due(record, now, options)) {
        save(gpa, &store, record) catch {};
        return .{ .skipped = .not_due };
    }

    // Contribution needs a signing key as well as consent. Asking for
    // `--submit` without one fails the whole trial in preflight, so a machine
    // that cannot sign simply learns locally.
    const contribute = options.contribute and scoring.loadScoreKey(io, arena, environ) != null;
    const resumed = hasPendingTrial(&store);
    const exe_path = std.process.executablePathAlloc(io, gpa) catch return .{ .skipped = .unconfigured };
    defer gpa.free(exe_path);
    var argv_buf: [8][]const u8 = undefined;
    const argv = trialArgv(&argv_buf, exe_path, resumed, contribute);

    record.sessions_since_trial = 0;
    record.trials_started +|= 1;
    record.last_started_unix_ms = now;
    save(gpa, &store, record) catch {};

    const log = openLog(&store);
    defer if (log) |file| file.close(io);
    // Release the engine lock before the child asks for it.
    lock.deinit();
    lock_held = false;

    _ = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = if (log) |file| .{ .file = file } else .ignore,
        .stderr = if (log) |file| .{ .file = file } else .ignore,
        // Its own process group: the trial outlives this session, and a
        // Ctrl-C aimed at the shell's foreground group afterwards must not
        // kill a tournament mid-holdout.
        .pgid = if (posix_process_groups) 0 else null,
    }) catch return .{ .skipped = .busy };
    // Deliberately not waited on. The trial reports through
    // `graff learn status` and .graff/learn/auto.log.
    return .{ .started = .{ .resumed = resumed, .contribute = contribute } };
}

test "the trigger is on unless it is explicitly turned off" {
    try std.testing.expect(enabled(null));
    try std.testing.expect(enabled("1"));
    try std.testing.expect(enabled("on"));
    try std.testing.expect(!enabled("off"));
    try std.testing.expect(!enabled("OFF"));
    try std.testing.expect(!enabled("0"));
    try std.testing.expect(!enabled("false"));
    try std.testing.expect(!enabled("no"));
}

test "cadence needs both the session count and the interval" {
    const options: Options = .{ .model_calls = 1, .contribute = false };
    const hour = 60 * 60 * 1000;
    try std.testing.expect(!due(.{ .sessions_since_trial = 4 }, 100 * hour, options));
    // Never run before: the session count alone is enough.
    try std.testing.expect(due(.{ .sessions_since_trial = 5 }, 100 * hour, options));
    try std.testing.expect(!due(.{ .sessions_since_trial = 9, .last_started_unix_ms = 99 * hour }, 100 * hour, options));
    try std.testing.expect(due(.{ .sessions_since_trial = 9, .last_started_unix_ms = 90 * hour }, 100 * hour, options));
    // A backwards clock jump must not wedge the loop permanently.
    try std.testing.expect(due(.{ .sessions_since_trial = 9, .last_started_unix_ms = 200 * hour }, 100 * hour, options));
}

test "an automatic trial always carries the two-key auto flag and never restarts a checkpoint" {
    var argv: [8][]const u8 = undefined;
    const local = trialArgv(&argv, "graff", false, false);
    try std.testing.expectEqualSlices([]const u8, &.{ "graff", "--learning-privacy", "local", "learn", "run", "--auto" }, local);
    const resumed = trialArgv(&argv, "graff", true, true);
    try std.testing.expectEqualSlices([]const u8, &.{ "graff", "--learning-privacy", "aggregate", "learn", "run", "--auto", "--resume", "--submit" }, resumed);
}
