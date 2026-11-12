//! In-process `git rev-parse --path-format=absolute --git-dir --git-common-dir`.
//!
//! Boot asks "which checkout am I in" three times (auto-isolate, startup
//! claim, presence). Each git spawn costs ~11 ms, so the common layouts are
//! answered here from the filesystem: a `.git` directory (main checkout) or a
//! `.git` file holding `gitdir:` (linked worktree, separate git dir). The walk
//! mirrors git's discovery (setup.c): `.git` first at each level, stop at a
//! filesystem boundary, validate HEAD / objects / refs, and print paths the
//! way `strbuf_realpath` does.
//!
//! Anything git could answer differently is `.fallback`, and the caller asks
//! git: discovery or config env vars, bare repos or a cwd inside a git dir,
//! symlinks anywhere in a resolved path, foreign ownership (safe.directory),
//! repository format extensions, any config file git would reject or that
//! git_config_check.zig cannot prove it accepts, unreadable or oversized
//! files, and every platform but macOS and Linux. `.not_git` is returned only
//! where git itself fails discovery.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config_check = @import("git_config_check.zig");

pub const Dirs = struct { git_dir: []const u8, common_dir: []const u8 };
pub const Result = union(enum) { not_git, found: Dirs, fallback };

const supported = builtin.os.tag == .macos or builtin.os.tag == .linux;

/// Present at all (even empty) means git's discovery, or the config files it
/// reads, may differ from ours.
pub const discovery_env = [_][:0]const u8{
    "GIT_DIR",                 "GIT_WORK_TREE",                   "GIT_COMMON_DIR",
    "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_OBJECT_DIRECTORY",
    "GIT_IMPLICIT_WORK_TREE",  "GIT_TEST_ASSUME_DIFFERENT_OWNER", "GIT_CONFIG_GLOBAL",
    "GIT_CONFIG_SYSTEM",       "GIT_CONFIG_PARAMETERS",
};

/// Tests only: check these files instead of the system and global configs.
pub var user_configs_for_test: ?[]const []const u8 = null;

/// Tests only: pretend a discovery env var is (true) or is not (false) set.
pub var env_override_for_test: ?bool = null;

pub fn envOverride() bool {
    if (env_override_for_test) |v| return v;
    if (comptime !supported) return true;
    for (discovery_env) |name| if (std.c.getenv(name.ptr) != null) return true;
    return false;
}

const Kind = enum { dir, file, link, other };
const Info = struct { kind: Kind, dev: u64, uid: u32 };
const Lstat = union(enum) { ok: Info, missing, failed };

fn kindOf(mode: u32) Kind {
    return switch (mode & 0o170000) {
        0o040000 => .dir,
        0o100000 => .file,
        0o120000 => .link,
        else => .other,
    };
}

fn lstat(path: []const u8) Lstat {
    if (comptime !supported) return .failed;
    var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len == 0 or path.len >= zbuf.len) return .failed;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    const z: [*:0]const u8 = zbuf[0..path.len :0];
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var sx: linux.Statx = undefined;
        const rc = linux.statx(linux.AT.FDCWD, z, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true }, &sx);
        return switch (linux.errno(rc)) {
            .SUCCESS => .{ .ok = .{ .kind = kindOf(sx.mode), .dev = (@as(u64, sx.dev_major) << 32) | sx.dev_minor, .uid = sx.uid } },
            .NOENT, .NOTDIR => .missing,
            else => .failed,
        };
    }
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, z, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) {
        return switch (std.posix.errno(@as(c_int, -1))) {
            .NOENT, .NOTDIR => .missing,
            else => .failed,
        };
    }
    return .{ .ok = .{ .kind = kindOf(@intCast(st.mode)), .dev = @bitCast(@as(i64, st.dev)), .uid = @intCast(st.uid) } };
}

/// git's `access(path, X_OK)` on objects/ and refs/.
fn searchable(path: []const u8) bool {
    var zbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len == 0 or path.len >= zbuf.len) return false;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    return std.c.access(zbuf[0..path.len :0], std.c.X_OK) == 0;
}

fn child(arena: Allocator, dir: []const u8, name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, dir, "/")) return std.fmt.allocPrint(arena, "/{s}", .{name}) catch null;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name }) catch null;
}

fn readSmall(io: Io, arena: Allocator, path: []const u8, cap: usize) ?[]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(cap)) catch null;
}

fn trimNewlines(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, "\r\n");
}

/// git's `strbuf_realpath` for a path with no symlink in it: `.` and `..`
/// fold lexically. Null when any component is a symlink or does not exist,
/// because then the OS realpath and git's may disagree.
pub fn plainRealPath(arena: Allocator, abs: []const u8) ?[]const u8 {
    if (!std.fs.path.isAbsolute(abs)) return null;
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, abs, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            out.shrinkRetainingCapacity(std.mem.lastIndexOfScalar(u8, out.items, '/') orelse 0);
            continue;
        }
        out.append(arena, '/') catch return null;
        out.appendSlice(arena, comp) catch return null;
        switch (lstat(out.items)) {
            .ok => |i| if (i.kind == .link) return null,
            else => return null,
        }
    }
    if (out.items.len == 0) return "/";
    return out.items;
}

/// setup.c `validate_headref`: a regular HEAD naming `refs/…` or an oid.
fn validHead(io: Io, arena: Allocator, git_dir: []const u8) bool {
    const p = child(arena, git_dir, "HEAD") orelse return false;
    switch (lstat(p)) {
        .ok => |i| if (i.kind != .file) return false,
        else => return false,
    }
    const bytes = readSmall(io, arena, p, 255) orelse return false;
    if (std.mem.startsWith(u8, bytes, "ref:")) {
        const rest = std.mem.trimStart(u8, bytes[4..], " \t\n\r\x0b\x0c");
        return std.mem.startsWith(u8, rest, "refs/");
    }
    if (bytes.len < 40) return false;
    for (bytes[0..40]) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn envPath(name: [:0]const u8) ?[]const u8 {
    if (comptime !supported) return null;
    const v = std.mem.span(std.c.getenv(name.ptr) orelse return null);
    return if (v.len > 0) v else null;
}

/// Every config file `git rev-parse` reads passes git_config_check.zig:
/// system (`/etc/gitconfig`; a git built with another prefix reads its own,
/// which is not checked), XDG and `~/.gitconfig`, then the repository's own
/// config, which must exist. Repository format version 0/1 and no extensions
/// are part of that check. Anything else is git's call.
pub fn plainFormat(io: Io, arena: Allocator, common: []const u8) bool {
    if (comptime !supported) return false;
    const home = envPath("HOME");
    if (home == null and std.c.getenv("HOME") != null) return false; // set but empty
    const ctx: config_check.Ctx = .{ .io = io, .arena = arena, .home = home };
    if (user_configs_for_test) |paths| {
        for (paths) |p| if (!config_check.fileOk(ctx, p, true)) return false;
    } else {
        if (!config_check.fileOk(ctx, "/etc/gitconfig", true)) return false;
        const xdg = if (envPath("XDG_CONFIG_HOME")) |x| child(arena, x, "git/config") else if (home) |h| child(arena, h, ".config/git/config") else null;
        if (xdg) |p| if (!config_check.fileOk(ctx, p, true)) return false;
        if (home) |h| if (!config_check.fileOk(ctx, child(arena, h, ".gitconfig") orelse return false, true)) return false;
    }
    const p = child(arena, common, "config") orelse return false;
    return config_check.fileOk(ctx, p, false) and envConfigOk(ctx);
}

/// `GIT_CONFIG_COUNT` pairs (graff's own tool shells set two). A count or
/// pair git would reject is git's call.
fn envConfigOk(ctx: config_check.Ctx) bool {
    const raw = std.mem.span(std.c.getenv("GIT_CONFIG_COUNT") orelse return true);
    if (raw.len == 0 or raw.len > 3) return false;
    for (raw) |c| if (!std.ascii.isDigit(c)) return false;
    const n = std.fmt.parseInt(u16, raw, 10) catch return false;
    for (0..n) |i| {
        var kb: [32]u8 = undefined;
        var vb: [32]u8 = undefined;
        const k = std.c.getenv((std.mem.printSentinel(&kb, "GIT_CONFIG_KEY_{d}", .{i}, 0) catch return false).ptr) orelse return false;
        const v = std.c.getenv((std.mem.printSentinel(&vb, "GIT_CONFIG_VALUE_{d}", .{i}, 0) catch return false).ptr) orelse return false;
        if (!config_check.pairOk(ctx, std.mem.span(k), std.mem.span(v))) return false;
    }
    return true;
}

/// setup.c `is_git_directory` plus the format check, for `git_dir` whose
/// shared parts live in `common`.
fn validRepo(io: Io, arena: Allocator, git_dir: []const u8, common: []const u8) bool {
    if (!validHead(io, arena, git_dir)) return false;
    const objects = child(arena, common, "objects") orelse return false;
    const refs = child(arena, common, "refs") orelse return false;
    return searchable(objects) and searchable(refs) and plainFormat(io, arena, common);
}

fn owned(path: []const u8, euid: u32) bool {
    return switch (lstat(path)) {
        .ok => |i| i.uid == euid,
        else => false,
    };
}

fn mainCheckout(io: Io, arena: Allocator, top: []const u8, dot_git: []const u8, euid: u32) Result {
    if (!owned(top, euid) or !owned(dot_git, euid)) return .fallback;
    const commondir = child(arena, dot_git, "commondir") orelse return .fallback;
    if (lstat(commondir) != .missing) return .fallback;
    if (!validRepo(io, arena, dot_git, dot_git)) return .fallback;
    return .{ .found = .{ .git_dir = dot_git, .common_dir = dot_git } };
}

fn gitFile(io: Io, arena: Allocator, top: []const u8, dot_git: []const u8, euid: u32) Result {
    const bytes = readSmall(io, arena, dot_git, 4096) orelse return .fallback;
    const prefix = "gitdir: ";
    if (!std.mem.startsWith(u8, bytes, prefix)) return .fallback;
    const raw = trimNewlines(bytes[prefix.len..]);
    if (raw.len == 0 or std.mem.indexOfScalar(u8, raw, 0) != null) return .fallback;
    const joined = if (std.fs.path.isAbsolute(raw)) raw else (child(arena, top, raw) orelse return .fallback);
    const git_dir = plainRealPath(arena, joined) orelse return .fallback;
    if (!owned(dot_git, euid) or !owned(top, euid) or !owned(git_dir, euid)) return .fallback;
    const commondir = child(arena, git_dir, "commondir") orelse return .fallback;
    const common = switch (lstat(commondir)) {
        .missing => git_dir,
        .ok => |i| blk: {
            if (i.kind != .file) return .fallback;
            const data = trimNewlines(readSmall(io, arena, commondir, 4096) orelse return .fallback);
            if (data.len == 0) return .fallback;
            const path = if (std.fs.path.isAbsolute(data)) data else (child(arena, git_dir, data) orelse return .fallback);
            break :blk plainRealPath(arena, path) orelse return .fallback;
        },
        .failed => return .fallback,
    };
    if (!validRepo(io, arena, git_dir, common)) return .fallback;
    return .{ .found = .{ .git_dir = git_dir, .common_dir = common } };
}

/// Resolve from `start`, an absolute physical directory path (getcwd or a
/// realpath). The strings in `.found` are what git prints, byte for byte.
pub fn resolve(io: Io, arena: Allocator, start: []const u8) Result {
    if (comptime !supported) return .fallback;
    if (envOverride()) return .fallback;
    if (!std.fs.path.isAbsolute(start)) return .fallback;
    const euid: u32 = @intCast(std.c.geteuid());
    if (euid == 0) return .fallback; // git consults SUDO_UID for root
    const first = switch (lstat(start)) {
        .ok => |i| i,
        else => return .fallback,
    };
    if (first.kind != .dir) return .fallback;
    var cur: []const u8 = if (start.len > 1) std.mem.trimEnd(u8, start, "/") else start;
    if (cur.len == 0) cur = "/";
    while (true) {
        const dot_git = child(arena, cur, ".git") orelse return .fallback;
        switch (lstat(dot_git)) {
            .ok => |i| return switch (i.kind) {
                .dir => mainCheckout(io, arena, cur, dot_git, euid),
                .file => gitFile(io, arena, cur, dot_git, euid),
                else => .fallback,
            },
            .missing => {},
            .failed => return .fallback,
        }
        // A directory holding HEAD may be a bare repo or the inside of a git
        // dir — git's `is_git_directory` branch. Never guess.
        const head = child(arena, cur, "HEAD") orelse return .fallback;
        switch (lstat(head)) {
            .missing => {},
            else => return .fallback,
        }
        if (std.mem.eql(u8, cur, "/")) return .not_git;
        const parent = std.fs.path.dirname(cur) orelse return .not_git;
        switch (lstat(parent)) {
            // git stops at a filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM unset).
            .ok => |i| if (i.dev != first.dev) return .not_git,
            else => return .fallback,
        }
        cur = parent;
    }
}

test {
    _ = @import("git_dirs_tests.zig");
}
