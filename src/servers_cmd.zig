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

pub fn command(gpa: Allocator, io: Io, arena: Allocator, args: []const []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    const out = &w.interface;
    defer out.flush() catch {};
    const home = job_registry.home;
    if (home.len == 0) return out.writeAll("graff servers: no HOME, so no job records\n");
    const action = if (args.len > 0) args[0] else "list";
    const recs = job_registry.list(io, arena, home);

    if (std.mem.eql(u8, action, "list") or std.mem.eql(u8, action, "ls")) {
        if (recs.len == 0) return out.writeAll("no background servers on record — graff writes one per background job it starts (~/.codegraff/jobs)\n");
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
        return out.writeAll("graff servers stop <pid> ends one (its whole process group); graff servers prune drops records of dead ones\n");
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
        return out.print("no record of pid {d} — only jobs graff started can be stopped here; graff servers lists them\n", .{pid});
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

    try out.print("unknown servers command '{s}' — use: graff servers [list | stop <pid> | prune]\n", .{action});
}
