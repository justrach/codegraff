//! /trajectory (#602): the DGM fitness archive rendered for a human — each
//! turn with what it DID (model calls, tool count, errors, cache hit, response
//! shape), its subagent children, and any recorded scores. Split out of
//! commands_session.zig (600-line ceiling); same tryHandle contract.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const trace = @import("trace.zig");
const util = @import("util.zig");
const utf8Prefix = util.utf8Prefix;

const ansi = @import("ansi.zig");
const style = &ansi.style;

/// Handles only "/trajectory"; anything else returns false untouched.
pub fn tryHandle(root: *Agent, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    if (!std.mem.eql(u8, line, "/trajectory")) return false;
    const data = trace.readTrajectoryArchive(root.io, arena, 4 << 20);
    const S = struct {
        fn str(o: std.json.ObjectMap, k: []const u8) []const u8 {
            const v = o.get(k) orelse return "";
            return if (v == .string) v.string else "";
        }
        fn int(o: std.json.ObjectMap, k: []const u8) i64 {
            const v = o.get(k) orelse return 0;
            return if (v == .integer) v.integer else 0;
        }
        fn flag(o: std.json.ObjectMap, k: []const u8) bool {
            const v = o.get(k) orelse return false;
            return v == .bool and v.bool;
        }
        /// A tools bag is comma-joined names ("bash,bash,read_file").
        fn bagCount(bag: []const u8) usize {
            if (bag.len == 0) return 0;
            var n: usize = 1;
            for (bag) |c| {
                if (c == ',') n += 1;
            }
            return n;
        }
        /// Cache-hit percent from the node's token counters, null when the
        /// turn recorded none.
        fn cachePercent(cache_read: i64, uncached: i64) ?u32 {
            const total = cache_read + uncached;
            if (total <= 0 or cache_read < 0) return null;
            return @intCast(@divTrunc(cache_read * 100, total));
        }
        // Latest score recorded for a prompt fingerprint, across the
        // whole archive (scores persist between sessions).
        fn scoreFor(all: []const std.json.ObjectMap, sha: []const u8) ?f64 {
            var found: ?f64 = null;
            for (all) |o| {
                if (!std.mem.eql(u8, str(o, "kind"), "score")) continue;
                if (!std.mem.eql(u8, str(o, "prompt_sha"), sha)) continue;
                const v = o.get("score") orelse continue;
                found = switch (v) {
                    .float => |x| x,
                    .integer => |x| @floatFromInt(x),
                    else => found,
                };
            }
            return found;
        }
    };
    var objs: std.ArrayList(std.json.ObjectMap) = .empty;
    var it = std.mem.tokenizeScalar(u8, data, '\n');
    while (it.next()) |ln| {
        const v = std.json.parseFromSliceLeaky(Value, arena, ln, .{ .allocate = .alloc_always }) catch continue;
        if (v == .object) objs.append(arena, v.object) catch {};
    }
    // Tree shows this invocation; scores still come from the whole archive.
    const current_run_id = if (root.tracer) |tr| tr.identity.run_id else if (trace.g_traj) |tj| tj.identity.run_id else "";
    var turns: usize = 0;
    for (objs.items) |o| {
        if (!std.mem.eql(u8, S.str(o, "run_id"), current_run_id)) continue;
        if (std.mem.eql(u8, S.str(o, "kind"), "turn")) turns += 1;
    }
    if (turns == 0) {
        try out.print("no trajectory recorded yet — run a turn first (current file: {s})\n", .{if (trace.g_traj) |tj| tj.path else trace.trajectories_dir});
        try out.flush();
        return true;
    }
    try out.print("{s}session trajectory{s} — {d} turn(s); current: {s}; archive: {s} ({d} record(s) total)\n", .{ style.bold, style.reset, turns, if (trace.g_traj) |tj| tj.path else "", trace.trajectories_dir, objs.items.len });
    for (objs.items) |o| {
        if (!std.mem.eql(u8, S.str(o, "run_id"), current_run_id)) continue;
        if (!std.mem.eql(u8, S.str(o, "kind"), "turn")) continue;
        const turn_id = S.int(o, "id");
        out.print("{s}●{s} turn {d} {s} {d}ms · prompt {s}{s}{s}{s} · {s}", .{
            style.accent,
            style.reset,
            turn_id,
            if (S.flag(o, "ok")) "✓" else "✗",
            S.int(o, "ms"),
            style.dim,
            S.str(o, "prompt_sha"),
            if (S.flag(o, "prompt_mutated")) " (mutated)" else "",
            style.reset,
            utf8Prefix(S.str(o, "task"), 80),
        }) catch {};
        if (S.scoreFor(objs.items, S.str(o, "prompt_sha"))) |sc|
            out.print(" {s}· score {d:.2}{s}", .{ style.green, sc, style.reset }) catch {};
        // #602: the node already carries what the turn DID — print it
        // instead of leaving the row a prompt sha and a task prefix.
        {
            const calls = S.int(o, "model_calls");
            const tool_n = S.bagCount(S.str(o, "tools"));
            const errs = S.int(o, "tool_errors");
            const resp_types = S.str(o, "resp_types");
            const hit = S.cachePercent(S.int(o, "cache_read_tokens"), S.int(o, "uncached_tokens"));
            if (calls > 0 or tool_n > 0 or errs > 0 or resp_types.len > 0 or hit != null) {
                out.print(" {s}·", .{style.dim}) catch {};
                if (calls > 0) out.print(" {d} call{s}", .{ calls, if (calls == 1) "" else "s" }) catch {};
                if (tool_n > 0) out.print(" · {d} tool{s}", .{ tool_n, if (tool_n == 1) "" else "s" }) catch {};
                if (errs > 0) out.print(" · {d} err", .{errs}) catch {};
                if (hit) |h| out.print(" · cache {d}%", .{h}) catch {};
                if (resp_types.len > 0) out.print(" · {s}", .{resp_types}) catch {};
                out.print("{s}", .{style.reset}) catch {};
            }
        }
        out.writeAll("\n") catch {};
        // children: subagents / workflow tasks spawned during this turn
        var remaining: usize = 0;
        for (objs.items) |c| {
            if (!std.mem.eql(u8, S.str(c, "run_id"), current_run_id)) continue;
            if (S.int(c, "parent") == turn_id and !std.mem.eql(u8, S.str(c, "kind"), "turn")) remaining += 1;
        }
        for (objs.items) |c| {
            if (!std.mem.eql(u8, S.str(c, "run_id"), current_run_id)) continue;
            if (S.int(c, "parent") != turn_id or std.mem.eql(u8, S.str(c, "kind"), "turn")) continue;
            remaining -= 1;
            out.print("  {s} {s} {s} {d}ms · prompt {s}{s}{s}{s} · {s}", .{
                if (remaining == 0) "└─" else "├─",
                S.str(c, "label"),
                if (S.flag(c, "ok")) "✓" else "✗",
                S.int(c, "ms"),
                style.dim,
                S.str(c, "prompt_sha"),
                if (S.flag(c, "prompt_mutated")) " (variant)" else "",
                style.reset,
                utf8Prefix(S.str(c, "task"), 70),
            }) catch {};
            if (S.scoreFor(objs.items, S.str(c, "prompt_sha"))) |sc|
                out.print(" {s}· score {d:.2}{s}", .{ style.green, sc, style.reset }) catch {};
            out.writeAll("\n") catch {};
        }
    }
    try out.flush();
    return true;
}
