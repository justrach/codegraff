//! Launch the separately installed fullscreen client before engine startup.
//!
//! Lookup: beside this executable, then PATH, then `~/.harness/tui/<version>`
//! (where the Harness app and graff's own first-use install put it). With none
//! found, graff offers to install it from the latest Harness release
//! (`tui_install.zig`); `--yes` accepts without asking. Once installed, no
//! network call is made.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const tui_install = @import("tui_install.zig");

const binary_name = if (builtin.os.tag == .windows) "graff-tui.exe" else "graff-tui";

/// Inspect raw arguments so UI flags (including --help) never reach graff's
/// parser. `graff -p "tui"` remains a normal prompt.
pub fn maybeRun(init: std.process.Init) !bool {
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer it.deinit();
    _ = it.next();
    const command = it.next() orelse return false;
    if (!std.mem.eql(u8, command, "tui")) return false;

    const a = init.arena.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, binary_name);
    // `--yes` is graff's (install consent), never the client's.
    var yes = false;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--yes")) {
            yes = true;
            continue;
        }
        try argv.append(a, arg);
    }

    // Prefer the companion shipped alongside this executable, then PATH.
    if (std.process.executableDirPathAlloc(init.io, a) catch null) |dir| {
        argv.items[0] = try std.fs.path.join(a, &.{ dir, binary_name });
        launchOrMissing(init.io, argv.items);
    }
    argv.items[0] = binary_name;
    launchOrMissing(init.io, argv.items);

    const home = init.environ_map.get("HOME") orelse "";
    const tui_root = tui_install.root(a, home) orelse std.process.fatal("{s} is not installed and HOME is not set. Install it from {s} and put bin/graff-tui on PATH.", .{ binary_name, tui_install.releases_page });
    if (tui_install.findInstalled(init.io, a, tui_root)) |installed| {
        argv.items[0] = installed;
        launchOrMissing(init.io, argv.items);
    }

    argv.items[0] = try firstUseInstall(init, a, tui_root, yes);
    launch(init.io, argv.items) catch |err| std.process.fatal("cannot launch {s}: {s}", .{ argv.items[0], @errorName(err) });
    unreachable;
}

/// Launch, returning only when the binary is not there.
fn launchOrMissing(io: Io, argv: []const []const u8) void {
    launch(io, argv) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.process.fatal("cannot launch {s}: {s}", .{ argv[0], @errorName(err) }),
    };
}

fn manualHint() []const u8 {
    return "To install it by hand, download harness-tui-<version>-<os>-<arch>.tar.gz and its .sha256 from " ++
        tui_install.releases_page ++ ", check it with `shasum -a 256 -c`, extract it, and put bin/graff-tui on PATH.";
}

/// Ask (or take `--yes`), then download, verify, and install the client.
fn firstUseInstall(init: std.process.Init, a: std.mem.Allocator, tui_root: []const u8, yes: bool) ![]const u8 {
    const io = init.io;
    var ebuf: [1024]u8 = undefined;
    var ew = Io.File.stderr().writer(io, &ebuf);
    const err_out = &ew.interface;

    const suffix = tui_install.platformSuffix() orelse std.process.fatal("{s} is not installed, and no prebuilt client exists for this OS and CPU. Build it from the Harness repository (tui/package.sh) and put bin/graff-tui on PATH.", .{binary_name});
    const interactive = (Io.File.stdin().isTty(io) catch false) and (Io.File.stderr().isTty(io) catch false);
    if (!yes and !interactive) std.process.fatal("{s} is not installed. Run `graff tui --yes` to download, verify, and install it. {s}", .{ binary_name, manualHint() });

    const body = tui_install.fetchLatest(io, init.gpa, a) catch std.process.fatal("{s} is not installed, and the latest Harness release could not be read (offline?). {s}", .{ binary_name, manualHint() });
    const release = tui_install.pick(a, body, suffix) catch |err| switch (err) {
        error.NoBuild => std.process.fatal("The latest Harness release has no {s} build of {s}. {s}", .{ suffix, binary_name, manualHint() }),
        error.NoChecksum => std.process.fatal("The latest Harness release publishes {s} without a .sha256, so it is not installed unverified. {s}", .{ binary_name, manualHint() }),
        else => std.process.fatal("The latest Harness release could not be read. {s}", .{manualHint()}),
    };

    if (!yes) {
        try err_out.print("{s} is not installed. Download {s} ({d} MB) from\n  {s}\nverify its SHA-256, and install it in {s}? [y/N] ", .{ binary_name, release.version, release.tarball.size / (1024 * 1024), release.tarball.url, tui_root });
        try err_out.flush();
        var ibuf: [256]u8 = undefined;
        var in = Io.File.stdin().reader(io, &ibuf);
        const answer = in.interface.takeDelimiter('\n') catch null;
        const ok = if (answer) |line| line.len > 0 and (line[0] == 'y' or line[0] == 'Y') else false;
        if (!ok) std.process.fatal("Not installed. {s}", .{manualHint()});
    }

    return tui_install.install(io, init.gpa, a, tui_root, release, err_out) catch |err| switch (err) {
        error.VerifyFailed => std.process.fatal("The download does not match its published SHA-256; nothing was installed. {s}", .{manualHint()}),
        error.Offline => std.process.fatal("The download failed; nothing was installed. {s}", .{manualHint()}),
        error.Broken => std.process.fatal("The downloaded client did not run; nothing was installed. {s}", .{manualHint()}),
        else => std.process.fatal("{s} could not be installed ({s}). {s}", .{ binary_name, @errorName(err), manualHint() }),
    };
}

fn launch(io: std.Io, argv: []const []const u8) !void {
    // POSIX replacement preserves the terminal, process identity, signals,
    // and exit status. Windows has no exec; inherit its handles and wait.
    if (builtin.os.tag != .windows) return std.process.replace(io, .{ .argv = argv });
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    std.process.exit(switch (term) {
        .exited => |code| code,
        else => 1,
    });
}

test {
    _ = tui_install;
}
