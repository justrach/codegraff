//! Bots as contacts (ADR 0334): what a client keeps on a bot, what every bot
//! knows about the user, and the record of when routines were last checked
//! and which came due while nothing was checking.
//!
//!   .graff/bots/check.json   when something last checked, and the last gap
//!   .graff/bots/about.md     a few facts about the user, shown to every bot
//!
//! Files and pure rules, like bot_store.zig.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const store = @import("bot_store.zig");
const schedule = @import("schedule.zig");

pub const check_rel = store.store_rel ++ "/check.json";
pub const about_rel = store.store_rel ++ "/about.md";
pub const about_cap: usize = 2048;
const chat_cap: usize = 128;

// -------------------------------------------------------------------- flag

/// Bots are experimental. They are off until the user turns them on, and the
/// switch is one file in the user's home, so the terminal, a client's engine
/// and a bot's own chat all read the same answer.
pub const enabled_rel = store.store_rel ++ "/enabled";
pub const flag_env = "GRAFF_BOTS";

/// Whether bots are on. `GRAFF_BOTS=1` turns them on for one process and
/// `GRAFF_BOTS=0` off, whatever the file says.
pub fn enabled(env_value: ?[]const u8, marker: bool) bool {
    if (env_value) |v| {
        if (std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true")) return true;
        if (std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "false")) return false;
    }
    return marker;
}

pub fn marked(io: Io, home: Io.Dir) bool {
    const stat = home.statFile(io, enabled_rel, .{}) catch return false;
    return stat.kind == .file;
}

/// Turn bots on or off. Off keeps every bot and what it remembers.
pub fn mark(io: Io, home: Io.Dir, on: bool) !void {
    if (on) {
        try home.createDirPath(io, store.store_rel);
        try home.writeFile(io, .{ .sub_path = enabled_rel, .data = "bots are on; `graff bot disable` turns them off\n" });
    } else home.deleteFile(io, enabled_rel) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

// ------------------------------------------------------------------ checks

pub const Check = struct {
    /// When routines were last checked.
    last_ms: i64 = 0,
    /// The most recent stretch in which nothing checked.
    gap_from_ms: i64 = 0,
    gap_to_ms: i64 = 0,
};

pub fn readCheck(io: Io, dir: Io.Dir, arena: Allocator) Check {
    return store.readJson(Check, io, dir, arena, check_rel) orelse .{};
}

/// The record after a check at `now_ms`. A silence longer than `stale_ms`
/// since the check before is kept as the latest gap.
pub fn checked(prev: Check, now_ms: i64, stale_ms: i64) Check {
    var next = prev;
    next.last_ms = now_ms;
    if (stale_ms > 0 and prev.last_ms > 0 and now_ms - prev.last_ms > stale_ms) {
        next.gap_from_ms = prev.last_ms;
        next.gap_to_ms = now_ms;
    }
    return next;
}

pub const Settled = struct { next: store.Routine, run: bool };

/// What a check at `now_ms` does with a routine, or null when it is not due.
/// With `stale_ms` of zero a late slot still runs, once (`store.advance`).
/// Otherwise a slot older than `stale_ms` is not run late: it is recorded as
/// missed, so a client can show "was due, did not run" and let the user
/// choose. Only the newest slot runs, and only if it is still fresh.
pub fn settle(r: store.Routine, now_ms: i64, stale_ms: i64) ?Settled {
    if (stale_ms <= 0) return if (store.advance(r, now_ms)) |next| .{ .next = next, .run = true } else null;
    if (r.paused or r.done or r.at_ms > now_ms) return null;
    var next = r;
    var skipped: u32 = 0;
    var run = true;
    if (r.interval_ms > 0) {
        const grid = schedule.nextGridSlot(r.at_ms, r.interval_ms, now_ms);
        run = now_ms - (grid.next_at_ms - r.interval_ms) <= stale_ms;
        skipped = grid.missed_slots +| @intFromBool(!run);
        next.at_ms = grid.next_at_ms;
    } else {
        run = now_ms - r.at_ms <= stale_ms;
        skipped = @intFromBool(!run);
        next.done = true;
    }
    if (skipped > 0) {
        if (next.missed_open == 0) next.missed_at_ms = r.at_ms;
        next.missed_open +|= skipped;
        next.missed_fires +|= skipped;
    }
    if (run) {
        next.runs +|= 1;
        next.last_run_ms = now_ms;
    }
    return .{ .next = next, .run = run };
}

fn dueBefore(_: void, a: store.Due, b: store.Due) bool {
    return a.routine.at_ms < b.routine.at_ms;
}

/// Check every routine at `now_ms`: move each due one to its next slot,
/// record the check, and return the ones to run, oldest slot first.
pub fn claim(io: Io, dir: Io.Dir, arena: Allocator, now_ms: i64, stale_ms: i64) []const store.Due {
    var out: std.ArrayList(store.Due) = .empty;
    const bots = store.list(io, dir, arena);
    for (bots) |bot| {
        for (store.routines(io, dir, arena, bot.name)) |r| {
            const s = settle(r, now_ms, stale_ms) orelse continue;
            store.saveRoutine(io, dir, arena, bot.name, s.next) catch continue;
            if (s.run) out.append(arena, .{ .bot = bot, .routine = r }) catch break;
        }
    }
    // No bots, no record: a check must not create a store in a folder.
    if (bots.len > 0) store.writeJson(io, dir, arena, check_rel, checked(readCheck(io, dir, arena), now_ms, stale_ms)) catch {};
    std.mem.sort(store.Due, out.items, {}, dueBefore);
    return out.items;
}

pub const Missed = struct {
    bot: []const u8,
    id: []const u8,
    instruction: []const u8,
    /// The first slot that was not run, and how many were not.
    at_ms: i64,
    count: u32,
};

pub fn missed(io: Io, dir: Io.Dir, arena: Allocator) []const Missed {
    var out: std.ArrayList(Missed) = .empty;
    for (store.list(io, dir, arena)) |bot| {
        for (store.routines(io, dir, arena, bot.name)) |r| {
            if (r.missed_open == 0) continue;
            out.append(arena, .{ .bot = bot.name, .id = r.id, .instruction = r.instruction, .at_ms = r.missed_at_ms, .count = r.missed_open }) catch break;
        }
    }
    return out.items;
}

/// The user ran it or dismissed it: the routine no longer reports a miss.
pub fn clearMissed(io: Io, dir: Io.Dir, arena: Allocator, name: []const u8, id: []const u8) !void {
    var r = store.loadRoutine(io, dir, arena, name, id) orelse return error.NoSuchRoutine;
    r.missed_at_ms = 0;
    r.missed_open = 0;
    try store.saveRoutine(io, dir, arena, name, r);
}

// ------------------------------------------------------------------ fields

pub const SetError = error{ NoSuchBot, BadKey, BadValue, StoreUnavailable, OutOfMemory };

pub const keys = "job, model, project, chat, primary";

fn plain(value: []const u8, cap: usize) bool {
    if (value.len > cap) return false;
    for (value) |c| if (c <= ' ' or c == 0x7f) return false;
    return true;
}

/// Change one field of a bot. `primary` moves: making one bot primary makes
/// every other bot not primary.
pub fn set(io: Io, dir: Io.Dir, arena: Allocator, name: []const u8, key: []const u8, raw: []const u8) SetError!store.Bot {
    var bot = store.load(io, dir, arena, name) orelse return error.NoSuchBot;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.eql(u8, key, "job")) {
        if (value.len == 0) return error.BadValue;
        bot.job = value;
    } else if (std.mem.eql(u8, key, "model")) {
        if (!plain(value, 128)) return error.BadValue;
        bot.model = value;
    } else if (std.mem.eql(u8, key, "project")) {
        if (value.len > 0 and !std.fs.path.isAbsolute(value)) return error.BadValue;
        bot.project = value;
    } else if (std.mem.eql(u8, key, "chat")) {
        if (!plain(value, chat_cap)) return error.BadValue;
        bot.chat = value;
    } else if (std.mem.eql(u8, key, "primary")) {
        const on = std.mem.eql(u8, value, "true");
        if (!on and !std.mem.eql(u8, value, "false")) return error.BadValue;
        if (on) for (store.list(io, dir, arena)) |other| {
            if (!other.primary or std.mem.eql(u8, other.name, name)) continue;
            var o = other;
            o.primary = false;
            store.saveBot(io, dir, arena, o) catch return error.StoreUnavailable;
        };
        bot.primary = on;
    } else return error.BadKey;
    store.saveBot(io, dir, arena, bot) catch return error.StoreUnavailable;
    return bot;
}

// ------------------------------------------------------------------- about

pub fn readAbout(io: Io, dir: Io.Dir, arena: Allocator) []const u8 {
    const raw = dir.readFileAlloc(io, about_rel, arena, .limited(64 * 1024)) catch return "";
    const text = std.mem.trim(u8, raw, " \t\r\n");
    return if (text.len > about_cap) text[0..about_cap] else text;
}

pub fn writeAbout(io: Io, dir: Io.Dir, text: []const u8) !void {
    const body = std.mem.trim(u8, text, " \t\r\n");
    if (body.len > about_cap) return error.TooLong;
    try dir.createDirPath(io, store.store_rel);
    try dir.writeFile(io, .{ .sub_path = about_rel, .data = body });
}
