//! `graff repl` Model — background chat-turn lifecycle: spawn the model call
//! on a worker thread, collect its result, and steering-queue plumbing
//! (queue a line while a turn streams, drain it as the next turn, or
//! force-interrupt with an empty Enter). Split out of the Model struct in
//! repl.zig (#123, 600-line goal); reached through repl.zig's member
//! aliases, so both `self.startJob()` and `Model.startJob(...)` resolve
//! here unchanged.

const std = @import("std");

const repl = @import("repl.zig");
const Model = repl.Model;
const Job = repl.Job;
const jobRun = repl.jobRun;
const Turn = repl.Turn;
const Effect = repl.Effect;
const renderMarkdown = repl.renderMarkdown;

/// Snapshot the conversation, push the `thinking…` placeholder, and spawn
/// the model call on a background thread (so the spinner can animate).
pub fn startJob(self: *Model) void {
    var turns = std.array_list.Managed(Turn).init(self.alloc);
    for (self.history.items) |e| {
        const role: ?Turn.Role = switch (e.kind) {
            .input => .user,
            .assistant => .assistant,
            else => null,
        };
        if (role) |r| {
            const t = self.alloc.dupe(u8, e.text) catch continue;
            turns.append(.{ .role = r, .text = t }) catch {
                self.alloc.free(t);
                continue;
            };
        }
    }
    const job = self.alloc.create(Job) catch {
        for (turns.items) |t| self.alloc.free(t.text);
        turns.deinit();
        self.push(.err, "out of memory") catch {};
        return;
    };
    job.* = .{
        .gpa = self.alloc,
        .history = turns.toOwnedSlice() catch &.{},
        .params = .{
            .effort = self.effort,
            .fast = self.fast,
            .thinking = self.thinking_show,
            .ultracode = self.ultracode or self.effort == .ultra,
            .goal = self.goal orelse "",
        },
        .stream = .{ .buf = self.alloc.alloc(u8, 256 * 1024) catch &.{} },
    };
    self.push(.pending, "") catch {};
    self.pending = job;
    if (std.Thread.spawn(.{}, jobRun, .{job})) |th| {
        job.thread = th;
    } else |_| {
        job.threaded = false;
        jobRun(job); // no threads → run synchronously (spinner just won't animate)
    }
}

/// Collect a finished job: drop the placeholder, append the reply, free.
pub fn finishJob(self: *Model) void {
    const job = self.pending orelse return;
    if (!job.done.load(.acquire)) return;
    if (job.threaded) job.thread.join();
    if (repl.g_debug) {
        if (job.stream.snapshot(self.alloc)) |raw| {
            std.debug.print("\n[repl-debug] raw agent stream ({d} bytes):\n{s}\n", .{ raw.len, raw });
            self.alloc.free(raw);
        }
        std.debug.print("[repl-debug] final reply:\n{s}\n[repl-debug] ----- end turn -----\n", .{job.result orelse "(model call failed)"});
    }

    const n = self.history.items.len;
    if (n > 0 and self.history.items[n - 1].kind == .pending) {
        self.alloc.free(self.history.items[n - 1].text);
        self.history.shrinkRetainingCapacity(n - 1);
    }
    if (job.result) |r| {
        self.chars_out += r.len;
        if (renderMarkdown(self.alloc, r, self.last_term_width)) |rendered| {
            self.alloc.free(r);
            self.pushOwned(.assistant, rendered) catch self.alloc.free(rendered);
        } else |_| {
            self.pushOwned(.assistant, r) catch self.alloc.free(r);
        }
    } else if (self.cancel_requested) {
        // Force-steer interrupted this turn (runTurn → error.Interrupted →
        // replTurnCb returns null); not an error.
        self.push(.info, "⏹ interrupted") catch {};
    } else {
        self.push(.err, "model call failed — check /model and your API key") catch {};
    }
    for (job.history) |t| self.alloc.free(t.text);
    self.alloc.free(job.history);
    if (job.stream.buf.len > 0) self.alloc.free(job.stream.buf);
    self.alloc.destroy(job);
    self.pending = null;
    self.cancel_requested = false;
    self.scroll = 0; // reply landed → jump to the latest
}

/// Pop the next queued steer line (FIFO) and run it as the next turn.
/// Returns the applyLine Effect so a steered "/quit" still propagates.
pub fn drainSteer(self: *Model) Effect {
    if (self.steer_queue.items.len == 0) return .stay;
    const text = self.steer_queue.orderedRemove(0);
    defer self.alloc.free(text);
    return self.applyLine(text);
}

/// Handle Enter while a turn streams. A typed line is queued as a steer
/// (runs as a follow-up turn after the current one finishes); an empty line
/// with a non-empty queue FORCES — flags the turn for interrupt and signals
/// the harness via the cancel callback so the queue drains immediately.
pub fn steerEnter(self: *Model) void {
    const v = std.mem.trim(u8, self.input.getValue(), " \t\r\n");
    if (v.len > 0) {
        if (self.alloc.dupe(u8, v)) |dup| {
            self.steer_queue.append(dup) catch self.alloc.free(dup);
            self.input.setValue("") catch {};
            self.pushFmt(.info, "↳ steer › queued ({d} waiting)", .{self.steer_queue.items.len}) catch {};
        } else |_| {}
    } else if (self.steer_queue.items.len > 0) {
        self.cancel_requested = true;
        if (repl.g_cancel_fn) |f| f(repl.g_turn_ctx);
        self.push(.info, "↳ force › interrupting…") catch {};
    }
}
