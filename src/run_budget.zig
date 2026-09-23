//! Invocation-wide model-call and concurrency budget shared by the root,
//! subagents, workflow retries, judges, compaction, and AI title generation.
//! Every Agent borrows the same instance; atomics make admission safe across
//! the Io pool without serializing network calls behind a mutex.
//!
//! The model-call *count* ceiling defaults to unlimited (`max_model_calls == 0`).
//! It is a process-lifetime counter that never resets, so any finite cap wedges
//! every later turn once a workflow fan-out hits it — and the Workflow layer
//! already carries its own 1000-agent runaway backstop. Depth and concurrency
//! stay bounded: those cap recursion and parallel connections, not whole turns.

const std = @import("std");
const Io = std.Io;
// Only for the mandatory outcome-row flush in exhaustedFatal below — a leaf
// module over shapes/trace/util, so this adds no cycle to the budget path.
const orch_rows = @import("orchestration_rows.zig");

/// Independent aggregate ceiling; the legacy --max-tool-calls remains per-turn.
pub var cli_max_tool_calls: ?u64 = null;

pub const default_max_concurrency: u32 = 8;
pub const default_max_depth: u8 = 1;
/// 0 = unlimited (default). Set a positive --max-model-calls / GRAFF_MAX_MODEL_CALLS
/// only when you deliberately want a hard ceiling on model calls for the whole run.
pub const default_max_model_calls: u64 = 0;

pub const CallKind = enum {
    root,
    child,
    workflow_retry,
    judge,
    title,
    recap,
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
    max_tool_calls: ?u64 = null,
    tool_calls: std.atomic.Value(u64) = .init(0),
    tool_exhausted: std.atomic.Value(bool) = .init(false),
    max_concurrency: u32 = default_max_concurrency,
    max_depth: u8 = default_max_depth,
    model_calls: std.atomic.Value(u64) = .init(0),
    active: std.atomic.Value(u32) = .init(0),
    peak_active: std.atomic.Value(u32) = .init(0),
    waiting: std.atomic.Value(u32) = .init(0),

    pub fn hasFiniteLimits(self: *const RunBudget) bool {
        return self.max_model_calls != 0 or self.max_tool_calls != null;
    }

    /// Every executable tool, including descendant/MCP/RLM dispatch, reserves
    /// before its side effects. Failed calls still consume their reservation.
    pub fn reserveTool(self: *RunBudget) !u64 {
        var current = self.tool_calls.load(.acquire);
        while (true) {
            if (self.max_tool_calls) |limit| if (current >= limit) {
                self.tool_exhausted.store(true, .release);
                return error.ToolBudgetExhausted;
            };
            if (self.tool_calls.cmpxchgWeak(current, current +| 1, .acq_rel, .acquire)) |observed| {
                current = observed;
                continue;
            }
            return current +| 1;
        }
    }

    pub fn toolRemaining(self: *const RunBudget) u64 {
        return if (self.max_tool_calls) |limit| limit -| self.tool_calls.load(.acquire) else std.math.maxInt(u64);
    }

    pub fn toolRefusal(self: *RunBudget, gpa: std.mem.Allocator, tracer: ?*@import("trace.zig").Tracer) ?@import("tools.zig").ToolOutput {
        _ = self.reserveTool() catch {
            const used_calls = self.tool_calls.load(.acquire);
            const limit = self.max_tool_calls orelse 0;
            if (tracer) |tr| tr.write(.{ .ev = "exhausted", .dimension = "tool_calls", .used = used_calls, .limit = limit });
            return .{ .text = std.fmt.allocPrint(gpa, "{{\"event\":\"exhausted\",\"dimension\":\"tool_calls\",\"used\":{d},\"limit\":{d}}}", .{ used_calls, limit }) catch unreachable, .is_error = true };
        };
        return null;
    }

    fn acquireConcurrency(self: *RunBudget, io: Io) !void {
        _ = self.waiting.fetchAdd(1, .acq_rel);
        defer _ = self.waiting.fetchSub(1, .release);
        while (true) {
            if (self.tool_exhausted.load(.acquire)) return error.ToolBudgetExhausted;
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

    fn reserveCall(self: *RunBudget, depth: u8) !u64 {
        // 0 = unlimited: keep counting for used()/telemetry, but never refuse.
        if (self.max_model_calls == 0) return self.model_calls.fetchAdd(1, .acq_rel) + 1;
        const limit = self.max_model_calls - @as(u64, if (depth > 0) 1 else 0);
        var current = self.model_calls.load(.acquire);
        while (current < limit) {
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
        if (self.tool_exhausted.load(.acquire)) return error.ToolBudgetExhausted;
        if (depth > self.max_depth) return error.AgentDepthExceeded;
        // #390 — the landing reserve's hard half: a CHILD may not take the
        // pool's last slot. The final call is the root's landing answer; a
        // worker that consumed it would leave the run to die narrating.
        // This early check avoids waiting after exhaustion. reserveCall checks
        // the same child ceiling atomically after the concurrency wait, so
        // queued siblings cannot take the root's final reservation.
        if (depth > 0 and self.max_model_calls != 0 and self.remaining() <= 1)
            return error.RunBudgetExhausted;
        try self.acquireConcurrency(io);
        errdefer {
            const before = self.active.fetchSub(1, .release);
            std.debug.assert(before > 0);
        }
        const call_number = try self.reserveCall(depth);
        return .{ .budget = self, .call_number = call_number, .kind = kind };
    }

    pub fn used(self: *const RunBudget) u64 {
        return self.model_calls.load(.acquire);
    }

    /// #368: RunBudgetExhausted used to end a -p run with a bare "turn
    /// failed:" line. The model never gets a concluding call at this point,
    /// so the HARNESS owns the last line: what ran out, that the work is
    /// partial and not rolled back, and where the evidence lives.
    ///
    /// It also owns the last ROW. An orchestration decision that ends here is
    /// the single most informative observation the policy can have — the
    /// escalation ladder bought a rung that could not finish — and before this
    /// flush it was the one outcome that never got recorded, because the
    /// process died between the decision and any score. The policy learned
    /// from every run except exactly the failures it exists to prevent.
    pub fn exhaustedFatal(max_model_calls: u64, run_id: []const u8) noreturn {
        orch_rows.flushPending(0, max_model_calls, 0, true, "");
        std.process.fatal("model-call budget exhausted (--max-model-calls {d}) before the task completed. Work done so far is PARTIAL and was NOT rolled back; inspect this run under .graff/traces/{s}.jsonl, then raise --max-model-calls or re-run to continue.", .{ max_model_calls, run_id });
    }

    /// True when at least `calls` more model calls fit under the ceiling.
    /// Advisory (racy against concurrent children) — for skipping OPTIONAL
    /// spending (e.g. a RED repair continuation), never for admission;
    /// acquire() remains the only authority.
    pub fn canAfford(self: *const RunBudget, calls: u64) bool {
        if (self.max_model_calls == 0) return true;
        return self.model_calls.load(.acquire) + calls <= self.max_model_calls;
    }

    pub fn remaining(self: *const RunBudget) u64 {
        if (self.max_model_calls == 0) return std.math.maxInt(u64); // 0 = unlimited
        return self.max_model_calls -| self.used();
    }
};

test "RunBudget enforces depth, call ceiling, and reserves the last call for the root" {
    var budget: RunBudget = .{ .max_model_calls = 3, .max_concurrency = 1, .max_depth = 1 };
    var first = try budget.acquire(std.testing.io, 0, .root);
    try std.testing.expectEqual(@as(u64, 1), first.call_number);
    try std.testing.expectEqual(@as(u32, 1), budget.active.load(.acquire));
    first.release();
    try std.testing.expectEqual(@as(u32, 0), budget.active.load(.acquire));

    var second = try budget.acquire(std.testing.io, 1, .child);
    second.release();
    // #390 — one slot left: a child is refused it, the root's landing takes it.
    try std.testing.expectError(error.RunBudgetExhausted, budget.acquire(std.testing.io, 1, .child));
    var last = try budget.acquire(std.testing.io, 0, .root);
    try std.testing.expectEqual(@as(u64, 3), last.call_number);
    last.release();
    try std.testing.expectError(error.RunBudgetExhausted, budget.acquire(std.testing.io, 0, .root));
    try std.testing.expectError(error.AgentDepthExceeded, budget.acquire(std.testing.io, 2, .child));
    try std.testing.expectEqual(@as(u64, 0), budget.remaining());
    try std.testing.expectEqual(@as(u32, 1), budget.peak_active.load(.acquire));
}

test "RunBudget with max_model_calls = 0 is unlimited and never exhausts" {
    var budget: RunBudget = .{ .max_model_calls = 0, .max_concurrency = 1, .max_depth = 1 };
    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        var permit = try budget.acquire(std.testing.io, 0, .root);
        permit.release();
    }
    try std.testing.expectEqual(@as(u64, 1000), budget.used());
    try std.testing.expectEqual(std.math.maxInt(u64), budget.remaining());
}

test "queued children cannot consume the root landing reservation" {
    const Worker = struct {
        fn run(io: Io, budget: *RunBudget, accepted: *std.atomic.Value(u32)) void {
            var permit = budget.acquire(io, 1, .child) catch return;
            defer permit.release();
            _ = accepted.fetchAdd(1, .acq_rel);
        }
    };
    const io = std.testing.io;
    var budget: RunBudget = .{ .max_model_calls = 3, .max_concurrency = 1 };
    var held = try budget.acquire(io, 0, .root);
    defer held.release();
    var accepted: std.atomic.Value(u32) = .init(0);
    var children: Io.Group = .init;
    defer children.cancel(io);
    try children.concurrent(io, Worker.run, .{ io, &budget, &accepted });
    try children.concurrent(io, Worker.run, .{ io, &budget, &accepted });
    const start = Io.Timestamp.now(io, .awake);
    while (budget.waiting.load(.acquire) != 2) {
        if (start.untilNow(io, .awake).toMilliseconds() > 5000) return error.ChildrenDidNotQueue;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    held.release();
    try children.await(io);
    try std.testing.expectEqual(@as(u32, 1), accepted.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), budget.remaining());
    var landing = try budget.acquire(io, 0, .root);
    landing.release();
    try std.testing.expectEqual(@as(u64, 0), budget.remaining());
    try std.testing.expectEqual(@as(u32, 0), budget.waiting.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), budget.active.load(.acquire));
}

test "aggregate tool ceiling is shared and stops subsequent model admission" {
    var budget: RunBudget = .{ .max_tool_calls = 2 };
    try std.testing.expect(budget.hasFiniteLimits());
    try std.testing.expectEqual(@as(u64, 1), try budget.reserveTool());
    try std.testing.expectEqual(@as(u64, 2), try budget.reserveTool());
    try std.testing.expectError(error.ToolBudgetExhausted, budget.reserveTool());
    try std.testing.expectError(error.ToolBudgetExhausted, budget.acquire(std.testing.io, 0, .root));
    try std.testing.expectError(error.ToolBudgetExhausted, budget.acquire(std.testing.io, 1, .child));
    try std.testing.expectEqual(@as(u64, 0), budget.toolRemaining());
    var zero: RunBudget = .{ .max_tool_calls = 0 };
    try std.testing.expectError(error.ToolBudgetExhausted, zero.reserveTool());
    var unlimited: RunBudget = .{};
    try std.testing.expect(!unlimited.hasFiniteLimits());
    _ = try unlimited.reserveTool();
    try std.testing.expectEqual(std.math.maxInt(u64), unlimited.toolRemaining());
}

test "parallel descendant tool reservations never overshoot" {
    const Worker = struct {
        fn run(budget: *RunBudget) void {
            for (0..100) |_| _ = budget.reserveTool() catch return;
        }
    };
    var budget: RunBudget = .{ .max_tool_calls = 31 };
    var group: Io.Group = .init;
    defer group.cancel(std.testing.io);
    for (0..12) |_| try group.concurrent(std.testing.io, Worker.run, .{&budget});
    try group.await(std.testing.io);
    try std.testing.expectEqual(@as(u64, 31), budget.tool_calls.load(.acquire));
    try std.testing.expect(budget.tool_exhausted.load(.acquire));
}

test "aggregate tool denial prevents actual root and descendant file mutation" {
    const a = std.testing.allocator;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_n = try dir.dir.realPath(std.testing.io, &path_buf);
    var budget: RunBudget = .{ .max_tool_calls = 0 };
    var client: std.http.Client = .{ .allocator = a, .io = std.testing.io };
    defer client.deinit();
    const input = try std.json.parseFromSlice(std.json.Value, a, "{\"path\":\"must-not-exist\",\"content\":\"bad\"}", .{});
    defer input.deinit();
    for ([_]bool{ false, true }) |child| {
        const ctx: @import("tools.zig").ToolCtx = .{
            .gpa = a,
            .io = std.testing.io,
            .client = &client,
            .provider = undefined,
            .registry = null,
            .from_sub = child,
            .approvals = null,
            .tracer = null,
            .run_budget = &budget,
            .agent_cwd = path_buf[0..path_n],
        };
        const output = @import("exec.zig").execTool(ctx, .{ .id = "budget-test", .name = "write_file", .input = input.value });
        defer a.free(output.text);
        try std.testing.expect(output.is_error);
        const event = try std.json.parseFromSlice(std.json.Value, a, output.text, .{});
        defer event.deinit();
        try std.testing.expectEqualStrings("exhausted", event.value.object.get("event").?.string);
        try std.testing.expectEqualStrings("tool_calls", event.value.object.get("dimension").?.string);
        try std.testing.expectEqual(@as(i64, 0), event.value.object.get("limit").?.integer);
    }
    try std.testing.expectError(error.FileNotFound, dir.dir.access(std.testing.io, "must-not-exist", .{}));
}
