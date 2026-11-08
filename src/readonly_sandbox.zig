//! ADR 0232: a read-only child's foreground shell runs under an OS sandbox
//! (macOS Seatbelt `sandbox-exec`, Linux `bubblewrap` `bwrap` when unprivileged
//! namespaces work). Any command may run and read; nothing may write inside the
//! project (or its enclosing git repository / linked-worktree `gitdir:` and
//! `commondir`) or reach the network. Where no OS sandbox can run, or for a
//! command sent to the background, the read-only gate keeps its allowlist.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const git_roots = @import("git_sandbox_roots.zig");

/// Part of every macOS install; a missing binary fails the spawn, it never
/// runs the command unsandboxed.
pub const exe = "/usr/bin/sandbox-exec";
pub const supported = builtin.os.tag == .macos or builtin.os.tag == .linux;

const ProbeState = enum(u8) {
    unprobed = 0,
    ok = 1,
    unavailable = 2,
    probing = 3,
};

var linux_probe_state: std.atomic.Value(u8) = .init(@backingInt(ProbeState.unprobed));
var linux_bwrap_buf: [4096]u8 = undefined;
var linux_bwrap_len: usize = 0;

fn resolveBwrapBinary(io: Io, buf: *[4096]u8) ?[]const u8 {
    for ([_][]const u8{ "/usr/bin/bwrap", "/bin/bwrap" }) |fixed| {
        const st = Io.Dir.cwd().statFile(io, fixed, .{}) catch continue;
        if (st.kind == .directory) continue;
        @memcpy(buf[0..fixed.len], fixed);
        return buf[0..fixed.len];
    }
    const path_env: []const u8 = if (std.c.getenv("PATH")) |p| std.mem.span(p) else "";
    return @import("path_lookup.zig").resolve(io, path_env, "bwrap", buf);
}

fn runBwrapSelfCheck(io: Io, bwrap_exe: []const u8) bool {
    const has_bin_true = if (Io.Dir.cwd().access(io, "/bin/true", .{})) |_| true else |_| false;
    const has_usr_true = !has_bin_true and if (Io.Dir.cwd().access(io, "/usr/bin/true", .{})) |_| true else |_| false;
    var argv_buf: [18][]const u8 = undefined;
    const head = [_][]const u8{
        bwrap_exe,
        "--ro-bind",
        "/",
        "/",
        "--dev",
        "/dev",
        "--proc",
        "/proc",
        "--tmpfs",
        "/tmp",
        "--tmpfs",
        "/var/tmp",
        "--unshare-net",
        "--die-with-parent",
    };
    @memcpy(argv_buf[0..head.len], &head);
    var n: usize = head.len;
    if (has_bin_true) {
        argv_buf[n] = "/bin/true";
        n += 1;
    } else if (has_usr_true) {
        argv_buf[n] = "/usr/bin/true";
        n += 1;
    } else {
        argv_buf[n] = "/bin/sh";
        argv_buf[n + 1] = "-c";
        argv_buf[n + 2] = ":";
        n += 3;
    }
    var child = std.process.spawn(io, .{
        .argv = argv_buf[0..n],
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return term == .exited and term.exited == 0;
}

fn probeLinuxBwrapOnce(buf: *[4096]u8, len_out: *usize) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    const resolved = resolveBwrapBinary(io, buf) orelse return false;
    if (!runBwrapSelfCheck(io, resolved)) return false;
    len_out.* = resolved.len;
    return true;
}

fn ensureBwrapCached(
    state: *std.atomic.Value(u8),
    buf: *[4096]u8,
    len: *usize,
    probe_fn: *const fn (*[4096]u8, *usize) bool,
) ?[]const u8 {
    while (true) {
        switch (@as(ProbeState, @fromBackingInt(@intCast(state.load(.acquire))))) {
            .ok => return buf[0..len.*],
            .unavailable => return null,
            .probing => std.Thread.yield() catch std.atomic.spinLoopHint(),
            .unprobed => {
                if (state.cmpxchgWeak(
                    @backingInt(ProbeState.unprobed),
                    @backingInt(ProbeState.probing),
                    .acquire,
                    .monotonic,
                ) == null) {
                    const ok = probe_fn(buf, len);
                    state.store(@backingInt(if (ok) ProbeState.ok else ProbeState.unavailable), .release);
                    return if (ok) buf[0..len.*] else null;
                }
            },
        }
    }
}

pub fn linuxBwrapPath() ?[]const u8 {
    if (builtin.os.tag != .linux) return null;
    return ensureBwrapCached(&linux_probe_state, &linux_bwrap_buf, &linux_bwrap_len, probeLinuxBwrapOnce);
}

pub fn isAvailable() bool {
    return switch (builtin.os.tag) {
        .macos => true,
        .linux => linuxBwrapPath() != null,
        else => false,
    };
}

/// The gate's half: a foreground shell command is admitted because it will
/// run under the sandbox.
pub fn admits(input: std.json.Value) bool {
    return !@import("json_args.zig").flag(input, "run_in_background") and isAvailable();
}

/// Everything allowed; then every write denied but temp, terminal and
/// descriptor paths; then every write under each protected `roots` entry denied
/// again (the last matching rule wins, so a project or linked gitdir under /tmp
/// stays read-only); no network.
pub fn profileRoots(buf: []u8, roots: []const []const u8) ?[]const u8 {
    if (roots.len == 0) return null;
    var w: Io.Writer = .fixed(buf);
    w.writeAll("(version 1)(allow default)(deny file-write*)" ++
        "(allow file-write* (subpath \"/private/tmp\") (subpath \"/private/var/folders\") (literal \"/dev/null\") (regex #\"^/dev/tty\") (regex #\"^/dev/fd/\"))") catch return null;
    for (roots) |root| {
        w.writeAll("(deny file-write* (subpath \"") catch return null;
        for (root) |c| {
            if (c == '"' or c == '\\') w.writeByte('\\') catch return null;
            w.writeByte(c) catch return null;
        }
        w.writeAll("\"))") catch return null;
    }
    w.writeAll("(deny network*)") catch return null;
    return w.buffered();
}

pub fn profile(buf: []u8, root: []const u8) ?[]const u8 {
    return profileRoots(buf, &.{root});
}

fn beneathPosix(path: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path.len == root.len or path[root.len] == '/';
}

fn underLinuxTmpfs(path: []const u8) bool {
    return beneathPosix(path, "/tmp") or beneathPosix(path, "/var/tmp");
}

fn coveredByTmpAncestor(path: []const u8, roots: []const []const u8) bool {
    for (roots) |other| {
        if (other.len >= path.len or !underLinuxTmpfs(other)) continue;
        if (beneathPosix(path, other)) return true;
    }
    return false;
}

pub const max_argv = 48;
const profile_cap = if (builtin.os.tag == .macos) git_roots.max_roots * std.fs.max_path_bytes + 512 else 1;

pub const Argv = struct {
    roots: if (supported) git_roots.Roots else void = if (supported) .{} else {},
    profile: [profile_cap]u8 = undefined,
    argv: [max_argv][]const u8 = undefined,
};

/// Pure Linux `bwrap` argv builder: `--ro-bind / /`, writable `--tmpfs /tmp`
/// and `--tmpfs /var/tmp`, followed by `--ro-bind <root> <root>` for any
/// protected checkout/gitdir residing under `/tmp` or `/var/tmp` so scratch
/// stays writable while the checkout and its git metadata stay read-only.
pub fn buildLinuxArgv(
    bwrap_exe: []const u8,
    canonical_cwd: []const u8,
    roots: []const []const u8,
    cmd: []const u8,
    argv_out: *[max_argv][]const u8,
) ?[]const []const u8 {
    const head = [_][]const u8{
        bwrap_exe,
        "--ro-bind",
        "/",
        "/",
        "--dev",
        "/dev",
        "--proc",
        "/proc",
        "--tmpfs",
        "/tmp",
        "--tmpfs",
        "/var/tmp",
    };
    @memcpy(argv_out[0..head.len], &head);
    var i: usize = head.len;
    for (roots) |r| {
        if (!underLinuxTmpfs(r) or coveredByTmpAncestor(r, roots)) continue;
        if (i + 3 > argv_out.len) return null;
        argv_out[i] = "--ro-bind";
        argv_out[i + 1] = r;
        argv_out[i + 2] = r;
        i += 3;
    }
    const tail = [_][]const u8{
        "--chdir",
        canonical_cwd,
        "--unshare-net",
        "--die-with-parent",
        "/usr/bin/env",
        "GIT_OPTIONAL_LOCKS=0",
        "/bin/sh",
        "-c",
        cmd,
    };
    if (i + tail.len > argv_out.len) return null;
    @memcpy(argv_out[i .. i + tail.len], &tail);
    return argv_out[0 .. i + tail.len];
}

/// `cmd` under the sandbox, rooted at the real path of `cwd` (null: the
/// process cwd) plus any enclosing git repository or linked-worktree `gitdir:`
/// / `commondir`. Null when there is no sandbox here or the root does not
/// resolve; the caller then refuses anything the allowlist would not pass.
pub fn build(io: Io, cwd: ?[]const u8, cmd: []const u8, out: *Argv) ?[]const []const u8 {
    if (!supported) return null;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(io, cwd orelse ".", &cwd_buf) catch return null;
    const roots = git_roots.discover(io, cwd_buf[0..n], &out.roots);
    if (roots.len == 0) return null;
    const canonical_cwd = roots[0];
    return switch (builtin.os.tag) {
        .macos => blk: {
            const p = profileRoots(&out.profile, roots) orelse return null;
            // git status would take index.lock, a write the sandbox refuses.
            const mac_argv = [_][]const u8{ exe, "-p", p, "/usr/bin/env", "GIT_OPTIONAL_LOCKS=0", "/bin/sh", "-c", cmd };
            @memcpy(out.argv[0..mac_argv.len], &mac_argv);
            break :blk out.argv[0..mac_argv.len];
        },
        .linux => blk: {
            const bwrap_exe = linuxBwrapPath() orelse return null;
            break :blk buildLinuxArgv(bwrap_exe, canonical_cwd, roots, cmd, &out.argv);
        },
        else => null,
    };
}

/// The allowlist a read-only child keeps where there is no sandbox (the same
/// predicates plan mode and the read-only gate use).
pub fn allowlisted(cmd: []const u8) bool {
    const policy = @import("harness_policy.zig");
    const c = std.mem.trim(u8, cmd, " \t");
    return policy.readOnlyAllowed(c) or policy.readOnlyExternal(c);
}

pub const refusal = "this subagent is read-only (an informational task) and its shell sandbox is unavailable — run read-only commands from the allowlist (ls, cat, head, tail, wc, grep, rg, git status/diff/log/show), and report the change instead of making it";

test "read-only sandbox: the project is the last word on writes, and paths are quoted" {
    var buf: [1024]u8 = undefined;
    const p = profile(&buf, "/private/tmp/a \"b\"").?;
    try std.testing.expect(std.mem.endsWith(u8, p, "(deny file-write* (subpath \"/private/tmp/a \\\"b\\\"\"))(deny network*)"));
    try std.testing.expect(std.mem.indexOf(u8, p, "(allow file-write* (subpath \"/private/tmp\")").? < std.mem.lastIndexOf(u8, p, "(deny file-write*").?);

    const multi = profileRoots(&buf, &.{ "/private/tmp/wt", "/private/tmp/repo/.git/worktrees/wt", "/private/tmp/repo" }).?;
    try std.testing.expect(std.mem.indexOf(u8, multi, "(deny file-write* (subpath \"/private/tmp/wt\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, multi, "(deny file-write* (subpath \"/private/tmp/repo/.git/worktrees/wt\"))") != null);
    try std.testing.expect(std.mem.indexOf(u8, multi, "(deny file-write* (subpath \"/private/tmp/repo\"))(deny network*)") != null);

    var small: [16]u8 = undefined;
    try std.testing.expect(profile(&small, "/x") == null);
    try std.testing.expect(profileRoots(&buf, &.{}) == null);
}

test "read-only sandbox: linux bwrap argv orders tmpfs before /tmp and /var/tmp ro-binds" {
    var argv_buf: [max_argv][]const u8 = undefined;

    // Checkout outside /tmp needs no extra --ro-bind after --tmpfs.
    const home_argv = buildLinuxArgv("/usr/bin/bwrap", "/home/dev/repo/sub", &.{ "/home/dev/repo/sub", "/home/dev/repo" }, "python3 -V", &argv_buf).?;
    try std.testing.expectEqualStrings("/usr/bin/bwrap", home_argv[0]);
    try std.testing.expectEqualStrings("--chdir", home_argv[12]);
    try std.testing.expectEqualStrings("/home/dev/repo/sub", home_argv[13]);
    try std.testing.expectEqualStrings("--unshare-net", home_argv[14]);
    try std.testing.expectEqualStrings("--die-with-parent", home_argv[15]);
    try std.testing.expectEqualStrings("GIT_OPTIONAL_LOCKS=0", home_argv[17]);
    try std.testing.expectEqualStrings("python3 -V", home_argv[20]);

    // Linked worktree + main repo under /tmp and /var/tmp mount read-only AFTER --tmpfs.
    const tmp_roots = [_][]const u8{
        "/tmp/wt/sub",
        "/tmp/wt",
        "/tmp/repo/.git/worktrees/wt",
        "/tmp/repo/.git",
        "/tmp/repo",
        "/var/tmp/shared.git",
    };
    const tmp_argv = buildLinuxArgv("/usr/bin/bwrap", "/tmp/wt/sub", &tmp_roots, "git status", &argv_buf).?;
    var tmpfs_var_idx: ?usize = null;
    var ro_wt_idx: ?usize = null;
    var ro_repo_idx: ?usize = null;
    var ro_shared_idx: ?usize = null;
    var chdir_idx: ?usize = null;
    for (tmp_argv, 0..) |arg, idx| {
        if (idx > 0 and std.mem.eql(u8, tmp_argv[idx - 1], "--tmpfs") and std.mem.eql(u8, arg, "/var/tmp")) tmpfs_var_idx = idx - 1;
        if (idx >= 2 and std.mem.eql(u8, tmp_argv[idx - 2], "--ro-bind")) {
            if (std.mem.eql(u8, arg, "/tmp/wt")) ro_wt_idx = idx - 2;
            if (std.mem.eql(u8, arg, "/tmp/repo")) ro_repo_idx = idx - 2;
            if (std.mem.eql(u8, arg, "/var/tmp/shared.git")) ro_shared_idx = idx - 2;
            // Subpaths covered by /tmp/wt or /tmp/repo are not redundantly re-bound.
            try std.testing.expect(!std.mem.eql(u8, arg, "/tmp/wt/sub"));
            try std.testing.expect(!std.mem.eql(u8, arg, "/tmp/repo/.git"));
            try std.testing.expect(!std.mem.eql(u8, arg, "/tmp/repo/.git/worktrees/wt"));
        }
        if (std.mem.eql(u8, arg, "--chdir")) chdir_idx = idx;
    }
    try std.testing.expect(tmpfs_var_idx.? < ro_wt_idx.?);
    try std.testing.expect(ro_wt_idx.? < ro_repo_idx.?);
    try std.testing.expect(ro_repo_idx.? < ro_shared_idx.?);
    try std.testing.expect(ro_shared_idx.? < chdir_idx.?);
    try std.testing.expectEqualStrings("/tmp/wt/sub", tmp_argv[chdir_idx.? + 1]);
}

test "read-only sandbox: linux bwrap probe caches ok and unavailable states" {
    const Hooks = struct {
        var calls: usize = 0;
        fn okProbe(buf: *[4096]u8, len: *usize) bool {
            calls += 1;
            const p = "/usr/bin/bwrap";
            @memcpy(buf[0..p.len], p);
            len.* = p.len;
            return true;
        }
        fn failProbe(_: *[4096]u8, _: *usize) bool {
            calls += 1;
            return false;
        }
    };
    var state: std.atomic.Value(u8) = .init(@backingInt(ProbeState.unprobed));
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    Hooks.calls = 0;
    try std.testing.expectEqualStrings("/usr/bin/bwrap", ensureBwrapCached(&state, &buf, &len, Hooks.okProbe).?);
    try std.testing.expectEqualStrings("/usr/bin/bwrap", ensureBwrapCached(&state, &buf, &len, Hooks.okProbe).?);
    try std.testing.expectEqual(@as(usize, 1), Hooks.calls);

    state.store(@backingInt(ProbeState.unprobed), .release);
    Hooks.calls = 0;
    try std.testing.expect(ensureBwrapCached(&state, &buf, &len, Hooks.failProbe) == null);
    try std.testing.expect(ensureBwrapCached(&state, &buf, &len, Hooks.failProbe) == null);
    try std.testing.expectEqual(@as(usize, 1), Hooks.calls);
}

test "read-only sandbox: python reads and computes, writes in the project fail" {
    if (!isAvailable()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.txt", .data = "a b ERROR E401\n" });
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer gpa.free(dir);
    var out: Argv = .{};
    const argv = build(io, dir, "python3 -c \"print(open('in.txt').read().split()[3])\" && (echo no > out.txt || echo denied)", &out) orelse return error.SkipZigTest;
    const jobs = @import("jobs.zig");
    const run = jobs.runCappedWithOptions(gpa, io, argv, 4096, 4096, 20_000, jobs.toolRunOptions(dir)) catch return error.SkipZigTest;
    defer gpa.free(run.stdout);
    defer gpa.free(run.stderr);
    if (std.mem.indexOf(u8, run.stderr, "python3") != null and std.mem.indexOf(u8, run.stdout, "E401") == null) return error.SkipZigTest; // no python3 here
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "E401") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.stdout, "denied") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "out.txt", .{}));
}

test "read-only sandbox: subdir and linked worktree under /tmp block writes to parent repo and gitdir" {
    if (!isAvailable()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var rand_bytes: [6]u8 = undefined;
    io.random(&rand_bytes);
    const base = try std.fmt.allocPrint(gpa, "/tmp/graff-ro-wt-{s}", .{&std.fmt.bytesToHex(rand_bytes, .lower)});
    defer gpa.free(base);
    Io.Dir.cwd().createDirPath(io, base) catch return error.SkipZigTest;
    defer Io.Dir.cwd().deleteTree(io, base) catch {};

    const repo = try std.fmt.allocPrint(gpa, "{s}/repo", .{base});
    defer gpa.free(repo);
    const sub = try std.fmt.allocPrint(gpa, "{s}/packages/api", .{repo});
    defer gpa.free(sub);
    const wt = try std.fmt.allocPrint(gpa, "{s}/wt", .{base});
    defer gpa.free(wt);
    const scratch_ok = try std.fmt.allocPrint(gpa, "{s}/scratch-ok.txt", .{base});
    defer gpa.free(scratch_ok);

    const runner = @import("process_runner.zig");
    for ([_][]const []const u8{
        &.{ "git", "init", "-q", repo },
        &.{ "git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t.invalid", "commit", "-q", "--allow-empty", "-m", "init" },
        &.{ "git", "-C", repo, "worktree", "add", "-q", "--detach", wt },
    }) |git_argv| {
        const gr = runner.runCapped(gpa, io, git_argv, 4096, 4096, 15_000) catch return error.SkipZigTest;
        defer gpa.free(gr.stdout);
        defer gpa.free(gr.stderr);
        if (!runner.ranOk(gr)) return error.SkipZigTest;
    }
    try Io.Dir.cwd().createDirPath(io, sub);
    const data_file = try std.fmt.allocPrint(gpa, "{s}/val.txt", .{wt});
    defer gpa.free(data_file);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = data_file, .data = "OK42\n" });

    const jobs = @import("jobs.zig");

    // 1) Subfolder cwd inside /tmp/.../repo/packages/api cannot write to parent repo or repo/.git.
    const sub_cmd = try std.fmt.allocPrint(
        gpa,
        "echo ok > '{s}' && (echo x > ../../escaped.txt 2>/dev/null && echo SUB_ESCAPED || echo SUB_BLOCKED) && (echo x > ../../.git/pwn 2>/dev/null && echo GIT_ESCAPED || echo GIT_BLOCKED)",
        .{scratch_ok},
    );
    defer gpa.free(sub_cmd);
    var sub_out: Argv = .{};
    const sub_argv = build(io, sub, sub_cmd, &sub_out) orelse return error.TestUnexpectedResult;
    const sub_run = try jobs.runCappedWithOptions(gpa, io, sub_argv, 4096, 4096, 20_000, jobs.toolRunOptions(sub));
    defer gpa.free(sub_run.stdout);
    defer gpa.free(sub_run.stderr);
    try std.testing.expect(std.mem.indexOf(u8, sub_run.stdout, "SUB_BLOCKED") != null);
    try std.testing.expect(std.mem.indexOf(u8, sub_run.stdout, "GIT_BLOCKED") != null);

    // 2) Linked worktree /tmp/.../wt runs python3, cannot write to wt, parent repo, or repo/.git/worktrees/wt.
    const wt_cmd = try std.fmt.allocPrint(
        gpa,
        "python3 -c \"print(open('val.txt').read().strip())\" && (echo x > wt_write.txt 2>/dev/null && echo WT_ESCAPED || echo WT_BLOCKED) && (echo x > '{s}/escaped.txt' 2>/dev/null && echo REPO_ESCAPED || echo REPO_BLOCKED) && (echo x > '{s}/.git/worktrees/wt/pwn' 2>/dev/null && echo WT_GIT_ESCAPED || echo WT_GIT_BLOCKED)",
        .{ repo, repo },
    );
    defer gpa.free(wt_cmd);
    var wt_out: Argv = .{};
    const wt_argv = build(io, wt, wt_cmd, &wt_out) orelse return error.TestUnexpectedResult;
    const wt_run = try jobs.runCappedWithOptions(gpa, io, wt_argv, 4096, 4096, 20_000, jobs.toolRunOptions(wt));
    defer gpa.free(wt_run.stdout);
    defer gpa.free(wt_run.stderr);
    if (std.mem.indexOf(u8, wt_run.stderr, "python3") != null and std.mem.indexOf(u8, wt_run.stdout, "OK42") == null) return error.SkipZigTest;
    try std.testing.expect(std.mem.indexOf(u8, wt_run.stdout, "OK42") != null);
    try std.testing.expect(std.mem.indexOf(u8, wt_run.stdout, "WT_BLOCKED") != null);
    try std.testing.expect(std.mem.indexOf(u8, wt_run.stdout, "REPO_BLOCKED") != null);
    try std.testing.expect(std.mem.indexOf(u8, wt_run.stdout, "WT_GIT_BLOCKED") != null);
}
