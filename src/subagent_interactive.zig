//! Interactive parents yield after delegation; children own the work until a
//! completion wake or a new user turn. No cancellation signal is involved.
const std = @import("std");
const tools = @import("tools.zig");
const subagent = @import("subagent.zig");

pub var enabled = std.atomic.Value(bool).init(false);
var requested = std.atomic.Value(bool).init(false);
pub var line_notice = false; // legacy line REPL provenance
pub var yielded = false; // root thread only

pub fn stealIdleLine(io: std.Io, owner: []const u8, gpa: std.mem.Allocator, buf: anytype, idle: bool) !?[]u8 {
    if (!idle or !enabled.load(.acquire) or buf.items.len != 0) return null;
    var notice: [512]u8 = undefined;
    const text = takeWake(io, owner, &notice) orelse return null;
    try buf.appendSlice(gpa, text);
    line_notice = true;
    return buf.items;
}

pub fn configure(on: bool) void {
    enabled.store(on, .release);
    requested.store(false, .release);
    yielded = false;
    line_notice = false;
}

pub fn request(ctx: tools.ToolCtx) void {
    if (ctx.interactive_children and !ctx.from_sub) requested.store(true, .release);
}

pub fn beforeRequest(root: anytype) !?[]const u8 {
    if (root.sub or !enabled.load(.acquire)) return null;
    yielded = requested.swap(false, .acq_rel);
    if (!yielded) return null;
    const text = "Subagents launched; their work continues separately. You can keep using the prompt; completed results will be surfaced automatically.";
    return try root.arena.dupe(u8, text);
}

/// Consume only complete, previously unread jobs owned by this session. Full
/// reports remain in agent_output. A short buffer never consumes a partial id.
pub fn takeWake(io: std.Io, owner: []const u8, buf: []u8) ?[]const u8 {
    const registry = &subagent.g_agent_jobs;
    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);
    var used: usize = 0;
    for (registry.list.items) |job| {
        if (!job.done or job.notified or job.owner == null) continue;
        if (!std.mem.eql(u8, job.owner.?, owner)) continue;
        const line = std.fmt.bufPrint(buf[used..], "{s}[agent {d} {s}] Read its report with agent_output (no wait). Reconcile it with the user's current task; do not restart paused or superseded work.", .{ if (used == 0) "" else "\n", job.id, if (job.is_error) "failed" else "completed" }) catch break;
        used += line.len;
        job.notified = true;
    }
    return if (used == 0) null else buf[0..used];
}

pub fn deliver(root: anytype) void {
    if (root.sub or !enabled.load(.acquire)) return;
    var buf: [512]u8 = undefined;
    const text = takeWake(root.io, root.session_name, &buf) orelse return;
    @import("session_wake.zig").inject(root, text);
}

/// Automatic session-title adoption renames the save file, not its children.
pub fn rename(io: std.Io, old: []const u8, new: []const u8) void {
    const registry = &subagent.g_agent_jobs;
    registry.mutex.lockUncancelable(io);
    defer registry.mutex.unlock(io);
    for (registry.list.items) |job| {
        const owner = job.owner orelse continue;
        if (!std.mem.eql(u8, owner, old)) continue;
        const storage = job.owned orelse continue;
        job.owner = storage.arena.allocator().dupe(u8, new) catch continue;
    }
}

pub fn output(ctx: tools.ToolCtx, id: u32, wait_ms: u64) !tools.ToolOutput {
    if (!ctx.interactive_children or ctx.from_sub) return subagent.agentOutput(ctx.gpa, ctx.io, id, wait_ms);
    const result = try subagent.agentOutput(ctx.gpa, ctx.io, id, 0);
    const registry = &subagent.g_agent_jobs;
    registry.mutex.lockUncancelable(ctx.io);
    defer registry.mutex.unlock(ctx.io);
    if (registry.find(id)) |job| if (!job.done) request(ctx);
    return result;
}
