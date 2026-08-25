//! Mid-stream spec-ptc cache for `rlm`. Leaf on purpose: the SSE / ArgLive
//! path must feed closed lines without importing exec.zig (that would cycle
//! through Agent). `run_host` is installed by rlm.zig once `--rlm` is on.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const spec_ptc = @import("spec_ptc.zig");
const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;

pub var available: bool = false;
pub var run_host: ?*const fn (ToolCtx, spec_ptc.Call) ToolOutput = null;

/// Cheap discovery while the full spec stays folded (ADR 0022). Startup
/// splices this only when `--rlm` is on.
pub const system_note = "\n\nrlm(code) is available: a short script whose functions are this session's tools. Independent read_file/codedb/bash/llm_query calls with literal args start in parallel as the script streams. Prefer one rlm script over N separate tool calls when the work does not depend on itself. Semicolons or newlines separate statements; print(...) is the answer.";

const Inflight = struct {
    fut: Io.Future(ToolOutput),
    key: []u8,
    name: []u8,
    args: []u8,
};

const Live = struct {
    mu: Io.Mutex = .init,
    ready: bool = false,
    seg: spec_ptc.Segmenter = .{},
    launched: std.StringHashMap(void) = undefined,
    inflight: std.ArrayList(Inflight) = .empty,
    done: std.StringHashMap(ToolOutput) = undefined,
};

var live: Live = .{};

pub fn resetLive(gpa: Allocator, io: Io) void {
    live.mu.lockUncancelable(io);
    defer live.mu.unlock(io);
    resetUnlocked(gpa, io);
}

pub fn feedLive(ctx: ToolCtx, delta: []const u8) void {
    if (!available or delta.len == 0) return;
    live.mu.lockUncancelable(ctx.io);
    defer live.mu.unlock(ctx.io);
    liveInit(ctx.gpa);
    const stmts = live.seg.feed(ctx.gpa, delta) catch return;
    defer {
        for (stmts) |s| ctx.gpa.free(s);
        ctx.gpa.free(stmts);
    }
    launchStmts(ctx, stmts);
}

pub fn takeLive(ctx: ToolCtx, claimed: *std.StringHashMap(ToolOutput), arena: Allocator) void {
    live.mu.lockUncancelable(ctx.io);
    defer live.mu.unlock(ctx.io);
    if (!live.ready) return;
    const tail = live.seg.finish(ctx.gpa) catch &.{};
    defer {
        for (tail) |s| ctx.gpa.free(s);
        if (tail.len > 0) ctx.gpa.free(tail);
    }
    launchStmts(ctx, tail);
    absorbUnlocked(ctx.gpa, ctx.io);
    var dit = live.done.iterator();
    while (dit.next()) |e| {
        const key = arena.dupe(u8, e.key_ptr.*) catch {
            ctx.gpa.free(e.value_ptr.text);
            ctx.gpa.free(e.key_ptr.*);
            continue;
        };
        claimed.put(key, e.value_ptr.*) catch {
            ctx.gpa.free(e.value_ptr.text);
            ctx.gpa.free(e.key_ptr.*);
            continue;
        };
        ctx.gpa.free(e.key_ptr.*);
    }
    live.done.clearRetainingCapacity();
    live.launched.clearRetainingCapacity();
    live.seg.deinit(ctx.gpa);
    live.seg = .{};
}

fn liveInit(gpa: Allocator) void {
    if (live.ready) return;
    live.launched = .init(gpa);
    live.done = .init(gpa);
    live.ready = true;
}

fn resetUnlocked(gpa: Allocator, io: Io) void {
    if (live.ready) {
        absorbUnlocked(gpa, io);
        var dit = live.done.iterator();
        while (dit.next()) |e| {
            gpa.free(e.value_ptr.text);
            gpa.free(e.key_ptr.*);
        }
        live.done.deinit();
        live.launched.deinit();
        live.inflight.deinit(gpa);
        live.inflight = .empty;
        live.ready = false;
    }
    live.seg.deinit(gpa);
    live.seg = .{};
}

fn runHostThunk(ctx: ToolCtx, call: spec_ptc.Call) ToolOutput {
    if (run_host) |f| return f(ctx, call);
    return .{ .text = ctx.gpa.dupe(u8, "rlm: host not installed") catch &.{}, .is_error = true };
}

fn launchStmts(ctx: ToolCtx, stmts: []const []const u8) void {
    if (run_host == null) return;
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (stmts) |stmt| {
        const pieces = spec_ptc.splitStatements(arena, stmt) catch continue;
        for (pieces) |piece| {
            launchOne(ctx, arena, piece);
        }
    }
}

fn launchOne(ctx: ToolCtx, arena: Allocator, stmt: []const u8) void {
    if (run_host == null) return;
    const call = (spec_ptc.extractCall(arena, stmt) catch return) orelse return;
    const key = call.key(arena) catch return;
    if (live.launched.contains(key) or live.done.contains(key)) return;
    const owned_key = ctx.gpa.dupe(u8, key) catch return;
    const owned_name = ctx.gpa.dupe(u8, call.name) catch {
        ctx.gpa.free(owned_key);
        return;
    };
    const owned_args = ctx.gpa.dupe(u8, call.args_json) catch {
        ctx.gpa.free(owned_key);
        ctx.gpa.free(owned_name);
        return;
    };
    live.launched.put(owned_key, {}) catch {
        ctx.gpa.free(owned_key);
        ctx.gpa.free(owned_name);
        ctx.gpa.free(owned_args);
        return;
    };
    const owned: spec_ptc.Call = .{ .name = owned_name, .args_json = owned_args };
    const fut = ctx.io.async(runHostThunk, .{ ctx, owned });
    live.inflight.append(ctx.gpa, .{ .fut = fut, .key = owned_key, .name = owned_name, .args = owned_args }) catch {};
}

fn absorbUnlocked(gpa: Allocator, io: Io) void {
    for (live.inflight.items) |*item| {
        const out = item.fut.await(io);
        gpa.free(item.name);
        gpa.free(item.args);
        live.done.put(item.key, out) catch {
            gpa.free(out.text);
            gpa.free(item.key);
        };
    }
    live.inflight.clearRetainingCapacity();
}
