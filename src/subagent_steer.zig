//! Direct user & ACP steering for background subagents (`@agent-1 <msg>`,
//! `@sa-001-... <msg>`, `/workers send <id> <msg>`, `graff/agents` `action:"steer"`).
//! Routes into the child's thread-safe `subagent_feedback.Inbox` while running,
//! or resumes a retained worker if it already completed (Codex `followup_task`
//! / OpenCode `steer` parity across REPL and ACP).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const subagent = @import("subagent.zig");
const tools = @import("tools.zig");
const ansi = @import("ansi.zig");
const style = &ansi.style;

pub const Parsed = struct {
    target: []const u8,
    message: []const u8,
};

pub const SteerOutcome = enum {
    queued,
    resumed,
    finished,
    not_found,
    invalid,
};

pub const SteerResult = struct {
    outcome: SteerOutcome,
    id: u32 = 0,
    sub_id_buf: [40]u8 = undefined,
    sub_id_len: u8 = 0,
    label_buf: [64]u8 = undefined,
    label_len: u8 = 0,
    detail: []const u8 = "",

    pub fn subId(self: *const SteerResult) []const u8 {
        return self.sub_id_buf[0..self.sub_id_len];
    }

    pub fn label(self: *const SteerResult) []const u8 {
        return self.label_buf[0..self.label_len];
    }
};

/// True when a composer line addresses a subagent (`@agent-1 ...`, `@sa-... ...`).
pub fn isSubagentSteer(text: []const u8) bool {
    return parseSteerLine(text) != null;
}

/// Parse `@agent-1 <msg>`, `@agent1 <msg>`, `@sa-... <msg>`, or `@worker-... <msg>`.
pub fn parseSteerLine(text: []const u8) ?Parsed {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len < 4 or t[0] != '@') return null;
    const body = t[1..];
    const space = std.mem.indexOfAny(u8, body, " \t\r\n") orelse return null;
    const raw_target = body[0..space];
    const msg = std.mem.trim(u8, body[space + 1 ..], " \t\r\n");
    if (msg.len == 0) return null;
    if (std.ascii.startsWithIgnoreCase(raw_target, "agent-")) {
        const rest = raw_target["agent-".len..];
        if (rest.len == 0) return null;
        return .{ .target = rest, .message = msg };
    }
    if (std.ascii.startsWithIgnoreCase(raw_target, "agent")) {
        const rest = raw_target["agent".len..];
        if (rest.len == 0) return null;
        return .{ .target = rest, .message = msg };
    }
    if (std.ascii.startsWithIgnoreCase(raw_target, "sa-") or std.ascii.startsWithIgnoreCase(raw_target, "worker-")) {
        return .{ .target = raw_target, .message = msg };
    }
    return null;
}

/// Normalize a user target token (`"1"`, `"#1"`, `"agent-1"`, `"agent 1"` -> `1`).
pub fn parseNumericId(target: []const u8) ?u32 {
    var s = std.mem.trim(u8, target, " \t\r\n");
    if (s.len > 0 and s[0] == '#') s = s[1..];
    if (std.ascii.startsWithIgnoreCase(s, "agent-")) {
        s = s["agent-".len..];
    } else if (std.ascii.startsWithIgnoreCase(s, "agent ")) {
        s = std.mem.trimStart(u8, s["agent ".len..], " \t");
    } else if (std.ascii.startsWithIgnoreCase(s, "agent")) {
        s = s["agent".len..];
    }
    if (s.len == 0) return null;
    const n = std.fmt.parseInt(u32, s, 10) catch return null;
    return if (n > 0) n else null;
}

pub fn matchesJob(job: *const subagent.AgentJob, target: []const u8) bool {
    const trimmed = std.mem.trim(u8, target, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (parseNumericId(trimmed)) |num| {
        if (job.id == num) return true;
    }
    const sid = job.feedback.subId();
    if (sid.len > 0 and (std.mem.eql(u8, sid, trimmed) or (trimmed.len >= 4 and std.mem.startsWith(u8, sid, trimmed)))) return true;
    if (job.ctx.retained_worker) |state| {
        if (std.mem.eql(u8, state.record.id, trimmed)) return true;
    }
    if (job.label.len > 0 and std.ascii.eqlIgnoreCase(job.label, trimmed)) return true;
    return false;
}

const LiveSlot = struct {
    id: u32 = 0,
    sub_id_buf: [40]u8 = undefined,
    sub_id_len: u8 = 0,
    label_buf: [64]u8 = undefined,
    label_len: u8 = 0,
    gpa: Allocator = undefined,
    inbox: ?*@import("subagent_feedback.zig").Inbox = null,

    fn subId(self: *const LiveSlot) []const u8 {
        return self.sub_id_buf[0..self.sub_id_len];
    }

    fn label(self: *const LiveSlot) []const u8 {
        return self.label_buf[0..self.label_len];
    }
};

var live_mu: Io.Mutex = .init;
var live_slots: [32]LiveSlot = @splat(.{});

pub fn registerLive(io: Io, gpa: Allocator, ordinal: u32, sub_id: []const u8, lbl: []const u8, inbox: *@import("subagent_feedback.zig").Inbox) void {
    live_mu.lockUncancelable(io);
    defer live_mu.unlock(io);
    for (&live_slots) |*slot| {
        if (slot.inbox == null) {
            slot.id = ordinal;
            const sn = @min(sub_id.len, slot.sub_id_buf.len);
            @memcpy(slot.sub_id_buf[0..sn], sub_id[0..sn]);
            slot.sub_id_len = @intCast(sn);
            const ln = @min(lbl.len, slot.label_buf.len);
            @memcpy(slot.label_buf[0..ln], lbl[0..ln]);
            slot.label_len = @intCast(ln);
            slot.gpa = gpa;
            slot.inbox = inbox;
            return;
        }
    }
}

pub fn unregisterLive(io: Io, inbox: *@import("subagent_feedback.zig").Inbox) void {
    live_mu.lockUncancelable(io);
    defer live_mu.unlock(io);
    for (&live_slots) |*slot| {
        if (slot.inbox == inbox) slot.inbox = null;
    }
}

fn matchesLiveSlot(slot: *const LiveSlot, target: []const u8) bool {
    const trimmed = std.mem.trim(u8, target, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (parseNumericId(trimmed)) |num| {
        if (slot.id == num) return true;
    }
    const sid = slot.subId();
    if (sid.len > 0 and (std.mem.eql(u8, sid, trimmed) or (trimmed.len >= 4 and std.mem.startsWith(u8, sid, trimmed)))) return true;
    const lbl = slot.label();
    if (lbl.len > 0 and std.ascii.eqlIgnoreCase(lbl, trimmed)) return true;
    return false;
}

/// Enqueue feedback on a live subagent matching `sub_id` (`sa-...` or numeric).
pub fn enqueueBySubId(io: Io, target: []const u8, message: []const u8) bool {
    return steerRegistry(&subagent.g_agent_jobs, io, target, message).outcome == .queued;
}

/// Pure registry lookup + feedback enqueue under `registry.mutex`.
pub fn steerRegistry(registry: *subagent.AgentJobs, io: Io, target: []const u8, message: []const u8) SteerResult {
    const trimmed = std.mem.trim(u8, message, " \t\r\n");
    if (trimmed.len == 0) return .{ .outcome = .invalid, .detail = "message must not be blank" };
    if (trimmed.len > @import("subagent_feedback.zig").max_message_bytes) return .{ .outcome = .invalid, .detail = "message exceeds 16 KiB" };
    if (!std.unicode.utf8ValidateSlice(trimmed)) return .{ .outcome = .invalid, .detail = "message must be valid UTF-8" };

    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);

    // Prefer the newest live match first, then fall back to a finished match.
    var finished_match: ?*subagent.AgentJob = null;
    var i: usize = registry.list.items.len;
    while (i > 0) {
        i -= 1;
        const job = registry.list.items[i];
        if (!matchesJob(job, target)) continue;
        if (job.done) {
            if (finished_match == null) finished_match = job;
            continue;
        }
        job.feedback.enqueue(job.ctx.gpa, io, trimmed) catch |err| {
            return .{
                .outcome = if (err == error.AgentFinished) .finished else .invalid,
                .id = job.id,
                .detail = switch (err) {
                    error.AgentFinished => "agent has already finished",
                    error.InboxFull => "agent's feedback queue is full",
                    else => @errorName(err),
                },
            };
        };
        return snapshotJobResult(.queued, job, "queued for next step boundary");
    }
    if (finished_match) |job| {
        return snapshotJobResult(.finished, job, "agent has already finished");
    }
    live_mu.lockUncancelable(io);
    defer live_mu.unlock(io);
    var j: usize = live_slots.len;
    while (j > 0) {
        j -= 1;
        const slot = &live_slots[j];
        const inbox = slot.inbox orelse continue;
        if (!matchesLiveSlot(slot, target)) continue;
        inbox.enqueue(slot.gpa, io, trimmed) catch |err| {
            return .{
                .outcome = if (err == error.AgentFinished) .finished else .invalid,
                .id = slot.id,
                .detail = if (err == error.AgentFinished) "agent has already finished" else @errorName(err),
            };
        };
        var res: SteerResult = .{ .outcome = .queued, .id = slot.id, .detail = "queued for next step boundary" };
        const sid = slot.subId();
        @memcpy(res.sub_id_buf[0..sid.len], sid);
        res.sub_id_len = @intCast(sid.len);
        const lbl = slot.label();
        @memcpy(res.label_buf[0..lbl.len], lbl);
        res.label_len = @intCast(lbl.len);
        return res;
    }
    return .{ .outcome = .not_found, .detail = "no matching background subagent" };
}

fn snapshotJobResult(outcome: SteerOutcome, job: *const subagent.AgentJob, detail: []const u8) SteerResult {
    var res: SteerResult = .{ .outcome = outcome, .id = job.id, .detail = detail };
    const sid = job.feedback.subId();
    const sn = @min(sid.len, res.sub_id_buf.len);
    @memcpy(res.sub_id_buf[0..sn], sid[0..sn]);
    res.sub_id_len = @intCast(sn);
    const ln = @min(job.label.len, res.label_buf.len);
    @memcpy(res.label_buf[0..ln], job.label[0..ln]);
    res.label_len = @intCast(ln);
    return res;
}

/// Handle a composer `@agent-...` line on either REPL (`out != null`) or ACP,
/// returning the formatted one-line receipt.
pub fn handleSteerLine(root: *Agent, arena: Allocator, out: ?*Io.Writer, text: []const u8) ![]const u8 {
    const parsed = parseSteerLine(text) orelse return "[subagent steer: invalid target or empty message]";
    return steerAndFormat(root, arena, out, parsed.target, parsed.message);
}

pub fn steerAndFormat(root: *Agent, arena: Allocator, out: ?*Io.Writer, target: []const u8, message: []const u8) ![]const u8 {
    const res = steerRegistry(&subagent.g_agent_jobs, root.io, target, message);
    const line = switch (res.outcome) {
        .queued => blk: {
            const lbl = if (res.label().len > 0) res.label() else "subagent";
            break :blk try std.fmt.allocPrint(
                arena,
                "Queued feedback for agent #{d} ({s}) · lands at its next step boundary.",
                .{ res.id, lbl },
            );
        },
        .finished => try std.fmt.allocPrint(
            arena,
            "Agent #{d} ({s}) already finished — start a new subagent or resume it for follow-up work.",
            .{ res.id, if (res.label().len > 0) res.label() else "subagent" },
        ),
        .not_found => try std.fmt.allocPrint(
            arena,
            "No live subagent matching '{s}' — /jobs or /workers lists active workers.",
            .{target},
        ),
        .invalid, .resumed => try std.fmt.allocPrint(arena, "Could not steer '{s}': {s}", .{ target, res.detail }),
    };
    if (out) |w| {
        w.print("{s}↳ {s}{s}\n", .{ style.accent, line, style.reset }) catch {};
        w.flush() catch {};
    }
    return line;
}

test "parseSteerLine recognizes @agent-N, @agentN, @sa-..., and ignores normal prompts" {
    const p1 = parseSteerLine("  @agent-2   check build.zig too  ").?;
    try std.testing.expectEqualStrings("2", p1.target);
    try std.testing.expectEqualStrings("check build.zig too", p1.message);

    const p2 = parseSteerLine("@agent12 focus on linux").?;
    try std.testing.expectEqualStrings("12", p2.target);
    try std.testing.expectEqualStrings("focus on linux", p2.message);

    const p3 = parseSteerLine("@sa-001-a1b2c3d4 skip windows").?;
    try std.testing.expectEqualStrings("sa-001-a1b2c3d4", p3.target);
    try std.testing.expectEqualStrings("skip windows", p3.message);

    try std.testing.expect(parseSteerLine("@agent-1") == null);
    try std.testing.expect(parseSteerLine("@agent-1    ") == null);
    try std.testing.expect(parseSteerLine("hello @agent-1") == null);
    try std.testing.expect(parseSteerLine("@someone_else hi") == null);
}

test "steerRegistry queues feedback by numeric id, sub_id, or label, and reports finished/not_found" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var registry: subagent.AgentJobs = .{};
    defer registry.list.deinit(gpa);

    var job: subagent.AgentJob = .{
        .id = 7,
        .label = @constCast("Scout"),
        .prompt = @constCast("inspect auth"),
        .niche = @constCast(""),
        .isolation = .shared_cwd,
        .isolation_fallback = false,
        .ctx = .{ .gpa = gpa, .io = io, .client = undefined, .provider = undefined, .registry = null, .from_sub = false, .approvals = null, .tracer = null },
    };
    defer job.feedback.deinit(gpa);
    job.feedback.setSubId(7, "sa-007-deadbeef");
    try registry.list.append(gpa, &job);

    const r1 = steerRegistry(&registry, io, "7", "check token expiry");
    try std.testing.expectEqual(SteerOutcome.queued, r1.outcome);
    try std.testing.expectEqual(@as(u32, 7), r1.id);
    try std.testing.expectEqualStrings("sa-007-deadbeef", r1.subId());
    try std.testing.expectEqualStrings("Scout", r1.label());

    const r2 = steerRegistry(&registry, io, "sa-007-deadbeef", "also check refresh tokens");
    try std.testing.expectEqual(SteerOutcome.queued, r2.outcome);

    const r3 = steerRegistry(&registry, io, "scout", "and rate limits");
    try std.testing.expectEqual(SteerOutcome.queued, r3.outcome);
    try std.testing.expectEqual(@as(usize, 3), job.feedback.pending.items.len);

    const miss = steerRegistry(&registry, io, "99", "hello");
    try std.testing.expectEqual(SteerOutcome.not_found, miss.outcome);

    job.done = true;
    const done = steerRegistry(&registry, io, "7", "too late");
    try std.testing.expectEqual(SteerOutcome.finished, done.outcome);
}
