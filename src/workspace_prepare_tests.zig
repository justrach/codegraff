//! Isolation tests for `workspace_prepare.zig`.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const prep = @import("workspace_prepare.zig");
const ws = @import("task_workspace.zig");
const process_runner = @import("process_runner.zig");
const runCapped = process_runner.runCapped;
const ranOk = process_runner.ranOk;

test "parseScripts reads graff workspace toml" {
    const s = prep.parseScripts(
        \\[scripts]
        \\setup = "pnpm install"
        \\run = "pnpm dev --port $GRAFF_WORKSPACE_PORT"
        \\archive = "./script/workspace-archive.sh"
        \\
    );
    try std.testing.expectEqualStrings("pnpm install", s.setup);
    try std.testing.expectEqualStrings("pnpm dev --port $GRAFF_WORKSPACE_PORT", s.run);
    try std.testing.expectEqualStrings("./script/workspace-archive.sh", s.archive);
    const globs = prep.parseIncludeGlobs(
        \\include = """
        \\.env.local
        \\certs/local/**
        \\"""
        \\
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, globs, ".env.local") != null);
    try std.testing.expect(std.mem.indexOf(u8, globs, "certs/local/**") != null);
}

test "workspacePort is stable per name and stays in 40000-49999" {
    const a = prep.workspacePort("task-a");
    const b = prep.workspacePort("task-a");
    const c = prep.workspacePort("task-b");
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);
    try std.testing.expect(a >= 40_000 and a < 50_000);
    try std.testing.expect(c >= 40_000 and c < 50_000);
}

test "create copies gitignored include files and runs setup" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(tmp_root);
    const root = try std.fmt.allocPrint(a, "{s}/repo", .{tmp_root});
    defer a.free(root);
    try Io.Dir.cwd().createDirPath(io, root);
    try git(io, a, &.{ "init", "-q", "-b", "main", root });
    try git(io, a, &.{ "-C", root, "config", "user.email", "t@t" });
    try git(io, a, &.{ "-C", root, "config", "user.name", "t" });
    try write(io, root, "f", "x\n");
    try write(io, root, ".gitignore", ".env.local\ntracked-secret\nscratch.txt\n");
    try write(io, root, ".worktreeinclude", ".env.local\n");
    try write(io, root, ".env.local", "SECRET=1\n");
    try write(io, root, "scratch.txt", "nope\n");
    try write(io, root, ".graff/workspace.toml",
        \\[scripts]
        \\setup = "printf ready > .graff-setup"
        \\archive = "printf gone > ../archive-ran"
        \\
    );
    try git(io, a, &.{ "-C", root, "add", "f", ".gitignore", ".worktreeinclude", ".graff/workspace.toml" });
    try git(io, a, &.{ "-C", root, "commit", "-m", "i" });

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const one = try ws.create(a, io, ar, .{ .slug = "task-a", .cwd = root });
    try std.testing.expect(one.copied >= 1);
    try std.testing.expect(one.setup_ran);
    try std.testing.expect(one.setup_ok);
    const copied = try std.fs.path.join(a, &.{ one.path, ".env.local" });
    defer a.free(copied);
    const body = try Io.Dir.cwd().readFileAlloc(io, copied, a, .limited(64));
    defer a.free(body);
    try std.testing.expectEqualStrings("SECRET=1\n", body);
    const skipped = try std.fs.path.join(a, &.{ one.path, "scratch.txt" });
    defer a.free(skipped);
    try std.testing.expect((Io.Dir.cwd().statFile(io, skipped, .{}) catch null) == null);
    const setup_mark = try std.fs.path.join(a, &.{ one.path, ".graff-setup" });
    defer a.free(setup_mark);
    const mark = try Io.Dir.cwd().readFileAlloc(io, setup_mark, a, .limited(64));
    defer a.free(mark);
    try std.testing.expectEqualStrings("ready", mark);
}

fn write(io: Io, root: []const u8, rel: []const u8, data: []const u8) !void {
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, rel });
    defer std.testing.allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn git(io: Io, a: std.mem.Allocator, argv: []const []const u8) !void {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(a);
    try args.append(a, "git");
    try args.appendSlice(a, argv);
    const r = try runCapped(a, io, args.items, 4096, 4096, 15_000);
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    try std.testing.expect(ranOk(r));
}
