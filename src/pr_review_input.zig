//! Immutable inputs for claim-versus-test review. PR prose is a claim, not
//! execution evidence. Read source blobs from the proposed commits, never
//! substitute an uncommitted working-tree repair for the published head.
const std = @import("std");
const evidence = @import("pr_evidence.zig");
const A = std.mem.Allocator;

fn repositoryPath(arena: A, dir: []const u8, name: []const u8) ![]const u8 {
    const path = try std.fs.path.resolvePosix(arena, &.{ "/", dir, name });
    return std.mem.trimStart(u8, path, "/");
}

pub const File = struct { path: []const u8, before: ?[]const u8, after: ?[]const u8 };
pub const Input = struct {
    version: u8 = 1,
    base: []const u8,
    head: []const u8,
    body: []const u8,
    files: []const File,
    support_omitted: bool = false,
    // Changed files plus unchanged callers/configuration that establish
    // how those files are reached by the repository's test runners.
    scope: []const u8 = "changed committed files plus unchanged callers/configuration that establish test reachability",
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

const Support = struct {
    gpa: A,
    io: std.Io,
    arena: A,
    cwd: []const u8,
    head: []const u8,
    files: *std.ArrayList(File),
    size: *usize,
    omitted: bool = false,
    packages: std.ArrayList([]const u8) = .empty,

    fn add(self: *Support, path: []const u8) !?[]const u8 {
        for (self.files.items) |file| if (std.mem.eql(u8, file.path, path)) return file.after;
        if (self.files.items.len >= max_files) {
            self.omitted = true;
            return null;
        }
        const after = try blob(self.gpa, self.io, self.arena, self.cwd, self.head, path) orelse return null;
        if (self.size.* + after.len > max_bytes) {
            self.omitted = true;
            return null;
        }
        self.size.* += after.len;
        // Supporting files are read only at the proposed head. Repeating their
        // unchanged base blobs consumes the budget without adding evidence.
        try self.files.append(self.arena, .{ .path = try self.arena.dupe(u8, path), .before = null, .after = after });
        return after;
    }

    fn package(self: *Support, dir: []const u8) !void {
        const manifest = try repositoryPath(self.arena, dir, "package.json");
        const text = try self.add(manifest) orelse return;
        try self.packages.append(self.arena, dir);
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, self.arena, text, .{}) catch return;
        if (parsed != .object) return;
        const scripts = parsed.object.get("scripts") orelse return;
        if (scripts != .object) return;
        var it = scripts.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) continue;
            try self.runners(dir, entry.value_ptr.string);
        }
    }

    fn runners(self: *Support, dir: []const u8, text: []const u8) !void {
        var words = std.mem.tokenizeAny(u8, text, " \t\r\n\"';&|");
        while (words.next()) |word| {
            if (std.fs.path.isAbsolute(word) or std.mem.indexOfAny(u8, word, "$`*?()") != null) continue;
            const ext = std.fs.path.extension(word);
            var source = false;
            for ([_][]const u8{ ".js", ".mjs", ".cjs", ".ts", ".py", ".sh" }) |allowed| if (std.mem.eql(u8, ext, allowed)) {
                source = true;
                break;
            };
            if (!source) continue;
            _ = try self.add(try repositoryPath(self.arena, dir, word));
        }
    }
};

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
    var support: Support = .{ .gpa = gpa, .io = io, .arena = arena, .cwd = cwd, .head = head, .files = &files, .size = &size };
    // Walk changed-file ancestors before generic root files: the closest
    // package defines the changed test's runner, often in a nested workspace.
    const changed = try arena.dupe(File, files.items);
    var visited = std.StringHashMap(void).init(arena);
    for (changed) |file| {
        var parent = std.fs.path.dirnamePosix(file.path);
        while (parent) |dir| {
            if (!visited.contains(dir)) {
                try visited.put(dir, {});
                try support.package(dir);
                for ([_][]const u8{ "bunfig.toml", "vitest.config.ts", "vitest.config.js", "jest.config.js", "jest.config.ts", "playwright.config.ts", "pyproject.toml" }) |config|
                    _ = try support.add(try repositoryPath(arena, dir, config));
            }
            parent = std.fs.path.dirnamePosix(dir);
        }
    }
    try support.package("");
    for ([_][]const u8{ "bunfig.toml", "vitest.config.ts", "vitest.config.js", "jest.config.js", "jest.config.ts", "playwright.config.ts", "pyproject.toml" }) |config|
        _ = try support.add(config);
    const workflows = try raw(gpa, io, arena, cwd, &.{ "git", "ls-tree", "-r", "--name-only", "-z", head, "--", ".github/workflows" });
    var workflow_paths = std.mem.splitScalar(u8, workflows, 0);
    while (workflow_paths.next()) |path| {
        if (!std.mem.endsWith(u8, path, ".yml") and !std.mem.endsWith(u8, path, ".yaml")) continue;
        const text = try support.add(path) orelse continue;
        try support.runners("", text);
        for (support.packages.items) |dir| try support.runners(dir, text);
    }
    const coverage = [_][]const u8{ "build.zig", "src/main.zig", "package.json", "scripts/eval/tier1-manifest.json" };
    for (coverage) |path| _ = try support.add(path);
    return .{ .base = base, .head = head, .body = body, .files = files.items, .support_omitted = support.omitted };
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

test "claim review includes unchanged callers that establish test reachability" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = path[0..try temp.dir.realPath(io, &path)];
    _ = try capture(std.testing.allocator, io, a, cwd, &.{ "git", "init", "-q" });
    try temp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "test { }\n" });
    _ = try capture(std.testing.allocator, io, a, cwd, &.{ "git", "add", "build.zig" });
    _ = try capture(std.testing.allocator, io, a, cwd, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "base" });
    const base = try capture(std.testing.allocator, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    try temp.dir.writeFile(io, .{ .sub_path = "dispatch.zig", .data = "pub fn run() void {}\n" });
    _ = try capture(std.testing.allocator, io, a, cwd, &.{ "git", "add", "dispatch.zig" });
    _ = try capture(std.testing.allocator, io, a, cwd, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "head" });
    const head = try capture(std.testing.allocator, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    const input = try gather(std.testing.allocator, io, a, cwd, base, head, "claim");
    var saw_caller = false;
    for (input.files) |file| {
        if (std.mem.eql(u8, file.path, "build.zig")) saw_caller = true;
    }
    try std.testing.expect(saw_caller);
    try std.testing.expect(std.mem.indexOf(u8, input.scope, "unchanged callers") != null);
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

test "claim review includes committed nested package runners and workflow reachability" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = path[0..try temp.dir.realPath(io, &path)];
    const gpa = std.testing.allocator;
    _ = try capture(gpa, io, a, cwd, &.{ "git", "init", "-q" });
    try temp.dir.createDirPath(io, "apps/client/scripts");
    try temp.dir.createDirPath(io, "apps/client/lib");
    try temp.dir.createDirPath(io, ".github/workflows");
    try temp.dir.writeFile(io, .{ .sub_path = "apps/client/package.json", .data = "{\"scripts\":{\"test\":\"node scripts/test-nested.mjs\"}}" });
    try temp.dir.writeFile(io, .{ .sub_path = "apps/client/scripts/test-nested.mjs", .data = "import '../lib/view.test.mjs';\n" });
    try temp.dir.writeFile(io, .{ .sub_path = "apps/client/lib/view.test.mjs", .data = "old test\n" });
    try temp.dir.writeFile(io, .{ .sub_path = ".github/workflows/check.yml", .data = "run: cd apps/client && npm test\n" });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "add", "." });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "base" });
    const base = try capture(gpa, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    try temp.dir.writeFile(io, .{ .sub_path = "apps/client/lib/view.test.mjs", .data = "new regression\n" });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "add", "." });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "head" });
    const head = try capture(gpa, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    try temp.dir.writeFile(io, .{ .sub_path = "apps/client/scripts/test-nested.mjs", .data = "uncommitted runner is not evidence" });
    const input = try gather(gpa, io, a, cwd, base, head, "Local: `npm test` passed.");
    try std.testing.expectEqual(@as(usize, 4), input.files.len);
    var bytes = input.body.len;
    for (input.files) |file| {
        bytes += if (file.before) |text| text.len else 0;
        bytes += if (file.after) |text| text.len else 0;
        if (std.mem.eql(u8, file.path, "apps/client/scripts/test-nested.mjs"))
            try std.testing.expectEqualStrings("import '../lib/view.test.mjs';\n", file.after.?);
    }
    try std.testing.expect(bytes <= max_bytes and input.files.len <= max_files);
    try std.testing.expect(!input.support_omitted);
    var files: std.ArrayList(File) = .empty;
    var size: usize = max_bytes;
    var support: Support = .{ .gpa = gpa, .io = io, .arena = a, .cwd = cwd, .head = head, .files = &files, .size = &size };
    try std.testing.expect(try support.add("apps/client/package.json") == null);
    try std.testing.expect(support.omitted and files.items.len == 0 and size == max_bytes);
}
