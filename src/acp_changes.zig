//! Read-only workspace review over ACP. Uses the same Git working tree as tools.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const runner = @import("process_runner.zig");
const proto = @import("acp_protocol.zig");

fn git(a: Allocator, io: Io, argv: []const []const u8, allow_diff: bool) ![]const u8 {
    const literal = try a.alloc([]const u8, argv.len + 1);
    literal[0] = "git";
    literal[1] = "--literal-pathspecs";
    @memcpy(literal[2..], argv[1..]);
    const result = try runner.runCapped(a, io, literal, 2 * 1024 * 1024, 4096, 10000);
    if (!runner.ranOk(result) and !(allow_diff and result.term == .exited and result.term.exited == 1)) return error.GitReviewFailed;
    if (result.stdout_truncated) return error.GitReviewTooLarge;
    return result.stdout;
}
fn field(value: ?std.json.Value, name: []const u8) ?[]const u8 {
    const params = value orelse return null;
    if (params != .object) return null;
    const item = params.object.get(name) orelse return null;
    return if (item == .string) item.string else null;
}
fn safePath(file: []const u8) bool {
    if (file.len == 0 or std.fs.path.isAbsolute(file) or std.mem.indexOfScalar(u8, file, 0) != null) return false;
    var parts = std.mem.tokenizeAny(u8, file, "/\\");
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}
pub fn handle(a: Allocator, io: Io, out: *Io.Writer, req: proto.Request) !bool {
    if (!std.mem.eql(u8, req.method, "graff/changes")) return false;
    if (req.id == null) return true;
    const action = field(req.params, "action") orelse "status";
    if (std.mem.eql(u8, action, "diff")) {
        const file = field(req.params, "path") orelse "";
        if (!safePath(file)) {
            try proto.writeError(out, req.id, -32602, "Expected a relative workspace file path");
            return true;
        }
        const scope = field(req.params, "scope") orelse "all";
        const diff = if (std.mem.eql(u8, scope, "staged"))
            try git(a, io, &.{ "git", "diff", "--no-ext-diff", "--no-textconv", "--cached", "--", file }, false)
        else if (std.mem.eql(u8, scope, "unstaged"))
            try git(a, io, &.{ "git", "diff", "--no-ext-diff", "--no-textconv", "--", file }, false)
        else blk: {
            const tracked = try git(a, io, &.{ "git", "ls-files", "--", file }, false);
            const existed = git(a, io, &.{ "git", "cat-file", "-e", try std.fmt.allocPrint(a, "HEAD:{s}", .{file}) }, false) catch null;
            if (tracked.len == 0 and existed == null) break :blk try git(a, io, &.{ "git", "diff", "--no-ext-diff", "--no-textconv", "--no-index", "--", "/dev/null", file }, true);
            break :blk git(a, io, &.{ "git", "diff", "--no-ext-diff", "--no-textconv", "HEAD", "--", file }, false) catch try git(a, io, &.{ "git", "diff", "--no-ext-diff", "--no-textconv", "--cached", "--", file }, false);
        };
        try proto.writeResult(out, req.id, .{ .path = file, .diff = diff });
    } else if (std.mem.eql(u8, action, "status")) {
        const status = try git(a, io, &.{ "git", "status", "--porcelain=v1", "-z", "--untracked-files=all" }, false);
        const branch = git(a, io, &.{ "git", "branch", "--show-current" }, false) catch "";
        const worktrees = git(a, io, &.{ "git", "worktree", "list", "--porcelain" }, false) catch "";
        const commits = git(a, io, &.{ "git", "log", "-8", "--format=%h%x00%an%x00%s" }, false) catch "";
        try proto.writeResult(out, req.id, .{ .status = status, .branch = std.mem.trim(u8, branch, "\r\n"), .worktrees = worktrees, .commits = commits, .scope = "Shared working tree; includes every actor's local edits. Uncommitted authorship is not inferred." });
    } else try proto.writeError(out, req.id, -32602, "Unknown changes action");
    return true;
}
