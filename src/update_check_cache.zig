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
//! A refresh first records when it was tried (`tried_ms`), so a machine that
//! cannot reach the release endpoint tries again after `retry_ms`, not on
//! every launch; one that cannot write the file tries once per process.
//! The file is untrusted input: every field is checked before it is used,
//! and no value in it can make the arithmetic trap.
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
/// After a refresh started (and maybe failed), wait this long before the next.
pub const retry_ms: i64 = 30 * 60 * 1000;
/// Bumped when the file shape changes; any other value reads as missing.
pub const format_version: i64 = 1;
pub const rel_path = ".graff/update-check.json";
const max_bytes = 4096;
const max_tag = 64;

/// Returns the latest release tag, or null. Production passes
/// `version_status.fetchLatestReleaseTag`; tests pass a fake.
pub const Fetch = *const fn (io: Io, gpa: Allocator, arena: Allocator, running_version: []const u8) ?[]const u8;

/// `tag` and `checked_ms` from the last successful check; `tried_ms` from
/// the last refresh started after it, if any.
pub const Entry = struct { tag: ?[]const u8 = null, checked_ms: i64 = 0, tried_ms: ?i64 = null };

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
    const entry = read(io, arena, opts.home) orelse Entry{};
    var out: Outcome = .{};
    if (!isFresh(entry, opts.now_ms) and !backingOff(entry, opts.now_ms) and !tried_this_process.swap(true, .acq_rel))
        out.refresh = detach(opts.home, opts.running, opts.fetch, entry);
    if (entry.tag) |tag| out.line = noticeLine(arena, opts.running, tag);
    return out;
}

/// The notice for `tag`, or null when the running build is not older.
pub fn noticeLine(arena: Allocator, running: []const u8, tag: []const u8) ?[]const u8 {
    const check = version_status.compare(running, tag);
    if (check.order != .lt) return null;
    return std.fmt.allocPrint(arena, "graff v{s} is available (you have {s}) — graff update", .{ check.latest.?, check.running }) catch null;
}

/// `now_ms - then_ms` when it is in `[0, limit)`. Any i64 pair is defined:
/// an overflowing difference or a time in the future is "not within".
fn within(now_ms: i64, then_ms: i64, limit: i64) bool {
    const age = std.math.sub(i64, now_ms, then_ms) catch return false;
    return age >= 0 and age < limit;
}

pub fn isFresh(entry: Entry, now_ms: i64) bool {
    return entry.tag != null and within(now_ms, entry.checked_ms, ttl_ms);
}

/// A refresh started less than `retry_ms` ago: do not start another.
pub fn backingOff(entry: Entry, now_ms: i64) bool {
    return within(now_ms, entry.tried_ms orelse return false, retry_ms);
}

/// One refresh per process at most, also when the file cannot be written.
var tried_this_process: std.atomic.Value(bool) = .init(false);

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

/// Null for anything but a `v` 1 object. A tag that is not a plain release
/// tag (it would reach the terminal) or has no time reads as no tag; a
/// `tried_ms` survives either way. Numbers outside i64 fail the parse.
fn parse(arena: Allocator, data: []const u8) ?Entry {
    const Shape = struct { v: i64, tag: ?[]const u8 = null, checked_ms: ?i64 = null, tried_ms: ?i64 = null };
    const s = std.json.parseFromSliceLeaky(Shape, arena, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    if (s.v != format_version) return null;
    var e: Entry = .{ .tried_ms = s.tried_ms };
    if (s.tag) |tag| if (s.checked_ms) |at| if (validTag(tag)) {
        e.tag = tag;
        e.checked_ms = at;
    };
    return e;
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
    if (!validTag(tag)) return false;
    return write(io, home, .{ .tag = tag, .checked_ms = now_ms });
}

/// Atomically replace the cache with `entry`. Its tag must be valid or null.
fn write(io: Io, home: []const u8, entry: Entry) bool {
    if (home.len == 0) return false;
    if (entry.tag) |tag| if (!validTag(tag)) return false;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fmt.bufPrint(&path_buf, "{s}/.graff", .{home}) catch return false;
    Io.Dir.cwd().createDirPath(io, dir) catch return false;
    var path_buf2: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf2, "{s}/" ++ rel_path, .{home}) catch return false;
    var body_buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&body_buf);
    w.print("{{\"v\":{d}", .{format_version}) catch return false;
    if (entry.tag) |tag| w.print(",\"tag\":\"{s}\",\"checked_ms\":{d}", .{ tag, entry.checked_ms }) catch return false;
    if (entry.tried_ms) |t| w.print(",\"tried_ms\":{d}", .{t}) catch return false;
    w.writeAll("}\n") catch return false;
    credential_store.replaceFile(io, Io.Dir.cwd(), path, w.buffered(), .default_file) catch return false;
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
    /// What the banner read, so the attempt record keeps the cached notice.
    tag_buf: [max_tag]u8 = undefined,
    tag_len: usize = 0,
    checked_ms: i64 = 0,

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
        // Recorded before the request: a refresh that fails, hangs, or is
        // cut off by exit still holds the next launches off for `retry_ms`.
        const kept: ?[]const u8 = if (t.tag_len > 0) t.tag_buf[0..t.tag_len] else null;
        _ = write(io, t.home, .{ .tag = kept, .checked_ms = t.checked_ms, .tried_ms = util.unixMs(io) });
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const tag = t.fetch(io, alloc, arena_state.allocator(), t.running) orelse return;
        _ = store(io, t.home, tag, util.unixMs(io));
    }
};

/// Start a refresh nobody waits for. False when it could not start.
fn detach(home: []const u8, running: []const u8, fetch: Fetch, entry: Entry) bool {
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
    t.* = .{ .home = home_d, .running = running_d, .fetch = fetch, .checked_ms = entry.checked_ms };
    if (entry.tag) |tag| if (tag.len <= max_tag) {
        @memcpy(t.tag_buf[0..tag.len], tag);
        t.tag_len = tag.len;
    };
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

/// The release endpoint unreachable.
fn failFetch(io: Io, gpa: Allocator, arena: Allocator, running: []const u8) ?[]const u8 {
    _ = .{ io, gpa, arena, running };
    _ = fake_calls.fetchAdd(1, .acq_rel);
    return null;
}

/// Each test stands for a fresh process.
fn newProcess() void {
    tried_this_process.store(false, .release);
}

const TestHome = struct {
    tmp: std.testing.TmpDir,
    home: [:0]u8,

    fn init() !TestHome {
        newProcess();
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
    try std.testing.expectEqualStrings(tag, e.tag orelse return error.TestExpectedCache);
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
        newProcess();
        const out = banner(std.testing.io, arena, h.opts(day0));
        try std.testing.expect(out.line == null);
        try std.testing.expect(out.refresh);
        try std.testing.expect(waitIdle(std.testing.io, .fromSeconds(10)));
    }
    // A clock that went backwards: keep the notice, but refresh.
    try std.testing.expect(store(std.testing.io, h.home, "v0.0.301", day0 + 1000));
    newProcess();
    const out = banner(std.testing.io, arena, h.opts(day0));
    try std.testing.expectEqualStrings(notice_301, out.line.?);
    try std.testing.expect(out.refresh);
    try std.testing.expect(waitIdle(std.testing.io, .fromSeconds(10)));
}

test "update check cache: extreme times and numbers never trap and read as stale or missing" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const min = std.math.minInt(i64);
    const max = std.math.maxInt(i64);
    for ([_]i64{ min, -1, 0, max }) |now| for ([_]i64{ min, -1, 0, max }) |then| {
        _ = isFresh(.{ .tag = "v1.0.0", .checked_ms = then }, now);
        _ = backingOff(.{ .tried_ms = then }, now);
    };
    try std.testing.expect(!isFresh(.{ .tag = "v1.0.0", .checked_ms = min }, max));
    try std.testing.expect(!isFresh(.{ .tag = "v1.0.0", .checked_ms = max }, min));
    try std.testing.expect(!backingOff(.{ .tried_ms = min }, max));
    try std.testing.expect(!backingOff(.{ .tried_ms = max }, 0)); // dated in the future: retry

    var h = try TestHome.init();
    defer h.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bodies = [_][]const u8{
        "{\"v\":1,\"tag\":\"v0.0.301\",\"checked_ms\":-9223372036854775808}",
        "{\"v\":1,\"tag\":\"v0.0.301\",\"checked_ms\":9223372036854775807}",
        "{\"v\":1,\"tag\":\"v0.0.301\",\"checked_ms\":-9223372036854775808,\"tried_ms\":9223372036854775807}",
        "{\"v\":1,\"tag\":\"v0.0.301\",\"checked_ms\":1700000000000,\"tried_ms\":-9223372036854775808}",
    };
    for (bodies) |body| for ([_]i64{ min, day0, max }) |now| {
        try h.rawWrite(body);
        newProcess();
        const out = banner(std.testing.io, arena, h.opts(now));
        try std.testing.expectEqualStrings(notice_301, out.line.?); // a valid tag still shows
        try std.testing.expect(waitIdle(std.testing.io, .fromSeconds(10)));
    };
    // Numbers outside i64, or not integers, fail the parse: the file reads as missing.
    const unparsable = [_][]const u8{
        "{\"v\":1,\"tag\":\"v0.0.301\",\"checked_ms\":9223372036854775808}",
        "{\"v\":1,\"tag\":\"v0.0.301\",\"checked_ms\":-9223372036854775809}",
        "{\"v\":1,\"tag\":\"v0.0.301\",\"checked_ms\":1e300}",
        "{\"v\":1,\"tag\":\"v0.0.301\",\"checked_ms\":-1e5000}",
        "{\"v\":1,\"tag\":\"v0.0.301\",\"checked_ms\":1.5}",
        "{\"v\":1e300,\"tag\":\"v0.0.301\",\"checked_ms\":0}",
        "{\"v\":1,\"tag\":\"v0.0.301\",\"checked_ms\":0,\"tried_ms\":99999999999999999999}",
    };
    for (unparsable) |body| {
        try h.rawWrite(body);
        try std.testing.expect(read(std.testing.io, arena, h.home) == null);
    }
    // Release tags past the u32 parts, escapes, and overlong tags never reach the terminal.
    const hostile = [_][]const u8{
        "{\"v\":1,\"tag\":\"v99999999999.0.0\",\"checked_ms\":1700000000000}",
        "{\"v\":1,\"tag\":\"v0.0.301\\u001b[2J\",\"checked_ms\":1700000000000}",
        "{\"v\":1,\"tag\":\"v0.0.301\\r\",\"checked_ms\":1700000000000}",
        "{\"v\":1,\"tag\":\"v0.0.301-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\",\"checked_ms\":1700000000000}",
    };
    for (hostile) |body| {
        try h.rawWrite(body);
        const e = read(std.testing.io, arena, h.home) orelse return error.TestExpectedEntry;
        try std.testing.expect(e.tag == null);
        try std.testing.expect(noticeLine(arena, "0.0.300", "v99999999999.0.0") == null);
    }
}

test "update check cache: a failed refresh holds later launches off for retry_ms" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var h = try TestHome.init();
    defer h.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(store(std.testing.io, h.home, "v0.0.301", day0 - ttl_ms)); // stale
    var o = h.opts(day0);
    o.fetch = failFetch;
    const before = fake_calls.load(.acquire);
    const first = banner(std.testing.io, arena, o);
    try std.testing.expect(first.refresh);
    try std.testing.expect(waitIdle(std.testing.io, .fromSeconds(10)));
    try std.testing.expectEqual(before + 1, fake_calls.load(.acquire));
    const e = read(std.testing.io, arena, h.home) orelse return error.TestExpectedEntry;
    try std.testing.expectEqualStrings("v0.0.301", e.tag.?); // the attempt record keeps the notice
    try std.testing.expectEqual(day0 - ttl_ms, e.checked_ms);
    try std.testing.expect(e.tried_ms != null);
    const tried = e.tried_ms.?;
    // The next launches, inside the back-off: notice, no request.
    for ([_]i64{ 1, retry_ms - 1 }) |later| {
        newProcess();
        o.now_ms = tried + later;
        const out = banner(std.testing.io, arena, o);
        try std.testing.expectEqualStrings(notice_301, out.line.?);
        try std.testing.expect(!out.refresh);
    }
    try std.testing.expectEqual(before + 1, fake_calls.load(.acquire));
    // After it, one more try; a success drops the attempt record.
    newProcess();
    o.now_ms = tried + retry_ms;
    o.fetch = fakeFetch;
    try std.testing.expect(banner(std.testing.io, arena, o).refresh);
    try std.testing.expect(waitIdle(std.testing.io, .fromSeconds(10)));
    const done = read(std.testing.io, arena, h.home) orelse return error.TestExpectedEntry;
    try std.testing.expectEqualStrings("v9.9.9", done.tag.?);
    try std.testing.expect(done.tried_ms == null);
}

test "update check cache: with no cache and a failed refresh, the attempt alone is recorded" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var h = try TestHome.init();
    defer h.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var o = h.opts(day0);
    o.fetch = failFetch;
    try std.testing.expect(banner(std.testing.io, arena, o).refresh);
    try std.testing.expect(waitIdle(std.testing.io, .fromSeconds(10)));
    const e = read(std.testing.io, arena, h.home) orelse return error.TestExpectedEntry;
    try std.testing.expect(e.tag == null and e.tried_ms != null);
    newProcess();
    o.now_ms = e.tried_ms.? + 1;
    const out = banner(std.testing.io, arena, o);
    try std.testing.expect(out.line == null and !out.refresh);
}

test "update check cache: an unwritable cache is tried once per process" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var h = try TestHome.init();
    defer h.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try h.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".graff", .data = "a file where the directory goes" });
    var o = h.opts(day0);
    o.fetch = failFetch;
    const before = fake_calls.load(.acquire);
    try std.testing.expect(banner(std.testing.io, arena, o).refresh);
    try std.testing.expect(waitIdle(std.testing.io, .fromSeconds(10)));
    try std.testing.expect(read(std.testing.io, arena, h.home) == null); // nothing could be recorded
    o.now_ms = day0 + 1;
    try std.testing.expect(!banner(std.testing.io, arena, o).refresh);
    o.fetch = fakeFetch;
    try std.testing.expect(!banner(std.testing.io, arena, o).refresh);
    try std.testing.expect(waitIdle(std.testing.io, .fromSeconds(10)));
    try std.testing.expectEqual(before + 1, fake_calls.load(.acquire));
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
