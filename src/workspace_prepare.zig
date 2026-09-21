//! After minting a task worktree: copy selected gitignored files and run
//! project scripts from `.graff/workspace.toml`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const gitignore = @import("gitignore.zig");
const process_runner = @import("process_runner.zig");
const runCapped = process_runner.runCapped;
const runCappedWithOptions = process_runner.runCappedWithOptions;
const ranOk = process_runner.ranOk;
const worktree_lease = @import("worktree_lease.zig");
const worktree_prune = @import("worktree_prune.zig");

const max_copy_bytes: std.Io.Limit = .limited(1 << 20);
const max_walk: usize = 4000;
const max_copies: usize = 256;
const setup_ms: u64 = 10 * 60 * 1000;
const archive_ms: u64 = 60 * 1000;
const run_ms: u64 = 0; // wait until exit (jobs cap)

pub const Scripts = struct {
    setup: []const u8 = "",
    run: []const u8 = "",
    archive: []const u8 = "",
};

pub const Report = struct {
    copied: usize = 0,
    setup_ran: bool = false,
    setup_ok: bool = true,
};

pub fn mainCheckout(gpa: Allocator, io: Io, arena: Allocator, cwd: []const u8) []const u8 {
    const common = worktree_lease.gitCommonDirAt(gpa, io, arena, cwd);
    const main_path = worktree_prune.mainWorktreePath(common);
    if (main_path.len > 0) return main_path;
    return cwd;
}

pub fn parseScripts(text: []const u8) Scripts {
    return .{
        .setup = tomlString(text, "setup") orelse "",
        .run = tomlString(text, "run") orelse "",
        .archive = tomlString(text, "archive") orelse "",
    };
}

pub fn parseIncludeGlobs(text: []const u8) ?[]const u8 {
    return tomlString(text, "include") orelse tomlString(text, "file_include_globs");
}

/// `.worktreeinclude` wins; else `include` in `.graff/workspace.toml`; else `.env*`.
pub fn includeText(arena: Allocator, io: Io, root: []const u8) []const u8 {
    if (readOptional(io, arena, root, ".worktreeinclude")) |t| return t;
    if (readOptional(io, arena, root, ".graff/workspace.toml")) |t| {
        if (parseIncludeGlobs(t)) |g| return g;
    }
    return ".env*\n.env\n";
}

pub fn loadScripts(arena: Allocator, io: Io, root: []const u8) Scripts {
    if (readOptional(io, arena, root, ".graff/workspace.toml")) |t| return parseScripts(t);
    return .{};
}

pub fn afterCreate(gpa: Allocator, io: Io, arena: Allocator, cwd: []const u8, dest: []const u8, name: []const u8) Report {
    const root = mainCheckout(gpa, io, arena, cwd);
    var report: Report = .{};
    report.copied = copyIgnored(gpa, io, arena, root, dest);
    const scripts = loadScripts(arena, io, root);
    if (scripts.setup.len == 0) return report;
    report.setup_ran = true;
    report.setup_ok = runScript(gpa, io, arena, scripts.setup, dest, root, name, setup_ms);
    return report;
}

pub fn beforeArchive(gpa: Allocator, io: Io, arena: Allocator, cwd: []const u8, dest: []const u8, name: []const u8) void {
    const root = mainCheckout(gpa, io, arena, cwd);
    const scripts = loadScripts(arena, io, root);
    if (scripts.archive.len == 0) return;
    _ = runScript(gpa, io, arena, scripts.archive, dest, root, name, archive_ms);
}

pub fn runNamed(gpa: Allocator, io: Io, arena: Allocator, cwd: []const u8, dest: []const u8, name: []const u8) bool {
    const root = mainCheckout(gpa, io, arena, cwd);
    const scripts = loadScripts(arena, io, root);
    if (scripts.run.len == 0) return false;
    return runScript(gpa, io, arena, scripts.run, dest, root, name, run_ms);
}

pub fn workspacePort(name: []const u8) u16 {
    var h: u32 = 2166136261;
    for (name) |c| h = (h ^ c) *% 16777619;
    return @intCast(40_000 + h % 10_000);
}

fn tomlString(text: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + key.len + 1 < text.len) : (i += 1) {
        if (!std.mem.eql(u8, text[i .. i + key.len], key)) continue;
        if (i > 0) {
            const prev = text[i - 1];
            if (std.ascii.isAlphanumeric(prev) or prev == '_' or prev == '.') continue;
        }
        var j = i + key.len;
        while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
        if (j >= text.len or text[j] != '=') continue;
        j += 1;
        while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
        if (j + 2 < text.len and std.mem.eql(u8, text[j .. j + 3], "\"\"\"")) {
            const start = j + 3;
            const end = std.mem.indexOfPos(u8, text, start, "\"\"\"") orelse return null;
            return std.mem.trim(u8, text[start..end], "\r\n");
        }
        if (j < text.len and text[j] == '"') {
            const start = j + 1;
            const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse return null;
            return text[start..end];
        }
    }
    return null;
}

fn readOptional(io: Io, arena: Allocator, root: []const u8, rel: []const u8) ?[]const u8 {
    const path = std.fs.path.join(arena, &.{ root, rel }) catch return null;
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch null;
}

fn skipName(name: []const u8) bool {
    const names = [_][]const u8{ ".git", "node_modules", "zig-out", "zig-cache", ".next", "dist", "target", ".graff", ".worktrees" };
    for (names) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

fn gitIgnored(gpa: Allocator, io: Io, root: []const u8, rel: []const u8) bool {
    const r = runCapped(gpa, io, &.{ "git", "-C", root, "check-ignore", "-q", "--", rel }, 256, 256, 15_000) catch return false;
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    return ranOk(r);
}

fn copyFile(io: Io, arena: Allocator, src: []const u8, dest: []const u8) bool {
    if ((Io.Dir.cwd().statFile(io, dest, .{}) catch null) != null) return false;
    const data = Io.Dir.cwd().readFileAlloc(io, src, arena, max_copy_bytes) catch return false;
    if (std.fs.path.dirname(dest)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch return false;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = data }) catch return false;
    return true;
}

fn copyIgnored(gpa: Allocator, io: Io, arena: Allocator, src_root: []const u8, dest_root: []const u8) usize {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_n = Io.Dir.cwd().realPathFile(io, src_root, &buf) catch 0;
    const src = if (abs_n > 0) arena.dupe(u8, buf[0..abs_n]) catch src_root else src_root;
    const include = includeText(arena, io, src);
    const rules = gitignore.parse(arena, include, src) catch return 0;
    var n: usize = 0;
    var walked: usize = 0;
    walkCopy(gpa, io, arena, src, dest_root, src, rules, &n, &walked) catch {};
    return n;
}

fn walkCopy(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    src_root: []const u8,
    dest_root: []const u8,
    dir_abs: []const u8,
    rules: []const gitignore.Rule,
    n: *usize,
    walked: *usize,
) !void {
    if (n.* >= max_copies or walked.* >= max_walk) return;
    var dir = Io.Dir.cwd().openDir(io, dir_abs, .{ .iterate = true, .follow_symlinks = false }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |ent| {
        if (ent.kind == .sym_link) continue;
        if (skipName(ent.name)) continue;
        walked.* += 1;
        if (walked.* > max_walk or n.* >= max_copies) return;
        const child = try std.fs.path.join(arena, &.{ dir_abs, ent.name });
        const rel = gitignore.relTo(child, src_root) orelse continue;
        if (std.mem.startsWith(u8, rel, ".graff/worktrees/") or std.mem.startsWith(u8, rel, ".worktrees/")) continue;
        if (ent.kind == .directory) {
            try walkCopy(gpa, io, arena, src_root, dest_root, child, rules, n, walked);
            continue;
        }
        if (ent.kind != .file) continue;
        switch (try gitignore.verdict(arena, rules, child, false)) {
            .ignore => {},
            else => continue,
        }
        if (!gitIgnored(gpa, io, src_root, rel)) continue;
        const dest = try std.fs.path.join(arena, &.{ dest_root, rel });
        if (copyFile(io, arena, child, dest)) n.* += 1;
    }
}

fn runScript(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    cmd: []const u8,
    dest: []const u8,
    root: []const u8,
    name: []const u8,
    deadline_ms: u64,
) bool {
    const port = workspacePort(name);
    const n1 = std.fmt.allocPrint(arena, "GRAFF_WORKSPACE_NAME={s}", .{name}) catch return false;
    const n2 = std.fmt.allocPrint(arena, "GRAFF_WORKSPACE_PATH={s}", .{dest}) catch return false;
    const n3 = std.fmt.allocPrint(arena, "GRAFF_ROOT_PATH={s}", .{root}) catch return false;
    const n4 = std.fmt.allocPrint(arena, "GRAFF_WORKSPACE_PORT={d}", .{port}) catch return false;
    const r = runCappedWithOptions(gpa, io, &.{
        "env", n1, n2, n3, n4, "/bin/sh", "-c", cmd,
    }, 64 * 1024, 16 * 1024, deadline_ms, .{ .cwd = .{ .path = dest } }) catch return false;
    defer {
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
    return ranOk(r);
}
