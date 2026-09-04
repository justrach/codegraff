//! Self-update for the packaged macOS shell.
//!
//! The app ships outside the App Store, so nothing updates it for us. This
//! asks GitHub for the newest release, and installs it only after proving
//! the download is the same publisher's, notarized build — a downloaded
//! .app is arbitrary code, and the whole point of shipping signed is that
//! an update path cannot be the hole that lets unsigned code in.
//!
//! Everything here shells out to tools that are on every macOS install
//! (curl, ditto, codesign, spctl, osascript) rather than linking a network
//! or archive stack into a window shell. The ObjC side stays in main.zig:
//! this file takes the bundle path as a string, so it is plain Zig and its
//! version logic is testable.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const repo = "justrach/codegraff";
/// The release must carry the app as a zip whose name starts with this and
/// ends with `.zip` — `Codegraff.zip` and `Codegraff-macos.zip` both match.
const asset_prefix = "Codegraff";
/// A stalled network must never hold the window's own work; the check runs
/// on its own thread but a hung curl would still keep the process alive.
const net_timeout_s = "20";
const max_output = 4 * 1024 * 1024;

pub const Version = struct {
    major: u32 = 0,
    minor: u32 = 0,
    patch: u32 = 0,

    /// `v0.0.286`, `0.0.286`, `0.0.286-rc1` — anything after the patch digits
    /// is ignored, so a pre-release tag still compares on its numbers.
    pub fn parse(text: []const u8) ?Version {
        var rest = std.mem.trim(u8, text, " \t\r\n\"");
        if (rest.len > 0 and (rest[0] == 'v' or rest[0] == 'V')) rest = rest[1..];
        var out: Version = .{};
        const fields = [_]*u32{ &out.major, &out.minor, &out.patch };
        var i: usize = 0;
        for (fields, 0..) |field, n| {
            if (i >= rest.len or !std.ascii.isDigit(rest[i])) return if (n == 0) null else out;
            var value: u32 = 0;
            while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) {
                value = std.math.mul(u32, value, 10) catch return null;
                value = std.math.add(u32, value, rest[i] - '0') catch return null;
            }
            field.* = value;
            if (i < rest.len and rest[i] == '.') i += 1 else break;
        }
        return out;
    }

    /// True when `self` is a later release than `other`. Compared field by
    /// field, never as text: 0.0.10 is newer than 0.0.9, which a string
    /// comparison gets backwards.
    pub fn newerThan(self: Version, other: Version) bool {
        if (self.major != other.major) return self.major > other.major;
        if (self.minor != other.minor) return self.minor > other.minor;
        return self.patch > other.patch;
    }
};

const Run = struct {
    ok: bool,
    stdout: []u8,
    stderr: []u8,
};

/// Run a tool and collect its output. A tool that cannot be spawned is the
/// same answer as a tool that failed: no update.
fn run(gpa: Allocator, io: Io, argv: []const []const u8) ?Run {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_output),
        .stderr_limit = .limited(max_output),
    }) catch return null;
    return .{ .ok = result.term.success(), .stdout = result.stdout, .stderr = result.stderr };
}

/// The version this running app was built as, from its own Info.plist. A
/// loose dev binary has no bundle and no version, and deliberately never
/// updates itself — replacing a developer's build with a release is not a
/// fix, it is losing their work.
pub fn installedVersion(gpa: Allocator, bundle: []const u8) ?Version {
    const path = std.fmt.allocPrint(gpa, "{s}/Contents/Info.plist", .{bundle}) catch return null;
    defer gpa.free(path);
    const io = Io.Threaded.global_single_threaded.io();
    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch return null;
    defer gpa.free(text);
    return plistString(text, "CFBundleShortVersionString");
}

/// The value of `<key>name</key><string>…</string>`. A plist parser is a lot
/// of machinery for one well-known key in a file this app wrote itself.
fn plistString(text: []const u8, name: []const u8) ?Version {
    var key_buf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "<key>{s}</key>", .{name}) catch return null;
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const open = std.mem.indexOfPos(u8, text, at + key.len, "<string>") orelse return null;
    const close = std.mem.indexOfPos(u8, text, open, "</string>") orelse return null;
    return Version.parse(text[open + "<string>".len .. close]);
}

const Release = struct {
    tag: []const u8,
    url: []const u8,
};

const ApiRelease = struct {
    tag_name: []const u8 = "",
    assets: []const struct {
        name: []const u8 = "",
        browser_download_url: []const u8 = "",
    } = &.{},
};

/// The newest published release and the macOS app asset on it. Draft and
/// pre-release tags are not returned by this endpoint, so an unfinished
/// release cannot be handed to users mid-upload.
fn latest(gpa: Allocator, io: Io, arena: Allocator) ?Release {
    const url = "https://api.github.com/repos/" ++ repo ++ "/releases/latest";
    const got = run(gpa, io, &.{
        "curl", "-fsSL", "--max-time", net_timeout_s,
        "-H",   "Accept: application/vnd.github+json",
        url,
    }) orelse return null;
    defer gpa.free(got.stdout);
    defer gpa.free(got.stderr);
    if (!got.ok) return null;

    const parsed = std.json.parseFromSlice(ApiRelease, arena, got.stdout, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    const body = parsed.value;
    if (body.tag_name.len == 0) return null;
    for (body.assets) |asset| {
        if (!std.mem.startsWith(u8, asset.name, asset_prefix)) continue;
        if (!std.mem.endsWith(u8, asset.name, ".zip")) continue;
        return .{
            .tag = arena.dupe(u8, body.tag_name) catch return null,
            .url = arena.dupe(u8, asset.browser_download_url) catch return null,
        };
    }
    return null;
}

/// The Team ID out of `codesign -dv`, which prints to stderr. This is the
/// identity that has to match: an attacker can produce a validly signed,
/// even notarized app, but not one signed by this project's team.
fn teamOf(gpa: Allocator, io: Io, path: []const u8) ?[]u8 {
    const got = run(gpa, io, &.{ "codesign", "-dv", "--verbose=4", path }) orelse return null;
    defer gpa.free(got.stdout);
    defer gpa.free(got.stderr);
    if (!got.ok) return null;
    const needle = "TeamIdentifier=";
    const at = std.mem.indexOf(u8, got.stderr, needle) orelse return null;
    var end = at + needle.len;
    while (end < got.stderr.len and got.stderr[end] != '\n' and got.stderr[end] != '\r') end += 1;
    const team = std.mem.trim(u8, got.stderr[at + needle.len .. end], " \t");
    if (team.len == 0 or std.mem.eql(u8, team, "not set")) return null;
    return gpa.dupe(u8, team) catch null;
}

/// Every check a downloaded bundle must pass before it is allowed to
/// replace the running one. All three matter and none implies another:
/// the signature can be intact on an app signed by anybody, the team can
/// match on a build Apple never saw, and Gatekeeper's verdict is the only
/// thing that actually proves notarization.
fn trustworthy(gpa: Allocator, io: Io, candidate: []const u8, ours: []const u8) bool {
    if (run(gpa, io, &.{ "codesign", "--verify", "--deep", "--strict", candidate })) |r| {
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        if (!r.ok) {
            std.log.warn("update rejected: the download's signature does not verify", .{});
            return false;
        }
    } else return false;

    const theirs = teamOf(gpa, io, candidate) orelse {
        std.log.warn("update rejected: the download carries no Team ID", .{});
        return false;
    };
    defer gpa.free(theirs);
    if (!std.mem.eql(u8, ours, theirs)) {
        std.log.warn("update rejected: the download is signed by another team", .{});
        return false;
    }

    // `-t install` is the assessment that matches how this app is
    // distributed. `-t exec` rejects anything not from the App Store, so it
    // would refuse every notarized build we ever ship.
    if (run(gpa, io, &.{ "spctl", "-a", "-vv", "-t", "install", candidate })) |r| {
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        if (!r.ok) {
            std.log.warn("update rejected: Gatekeeper does not accept the download", .{});
            return false;
        }
    } else return false;

    return true;
}

/// Ask, once, and only when there is a verified build waiting. A dialog for
/// "you are up to date" or for a failed check would be noise; those go to
/// the log. Run through osascript so the question does not need the main
/// thread, which this check is deliberately not on.
fn accepted(gpa: Allocator, io: Io, tag: []const u8) bool {
    const script = std.fmt.allocPrint(gpa,
        \\display dialog "Codegraff {s} is ready to install." with title "Codegraff" buttons {{"Later", "Update and restart"}} default button "Update and restart"
    , .{tag}) catch return false;
    defer gpa.free(script);
    const got = run(gpa, io, &.{ "osascript", "-e", script }) orelse return false;
    defer gpa.free(got.stdout);
    defer gpa.free(got.stderr);
    return got.ok and std.mem.indexOf(u8, got.stdout, "Update and restart") != null;
}

/// Swap the bundle and relaunch. ditto is what keeps the signature intact —
/// a plain recursive copy does not always — and the running image stays
/// mapped, so replacing the bundle underneath ourselves is safe until exit.
fn install(gpa: Allocator, io: Io, staged: []const u8, bundle: []const u8) void {
    if (run(gpa, io, &.{ "rm", "-rf", bundle })) |r| {
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        if (!r.ok) {
            std.log.warn("update failed: could not clear the installed app", .{});
            return;
        }
    } else return;
    if (run(gpa, io, &.{ "ditto", staged, bundle })) |r| {
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        if (!r.ok) {
            std.log.warn("update failed: could not copy the new app into place", .{});
            return;
        }
    } else return;
    if (run(gpa, io, &.{ "open", "-n", bundle })) |r| {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    std.process.exit(0);
}

/// The whole flow, start to finish. Best effort throughout: every failure
/// leaves the installed app exactly as it was and says why in the log.
pub fn check(gpa: Allocator, bundle: []const u8) void {
    const io = Io.Threaded.global_single_threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const current = installedVersion(gpa, bundle) orelse {
        std.log.info("update check skipped: this build has no bundle version", .{});
        return;
    };
    const release = latest(gpa, io, arena) orelse return;
    const newest = Version.parse(release.tag) orelse return;
    if (!newest.newerThan(current)) return;

    const ours = teamOf(gpa, io, bundle) orelse {
        std.log.info("update check skipped: this build is unsigned", .{});
        return;
    };
    defer gpa.free(ours);

    var tmp_buf: [64]u8 = undefined;
    const stamp = Io.Timestamp.now(io, .real);
    const tmp = std.fmt.bufPrint(&tmp_buf, "/tmp/codegraff-update-{d}", .{stamp.nanoseconds}) catch return;
    defer if (run(gpa, io, &.{ "rm", "-rf", tmp })) |r| {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    };
    const zip = std.fmt.allocPrint(arena, "{s}/app.zip", .{tmp}) catch return;

    if (run(gpa, io, &.{ "mkdir", "-p", tmp })) |r| {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    } else return;
    if (run(gpa, io, &.{ "curl", "-fsSL", "--max-time", net_timeout_s, "-o", zip, release.url })) |r| {
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        if (!r.ok) {
            std.log.warn("update failed: could not download {s}", .{release.tag});
            return;
        }
    } else return;
    if (run(gpa, io, &.{ "ditto", "-x", "-k", zip, tmp })) |r| {
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        if (!r.ok) {
            std.log.warn("update failed: the download did not expand", .{});
            return;
        }
    } else return;

    const staged = std.fmt.allocPrint(arena, "{s}/Codegraff.app", .{tmp}) catch return;
    if (!trustworthy(gpa, io, staged, ours)) return;
    if (!accepted(gpa, io, release.tag)) return;
    install(gpa, io, staged, bundle);
}

test "a version is compared by number, not by text" {
    const nine = Version.parse("v0.0.9").?;
    const ten = Version.parse("v0.0.10").?;
    // The bug this guards: "0.0.10" sorts before "0.0.9" as text, so a
    // string comparison would never offer the newer release.
    try std.testing.expect(ten.newerThan(nine));
    try std.testing.expect(!nine.newerThan(ten));
    try std.testing.expect(!ten.newerThan(ten));

    try std.testing.expect(Version.parse("1.0.0").?.newerThan(Version.parse("0.9.9").?));
    try std.testing.expect(Version.parse("0.1.0").?.newerThan(Version.parse("0.0.999").?));
}

test "a tag parses with or without its v, and a partial one still reads" {
    try std.testing.expectEqual(Version{ .major = 0, .minor = 0, .patch = 286 }, Version.parse("v0.0.286").?);
    try std.testing.expectEqual(Version{ .major = 0, .minor = 0, .patch = 286 }, Version.parse("0.0.286").?);
    try std.testing.expectEqual(Version{ .major = 1, .minor = 2, .patch = 0 }, Version.parse("1.2").?);
    try std.testing.expectEqual(Version{ .major = 3, .minor = 0, .patch = 0 }, Version.parse("3").?);
    // A pre-release suffix compares on its numbers rather than failing.
    try std.testing.expectEqual(Version{ .major = 0, .minor = 0, .patch = 287 }, Version.parse("v0.0.287-rc1").?);
    try std.testing.expect(Version.parse("") == null);
    try std.testing.expect(Version.parse("main") == null);
}

test "the bundle version is read out of a plist" {
    const plist =
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleVersion</key>
        \\  <string>0.0.1</string>
        \\  <key>CFBundleShortVersionString</key>
        \\  <string>0.0.286</string>
        \\</dict>
        \\</plist>
    ;
    try std.testing.expectEqual(
        Version{ .major = 0, .minor = 0, .patch = 286 },
        plistString(plist, "CFBundleShortVersionString").?,
    );
    try std.testing.expect(plistString(plist, "CFBundleNothing") == null);
}
