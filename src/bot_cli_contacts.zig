//! `graff bot` commands for bots as contacts (ADR 0334): the one-call state a
//! client draws from, the fields it keeps on a bot, memory entries by
//! command, what every bot knows about the user, and missed routines.

const std = @import("std");
const Io = std.Io;
const cli = @import("bot_cli.zig");
const store = @import("bot_store.zig");
const contacts = @import("bot_contacts.zig");

const BotRow = struct {
    name: []const u8,
    job: []const u8,
    model: []const u8,
    yolo: bool,
    project: []const u8,
    primary: bool,
    chat: []const u8,
    created_ms: i64,
    routines: []const cli.RoutineRow,
};

const State = struct {
    scope: []const u8,
    now_ms: i64,
    /// When routines were last checked, and the last stretch nothing checked.
    last_check_ms: i64,
    gap_from_ms: i64,
    gap_to_ms: i64,
    about: []const u8,
    bots: []const BotRow,
};

fn state(ctx: cli.Ctx) !State {
    const a = ctx.arena;
    var bots: std.ArrayList(BotRow) = .empty;
    for (store.list(ctx.io, ctx.dir, a)) |bot| {
        var routines: std.ArrayList(cli.RoutineRow) = .empty;
        for (store.routines(ctx.io, ctx.dir, a, bot.name)) |r| try routines.append(a, try cli.row(a, bot.name, r, ctx.now_ms));
        try bots.append(a, .{ .name = bot.name, .job = bot.job, .model = bot.model, .yolo = bot.yolo, .project = bot.project, .primary = bot.primary, .chat = bot.chat, .created_ms = bot.created_ms, .routines = routines.items });
    }
    const check = contacts.readCheck(ctx.io, ctx.dir, a);
    return .{
        .scope = @tagName(ctx.scope),
        .now_ms = ctx.now_ms,
        .last_check_ms = check.last_ms,
        .gap_from_ms = check.gap_from_ms,
        .gap_to_ms = check.gap_to_ms,
        .about = contacts.readAbout(ctx.io, ctx.dir, a),
        .bots = bots.items,
    };
}

/// One memory entry, as `remember` and `forget` take it.
fn entry(text: []const u8) ?[]const u8 {
    const e = std.mem.trim(u8, text, " \t\r\n");
    if (e.len == 0 or e.len > store.entry_cap or std.mem.indexOfAny(u8, e, "\r\n") != null) return null;
    return e;
}

/// The commands of this file, or null when `opts` names another one.
pub fn dispatch(ctx: cli.Ctx, opts: cli.Opts, out: *Io.Writer) !?u8 {
    const a = ctx.arena;
    const w = opts.words;
    const action = w[0];
    if (std.mem.eql(u8, action, "state")) {
        const s = try state(ctx);
        if (opts.json) return try cli.writeJson(out, s);
        var b: [17]u8 = undefined;
        try out.print("{d} bot(s) in {s}; routines last checked {s}\n", .{ s.bots.len, ctx.scope.where(), if (s.last_check_ms > 0) store.stamp(&b, s.last_check_ms) else "never" });
        for (s.bots) |bot| try out.print("{s}{s}  {s}  {d} routine(s)\n", .{ bot.name, if (bot.primary) " (primary)" else "", store.summary(bot.job), bot.routines.len });
        return 0;
    }
    if (std.mem.eql(u8, action, "about")) {
        if (w.len > 1) {
            contacts.writeAbout(ctx.io, ctx.dir, try std.mem.join(a, " ", w[1..])) catch |err| return switch (err) {
                error.TooLong => try cli.fail(out, "keep it under {d} bytes: a few facts, not a profile", .{contacts.about_cap}),
                else => try cli.fail(out, "could not write {s}/about.md", .{ctx.scope.where()}),
            };
            return 0;
        }
        const text = contacts.readAbout(ctx.io, ctx.dir, a);
        try out.print("{s}\n", .{if (text.len > 0) text else "(nothing yet)"});
        return 0;
    }
    if (std.mem.eql(u8, action, "missed")) {
        if (w.len > 1) {
            if (w.len != 4 or !std.mem.eql(u8, w[1], "clear")) return error.Usage;
            contacts.clearMissed(ctx.io, ctx.dir, a, w[2], w[3]) catch return try cli.fail(out, "{s} has no routine {s}", .{ w[2], w[3] });
            return 0;
        }
        const list = contacts.missed(ctx.io, ctx.dir, a);
        if (opts.json) return try cli.writeJson(out, list);
        if (list.len == 0) try out.writeAll("nothing was missed\n");
        var b: [17]u8 = undefined;
        for (list) |m| try out.print("{s}/{s}  due {s}, did not run ({d})  {s}\n", .{ m.bot, m.id, store.stamp(&b, m.at_ms), m.count, m.instruction });
        return 0;
    }
    const by_name = std.mem.eql(u8, action, "set") or std.mem.eql(u8, action, "remember") or std.mem.eql(u8, action, "forget");
    if (!by_name) return null;
    if (w.len < 3) return error.Usage;
    const name = w[1];
    if (action[0] == 's') {
        const bot = contacts.set(ctx.io, ctx.dir, a, name, w[2], try std.mem.join(a, " ", w[3..])) catch |err| return switch (err) {
            error.NoSuchBot => try cli.fail(out, "no bot named '{s}' here (graff bot list)", .{name}),
            error.BadKey => try cli.fail(out, "'{s}' is not a field: use {s}", .{ w[2], contacts.keys }),
            error.BadValue => try cli.fail(out, "that is not a value for {s} (job: text; project: a full path; primary: true or false)", .{w[2]}),
            error.StoreUnavailable => try cli.fail(out, "could not write {s}", .{ctx.scope.where()}),
            error.OutOfMemory => error.OutOfMemory,
        };
        if (opts.json) return try cli.writeJson(out, bot);
        return 0;
    }
    if (store.load(ctx.io, ctx.dir, a, name) == null) return try cli.fail(out, "no bot named '{s}' here (graff bot list)", .{name});
    const text = entry(try std.mem.join(a, " ", w[2..])) orelse return try cli.fail(out, "an entry is one line, {d} bytes at most", .{store.entry_cap});
    const one = [_][]const u8{text};
    const forget = action[0] == 'f';
    const change = try store.applyMemory(ctx.io, ctx.dir, a, name, .{ .reply = "", .remember = if (forget) &.{} else &one, .forget = if (forget) &one else &.{} });
    if (forget and change.removed == 0) return try cli.fail(out, "{s} has no entry that reads exactly that", .{name});
    try out.print("\xe2\x9c\x93 memory: {d} added, {d} removed\n", .{ change.added, change.removed });
    return 0;
}
