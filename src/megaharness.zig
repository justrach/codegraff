//! Megaharness: GPU-megakernel-inspired fused execution engine (ADR 0322).
//!
//! Synthesizes the four core mechanisms of persistent GPU megakernels
//! (ThunderKittens "No-Bubbles" stream overlapping, CMU Mirage Persistent
//! Kernel / MPK dependency wavefronts, on-chip SRAM register residency vs.
//! HBM round-trips, and persistent delta state) into `codegraff`'s agent
//! tool-execution loop:
//!
//!   1. Zero-bubble stream speculation (`rlm_spec.feedLive` -> `takeLive`):
//!      Closed literal calls launch while SSE tokens are still streaming.
//!   2. Multi-wave dependency DAG scheduling (`collectWave`):
//!      Statements in `rlm` are partitioned into dataflow waves over the live
//!      register file (`binds`). Once wave W resolves a binding (`p = ...`),
//!      independent safe calls in wave W+1 that consume `p` fan out in parallel
//!      instead of dropping to serial execution after the first barrier.
//!   3. SRAM register locality vs. HBM context round-trips:
//!      Intermediate tool outputs stay in local `binds` registers (`sram_bytes`)
//!      across chained operations; only `print()` outputs cross the wire into
//!      the model's context window (`hbm_bytes`).
//!   4. Live fusion telemetry (`/megaharness` and `/kernel`):
//!      Tracks `scripts_fused`, `ops_executed`, `waves_launched`,
//!      `parallel_ops_fused`, `speculative_stream_hits`,
//!      `llm_round_trips_saved`, `sram_register_bytes`, and
//!      `hbm_context_bytes_emitted`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ptc = @import("spec_ptc.zig");
const order = @import("rlm_order.zig");

pub const WavePlan = struct {
    /// Statements included in this concurrent wavefront (`stmts[0..stmt_count]`).
    stmt_count: usize = 0,
    /// Extracted calls (with bound arguments resolved from `binds`) to launch in parallel.
    calls: []const ptc.Call = &.{},
};

/// Collect a concurrent wavefront of safe calls starting at `stmts[0]`, using
/// the currently resolved register bindings `binds`.
///
/// Stops the wave as soon as a statement:
///   - is not a safe call (or `print(...)` of safe calls) with all input
///     bindings already present in `binds`, OR
///   - reads a variable name that an earlier statement in the SAME wave
///     assigns (a Read-After-Write / RAW hazard across statements in one wave).
pub fn collectWave(
    arena: Allocator,
    stmts: []const []const u8,
    binds: []const ptc.Bound,
) !WavePlan {
    var written: std.ArrayList([]const u8) = .empty;
    var calls: std.ArrayList(ptc.Call) = .empty;
    var count: usize = 0;

    for (stmts) |stmt| {
        if (readsAnyWritten(stmt, written.items)) break;
        const stmt_calls = (try extractBoundSafeCalls(arena, stmt, binds)) orelse break;
        if (assignLhs(stmt)) |lhs| {
            try written.append(arena, lhs);
        }
        try calls.appendSlice(arena, stmt_calls);
        count += 1;
    }
    return .{
        .stmt_count = count,
        .calls = calls.items,
    };
}

/// Extract safe calls from `stmt` resolving argument identifiers against `binds`.
pub fn extractBoundSafeCalls(
    arena: Allocator,
    stmt: []const u8,
    binds: []const ptc.Bound,
) !?[]const ptc.Call {
    if (try ptc.extractCallBound(arena, stmt, binds)) |call| {
        if (!order.safe(call)) return null;
        const one = try arena.alloc(ptc.Call, 1);
        one[0] = call;
        return one;
    }
    const text = std.mem.trim(u8, ptc.stripComment(stmt), " \t");
    if (!std.mem.startsWith(u8, text, "print(") or text[text.len - 1] != ')') return null;
    const parts = try ptc.splitTopLevel(arena, text[6 .. text.len - 1], ',');
    var calls: std.ArrayList(ptc.Call) = .empty;
    for (parts) |part| {
        const call = (try ptc.extractCallBound(arena, part, binds)) orelse return null;
        if (!order.safe(call)) return null;
        try calls.append(arena, call);
    }
    return if (calls.items.len > 0) calls.items else null;
}

fn assignLhs(stmt: []const u8) ?[]const u8 {
    const clean = std.mem.trim(u8, ptc.stripComment(stmt), " \t");
    const paren = std.mem.indexOfScalar(u8, clean, '(') orelse clean.len;
    const eq = std.mem.indexOfScalar(u8, clean[0..paren], '=') orelse return null;
    if (eq + 1 < clean.len and clean[eq + 1] == '=') return null;
    const lhs = std.mem.trim(u8, clean[0..eq], " \t");
    return if (lhs.len > 0) lhs else null;
}

/// True if the RHS of `stmt` references any identifier in `written` outside string literals.
fn readsAnyWritten(stmt: []const u8, written: []const []const u8) bool {
    if (written.len == 0) return false;
    const clean = std.mem.trim(u8, ptc.stripComment(stmt), " \t");
    const paren = std.mem.indexOfScalar(u8, clean, '(') orelse return false;
    const rhs = clean[paren..];
    var i: usize = 0;
    var in_str: ?u8 = null;
    var esc = false;
    while (i < rhs.len) {
        const c = rhs[i];
        if (in_str) |q| {
            if (esc) {
                esc = false;
            } else if (c == '\\') {
                esc = true;
            } else if (c == q) {
                in_str = null;
            }
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_str = c;
            i += 1;
            continue;
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            var end = i + 1;
            while (end < rhs.len and (std.ascii.isAlphanumeric(rhs[end]) or rhs[end] == '_')) : (end += 1) {}
            const ident = rhs[i..end];
            // Skip if followed by `=` (keyword arg name) or `(` (callee name).
            var next = end;
            while (next < rhs.len and (rhs[next] == ' ' or rhs[next] == '\t')) : (next += 1) {}
            const is_kw_or_fn = next < rhs.len and (rhs[next] == '=' or rhs[next] == '(');
            if (!is_kw_or_fn) {
                for (written) |w| if (std.mem.eql(u8, ident, w)) return true;
            }
            i = end;
            continue;
        }
        i += 1;
    }
    return false;
}

// ── Live Megaharness Telemetry ─────────────────────────────────────────────

pub const Stats = struct {
    scripts_fused: u64 = 0,
    ops_executed: u64 = 0,
    waves_launched: u64 = 0,
    parallel_ops_fused: u64 = 0,
    speculative_stream_hits: u64 = 0,
    llm_round_trips_saved: u64 = 0,
    sram_register_bytes: u64 = 0,
    hbm_context_bytes_emitted: u64 = 0,

    pub fn sramLocalityPct(self: Stats) u64 {
        const total = self.sram_register_bytes + self.hbm_context_bytes_emitted;
        if (total == 0) return 0;
        return (self.sram_register_bytes * 100) / total;
    }
};

var g_stats: Stats = .{};

pub fn snapshot() Stats {
    return g_stats;
}

pub fn reset() void {
    g_stats = .{};
}

pub fn recordScript(
    ops: u64,
    waves: u64,
    parallel_ops: u64,
    spec_hits: u64,
    sram_bytes: u64,
    hbm_bytes: u64,
) void {
    g_stats.scripts_fused +%= 1;
    g_stats.ops_executed +%= ops;
    g_stats.waves_launched +%= waves;
    g_stats.parallel_ops_fused +%= parallel_ops;
    g_stats.speculative_stream_hits +%= spec_hits;
    if (ops > 1) g_stats.llm_round_trips_saved +%= (ops - 1);
    g_stats.sram_register_bytes +%= sram_bytes;
    g_stats.hbm_context_bytes_emitted +%= hbm_bytes;
}

pub fn render(arena: Allocator, s: Stats) ![]u8 {
    return std.fmt.allocPrint(
        arena,
        "megaharness fusion state (ADR 0322)\n" ++
            "  fused scripts:          {d}\n" ++
            "  host ops executed:      {d} across {d} dependency wave(s) ({d} parallel-wave ops)\n" ++
            "  LLM round-trips saved:  {d} (zero-bubble SSE speculative hits: {d})\n" ++
            "  register SRAM locality: {d} B kept in local binds vs {d} B emitted to context HBM ({d}% on-chip)\n",
        .{
            s.scripts_fused,
            s.ops_executed,
            s.waves_launched,
            s.parallel_ops_fused,
            s.llm_round_trips_saved,
            s.speculative_stream_hits,
            s.sram_register_bytes,
            s.hbm_context_bytes_emitted,
            s.sramLocalityPct(),
        },
    );
}

pub fn toJson(arena: Allocator, s: Stats) ![]u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"scripts_fused\":{d},\"ops_executed\":{d},\"waves_launched\":{d},\"parallel_ops_fused\":{d},\"speculative_stream_hits\":{d},\"llm_round_trips_saved\":{d},\"sram_register_bytes\":{d},\"hbm_context_bytes_emitted\":{d},\"sram_locality_pct\":{d}}}",
        .{
            s.scripts_fused,
            s.ops_executed,
            s.waves_launched,
            s.parallel_ops_fused,
            s.speculative_stream_hits,
            s.llm_round_trips_saved,
            s.sram_register_bytes,
            s.hbm_context_bytes_emitted,
            s.sramLocalityPct(),
        },
    );
}

pub fn trySlash(arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    const is_mh = std.mem.eql(u8, trimmed, "/megaharness") or std.mem.startsWith(u8, trimmed, "/megaharness ");
    const is_k = std.mem.eql(u8, trimmed, "/kernel") or std.mem.startsWith(u8, trimmed, "/kernel ");
    if (!is_mh and !is_k) return false;
    const prefix = if (is_mh) "/megaharness" else "/kernel";
    const arg = std.mem.trim(u8, trimmed[prefix.len..], " \t");
    if (std.mem.eql(u8, arg, "reset")) {
        reset();
        try out.writeAll("megaharness counters reset.\n");
        try out.flush();
        return true;
    }
    const s = snapshot();
    if (std.mem.eql(u8, arg, "json") or std.mem.eql(u8, arg, "--json")) {
        try out.print("{s}\n", .{try toJson(arena, s)});
    } else {
        try out.writeAll(try render(arena, s));
    }
    try out.flush();
    return true;
}

test "collectWave schedules multi-wave bound calls and stops at RAW hazards" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Wave 1: two literal reads can run concurrently, but stmt 3 (`c = read_file(p)`)
    // depends on `p = "src/main.zig"` which is not a safe host call.
    const stmts1 = [_][]const u8{
        "a = read_file(\"README.md\")",
        "b = codedb(\"status\")",
        "p = \"src/main.zig\"",
        "c = read_file(p)",
        "d = codedb(p)",
    };
    const w1 = try collectWave(a, &stmts1, &.{});
    try std.testing.expectEqual(@as(usize, 2), w1.stmt_count);
    try std.testing.expectEqual(@as(usize, 2), w1.calls.len);

    // Once `p` is bound in the register file (after wave 1 + literal assignment),
    // Wave 2 (`c = read_file(p)` and `d = codedb(p)`) both consume `p` and fan out
    // concurrently in a single wave!
    const binds = [_]ptc.Bound{.{ .name = "p", .text = "src/main.zig" }};
    const w2 = try collectWave(a, stmts1[3..], &binds);
    try std.testing.expectEqual(@as(usize, 2), w2.stmt_count);
    try std.testing.expectEqual(@as(usize, 2), w2.calls.len);
    try std.testing.expectEqualStrings("read_file", w2.calls[0].name);
    try std.testing.expectEqualStrings("codedb", w2.calls[1].name);

    // RAW hazard: if stmt 0 writes `x` and stmt 1 reads `x`, stmt 1 must wait for wave 2.
    const hazard_stmts = [_][]const u8{
        "x = read_file(\"a.txt\")",
        "y = read_file(x)",
    };
    const wh = try collectWave(a, &hazard_stmts, &binds);
    try std.testing.expectEqual(@as(usize, 1), wh.stmt_count);
    try std.testing.expectEqual(@as(usize, 1), wh.calls.len);
}

test "megaharness telemetry tracks round-trips saved and SRAM register locality" {
    reset();
    defer reset();
    recordScript(4, 2, 4, 2, 16_000, 4_000);
    const s = snapshot();
    try std.testing.expectEqual(@as(u64, 1), s.scripts_fused);
    try std.testing.expectEqual(@as(u64, 4), s.ops_executed);
    try std.testing.expectEqual(@as(u64, 2), s.waves_launched);
    try std.testing.expectEqual(@as(u64, 3), s.llm_round_trips_saved);
    try std.testing.expectEqual(@as(u64, 2), s.speculative_stream_hits);
    try std.testing.expectEqual(@as(u64, 80), s.sramLocalityPct());

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const hud = try render(a, s);
    try std.testing.expect(std.mem.indexOf(u8, hud, "LLM round-trips saved:  3") != null);
    try std.testing.expect(std.mem.indexOf(u8, hud, "(80% on-chip)") != null);
    const j = try toJson(a, s);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"llm_round_trips_saved\":3") != null);
}
