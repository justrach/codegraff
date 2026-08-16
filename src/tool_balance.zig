//! Session-wide tool-CLASS tally: how the model's reads/searches actually
//! split across the licensed codedb-pro tools, zigrep, and the native
//! fallbacks — plus how often the licensed gate had to refuse a native call.
//! The per-turn ToolSink (trace.zig) already logs names for the trajectory,
//! but nothing aggregated by class, so "the model hammered faster_search 40
//! times and never opened a file outline" was invisible. This is the
//! aggregate: /tools renders it, and the skew line names a dominant class.
//!
//! Counting hooks: exec.zig's central post-call point (every tool call) and
//! codedbpro_report.nativeRefusal (gate refusals, which never reach a call).
//! Counters are plain u64s touched through @atomicRmw/@atomicLoad — tool
//! calls run on pool threads, and a mutex here would invite cancellation
//! deadlock for a three-instruction critical section.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tools = @import("tools.zig");

pub const Class = enum {
    pro_read, // mcp__codedbpro__read
    pro_search, // faster_search / meta_search
    pro_batch, // batch
    pro_other, // any other mcp__codedbpro__*
    zigrep, // leading `zigrep` via bash
    native_search, // leading grep/rg/find via bash — only runs unlicensed or post-fallback
    native_read, // read_file / codedb — same
    other,

    fn label(self: Class) []const u8 {
        return switch (self) {
            .pro_read => "read",
            .pro_search => "search",
            .pro_batch => "batch",
            .pro_other => "other",
            .zigrep => "zigrep",
            .native_search => "grep/rg/find",
            .native_read => "read_file/codedb",
            .other => "other",
        };
    }
};

const class_count = @as(usize, @intFromEnum(Class.other)) + 1; // `other` must stay LAST (std.meta.fields is deprecated in this std)
var g_counts: [class_count]u64 = @splat(0);
var g_refused: u64 = 0;
var g_errors: u64 = 0;

fn bump(counter: *u64) void {
    _ = @atomicRmw(u64, counter, .Add, 1, .monotonic);
}

fn load(counter: *const u64) u64 {
    return @atomicLoad(u64, counter, .monotonic);
}

fn firstToken(cmd: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, cmd, " \t");
    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    return trimmed[0..end];
}

/// The class one tool call belongs to. Bash is inspected by LEADING command
/// only — a piped `| grep` filters output and stays `other`.
pub fn classOf(call: tools.ToolCall) Class {
    const name = call.name;
    if (std.mem.eql(u8, name, "read_file") or std.mem.eql(u8, name, "codedb")) return .native_read;
    if (std.mem.eql(u8, name, "bash")) {
        const cmd = tools.strField(call.input, "command") orelse return .other;
        const first = firstToken(cmd);
        if (std.mem.eql(u8, first, "zigrep")) return .zigrep;
        if (std.mem.eql(u8, first, "grep") or std.mem.eql(u8, first, "rg") or std.mem.eql(u8, first, "find")) return .native_search;
        return .other;
    }
    if (std.mem.eql(u8, name, "mcp__codedbpro__read")) return .pro_read;
    if (std.mem.eql(u8, name, "mcp__codedbpro__faster_search") or std.mem.eql(u8, name, "mcp__codedbpro__meta_search")) return .pro_search;
    if (std.mem.eql(u8, name, "mcp__codedbpro__batch")) return .pro_batch;
    if (std.mem.startsWith(u8, name, "mcp__codedbpro__")) return .pro_other;
    return .other;
}

/// Edge-trigger state for the steering nudge: 0 = none/balanced, else the
/// dominant Class + 1 already nudged this session. The nudge fires once per
/// dominant class — a model that keeps hammering after being told gets no
/// repeats, and a shift to a DIFFERENT dominant class re-arms it.
var g_last_skew: std.atomic.Value(u8) = .init(0);

fn isSuite(class: Class) bool {
    return switch (class) {
        .pro_read, .pro_search, .pro_batch, .pro_other, .zigrep => true,
        else => false,
    };
}

/// The dominant suite class when usage is skewed (8+ suite calls, one class
/// at 80%+), null when balanced or too thin to judge. Alloc-free; record()
/// only formats a message when this edge-triggers.
pub fn skewClass(snap: *const Snapshot) ?Class {
    const total = snap.suiteTotal();
    if (total < 8) return null;
    const classes = [_]Class{ .pro_read, .pro_search, .pro_batch, .zigrep };
    var top: Class = .pro_read;
    for (classes) |c| if (snap.get(c) > snap.get(top)) {
        top = c;
    };
    if (snap.get(top) * 5 < total * 4) return null;
    return top;
}

/// exec.zig's post-call hook. Errors counted apart: a failing dominant tool
/// is a different story than a preferred one. Returns a gpa-owned steering
/// nudge when suite usage NEWLY skews (the caller appends it to the tool
/// result so the model hears it, not just /tools) — null otherwise.
pub fn record(gpa: Allocator, call: tools.ToolCall, is_error: bool) ?[]u8 {
    const class = classOf(call);
    bump(&g_counts[@intFromEnum(class)]);
    if (is_error) bump(&g_errors);
    if (!isSuite(class)) return null;
    var snap = snapshot();
    const top = skewClass(&snap) orelse {
        g_last_skew.store(0, .release);
        return null;
    };
    const marker: u8 = @intCast(@intFromEnum(top) + 1);
    if (g_last_skew.swap(marker, .acq_rel) == marker) return null;
    return std.fmt.allocPrint(gpa, "tool balance: {d}/{d} suite calls were {s} — read (outline-first), search and batch are all available; balance them", .{ snap.get(top), snap.suiteTotal(), top.label() }) catch null;
}

/// codedbpro_report.nativeRefusal's hook: a native call the licensed gate
/// turned away. High counts are the gate working, not a failure — but they
/// also say the model needed steering.
pub fn recordRefusal() void {
    bump(&g_refused);
}

pub const Snapshot = struct {
    counts: [class_count]u64 = @splat(0),
    refused: u64 = 0,
    errors: u64 = 0,

    pub fn get(self: *const Snapshot, class: Class) u64 {
        return self.counts[@intFromEnum(class)];
    }

    /// Every read/search the licensed suite owns: pro tools plus zigrep.
    pub fn suiteTotal(self: *const Snapshot) u64 {
        return self.get(.pro_read) + self.get(.pro_search) + self.get(.pro_batch) + self.get(.pro_other) + self.get(.zigrep);
    }
};

pub fn snapshot() Snapshot {
    var snap: Snapshot = .{};
    inline for (0..class_count) |i| snap.counts[i] = load(&g_counts[i]);
    snap.refused = load(&g_refused);
    snap.errors = load(&g_errors);
    return snap;
}

/// Test seam: a fresh tally.
pub fn reset() void {
    inline for (0..class_count) |i| @atomicStore(u64, &g_counts[i], 0, .monotonic);
    @atomicStore(u64, &g_refused, 0, .monotonic);
    @atomicStore(u64, &g_errors, 0, .monotonic);
    g_last_skew.store(0, .monotonic);
}

/// The "not overleveraging just one" check for /tools: same rule record()
/// edge-triggers on, formatted for the report. null when balanced or thin.
pub fn skewWarning(alloc: Allocator, snap: *const Snapshot) ?[]const u8 {
    const top = skewClass(snap) orelse return null;
    return std.fmt.allocPrint(alloc, "skew: {d}/{d} suite calls were {s} — read (outline-first), search and batch are all available; balance them", .{ snap.get(top), snap.suiteTotal(), top.label() }) catch null;
}

/// The /tools body. `licensed`/`fallback_open` come from codedbpro_report's
/// gate state so the reader can tell "natives unused because blocked" from
/// "natives unused because chosen".
pub fn render(alloc: Allocator, snap: *const Snapshot, licensed: bool, fallback_open: bool) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    try w.writeAll("tool balance this session:\n");
    try w.print("  codedb-pro:  read {d} · search {d} · batch {d} · other {d}\n", .{ snap.get(.pro_read), snap.get(.pro_search), snap.get(.pro_batch), snap.get(.pro_other) });
    try w.print("  zigrep:      {d}\n", .{snap.get(.zigrep)});
    try w.print("  native:      read_file/codedb {d} · grep/rg/find {d}\n", .{ snap.get(.native_read), snap.get(.native_search) });
    if (licensed) try w.print("  gate:        {d} blocked native attempt(s) · fallback {s}\n", .{ snap.refused, if (fallback_open) "OPEN (a codedb-pro call failed)" else "closed" });
    if (snap.errors > 0) try w.print("  errors:      {d} failed tool call(s)\n", .{snap.errors});
    if (skewWarning(alloc, snap)) |warn| try w.print("  {s}\n", .{warn});
    return alloc.dupe(u8, w.buffered());
}

test "classOf sorts pro tools, zigrep, shell search and natives" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const bash = struct {
        fn call(alloc: Allocator, cmd: []const u8) tools.ToolCall {
            const src = std.fmt.allocPrint(alloc, "{{\"command\":\"{s}\"}}", .{cmd}) catch unreachable;
            const v = std.json.parseFromSliceLeaky(std.json.Value, alloc, src, .{}) catch unreachable;
            return .{ .id = "t", .name = "bash", .input = v };
        }
    };
    try std.testing.expectEqual(Class.pro_read, classOf(.{ .id = "t", .name = "mcp__codedbpro__read", .input = .null }));
    try std.testing.expectEqual(Class.pro_search, classOf(.{ .id = "t", .name = "mcp__codedbpro__meta_search", .input = .null }));
    try std.testing.expectEqual(Class.pro_batch, classOf(.{ .id = "t", .name = "mcp__codedbpro__batch", .input = .null }));
    try std.testing.expectEqual(Class.zigrep, classOf(bash.call(a, "zigrep TODO src")));
    try std.testing.expectEqual(Class.native_search, classOf(bash.call(a, "find . -name '*.zig'")));
    try std.testing.expectEqual(Class.other, classOf(bash.call(a, "curl -s x | grep err"))); // piped: output filtering
    try std.testing.expectEqual(Class.native_read, classOf(.{ .id = "t", .name = "read_file", .input = .null }));
    try std.testing.expectEqual(Class.other, classOf(.{ .id = "t", .name = "edit_file", .input = .null }));
}

test "record/snapshot/skew: a dominant class is named, balanced usage is quiet" {
    reset();
    defer reset();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const search: tools.ToolCall = .{ .id = "t", .name = "mcp__codedbpro__faster_search", .input = .null };
    for (0..9) |_| _ = record(a, search, false);
    _ = record(a, .{ .id = "t", .name = "mcp__codedbpro__read", .input = .null }, false);
    recordRefusal();
    var snap = snapshot();
    try std.testing.expectEqual(@as(u64, 10), snap.suiteTotal());
    try std.testing.expectEqual(@as(u64, 1), snap.refused);
    const warn = skewWarning(a, &snap) orelse return error.TestExpectedSkew;
    try std.testing.expect(std.mem.indexOf(u8, warn, "search") != null);

    reset();
    for (0..3) |_| _ = record(a, search, false);
    for (0..3) |_| _ = record(a, .{ .id = "t", .name = "mcp__codedbpro__read", .input = .null }, false);
    for (0..3) |_| _ = record(a, .{ .id = "t", .name = "mcp__codedbpro__batch", .input = .null }, false);
    var even = snapshot();
    try std.testing.expect(skewWarning(a, &even) == null);
    // ...and below the 8-call floor the warning stays out of thin sessions.
    reset();
    for (0..5) |_| _ = record(a, search, false);
    var thin = snapshot();
    try std.testing.expect(skewWarning(a, &thin) == null);
}

test "record edge-triggers the steering nudge: once per dominant class" {
    reset();
    defer reset();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const search: tools.ToolCall = .{ .id = "t", .name = "mcp__codedbpro__faster_search", .input = .null };
    var nudges: usize = 0;
    for (0..9) |_| if (record(a, search, false)) |_| {
        nudges += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), nudges); // fired exactly once, at the crossing
    // A non-suite call never nudges.
    try std.testing.expect(record(a, .{ .id = "t", .name = "edit_file", .input = .null }, false) == null);
}

test "render shows classes, gate state and skew" {
    reset();
    defer reset();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for (0..9) |_| _ = record(a, .{ .id = "t", .name = "mcp__codedbpro__faster_search", .input = .null }, false);
    recordRefusal();
    var snap = snapshot();
    const text = try render(a, &snap, true, false);
    try std.testing.expect(std.mem.indexOf(u8, text, "search 9") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fallback closed") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "skew:") != null);
}
