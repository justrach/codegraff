//! Time-triggered tasks that wake a session (#556). Store is
//! `.graff/schedule/<id>.json`. Due-claim runs at the same step boundary as
//! job_notify. `/goal` is the standing-goal controller; this is cron.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const schema = @import("schema.zig");
const no_local_tools = @import("no_local_tools.zig");
const goal_pacing = @import("goal_pacing.zig");
const session_wake = @import("session_wake.zig");
const agent_mod = @import("agent.zig");
const tools_mod = @import("tools.zig");
const util = @import("util.zig");

const Agent = agent_mod.Agent;
const ToolCall = tools_mod.ToolCall;
const ExecResult = tools_mod.ExecResult;
const ToolSpec = schema.ToolSpec;

pub const tool_name = "schedule_task";
pub const tool_desc = "Schedule a prompt to wake this session later. delay is 30s/5m/2h. At the due time the prompt is injected as a user turn.";
pub const tool_schema =
    \\{"type": "object", "properties": {"delay": {"type": "string", "description": "30s, 5m, or 2h"}, "prompt": {"type": "string", "description": "what to do when it fires"}}, "required": ["delay", "prompt"]}
;

pub const store_rel = ".graff/schedule";

const tool_spec = ToolSpec{ .name = tool_name, .desc = tool_desc, .schema = tool_schema };

pub const MissedPolicy = enum {
    once,
    skip,

    pub fn parse(raw: []const u8) ?MissedPolicy {
        if (std.mem.eql(u8, raw, "once")) return .once;
        if (std.mem.eql(u8, raw, "skip")) return .skip;
        return null;
    }
};

/// One-shot tasks with `missed == .skip` that are older than this window when
/// claimed are dropped instead of firing stale after host sleep/downtime.
pub const stale_grace_ms: i64 = 60_000;

pub const Record = struct {
    id: []const u8,
    at_ms: i64,
    prompt: []const u8,
    claimed_ms: i64 = 0,
    interval_ms: i64 = 0,
    missed: MissedPolicy = .once,
    missed_fires: u32 = 0,
};

pub const AddOpts = struct {
    interval_ms: i64 = 0,
    missed: MissedPolicy = .once,
};

pub const GridStep = struct {
    next_at_ms: i64,
    missed_slots: u32,
};

/// Anchor a recurring schedule to its original wall-clock grid (`at_ms + k * interval_ms`)
/// so slow turns or host sleep never drift future fire slots.
pub fn nextGridSlot(at_ms: i64, interval_ms: i64, now_ms: i64) GridStep {
    if (interval_ms <= 0 or now_ms < at_ms) return .{ .next_at_ms = at_ms, .missed_slots = 0 };
    const elapsed = now_ms - at_ms;
    const steps = @divTrunc(elapsed, interval_ms) + 1;
    const missed: u32 = @intCast(@min(@max(steps - 1, 0), std.math.maxInt(u32)));
    return .{
        .next_at_ms = at_ms + steps * interval_ms,
        .missed_slots = missed,
    };
}

pub fn isName(name: []const u8) bool {
    return std.mem.eql(u8, name, tool_name);
}

pub fn catalogExtras(arena: Allocator) []const ToolSpec {
    _ = arena;
    if (no_local_tools.enabled or no_local_tools.lean) return &.{};
    return &.{tool_spec};
}

pub fn add(io: Io, arena: Allocator, at_ms: i64, prompt: []const u8) !Record {
    return addOpts(io, arena, at_ms, prompt, .{});
}

pub fn addOpts(io: Io, arena: Allocator, at_ms: i64, prompt: []const u8, opts: AddOpts) !Record {
    Io.Dir.cwd().createDirPath(io, store_rel) catch return error.StoreUnavailable;
    const id = try std.fmt.allocPrint(arena, "{d}", .{at_ms});
    const rec = Record{
        .id = id,
        .at_ms = at_ms,
        .prompt = prompt,
        .interval_ms = opts.interval_ms,
        .missed = opts.missed,
    };
    const text = try encode(arena, rec);
    const path = try std.fmt.allocPrint(arena, "{s}/{s}.json", .{ store_rel, id });
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch return error.StoreUnavailable;
    return rec;
}

fn encode(arena: Allocator, rec: Record) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(.{
        .id = rec.id,
        .at_ms = rec.at_ms,
        .prompt = rec.prompt,
        .claimed_ms = rec.claimed_ms,
        .interval_ms = rec.interval_ms,
        .missed = @tagName(rec.missed),
        .missed_fires = rec.missed_fires,
    });
    return aw.writer.buffered();
}

pub fn claimDue(io: Io, arena: Allocator, now_ms: i64) []const Record {
    var dir = Io.Dir.cwd().openDir(io, store_rel, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var it = dir.iterate();
    var out: std.ArrayList(Record) = .empty;
    while (it.next(io) catch null) |ent| {
        if (ent.kind != .file) continue;
        if (!std.mem.endsWith(u8, ent.name, ".json")) continue;
        const raw = dir.readFileAlloc(io, ent.name, arena, .limited(16 * 1024)) catch continue;
        const rec = parse(arena, raw) orelse continue;
        if (rec.claimed_ms != 0 or rec.at_ms > now_ms) continue;
        if (rec.interval_ms > 0) {
            const grid = nextGridSlot(rec.at_ms, rec.interval_ms, now_ms);
            const stale_slot = now_ms - rec.at_ms >= rec.interval_ms;
            var next_rec = rec;
            next_rec.at_ms = grid.next_at_ms;
            next_rec.claimed_ms = 0;
            if (rec.missed == .skip and stale_slot) {
                next_rec.missed_fires +|= grid.missed_slots +| 1;
                const text = encode(arena, next_rec) catch continue;
                dir.writeFile(io, .{ .sub_path = ent.name, .data = text }) catch continue;
                continue;
            }
            next_rec.missed_fires +|= grid.missed_slots;
            const text = encode(arena, next_rec) catch continue;
            dir.writeFile(io, .{ .sub_path = ent.name, .data = text }) catch continue;
            var fired = next_rec;
            fired.at_ms = rec.at_ms;
            fired.claimed_ms = now_ms;
            out.append(arena, fired) catch break;
            continue;
        }
        var claimed = rec;
        claimed.claimed_ms = now_ms;
        if (rec.missed == .skip and now_ms - rec.at_ms >= stale_grace_ms) {
            claimed.missed_fires +|= 1;
            const text = encode(arena, claimed) catch continue;
            dir.writeFile(io, .{ .sub_path = ent.name, .data = text }) catch continue;
            continue;
        }
        const text = encode(arena, claimed) catch continue;
        dir.writeFile(io, .{ .sub_path = ent.name, .data = text }) catch continue;
        out.append(arena, claimed) catch break;
    }
    return out.items;
}

fn parse(arena: Allocator, raw: []const u8) ?Record {
    const v = std.json.parseFromSliceLeaky(Value, arena, raw, .{}) catch return null;
    if (v != .object) return null;
    const id = if (v.object.get("id")) |x| (if (x == .string) x.string else "") else "";
    const prompt = if (v.object.get("prompt")) |x| (if (x == .string) x.string else "") else "";
    const at = if (v.object.get("at_ms")) |x| switch (x) {
        .integer => |n| n,
        else => return null,
    } else return null;
    const claimed = if (v.object.get("claimed_ms")) |x| switch (x) {
        .integer => |n| n,
        else => 0,
    } else 0;
    const interval = if (v.object.get("interval_ms")) |x| switch (x) {
        .integer => |n| @max(n, 0),
        else => 0,
    } else 0;
    const missed: MissedPolicy = if (v.object.get("missed")) |x|
        (if (x == .string) MissedPolicy.parse(x.string) orelse .once else .once)
    else
        .once;
    const missed_fires: u32 = if (v.object.get("missed_fires")) |x| switch (x) {
        .integer => |n| @intCast(@min(@max(n, 0), std.math.maxInt(u32))),
        else => 0,
    } else 0;
    if (id.len == 0 or prompt.len == 0) return null;
    return .{
        .id = id,
        .at_ms = at,
        .prompt = prompt,
        .claimed_ms = claimed,
        .interval_ms = interval,
        .missed = missed,
        .missed_fires = missed_fires,
    };
}

pub fn deliver(root: *Agent) void {
    if (root.sub) return;
    const due = claimDue(root.io, root.arena, util.unixMs(root.io));
    for (due) |rec| {
        const line = std.fmt.allocPrint(root.arena, "[schedule {s}] {s}", .{ rec.id, rec.prompt }) catch continue;
        session_wake.inject(root, line);
    }
}

const ParsedScheduleSpec = struct {
    delta_ms: i64,
    interval_ms: i64 = 0,
    missed: MissedPolicy = .once,
    prompt: []const u8,
    display_delay: []const u8,
};

fn parseSpec(rest_in: []const u8) ?ParsedScheduleSpec {
    var rest = std.mem.trim(u8, rest_in, " \t");
    var missed: MissedPolicy = .once;
    var recurring = false;
    while (rest.len > 0) {
        if (std.mem.startsWith(u8, rest, "--missed=")) {
            const sp = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
            missed = MissedPolicy.parse(rest["--missed=".len..sp]) orelse return null;
            rest = std.mem.trim(u8, rest[sp..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, rest, "@every ")) {
            recurring = true;
            rest = std.mem.trim(u8, rest["@every ".len..], " \t");
            continue;
        }
        break;
    }
    const budget = goal_pacing.parseLoopBudget(rest);
    const delta = budget.deadline_ms_delta orelse return null;
    if (budget.prompt.len == 0) return null;
    return .{
        .delta_ms = delta,
        .interval_ms = if (recurring) delta else 0,
        .missed = missed,
        .prompt = budget.prompt,
        .display_delay = std.mem.trim(u8, rest[0 .. rest.len - budget.prompt.len], " \t"),
    };
}

pub fn handleTool(self: *Agent, call: ToolCall) !ExecResult {
    if (self.sub) return .{ .text = "schedule_task is root-only", .is_error = true };
    if (no_local_tools.enabled or no_local_tools.lean) return .{ .text = "schedule_task is disabled under --no-local-tools / --lean", .is_error = true };
    const obj = tools_mod.json_args.object(call.input) orelse return .{ .text = "schedule_task needs an object", .is_error = true };
    const delay = tools_mod.json_args.str(obj, "delay") orelse "";
    const prompt = tools_mod.json_args.str(obj, "prompt") orelse "";
    if (delay.len == 0 or prompt.len == 0) return .{ .text = "usage: delay (30s|5m|2h or @every 30s|5m|2h) and prompt", .is_error = true };
    var missed: MissedPolicy = .once;
    if (tools_mod.json_args.str(obj, "missed")) |m| {
        missed = MissedPolicy.parse(m) orelse return .{ .text = "missed must be 'once' or 'skip'", .is_error = true };
    }
    const padded = try std.fmt.allocPrint(self.arena, "{s} {s}", .{ delay, prompt });
    const spec = parseSpec(padded) orelse return .{ .text = "delay must be 30s, 5m, or 2h (optionally prefixed with @every)", .is_error = true };
    const effective_missed = if (tools_mod.json_args.str(obj, "missed") != null) missed else spec.missed;
    const at = util.unixMs(self.io) + spec.delta_ms;
    const rec = addOpts(self.io, self.arena, at, spec.prompt, .{ .interval_ms = spec.interval_ms, .missed = effective_missed }) catch return .{ .text = "could not write .graff/schedule", .is_error = true };
    return .{ .text = try std.fmt.allocPrint(self.arena, "scheduled {s} at {d}", .{ rec.id, rec.at_ms }), .is_error = false };
}

/// `/schedule [30s|5m|2h | @every 30s|5m|2h] [--missed=once|skip] <prompt>`
pub fn slashCommand(root: *Agent, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    const rest = std.mem.trim(u8, line["/schedule".len..], " \t");
    if (rest.len == 0) {
        try out.writeAll("usage: /schedule <30s|5m|2h> <prompt>\n");
        try out.flush();
        return true;
    }
    const spec = parseSpec(rest) orelse {
        try out.writeAll("usage: /schedule <30s|5m|2h> <prompt>\n");
        try out.flush();
        return true;
    };
    const at = util.unixMs(root.io) + spec.delta_ms;
    const rec = addOpts(root.io, arena, at, spec.prompt, .{ .interval_ms = spec.interval_ms, .missed = spec.missed }) catch {
        try out.writeAll("could not write .graff/schedule\n");
        try out.flush();
        return true;
    };
    try out.print("scheduled {s} — fires in {s}\n", .{ rec.id, spec.display_delay });
    try out.flush();
    return true;
}

test "add then claimDue only yields past-due unclaimed records" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var orig = try Io.Dir.cwd().openDir(io, ".", .{});
    defer orig.close(io);
    defer _ = std.posix.system.fchdir(orig.handle);
    if (std.posix.system.fchdir(tmp.dir.handle) != 0) return error.ChdirFailed;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rec = try add(io, arena, 10, "check the deploy");
    try std.testing.expectEqualStrings("10", rec.id);
    try std.testing.expectEqual(@as(usize, 0), claimDue(io, arena, 9).len);
    const due = claimDue(io, arena, 11);
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqualStrings("check the deploy", due[0].prompt);
    try std.testing.expect(due[0].claimed_ms == 11);
    try std.testing.expectEqual(@as(usize, 0), claimDue(io, arena, 12).len);
}

/// Idle TUI auto-turn: claim due tasks into a buffer without an Agent.
pub fn takeWake(io: Io, buf: []u8) ?[]const u8 {
    var scratch: [32 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const due = claimDue(io, fba.allocator(), util.unixMs(io));
    if (due.len == 0) return null;
    var used: usize = 0;
    for (due) |rec| {
        const piece = if (used == 0)
            std.fmt.bufPrint(buf[used..], "[schedule {s}] {s}", .{ rec.id, rec.prompt }) catch break
        else
            std.fmt.bufPrint(buf[used..], "\n[schedule {s}] {s}", .{ rec.id, rec.prompt }) catch break;
        used += piece.len;
    }
    return if (used == 0) null else buf[0..used];
}

test "slashCommand and takeWake share the due-claim store" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var orig = try Io.Dir.cwd().openDir(io, ".", .{});
    defer orig.close(io);
    defer _ = std.posix.system.fchdir(orig.handle);
    if (std.posix.system.fchdir(tmp.dir.handle) != 0) return error.ChdirFailed;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: Agent = undefined;
    root.io = io;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.testing.expect(try slashCommand(&root, arena, "/schedule 30s check the deploy", &aw.writer));
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "scheduled") != null);
    const rec = try add(io, arena, 1, "already due");
    try std.testing.expectEqualStrings("1", rec.id);
    var buf: [256]u8 = undefined;
    const wake = takeWake(io, &buf) orelse return error.Empty;
    try std.testing.expect(std.mem.indexOf(u8, wake, "[schedule 1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, wake, "already due") != null);
    try std.testing.expect(takeWake(io, &buf) == null);
}

test "nextGridSlot anchors recurring schedules to wall-clock grid without drift" {
    const on_time = nextGridSlot(1_000, 60_000, 1_500);
    try std.testing.expectEqual(@as(i64, 61_000), on_time.next_at_ms);
    try std.testing.expectEqual(@as(u32, 0), on_time.missed_slots);

    const after_sleep = nextGridSlot(1_000, 60_000, 310_000);
    try std.testing.expectEqual(@as(i64, 361_000), after_sleep.next_at_ms);
    try std.testing.expectEqual(@as(u32, 5), after_sleep.missed_slots);
}

test "recurring schedule coalesces missed fires under .once and drops stale slots under .skip" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var orig = try Io.Dir.cwd().openDir(io, ".", .{});
    defer orig.close(io);
    defer _ = std.posix.system.fchdir(orig.handle);
    if (std.posix.system.fchdir(tmp.dir.handle) != 0) return error.ChdirFailed;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = try addOpts(io, arena, 1_000, "once-catchup", .{ .interval_ms = 60_000, .missed = .once });
    _ = try addOpts(io, arena, 2_000, "skip-stale", .{ .interval_ms = 60_000, .missed = .skip });

    // Wake after 5 intervals: .once fires a single catch-up turn and advances to 361_000;
    // .skip drops the stale slot and advances to 362_000 without firing now.
    const due = claimDue(io, arena, 310_000);
    try std.testing.expectEqual(@as(usize, 1), due.len);
    try std.testing.expectEqualStrings("once-catchup", due[0].prompt);
    try std.testing.expectEqual(@as(u32, 5), due[0].missed_fires);

    // Before 361_000 neither is due; at 365_000 (on time for the 361_000/362_000 grid slot) both fire!
    try std.testing.expectEqual(@as(usize, 0), claimDue(io, arena, 360_000).len);
    const next_due = claimDue(io, arena, 365_000);
    try std.testing.expectEqual(@as(usize, 2), next_due.len);
}
