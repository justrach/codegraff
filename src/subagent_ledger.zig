//! Session ledger for background subagent handles (#753).
//!
//! `g_agent_jobs` is the live pump table: it dies with the process (ACP child
//! respawn, a panic on a bad API envelope, `agentJobsReap` at session end).
//! The model still holds the numeric ids from the interrupted turn. This
//! ledger is the durable record of every id we issued, so `agent_output`
//! can replay a finished report or say the launch ended with the parent
//! turn instead of "it may never have started".

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const tools = @import("tools.zig");
const ToolOutput = tools.ToolOutput;
const AgentUsage = @import("subagent_run.zig").AgentUsage;
const agentStatusText = @import("subagent.zig").agentStatusText;

const Entry = struct {
    id: u32,
    label: []u8,
    done: bool = false,
    is_error: bool = false,
    interrupted: bool = false,
    result: []u8 = &.{},
    usage: AgentUsage = .{},
};

const Ledger = struct {
    mutex: Io.Mutex = .init,
    list: std.ArrayList(*Entry) = .empty,
    next_id: u32 = 1,

    fn find(self: *Ledger, id: u32) ?*Entry {
        for (self.list.items) |e| if (e.id == id) return e;
        return null;
    }
};

var g_ledger: Ledger = .{};

/// One allocator for every ledger row. The table is process-global and
/// `remember` is called with whatever gpa the spawn used (root, a test, a
/// child); mixing those in one ArrayList crashes `reset` in the suite.
fn heap() Allocator {
    return std.heap.page_allocator;
}

fn dup(s: []const u8) []u8 {
    return heap().dupe(u8, s) catch &.{};
}

fn freeOwned(s: []u8) void {
    if (s.len == 0) return;
    heap().free(s);
}

/// Record a freshly issued handle. Best-effort: a failed append still leaves
/// the live job in `g_agent_jobs`.
pub fn remember(gpa: Allocator, io: Io, id: u32, label: []const u8) void {
    _ = gpa;
    g_ledger.mutex.lockUncancelable(io);
    defer g_ledger.mutex.unlock(io);
    if (g_ledger.find(id) != null) {
        if (id >= g_ledger.next_id) g_ledger.next_id = id + 1;
        return;
    }
    const e = heap().create(Entry) catch return;
    e.* = .{ .id = id, .label = dup(label) };
    g_ledger.list.append(heap(), e) catch {
        freeOwned(e.label);
        heap().destroy(e);
        return;
    };
    if (id >= g_ledger.next_id) g_ledger.next_id = id + 1;
}

/// Pump finished: keep the report so a later `agent_output` can replay it
/// after the live table is gone.
pub fn finish(gpa: Allocator, io: Io, id: u32, is_error: bool, result: []const u8, usage: AgentUsage) void {
    _ = gpa;
    g_ledger.mutex.lockUncancelable(io);
    defer g_ledger.mutex.unlock(io);
    const e = g_ledger.find(id) orelse return;
    freeOwned(e.result);
    e.result = dup(result);
    e.is_error = is_error;
    e.usage = usage;
    e.done = true;
    e.interrupted = false;
}

/// Still-running handles cannot be reattached after a process death or a
/// reap. Mark them so `agent_output` names the interruption.
pub fn markRunningInterrupted(io: Io) void {
    g_ledger.mutex.lockUncancelable(io);
    defer g_ledger.mutex.unlock(io);
    for (g_ledger.list.items) |e| {
        if (!e.done) e.interrupted = true;
    }
}

pub fn missingText(gpa: Allocator, id: u32, interrupted: bool, label: []const u8) ![]u8 {
    if (interrupted) {
        if (label.len > 0)
            return std.fmt.allocPrint(gpa, "background agent {d} ({s}) started, then the parent turn was interrupted — it is no longer running in this process. Re-launch with subagent run_in_background:true if the work is still needed.", .{ id, label });
        return std.fmt.allocPrint(gpa, "background agent {d} started, then the parent turn was interrupted — it is no longer running in this process. Re-launch with subagent run_in_background:true if the work is still needed.", .{id});
    }
    return std.fmt.allocPrint(gpa, "no background agent {d} — it may never have started; subagent with run_in_background:true returns the id when it launches", .{id});
}

/// `agent_output` when the live pump table has no row. Replays a finished
/// report from the ledger, or names an interrupted launch, or the original
/// "never started" text when we never issued that id.
pub fn missing(gpa: Allocator, io: Io, id: u32) !ToolOutput {
    g_ledger.mutex.lockUncancelable(io);
    defer g_ledger.mutex.unlock(io);
    const e = g_ledger.find(id) orelse {
        return .{ .text = try missingText(gpa, id, false, ""), .is_error = true };
    };
    if (e.done) {
        const text = try agentStatusText(gpa, id, true, e.is_error, e.usage, e.result);
        return .{ .text = text, .is_error = e.is_error };
    }
    return .{ .text = try missingText(gpa, id, true, e.label), .is_error = true };
}

pub fn writeFields(s: *std.json.Stringify, io: Io) !void {
    g_ledger.mutex.lockUncancelable(io);
    defer g_ledger.mutex.unlock(io);
    try s.objectField("background_agents");
    try s.beginArray();
    for (g_ledger.list.items) |e| {
        try s.beginObject();
        try s.objectField("id");
        try s.write(e.id);
        try s.objectField("label");
        try s.write(e.label);
        try s.objectField("done");
        try s.write(e.done);
        try s.objectField("is_error");
        try s.write(e.is_error);
        try s.objectField("interrupted");
        try s.write(e.interrupted or !e.done);
        try s.objectField("result");
        try s.write(e.result);
        try s.objectField("duration_ms");
        try s.write(e.usage.duration_ms);
        try s.objectField("tool_calls");
        try s.write(e.usage.tool_calls);
        try s.endObject();
    }
    try s.endArray();
}

pub fn mixFingerprint(f: anytype) void {
    f.num(g_ledger.list.items.len);
    f.num(g_ledger.next_id);
    for (g_ledger.list.items) |e| {
        f.num(e.id);
        f.flag(e.done);
        f.flag(e.interrupted);
        f.num(e.result.len);
    }
}

/// Resume: restore reports we can replay, and treat leftover running rows as
/// interrupted (pumps do not survive a new process). Advances `next_id` so
/// a later spawn does not reuse a handle from the saved turn.
pub fn restore(gpa: Allocator, io: Io, v: ?Value) void {
    _ = gpa;
    const arr = if (v) |val| (if (val == .array) val.array else return) else return;
    g_ledger.mutex.lockUncancelable(io);
    defer g_ledger.mutex.unlock(io);
    for (arr.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const id_v = obj.get("id") orelse continue;
        if (id_v != .integer or id_v.integer < 1 or id_v.integer > std.math.maxInt(u32)) continue;
        const id: u32 = @intCast(id_v.integer);
        if (g_ledger.find(id) != null) {
            if (id >= g_ledger.next_id) g_ledger.next_id = id + 1;
            continue;
        }
        const label = if (obj.get("label")) |x| (if (x == .string) x.string else "") else "";
        const result = if (obj.get("result")) |x| (if (x == .string) x.string else "") else "";
        const done = if (obj.get("done")) |x| (x == .bool and x.bool) else false;
        const is_err = if (obj.get("is_error")) |x| (x == .bool and x.bool) else false;
        const interrupted = !done or (if (obj.get("interrupted")) |x| (x == .bool and x.bool) else false);
        const e = heap().create(Entry) catch continue;
        e.* = .{
            .id = id,
            .label = dup(label),
            .done = done,
            .is_error = is_err,
            .interrupted = interrupted,
            .result = dup(result),
            .usage = .{
                .duration_ms = intUsage64(obj, "duration_ms"),
                .tool_calls = intUsage(obj, "tool_calls"),
            },
        };
        g_ledger.list.append(heap(), e) catch {
            freeOwned(e.label);
            freeOwned(e.result);
            heap().destroy(e);
            continue;
        };
        if (id >= g_ledger.next_id) g_ledger.next_id = id + 1;
    }
}

pub fn nextId() u32 {
    return g_ledger.next_id;
}

fn intUsage(obj: std.json.ObjectMap, field: []const u8) u32 {
    const v = obj.get(field) orelse return 0;
    if (v != .integer or v.integer < 0) return 0;
    return @intCast(@min(v.integer, std.math.maxInt(u32)));
}

fn intUsage64(obj: std.json.ObjectMap, field: []const u8) u64 {
    const v = obj.get(field) orelse return 0;
    if (v != .integer or v.integer < 0) return 0;
    return @intCast(v.integer);
}

pub fn reset(gpa: Allocator) void {
    _ = gpa;
    for (g_ledger.list.items) |e| {
        freeOwned(e.label);
        freeOwned(e.result);
        heap().destroy(e);
    }
    g_ledger.list.deinit(heap());
    g_ledger = .{};
}

test "#753: missing names an interrupted launch, not 'never started'" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    reset(gpa);
    defer reset(gpa);

    remember(gpa, io, 3, "review auth");
    const out = try missing(gpa, io, 3);
    defer gpa.free(out.text);
    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "interrupted") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "review auth") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "may never have started") == null);

    const unknown = try missing(gpa, io, 99);
    defer gpa.free(unknown.text);
    try std.testing.expect(std.mem.indexOf(u8, unknown.text, "may never have started") != null);
}

test "#753: a finished ledger row replays the report after the live table is gone" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    reset(gpa);
    defer reset(gpa);

    remember(gpa, io, 1, "scan");
    finish(gpa, io, 1, false, "found three files", .{ .duration_ms = 40, .tool_calls = 2 });
    const out = try missing(gpa, io, 1);
    defer gpa.free(out.text);
    try std.testing.expect(!out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "found three files") != null);
}

test "#753: restore marks leftover running rows interrupted and advances next_id" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    reset(gpa);
    defer reset(gpa);

    const parsed = try std.json.parseFromSlice(Value, gpa,
        \\[{"id":2,"label":"left","done":false,"result":""},{"id":5,"label":"done","done":true,"result":"ok"}]
    , .{});
    defer parsed.deinit();
    restore(gpa, io, parsed.value);

    const running = try missing(gpa, io, 2);
    defer gpa.free(running.text);
    try std.testing.expect(std.mem.indexOf(u8, running.text, "interrupted") != null);

    const done = try missing(gpa, io, 5);
    defer gpa.free(done.text);
    try std.testing.expect(std.mem.indexOf(u8, done.text, "ok") != null);

    try std.testing.expectEqual(@as(u32, 6), g_ledger.next_id);
}

test "missingText: interrupted vs never-started wording" {
    const gpa = std.testing.allocator;
    const gone = try missingText(gpa, 4, true, "audit");
    defer gpa.free(gone);
    try std.testing.expect(std.mem.indexOf(u8, gone, "agent 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, gone, "audit") != null);
    const never = try missingText(gpa, 4, false, "");
    defer gpa.free(never);
    try std.testing.expect(std.mem.indexOf(u8, never, "may never have started") != null);
}
