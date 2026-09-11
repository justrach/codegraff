//! `graff servers [stop <pid>|prune]` (#199): every background server graff
//! started — this session's and earlier ones' — from the ownership records
//! in ~/.codegraff/jobs. `stop <pid>` ends a tree only after the leader's
//! start identity matches its record, so a recycled pid is never signalled;
//! `prune` drops records whose process is gone.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const job_registry = @import("job_registry.zig");
const tool_pulse = @import("tool_pulse.zig");
const util = @import("util.zig");
const discovery = @import("server_discovery.zig");

pub fn command(gpa: Allocator, io: Io, arena: Allocator, args: []const []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    const out = &w.interface;
    defer out.flush() catch {};
    const home = job_registry.home;
    if (home.len == 0) try out.writeAll("graff servers: no HOME, so no job records (discovery still available)\n");
    const action = if (args.len > 0) args[0] else "list";
    const recs = if (home.len == 0) &.{} else job_registry.list(io, arena, home);

    if (std.mem.eql(u8, action, "list") or std.mem.eql(u8, action, "ls")) {
        if (recs.len == 0) try out.writeAll("no background servers on record — checking suspected orphan listeners\n");
        const now = util.unixMs(io);
        try out.writeAll("pid      state     age      owner  port(s)               command\n");
        for (recs) |rec| {
            const st = job_registry.state(io, rec);
            var abuf: [16]u8 = undefined;
            const age = tool_pulse.formatElapsed(&abuf, @intCast(@max(now - rec.started_ms, 0)));
            const owner: []const u8 = if (job_registry.ownerAlive(io, rec)) "live" else "gone";
            const ports = if (st == .running) job_registry.listenPorts(gpa, io, arena, rec.pid) else "";
            const state_s: []const u8 = switch (st) {
                .running => if (rec.retained) "retained" else if (rec.pinned) "pinned" else "running",
                .gone => "gone",
                .unverifiable => "unknown",
            };
            try out.print("{d:<8} {s:<9} {s:<8} {s:<6} {s:<21} {s}", .{ rec.pid, state_s, age, owner, ports, util.utf8Prefix(rec.cmd, 60) });
            if (rec.cwd.len > 0) try out.print("  ({s})", .{rec.cwd});
            try out.writeAll("\n");
        }
        const found = discovery.scan(gpa, io, arena) catch |err| {
            try out.print("orphan discovery unavailable/incomplete: {s}; listener status is unknown\n", .{@errorName(err)});
            return;
        };
        for (found.candidates) |candidate| {
            var recorded = false;
            for (recs) |rec| {
                if (rec.pid == candidate.pid and job_registry.state(io, rec) == .running) recorded = true;
            }
            if (!recorded) {
                try out.print("{d:<8} suspected orphan listener (listener pid {d}); origin unverified\n", .{ candidate.pid, candidate.listener });
                if (@import("server_orphan.zig").capture(io, candidate.pid)) |snapshot| {
                    var token: [80]u8 = undefined;
                    try out.print("  After inspecting this process, explicitly stop this snapshot with: graff servers stop-suspect {d} {s}\n", .{ candidate.pid, try snapshot.token(&token) });
                }
            }
        }
        if (found.incomplete) try out.writeAll("orphan discovery incomplete: inspection limit or process query failed; listener status is unknown\n");
        try out.writeAll("Suspects are never adopted or automatically stopped. stop-suspect requires the displayed identity token and revalidates start, executable and process group.\n");
        return out.writeAll("graff servers stop <pid> ends a verified recorded job only; graff servers prune drops dead records\n");
    }

    if (std.mem.eql(u8, action, "stop-suspect")) {
        if (args.len != 3) return out.writeAll("usage: graff servers stop-suspect <pid> <identity-token-from-list>\n");
        const pid = std.fmt.parseInt(i32, args[1], 10) catch return out.writeAll("invalid pid; no process stopped\n");
        const found = discovery.scan(gpa, io, arena) catch return out.writeAll("discovery unavailable; no process stopped\n");
        for (found.candidates) |candidate| {
            if (candidate.pid != pid) continue;
            const orphan = @import("server_orphan.zig");
            const snapshot = orphan.capture(io, pid) orelse return out.writeAll("identity unavailable; no process stopped\n");
            const result = orphan.stop(io, snapshot, args[2]);
            return out.print("legacy listener stop: {s}; no ownership record created\n", .{@tagName(result)});
        }
        return out.writeAll("pid is no longer a discovered same-user orphan listener; no process stopped\n");
    }

    if (std.mem.eql(u8, action, "stop")) {
        if (args.len < 2) return out.writeAll("usage: graff servers stop <pid>\n");
        const pid = std.fmt.parseInt(i32, args[1], 10) catch return out.print("graff servers stop: '{s}' is not a pid\n", .{args[1]});
        for (recs) |rec| {
            if (rec.pid != pid) continue;
            switch (job_registry.stopTree(io, rec)) {
                .stopped => {
                    job_registry.forget(io, home, pid);
                    try out.print("✓ stopped pid {d} and its process group: {s}\n", .{ pid, rec.cmd });
                },
                .gone => {
                    job_registry.forget(io, home, pid);
                    try out.print("pid {d} is already gone (record dropped)\n", .{pid});
                },
                .unverifiable => try out.print("✗ pid {d} could not be verified as the job graff started — not touched\n", .{pid}),
                .unsupported => try out.writeAll("✗ graff servers stop is not available on this platform\n"),
            }
            return;
        }
        return out.print("no record of pid {d} — use servers list to inspect suspected listeners and obtain an explicit stop-suspect identity token\n", .{pid});
    }

    if (std.mem.eql(u8, action, "prune")) {
        var dropped: usize = 0;
        for (recs) |rec| {
            if (job_registry.state(io, rec) != .gone) continue;
            job_registry.forget(io, home, rec.pid);
            dropped += 1;
        }
        return out.print("✓ dropped {d} record(s) of servers that are gone\n", .{dropped});
    }

    try out.print("unknown servers command '{s}' — use: graff servers [list | stop <pid> | stop-suspect <pid> <identity-token> | prune]\n", .{action});
}
