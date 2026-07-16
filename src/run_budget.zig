//! Invocation-wide model-call and concurrency budget shared by the root,
//! subagents, workflow retries, judges, compaction, and AI title generation.
//! Every Agent borrows the same instance; atomics make admission safe across
//! the Io pool without serializing network calls behind a mutex.

const std = @import("std");
const Io = std.Io;

pub const default_max_concurrency: u32 = 4;
pub const default_max_depth: u8 = 1;
pub const default_max_model_calls: u64 = 256;

pub const CallKind = enum {
    root,
    child,
    workflow_retry,
    judge,
    title,
    compaction,
};

pub const Permit = struct {
    budget: *RunBudget,
    call_number: u64,
    kind: CallKind,
    released: bool = false,

    pub fn release(self: *Permit) void {
        if (self.released) return;
        self.released = true;
        const before = self.budget.active.fetchSub(1, .release);
        std.debug.assert(before > 0);
    }
};

pub const RunBudget = struct {
    max_model_calls: u64 = default_max_model_calls,
    max_concurrency: u32 = default_max_concurrency,
    max_depth: u8 = default_max_depth,
    model_calls: std.atomic.Value(u64) = .init(0),
    active: std.atomic.Value(u32) = .init(0),
    peak_active: std.atomic.Value(u32) = .init(0),

    fn acquireConcurrency(self: *RunBudget, io: Io) !void {
        while (true) {
            var current = self.active.load(.acquire);
            if (current < self.max_concurrency) {
                if (self.active.cmpxchgWeak(current, current + 1, .acquire, .monotonic)) |observed| {
                    current = observed;
                    continue;
                }
                _ = self.peak_active.fetchMax(current + 1, .monotonic);
                return;
            }
            // Waiting is cancelable: Esc/session shutdown can stop a queued
            // title or child instead of leaving it parked behind the limiter.
            try io.sleep(.fromMilliseconds(10), .awake);
        }
    }

    fn reserveCall(self: *RunBudget) !u64 {
        var current = self.model_calls.load(.acquire);
        while (current < self.max_model_calls) {
            if (self.model_calls.cmpxchgWeak(current, current + 1, .acq_rel, .acquire)) |observed| {
                current = observed;
                continue;
            }
            return current + 1;
        }
        return error.RunBudgetExhausted;
    }

    /// Admit one logical provider request. Transport retries remain inside the
    /// same permit; a workflow retry constructs a new Agent and therefore takes
    /// a new call from the same shared ceiling.
    pub fn acquire(self: *RunBudget, io: Io, depth: u8, kind: CallKind) !Permit {
        if (depth > self.max_depth) return error.AgentDepthExceeded;
        try self.acquireConcurrency(io);
        errdefer {
            const before = self.active.fetchSub(1, .release);
            std.debug.assert(before > 0);
        }
        const call_number = try self.reserveCall();
        return .{ .budget = self, .call_number = call_number, .kind = kind };
    }

    pub fn used(self: *const RunBudget) u64 {
        return self.model_calls.load(.acquire);
    }

    pub fn remaining(self: *const RunBudget) u64 {
        return self.max_model_calls -| self.used();
    }
};

test "RunBudget enforces depth, call ceiling, and releases concurrency" {
    var budget: RunBudget = .{ .max_model_calls = 2, .max_concurrency = 1, .max_depth = 1 };
    var first = try budget.acquire(std.testing.io, 0, .root);
    try std.testing.expectEqual(@as(u64, 1), first.call_number);
    try std.testing.expectEqual(@as(u32, 1), budget.active.load(.acquire));
    first.release();
    try std.testing.expectEqual(@as(u32, 0), budget.active.load(.acquire));

    var second = try budget.acquire(std.testing.io, 1, .child);
    second.release();
    try std.testing.expectError(error.RunBudgetExhausted, budget.acquire(std.testing.io, 0, .root));
    try std.testing.expectError(error.AgentDepthExceeded, budget.acquire(std.testing.io, 2, .child));
    try std.testing.expectEqual(@as(u64, 0), budget.remaining());
    try std.testing.expectEqual(@as(u32, 1), budget.peak_active.load(.acquire));
}
