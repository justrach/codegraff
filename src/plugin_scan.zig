//! Timed, once-per-process plugin discover (ADR 0007).
//!
//! Startup used to walk Cursor/Claude/Grok trees three times (MCP merge, fleet
//! agents, skill catalog). Production keeps the first walk and copies it;
//! tests stay live so parallel cases cannot share a slot. `/plugins` and the
//! interactive boot line print the wall time so a slow home directory is
//! visible instead of a silent minute.

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const plugins = @import("plugins.zig");
const layout = @import("plugin_layout.zig");

pub const Stats = struct {
    ms: i64 = 0,
    first_ms: i64 = 0,
    n: usize = 0,
    visits: usize = 0,
    cached: bool = false,
};

pub var last: Stats = .{};

var lock: std.atomic.Value(bool) = .init(false);
var ready = false;
var inited = false;
var store: std.heap.ArenaAllocator = undefined;
var cached: []const plugins.Plugin = &.{};
var home_buf: [std.fs.max_path_bytes]u8 = undefined;
var home_len: usize = 0;
var proj_buf: [std.fs.max_path_bytes]u8 = undefined;
var proj_len: usize = 0;
var first_ms: i64 = 0;
var first_visits: usize = 0;

fn acquire() void {
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn release() void {
    lock.store(false, .release);
}

pub fn invalidate() void {
    if (builtin.is_test) return;
    acquire();
    defer release();
    ready = false;
}

fn elapsedMs(start: Io.Timestamp, io: Io) i64 {
    return @intCast(@max(0, start.untilNow(io, .awake).toMilliseconds()));
}

fn dup(arena: Allocator, s: []const u8) []const u8 {
    if (s.len == 0) return "";
    return arena.dupe(u8, s) catch "";
}

fn dupDirs(arena: Allocator, src: []const []const u8) []const []const u8 {
    if (src.len == 0) return &.{};
    const out = arena.alloc([]const u8, src.len) catch return &.{};
    for (src, 0..) |d, i| out[i] = dup(arena, d);
    return out;
}

fn copyPlugin(arena: Allocator, p: plugins.Plugin) plugins.Plugin {
    var root: ?layout.RootSkill = null;
    if (p.root_skill) |rs| {
        root = .{ .path = dup(arena, rs.path), .name = dup(arena, rs.name), .dir = dup(arena, rs.dir) };
    }
    return .{
        .name = dup(arena, p.name),
        .path = dup(arena, p.path),
        .origin = dup(arena, p.origin),
        .personal = p.personal,
        .skills = p.skills,
        .agents = p.agents,
        .mcp = p.mcp,
        .commands = p.commands,
        .skill_dirs = dupDirs(arena, p.skill_dirs),
        .agent_dirs = dupDirs(arena, p.agent_dirs),
        .root_skill = root,
    };
}

fn copyList(arena: Allocator, src: []const plugins.Plugin) []const plugins.Plugin {
    var out: std.ArrayList(plugins.Plugin) = .empty;
    for (src) |p| out.append(arena, copyPlugin(arena, p)) catch {};
    return out.items;
}

fn setKey(home: []const u8, proj: []const u8) void {
    const h = home[0..@min(home.len, home_buf.len)];
    const p = proj[0..@min(proj.len, proj_buf.len)];
    @memcpy(home_buf[0..h.len], h);
    home_len = h.len;
    @memcpy(proj_buf[0..p.len], p);
    proj_len = p.len;
}

fn keyMatch(home: []const u8, proj: []const u8) bool {
    return std.mem.eql(u8, home_buf[0..home_len], home) and std.mem.eql(u8, proj_buf[0..proj_len], proj);
}

/// One-line receipt for `/plugins` and the interactive boot notice.
pub fn formatStats(arena: Allocator, s: Stats) []const u8 {
    if (s.cached)
        return std.fmt.allocPrint(arena, "{d} plugin(s) in {d}ms (cached, first scan {d}ms, {d} dirs)", .{
            s.n, s.ms, s.first_ms, s.visits,
        }) catch "";
    return std.fmt.allocPrint(arena, "{d} plugin(s) in {d}ms ({d} dirs)", .{ s.n, s.ms, s.visits }) catch "";
}

pub fn format(arena: Allocator) []const u8 {
    return formatStats(arena, last);
}

pub fn discover(io: Io, arena: Allocator, home: ?[]const u8, project: Io.Dir) []const plugins.Plugin {
    const start = Io.Timestamp.now(io, .awake);
    const home_s = home orelse "";
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const pn = project.realPath(io, &pbuf) catch 0;
    const proj_s = pbuf[0..pn];

    if (!builtin.is_test) {
        acquire();
        if (ready and keyMatch(home_s, proj_s)) {
            const list = copyList(arena, cached);
            release();
            last = .{
                .ms = elapsedMs(start, io),
                .first_ms = first_ms,
                .n = list.len,
                .visits = first_visits,
                .cached = true,
            };
            return list;
        }
        release();
    }

    const list = plugins.discoverFresh(io, arena, home, project);
    const took = elapsedMs(start, io);
    last = .{
        .ms = took,
        .first_ms = took,
        .n = list.len,
        .visits = plugins.last_visits,
        .cached = false,
    };

    if (!builtin.is_test) {
        acquire();
        defer release();
        if (!inited) {
            store = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            inited = true;
        } else {
            _ = store.reset(.retain_capacity);
        }
        cached = copyList(store.allocator(), list);
        setKey(home_s, proj_s);
        first_ms = took;
        first_visits = plugins.last_visits;
        ready = true;
    }
    return list;
}

const testing = std.testing;

test "format: uncached vs cached wording names the milliseconds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("3 plugin(s) in 12ms (40 dirs)", formatStats(arena, .{
        .ms = 12,
        .first_ms = 12,
        .n = 3,
        .visits = 40,
        .cached = false,
    }));
    try testing.expectEqualStrings("3 plugin(s) in 1ms (cached, first scan 840ms, 40 dirs)", formatStats(arena, .{
        .ms = 1,
        .first_ms = 840,
        .n = 3,
        .visits = 40,
        .cached = true,
    }));
}

test "discover: empty tmp home is zero plugins and the listing names milliseconds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const home = std.fmt.allocPrint(arena, "{s}/home", .{buf[0..n]}) catch return error.OutOfMemory;
    const list = plugins.discover(io, arena, home, tmp.dir);
    try testing.expectEqual(@as(usize, 0), list.len);

    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try testing.expect(try plugins.slashCommand(io, arena, home, "/plugins", &aw.writer));
    try testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "ms") != null);
}
