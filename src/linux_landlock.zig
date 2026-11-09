//! Zero-dependency Linux Landlock ABI v1–v3 constants, kernel probe, and
//! read-only sandbox denial annotation for subagent shell commands.
//!
//! When a read-only subagent runs under `bwrap` (Linux) or `sandbox-exec`
//! (macOS), write attempts inside protected checkout/gitdir paths fail with OS
//! permission/read-only errors (`EROFS`, `EACCES`, `EPERM`). Tagging those
//! failures explicitly as sandbox policy boundaries prevents the model from
//! retrying alternative write commands in a loop.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// `landlock_create_ruleset` flag to query the highest supported ABI version.
pub const LANDLOCK_CREATE_RULESET_VERSION: u32 = 1 << 0;

/// Rule type for `landlock_add_rule`.
pub const LANDLOCK_RULE_PATH_BENEATH: u32 = 1;

/// Landlock filesystem access rights (ABI v1..v3).
pub const LANDLOCK_ACCESS_FS_EXECUTE: u64 = 1 << 0;
pub const LANDLOCK_ACCESS_FS_WRITE_FILE: u64 = 1 << 1;
pub const LANDLOCK_ACCESS_FS_READ_FILE: u64 = 1 << 2;
pub const LANDLOCK_ACCESS_FS_READ_DIR: u64 = 1 << 3;
pub const LANDLOCK_ACCESS_FS_REMOVE_DIR: u64 = 1 << 4;
pub const LANDLOCK_ACCESS_FS_REMOVE_FILE: u64 = 1 << 5;
pub const LANDLOCK_ACCESS_FS_MAKE_CHAR: u64 = 1 << 6;
pub const LANDLOCK_ACCESS_FS_MAKE_DIR: u64 = 1 << 7;
pub const LANDLOCK_ACCESS_FS_MAKE_REG: u64 = 1 << 8;
pub const LANDLOCK_ACCESS_FS_MAKE_SOCK: u64 = 1 << 9;
pub const LANDLOCK_ACCESS_FS_MAKE_FIFO: u64 = 1 << 10;
pub const LANDLOCK_ACCESS_FS_MAKE_BLOCK: u64 = 1 << 11;
pub const LANDLOCK_ACCESS_FS_MAKE_SYM: u64 = 1 << 12;
pub const LANDLOCK_ACCESS_FS_REFER: u64 = 1 << 13; // ABI v2 (Linux 5.19+)
pub const LANDLOCK_ACCESS_FS_TRUNCATE: u64 = 1 << 14; // ABI v3 (Linux 6.2+)

/// Linux syscall numbers on both `x86_64` and `aarch64`.
pub const SYS_landlock_create_ruleset: usize = 444;
pub const SYS_landlock_add_rule: usize = 445;
pub const SYS_landlock_restrict_self: usize = 446;

pub const FS_READ_ONLY_MASK: u64 =
    LANDLOCK_ACCESS_FS_EXECUTE |
    LANDLOCK_ACCESS_FS_READ_FILE |
    LANDLOCK_ACCESS_FS_READ_DIR;

pub const FS_WRITE_V1_MASK: u64 =
    LANDLOCK_ACCESS_FS_WRITE_FILE |
    LANDLOCK_ACCESS_FS_REMOVE_DIR |
    LANDLOCK_ACCESS_FS_REMOVE_FILE |
    LANDLOCK_ACCESS_FS_MAKE_CHAR |
    LANDLOCK_ACCESS_FS_MAKE_DIR |
    LANDLOCK_ACCESS_FS_MAKE_REG |
    LANDLOCK_ACCESS_FS_MAKE_SOCK |
    LANDLOCK_ACCESS_FS_MAKE_FIFO |
    LANDLOCK_ACCESS_FS_MAKE_BLOCK |
    LANDLOCK_ACCESS_FS_MAKE_SYM;

/// Kernel `struct landlock_ruleset_attr`.
pub const RulesetAttr = extern struct {
    handled_access_fs: u64,
};

/// Kernel `struct landlock_path_beneath_attr` (`__attribute__((packed))` in UAPI).
pub const PathBeneathAttr = extern struct {
    allowed_access: u64 align(1),
    parent_fd: i32 align(1),
};

/// Returns the filesystem access mask handled by Landlock ABI `abi` (v1–v3+).
pub fn handledFsMaskForAbi(abi: u32) u64 {
    if (abi == 0) return 0;
    var mask: u64 = FS_READ_ONLY_MASK | FS_WRITE_V1_MASK;
    if (abi >= 2) mask |= LANDLOCK_ACCESS_FS_REFER;
    if (abi >= 3) mask |= LANDLOCK_ACCESS_FS_TRUNCATE;
    return mask;
}

/// Queries the running Linux kernel for its supported Landlock ABI version.
/// Returns `0` on non-Linux targets or when Landlock is disabled/unsupported.
pub fn probeAbiVersion() u32 {
    if (builtin.os.tag != .linux) return 0;
    const rc = std.os.linux.syscall3(.landlock_create_ruleset, 0, 0, LANDLOCK_CREATE_RULESET_VERSION);
    if (std.os.linux.errno(rc) != .SUCCESS) return 0;
    if (rc == 0 or rc > 64) return 0;
    return @intCast(rc);
}

pub const denial_notice = "\n[sandbox: write or privileged operation denied under read-only sandbox mode — do not retry writing to this path]";

pub const denial_signatures = [_][]const u8{
    "Read-only file system",
    "Operation not permitted",
    "Permission denied",
    "EACCES",
    "EROFS",
    "EPERM",
};

pub fn hasDenialSignature(text: []const u8) bool {
    for (denial_signatures) |sig| {
        if (std.mem.indexOf(u8, text, sig) != null) return true;
    }
    return false;
}

/// When a read-only sandboxed command exits non-zero (`exit_code != 0`) and its
/// output contains an OS write-denial signature (`EROFS`, `EACCES`, `EPERM`,
/// `"Read-only file system"`, `"Operation not permitted"`, `"Permission denied"`),
/// returns an allocated slice with `denial_notice` appended so the model
/// recognizes a policy boundary instead of retrying in a loop.
pub fn annotateSandboxDenial(a: Allocator, stderr_or_output: []const u8, exit_code: u8) ?[]const u8 {
    if (exit_code == 0 or stderr_or_output.len == 0) return null;
    if (std.mem.indexOf(u8, stderr_or_output, denial_notice) != null) return null;
    if (!hasDenialSignature(stderr_or_output)) return null;
    return std.fmt.allocPrint(a, "{s}{s}", .{ stderr_or_output, denial_notice }) catch null;
}

test "linux_landlock: UAPI struct layout and ABI v1-v3 access masks match kernel headers" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(RulesetAttr));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(PathBeneathAttr));
    try std.testing.expectEqual(@as(u64, 0), handledFsMaskForAbi(0));
    const v1 = handledFsMaskForAbi(1);
    try std.testing.expect((v1 & LANDLOCK_ACCESS_FS_WRITE_FILE) != 0);
    try std.testing.expect((v1 & LANDLOCK_ACCESS_FS_REFER) == 0);
    try std.testing.expect((v1 & LANDLOCK_ACCESS_FS_TRUNCATE) == 0);
    const v2 = handledFsMaskForAbi(2);
    try std.testing.expect((v2 & LANDLOCK_ACCESS_FS_REFER) != 0);
    try std.testing.expect((v2 & LANDLOCK_ACCESS_FS_TRUNCATE) == 0);
    const v3 = handledFsMaskForAbi(3);
    try std.testing.expect((v3 & LANDLOCK_ACCESS_FS_REFER) != 0);
    try std.testing.expect((v3 & LANDLOCK_ACCESS_FS_TRUNCATE) != 0);
}

test "linux_landlock: probeAbiVersion compiles across platforms and returns 0 on non-Linux" {
    const ver = probeAbiVersion();
    if (builtin.os.tag != .linux) {
        try std.testing.expectEqual(@as(u32, 0), ver);
    } else {
        try std.testing.expect(ver <= 64);
    }
}

test "linux_landlock: annotateSandboxDenial tags EROFS, Read-only file system, and Permission denied on non-zero exit" {
    const a = std.testing.allocator;

    const rofs = annotateSandboxDenial(a, "sh: 1: cannot create out.txt: Read-only file system\n[exit code 2]", 2).?;
    defer a.free(rofs);
    try std.testing.expect(std.mem.endsWith(u8, rofs, denial_notice));

    const erofs = annotateSandboxDenial(a, "OSError: [Errno 30] EROFS: 'out.txt'", 1).?;
    defer a.free(erofs);
    try std.testing.expect(std.mem.endsWith(u8, erofs, denial_notice));

    const eacces = annotateSandboxDenial(a, "tee: /repo/foo: Permission denied", 1).?;
    defer a.free(eacces);
    try std.testing.expect(std.mem.endsWith(u8, eacces, denial_notice));

    const eperm = annotateSandboxDenial(a, "sandbox-exec: Operation not permitted (EPERM)", 1).?;
    defer a.free(eperm);
    try std.testing.expect(std.mem.endsWith(u8, eperm, denial_notice));

    // Exit code 0 must not be tagged even if output mentions permission strings.
    try std.testing.expect(annotateSandboxDenial(a, "grep matched: Read-only file system", 0) == null);

    // Normal test/command failure without permission errors returns null.
    try std.testing.expect(annotateSandboxDenial(a, "FAIL: expected 42, found 41\n[exit code 1]", 1) == null);

    // Already-annotated output is not tagged a second time.
    try std.testing.expect(annotateSandboxDenial(a, rofs, 2) == null);
}
