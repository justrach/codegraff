//! GRAFF_REQ_STATS=1 request anatomy (the token-diet program's measurement
//! hook): per-call body/tools/system byte split. GRAFF_REQ_DUMP_DIR opts into
//! private per-run body and system dumps for
//! byte-diffing consecutive requests (cache-prefix forensics), a one-time
//! system-prompt dump for offline segment attribution (#476), and the
//! per-server tools split with the top-5 native specs. All output is stderr,
//! never json_mode's stdout. Extracted from agent_request.zig to keep that
//! file under the 600-line ceiling.

const std = @import("std");
const Io = std.Io;

/// Set once at startup by session_settings.applyEnvKnobs (GRAFF_REQ_STATS).
pub var g_armed = false;
pub var g_dump_dir: ?[]const u8 = null;
var dump_state: Dump = .{};

/// Startup-only: configuration owns no handles and uses the session arena.
pub fn configure(arena: std.mem.Allocator, armed: bool, directory: ?[]const u8) !void {
    const path = if (directory) |d| std.mem.trim(u8, d, " \t\r\n") else "";
    const owned = if (path.len == 0) null else try arena.dupe(u8, path);
    g_armed = armed;
    g_dump_dir = owned;
    dump_state = .{};
}

const Dump = struct {
    mutex: Io.Mutex = .init,
    path: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    seq: usize = 0,
    system_written: bool = false,

    fn write(self: *Dump, io: Io, root: []const u8, body: []const u8, system: []const u8) !void {
        const private = @import("credential_store.zig");
        if (self.path_len == 0) {
            _ = try Io.Dir.cwd().createDirPathStatus(io, root, private.private_dir);
            var nonce: [16]u8 = undefined;
            io.random(&nonce);
            const hex = std.fmt.bytesToHex(nonce, .lower);
            const path = try std.fmt.bufPrint(&self.path, "{s}/run-{s}", .{ root, hex });
            try Io.Dir.cwd().createDir(io, path, private.private_dir);
            self.path_len = path.len;
            std.debug.print("  [req] dump_dir={s}\n", .{path});
        }
        var dir = try Io.Dir.cwd().openDir(io, self.path[0..self.path_len], .{});
        defer dir.close(io);
        self.seq += 1;
        var name: [64]u8 = undefined;
        try writePrivate(io, dir, try std.fmt.bufPrint(&name, "body-{d:0>3}.json", .{self.seq}), body);
        if (!self.system_written) {
            try writePrivate(io, dir, "system.txt", system);
            self.system_written = true;
        }
    }

    fn writePrivate(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
        const file = try dir.createFile(io, name, .{ .exclusive = true, .permissions = @import("credential_store.zig").private_file });
        defer file.close(io);
        try file.writePositionalAll(io, bytes, 0);
    }
};

pub fn report(io: Io, body: []const u8, tools: ?[]const u8, sys_normal: []const u8) void {
    if (!g_armed) return;
    std.debug.print("  [req] body={d}B tools={d}B system={d}B messages~={d}B\n", .{ body.len, if (tools) |t| t.len else 0, sys_normal.len, body.len -| (if (tools) |t| t.len else 0) -| sys_normal.len });
    if (g_dump_dir) |root| {
        dump_state.mutex.lockUncancelable(io);
        defer dump_state.mutex.unlock(io);
        dump_state.write(io, root, body, sys_normal) catch |err| {
            std.debug.print("  [req] dump failed: {s}\n", .{@errorName(err)});
        };
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

test "request dumps isolate configured runs and preserve emitted JSON privately" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const saved_armed = g_armed;
    const saved_dir = g_dump_dir;
    const saved_state = dump_state;
    defer {
        g_armed = saved_armed;
        g_dump_dir = saved_dir;
        dump_state = saved_state;
    }
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try temp.dir.realPath(io, &root_buffer)];
    var agent = try @import("agent_request_body_responses.zig").testAgentFor(arena, "codegraff", .openai, "mimo-v2.5");
    const body = try agent.buildBody(null, false, true, true);
    defer a.free(body);
    var paths: [3][]const u8 = undefined;
    for (0..3) |i| {
        // The third invocation deliberately reuses the first output root.
        const destination = try std.fmt.allocPrint(arena, "{s}/output-{d}", .{ root, i % 2 });
        try configure(arena, true, destination);
        report(io, body, null, agent.sys_normal);
        paths[i] = try arena.dupe(u8, dump_state.path[0..dump_state.path_len]);
        var dir = try Io.Dir.cwd().openDir(io, paths[i], .{});
        defer dir.close(io);
        const bytes = try dir.readFileAlloc(io, "body-001.json", arena, .limited(1024 * 1024));
        try std.testing.expectEqualStrings(body, bytes);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
        try std.testing.expectEqualStrings(agent.provider.model, parsed.object.get("model").?.string);
        const system = try dir.readFileAlloc(io, "system.txt", arena, .limited(1024 * 1024));
        try std.testing.expectEqualStrings(agent.sys_normal, system);
        if (@import("builtin").os.tag != .windows) {
            try std.testing.expectEqual(@as(u32, 0o700), (try dir.stat(io)).permissions.toMode() & 0o777);
            try std.testing.expectEqual(@as(u32, 0o600), (try dir.statFile(io, "body-001.json", .{})).permissions.toMode() & 0o777);
            try std.testing.expectEqual(@as(u32, 0o600), (try dir.statFile(io, "system.txt", .{})).permissions.toMode() & 0o777);
        }
    }
    try std.testing.expect(!std.mem.eql(u8, paths[0], paths[2]));
    for (paths) |path| {
        const file = try std.fmt.allocPrint(arena, "{s}/body-001.json", .{path});
        try std.testing.expectEqualStrings(body, try Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(1024 * 1024)));
    }
    // Statistics alone must not create an implicit shared dump destination.
    try configure(arena, true, null);
    report(io, body, null, agent.sys_normal);
    try std.testing.expectEqual(@as(usize, 0), dump_state.path_len);
    try std.testing.expectEqual(@as(usize, 0), dump_state.seq);
}
