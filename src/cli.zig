//! `graff update [--force|--check]`: compare the installed harness_version
//! against the latest GitHub release tag (SemVer parse; refuse to downgrade a
//! dev/newer build) and delegate the download / codesign / atomic swap to
//! install.sh. Split out of main.zig (600-line goal). Back-imports main for
//! harness_version. main aliases updateCommand back.
//!
//! The --help/--version text is built separately by cli_text_source.zig.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const root = @import("main.zig");
const harness_version = root.harness_version;
const version_status = @import("version_status.zig");
const update_service = @import("update_service.zig");
const update_target = @import("update_target.zig");

/// Dim REPL/TUI line when GitHub has a newer release. Null if current, newer,
/// offline, or GRAFF_NO_UPDATE_CHECK is set.
pub fn updateAvailableLine(io: Io, gpa: Allocator, arena: Allocator, skip: bool) ?[]const u8 {
    if (skip) return null;
    const check = version_status.checkLatest(io, gpa, arena, harness_version);
    if (check.order != .lt) return null;
    return std.fmt.allocPrint(arena, "graff v{s} is available (you have {s}) — graff update", .{ check.latest.?, check.running }) catch null;
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
    const install_url = environ.get("GRAFF_INSTALL_URL") orelse environ.get("HARNESS_INSTALL_URL") orelse
        "https://github.com/justrach/codegraff/releases/latest/download/install.sh";

    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;

    const check = version_status.checkLatest(io, gpa, arena, harness_version);
    const cur_raw = check.running;
    const latest_tag = check.latest_tag;
    const latest_raw = check.latest;

    if (check.failure == .latest_tag) {
        // The release endpoint returned a tag we couldn't parse — treat like a
        // failed check rather than guessing.
        if (check_only) std.process.fatal("update check failed — unparseable release tag '{s}'", .{latest_tag.?});
        try out.print("could not parse latest release tag '{s}'; running installer anyway…\n", .{latest_tag.?});
    } else if (latest_raw != null) {
        const up_to_date = check.order == .eq;
        const cur_newer = check.order == .gt;
        const cur_is_release = check.clean_release;

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

    if (builtin.os.tag == .windows) return @import("update_windows.zig").run(io, gpa, environ, out);

    // Delegate download/codesign/atomic swap to install.sh. Inherit our stdio
    // so its progress (and any sudo prompt) reaches the terminal directly.
    // Download to a temp file, then run it: piping curl into sh would mask a
    // failed curl (sh exits 0 on EOF) unless "set -o pipefail" is on, and
    // /bin/sh is dash on Debian/Ubuntu, which rejects that option outright.
    //
    // `install_url` is user-controllable via GRAFF_INSTALL_URL / HARNESS_INSTALL_URL,
    // so it MUST NOT be interpolated into the sh -c string (shell injection).
    // Pass it as positional $1 instead — the shell never re-parses it and curl
    // receives it verbatim.
    var child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "f=$(mktemp) || exit 1; trap 'rm -f \"$f\"' EXIT; curl -fsSL \"$1\" -o \"$f\" || exit 1; HARNESS_NO_GRAFF=1 sh \"$f\"", "sh", install_url },
    }) catch |err|
        std.process.fatal("update: could not launch installer: {t}", .{err});
    const term = child.wait(io) catch std.process.fatal("update: installer did not exit cleanly", .{});
    if (term != .exited or term.exited != 0)
        std.process.fatal("update: installer failed — try again or download manually from https://github.com/justrach/codegraff/releases/latest", .{});
    try out.writeAll("✓ update installed — restart every running graff session to load the new binary\n");
    try out.flush();
}

/// Explicit beta opt-in. Resolve a tag on the newest numeric release branch,
/// then reuse the in-session updater's pinned checksum and atomic placement.
pub fn updateBetaCommand(io: Io, gpa: Allocator, arena: Allocator, environ: *const std.process.Environ.Map, check_only: bool) !void {
    const asset = update_target.assetName() orelse std.process.fatal("beta updates are unavailable on this platform", .{});
    const exe = std.process.executablePathAlloc(io, gpa) catch std.process.fatal("cannot locate the running graff executable", .{});
    defer gpa.free(exe);
    const home = environ.get("HOME") orelse "";
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = update_target.resolve(exe, home, &target_buf);
    if (target.kind != .supported) std.process.fatal("beta update: {s}", .{target.detail});

    var http: update_service.HttpFetch = .{ .io = io, .gpa = gpa, .user_agent = "simple-harness/" ++ harness_version };
    const opts: update_service.Opts = .{
        .io = io,
        .gpa = gpa,
        .running_version = harness_version,
        .target_path = target.path,
        .asset_name = asset,
        .fetch = http.fetch(),
        .channel = .beta,
    };
    var buf: [4096]u8 = undefined;
    var writer = Io.File.stdout().writer(io, &buf);
    const out = &writer.interface;
    const report = if (check_only) update_service.inspect(opts) else update_service.install(opts, .human);
    switch (report.kind) {
        .available => try out.print("beta available: {s} (run `graff update --beta`)\n", .{report.latest_tag().?}),
        .installed => try out.print("installed {s} for the next launch; restart graff to use it\n", .{report.latest_tag().?}),
        .current, .already_installed => try out.print("beta {s} is already installed\n", .{report.latest_tag().?}),
        .newer => try out.print("running graff v{s} is newer than beta {s}; keeping it\n", .{ report.running(), report.latest_tag().? }),
        .offline => std.process.fatal("beta update: could not reach GitHub or download a release asset", .{}),
        .malformed => std.process.fatal("beta update: no published beta for the newest release branch, or release metadata is invalid", .{}),
        .verify_failed => std.process.fatal("beta update: SHA256SUMS verification failed", .{}),
        .permission => std.process.fatal("beta update: cannot write {s}", .{target.path}),
        else => std.process.fatal("beta update: {s}", .{report.detail}),
    }
    try out.flush();
    _ = arena;
}
