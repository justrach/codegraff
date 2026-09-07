//! Nonfatal, noninteractive in-session update service.
//!
//! Pins a GitHub release tag, downloads that tag's tarball + SHA256SUMS,
//! verifies, and atomically replaces a caller-supplied install path. Never
//! calls `graff update`, never runs install.sh, never inherits a TTY, never
//! execs or relaunches this process. Concurrent installs serialize; a
//! failure or cancel before commit leaves the existing file in place.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const version_status = @import("version_status.zig");
const update_target = @import("update_target.zig");
const archive = @import("update_archive.zig");
const credential_store = @import("credential_store.zig");

pub const FetchError = error{ Offline, Malformed, Permission, OutOfMemory };

pub const Fetch = struct {
    ctx: ?*anyopaque = null,
    get: *const fn (ctx: ?*anyopaque, gpa: Allocator, url: []const u8) FetchError![]u8,
};

pub const Consent = enum { human };

pub const Kind = enum {
    available,
    already_installed,
    current,
    newer,
    unsupported,
    package_managed,
    development,
    offline,
    malformed,
    verify_failed,
    permission,
    cancelled,
    busy,
    installed,
    no_consent,
};

pub const Report = struct {
    kind: Kind,
    target: []const u8 = "",
    detail: []const u8 = "",
    running_buf: [64]u8 = undefined,
    running_len: usize = 0,
    installed_buf: [64]u8 = undefined,
    installed_len: usize = 0,
    latest_buf: [64]u8 = undefined,
    latest_len: usize = 0,
    tag_buf: [64]u8 = undefined,
    tag_len: usize = 0,

    pub fn running(self: *const Report) []const u8 {
        return self.running_buf[0..self.running_len];
    }
    pub fn installed(self: *const Report) ?[]const u8 {
        return if (self.installed_len == 0) null else self.installed_buf[0..self.installed_len];
    }
    pub fn latest(self: *const Report) ?[]const u8 {
        return if (self.latest_len == 0) null else self.latest_buf[0..self.latest_len];
    }
    pub fn latest_tag(self: *const Report) ?[]const u8 {
        return if (self.tag_len == 0) null else self.tag_buf[0..self.tag_len];
    }
};

fn hold(buf: *[64]u8, src: []const u8) usize {
    const n = @min(src.len, buf.len);
    @memcpy(buf[0..n], src[0..n]);
    return n;
}

pub const Opts = struct {
    io: Io,
    gpa: Allocator,
    running_version: []const u8,
    target_path: []const u8,
    asset_name: []const u8,
    fetch: Fetch,
    cancel: ?*const std.atomic.Value(bool) = null,
};

var install_busy = std.atomic.Value(bool).init(false);

pub fn resetBusyForTest() void {
    install_busy.store(false, .release);
}

fn cancelled(opts: Opts) bool {
    const flag = opts.cancel orelse return false;
    return flag.load(.acquire);
}

fn tryLock() bool {
    return install_busy.cmpxchgStrong(false, true, .acq_rel, .acquire) == null;
}

fn unlock() void {
    install_busy.store(false, .release);
}

pub fn readInstalledVersion(io: Io, gpa: Allocator, target_path: []const u8) ?[]u8 {
    var side_buf: [std.fs.max_path_bytes + 8]u8 = undefined;
    const side = update_target.versionSidecar(target_path, &side_buf) orelse return null;
    return Io.Dir.cwd().readFileAlloc(io, side, gpa, .limited(128)) catch return null;
}

pub fn writeInstalledVersion(io: Io, target_path: []const u8, version: []const u8) void {
    var side_buf: [std.fs.max_path_bytes + 8]u8 = undefined;
    const side = update_target.versionSidecar(target_path, &side_buf) orelse return;
    const parent = std.fs.path.dirname(side) orelse return;
    var dir = Io.Dir.cwd().openDir(io, parent, .{}) catch return;
    defer dir.close(io);
    credential_store.replaceFile(io, dir, std.fs.path.basename(side), version, .default_file) catch {};
}

fn fetchOwned(opts: Opts, url: []const u8) FetchError![]u8 {
    return opts.fetch.get(opts.fetch.ctx, opts.gpa, url);
}

fn latestFromFetch(opts: Opts) FetchError![]u8 {
    const body = fetchOwned(opts, version_status.repo_api) catch |err| return err;
    defer opts.gpa.free(body);
    var tag_buf: [64]u8 = undefined;
    const tag = version_status.copyTagName(body, &tag_buf) orelse return error.Malformed;
    return opts.gpa.dupe(u8, tag);
}

fn snapshot(opts: Opts, kind: Kind, latest_tag: ?[]const u8, installed: ?[]const u8, detail: []const u8) Report {
    var r: Report = .{ .kind = kind, .target = opts.target_path, .detail = detail };
    r.running_len = hold(&r.running_buf, version_status.stripV(opts.running_version));
    if (installed) |v| r.installed_len = hold(&r.installed_buf, version_status.stripV(v));
    if (latest_tag) |t| {
        r.tag_len = hold(&r.tag_buf, t);
        r.latest_len = hold(&r.latest_buf, version_status.stripV(t));
    }
    return r;
}

pub fn inspect(opts: Opts) Report {
    const installed = readInstalledVersion(opts.io, opts.gpa, opts.target_path);
    defer if (installed) |v| opts.gpa.free(v);
    const tag = latestFromFetch(opts) catch |err| return snapshot(opts, switch (err) {
        error.Offline => .offline,
        error.Malformed => .malformed,
        error.Permission => .permission,
        error.OutOfMemory => .offline,
    }, null, installed, "could not reach the release feed");
    defer opts.gpa.free(tag);

    const run = version_status.compare(opts.running_version, tag);
    if (run.failure == .latest_tag) return snapshot(opts, .malformed, tag, installed, "unparseable release tag");

    if (installed) |inst| {
        if (version_status.alreadyHasRelease(inst, tag))
            return snapshot(opts, .already_installed, tag, inst, "the install target is already at this release");
    }

    return snapshot(opts, switch (run.state) {
        .current => .current,
        .older, .dev => if (run.order == .gt) .newer else .available,
        .newer => .newer,
        .unable => .malformed,
    }, tag, installed, "");
}

fn pinnedUrls(opts: Opts, tag: []const u8, asset_buf: *[512]u8, sums_buf: *[512]u8) error{Malformed}!struct { asset: []const u8, sums: []const u8 } {
    const asset = std.fmt.bufPrint(asset_buf, "{s}/{s}/{s}", .{
        version_status.repo_download_base, tag, opts.asset_name,
    }) catch return error.Malformed;
    const sums = std.fmt.bufPrint(sums_buf, "{s}/{s}/SHA256SUMS", .{
        version_status.repo_download_base, tag,
    }) catch return error.Malformed;
    return .{ .asset = asset, .sums = sums };
}

const exe_mode: Io.File.Permissions = if (Io.File.Permissions.has_executable_bit)
    Io.File.Permissions.fromMode(0o755)
else
    .default_file;

fn atomicPlace(io: Io, target_path: []const u8, bytes: []const u8) error{Permission}!void {
    const parent = std.fs.path.dirname(target_path) orelse return error.Permission;
    var dir = Io.Dir.cwd().openDir(io, parent, .{}) catch return error.Permission;
    defer dir.close(io);
    credential_store.replaceFile(io, dir, std.fs.path.basename(target_path), bytes, exe_mode) catch return error.Permission;
}

fn existingMatches(io: Io, gpa: Allocator, path: []const u8, bytes: []const u8) bool {
    const cur = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(80 * 1024 * 1024)) catch return false;
    defer gpa.free(cur);
    return std.mem.eql(u8, cur, bytes);
}

/// Install the pinned latest release into `opts.target_path`. Requires an
/// explicit `Consent.human` minted by the TTY picker or `/update install`
/// after a human `/update` check — yolo, tools, and saved transcripts never
/// call this.
pub fn install(opts: Opts, consent: Consent) Report {
    _ = consent;
    if (!tryLock()) return snapshot(opts, .busy, null, null, "an update is already installing");
    defer unlock();
    if (cancelled(opts)) return snapshot(opts, .cancelled, null, null, "update cancelled");

    const viewed = inspect(opts);
    switch (viewed.kind) {
        .available => {},
        .already_installed, .current, .newer, .offline, .malformed, .permission => return viewed,
        else => return viewed,
    }
    const tag = viewed.latest_tag() orelse return snapshot(opts, .malformed, null, viewed.installed(), "release tag missing");
    var tag_owned: [64]u8 = undefined;
    if (tag.len > tag_owned.len) return snapshot(opts, .malformed, null, viewed.installed(), "release tag missing");
    @memcpy(tag_owned[0..tag.len], tag);
    const tag_copy = tag_owned[0..tag.len];

    if (cancelled(opts)) return snapshot(opts, .cancelled, tag_copy, viewed.installed(), "update cancelled");

    var asset_url_buf: [512]u8 = undefined;
    var sums_url_buf: [512]u8 = undefined;
    const urls = pinnedUrls(opts, tag_copy, &asset_url_buf, &sums_url_buf) catch
        return snapshot(opts, .malformed, tag_copy, viewed.installed(), "could not pin release URLs");

    const sums = fetchOwned(opts, urls.sums) catch |err| return snapshot(opts, switch (err) {
        error.Offline => .offline,
        error.Malformed => .malformed,
        error.Permission => .permission,
        error.OutOfMemory => .offline,
    }, tag_copy, viewed.installed(), "SHA256SUMS unavailable — refusing to install");
    defer opts.gpa.free(sums);
    if (cancelled(opts)) return snapshot(opts, .cancelled, tag_copy, viewed.installed(), "update cancelled");

    const tarball = fetchOwned(opts, urls.asset) catch |err| return snapshot(opts, switch (err) {
        error.Offline => .offline,
        error.Malformed => .malformed,
        error.Permission => .permission,
        error.OutOfMemory => .offline,
    }, tag_copy, viewed.installed(), "release artifact unavailable");
    defer opts.gpa.free(tarball);
    if (cancelled(opts)) return snapshot(opts, .cancelled, tag_copy, viewed.installed(), "update cancelled");

    const bin = archive.extractVerified(opts.gpa, sums, opts.asset_name, tarball) catch |err| return snapshot(opts, switch (err) {
        error.VerifyFailed => .verify_failed,
        error.Malformed => .malformed,
        error.OutOfMemory => .offline,
    }, tag_copy, viewed.installed(), "artifact verification failed");
    defer opts.gpa.free(bin);
    if (cancelled(opts)) return snapshot(opts, .cancelled, tag_copy, viewed.installed(), "update cancelled");

    if (existingMatches(opts.io, opts.gpa, opts.target_path, bin)) {
        writeInstalledVersion(opts.io, opts.target_path, version_status.stripV(tag_copy));
        return snapshot(opts, .already_installed, tag_copy, version_status.stripV(tag_copy), "the install target already has these bytes");
    }

    atomicPlace(opts.io, opts.target_path, bin) catch
        return snapshot(opts, .permission, tag_copy, viewed.installed(), "install target is not writable — not escalating privileges");
    writeInstalledVersion(opts.io, opts.target_path, version_status.stripV(tag_copy));
    return snapshot(opts, .installed, tag_copy, version_status.stripV(tag_copy), update_target.install_note);
}

pub const HttpFetch = struct {
    io: Io,
    gpa: Allocator,
    user_agent: []const u8,
    max_bytes: usize = 80 * 1024 * 1024,

    pub fn get(ctx: ?*anyopaque, gpa: Allocator, url: []const u8) FetchError![]u8 {
        const self: *HttpFetch = @ptrCast(@alignCast(ctx orelse return error.Offline));
        var client: std.http.Client = .{ .allocator = self.gpa, .io = self.io };
        defer client.deinit();
        var aw: Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        const extra = [_]std.http.Header{.{ .name = "Accept", .value = "application/octet-stream" }};
        const res = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &aw.writer,
            .headers = .{ .user_agent = .{ .override = self.user_agent } },
            .extra_headers = &extra,
        }) catch return error.Offline;
        if (@intFromEnum(res.status) != 200) return error.Offline;
        if (aw.writer.buffered().len > self.max_bytes) return error.Malformed;
        return aw.toOwnedSlice() catch return error.OutOfMemory;
    }

    pub fn fetch(self: *HttpFetch) Fetch {
        return .{ .ctx = self, .get = get };
    }
};
