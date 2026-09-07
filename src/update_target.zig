//! Resolve the on-disk graff the in-session updater may replace.
//!
//! Never PATH-lookup `graff` or `install.sh`. A project-local zig-out binary,
//! a Homebrew/Nix/apt prefix, or an unwritable system path is explained
//! rather than guessed or escalated.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const Kind = enum { supported, package_managed, development, unsupported };

pub const Target = struct {
    kind: Kind,
    path: []const u8,
    detail: []const u8,
};

pub const install_note =
    \\Update installed for the next launch. This session is still running its original version; you can keep working.
;

pub const no_activate_note =
    \\/new and /resume keep this process and do not activate the update.
;

pub fn assetTriple() ?[]const u8 {
    const os = builtin.os.tag;
    const arch = builtin.cpu.arch;
    return switch (os) {
        .macos => switch (arch) {
            .aarch64 => "aarch64-macos",
            .x86_64 => "x86_64-macos",
            else => null,
        },
        .linux => switch (arch) {
            .aarch64 => "aarch64-linux",
            .x86_64 => "x86_64-linux",
            else => null,
        },
        else => null,
    };
}

pub fn assetName() ?[]const u8 {
    const triple = assetTriple() orelse return null;
    return switch (builtin.os.tag) {
        .macos => if (std.mem.eql(u8, triple, "aarch64-macos"))
            "graff-aarch64-macos.tar.gz"
        else
            "graff-x86_64-macos.tar.gz",
        .linux => if (std.mem.eql(u8, triple, "aarch64-linux"))
            "graff-aarch64-linux.tar.gz"
        else
            "graff-x86_64-linux.tar.gz",
        else => null,
    };
}

pub fn versionSidecar(path: []const u8, buf: []u8) ?[]const u8 {
    const n = std.fmt.bufPrint(buf, "{s}.version", .{path}) catch return null;
    return n;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn basenameIs(path: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(path), name);
}

/// Classify an absolute (or user-supplied) executable path. `home` may be
/// empty; then `$HOME/bin` is not treated as the install.sh target.
pub fn classify(path: []const u8, home: []const u8) Kind {
    if (path.len == 0) return .unsupported;
    if (contains(path, "/Cellar/") or contains(path, "/linuxbrew/") or
        contains(path, "/Homebrew/") or contains(path, "/homebrew/"))
        return .package_managed;
    if (contains(path, "/nix/store/") or contains(path, "/.nix-profile/") or
        contains(path, "/nix-profile/"))
        return .package_managed;
    if (contains(path, "/snap/") or contains(path, "/flatpak/") or
        contains(path, "/var/lib/flatpak/"))
        return .package_managed;
    if (contains(path, "/opt/local/")) return .package_managed;
    if (std.mem.startsWith(u8, path, "/usr/bin/") or
        std.mem.startsWith(u8, path, "/bin/") or
        std.mem.startsWith(u8, path, "/usr/sbin/"))
        return .package_managed;
    if (contains(path, "/zig-out/bin/") or contains(path, "/.zig-cache/") or
        contains(path, "/zig-cache/"))
        return .development;
    if (home.len > 0) {
        if (underHomeBin(path, home, "bin") or underHomeBin(path, home, ".local/bin"))
            return .supported;
    }
    // A writable user prefix that is not a package tree. `/usr/local/bin`
    // is often Homebrew on Intel Macs — treat it as package-managed when
    // the basename is graff and it is not under $HOME.
    if (std.mem.startsWith(u8, path, "/usr/local/") or std.mem.startsWith(u8, path, "/opt/homebrew/"))
        return .package_managed;
    if (basenameIs(path, "graff") or basenameIs(path, "graff.exe")) return .supported;
    return .unsupported;
}

fn underHomeBin(path: []const u8, home: []const u8, rel: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "{s}/{s}/", .{ home, rel }) catch return false;
    return std.mem.startsWith(u8, path, prefix);
}

pub fn explain(kind: Kind) []const u8 {
    return switch (kind) {
        .supported => "writable user install (install.sh location)",
        .package_managed => "this install is package-managed — update it with the package manager, not /update",
        .development => "this process is a development build (zig-out); /update will not overwrite the checkout",
        .unsupported => "this platform or install location is not supported for in-session updates",
    };
}

/// Prefer the running executable when it is a supported user install.
/// A development process may still name `$HOME/bin/graff` as the future-launch
/// target when that path is classified supported — never zig-out, never PATH.
pub fn resolve(running_exe: []const u8, home: []const u8, buf: []u8) Target {
    const running_kind = classify(running_exe, home);
    if (running_kind == .supported) {
        return .{ .kind = .supported, .path = running_exe, .detail = explain(.supported) };
    }
    if (running_kind == .package_managed) {
        return .{ .kind = .package_managed, .path = running_exe, .detail = explain(.package_managed) };
    }
    if (home.len > 0) {
        const home_bin = std.fmt.bufPrint(buf, "{s}/bin/graff", .{home}) catch
            return .{ .kind = running_kind, .path = running_exe, .detail = explain(running_kind) };
        if (classify(home_bin, home) == .supported) {
            return .{
                .kind = .supported,
                .path = home_bin,
                .detail = "install.sh default ($HOME/bin/graff) — this process stays on its original binary",
            };
        }
    }
    return .{ .kind = running_kind, .path = running_exe, .detail = explain(running_kind) };
}

test "classify: package trees and zig-out never look supported" {
    try std.testing.expectEqual(Kind.package_managed, classify("/opt/homebrew/bin/graff", "/Users/me"));
    try std.testing.expectEqual(Kind.package_managed, classify("/usr/local/Cellar/graff/0.1/bin/graff", "/Users/me"));
    try std.testing.expectEqual(Kind.package_managed, classify("/nix/store/aaa/bin/graff", "/home/me"));
    try std.testing.expectEqual(Kind.package_managed, classify("/usr/bin/graff", "/home/me"));
    try std.testing.expectEqual(Kind.development, classify("/work/codegraff/zig-out/bin/graff", "/home/me"));
    try std.testing.expectEqual(Kind.supported, classify("/home/me/bin/graff", "/home/me"));
    try std.testing.expectEqual(Kind.supported, classify("/home/me/.local/bin/graff", "/home/me"));
}

test "resolve: a zig-out process names $HOME/bin, never the checkout" {
    var buf: [256]u8 = undefined;
    const t = resolve("/repo/zig-out/bin/graff", "/home/me", &buf);
    try std.testing.expectEqual(Kind.supported, t.kind);
    try std.testing.expectEqualStrings("/home/me/bin/graff", t.path);
}

test "resolve: Homebrew stays package-managed" {
    var buf: [256]u8 = undefined;
    const t = resolve("/opt/homebrew/bin/graff", "/Users/me", &buf);
    try std.testing.expectEqual(Kind.package_managed, t.kind);
    try std.testing.expect(std.mem.indexOf(u8, t.detail, "package-managed") != null);
}
