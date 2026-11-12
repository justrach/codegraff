//! The REPL banner's update notice reads a disk cache; it never fetches.
//!
//! The banner used to GET GitHub's latest-release endpoint on every launch,
//! which held the interactive banner for ~300 ms on a normal network. Now it
//! renders the notice from `~/.graff/update-check.json` (the last release tag
//! seen and when) and, when that file is missing, unreadable, or older than
//! `ttl_ms`, refreshes it on a detached thread. The refresh follows
//! `catalog_bounded.zig`: a private Io and allocator, nothing waits for it,
//! exit never joins it, and its only output is the cache file, written
//! atomically. A new release therefore shows its notice one launch late.
//!
//! The explicit commands (`graff update`, `/version`) still fetch live and
//! write the tag they saw here (`remember`).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const version_status = @import("version_status.zig");
const credential_store = @import("credential_store.zig");
const util = @import("util.zig");

/// A cached tag younger than this is used without a refresh.
pub const ttl_ms: i64 = 24 * 60 * 60 * 1000;
/// Bumped when the file shape changes; any other value reads as missing.
pub const format_version: i64 = 1;
pub const rel_path = ".graff/update-check.json";
const max_bytes = 4096;
const max_tag = 64;

/// Returns the latest release tag, or null. Production passes
/// `version_status.fetchLatestReleaseTag`; tests pass a fake.
pub const Fetch = *const fn (io: Io, gpa: Allocator, arena: Allocator, running_version: []const u8) ?[]const u8;

pub const Entry = struct { tag: []const u8, checked_ms: i64 };

pub const Opts = struct {
    home: []const u8,
    running: []const u8,
    skip: bool,
    now_ms: i64,
    fetch: Fetch,
};

pub const Outcome = struct {
    line: ?[]const u8 = null,
    /// A detached refresh was started.
    refresh: bool = false,
};

/// The banner notice from the cache alone. Starts a detached refresh when the
/// cache is missing, corrupt, foreign, or stale. `skip` (GRAFF_NO_UPDATE_CHECK)
/// reads nothing and starts nothing.
pub fn banner(io: Io, arena: Allocator, opts: Opts) Outcome {
    if (opts.skip) return .{};
    const entry = read(io, arena, opts.home);
    var out: Outcome = .{};
    if (entry == null or !isFresh(entry.?, opts.now_ms)) out.refresh = detach(opts.home, opts.running, opts.fetch);
    if (entry) |e| out.line = noticeLine(arena, opts.running, e.tag);
    return out;
}

/// The notice for `tag`, or null when the running build is not older.
pub fn noticeLine(arena: Allocator, running: []const u8, tag: []const u8) ?[]const u8 {
    const check = version_status.compare(running, tag);
    if (check.order != .lt) return null;
    return std.fmt.allocPrint(arena, "graff v{s} is available (you have {s}) — graff update", .{ check.latest.?, check.running }) catch null;
}

pub fn isFresh(entry: Entry, now_ms: i64) bool {
    const age = now_ms - entry.checked_ms;
    return age >= 0 and age < ttl_ms;
}

/// Record a tag a live check just saw, under the startup-pinned home.
pub fn remember(io: Io, tag: ?[]const u8) void {
    const t = tag orelse return;
    _ = store(io, credential_store.g_home, t, util.unixMs(io));
}

pub fn read(io: Io, arena: Allocator, home: []const u8) ?Entry {
    if (home.len == 0) return null;
    const path = std.fmt.allocPrint(arena, "{s}/" ++ rel_path, .{home}) catch return null;
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes)) catch return null;
    return parse(arena, data);
}

fn parse(arena: Allocator, data: []const u8) ?Entry {
    const Shape = struct { v: i64, tag: []const u8, checked_ms: i64 };
    const s = std.json.parseFromSliceLeaky(Shape, arena, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    if (s.v != format_version or !validTag(s.tag)) return null;
    return .{ .tag = s.tag, .checked_ms = s.checked_ms };
}

/// A parseable release tag made only of characters that need no JSON escape.
fn validTag(tag: []const u8) bool {
    if (tag.len == 0 or tag.len > max_tag) return false;
    for (tag) |c| switch (c) {
        '0'...'9', 'a'...'z', 'A'...'Z', '.', '-', '+' => {},
        else => return false,
    };
    return version_status.compare("0.0.0", tag).failure == .none;
}

/// Atomically replace the cache with `tag` checked at `now_ms`.
pub fn store(io: Io, home: []const u8, tag: []const u8, now_ms: i64) bool {
    if (home.len == 0 or !validTag(tag)) return false;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fmt.bufPrint(&path_buf, "{s}/.graff", .{home}) catch return false;
    Io.Dir.cwd().createDirPath(io, dir) catch return false;
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf2, "{s}/" ++ rel_path, .{home}) catch return false;
    var body_buf: [256]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf, "{{\"v\":{d},\"tag\":\"{s}\",\"checked_ms\":{d}}}\n", .{ format_version, tag, now_ms }) catch return false;
    credential_store.replaceFile(io, Io.Dir.cwd(), path, body, .default_file) catch return false;
    return true;
}

/// Thread-safe and independent of the session: a detached task frees itself.
const alloc = std.heap.smp_allocator;

/// Refreshes still running. Tests drain it (`waitIdle`) so no worker outlives
/// the test Io that started it; production never waits.
var live: std.atomic.Value(usize) = .init(0);

const Task = struct {
    home: []u8,
    running: []u8,
    fetch: Fetch,

    fn destroy(t: *Task) void {
        alloc.free(t.home);
        alloc.free(t.running);
        alloc.destroy(t);
    }

    fn run(t: *Task) void {
        defer _ = live.fetchSub(1, .release);
        defer t.destroy();
        var threaded = @import("catalog_bounded.zig").privateThreaded(); // the worker may outlive every other Io
        defer threaded.deinit();
        const io = threaded.io();
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const tag = t.fetch(io, alloc, arena_state.allocator(), t.running) orelse return;
        _ = store(io, t.home, tag, util.unixMs(io));
    }
};

/// Start a refresh nobody waits for. False when it could not start.
fn detach(home: []const u8, running: []const u8, fetch: Fetch) bool {
    if (builtin.single_threaded or home.len == 0) return false;
    const t = alloc.create(Task) catch return false;
    const home_d = alloc.dupe(u8, home) catch {
        alloc.destroy(t);
        return false;
    };
    const running_d = alloc.dupe(u8, running) catch {
        alloc.free(home_d);
        alloc.destroy(t);
        return false;
    };
    t.* = .{ .home = home_d, .running = running_d, .fetch = fetch };
    _ = live.fetchAdd(1, .acquire);
    const thread = std.Thread.spawn(.{}, Task.run, .{t}) catch {
        _ = live.fetchSub(1, .release);
        t.destroy();
        return false;
    };
    thread.detach();
    return true;
}

/// For tests: wait up to `budget` for every refresh to finish.
pub fn waitIdle(io: Io, budget: Io.Duration) bool {
    const step: Io.Duration = .fromMilliseconds(5);
    var left = budget.nanoseconds;
    while (live.load(.acquire) != 0) {
        if (left <= 0) return false;
        io.sleep(step, .awake) catch return false;
        left -= step.nanoseconds;
    }
    return true;
}

var fake_calls: std.atomic.Value(usize) = .init(0);

fn fakeFetch(io: Io, gpa: Allocator, arena: Allocator, running: []const u8) ?[]const u8 {
    _ = .{ io, gpa, arena, running };
    _ = fake_calls.fetchAdd(1, .acq_rel);
    return "v9.9.9";
}

const TestHome = struct {
    tmp: std.testing.TmpDir,
    home: [:0]u8,

    fn init() !TestHome {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        return .{ .tmp = tmp, .home = home };
    }

    fn deinit(h: *TestHome) void {
        std.testing.allocator.free(h.home);
        h.tmp.cleanup();
    }

    fn opts(h: *const TestHome, now_ms: i64) Opts {
        return .{ .home = h.home, .running = "0.0.300", .skip = false, .now_ms = now_ms, .fetch = fakeFetch };
    }

    fn rawWrite(h: *TestHome, body: []const u8) !void {
        try h.tmp.dir.createDirPath(std.testing.io, ".graff");
        try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = rel_path, .data = body });
    }
};

const day0: i64 = 1_700_000_000_000;
const notice_301 = "graff v0.0.301 is available (you have 0.0.300) — graff update";

fn expectCachedTag(h: *const TestHome, arena: Allocator, tag: []const u8) !void {
    const e = read(std.testing.io, arena, h.home) orelse return error.TestExpectedCache;
    try std.testing.expectEqualStrings(tag, e.tag);
}

test "update check cache: fresh cache gives the notice with no refresh" {
    var h = try TestHome.init();
    defer h.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(store(std.testing.io, h.home, "v0.0.301", day0));
    const before = fake_calls.load(.acquire);
    const out = banner(std.testing.io, arena, h.opts(day0 + ttl_ms - 1));
    try std.testing.expectEqualStrings(notice_301, out.line.?);
    try std.testing.expect(!out.refresh);
    try std.testing.expect(waitIdle(std.testing.io, .fromSeconds(10)));
    try std.testing.expectEqual(before, fake_calls.load(.acquire));
}

test "update check cache: stale cache gives the notice and refreshes behind" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var h = try TestHome.init();
    defer h.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(store(std.testing.io, h.home, "v0.0.301", day0));
    const before = fake_calls.load(.acquire);
    const out = banner(std.testing.io, arena, h.opts(day0 + ttl_ms));
    try std.testing.expectEqualStrings(notice_301, out.line.?);
    try std.testing.expect(out.refresh);
    try std.testing.expect(waitIdle(std.testing.io, .fromSeconds(10)));
    try std.testing.expectEqual(before + 1, fake_calls.load(.acquire));
    try expectCachedTag(&h, arena, "v9.9.9");
}

test "update check cache: no cache gives no notice and refreshes behind" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var h = try TestHome.init();
    defer h.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const out = banner(std.testing.io, arena, h.opts(day0));
    try std.testing.expect(out.line == null);
    try std.testing.expect(out.refresh);
    try std.testing.expect(waitIdle(std.testing.io, .fromSeconds(10)));
    try expectCachedTag(&h, arena, "v9.9.9");
}

test "update check cache: corrupt, foreign, and future caches read as missing or stale" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var h = try TestHome.init();
    defer h.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bodies = [_][]const u8{
        "{not json",
        "{\"v\":2,\"tag\":\"v0.0.301\",\"checked_ms\":1700000000000}",
        "{\"v\":1,\"tag\":\"latest\",\"checked_ms\":1700000000000}",
        "{\"v\":1,\"tag\":\"v0.0.301\\\"x\",\"checked_ms\":1700000000000}",
        "{\"v\":1,\"checked_ms\":1700000000000}",
    };
    for (bodies) |body| {
        try h.rawWrite(body);
        const out = banner(std.testing.io, arena, h.opts(day0));
        try std.testing.expect(out.line == null);
        try std.testing.expect(out.refresh);
        try std.testing.expect(waitIdle(std.testing.io, .fromSeconds(10)));
    }
    // A clock that went backwards: keep the notice, but refresh.
    try std.testing.expect(store(std.testing.io, h.home, "v0.0.301", day0 + 1000));
    const out = banner(std.testing.io, arena, h.opts(day0));
    try std.testing.expectEqualStrings(notice_301, out.line.?);
    try std.testing.expect(out.refresh);
    try std.testing.expect(waitIdle(std.testing.io, .fromSeconds(10)));
}

test "update check cache: GRAFF_NO_UPDATE_CHECK reads and starts nothing" {
    var h = try TestHome.init();
    defer h.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expect(store(std.testing.io, h.home, "v0.0.301", day0 - ttl_ms));
    var o = h.opts(day0);
    o.skip = true;
    const before = fake_calls.load(.acquire);
    const out = banner(std.testing.io, arena_state.allocator(), o);
    try std.testing.expect(out.line == null);
    try std.testing.expect(!out.refresh);
    try std.testing.expectEqual(@as(usize, 0), live.load(.acquire));
    try std.testing.expectEqual(before, fake_calls.load(.acquire));
}

test "update check cache: a cached tag at or below the running version shows nothing" {
    var h = try TestHome.init();
    defer h.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "v0.0.300", "v0.0.299", "v0.0.300.0" }) |tag| {
        try std.testing.expect(store(std.testing.io, h.home, tag, day0));
        const out = banner(std.testing.io, arena, h.opts(day0 + 1));
        try std.testing.expect(out.line == null);
        try std.testing.expect(!out.refresh);
    }
    // Same comparison rules as the live check: a hotfix of the running base is newer.
    try std.testing.expect(noticeLine(arena, "0.0.300", "v0.0.300.1") != null);
    try std.testing.expect(noticeLine(arena, "0.0.301-2-gabc", "v0.0.301") == null);
}
