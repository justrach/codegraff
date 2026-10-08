//! First-use install of the fullscreen client (#1444).
//!
//! `graff tui` runs `graff-tui`, which Harness publishes with each release as
//! `harness-tui-<version>-<os>-<arch>.tar.gz` plus `<tarball>.sha256`. When no
//! client is installed, the launcher asks once, then downloads this platform's
//! tarball from the latest Harness release, refuses it unless it matches its
//! published SHA-256, extracts it beside the install, checks that it runs
//! (`--version`), and only then renames it into `~/.harness/tui/<version>` —
//! the same place the Harness app installs it, so either install serves both.
//! An installed client is found without any network call.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const archive = @import("update_archive.zig");
const process_runner = @import("process_runner.zig");

pub const releases_api = "https://api.github.com/repos/justrach/harness/releases/latest";
pub const releases_page = "https://github.com/justrach/harness/releases";
const user_agent = "simple-harness/" ++ @import("main.zig").harness_version;

pub const Error = error{
    /// The release has no tarball for this platform.
    NoBuild,
    /// The tarball is published without its `.sha256`: never installed unverified.
    NoChecksum,
    /// The download does not match its published digest.
    VerifyFailed,
    /// The release metadata could not be read.
    Malformed,
    /// GitHub or the asset host could not be reached.
    Offline,
    /// The extracted client did not run.
    Broken,
};

/// The platform part of the tarball name, or null where Harness publishes none.
pub fn platformSuffix() ?[]const u8 {
    return switch (builtin.os.tag) {
        .macos => if (builtin.cpu.arch == .aarch64) "macos-aarch64" else null,
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => "linux-x86_64",
            .aarch64 => "linux-aarch64",
            else => null,
        },
        else => null,
    };
}

pub const Asset = struct { name: []const u8, url: []const u8, size: u64 };
pub const Release = struct { version: []const u8, tarball: Asset, sums: Asset };

/// This platform's tarball and its `.sha256` from a GitHub release document.
pub fn pick(arena: Allocator, body: []const u8, suffix: []const u8) Error!Release {
    const doc = std.json.parseFromSliceLeaky(Value, arena, body, .{}) catch return error.Malformed;
    if (doc != .object) return error.Malformed;
    const tag = doc.object.get("tag_name") orelse return error.Malformed;
    if (tag != .string) return error.Malformed;
    const version = if (std.mem.startsWith(u8, tag.string, "v")) tag.string[1..] else tag.string;
    const tarball_name = std.fmt.allocPrint(arena, "harness-tui-{s}-{s}.tar.gz", .{ version, suffix }) catch return error.Malformed;
    const sums_name = std.fmt.allocPrint(arena, "{s}.sha256", .{tarball_name}) catch return error.Malformed;
    const assets = doc.object.get("assets") orelse return error.Malformed;
    if (assets != .array) return error.Malformed;
    var tarball: ?Asset = null;
    var sums: ?Asset = null;
    for (assets.array.items) |item| {
        const asset = readAsset(item) orelse continue;
        if (std.mem.eql(u8, asset.name, tarball_name)) tarball = asset;
        if (std.mem.eql(u8, asset.name, sums_name)) sums = asset;
    }
    return .{
        .version = version,
        .tarball = tarball orelse return error.NoBuild,
        .sums = sums orelse return error.NoChecksum,
    };
}

fn readAsset(item: Value) ?Asset {
    if (item != .object) return null;
    const name = item.object.get("name") orelse return null;
    const url = item.object.get("browser_download_url") orelse return null;
    if (name != .string or url != .string) return null;
    const size: u64 = if (item.object.get("size")) |s| (if (s == .integer and s.integer >= 0) @intCast(s.integer) else 0) else 0;
    return .{ .name = name.string, .url = url.string, .size = size };
}

/// `~/.harness/tui`, where the Harness app installs the client too.
pub fn root(arena: Allocator, home: []const u8) ?[]const u8 {
    if (home.len == 0) return null;
    return std.fs.path.join(arena, &.{ home, ".harness", "tui" }) catch null;
}

fn parseVersion(name: []const u8) ?std.SemanticVersion {
    return std.SemanticVersion.parse(name) catch null;
}

/// The newest installed `<root>/<version>/bin/graff-tui`, if any.
pub fn findInstalled(io: Io, arena: Allocator, tui_root: []const u8) ?[]const u8 {
    var dir = Io.Dir.cwd().openDir(io, tui_root, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var best: ?std.SemanticVersion = null;
    var best_path: ?[]const u8 = null;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const version = parseVersion(entry.name) orelse continue;
        const path = std.fs.path.join(arena, &.{ tui_root, entry.name, "bin", "graff-tui" }) catch continue;
        _ = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        if (best == null or version.order(best.?) == .gt) {
            best = version;
            best_path = path;
        }
    }
    return best_path;
}

/// Stream `url` into the file at `path` (the tarball is too large to hold).
fn download(io: Io, gpa: Allocator, url: []const u8, path: []const u8) Error!void {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const file = Io.Dir.cwd().createFile(io, path, .{}) catch return error.Offline;
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &buf);
    const extra = [_]std.http.Header{.{ .name = "Accept", .value = "application/octet-stream" }};
    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &fw.interface,
        .headers = .{ .user_agent = .{ .override = user_agent } },
        .extra_headers = &extra,
    }) catch return error.Offline;
    if (@backingInt(res.status) != 200) return error.Offline;
    fw.interface.flush() catch return error.Offline;
}

/// The release document from GitHub's API.
pub fn fetchLatest(io: Io, gpa: Allocator, arena: Allocator) Error![]const u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var aw: Io.Writer.Allocating = .init(arena);
    const extra = [_]std.http.Header{.{ .name = "Accept", .value = "application/vnd.github+json" }};
    const res = client.fetch(.{
        .location = .{ .url = releases_api },
        .method = .GET,
        .response_writer = &aw.writer,
        .headers = .{ .user_agent = .{ .override = user_agent } },
        .extra_headers = &extra,
    }) catch return error.Offline;
    if (@backingInt(res.status) != 200) return error.Offline;
    return aw.writer.buffered();
}

/// Lowercase hex SHA-256 of the file at `path`, read in chunks.
fn sha256File(io: Io, path: []const u8, out: *[64]u8) Error![]const u8 {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return error.Offline;
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buf);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = reader.interface.readSliceShort(&chunk) catch return error.Offline;
        if (n == 0) break;
        hash.update(chunk[0..n]);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const digits = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0x0f];
    }
    return out;
}

/// `sums` (GNU sha256sum text) names `asset` with the digest `hex`.
pub fn matches(sums: []const u8, asset: []const u8, hex: []const u8) bool {
    const want = archive.digestFor(sums, asset) orelse return false;
    return std.ascii.eqlIgnoreCase(want, hex);
}

/// Download, verify, extract, check, and place `release` under `tui_root`.
/// Returns the installed `bin/graff-tui`. Nothing reaches `<root>/<version>`
/// unless every step passed; a failure leaves no partial install behind.
pub fn install(io: Io, gpa: Allocator, arena: Allocator, tui_root: []const u8, release: Release, log: *Io.Writer) Error![]const u8 {
    Io.Dir.cwd().createDirPath(io, tui_root) catch return error.Offline;
    const final_dir = std.fs.path.join(arena, &.{ tui_root, release.version }) catch return error.Malformed;
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const staging = std.fmt.allocPrint(arena, "{s}/.staging-{s}-{x}", .{ tui_root, release.version, std.mem.readInt(u64, &nonce, .little) }) catch return error.Malformed;
    Io.Dir.cwd().deleteTree(io, staging) catch {};
    Io.Dir.cwd().createDirPath(io, staging) catch return error.Offline;
    defer Io.Dir.cwd().deleteTree(io, staging) catch {};

    const sums_path = std.fs.path.join(arena, &.{ staging, release.sums.name }) catch return error.Malformed;
    const tar_path = std.fs.path.join(arena, &.{ staging, release.tarball.name }) catch return error.Malformed;
    try download(io, gpa, release.sums.url, sums_path);
    const sums = Io.Dir.cwd().readFileAlloc(io, sums_path, arena, .limited(4096)) catch return error.NoChecksum;
    log.print("downloading {s} ({d} MB)…\n", .{ release.tarball.name, release.tarball.size / (1024 * 1024) }) catch {};
    log.flush() catch {};
    try download(io, gpa, release.tarball.url, tar_path);
    var hex_buf: [64]u8 = undefined;
    const hex = try sha256File(io, tar_path, &hex_buf);
    if (!matches(sums, release.tarball.name, hex)) return error.VerifyFailed;
    log.print("verified sha256 {s}\n", .{hex}) catch {};
    log.flush() catch {};

    const untar = process_runner.runCapped(gpa, io, &.{ "tar", "-xzf", tar_path, "-C", staging }, 4096, 4096, 5 * 60 * 1000) catch return error.Broken;
    if (!process_runner.ranOk(untar)) return error.Broken;
    const top = release.tarball.name[0 .. release.tarball.name.len - ".tar.gz".len];
    const extracted = std.fs.path.join(arena, &.{ staging, top }) catch return error.Malformed;
    const exe = std.fs.path.join(arena, &.{ extracted, "bin", "graff-tui" }) catch return error.Malformed;
    const check = process_runner.runCapped(gpa, io, &.{ exe, "--version" }, 4096, 4096, 60 * 1000) catch return error.Broken;
    if (!process_runner.ranOk(check)) return error.Broken;

    // Another install (the Harness app, a second `graff tui`) may have landed
    // the same version meanwhile: keep that one.
    Io.Dir.cwd().renamePreserve(extracted, Io.Dir.cwd(), final_dir, io) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.Broken,
    };
    return std.fs.path.join(arena, &.{ final_dir, "bin", "graff-tui" }) catch error.Malformed;
}

test "pick finds this platform's tarball and its checksum" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const body =
        \\{"tag_name":"v0.2.111","assets":[
        \\ {"name":"harness-tui-0.2.111-linux-x86_64.tar.gz","browser_download_url":"https://x/l","size":10},
        \\ {"name":"harness-tui-0.2.111-macos-aarch64.tar.gz","browser_download_url":"https://x/m","size":110519353},
        \\ {"name":"harness-tui-0.2.111-macos-aarch64.tar.gz.sha256","browser_download_url":"https://x/m.sha256","size":105},
        \\ {"name":"Harness.dmg","browser_download_url":"https://x/d","size":1}]}
    ;
    const release = try pick(a, body, "macos-aarch64");
    try std.testing.expectEqualStrings("0.2.111", release.version);
    try std.testing.expectEqualStrings("https://x/m", release.tarball.url);
    try std.testing.expectEqual(@as(u64, 110519353), release.tarball.size);
    try std.testing.expectEqualStrings("https://x/m.sha256", release.sums.url);
    // A tarball without its checksum is never installed; a missing build is named.
    try std.testing.expectError(error.NoChecksum, pick(a, body, "linux-x86_64"));
    try std.testing.expectError(error.NoBuild, pick(a, body, "linux-aarch64"));
    try std.testing.expectError(error.Malformed, pick(a, "{}", "macos-aarch64"));
}

test "a digest matches only its own tarball" {
    const sums = "739c48d952911f2ce00547beb0b803a0c18f1cea6d566d2520ef3788f2f6caa3  harness-tui-0.0.0-macos-aarch64.tar.gz\n";
    try std.testing.expect(matches(sums, "harness-tui-0.0.0-macos-aarch64.tar.gz", "739C48D952911F2CE00547BEB0B803A0C18F1CEA6D566D2520EF3788F2F6CAA3"));
    try std.testing.expect(!matches(sums, "harness-tui-0.0.0-macos-aarch64.tar.gz", "0000000000000000000000000000000000000000000000000000000000000000"));
    try std.testing.expect(!matches("", "harness-tui-0.0.0-macos-aarch64.tar.gz", "0000000000000000000000000000000000000000000000000000000000000000"));
}

test "findInstalled picks the newest version that has the client" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    for ([_][]const u8{ "0.2.9/bin", "0.2.110/bin", "0.2.200", "codex-home" }) |sub| try tmp.dir.createDirPath(io, sub);
    try tmp.dir.writeFile(io, .{ .sub_path = "0.2.9/bin/graff-tui", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "0.2.110/bin/graff-tui", .data = "" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const found = findInstalled(io, a, base).?;
    try std.testing.expect(std.mem.endsWith(u8, found, "0.2.110/bin/graff-tui"));
    try std.testing.expect(findInstalled(io, a, "/nonexistent/graff-tui-root") == null);
}
