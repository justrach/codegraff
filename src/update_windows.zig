//! `graff update` on Windows. The macOS/Linux path pipes install.sh through
//! /bin/sh, which Windows does not have, so updating died with "could not
//! launch installer". Here the release's install.ps1 runs under PowerShell.
//! It verifies SHA256SUMS and, because a running graff.exe cannot be
//! overwritten, renames it aside before copying the new one in. Both URL and
//! directory travel as environment variables, never interpolated into the
//! command string.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const default_url = "https://github.com/justrach/codegraff/releases/latest/download/install.ps1";

/// The PowerShell program: download the installer to a temp file, run it,
/// clean up, and exit non-zero on any failure.
pub const script =
    "$f = Join-Path ([IO.Path]::GetTempPath()) ('graff-update-' + [guid]::NewGuid().ToString('N') + '.ps1'); " ++
    "try { Invoke-WebRequest -UseBasicParsing -Uri $env:GRAFF_INSTALL_PS1_URL -OutFile $f; & $f; exit 0 } " ++
    "catch { Write-Host ('  error: ' + $_); exit 1 } " ++
    "finally { Remove-Item -Force -ErrorAction SilentlyContinue $f }";

/// The installer URL: `GRAFF_INSTALL_PS1_URL`, else a `GRAFF_INSTALL_URL`
/// that names a .ps1, else the latest release's install.ps1.
pub fn installerUrl(environ: *const std.process.Environ.Map) []const u8 {
    if (environ.get("GRAFF_INSTALL_PS1_URL")) |url| return url;
    if (environ.get("GRAFF_INSTALL_URL")) |url| {
        if (std.ascii.endsWithIgnoreCase(url, ".ps1")) return url;
    }
    return default_url;
}

/// Run install.ps1 into the running graff.exe's own directory. Returns
/// normally on success; exits the process with a message on failure.
pub fn run(io: Io, gpa: Allocator, environ: *const std.process.Environ.Map, out: *Io.Writer) !void {
    const exe = std.process.executablePathAlloc(io, gpa) catch std.process.fatal("update: cannot locate the running graff.exe", .{});
    defer gpa.free(exe);
    const dir = std.fs.path.dirname(exe) orelse std.process.fatal("update: cannot locate the running graff.exe", .{});

    var env = try environ.clone(gpa);
    defer env.deinit();
    try env.put("GRAFF_INSTALL_PS1_URL", installerUrl(environ));
    try env.put("GRAFF_INSTALL_DIR", dir);
    // Updating keeps the install where it is; PATH already finds it.
    try env.put("GRAFF_NO_PATH", "1");
    // Started from PowerShell 7, graff carries its PSModulePath, and Windows
    // PowerShell then cannot load its own modules (Get-FileHash is "not
    // recognized"). Without it powershell.exe uses its defaults.
    _ = env.swapRemove("PSModulePath");

    var child = std.process.spawn(io, .{
        .argv = &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script },
        .environ_map = &env,
    }) catch |err|
        std.process.fatal("update: could not launch PowerShell: {t}", .{err});
    const term = child.wait(io) catch std.process.fatal("update: installer did not exit cleanly", .{});
    if (term != .exited or term.exited != 0)
        std.process.fatal("update: installer failed — try again or run: irm {s} | iex", .{default_url});
    try out.writeAll("✓ update installed — restart every running graff session to load the new binary\n");
    try out.flush();
}

test "installerUrl prefers an explicit ps1 and ignores install.sh overrides" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try std.testing.expectEqualStrings(default_url, installerUrl(&env));
    try env.put("GRAFF_INSTALL_URL", "https://example.test/install.sh");
    try std.testing.expectEqualStrings(default_url, installerUrl(&env));
    try env.put("GRAFF_INSTALL_URL", "https://example.test/install.PS1");
    try std.testing.expectEqualStrings("https://example.test/install.PS1", installerUrl(&env));
    try env.put("GRAFF_INSTALL_PS1_URL", "https://example.test/pinned.ps1");
    try std.testing.expectEqualStrings("https://example.test/pinned.ps1", installerUrl(&env));
}

test "the PowerShell program reads its inputs from the environment only" {
    try std.testing.expect(std.mem.indexOf(u8, script, "$env:GRAFF_INSTALL_PS1_URL") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "exit 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "http") == null);
}
