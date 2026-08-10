//! GRAFF_REQ_STATS=1 request anatomy (the token-diet program's measurement
//! hook): per-call body/tools/system byte split, a per-call body dump for
//! byte-diffing consecutive requests (cache-prefix forensics), a one-time
//! system-prompt dump for offline segment attribution (#476), and the
//! per-server tools split with the top-5 native specs. All output is stderr,
//! never json_mode's stdout. Extracted from agent_request.zig to keep that
//! file under the 600-line ceiling.

const std = @import("std");
const Io = std.Io;

/// Set once at startup by session_settings.applyEnvKnobs (GRAFF_REQ_STATS).
pub var g_armed = false;

pub fn report(io: Io, body: []const u8, tools: ?[]const u8, sys_normal: []const u8) void {
    if (!g_armed) return;
    std.debug.print("  [req] body={d}B tools={d}B system={d}B messages~={d}B\n", .{ body.len, if (tools) |t| t.len else 0, sys_normal.len, body.len -| (if (tools) |t| t.len else 0) -| sys_normal.len });
    // Per-call body dump, for byte-diffing consecutive requests.
    const dump_seq = struct {
        var n: usize = 0;
    };
    dump_seq.n += 1;
    var dpath: [64]u8 = undefined;
    if (std.fmt.bufPrint(&dpath, "/tmp/graff-body-{d:0>3}.json", .{dump_seq.n})) |p| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = body }) catch {};
    } else |_| {}
    // One dump per process: the assembled system prompt.
    const dumped = struct {
        var done: bool = false;
    };
    if (!dumped.done and sys_normal.len > 10_000) {
        dumped.done = true;
        Io.Dir.cwd().writeFile(io, .{ .sub_path = "/tmp/graff-sys.txt", .data = sys_normal }) catch {};
    }
    // Per-server split: attribute each tool's serialized span by its name
    // prefix (next-"name" boundary ≈ tool size, ±separators).
    if (tools) |t| {
        var cdbp: usize = 0;
        var other_mcp: usize = 0;
        var native: usize = 0;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, t, pos, "\"name\":\"")) |n| {
            const name_start = n + 8;
            const name_end = std.mem.indexOfScalarPos(u8, t, name_start, '"') orelse break;
            const next = std.mem.indexOfPos(u8, t, name_end, "\"name\":\"") orelse t.len;
            const span = next - n;
            const nm = t[name_start..name_end];
            if (std.mem.startsWith(u8, nm, "mcp__codedbpro__")) cdbp += span else if (std.mem.startsWith(u8, nm, "mcp__")) other_mcp += span else native += span;
            pos = name_end;
        }
        std.debug.print("  [req]   tools split: native={d}B codedbpro={d}B other_mcp={d}B\n", .{ native, cdbp, other_mcp });
        // Top-5 largest native specs — the deferral candidates list.
        var sizes: [64]struct { span: usize, at: usize } = undefined;
        var n_sizes: usize = 0;
        pos = 0;
        while (std.mem.indexOfPos(u8, t, pos, "\"name\":\"")) |n2| {
            const ns = n2 + 8;
            const ne = std.mem.indexOfScalarPos(u8, t, ns, '"') orelse break;
            const nxt = std.mem.indexOfPos(u8, t, ne, "\"name\":\"") orelse t.len;
            if (!std.mem.startsWith(u8, t[ns..ne], "mcp__") and n_sizes < sizes.len) {
                sizes[n_sizes] = .{ .span = nxt - n2, .at = ns };
                n_sizes += 1;
            }
            pos = ne;
        }
        var top: usize = 0;
        while (top < 5 and top < n_sizes) : (top += 1) {
            var bi: usize = 0;
            for (sizes[0..n_sizes], 0..) |sz, j| if (sz.span > sizes[bi].span) {
                bi = j;
            };
            const nm = t[sizes[bi].at .. std.mem.indexOfScalarPos(u8, t, sizes[bi].at, '"') orelse sizes[bi].at];
            std.debug.print("  [req]     {s}: {d}B\n", .{ nm, sizes[bi].span });
            sizes[bi].span = 0;
        }
    }
}
