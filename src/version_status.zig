//! Running / installed / latest comparison shared by `graff update --check`,
//! the startup update notice, and the terminal `/update` (and `/version`)
//! surfaces. One policy so the CLI and the in-session command cannot drift.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const State = enum { current, older, newer, dev, unable };
pub const Failure = enum { none, fetch, latest_tag };

pub const Check = struct {
    running: []const u8,
    latest: ?[]const u8 = null,
    latest_tag: ?[]const u8 = null,
    state: State,
    failure: Failure = .none,
    order: ?std.math.Order = null,
    clean_release: bool = false,
};

const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    fn eql(self: Version, other: Version) bool {
        return self.major == other.major and self.minor == other.minor and self.patch == other.patch;
    }

    fn order(self: Version, other: Version) std.math.Order {
        if (self.major != other.major) return std.math.order(self.major, other.major);
        if (self.minor != other.minor) return std.math.order(self.minor, other.minor);
        return std.math.order(self.patch, other.patch);
    }
};

pub const repo_api = "https://api.github.com/repos/justrach/codegraff/releases/latest";
pub const repo_download_base = "https://github.com/justrach/codegraff/releases/download";

pub fn stripV(s: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, s, "v")) s[1..] else s;
}

fn parseVersion(s: []const u8) ?Version {
    var it = std.mem.splitScalar(u8, s, '.');
    const major_s = it.next() orelse return null;
    const minor_s = it.next() orelse return null;
    const patch_s = it.next() orelse return null;
    const major = std.fmt.parseInt(u32, major_s, 10) catch return null;
    const minor = std.fmt.parseInt(u32, minor_s, 10) catch return null;
    const patch_digits = std.mem.indexOfAny(u8, patch_s, "-+") orelse patch_s.len;
    const patch = std.fmt.parseInt(u32, patch_s[0..patch_digits], 10) catch return null;
    return .{ .major = major, .minor = minor, .patch = patch };
}

fn isCleanReleaseVersion(s: []const u8) bool {
    if (s.len == 0) return false;
    var dots: u8 = 0;
    for (s) |c| switch (c) {
        '0'...'9' => {},
        '.' => dots += 1,
        else => return false,
    };
    return dots == 2;
}

/// Pure comparison. `latest_tag` is the GitHub tag (with or without `v`);
/// `running_version` is the build option baked into this process.
pub fn compare(running_version: []const u8, latest_tag: ?[]const u8) Check {
    const running = stripV(running_version);
    const tag = latest_tag orelse return .{ .running = running, .state = .unable, .failure = .fetch };
    const latest = stripV(tag);
    const release = parseVersion(latest) orelse return .{
        .running = running,
        .latest_tag = tag,
        .state = .unable,
        .failure = .latest_tag,
    };
    const current = parseVersion(running);
    const clean = current != null and isCleanReleaseVersion(running);
    const order = if (current) |v| v.order(release) else null;
    if (!clean) return .{
        .running = running,
        .latest = latest,
        .latest_tag = tag,
        .state = .dev,
        .order = order,
    };
    return .{
        .running = running,
        .latest = latest,
        .latest_tag = tag,
        .state = switch (order.?) {
            .lt => .older,
            .eq => .current,
            .gt => .newer,
        },
        .order = order,
        .clean_release = true,
    };
}

/// True when `candidate` is a clean release at or newer than `latest_tag`.
/// Used to refuse a reinstall or implicit downgrade of an already-installed
/// binary that is current even when this process is older.
pub fn alreadyHasRelease(installed_version: []const u8, latest_tag: []const u8) bool {
    const check = compare(installed_version, latest_tag);
    return switch (check.state) {
        .current, .newer => true,
        .dev => check.order == .gt or check.order == .eq,
        .older, .unable => false,
    };
}

pub fn fetchLatestReleaseTag(io: Io, gpa: Allocator, arena: Allocator, running_version: []const u8) ?[]const u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    defer aw.deinit();
    const extra = [_]std.http.Header{.{ .name = "Accept", .value = "application/vnd.github+json" }};
    const user_agent = std.fmt.allocPrint(arena, "simple-harness/{s}", .{running_version}) catch return null;
    const res = client.fetch(.{
        .location = .{ .url = repo_api },
        .method = .GET,
        .response_writer = &aw.writer,
        .headers = .{ .user_agent = .{ .override = user_agent } },
        .extra_headers = &extra,
    }) catch return null;
    if (@intFromEnum(res.status) != 200 or aw.writer.buffered().len > 64 * 1024) return null;
    const parsed = std.json.parseFromSliceLeaky(Value, arena, aw.writer.buffered(), .{ .allocate = .alloc_always }) catch return null;
    if (parsed != .object) return null;
    const tag = parsed.object.get("tag_name") orelse return null;
    return if (tag == .string) tag.string else null;
}

pub fn checkLatest(io: Io, gpa: Allocator, arena: Allocator, running_version: []const u8) Check {
    return compare(running_version, fetchLatestReleaseTag(io, gpa, arena, running_version));
}

/// Leak-free tag extract for tests and the update service: copies into `buf`.
pub fn copyTagName(body: []const u8, buf: []u8) ?[]const u8 {
    var parsed = std.json.parseFromSlice(Value, std.heap.page_allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const tag = parsed.value.object.get("tag_name") orelse return null;
    if (tag != .string or tag.string.len == 0 or tag.string.len > buf.len) return null;
    @memcpy(buf[0..tag.string.len], tag.string);
    return buf[0..tag.string.len];
}

test "comparison classifies release and dev builds with one policy" {
    try std.testing.expectEqual(State.current, compare("0.0.292", "v0.0.292").state);
    try std.testing.expectEqual(State.older, compare("0.0.291", "v0.0.292").state);
    try std.testing.expectEqual(State.newer, compare("0.0.293", "v0.0.292").state);
    const dev = compare("0.0.293-2-gabc", "v0.0.292");
    try std.testing.expectEqual(State.dev, dev.state);
    try std.testing.expectEqual(std.math.Order.gt, dev.order.?);
}

test "unavailable and unparseable latest checks do not guess" {
    try std.testing.expectEqual(Failure.fetch, compare("0.0.292", null).failure);
    try std.testing.expectEqual(Failure.latest_tag, compare("0.0.292", "latest").failure);
}

test "alreadyHasRelease refuses a reinstall when disk is current or newer" {
    try std.testing.expect(alreadyHasRelease("0.0.292", "v0.0.292"));
    try std.testing.expect(alreadyHasRelease("0.0.293", "v0.0.292"));
    try std.testing.expect(!alreadyHasRelease("0.0.291", "v0.0.292"));
    try std.testing.expect(!alreadyHasRelease("0.0.291-3-gabc", "v0.0.292"));
}
