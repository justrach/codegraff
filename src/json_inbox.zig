//! Single owner for `--json` stdin. The reader runs while a model turn is
//! blocked so `cancel` can trip Agent.esc_cancel without racing ask/gate replies.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Agent = @import("agent.zig").Agent;
const cancel_source = @import("cancel_source.zig"); // #728

const cancelled_answer = "{\"type\":\"answer\",\"cancelled\":true}";

var inbox_io: ?Io = null;
var inbox_gpa: ?Allocator = null;
var inbox_reader: ?*Io.Reader = null;
var mutex: Io.Mutex = .init;
var ready: Io.Condition = .init;
var lines: std.ArrayList([]u8) = .empty;
var eof = false;
var cancel_epoch: u64 = 0;
var turn_active: std.atomic.Value(bool) = .init(false);
var turn_pending: std.atomic.Value(bool) = .init(false);
var pending_cancelled = false;
var queued_cancel = false;
var reply_cancel_epoch: u64 = 0;
var future: ?Io.Future(void) = null;

pub fn start(gpa: Allocator, io: Io, reader: *Io.Reader) void {
    std.debug.assert(inbox_io == null);
    inbox_io = io;
    inbox_gpa = gpa;
    inbox_reader = reader;
    eof = false;
    cancel_epoch = 0;
    reply_cancel_epoch = 0;
    pending_cancelled = false;
    queued_cancel = false;
    turn_active.store(false, .release);
    turn_pending.store(false, .release);
    future = io.async(readerTask, .{});
}

pub fn stop() void {
    const io = inbox_io orelse return;
    if (future) |*f| f.cancel(io);
    future = null;
    mutex.lockUncancelable(io);
    const gpa = inbox_gpa.?;
    for (lines.items) |line| gpa.free(line);
    lines.deinit(gpa);
    lines = .empty;
    inbox_reader = null;
    inbox_gpa = null;
    inbox_io = null;
    mutex.unlock(io);
}

/// Promote the dequeued request to active without a gap where cancel can be
/// cleared by fresh-turn setup. Returns false when the pending turn was cancelled.
pub fn beginTurn(root: *Agent) bool {
    const io = inbox_io orelse {
        Agent.prepareRootTurn();
        return true;
    };
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    turn_pending.store(false, .release);
    if (pending_cancelled) {
        pending_cancelled = false;
        Agent.esc_cancel.store(false, .release);
        root.emit(.{ .type = "error", .message = "turn cancelled" });
        return false;
    }
    Agent.prepareRootTurn();
    turn_active.store(true, .release);
    return true;
}

pub fn endTurn() void {
    turn_active.store(false, .release);
}

/// Mainloop request read. In non-JSON modes the original reader remains owner.
pub fn request(arena: Allocator, fallback: *Io.Reader) !?[]const u8 {
    return read(arena, fallback, false);
}

/// Mid-turn ask/gate read. A cancel wakes it with a synthetic cancelled answer,
/// allowing the tool future to join before runTurn observes esc_cancel.
pub fn reply(arena: Allocator, fallback: *Io.Reader) !?[]const u8 {
    return read(arena, fallback, true);
}

fn read(arena: Allocator, fallback: *Io.Reader, is_reply: bool) !?[]const u8 {
    const io = inbox_io orelse return fallback.takeDelimiter('\n');
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    while (lines.items.len == 0 and !eof and !(is_reply and cancel_epoch > reply_cancel_epoch))
        ready.waitUncancelable(io, &mutex);
    if (is_reply and cancel_epoch > reply_cancel_epoch) {
        reply_cancel_epoch = cancel_epoch;
        return try arena.dupe(u8, cancelled_answer);
    }
    if (lines.items.len == 0) return null;
    const owned = lines.orderedRemove(0);
    defer inbox_gpa.?.free(owned);
    if (!is_reply and isTurn(inbox_gpa.?, owned)) {
        turn_pending.store(true, .release);
        if (queued_cancel) {
            queued_cancel = false;
            pending_cancelled = true;
        }
    }
    return try arena.dupe(u8, owned);
}

fn readerTask() void {
    const io = inbox_io.?;
    const gpa = inbox_gpa.?;
    const reader = inbox_reader.?;
    while (true) {
        const raw = reader.takeDelimiter('\n') catch break;
        const line = raw orelse break;
        if (isCancel(gpa, line)) {
            mutex.lockUncancelable(io);
            const active = turn_active.load(.acquire);
            const pending = turn_pending.load(.acquire);
            var queued_turn = false;
            for (lines.items) |queued| queued_turn = queued_turn or isTurn(gpa, queued);
            if (active) {
                cancel_source.cancel(.json_cancel);
                cancel_epoch +%= 1;
            } else if (pending) {
                pending_cancelled = true;
            } else if (queued_turn) {
                queued_cancel = true;
            }
            if (active or pending or queued_turn) ready.broadcast(io);
            mutex.unlock(io);
            continue;
        }
        const copy = gpa.dupe(u8, line) catch break;
        mutex.lockUncancelable(io);
        lines.append(gpa, copy) catch {
            mutex.unlock(io);
            gpa.free(copy);
            break;
        };
        ready.broadcast(io);
        mutex.unlock(io);
    }
    mutex.lockUncancelable(io);
    eof = true;
    ready.broadcast(io);
    mutex.unlock(io);
}

fn isCancel(gpa: Allocator, line: []const u8) bool {
    return isRequestType(gpa, line, "cancel", false);
}

fn isTurn(gpa: Allocator, line: []const u8) bool {
    return isRequestType(gpa, line, "user", true) or isRequestType(gpa, line, "review", true);
}

fn isRequestType(gpa: Allocator, line: []const u8, expected: []const u8, require_text: bool) bool {
    const parsed = std.json.parseFromSlice(Value, gpa, std.mem.trim(u8, line, " \t\r"), .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const ty = parsed.value.object.get("type") orelse return false;
    if (ty != .string or !std.mem.eql(u8, ty.string, expected)) return false;
    if (!require_text) return true;
    const text = parsed.value.object.get("text") orelse return false;
    return text == .string and std.mem.trim(u8, text.string, " \t\r").len > 0;
}

test "cancel classification is exact" {
    try std.testing.expect(isCancel(std.testing.allocator, "{\"type\":\"cancel\"}"));
    try std.testing.expect(!isCancel(std.testing.allocator, "{\"type\":\"user\",\"text\":\"cancel\"}"));
    try std.testing.expect(!isCancel(std.testing.allocator, "not json"));
}
