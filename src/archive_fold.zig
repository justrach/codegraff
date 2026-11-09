//! Bounded, cached, and streaming fold over `.graff/trajectories` (#1864).
//!
//! Prior to #1864, every process startup (`noteKeysAtStartup`) read up to 8 MiB
//! of raw `.graff/trajectories/*.jsonl` into a page-backed arena (~24 MiB of
//! doubling buffers) and scanned it four times across `bench_priors`,
//! `route_policy`, and `orchestration_policy` without resetting per-line JSON
//! parse trees (~30.6 MiB peak RSS and ~93 ms paid before the first token).
//!
//! Three invariants keep the boot floor flat regardless of archive size:
//! 1. **Defer until routing**: startup loads `.harness/bench.json` (or compiled
//!    builtins) and warms from `.graff/folded_priors.json` only if it already
//!    exists; scanning `.graff/trajectories/*.jsonl` waits until the first
//!    routing consumer (`ensureArchiveLoaded`) or an explicit hot-reload.
//! 2. **Stream + persist beside the archive**: a cold fold streams `.jsonl`
//!    files through a fixed stack buffer in one pass, resets a tiny per-line
//!    parse arena on every row, and persists `.graff/folded_priors.json` keyed
//!    by `(files, bytes, max_mtime_ms, legacy_bytes, legacy_mtime_ms)`. When
//!    new runs add `.jsonl` files with no `score` or `orch_outcome` rows, only
//!    those delta files are inspected and the cached fold is reused.
//! 3. **Shared retention budget**: every table (`Obs`, `CellObs`, `ArmObs`)
//!    retains at most `max_obs_per_cell` (32) recent observations per bucket
//!    and at most `max_buckets` (128) buckets, recording truncations in
//!    `g_truncated_obs`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const bench = @import("bench_priors.zig");
const route_policy = @import("route_policy.zig");
const orch = @import("orchestration_policy.zig");
const trace = @import("trace.zig");

pub const folded_cache_path = ".graff/folded_priors.json";
pub const max_archive_bytes: usize = 8 << 20;
pub const max_obs_per_cell: u32 = 32;
pub const max_buckets: usize = 128;
pub const max_recipes: usize = 512;

pub var g_truncated_obs: u32 = 0;

pub fn truncatedCount() u32 {
    return g_truncated_obs;
}

pub const ScoreRing = struct {
    samples: [max_obs_per_cell]f64 = @splat(0),
    head: u32 = 0,

    pub fn add(self: *ScoreRing, sum: *f64, n: *u32, score: f64) void {
        if (n.* < max_obs_per_cell) {
            self.samples[n.*] = score;
            sum.* += score;
            n.* += 1;
        } else {
            sum.* -= self.samples[self.head];
            self.samples[self.head] = score;
            sum.* += score;
            self.head = (self.head + 1) % max_obs_per_cell;
            g_truncated_obs +|= 1;
        }
    }
};

pub const ArmSample = struct { score: f64 = 0, calls: u32 = 0, exhausted: bool = false, landed: bool = false };

pub const ArmRing = struct {
    samples: [max_obs_per_cell]ArmSample = @splat(.{}),
    head: u32 = 0,

    pub fn add(self: *ArmRing, arm: *orch.ArmObs, score: f64, calls: u64, exhausted: bool, landed: bool) void {
        const c32 = std.math.cast(u32, calls) orelse std.math.maxInt(u32);
        if (arm.n < max_obs_per_cell) {
            const idx = arm.n;
            self.samples[idx] = .{ .score = score, .calls = c32, .exhausted = exhausted, .landed = landed };
            arm.sum_score += score;
            arm.n += 1;
            if (exhausted) arm.exhausted_n += 1;
            if (landed) arm.landed_n += 1;
            arm.calls[idx] = c32;
            arm.n_calls = arm.n;
        } else {
            const old = self.samples[self.head];
            arm.sum_score -= old.score;
            if (old.exhausted and arm.exhausted_n > 0) arm.exhausted_n -= 1;
            if (old.landed and arm.landed_n > 0) arm.landed_n -= 1;
            self.samples[self.head] = .{ .score = score, .calls = c32, .exhausted = exhausted, .landed = landed };
            arm.sum_score += score;
            if (exhausted) arm.exhausted_n += 1;
            if (landed) arm.landed_n += 1;
            arm.calls[self.head] = c32;
            self.head = (self.head + 1) % max_obs_per_cell;
            g_truncated_obs +|= 1;
        }
    }
};

pub const FoldResult = struct {
    obs: []bench.Obs = &.{},
    cells: []route_policy.CellObs = &.{},
    arms: []orch.ArmObs = &.{},
};

const Recipe = struct { sha: []const u8, model: []const u8, effort: []const u8 };
const PendingScore = struct { sha: []const u8, score: f64 };

fn strField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn numField(o: std.json.ObjectMap, key: []const u8) ?f64 {
    const v = o.get(key) orelse return null;
    return switch (v) {
        .float => |f| f,
        .integer => |x| @floatFromInt(x),
        else => null,
    };
}

fn boolField(o: std.json.ObjectMap, key: []const u8, dflt: bool) bool {
    const v = o.get(key) orelse return dflt;
    return if (v == .bool) v.bool else dflt;
}

pub const Folder = struct {
    arena: Allocator,
    sa: Allocator,
    want_obs: bool = true,
    want_cells: bool = true,
    want_arms: bool = true,
    recipes: std.ArrayList(Recipe) = .empty,
    recipe_head: usize = 0,
    pending_scores: std.ArrayList(PendingScore) = .empty,
    score_head: usize = 0,
    obs: std.ArrayList(bench.Obs) = .empty,
    obs_rings: std.ArrayList(ScoreRing) = .empty,
    cells: std.ArrayList(route_policy.CellObs) = .empty,
    cell_rings: std.ArrayList(ScoreRing) = .empty,
    arms: std.ArrayList(orch.ArmObs) = .empty,
    arm_rings: std.ArrayList(ArmRing) = .empty,
    line_buf: [16 * 1024]u8 = undefined,

    pub fn feedLine(self: *Folder, raw: []const u8) void {
        const t = std.mem.trim(u8, raw, " \t\r");
        if (t.len == 0) return;
        const is_recipe = self.want_obs and bench.kindIs(t, "recipe");
        const is_score = (self.want_obs or self.want_cells) and bench.kindIs(t, "score");
        const is_orch = self.want_arms and bench.kindIs(t, "orch_outcome");
        if (!is_recipe and !is_score and !is_orch) return;

        var fba = std.heap.FixedBufferAllocator.init(&self.line_buf);
        const v = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), t, .{}) catch return;
        if (v != .object) return;
        const o = v.object;
        const kind = strField(o, "kind") orelse return;

        if (is_recipe and std.mem.eql(u8, kind, "recipe")) {
            const sha = strField(o, "prompt_sha") orelse return;
            const model = strField(o, "model") orelse return;
            const effort = strField(o, "effort") orelse "";
            for (self.recipes.items) |*rc| if (std.mem.eql(u8, rc.sha, sha)) return;
            const rec: Recipe = .{
                .sha = self.sa.dupe(u8, sha) catch return,
                .model = self.sa.dupe(u8, model) catch return,
                .effort = if (effort.len == 0) "" else (self.sa.dupe(u8, effort) catch return),
            };
            if (self.recipes.items.len < max_recipes) {
                self.recipes.append(self.sa, rec) catch return;
            } else {
                self.recipes.items[self.recipe_head] = rec;
                self.recipe_head = (self.recipe_head + 1) % max_recipes;
            }
        } else if (is_score and std.mem.eql(u8, kind, "score")) {
            const s = numField(o, "score") orelse return;
            if (!(s >= 0 and s <= 1)) return;
            if (self.want_obs) if (strField(o, "prompt_sha")) |sha| {
                const ps: PendingScore = .{ .sha = self.sa.dupe(u8, sha) catch return, .score = s };
                const cap = max_recipes * 2;
                if (self.pending_scores.items.len < cap) {
                    self.pending_scores.append(self.sa, ps) catch {};
                } else {
                    self.pending_scores.items[self.score_head] = ps;
                    self.score_head = (self.score_head + 1) % cap;
                }
            };
            if (self.want_cells) self.noteCell(o, s);
        } else if (is_orch and std.mem.eql(u8, kind, "orch_outcome")) {
            self.noteArm(o);
        }
    }

    fn noteCell(self: *Folder, o: std.json.ObjectMap, s: f64) void {
        const shape = strField(o, "shape") orelse return;
        const tier = strField(o, "tier") orelse return;
        const model = strField(o, "model") orelse return;
        if (shape.len == 0 or tier.len == 0 or model.len == 0) return;
        const role = strField(o, "role") orelse "";
        for (self.cells.items, 0..) |*c, idx| {
            if (std.mem.eql(u8, c.shape, shape) and std.mem.eql(u8, c.role, role) and
                std.mem.eql(u8, c.tier, tier) and std.mem.eql(u8, c.model, model))
            {
                self.cell_rings.items[idx].add(&c.sum, &c.n, s);
                return;
            }
        }
        if (self.cells.items.len >= max_buckets) {
            g_truncated_obs +|= 1;
            return;
        }
        const shape_copy = self.arena.dupe(u8, shape) catch return;
        const role_copy = if (role.len == 0) "" else (self.arena.dupe(u8, role) catch return);
        const tier_copy = self.arena.dupe(u8, tier) catch return;
        const model_copy = self.arena.dupe(u8, model) catch return;
        self.cells.append(self.arena, .{ .shape = shape_copy, .role = role_copy, .tier = tier_copy, .model = model_copy }) catch return;
        self.cell_rings.append(self.sa, .{}) catch {
            _ = self.cells.pop();
            return;
        };
        const last = self.cells.items.len - 1;
        self.cell_rings.items[last].add(&self.cells.items[last].sum, &self.cells.items[last].n, s);
    }

    fn noteArm(self: *Folder, o: std.json.ObjectMap) void {
        const source = orch.Source.parse(strField(o, "source") orelse "") orelse return;
        if (source == .explicit or !boolField(o, "variant_free", true)) return;
        const arm = orch.Rung.parse(strField(o, "arm") orelse "") orelse return;
        const stratum = strField(o, "stratum") orelse return;
        if (stratum.len == 0) return;
        const tc = strField(o, "task_class") orelse return;
        const bb = strField(o, "budget_band") orelse return;
        const score = numField(o, "score") orelse return;
        if (!(score >= 0 and score <= 1)) return;
        const cval = numField(o, "calls_used") orelse 0;
        const calls: u64 = if (cval < 0) 0 else @intFromFloat(cval);
        const probe_key: orch.Key = .{ .task_class = orch.TaskClass.parse(tc), .budget_band = orch.BudgetBand.parse(bb), .stratum = stratum };
        const exhausted = boolField(o, "exhausted", false);
        const landed = boolField(o, "landed", false);
        for (self.arms.items, 0..) |*c, idx| {
            if (c.arm == arm and c.key.eql(probe_key)) {
                self.arm_rings.items[idx].add(c, score, calls, exhausted, landed);
                return;
            }
        }
        if (self.arms.items.len >= max_buckets) {
            g_truncated_obs +|= 1;
            return;
        }
        const stratum_copy = self.arena.dupe(u8, stratum) catch return;
        const key: orch.Key = .{ .task_class = probe_key.task_class, .budget_band = probe_key.budget_band, .stratum = stratum_copy };
        self.arms.append(self.arena, .{ .key = key, .arm = arm }) catch return;
        self.arm_rings.append(self.sa, .{}) catch {
            _ = self.arms.pop();
            return;
        };
        const last = self.arms.items.len - 1;
        self.arm_rings.items[last].add(&self.arms.items[last], score, calls, exhausted, landed);
    }

    pub fn finish(self: *Folder) FoldResult {
        if (self.want_obs) {
            for (self.pending_scores.items) |ps| {
                const joined: ?Recipe = for (self.recipes.items) |rc| {
                    if (std.mem.eql(u8, rc.sha, ps.sha)) break rc;
                } else null;
                const r = joined orelse continue;
                var matched = false;
                for (self.obs.items, 0..) |*x, idx| {
                    if (std.mem.eql(u8, x.model, r.model) and std.mem.eql(u8, x.effort, r.effort)) {
                        self.obs_rings.items[idx].add(&x.sum, &x.n, ps.score);
                        matched = true;
                        break;
                    }
                }
                if (matched) continue;
                if (self.obs.items.len >= max_buckets) {
                    g_truncated_obs +|= 1;
                    continue;
                }
                const m_copy = self.arena.dupe(u8, r.model) catch break;
                const e_copy = if (r.effort.len == 0) "" else (self.arena.dupe(u8, r.effort) catch break);
                self.obs.append(self.arena, .{ .model = m_copy, .effort = e_copy }) catch break;
                self.obs_rings.append(self.sa, .{}) catch {
                    _ = self.obs.pop();
                    break;
                };
                const last = self.obs.items.len - 1;
                self.obs_rings.items[last].add(&self.obs.items[last].sum, &self.obs.items[last].n, ps.score);
            }
        }
        return .{ .obs = self.obs.items, .cells = self.cells.items, .arms = self.arms.items };
    }
};

pub fn foldSlice(arena: Allocator, archive: []const u8, want_obs: bool, want_cells: bool, want_arms: bool) FoldResult {
    g_truncated_obs = 0;
    if ((want_obs or want_cells) and !want_arms and std.mem.indexOf(u8, archive, "\"score\"") == null) return .{};
    if (want_arms and !want_obs and !want_cells and std.mem.indexOf(u8, archive, "\"orch_outcome\"") == null) return .{};
    var scratch_buf: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch_buf);
    var folder: Folder = .{ .arena = arena, .sa = fba.allocator(), .want_obs = want_obs, .want_cells = want_cells, .want_arms = want_arms };
    var it = std.mem.splitScalar(u8, archive, '\n');
    while (it.next()) |ln| folder.feedLine(ln);
    return folder.finish();
}

pub const ArchiveKey = struct {
    files: u32 = 0,
    bytes: u64 = 0,
    max_mtime_ms: i64 = 0,
    legacy_bytes: u64 = 0,
    legacy_mtime_ms: i64 = 0,

    pub fn eql(a: ArchiveKey, b: ArchiveKey) bool {
        return a.files == b.files and a.bytes == b.bytes and a.max_mtime_ms == b.max_mtime_ms and
            a.legacy_bytes == b.legacy_bytes and a.legacy_mtime_ms == b.legacy_mtime_ms;
    }
};

pub fn statArchiveKey(io: Io) ArchiveKey {
    var key: ArchiveKey = .{};
    if (Io.Dir.cwd().openDir(io, trace.trajectories_dir, .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        defer dir.close(io);
        var it = dir.iterate();
        while (true) {
            const entry = it.next(io) catch break;
            if (entry == null) break;
            if (entry.?.kind != .file or !std.mem.endsWith(u8, entry.?.name, ".jsonl")) continue;
            const st = dir.statFile(io, entry.?.name, .{}) catch continue;
            key.files += 1;
            key.bytes +|= st.size;
            const ms: i64 = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms));
            if (ms > key.max_mtime_ms) key.max_mtime_ms = ms;
        }
    } else |_| {}
    if (Io.Dir.cwd().statFile(io, trace.legacy_trajectory_path, .{})) |st| {
        key.legacy_bytes = st.size;
        key.legacy_mtime_ms = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms));
    } else |_| {}
    return key;
}

const CachedArm = struct {
    task_class: []const u8,
    budget_band: []const u8,
    stratum: []const u8,
    arm: []const u8,
    n: u32,
    sum_score: f64,
    exhausted_n: u32,
    landed_n: u32,
    calls: []const u32,
};

const PersistedFold = struct {
    files: u32 = 0,
    bytes: u64 = 0,
    max_mtime_ms: i64 = 0,
    legacy_bytes: u64 = 0,
    legacy_mtime_ms: i64 = 0,
    truncated: u32 = 0,
    obs: []bench.Obs = &.{},
    cells: []route_policy.CellObs = &.{},
    arms: []CachedArm = &.{},
};

fn scanFileLines(io: Io, dir: Io.Dir, name: []const u8, remaining: ?*usize, folder: ?*Folder) bool {
    if (remaining) |rem| if (rem.* == 0) return false;
    const file = dir.openFile(io, name, .{}) catch return false;
    defer file.close(io);
    const st = file.stat(io) catch return false;
    const size = std.math.cast(usize, st.size) orelse return false;
    if (size == 0) return false;
    if (remaining) |rem| {
        if (size > rem.*) return false;
        rem.* -= size;
    }

    var rbuf: [16 * 1024]u8 = undefined;
    var carry: [8 * 1024]u8 = undefined;
    var carry_len: usize = 0;
    var skip_long = false;
    var offset: u64 = 0;
    while (offset < st.size) {
        const n = file.readPositionalAll(io, &rbuf, offset) catch break;
        if (n == 0) break;
        offset += n;
        var chunk: []const u8 = rbuf[0..n];
        while (std.mem.indexOfScalar(u8, chunk, '\n')) |nl| {
            const part = chunk[0..nl];
            chunk = chunk[nl + 1 ..];
            if (skip_long) {
                skip_long = false;
                carry_len = 0;
                continue;
            }
            const line = if (carry_len == 0) part else blk: {
                if (carry_len + part.len > carry.len) {
                    carry_len = 0;
                    continue;
                }
                @memcpy(carry[carry_len .. carry_len + part.len], part);
                const s = carry[0 .. carry_len + part.len];
                carry_len = 0;
                break :blk s;
            };
            if (folder) |f| f.feedLine(line) else {
                const t = std.mem.trim(u8, line, " \t\r");
                if (bench.kindIs(t, "score") or bench.kindIs(t, "orch_outcome")) return true;
            }
        }
        if (chunk.len > 0 and !skip_long) {
            if (carry_len + chunk.len <= carry.len) {
                @memcpy(carry[carry_len .. carry_len + chunk.len], chunk);
                carry_len += chunk.len;
            } else {
                carry_len = 0;
                skip_long = true;
            }
        }
    }
    if (!skip_long and carry_len > 0) {
        const line = carry[0..carry_len];
        if (folder) |f| f.feedLine(line) else {
            const t = std.mem.trim(u8, line, " \t\r");
            if (bench.kindIs(t, "score") or bench.kindIs(t, "orch_outcome")) return true;
        }
    }
    return false;
}

fn deltaHasScoreOrOrch(io: Io, since_ms: i64) bool {
    var dir = Io.Dir.cwd().openDir(io, trace.trajectories_dir, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (true) {
        const entry = it.next(io) catch break;
        if (entry == null) break;
        if (entry.?.kind != .file or !std.mem.endsWith(u8, entry.?.name, ".jsonl")) continue;
        const st = dir.statFile(io, entry.?.name, .{}) catch continue;
        const ms: i64 = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms));
        if (ms >= since_ms and scanFileLines(io, dir, entry.?.name, null, null)) return true;
    }
    return false;
}

fn decodeCached(arena: Allocator, parsed: PersistedFold) FoldResult {
    g_truncated_obs = parsed.truncated;
    var arms: std.ArrayList(orch.ArmObs) = .empty;
    for (parsed.arms) |ca| {
        const arm = orch.Rung.parse(ca.arm) orelse continue;
        var item: orch.ArmObs = .{
            .key = .{ .task_class = orch.TaskClass.parse(ca.task_class), .budget_band = orch.BudgetBand.parse(ca.budget_band), .stratum = ca.stratum },
            .arm = arm,
            .n = ca.n,
            .sum_score = ca.sum_score,
            .exhausted_n = ca.exhausted_n,
            .landed_n = ca.landed_n,
        };
        const count = @min(ca.calls.len, orch.max_call_samples);
        @memcpy(item.calls[0..count], ca.calls[0..count]);
        item.n_calls = count;
        arms.append(arena, item) catch break;
    }
    return .{ .obs = parsed.obs, .cells = parsed.cells, .arms = arms.items };
}

fn writePersistedFold(io: Io, key: ArchiveKey, res: FoldResult) void {
    if (key.files == 0) return;
    var buf: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const a = fba.allocator();
    var cached_arms: std.ArrayList(CachedArm) = .empty;
    for (res.arms) |arm| {
        cached_arms.append(a, .{
            .task_class = arm.key.task_class.label(),
            .budget_band = arm.key.budget_band.label(),
            .stratum = arm.key.stratum,
            .arm = arm.arm.label(),
            .n = arm.n,
            .sum_score = arm.sum_score,
            .exhausted_n = arm.exhausted_n,
            .landed_n = arm.landed_n,
            .calls = arm.calls[0..arm.n_calls],
        }) catch return;
    }
    const payload: PersistedFold = .{
        .files = key.files,
        .bytes = key.bytes,
        .max_mtime_ms = key.max_mtime_ms,
        .legacy_bytes = key.legacy_bytes,
        .legacy_mtime_ms = key.legacy_mtime_ms,
        .truncated = g_truncated_obs,
        .obs = res.obs,
        .cells = res.cells,
        .arms = cached_arms.items,
    };
    var out: Io.Writer.Allocating = .init(a);
    std.json.Stringify.value(payload, .{}, &out.writer) catch return;
    const file = Io.Dir.cwd().createFile(io, folded_cache_path, .{ .truncate = true }) catch return;
    defer file.close(io);
    file.writeStreamingAll(io, out.writer.buffered()) catch {};
}

pub fn loadPersistedOnly(io: Io, arena: Allocator) ?FoldResult {
    var rbuf: [64 * 1024]u8 = undefined;
    const file = Io.Dir.cwd().openFile(io, folded_cache_path, .{}) catch return null;
    defer file.close(io);
    const n = file.readPositionalAll(io, &rbuf, 0) catch return null;
    if (n == 0 or n == rbuf.len) return null;
    const parsed = std.json.parseFromSliceLeaky(PersistedFold, arena, rbuf[0..n], .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    return decodeCached(arena, parsed);
}

pub fn loadOrFold(io: Io, arena: Allocator) FoldResult {
    const key = statArchiveKey(io);
    if (key.files == 0 and key.legacy_bytes == 0) {
        g_truncated_obs = 0;
        return .{};
    }
    if (Io.Dir.cwd().openFile(io, folded_cache_path, .{})) |file| {
        defer file.close(io);
        var rbuf: [64 * 1024]u8 = undefined;
        if (file.readPositionalAll(io, &rbuf, 0)) |n| {
            if (n > 0 and n < rbuf.len) {
                if (std.json.parseFromSliceLeaky(PersistedFold, arena, rbuf[0..n], .{ .ignore_unknown_fields = true, .allocate = .alloc_always })) |parsed| {
                    const cached_key: ArchiveKey = .{ .files = parsed.files, .bytes = parsed.bytes, .max_mtime_ms = parsed.max_mtime_ms, .legacy_bytes = parsed.legacy_bytes, .legacy_mtime_ms = parsed.legacy_mtime_ms };
                    if (cached_key.eql(key)) return decodeCached(arena, parsed);
                    if (key.files >= cached_key.files and key.bytes >= cached_key.bytes and key.max_mtime_ms >= cached_key.max_mtime_ms and
                        key.legacy_bytes == cached_key.legacy_bytes and key.legacy_mtime_ms == cached_key.legacy_mtime_ms and !deltaHasScoreOrOrch(io, cached_key.max_mtime_ms))
                    {
                        const res = decodeCached(arena, parsed);
                        writePersistedFold(io, key, res);
                        return res;
                    }
                } else |_| {}
            }
        } else |_| {}
    } else |_| {}

    g_truncated_obs = 0;
    var scratch_buf: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch_buf);
    var folder: Folder = .{ .arena = arena, .sa = fba.allocator() };
    var remaining: usize = max_archive_bytes;
    if (Io.Dir.cwd().openDir(io, trace.trajectories_dir, .{ .iterate = true })) |dir_val| {
        var dir = dir_val;
        defer dir.close(io);
        var it = dir.iterate();
        while (remaining > 0) {
            const entry = it.next(io) catch break;
            if (entry == null) break;
            if (entry.?.kind != .file or !std.mem.endsWith(u8, entry.?.name, ".jsonl")) continue;
            _ = scanFileLines(io, dir, entry.?.name, &remaining, &folder);
        }
    } else |_| {}
    _ = scanFileLines(io, Io.Dir.cwd(), trace.legacy_trajectory_path, &remaining, &folder);
    const res = folder.finish();
    writePersistedFold(io, key, res);
    return res;
}
