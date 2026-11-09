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
const rlm_literal = @import("rlm_literal.zig");
const rlm_reduce = @import("rlm_reduce.zig");
const rlm_mcp = @import("rlm_mcp.zig");

pub const WavePlan = struct {
    /// Statements included in this concurrent wavefront (`stmts[0..stmt_count]`).
    stmt_count: usize = 0,
    /// Extracted calls (with bound arguments resolved from `binds` + folded ALU ops) to launch in parallel.
    calls: []const ptc.Call = &.{},
    /// Pure local register ALU operations (`name = literal`, `len()`, `project()`) folded into this wave.
    alu_ops_folded: usize = 0,
};

/// Collect a concurrent wavefront of safe calls starting at `stmts[0]`, using
/// the currently resolved register bindings `binds` plus shadow ALU folding.
///
/// Pure local SRAM register operations (`name = "literal"`, `name = [...]`,
/// `name = {...}`, `len(x)`, `project(x, field)`) whose inputs are already
/// resolved fold directly into `wave_binds` without breaking the wavefront, so
/// interleaved path/argument bindings between `read_file`/`codedb`/`llm_query`
/// calls still fuse into a single parallel wave.
///
/// Stops the wave as soon as a statement:
///   - reads or overwrites a variable name that an earlier host call in the
///     SAME wave assigns (RAW / WAW hazard on a pending host call), OR
///   - is an in-kernel predicate guard (`assert_contains` / `assert_eq`), OR
///   - is neither a safe host call nor a pure register ALU operation with all
///     inputs resolved.
pub fn collectWave(
    arena: Allocator,
    stmts: []const []const u8,
    binds: []const ptc.Bound,
) !WavePlan {
    var wave_binds: std.ArrayList(ptc.Bound) = .empty;
    try wave_binds.appendSlice(arena, binds);
    var written: std.ArrayList([]const u8) = .empty;
    var calls: std.ArrayList(ptc.Call) = .empty;
    var count: usize = 0;
    var alu_folded: usize = 0;

    for (stmts) |stmt| {
        if (readsAnyWritten(stmt, written.items)) break;
        const lhs = assignLhs(stmt);
        if (lhs) |name| {
            if (containsName(written.items, name)) break;
        }
        if (isAssertStmt(stmt)) break;

        if (try extractBoundSafeCalls(arena, stmt, wave_binds.items)) |stmt_calls| {
            if (lhs) |name| try written.append(arena, name);
            try calls.appendSlice(arena, stmt_calls);
            count += 1;
            continue;
        }
        if (try rlm_literal.assign(arena, stmt, wave_binds.items)) |b| {
            try wave_binds.append(arena, b);
            alu_folded += 1;
            count += 1;
            continue;
        }
        switch (try rlm_reduce.evalStmt(arena, arena, stmt, wave_binds.items, &wave_binds)) {
            .ok => {
                alu_folded += 1;
                count += 1;
                continue;
            },
            .miss, .fail => break,
        }
    }
    return .{
        .stmt_count = count,
        .calls = calls.items,
        .alu_ops_folded = alu_folded,
    };
}

fn containsName(list: []const []const u8, target: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, target)) return true;
    return false;
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

fn stmtRhs(stmt: []const u8) []const u8 {
    const clean = std.mem.trim(u8, ptc.stripComment(stmt), " \t");
    const paren = std.mem.indexOfScalar(u8, clean, '(') orelse clean.len;
    if (std.mem.indexOfScalar(u8, clean[0..paren], '=')) |eq| {
        if (eq + 1 < clean.len and clean[eq + 1] != '=') {
            return std.mem.trim(u8, clean[eq + 1 ..], " \t");
        }
    }
    return clean;
}

/// True if the RHS of `stmt` references any identifier in `written` outside string literals.
fn readsAnyWritten(stmt: []const u8, written: []const []const u8) bool {
    if (written.len == 0) return false;
    const rhs = stmtRhs(stmt);
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

pub fn isAssertStmt(stmt: []const u8) bool {
    const rhs = stmtRhs(stmt);
    if (rhs.len == 0 or rhs[rhs.len - 1] != ')') return false;
    return std.mem.startsWith(u8, rhs, "assert_contains(") or std.mem.startsWith(u8, rhs, "assert_eq(");
}

/// Evaluate in-kernel predicate assertions (`assert_contains(x, "needle")`,
/// `assert_eq(x, "expected")`) inside `rlm` without an LLM round-trip.
pub fn evalAssert(
    arena: Allocator,
    gpa: Allocator,
    stmt: []const u8,
    binds: []const ptc.Bound,
    bind_out: *std.ArrayList(ptc.Bound),
) !rlm_mcp.StmtHit {
    if (!isAssertStmt(stmt)) return .miss;
    const rhs = stmtRhs(stmt);
    const is_contains = std.mem.startsWith(u8, rhs, "assert_contains(");
    const prefix_len = if (is_contains) "assert_contains(".len else "assert_eq(".len;
    const inner = rhs[prefix_len .. rhs.len - 1];
    const parts = ptc.splitTopLevel(arena, inner, ',') catch {
        g_stats.assertions_failed +%= 1;
        return .{ .fail = try gpa.dupe(u8, "rlm: assert_contains/assert_eq requires 2 arguments") };
    };
    if (parts.len != 2) {
        g_stats.assertions_failed +%= 1;
        return .{ .fail = try gpa.dupe(u8, "rlm: assert_contains/assert_eq requires 2 arguments") };
    }
    const a_val = resolveAssertArg(arena, parts[0], binds) orelse {
        g_stats.assertions_failed +%= 1;
        return .{ .fail = try std.fmt.allocPrint(gpa, "rlm: unbound first argument in {s}", .{rhs}) };
    };
    const b_val = resolveAssertArg(arena, parts[1], binds) orelse {
        g_stats.assertions_failed +%= 1;
        return .{ .fail = try std.fmt.allocPrint(gpa, "rlm: unbound second argument in {s}", .{rhs}) };
    };
    const ok = if (is_contains)
        std.mem.indexOf(u8, a_val, b_val) != null
    else
        std.mem.eql(u8, a_val, b_val);
    if (!ok) {
        g_stats.assertions_failed +%= 1;
        const msg = if (is_contains)
            try std.fmt.allocPrint(gpa, "rlm: assert_contains failed: expected '{s}' in bound value", .{b_val})
        else
            try std.fmt.allocPrint(gpa, "rlm: assert_eq failed: '{s}' != '{s}'", .{ a_val, b_val });
        return .{ .fail = msg };
    }
    g_stats.assertions_passed +%= 1;
    if (assignLhs(stmt)) |lhs| {
        try bind_out.append(arena, .{ .name = try arena.dupe(u8, lhs), .text = "true" });
    }
    return .ok;
}

fn resolveAssertArg(arena: Allocator, raw: []const u8, binds: []const ptc.Bound) ?[]const u8 {
    const t = std.mem.trim(u8, raw, " \t");
    if (t.len == 0) return null;
    if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0]) {
        const assign_stmt = std.fmt.allocPrint(arena, "_ = {s}", .{t}) catch return t[1 .. t.len - 1];
        if (rlm_literal.assign(arena, assign_stmt, binds) catch null) |b| return b.text;
        return t[1 .. t.len - 1];
    }
    var i = binds.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, binds[i].name, t)) return binds[i].text;
    }
    const assign_stmt = std.fmt.allocPrint(arena, "_ = {s}", .{t}) catch return null;
    if (rlm_literal.assign(arena, assign_stmt, binds) catch null) |b| return b.text;
    return null;
}

// ── Live Megaharness Telemetry ─────────────────────────────────────────────

pub const Stats = struct {
    scripts_fused: u64 = 0,
    ops_executed: u64 = 0,
    waves_launched: u64 = 0,
    parallel_ops_fused: u64 = 0,
    alu_ops_folded: u64 = 0,
    speculative_stream_hits: u64 = 0,
    native_batches_fused: u64 = 0,
    native_batch_calls: u64 = 0,
    snapshot_chunks_reused: u64 = 0,
    snapshot_bytes_reused: u64 = 0,
    assertions_passed: u64 = 0,
    assertions_failed: u64 = 0,
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
    alu_folded: u64,
    spec_hits: u64,
    sram_bytes: u64,
    hbm_bytes: u64,
) void {
    g_stats.scripts_fused +%= 1;
    g_stats.ops_executed +%= ops;
    g_stats.waves_launched +%= waves;
    g_stats.parallel_ops_fused +%= parallel_ops;
    g_stats.alu_ops_folded +%= alu_folded;
    g_stats.speculative_stream_hits +%= spec_hits;
    if (ops > 1) g_stats.llm_round_trips_saved +%= (ops - 1);
    g_stats.sram_register_bytes +%= sram_bytes;
    g_stats.hbm_context_bytes_emitted +%= hbm_bytes;
}

pub fn recordNativeBatch(batch_calls: usize) void {
    if (batch_calls <= 1) return;
    g_stats.native_batches_fused +%= 1;
    g_stats.native_batch_calls +%= batch_calls;
    g_stats.llm_round_trips_saved +%= (batch_calls - 1);
}

pub fn recordSnapshotReuse(reused_chunks: usize, reused_bytes: usize) void {
    if (reused_chunks == 0) return;
    g_stats.snapshot_chunks_reused +%= reused_chunks;
    g_stats.snapshot_bytes_reused +%= reused_bytes;
}

pub fn render(arena: Allocator, s: Stats) ![]u8 {
    return std.fmt.allocPrint(
        arena,
        "megaharness fusion state (ADR 0322)\n" ++
            "  fused scripts:          {d} ({d} ALU register ops folded)\n" ++
            "  host ops executed:      {d} across {d} dependency wave(s) ({d} parallel-wave ops)\n" ++
            "  native batches fused:   {d} ({d} concurrent catalog tool calls)\n" ++
            "  in-kernel assertions:   {d} passed, {d} halted\n" ++
            "  LLM round-trips saved:  {d} (zero-bubble SSE speculative hits: {d})\n" ++
            "  register SRAM locality: {d} B kept in local binds vs {d} B emitted to context HBM ({d}% on-chip)\n" ++
            "  delta snapshot reuse:   {d} immutable message chunks ({d} B reused without re-serializing)\n",
        .{
            s.scripts_fused,
            s.alu_ops_folded,
            s.ops_executed,
            s.waves_launched,
            s.parallel_ops_fused,
            s.native_batches_fused,
            s.native_batch_calls,
            s.assertions_passed,
            s.assertions_failed,
            s.llm_round_trips_saved,
            s.speculative_stream_hits,
            s.sram_register_bytes,
            s.hbm_context_bytes_emitted,
            s.sramLocalityPct(),
            s.snapshot_chunks_reused,
            s.snapshot_bytes_reused,
        },
    );
}

pub fn toJson(arena: Allocator, s: Stats) ![]u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"scripts_fused\":{d},\"ops_executed\":{d},\"waves_launched\":{d},\"parallel_ops_fused\":{d},\"alu_ops_folded\":{d},\"speculative_stream_hits\":{d},\"native_batches_fused\":{d},\"native_batch_calls\":{d},\"snapshot_chunks_reused\":{d},\"snapshot_bytes_reused\":{d},\"assertions_passed\":{d},\"assertions_failed\":{d},\"llm_round_trips_saved\":{d},\"sram_register_bytes\":{d},\"hbm_context_bytes_emitted\":{d},\"sram_locality_pct\":{d}}}",
        .{
            s.scripts_fused,
            s.ops_executed,
            s.waves_launched,
            s.parallel_ops_fused,
            s.alu_ops_folded,
            s.speculative_stream_hits,
            s.native_batches_fused,
            s.native_batch_calls,
            s.snapshot_chunks_reused,
            s.snapshot_bytes_reused,
            s.assertions_passed,
            s.assertions_failed,
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

test "collectWave folds interleaved register ALU ops into a single parallel wave and stops at RAW hazards" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Interleaved literal bindings (`p = "src/main.zig"`) and reducers (`n = len(items)`)
    // fold directly into `wave_binds`, so ALL FOUR safe host calls (`a`, `b`, `c`, `d`)
    // launch concurrently in a SINGLE wavefront!
    const stmts1 = [_][]const u8{
        "a = read_file(\"README.md\")",
        "b = codedb(\"status\")",
        "p = \"src/main.zig\"",
        "c = read_file(p)",
        "d = codedb(p)",
    };
    const w1 = try collectWave(a, &stmts1, &.{});
    try std.testing.expectEqual(@as(usize, 5), w1.stmt_count);
    try std.testing.expectEqual(@as(usize, 4), w1.calls.len);
    try std.testing.expectEqual(@as(usize, 1), w1.alu_ops_folded);
    try std.testing.expectEqualStrings("read_file", w1.calls[2].name);
    try std.testing.expect(std.mem.indexOf(u8, w1.calls[2].args_json, "src/main.zig") != null);

    // RAW hazard: if stmt 0 writes `x` via a host call and stmt 1 reads `x` (either via a
    // host call or a literal/reducer), stmt 1 must wait for wave 2.
    const hazard_stmts = [_][]const u8{
        "x = read_file(\"a.txt\")",
        "y = read_file(x)",
    };
    const wh = try collectWave(a, &hazard_stmts, &.{});
    try std.testing.expectEqual(@as(usize, 1), wh.stmt_count);
    try std.testing.expectEqual(@as(usize, 1), wh.calls.len);

    // RAW hazard through a literal alias (`alias = x` after `x = read_file(...)`):
    const alias_hazard = [_][]const u8{
        "x = read_file(\"a.txt\")",
        "alias = x",
        "y = read_file(alias)",
    };
    const wah = try collectWave(a, &alias_hazard, &.{});
    try std.testing.expectEqual(@as(usize, 1), wah.stmt_count);
    try std.testing.expectEqual(@as(usize, 1), wah.calls.len);
}

test "evalAssert validates in-kernel predicates and halts on mismatch" {
    reset();
    defer reset();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const binds = [_]ptc.Bound{
        .{ .name = "src", .text = "pub fn collectWave() void {}" },
        .{ .name = "count", .text = "3" },
    };
    var out_binds: std.ArrayList(ptc.Bound) = .empty;
    const ok1 = try evalAssert(a, std.testing.allocator, "assert_contains(src, \"collectWave\")", &binds, &out_binds);
    try std.testing.expect(ok1 == .ok);
    const ok2 = try evalAssert(a, std.testing.allocator, "ok = assert_eq(count, 3)", &binds, &out_binds);
    try std.testing.expect(ok2 == .ok);
    try std.testing.expectEqualStrings("true", out_binds.items[0].text);

    const fail = try evalAssert(a, std.testing.allocator, "assert_contains(src, \"missingSymbol\")", &binds, &out_binds);
    defer switch (fail) {
        .fail => |msg| std.testing.allocator.free(msg),
        else => {},
    };
    try std.testing.expect(fail == .fail);
    const s = snapshot();
    try std.testing.expectEqual(@as(u64, 2), s.assertions_passed);
    try std.testing.expectEqual(@as(u64, 1), s.assertions_failed);
}

test "megaharness telemetry tracks round-trips saved, native batches, and SRAM register locality" {
    reset();
    defer reset();
    recordScript(4, 1, 4, 1, 2, 16_000, 4_000);
    recordNativeBatch(3);
    recordSnapshotReuse(5, 12_800);
    const s = snapshot();
    try std.testing.expectEqual(@as(u64, 1), s.scripts_fused);
    try std.testing.expectEqual(@as(u64, 4), s.ops_executed);
    try std.testing.expectEqual(@as(u64, 1), s.waves_launched);
    try std.testing.expectEqual(@as(u64, 1), s.alu_ops_folded);
    try std.testing.expectEqual(@as(u64, 1), s.native_batches_fused);
    try std.testing.expectEqual(@as(u64, 3), s.native_batch_calls);
    try std.testing.expectEqual(@as(u64, 5), s.snapshot_chunks_reused);
    try std.testing.expectEqual(@as(u64, 5), s.llm_round_trips_saved);
    try std.testing.expectEqual(@as(u64, 2), s.speculative_stream_hits);
    try std.testing.expectEqual(@as(u64, 80), s.sramLocalityPct());

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const hud = try render(a, s);
    try std.testing.expect(std.mem.indexOf(u8, hud, "LLM round-trips saved:  5") != null);
    try std.testing.expect(std.mem.indexOf(u8, hud, "(80% on-chip)") != null);
    const j = try toJson(a, s);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"llm_round_trips_saved\":5") != null);
}
