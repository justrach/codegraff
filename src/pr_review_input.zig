//! Immutable inputs for claim-versus-test review. PR prose is a claim, not
//! execution evidence. Read source blobs from the proposed commits, never
//! substitute an uncommitted working-tree repair for the published head.
const std = @import("std");
const evidence = @import("pr_evidence.zig");
const A = std.mem.Allocator;

pub const File = struct { path: []const u8, before: ?[]const u8, after: ?[]const u8 };
pub const Input = struct {
    version: u8 = 1,
    base: []const u8,
    head: []const u8,
    body: []const u8,
    files: []const File,
    // Changed files alone may omit a dispatch caller or an existing test.
    // A reviewer must report unresolved when these inputs do not establish it.
    scope: []const u8 = "changed committed files; transitive coverage is not established",
};
pub fn digest(arena: A, input: Input) ![64]u8 {
    const bytes = try std.json.Stringify.valueAlloc(arena, input, .{});
    defer arena.free(bytes);
    var value: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &value, .{});
    return std.fmt.bytesToHex(value, .lower);
}

pub const max_files = 32;
pub const max_bytes = 128 * 1024;

fn capture(gpa: A, io: std.Io, arena: A, cwd: []const u8, args: []const []const u8) ![]const u8 {
    return evidence.capture(gpa, io, arena, .{ .cwd = cwd, .selector = "" }, args);
}

fn raw(gpa: A, io: std.Io, arena: A, cwd: []const u8, args: []const []const u8) ![]const u8 {
    const runner = @import("process_runner.zig");
    const result = try runner.runCappedWithOptions(gpa, io, args, max_bytes + 1, 2048, 15_000, .{ .cwd = .{ .path = cwd } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (!runner.ranOk(result) or result.stdout_truncated or result.stderr_truncated) return error.EvidenceUnavailable;
    return arena.dupe(u8, result.stdout);
}

fn blob(gpa: A, io: std.Io, arena: A, cwd: []const u8, commit: []const u8, path: []const u8) !?[]const u8 {
    const metadata = try raw(gpa, io, arena, cwd, &.{ "git", "--literal-pathspecs", "ls-tree", "-z", commit, "--", path });
    if (metadata.len == 0) return null;
    const space = std.mem.indexOfScalar(u8, metadata, ' ') orelse return error.InvalidTree;
    const mode = metadata[0..space];
    if (!std.mem.eql(u8, mode, "100644") and !std.mem.eql(u8, mode, "100755")) return error.UnsupportedTreeEntry;
    const spec = try std.fmt.allocPrint(arena, "{s}:{s}", .{ commit, path });
    const content = try raw(gpa, io, arena, cwd, &.{ "git", "show", "--no-ext-diff", spec });
    if (content.len > max_bytes or std.mem.indexOfScalar(u8, content, 0) != null or !std.unicode.utf8ValidateSlice(content)) return error.UnsupportedSource;
    return content;
}

pub fn gather(gpa: A, io: std.Io, arena: A, cwd: []const u8, base: []const u8, head: []const u8, body: []const u8) !Input {
    if (!evidence.validSha(base) or !evidence.validSha(head)) return error.InvalidCommit;
    if (body.len > max_bytes) return error.ReviewTooLarge;
    const names = try raw(gpa, io, arena, cwd, &.{ "git", "diff", "--no-ext-diff", "--no-renames", "--name-only", "-z", base, head, "--" });
    var paths = std.mem.splitScalar(u8, names, 0);
    var files: std.ArrayList(File) = .empty;
    var size = body.len;
    while (paths.next()) |path| {
        if (path.len == 0) continue;
        if (files.items.len >= max_files) return error.ReviewTooLarge;
        const before = try blob(gpa, io, arena, cwd, base, path);
        const after = try blob(gpa, io, arena, cwd, head, path);
        size += (if (before) |text| text.len else 0) + (if (after) |text| text.len else 0);
        if (size > max_bytes) return error.ReviewTooLarge;
        try files.append(arena, .{ .path = path, .before = before, .after = after });
    }
    if (files.items.len == 0) return error.NoChangedFiles;
    return .{ .base = base, .head = head, .body = body, .files = files.items };
}

test "claim review rejects branch names as immutable identities" {
    try std.testing.expectError(error.InvalidCommit, gather(std.testing.allocator, std.testing.io, std.testing.allocator, ".", "main", "HEAD", "claim"));
}

test "claim review reads committed blobs despite a repaired working tree" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = path[0..try temp.dir.realPath(io, &path)];
    _ = try capture(std.testing.allocator, io, a, cwd, &.{ "git", "init", "-q" });
    _ = try capture(std.testing.allocator, io, a, cwd, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "base" });
    const base = try capture(std.testing.allocator, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    try temp.dir.writeFile(io, .{ .sub_path = "dispatch.py", .data = "  broken dispatch\n\n" });
    _ = try capture(std.testing.allocator, io, a, cwd, &.{ "git", "add", "dispatch.py" });
    _ = try capture(std.testing.allocator, io, a, cwd, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "head" });
    const head = try capture(std.testing.allocator, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    try temp.dir.writeFile(io, .{ .sub_path = "dispatch.py", .data = "repaired but uncommitted\n" });
    const input = try gather(std.testing.allocator, io, a, cwd, base, head, "claim");
    try std.testing.expectEqual(@as(usize, 1), input.files.len);
    try std.testing.expect(input.files[0].before == null);
    try std.testing.expectEqualStrings("  broken dispatch\n\n", input.files[0].after.?);
}

test "claim review digest invalidates changed body head and committed source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files = [_]File{.{ .path = "dispatch.py", .before = null, .after = "source" }};
    var input: Input = .{ .base = "base", .head = "head", .body = "claim", .files = &files };
    const original = try digest(a, input);
    input.body = "different claim";
    try std.testing.expect(!std.mem.eql(u8, &original, &try digest(a, input)));
    input.body = "claim";
    input.head = "different head";
    try std.testing.expect(!std.mem.eql(u8, &original, &try digest(a, input)));
    input.head = "head";
    files[0].after = "different committed source";
    try std.testing.expect(!std.mem.eql(u8, &original, &try digest(a, input)));
}
