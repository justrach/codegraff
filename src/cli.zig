//! `graff update [--force|--check]`: compare the installed harness_version
//! against the latest GitHub release tag (SemVer parse; refuse to downgrade a
//! dev/newer build) and delegate the download / codesign / atomic swap to
//! install.sh. Split out of main.zig (600-line goal). Back-imports main for
//! harness_version. main aliases updateCommand back.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const root = @import("main.zig");
const harness_version = root.harness_version;

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

/// Parse a leading `MAJOR.MINOR.PATCH` from `s` (after any leading 'v' is
/// stripped by the caller). Returns null if the numeric triple isn't present.
fn parseVersion(s: []const u8) ?Version {
    var it = std.mem.splitScalar(u8, s, '.');
    const major_s = it.next() orelse return null;
    const minor_s = it.next() orelse return null;
    const patch_s = it.next() orelse return null;
    // Each component must be all digits up to the next '.' (or end). `patch`
    // may trail a pre-release suffix ("-3-gabc", "-dev"); take only the leading
    // digits so "0.0.14-3-gabc" parses as 0.0.14.
    const major = std.fmt.parseInt(u32, major_s, 10) catch return null;
    const minor = std.fmt.parseInt(u32, minor_s, 10) catch return null;
    const patch_digits = std.mem.indexOfAny(u8, patch_s, "-+") orelse patch_s.len;
    const patch = std.fmt.parseInt(u32, patch_s[0..patch_digits], 10) catch return null;
    return .{ .major = major, .minor = minor, .patch = patch };
}

/// True when `s` is a bare release version with no `git describe` suffix — i.e.
/// exactly `MAJOR.MINOR.PATCH` (optionally 'v'-prefixed), no "-N-gHASH",
/// "-dirty", "-dev", or "+build". A dev/dirty/commit-ahead build is not a clean
/// release and shouldn't be silently "updated" (downgraded) to an older tag.
fn isCleanReleaseVersion(s: []const u8) bool {
    if (s.len == 0) return false;
    var dots: u8 = 0;
    for (s) |c| {
        switch (c) {
            '0'...'9' => {},
            '.' => dots += 1,
            else => return false, // any '-','+','g',... means it's not a bare tag
        }
    }
    return dots == 2;
}

/// `graff update [--force|--check]` — bring the installed binary up to the
/// latest GitHub release. Checks the release tag first and skips when already
/// current (unless --force); --check only reports, never installs. The actual
/// download, codesign, and atomic binary swap are delegated to install.sh
/// (curl | sh) — that platform-specific logic already lives there, so we don't
/// reimplement it. HARNESS_NO_GRAFF=1 keeps the installer from also pulling in
/// the companion suite: an update touches only graff itself.
pub fn updateCommand(
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    environ: *const std.process.Environ.Map,
    force: bool,
    check_only: bool,
) !void {
    const repo_api = "https://api.github.com/repos/justrach/codegraff/releases/latest";
    const install_url = environ.get("GRAFF_INSTALL_URL") orelse environ.get("HARNESS_INSTALL_URL") orelse
        "https://github.com/justrach/codegraff/releases/latest/download/install.sh";

    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;

    // current version, leading 'v' stripped so the comparison ignores tag style.
    const cur_raw = if (std.mem.startsWith(u8, harness_version, "v")) harness_version[1..] else harness_version;

    // A release tag is a bare "MAJOR.MINOR.PATCH". A dev/dirty/commit-ahead
    // build (from `git describe --tags --always --dirty`) carries a suffix
    // ("-3-gabc", "-dirty", "-dev+hash", "0.1.0-dev") and is NOT a clean
    // release version. Comparing such a string against a release tag with exact
    // equality always mismatched, so `graff update` would "update" (downgrade)
    // a newer dev build to an older release, and `--check` always reported an
    // update available. Parse the leading numeric triple instead, and refuse to
    // act on a non-release local build rather than silently downgrading it.
    const cur = parseVersion(cur_raw);
    const cur_is_release = cur != null and isCleanReleaseVersion(cur_raw);

    // Query the latest release tag. GitHub's API requires a User-Agent; the
    // Accept header pins the v3 JSON response. Any failure → null, handled below.
    const latest_tag: ?[]const u8 = blk: {
        var client: std.http.Client = .{ .allocator = gpa, .io = io };
        defer client.deinit();
        var aw: Io.Writer.Allocating = .init(arena);
        defer aw.deinit();
        const extra = [_]std.http.Header{.{ .name = "Accept", .value = "application/vnd.github+json" }};
        const res = client.fetch(.{
            .location = .{ .url = repo_api },
            .method = .GET,
            .response_writer = &aw.writer,
            .headers = .{ .user_agent = .{ .override = "simple-harness/" ++ harness_version } },
            .extra_headers = &extra,
        }) catch break :blk null;
        if (@intFromEnum(res.status) != 200) break :blk null;
        // Cap the response before parsing: the endpoint is pinned to GitHub's
        // API (normally a small JSON blob), but a captive-portal redirect or a
        // TLS MITM could stream an unbounded body and exhaust memory. 64 KiB is
        // far above any legitimate /releases/latest payload.
        if (aw.writer.buffered().len > 64 * 1024) break :blk null;
        const v = std.json.parseFromSliceLeaky(Value, arena, aw.writer.buffered(), .{ .allocate = .alloc_always }) catch break :blk null;
        if (v != .object) break :blk null;
        const t = v.object.get("tag_name") orelse break :blk null;
        break :blk if (t == .string) t.string else null;
    };

    // `latest` is a release tag from GitHub, so it parses to a clean triple.
    const latest_raw = if (latest_tag) |tag| (if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag) else null;
    const latest = if (latest_raw) |r| parseVersion(r) else null;

    if (latest_tag != null and latest == null) {
        // The release endpoint returned a tag we couldn't parse — treat like a
        // failed check rather than guessing.
        if (check_only) std.process.fatal("update check failed — unparseable release tag '{s}'", .{latest_tag.?});
        try out.print("could not parse latest release tag '{s}'; running installer anyway…\n", .{latest_tag.?});
    } else if (latest != null) {
        const up_to_date = cur != null and cur.?.eql(latest.?);
        const cur_newer = cur != null and cur.?.order(latest.?) == .gt;

        if (check_only) {
            if (cur_is_release and up_to_date) {
                try out.print("graff is up to date (v{s})\n", .{cur_raw});
            } else if (cur_is_release and cur_newer) {
                try out.print("graff v{s} is newer than latest release v{s} — not downgrading\n", .{ cur_raw, latest_raw.? });
            } else if (cur_is_release) {
                // Release build older than latest.
                try out.print("update available: v{s} → v{s}  (run `graff update`)\n", .{ cur_raw, latest_raw.? });
            } else if (cur_newer) {
                // Dev/dirty build whose base version is ahead of the latest release.
                try out.print("local build v{s} is newer than latest release v{s} — not a release build; no update needed\n", .{ cur_raw, latest_raw.? });
            } else {
                // Dev/dirty build at or below the release version: installing the
                // release is reasonable if the user wants it.
                try out.print("update available: v{s} → v{s}  (local build {s} is not a release; run `graff update` to install the release)\n", .{ cur_raw, latest_raw.?, cur_raw });
            }
            try out.flush();
            return;
        }

        // Install path.
        if (up_to_date and cur_is_release and !force) {
            try out.print("graff is already up to date (v{s})\n", .{cur_raw});
            try out.flush();
            return;
        }
        // Refuse to downgrade a build whose version is strictly ahead of the
        // latest release without --force (applies to both release and dev builds
        // — installing would replace a newer version with an older one).
        if (cur_newer and !force) {
            try out.print("graff v{s} is newer than latest release v{s} — not downgrading (use --force to override)\n", .{ cur_raw, latest_raw.? });
            try out.flush();
            return;
        }
        try out.print("updating graff v{s} → v{s}…\n", .{ cur_raw, latest_raw.? });
    } else {
        // Version check failed (offline / rate-limited / bad response). For
        // --check that's a hard error; otherwise fall through to the installer,
        // which fetches the latest release on its own.
        if (check_only) std.process.fatal("update check failed — could not reach GitHub", .{});
        try out.writeAll("could not determine latest version; running installer anyway…\n");
    }
    try out.flush();

    // Delegate download/codesign/atomic swap to install.sh. Inherit our stdio
    // so its progress (and any sudo prompt) reaches the terminal directly.
    // "set -o pipefail" is required: without it, a failed "curl" is masked
    // by the right-hand "sh" exiting 0 on EOF, and the pipeline reports
    // success while installing nothing — silently.
    //
    // `install_url` is user-controllable via GRAFF_INSTALL_URL / HARNESS_INSTALL_URL,
    // so it MUST NOT be interpolated into the sh -c string (shell injection).
    // Pass it as positional $1 instead — the shell never re-parses it and curl
    // receives it verbatim.
    var child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "set -o pipefail; curl -fsSL \"$1\" | HARNESS_NO_GRAFF=1 sh", "sh", install_url },
    }) catch |err|
        std.process.fatal("update: could not launch installer: {t}", .{err});
    const term = child.wait(io) catch std.process.fatal("update: installer did not exit cleanly", .{});
    if (term != .exited or term.exited != 0)
        std.process.fatal("update: installer failed — try again or download manually from https://github.com/justrach/codegraff/releases/latest", .{});
}
