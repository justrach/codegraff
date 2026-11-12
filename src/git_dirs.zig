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
//! git: discovery env vars, bare repos or a cwd inside a git dir, symlinks
//! anywhere in a resolved path, foreign ownership (safe.directory), repository
//! format extensions or config includes, unreadable or oversized files, and
//! every platform but macOS and Linux. `.not_git` is returned only where git
//! itself fails discovery.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Dirs = struct { git_dir: []const u8, common_dir: []const u8 };
pub const Result = union(enum) { not_git, found: Dirs, fallback };

const supported = builtin.os.tag == .macos or builtin.os.tag == .linux;

/// Present at all (even empty) means git's discovery may differ from ours.
pub const discovery_env = [_][:0]const u8{
    "GIT_DIR",                 "GIT_WORK_TREE",                   "GIT_COMMON_DIR",
    "GIT_CEILING_DIRECTORIES", "GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_OBJECT_DIRECTORY",
    "GIT_IMPLICIT_WORK_TREE",  "GIT_TEST_ASSUME_DIFFERENT_OWNER",
};

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

/// Repository format git is sure to accept: version 0/1, no extensions, no
/// includes that could add them. Anything else is git's call.
pub fn plainFormat(io: Io, arena: Allocator, common: []const u8) bool {
    const p = child(arena, common, "config") orelse return false;
    const raw = readSmall(io, arena, p, 64 * 1024) orelse return false;
    const text = std.ascii.allocLowerString(arena, raw) catch return false;
    if (std.mem.indexOf(u8, text, "[extensions") != null) return false;
    if (std.mem.indexOf(u8, text, "[include") != null) return false;
    const key = "repositoryformatversion";
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, key)) |i| {
        at = i + key.len;
        var v = std.mem.trimStart(u8, text[at..], " \t");
        if (v.len == 0 or v[0] != '=') return false;
        v = v[1..];
        const end = std.mem.indexOfAny(u8, v, "\n;#") orelse v.len;
        const val = std.mem.trim(u8, v[0..end], " \t\r");
        if (!std.mem.eql(u8, val, "0") and !std.mem.eql(u8, val, "1")) return false;
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
