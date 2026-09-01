//! The typed engine-event channel the TUI consumes (#551, the #422 epic).
//!
//! Before this file the TUI learned what the engine did by SCANNING the sink's
//! own rendered bytes: turn.zig matched "⚙ /✓ /✗ /⊘ " line prefixes out of the
//! live stream and scrollback.zig re-derived the tool's name, status, argument
//! and preview by splitting that line on the glyph, ' ' and ' | '. Both were
//! guesses about formatting rather than knowledge about the run, and both were
//! wrong in the obvious ways: an assistant answer whose line began "✓ " became
//! a phantom tool row, and a command containing " | " was mis-titled.
//!
//! Now the engine hands over typed events and this queue carries them across
//! the turn thread. Growth rule: a new engine moment becomes a new variant with
//! the FIELDS a frontend needs, never a pre-rendered string that a reader has
//! to take apart again.
//!
//! The package stays frontend-agnostic (it never imports the harness), so this
//! is a projection of src/engine_events.zig, not that union itself; the
//! translation lives in src/tui_sink.zig, which is the only place that knows
//! both vocabularies.

const std = @import("std");

/// One tool moment, as a row can render it without parsing anything.
pub const Tool = struct {
    /// The engine's tool name, verbatim ("bash", "read_file",
    /// "mcp__codedbpro__read"). Classification reads THIS, never a rendered
    /// line: `isMcp` is a prefix test on the name, and a bash command that
    /// happens to mention "search" is not a search.
    name: []const u8,
    /// A one-line argument preview (on a call) or result preview (on an
    /// outcome). Already first-lined and capped by the emitter.
    detail: []const u8 = "",
    is_error: bool = false,
    /// The harness refused the call before it ran (tool_rejected).
    denied: bool = false,
    /// Wall-clock ms the engine measured (tool_finished). 0 while running.
    ms: u64 = 0,
};

/// What the cost meter can say. Three of the four are STATES, not numbers, so
/// a pre-formatted string would have had to invent figures for them.
pub const Cost = union(enum) {
    /// --no-cost: the segment does not exist.
    hidden,
    /// Flat-rate provider: spend is not per-turn.
    subscription,
    /// No price-table row for this model.
    unpriced,
    usd: f64,
};

/// The engine's view of the session after a turn (engine_events.PromptStatus).
/// The TUI used to answer /context and /session-info from characters it had
/// counted itself, which measured the transcript rather than the request and
/// went further wrong every time the engine compacted or a tool result landed.
pub const Status = struct {
    model: []const u8,
    provider_id: []const u8 = "",
    /// Context figures are meaningful only once a response has reported usage.
    has_context: bool = false,
    tokens: u64 = 0,
    window: u64 = 0,
    compact_at: u64 = 0,
    cache_read: u64 = 0,
    cost: Cost = .hidden,
    fast: bool = false,
    fallback: bool = false,
    plan: bool = false,
    strict: bool = false,
    ultracode: bool = false,

    /// Percent of the window in use, 0 when nothing has been measured.
    pub fn percent(self: Status) u64 {
        if (!self.has_context or self.window == 0) return 0;
        return @min((self.tokens *| 100) / self.window, 100);
    }

    /// Last-turn prompt-cache hit: cached tokens over the prompt that
    /// produced them. Null until a turn has reported a context size.
    pub fn cachePercent(self: Status) ?u64 {
        if (!self.has_context or self.tokens == 0) return null;
        return @min((self.cache_read *| 100) / self.tokens, 100);
    }
};

/// What a mid-turn failover landed on. The provider travels with the model for
/// the same reason it travels with `Picked`: the picker's current-row marker
/// compares BOTH, so a name alone cannot tell two same-named seats apart.
pub const ModelChanged = struct { model: []const u8, provider: []const u8 = "" };

pub const Event = union(enum) {
    /// A tool call cleared the gates and is running (ToolInvocation).
    tool_started: Tool,
    /// It returned (ToolOutcome). `is_error` is the engine's verdict.
    tool_finished: Tool,
    /// The harness refused it before it ran (ToolRejection) — a moment the
    /// TUI had no way to see at all before this file existed.
    tool_rejected: Tool,
    /// One operational line about the session (session_notice) -> system row.
    notice: []const u8,
    /// The active provider failed over mid-turn (provider_fallback).
    model_changed: ModelChanged,
    /// The engine's own context/cost meters (prompt_ready). The TUI renders
    /// /context, /session-info and the footer from THIS, instead of counting
    /// characters and calling the result a context meter.
    status: Status,
};

/// Lock-guarded SPSC-shaped hand-off: the turn thread (and the parallel tool
/// pool behind it) pushes, the render loop drains at its existing poll points.
///
/// Allocation discipline: engine payloads point into the per-turn arena that
/// dies with the turn, so `push` COPIES every string into this queue's own
/// gpa and `drain` hands that ownership to the caller. The queue is bounded —
/// a turn that outruns the render loop drops events and counts them rather
/// than growing without limit.
pub const Queue = struct {
    /// Bounded so a runaway turn cannot grow the queue without limit. ~4k
    /// events is far more tool activity than one turn produces.
    pub const cap: usize = 4096;

    /// Spin lock rather than a mutex: this zig's std has no io-less Thread
    /// mutex, and the TUI package deliberately never takes an Io handle. The
    /// critical sections are a dupe and an append — microseconds, never a
    /// syscall — so it stays uncontended (the same choice repl_glue's
    /// steerLock made for its queue).
    lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set by the owner (turn.zig) before the turn thread starts. A queue that
    /// was never attached drops silently — which is exactly what a Job literal
    /// in a test that does not care about events wants.
    gpa: ?std.mem.Allocator = null,
    items: std.ArrayList(Event) = .empty,
    /// Events refused because the queue was full or a copy failed. Surfaced
    /// rather than swallowed: silent loss here is how a tool row goes missing.
    dropped: usize = 0,

    fn acquire(self: *Queue) void {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn release(self: *Queue) void {
        self.lock.store(false, .release);
    }

    pub fn attach(self: *Queue, gpa: std.mem.Allocator) void {
        self.acquire();
        defer self.release();
        self.gpa = gpa;
    }

    pub fn push(self: *Queue, ev: Event) void {
        self.acquire();
        defer self.release();
        const gpa = self.gpa orelse return;
        if (self.items.items.len >= cap) {
            self.dropped += 1;
            return;
        }
        const owned = dupeEvent(gpa, ev) orelse {
            self.dropped += 1;
            return;
        };
        self.items.append(gpa, owned) catch {
            freeEvent(gpa, owned);
            self.dropped += 1;
        };
    }

    /// Everything queued so far. The caller owns the slice AND every string in
    /// it until it calls `free`.
    pub fn drain(self: *Queue) []Event {
        self.acquire();
        defer self.release();
        const gpa = self.gpa orelse return &.{};
        return self.items.toOwnedSlice(gpa) catch &.{};
    }

    pub fn free(self: *Queue, evs: []Event) void {
        const gpa = self.gpa orelse return;
        for (evs) |e| freeEvent(gpa, e);
        gpa.free(evs);
    }

    pub fn deinit(self: *Queue) void {
        self.acquire();
        defer self.release();
        const gpa = self.gpa orelse return;
        for (self.items.items) |e| freeEvent(gpa, e);
        self.items.deinit(gpa);
        self.items = .empty;
    }
};

fn dupeEvent(gpa: std.mem.Allocator, ev: Event) ?Event {
    return switch (ev) {
        .tool_started => |t| .{ .tool_started = dupeTool(gpa, t) orelse return null },
        .tool_finished => |t| .{ .tool_finished = dupeTool(gpa, t) orelse return null },
        .tool_rejected => |t| .{ .tool_rejected = dupeTool(gpa, t) orelse return null },
        .notice => |s| .{ .notice = gpa.dupe(u8, s) catch return null },
        // Only the model name is copied: a provider id is a static spec literal
        // (see app.Model.adoptModel), so it outlives the drain on its own.
        .model_changed => |m| .{ .model_changed = .{ .model = gpa.dupe(u8, m.model) catch return null, .provider = m.provider } },
        .status => |st| .{ .status = dupeStatus(gpa, st) orelse return null },
    };
}

fn dupeStatus(gpa: std.mem.Allocator, st: Status) ?Status {
    var out = st;
    out.model = gpa.dupe(u8, st.model) catch return null;
    out.provider_id = gpa.dupe(u8, st.provider_id) catch {
        gpa.free(out.model);
        return null;
    };
    return out;
}

fn freeEvent(gpa: std.mem.Allocator, ev: Event) void {
    switch (ev) {
        .tool_started, .tool_finished, .tool_rejected => |t| {
            gpa.free(t.name);
            gpa.free(t.detail);
        },
        .notice => |s| gpa.free(s),
        .model_changed => |m| gpa.free(m.model),
        .status => |st| {
            gpa.free(st.model);
            gpa.free(st.provider_id);
        },
    }
}

fn dupeTool(gpa: std.mem.Allocator, t: Tool) ?Tool {
    const name = gpa.dupe(u8, t.name) catch return null;
    const detail = gpa.dupe(u8, t.detail) catch {
        gpa.free(name);
        return null;
    };
    return .{ .name = name, .detail = detail, .is_error = t.is_error, .denied = t.denied, .ms = t.ms };
}

test "queue copies payloads, so an arena that dies with the turn cannot dangle" {
    var q: Queue = .{};
    q.attach(std.testing.allocator);
    defer q.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    const arena = arena_state.allocator();
    const name = try arena.dupe(u8, "mcp__codedbpro__read");
    const detail = try arena.dupe(u8, "src/main.zig");
    q.push(.{ .tool_started = .{ .name = name, .detail = detail } });
    // The engine's arena is gone; the queued copy must still be readable.
    arena_state.deinit();

    const evs = q.drain();
    defer q.free(evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqualStrings("mcp__codedbpro__read", evs[0].tool_started.name);
    try std.testing.expectEqualStrings("src/main.zig", evs[0].tool_started.detail);
}

test "drain empties the queue and hands ownership over exactly once" {
    var q: Queue = .{};
    q.attach(std.testing.allocator);
    defer q.deinit();
    q.push(.{ .tool_started = .{ .name = "bash", .detail = "ls" } });
    q.push(.{ .tool_finished = .{ .name = "bash", .detail = "ok", .is_error = false } });
    const first = q.drain();
    try std.testing.expectEqual(@as(usize, 2), first.len);
    q.free(first);
    const second = q.drain();
    defer q.free(second);
    try std.testing.expectEqual(@as(usize, 0), second.len);
}

test "an unattached queue drops instead of crashing, and never hands out memory" {
    var q: Queue = .{};
    q.push(.{ .notice = "loaded 2 saved approval(s)" });
    const evs = q.drain();
    defer q.free(evs);
    try std.testing.expectEqual(@as(usize, 0), evs.len);
}

test "the queue is bounded: past cap it drops and counts instead of growing" {
    var q: Queue = .{};
    q.attach(std.testing.allocator);
    defer q.deinit();
    var i: usize = 0;
    while (i < Queue.cap + 8) : (i += 1) q.push(.{ .notice = "x" });
    try std.testing.expectEqual(Queue.cap, q.items.items.len);
    try std.testing.expectEqual(@as(usize, 8), q.dropped);
}

test "pushes from another thread arrive intact" {
    var q: Queue = .{};
    q.attach(std.testing.allocator);
    defer q.deinit();
    const Writer = struct {
        fn f(target: *Queue) void {
            var i: usize = 0;
            while (i < 200) : (i += 1) target.push(.{ .tool_finished = .{ .name = "bash", .detail = "done" } });
        }
    };
    const th = try std.Thread.spawn(.{}, Writer.f, .{&q});
    th.join();
    const evs = q.drain();
    defer q.free(evs);
    try std.testing.expectEqual(@as(usize, 200), evs.len);
    for (evs) |e| try std.testing.expectEqualStrings("bash", e.tool_finished.name);
}
