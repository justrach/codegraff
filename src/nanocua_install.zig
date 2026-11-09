//! `graff update`'s half of shipping nanocua (ADR 0314): a macOS release
//! tarball carries nanocua.app beside graff, and this puts it in
//! ~/Applications. The archive is already verified against SHA256SUMS. A tarball
//! without the app (one CI didn't sign) changes nothing, so a signed app already
//! installed is never swapped for no app.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const archive = @import("update_archive.zig");
const nanocua_default = @import("nanocua_default.zig");
const version_status = @import("version_status.zig");
const update_target = @import("update_target.zig");
const update_service = @import("update_service.zig");

const bundle = "nanocua.app";
pub const installed_note = "Installed nanocua.app in ~/Applications.";

pub const ReleaseKind = enum {
    installed,
    unsupported,
    offline,
    malformed,
    verify_failed,
    no_app,
    permission,
};

pub const ReleaseReport = struct {
    kind: ReleaseKind,
    detail: []const u8 = "",
    tag_buf: [64]u8 = undefined,
    tag_len: usize = 0,
    path_buf: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,

    pub fn tag(self: *const ReleaseReport) ?[]const u8 {
        return if (self.tag_len == 0) null else self.tag_buf[0..self.tag_len];
    }

    pub fn path(self: *const ReleaseReport) ?[]const u8 {
        return if (self.path_len == 0) null else self.path_buf[0..self.path_len];
    }
};

pub const ReleaseOpts = struct {
    io: Io,
    gpa: Allocator,
    home: []const u8,
    running_version: []const u8,
    asset_name: ?[]const u8 = null,
    fetch: update_service.Fetch,
    pinned_tag: ?[]const u8 = null,
    is_macos: bool = builtin.os.tag == .macos,
};

/// `name`'s path inside the bundle, if it is in one. Nothing may climb out.
pub fn memberPath(name: []const u8) ?[]const u8 {
    const marker = bundle ++ "/";
    const at = if (std.mem.startsWith(u8, name, marker))
        0
    else if (std.mem.indexOf(u8, name, "/" ++ marker)) |i| i + 1 else return null;
    const rel = name[at + marker.len ..];
    if (rel.len == 0 or rel[0] == '/') return null;
    var parts = std.mem.splitScalar(u8, rel, '/');
    while (parts.next()) |p| if (std.mem.eql(u8, p, "..")) return null;
    return rel;
}

fn modeFor(rel: []const u8) Io.File.Permissions {
    if (builtin.os.tag == .windows) return .default_file;
    const executable = std.mem.startsWith(u8, rel, "Contents/MacOS/");
    return .fromMode(if (executable) 0o755 else 0o644);
}

/// Installs the app from a gzipped release tarball. True if it held one.
pub fn fromArchive(io: Io, gpa: Allocator, home: []const u8, gz: []const u8) !bool {
    if (home.len == 0) return false;
    const tar = try archive.gunzip(gpa, gz);
    defer gpa.free(tar);
    return fromTar(io, gpa, home, tar);
}

pub fn fromTar(io: Io, gpa: Allocator, home: []const u8, tar: []const u8) !bool {
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const a = state.allocator();
    const root = nanocua_default.installRoot(a, home) orelse return false;
    const dest = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, bundle });
    const stage = try std.fmt.allocPrint(a, "{s}/.{s}.new", .{ root, bundle });
    const old = try std.fmt.allocPrint(a, "{s}/.{s}.old", .{ root, bundle });
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, stage) catch {};
    var any = false;
    errdefer cwd.deleteTree(io, stage) catch {};
    var members = archive.Members.init(tar);
    while (try members.next()) |m| {
        const rel = memberPath(m.name) orelse continue;
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ stage, rel });
        try cwd.createDirPath(io, std.fs.path.dirname(path).?);
        try cwd.writeFile(io, .{ .sub_path = path, .data = m.payload, .flags = .{ .permissions = modeFor(rel) } });
        any = true;
    }
    if (!any) return false;
    // Aside, in, then away: a failure between puts the old app back, never
    // leaving half of a new one.
    cwd.deleteTree(io, old) catch {};
    const had = if (cwd.rename(dest, cwd, old, io)) true else |_| false;
    cwd.rename(stage, cwd, dest, io) catch |err| {
        if (had) cwd.rename(old, cwd, dest, io) catch {};
        return err;
    };
    if (had) cwd.deleteTree(io, old) catch {};
    return true;
}

fn holdBuf(buf: []u8, src: []const u8) usize {
    const n = @min(src.len, buf.len);
    @memcpy(buf[0..n], src[0..n]);
    return n;
}

fn releaseReport(kind: ReleaseKind, tag: ?[]const u8, path: ?[]const u8, detail: []const u8) ReleaseReport {
    var r: ReleaseReport = .{ .kind = kind, .detail = detail };
    if (tag) |t| r.tag_len = holdBuf(&r.tag_buf, t);
    if (path) |p| r.path_len = holdBuf(&r.path_buf, p);
    return r;
}

fn mapFetchErr(err: update_service.FetchError) ReleaseKind {
    return switch (err) {
        error.Offline, error.OutOfMemory => .offline,
        error.Malformed => .malformed,
        error.Permission => .permission,
    };
}

fn fetchTagSums(opts: ReleaseOpts, tag: []const u8) update_service.FetchError![]u8 {
    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/{s}/SHA256SUMS", .{ version_status.repo_download_base, tag }) catch
        return error.Malformed;
    return opts.fetch.get(opts.fetch.ctx, opts.gpa, url);
}

fn latestStableTag(opts: ReleaseOpts, out: *[64]u8) update_service.FetchError![]const u8 {
    const body = try opts.fetch.get(opts.fetch.ctx, opts.gpa, version_status.repo_api);
    defer opts.gpa.free(body);
    const tag = version_status.copyTagName(body, out) orelse return error.Malformed;
    if (version_status.compare("0.0.0", tag).failure != .none) return error.Malformed;
    return tag;
}

/// Download a verified macOS release archive and place only `nanocua.app` in
/// `~/Applications/nanocua.app` (leaving any installed `graff` binary untouched).
pub fn installRelease(opts: ReleaseOpts) ReleaseReport {
    if (!opts.is_macos) return releaseReport(.unsupported, null, null, "Computer use is macOS-only for now.");
    const asset = opts.asset_name orelse update_target.assetName() orelse
        return releaseReport(.unsupported, null, null, "nanocua.app is unavailable for this macOS architecture.");
    const dest_home = nanocua_default.userHome(opts.home);
    if (dest_home.len == 0) return releaseReport(.permission, null, null, "HOME is not set; cannot locate ~/Applications.");

    var tag_buf: [64]u8 = undefined;
    var tag: []const u8 = "";
    var sums: []u8 = &.{};
    if (opts.pinned_tag) |pt| {
        if (pt.len == 0 or pt.len > tag_buf.len) return releaseReport(.malformed, null, null, "release tag is invalid.");
        const n = holdBuf(&tag_buf, pt);
        tag = tag_buf[0..n];
        sums = fetchTagSums(opts, tag) catch |err|
            return releaseReport(mapFetchErr(err), tag, null, "SHA256SUMS unavailable — refusing to install nanocua.app.");
    } else if (version_status.compare(opts.running_version, "v0.0.0").clean_release) {
        var cand_buf: [64]u8 = undefined;
        const cand = std.fmt.bufPrint(&cand_buf, "v{s}", .{version_status.stripV(opts.running_version)}) catch
            return releaseReport(.malformed, null, null, "running version is invalid.");
        if (fetchTagSums(opts, cand)) |got| {
            const n = holdBuf(&tag_buf, cand);
            tag = tag_buf[0..n];
            sums = got;
        } else |err| switch (err) {
            error.Offline => {
                tag = latestStableTag(opts, &tag_buf) catch |lerr|
                    return releaseReport(mapFetchErr(lerr), null, null, "could not reach GitHub releases to locate nanocua.app.");
                sums = fetchTagSums(opts, tag) catch |serr|
                    return releaseReport(mapFetchErr(serr), tag, null, "SHA256SUMS unavailable — refusing to install nanocua.app.");
            },
            else => return releaseReport(mapFetchErr(err), cand, null, "SHA256SUMS unavailable — refusing to install nanocua.app."),
        }
    } else {
        tag = latestStableTag(opts, &tag_buf) catch |err|
            return releaseReport(mapFetchErr(err), null, null, "could not reach GitHub releases to locate nanocua.app.");
        sums = fetchTagSums(opts, tag) catch |err|
            return releaseReport(mapFetchErr(err), tag, null, "SHA256SUMS unavailable — refusing to install nanocua.app.");
    }
    defer opts.gpa.free(sums);

    var asset_url_buf: [512]u8 = undefined;
    const asset_url = std.fmt.bufPrint(&asset_url_buf, "{s}/{s}/{s}", .{ version_status.repo_download_base, tag, asset }) catch
        return releaseReport(.malformed, tag, null, "could not pin release asset URL.");
    const tarball = opts.fetch.get(opts.fetch.ctx, opts.gpa, asset_url) catch |err|
        return releaseReport(mapFetchErr(err), tag, null, "release archive download failed.");
    defer opts.gpa.free(tarball);

    archive.verifyAsset(sums, asset, tarball) catch |err| return switch (err) {
        error.VerifyFailed => releaseReport(.verify_failed, tag, null, "nanocua install refused — release artifact did not match SHA256SUMS."),
        error.Malformed => releaseReport(.malformed, tag, null, "nanocua install failed — malformed SHA256SUMS."),
        error.OutOfMemory => releaseReport(.offline, tag, null, "nanocua install failed — out of memory."),
    };

    const placed = fromArchive(opts.io, opts.gpa, dest_home, tarball) catch |err| return switch (err) {
        error.Malformed => releaseReport(.malformed, tag, null, "nanocua install failed — release archive is malformed."),
        error.OutOfMemory => releaseReport(.offline, tag, null, "nanocua install failed — out of memory."),
        else => releaseReport(.permission, tag, null, "nanocua install failed — could not write ~/Applications/nanocua.app."),
    };
    if (!placed) return releaseReport(.no_app, tag, null, "nanocua install failed — release archive did not contain nanocua.app.");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const app_path = std.fmt.bufPrint(&path_buf, "{s}/Applications/{s}", .{ dest_home, bundle }) catch "";
    return releaseReport(.installed, tag, app_path, installed_note);
}

const testing = std.testing;

test "members inside the bundle, and nothing that climbs out" {
    try testing.expectEqualStrings("Contents/Info.plist", memberPath("graff-aarch64-macos/nanocua.app/Contents/Info.plist").?);
    try testing.expectEqualStrings("Contents/MacOS/nanocua", memberPath("nanocua.app/Contents/MacOS/nanocua").?);
    try testing.expect(memberPath("graff-aarch64-macos/graff") == null);
    try testing.expect(memberPath("graff-aarch64-macos/nanocua.app/") == null);
    try testing.expect(memberPath("x/nanocua.app/../../evil") == null);
    try testing.expect(memberPath("x/notnanocua.app/Contents/Info.plist") == null);
}

fn appendMember(gpa: Allocator, out: *std.ArrayList(u8), name: []const u8, data: []const u8, kind: u8) !void {
    var hdr: [512]u8 = @splat(0);
    @memcpy(hdr[0..name.len], name);
    _ = try std.fmt.bufPrint(hdr[124..136], "{o:0>11}", .{data.len});
    hdr[156] = kind;
    try out.appendSlice(gpa, &hdr);
    try out.appendSlice(gpa, data);
    try out.appendNTimes(gpa, 0, std.mem.alignForward(usize, data.len, 512) - data.len);
}

/// Build an offline gzipped macOS release archive fixture for unit tests.
pub fn fixtureMacosArchive(gpa: Allocator, with_app: bool, graff_payload: []const u8, app_payload: []const u8) ![]u8 {
    var tar: std.ArrayList(u8) = .empty;
    defer tar.deinit(gpa);
    try appendMember(gpa, &tar, "graff-aarch64-macos/graff", graff_payload, '0');
    if (with_app) {
        try appendMember(gpa, &tar, "graff-aarch64-macos/nanocua.app/", "", '5');
        try appendMember(gpa, &tar, "graff-aarch64-macos/nanocua.app/Contents/MacOS/nanocua", app_payload, '0');
        try appendMember(gpa, &tar, "graff-aarch64-macos/nanocua.app/Contents/Info.plist", "<plist/>", '0');
    }
    try tar.appendNTimes(gpa, 0, 1024);
    return archive.gzipAlloc(gpa, tar.items);
}

test "the app lands in ~/Applications, replacing the old one; none in the tarball changes nothing" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const home = buf[0..n];
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const a = state.allocator();
    const stale = try std.fmt.allocPrint(a, "{s}/Applications/nanocua.app/Contents/stale", .{home});
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(stale).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = stale, .data = "old" });

    var none: std.ArrayList(u8) = .empty;
    defer none.deinit(gpa);
    try appendMember(gpa, &none, "graff-aarch64-macos/graff", "bin", '0');
    try none.appendNTimes(gpa, 0, 1024);
    try testing.expect(!try fromTar(io, gpa, home, none.items));
    _ = try Io.Dir.cwd().statFile(io, stale, .{}); // still there

    var with: std.ArrayList(u8) = .empty;
    defer with.deinit(gpa);
    try appendMember(gpa, &with, "graff-aarch64-macos/graff", "bin", '0');
    try appendMember(gpa, &with, "graff-aarch64-macos/nanocua.app/", "", '5');
    try appendMember(gpa, &with, "graff-aarch64-macos/nanocua.app/Contents/MacOS/nanocua", "app", '0');
    try appendMember(gpa, &with, "graff-aarch64-macos/nanocua.app/Contents/Info.plist", "plist", '0');
    try with.appendNTimes(gpa, 0, 1024);
    try testing.expect(try fromTar(io, gpa, home, with.items));
    const exe = try std.fmt.allocPrint(a, "{s}/Applications/nanocua.app/Contents/MacOS/nanocua", .{home});
    const data = try Io.Dir.cwd().readFileAlloc(io, exe, a, .limited(16));
    try testing.expectEqualStrings("app", data);
    if (builtin.os.tag != .windows) {
        const stat = try Io.Dir.cwd().statFile(io, exe, .{});
        try testing.expect(stat.permissions.toMode() & 0o111 != 0);
    }
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, stale, .{}));
}

const ReleaseFx = struct {
    archive: []const u8,
    sums: []const u8,
    published_tag: []const u8 = "v0.302.74.4",
    bad_sums: bool = false,
    api_calls: usize = 0,

    fn get(ctx: ?*anyopaque, gpa: Allocator, url: []const u8) update_service.FetchError![]u8 {
        const self: *ReleaseFx = @ptrCast(@alignCast(ctx.?));
        if (std.mem.eql(u8, url, version_status.repo_api)) {
            self.api_calls += 1;
            return std.fmt.allocPrint(gpa, "{{\"tag_name\":\"{s}\"}}", .{self.published_tag}) catch return error.OutOfMemory;
        }
        var want_sums: [256]u8 = undefined;
        const ok_sums = std.fmt.bufPrint(&want_sums, "{s}/{s}/SHA256SUMS", .{ version_status.repo_download_base, self.published_tag }) catch unreachable;
        if (std.mem.eql(u8, url, ok_sums)) {
            if (self.bad_sums) return gpa.dupe(u8, "0000000000000000000000000000000000000000000000000000000000000000  graff-aarch64-macos.tar.gz\n") catch return error.OutOfMemory;
            return gpa.dupe(u8, self.sums) catch return error.OutOfMemory;
        }
        var want_asset: [256]u8 = undefined;
        const ok_asset = std.fmt.bufPrint(&want_asset, "{s}/{s}/graff-aarch64-macos.tar.gz", .{ version_status.repo_download_base, self.published_tag }) catch unreachable;
        if (std.mem.eql(u8, url, ok_asset)) return gpa.dupe(u8, self.archive) catch return error.OutOfMemory;
        return error.Offline;
    }

    fn fetch(self: *ReleaseFx) update_service.Fetch {
        return .{ .ctx = self, .get = get };
    }
};

test "installRelease verifies SHA256SUMS, falls back to latest on dev/unpublished tags, and leaves managed graff untouched" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = buf[0..try tmp.dir.realPath(io, &buf)];
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const a = state.allocator();

    const managed = try std.fmt.allocPrint(a, "{s}/.harness/bin/graff", .{home});
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(managed).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = managed, .data = "MANAGED-GRAFF" });

    const gz = try fixtureMacosArchive(gpa, true, "ARCHIVE-GRAFF", "SIGNED-NANOCUA");
    defer gpa.free(gz);
    const sums = try archive.sumsLine(gpa, "graff-aarch64-macos.tar.gz", gz);
    defer gpa.free(sums);

    // 1. Clean release tag matches directly without hitting releases/latest.
    var fx: ReleaseFx = .{ .archive = gz, .sums = sums };
    const r1 = installRelease(.{
        .io = io,
        .gpa = gpa,
        .home = home,
        .running_version = "0.302.74.4",
        .asset_name = "graff-aarch64-macos.tar.gz",
        .fetch = fx.fetch(),
        .is_macos = true,
    });
    try testing.expectEqual(ReleaseKind.installed, r1.kind);
    try testing.expectEqual(@as(usize, 0), fx.api_calls);
    try testing.expectEqualStrings("v0.302.74.4", r1.tag().?);
    try testing.expectEqualStrings("SIGNED-NANOCUA", try Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/Applications/nanocua.app/Contents/MacOS/nanocua", .{home}), a, .limited(64)));
    try testing.expectEqualStrings("MANAGED-GRAFF", try Io.Dir.cwd().readFileAlloc(io, managed, a, .limited(64)));

    // 2. Beta/dev or unpublished tag falls back to releases/latest.
    for ([_][]const u8{ "0.302.75-dev", "0.302.75" }) |ver| {
        var dev_fx: ReleaseFx = .{ .archive = gz, .sums = sums };
        const rd = installRelease(.{
            .io = io,
            .gpa = gpa,
            .home = home,
            .running_version = ver,
            .asset_name = "graff-aarch64-macos.tar.gz",
            .fetch = dev_fx.fetch(),
            .is_macos = true,
        });
        try testing.expectEqual(ReleaseKind.installed, rd.kind);
        try testing.expectEqual(@as(usize, 1), dev_fx.api_calls);
    }

    // 3. Bad checksum, missing bundle, non-macOS, and blocked path fail closed.
    var bad_fx: ReleaseFx = .{ .archive = gz, .sums = sums, .bad_sums = true };
    try testing.expectEqual(ReleaseKind.verify_failed, installRelease(.{
        .io = io,
        .gpa = gpa,
        .home = home,
        .running_version = "0.302.74.4",
        .asset_name = "graff-aarch64-macos.tar.gz",
        .fetch = bad_fx.fetch(),
        .is_macos = true,
    }).kind);

    const no_app_gz = try fixtureMacosArchive(gpa, false, "ARCHIVE-GRAFF", "");
    defer gpa.free(no_app_gz);
    const no_app_sums = try archive.sumsLine(gpa, "graff-aarch64-macos.tar.gz", no_app_gz);
    defer gpa.free(no_app_sums);
    var no_app_fx: ReleaseFx = .{ .archive = no_app_gz, .sums = no_app_sums };
    try testing.expectEqual(ReleaseKind.no_app, installRelease(.{
        .io = io,
        .gpa = gpa,
        .home = home,
        .running_version = "0.302.74.4",
        .asset_name = "graff-aarch64-macos.tar.gz",
        .fetch = no_app_fx.fetch(),
        .is_macos = true,
    }).kind);

    try testing.expectEqual(ReleaseKind.unsupported, installRelease(.{
        .io = io,
        .gpa = gpa,
        .home = home,
        .running_version = "0.302.74.4",
        .asset_name = "graff-aarch64-macos.tar.gz",
        .fetch = fx.fetch(),
        .is_macos = false,
    }).kind);

    const bad_home = try std.fmt.allocPrint(a, "{s}/blocked-home", .{home});
    try Io.Dir.cwd().createDirPath(io, bad_home);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/Applications", .{bad_home}), .data = "not-a-dir" });
    try testing.expectEqual(ReleaseKind.permission, installRelease(.{
        .io = io,
        .gpa = gpa,
        .home = bad_home,
        .running_version = "0.302.74.4",
        .asset_name = "graff-aarch64-macos.tar.gz",
        .fetch = fx.fetch(),
        .is_macos = true,
    }).kind);
}
