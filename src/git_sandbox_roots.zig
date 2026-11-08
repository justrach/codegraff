//! Protected read-only roots for shell sandboxes (Seatbelt and Linux bwrap).
//!
//! A read-only command whose leaf `cwd` is a subdirectory of a checkout under
//! `/tmp` (or `/private/var/folders`), or a linked git worktree whose `.git`
//! pointer and `commondir` reach back into a sibling checkout, must not write
//! to the enclosing repository, the worktree administrative directory, or the
//! shared primary repository.

const std = @import("std");
const Io = std.Io;

pub const max_roots = 8;

pub const Roots = struct {
    bufs: [max_roots][std.fs.max_path_bytes]u8 = undefined,
    slices: [max_roots][]const u8 = undefined,
    len: usize = 0,

    pub fn items(self: *const Roots) []const []const u8 {
        return self.slices[0..self.len];
    }

    pub fn add(self: *Roots, raw_path: []const u8) void {
        var p = raw_path;
        while (p.len > 1 and (p[p.len - 1] == '/' or p[p.len - 1] == '\\')) {
            p = p[0 .. p.len - 1];
        }
        if (p.len == 0 or p.len > std.fs.max_path_bytes or self.len >= max_roots) return;
        for (self.slices[0..self.len]) |existing| {
            if (std.mem.eql(u8, existing, p)) return;
        }
        const slot = &self.bufs[self.len];
        @memcpy(slot[0..p.len], p);
        self.slices[self.len] = slot[0..p.len];
        self.len += 1;
    }
};

/// Top-level OS scratch roots must never be promoted into read-only git roots
/// if a stray `.git` sits directly inside `/tmp` — doing so would disable temp
/// writes for every tool inside the sandbox.
pub fn isScratchRoot(path: []const u8) bool {
    var p = path;
    while (p.len > 1 and (p[p.len - 1] == '/' or p[p.len - 1] == '\\')) {
        p = p[0 .. p.len - 1];
    }
    const system_roots = [_][]const u8{
        "/",
        "/tmp",
        "/private/tmp",
        "/var/tmp",
        "/private/var/tmp",
        "/var/folders",
        "/private/var/folders",
    };
    for (system_roots) |sys_root| {
        if (std.mem.eql(u8, p, sys_root)) return true;
    }
    return false;
}

/// Extract `<target>` from a `.git` pointer file (`gitdir: <target>`).
pub fn parseGitdirPointer(text: []const u8) ?[]const u8 {
    const line_end = std.mem.indexOfAny(u8, text, "\r\n") orelse text.len;
    const line = std.mem.trim(u8, text[0..line_end], " \t");
    if (!std.mem.startsWith(u8, line, "gitdir:")) return null;
    const target = std.mem.trim(u8, line["gitdir:".len..], " \t");
    if (target.len == 0 or std.mem.indexOfScalar(u8, target, 0) != null) return null;
    return target;
}

fn realPathOrResolved(io: Io, path: []const u8, buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    if (Io.Dir.cwd().realPathFile(io, path, buf)) |n| return buf[0..n] else |_| {}
    const parent = std.fs.path.dirname(path) orelse return null;
    const base = std.fs.path.basename(path);
    if (base.len == 0) return null;
    var parent_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pn = Io.Dir.cwd().realPathFile(io, parent, &parent_buf) catch return null;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ parent_buf[0..pn], base }) catch null;
}

fn addGitAdminAndOwner(admin_canon: []const u8, out: *Roots) void {
    out.add(admin_canon);
    if (std.mem.eql(u8, std.fs.path.basename(admin_canon), ".git")) {
        if (std.fs.path.dirname(admin_canon)) |repo_dir| {
            if (!isScratchRoot(repo_dir)) out.add(repo_dir);
        }
    }
}

fn inspectCommondir(io: Io, gitdir_canon: []const u8, out: *Roots) void {
    var scratch: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const a = fba.allocator();

    const commondir_file = std.fs.path.join(a, &.{ gitdir_canon, "commondir" }) catch return;
    const raw_bytes = Io.Dir.cwd().readFileAlloc(io, commondir_file, a, .limited(4096)) catch return;
    const common_raw = std.mem.trim(u8, raw_bytes, " \t\r\n");
    if (common_raw.len == 0 or std.mem.indexOfAny(u8, common_raw, "\r\n\x00") != null) return;

    const resolved = std.fs.path.resolve(a, &.{ gitdir_canon, common_raw }) catch return;
    var canon_buf: [std.fs.max_path_bytes]u8 = undefined;
    const common_canon = realPathOrResolved(io, resolved, &canon_buf) orelse return;
    addGitAdminAndOwner(common_canon, out);
}

fn inspectGitFile(io: Io, worktree_dir: []const u8, git_file: []const u8, out: *Roots) void {
    var scratch: [16384]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const a = fba.allocator();

    const text = Io.Dir.cwd().readFileAlloc(io, git_file, a, .limited(4096)) catch return;
    const target_raw = parseGitdirPointer(text) orelse return;
    const resolved = std.fs.path.resolve(a, &.{ worktree_dir, target_raw }) catch return;

    var canon_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_canon = realPathOrResolved(io, resolved, &canon_buf) orelse return;
    addGitAdminAndOwner(target_canon, out);
    inspectCommondir(io, target_canon, out);
}

/// Collect `canonical_cwd` plus every enclosing git checkout, linked-worktree
/// `gitdir:`, and `commondir` (with its owning `<main_repo>` when `.git` is a
/// standard `<main_repo>/.git` directory).
pub fn discover(io: Io, canonical_cwd: []const u8, out: *Roots) []const []const u8 {
    out.len = 0;
    out.add(canonical_cwd);

    var cur = canonical_cwd;
    while (cur.len > 1 and (cur[cur.len - 1] == '/' or cur[cur.len - 1] == '\\')) {
        cur = cur[0 .. cur.len - 1];
    }

    var git_buf: [std.fs.max_path_bytes]u8 = undefined;
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (cur.len > 1) {
        if (std.fmt.bufPrint(&git_buf, "{s}/.git", .{cur})) |git_entry| {
            if (Io.Dir.cwd().statFile(io, git_entry, .{})) |st| {
                if (!isScratchRoot(cur)) out.add(cur);
                switch (st.kind) {
                    .directory => {
                        if (Io.Dir.cwd().realPathFile(io, git_entry, &real_buf)) |n| {
                            out.add(real_buf[0..n]);
                            inspectCommondir(io, real_buf[0..n], out);
                        } else |_| {}
                    },
                    .file => inspectGitFile(io, cur, git_entry, out),
                    else => {},
                }
            } else |_| {}
        } else |_| {}

        const parent = std.fs.path.dirname(cur) orelse break;
        if (parent.len == 0 or std.mem.eql(u8, parent, cur)) break;
        cur = parent;
    }
    return out.items();
}

fn containsRoot(roots: []const []const u8, needle: []const u8) bool {
    for (roots) |r| if (std.mem.eql(u8, r, needle)) return true;
    return false;
}

test "git_sandbox_roots: parseGitdirPointer handles whitespace, CRLF, and malformed pointers" {
    try std.testing.expectEqualStrings("/tmp/repo/.git/worktrees/wt", parseGitdirPointer("gitdir: /tmp/repo/.git/worktrees/wt\n").?);
    try std.testing.expectEqualStrings("../repo/.git/worktrees/wt", parseGitdirPointer("  gitdir:\t../repo/.git/worktrees/wt  \r\n").?);
    try std.testing.expect(parseGitdirPointer("") == null);
    try std.testing.expect(parseGitdirPointer("gitdir:   \n") == null);
    try std.testing.expect(parseGitdirPointer("not-gitdir: /tmp/x\n") == null);
    try std.testing.expect(parseGitdirPointer("gitdir: /tmp/a\x00b\n") == null);
}

test "git_sandbox_roots: nested subdir and linked worktrees protect main repo and bare gitdir" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "repo/.git/worktrees/wt-1");
    try tmp.dir.createDirPath(io, "repo/packages/api");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git/worktrees/wt-1/commondir", .data = "../..\n" });

    try tmp.dir.createDirPath(io, "wt-1/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "wt-1/.git", .data = "gitdir: ../repo/.git/worktrees/wt-1\n" });

    try tmp.dir.createDirPath(io, "bare.git/worktrees/wt-bare");
    try tmp.dir.writeFile(io, .{ .sub_path = "bare.git/worktrees/wt-bare/commondir", .data = "../..\n" });
    try tmp.dir.createDirPath(io, "wt-bare");
    try tmp.dir.writeFile(io, .{ .sub_path = "wt-bare/.git", .data = "gitdir: ../bare.git/worktrees/wt-bare\n" });

    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const repo = try std.fs.path.join(a, &.{ base, "repo" });
    defer a.free(repo);
    const repo_git = try std.fs.path.join(a, &.{ repo, ".git" });
    defer a.free(repo_git);
    const repo_api = try std.fs.path.join(a, &.{ repo, "packages", "api" });
    defer a.free(repo_api);
    const wt1 = try std.fs.path.join(a, &.{ base, "wt-1" });
    defer a.free(wt1);
    const wt1_sub = try std.fs.path.join(a, &.{ wt1, "sub" });
    defer a.free(wt1_sub);
    const wt1_admin = try std.fs.path.join(a, &.{ repo_git, "worktrees", "wt-1" });
    defer a.free(wt1_admin);

    var roots: Roots = .{};
    const sub_roots = discover(io, repo_api, &roots);
    try std.testing.expect(containsRoot(sub_roots, repo_api));
    try std.testing.expect(containsRoot(sub_roots, repo));
    try std.testing.expect(containsRoot(sub_roots, repo_git));

    const wt_roots = discover(io, wt1_sub, &roots);
    try std.testing.expect(containsRoot(wt_roots, wt1_sub));
    try std.testing.expect(containsRoot(wt_roots, wt1));
    try std.testing.expect(containsRoot(wt_roots, wt1_admin));
    try std.testing.expect(containsRoot(wt_roots, repo_git));
    try std.testing.expect(containsRoot(wt_roots, repo));

    const bare_git = try std.fs.path.join(a, &.{ base, "bare.git" });
    defer a.free(bare_git);
    const wt_bare = try std.fs.path.join(a, &.{ base, "wt-bare" });
    defer a.free(wt_bare);
    const wt_bare_admin = try std.fs.path.join(a, &.{ bare_git, "worktrees", "wt-bare" });
    defer a.free(wt_bare_admin);
    const bare_roots = discover(io, wt_bare, &roots);
    try std.testing.expect(containsRoot(bare_roots, wt_bare));
    try std.testing.expect(containsRoot(bare_roots, wt_bare_admin));
    try std.testing.expect(containsRoot(bare_roots, bare_git));
    try std.testing.expect(!containsRoot(bare_roots, base));
}
