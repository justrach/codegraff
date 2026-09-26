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

pub const File = struct { path: []const u8, before: ?[]const u8, after: ?[]const u8, change: ?[]const u8 = null, after_omitted: bool = false };
pub const Input = struct {
    version: u8 = 3,
    base: []const u8,
    head: []const u8,
    body: []const u8,
    files: []const File,
    support_omitted: bool = false,
    support_limit: ?[]const u8 = null,
    // Changed files plus unchanged callers/configuration that establish
    // how those files are reached by the repository's test runners.
    scope: []const u8 = "changed committed files (full head or marked context diff) plus unchanged callers/configuration that establish test reachability",
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
    if (result.stdout_truncated) return error.ReviewTooLarge;
    if (!runner.ranOk(result) or result.stderr_truncated) return error.EvidenceUnavailable;
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
    seen: std.StringHashMap(void),
    limit: ?[]const u8 = null,

    fn add(self: *Support, path: []const u8) !?[]const u8 {
        for (self.files.items) |file| if (std.mem.eql(u8, file.path, path)) return file.after;
        if (self.files.items.len >= max_files) {
            self.omitted = true;
            if (self.limit == null) self.limit = "support file count exceeded 32";
            return null;
        }
        const after = blob(self.gpa, self.io, self.arena, self.cwd, self.head, path) catch |err| {
            if (err != error.ReviewTooLarge) return err;
            self.omitted = true;
            if (self.limit == null) self.limit = "a support file exceeded 128 KiB";
            return null;
        } orelse return null;
        if (self.size.* + after.len > max_bytes) {
            self.omitted = true;
            if (self.limit == null) self.limit = "support source exceeded the 128 KiB review budget";
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
        return self.walk(dir, text, 0);
    }

    fn walk(self: *Support, dir: []const u8, text: []const u8, depth: usize) !void {
        var words = std.mem.tokenizeAny(u8, text, " \t\r\n\"';&|(),{}[]");
        while (words.next()) |word| {
            if (std.fs.path.isAbsolute(word) or std.mem.indexOfAny(u8, word, "$`*?:") != null) continue;
            const ext = std.fs.path.extension(word);
            var source = false;
            for ([_][]const u8{ ".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx", ".py", ".sh" }) |allowed| if (std.mem.eql(u8, ext, allowed)) {
                source = true;
                break;
            };
            if (!source) continue;
            if (depth >= 5) {
                self.omitted = true;
                if (self.limit == null) self.limit = "test runner chain exceeded five levels";
                return;
            }
            const path = try repositoryPath(self.arena, dir, word);
            if (self.seen.contains(path)) continue;
            try self.seen.put(path, {});
            const contents = try self.add(path) orelse continue;
            try self.walk(std.fs.path.dirnamePosix(path) orelse "", contents, depth + 1);
        }
    }
};

pub fn gather(gpa: A, io: std.Io, arena: A, cwd: []const u8, base: []const u8, head: []const u8, body: []const u8) !Input {
    if (!evidence.validSha(base) or !evidence.validSha(head)) return error.InvalidCommit;
    if (body.len > max_bytes) return error.ReviewTooLarge;
    const names = try raw(gpa, io, arena, cwd, &.{ "git", "diff", "--no-ext-diff", "--no-renames", "--name-only", "-z", base, head, "--" });
    var has_source_change = false;
    var scan = std.mem.splitScalar(u8, names, 0);
    while (scan.next()) |path| {
        if (path.len > 0 and !std.mem.endsWith(u8, path, ".md")) {
            has_source_change = true;
            break;
        }
    }
    var paths = std.mem.splitScalar(u8, names, 0);
    var files: std.ArrayList(File) = .empty;
    var size = body.len;
    while (paths.next()) |path| {
        if (path.len == 0) continue;
        if (files.items.len >= max_files) return error.ReviewTooLarge;
        var after_omitted = false;
        const after = blob(gpa, io, arena, cwd, head, path) catch |err| blk: {
            if (err != error.ReviewTooLarge) return err;
            after_omitted = true;
            break :blk null;
        };
        // In mixed changes, reserve room for source and test reachability
        // instead of repeating complete documentation pages.
        if (after != null and has_source_change and std.mem.endsWith(u8, path, ".md")) after_omitted = true;
        // A context diff carries the old lines; repeating the complete base
        // blob would charge unchanged source twice and crowd out test evidence.
        var change = try raw(gpa, io, arena, cwd, &.{ "git", "diff", "--no-ext-diff", "--no-renames", "--unified=3", base, head, "--", path });
        if (size + change.len > max_bytes) return error.ReviewTooLarge;
        if (after) |text| {
            if (size + change.len + text.len > max_bytes) after_omitted = true;
        }
        if (after_omitted) {
            // Preserve more committed context when it fits. Never label this
            // excerpt as the complete proposed-head source.
            if (raw(gpa, io, arena, cwd, &.{ "git", "diff", "--no-ext-diff", "--no-renames", "--unified=20", base, head, "--", path })) |expanded| {
                if (size + expanded.len <= max_bytes) change = expanded;
            } else |err| {
                if (err != error.ReviewTooLarge) return err;
            }
        }
        size += change.len + if (after_omitted) @as(usize, 0) else if (after) |text| text.len else 0;
        try files.append(arena, .{ .path = path, .before = null, .after = if (after_omitted) null else after, .change = change, .after_omitted = after_omitted });
    }
    if (files.items.len == 0) return error.NoChangedFiles;
    var support: Support = .{ .gpa = gpa, .io = io, .arena = arena, .cwd = cwd, .head = head, .files = &files, .size = &size, .seen = std.StringHashMap(void).init(arena) };
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
    // Direct test roots matter more than broad workflow inventory when the
    // remaining support budget is tight.
    const coverage = [_][]const u8{ "build.zig", "src/main.zig", "package.json", "scripts/eval/tier1-manifest.json" };
    for (coverage) |path| _ = try support.add(path);
    const workflows = try raw(gpa, io, arena, cwd, &.{ "git", "ls-tree", "-r", "--name-only", "-z", head, "--", ".github/workflows" });
    var workflow_paths = std.mem.splitScalar(u8, workflows, 0);
    while (workflow_paths.next()) |path| {
        if (!std.mem.endsWith(u8, path, ".yml") and !std.mem.endsWith(u8, path, ".yaml")) continue;
        const text = try support.add(path) orelse continue;
        try support.runners("", text);
        for (support.packages.items) |dir| try support.runners(dir, text);
    }
    return .{ .base = base, .head = head, .body = body, .files = files.items, .support_omitted = support.omitted, .support_limit = support.limit };
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

test "claim review budgets changed hunks instead of the complete base blob" {
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
    const source = try a.alloc(u8, 75 * 1024);
    @memset(source, 'a');
    for (source, 0..) |*byte, i| if (i % 80 == 79) {
        byte.* = '\n';
    };
    source[0] = 'x';
    source[source.len - 1] = '\n';
    try temp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = source });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "add", "." });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "base" });
    const base = try capture(gpa, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    source[0] = 'y';
    try temp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = source });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "add", "." });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "head" });
    const head = try capture(gpa, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    const input = try gather(gpa, io, a, cwd, base, head, "claim");
    try std.testing.expectEqual(@as(usize, 1), input.files.len);
    try std.testing.expect(input.files[0].before == null);
    try std.testing.expect(input.files[0].change != null);
    try std.testing.expectEqual(@as(u8, 'y'), input.files[0].after.?[0]);
    const oversized = try a.alloc(u8, max_bytes + 1024);
    @memset(oversized, 'z');
    try temp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = oversized });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "add", "." });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "oversized" });
    const large_head = try capture(gpa, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    try std.testing.expectError(error.ReviewTooLarge, gather(gpa, io, a, cwd, head, large_head, "claim"));
}

test "claim review uses committed context when changed head source exceeds the budget" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const gpa = std.testing.allocator;
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = path[0..try temp.dir.realPath(io, &path)];
    _ = try capture(gpa, io, a, cwd, &.{ "git", "init", "-q" });
    const source = try a.alloc(u8, 75 * 1024);
    @memset(source, 'a');
    for (source, 0..) |*byte, i| if (i % 80 == 79) {
        byte.* = '\n';
    };
    source[0] = 'x';
    source[source.len - 1] = '\n';
    try temp.dir.writeFile(io, .{ .sub_path = "alpha.txt", .data = source });
    try temp.dir.writeFile(io, .{ .sub_path = "beta.txt", .data = source });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "add", "." });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "base" });
    const base = try capture(gpa, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    source[0] = 'y';
    try temp.dir.writeFile(io, .{ .sub_path = "alpha.txt", .data = source });
    try temp.dir.writeFile(io, .{ .sub_path = "beta.txt", .data = source });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "add", "." });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "head" });
    const head = try capture(gpa, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    source[0] = 'u';
    try temp.dir.writeFile(io, .{ .sub_path = "beta.txt", .data = source });
    const input = try gather(gpa, io, a, cwd, base, head, "claim");
    try std.testing.expectEqual(@as(usize, 2), input.files.len);
    try std.testing.expectEqual(@as(u8, 'y'), input.files[0].after.?[0]);
    try std.testing.expect(!input.files[0].after_omitted);
    try std.testing.expect(input.files[1].after == null);
    try std.testing.expect(input.files[1].after_omitted);
    try std.testing.expect(std.mem.indexOf(u8, input.files[1].change.?, "+yaaa") != null);
    try std.testing.expect(std.mem.indexOf(u8, input.files[1].change.?, "+uaaa") == null);

    const large = try a.alloc(u8, max_bytes + 1024);
    @memset(large, 'a');
    for (large, 0..) |*byte, i| if (i % 80 == 79) {
        byte.* = '\n';
    };
    large[0] = 'x';
    large[large.len - 1] = '\n';
    try temp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = large });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "add", "." });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "large-base" });
    const large_base = try capture(gpa, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    large[0] = 'y';
    try temp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = large });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "add", "." });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "large-head" });
    const large_head = try capture(gpa, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    const single = try gather(gpa, io, a, cwd, large_base, large_head, "claim");
    try std.testing.expectEqual(@as(usize, 1), single.files.len);
    try std.testing.expect(single.files[0].after == null and single.files[0].after_omitted);
    try std.testing.expect(std.mem.indexOf(u8, single.files[0].change.?, "+yaaa") != null);
}

test "mixed documentation changes leave room for committed test roots" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const gpa = std.testing.allocator;
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = path[0..try temp.dir.realPath(io, &path)];
    _ = try capture(gpa, io, a, cwd, &.{ "git", "init", "-q" });
    try temp.dir.createDirPath(io, "src");
    const docs = try a.alloc(u8, 60 * 1024);
    const source = try a.alloc(u8, 50 * 1024);
    @memset(docs, 'a');
    @memset(source, 'a');
    for (docs, 0..) |*byte, i| if (i % 80 == 79) {
        byte.* = '\n';
    };
    for (source, 0..) |*byte, i| if (i % 80 == 79) {
        byte.* = '\n';
    };
    docs[0] = 'x';
    source[0] = 'x';
    docs[docs.len - 1] = '\n';
    source[source.len - 1] = '\n';
    try temp.dir.writeFile(io, .{ .sub_path = "README.md", .data = docs });
    try temp.dir.writeFile(io, .{ .sub_path = "dispatch.zig", .data = source });
    try temp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = source });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "add", "." });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "base" });
    const base = try capture(gpa, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    docs[0] = 'y';
    source[0] = 'y';
    try temp.dir.writeFile(io, .{ .sub_path = "README.md", .data = docs });
    try temp.dir.writeFile(io, .{ .sub_path = "dispatch.zig", .data = source });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "add", "." });
    _ = try capture(gpa, io, a, cwd, &.{ "git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "head" });
    const head = try capture(gpa, io, a, cwd, &.{ "git", "rev-parse", "HEAD" });
    const input = try gather(gpa, io, a, cwd, base, head, "claim");
    try std.testing.expectEqual(@as(usize, 3), input.files.len);
    try std.testing.expectEqualStrings("README.md", input.files[0].path);
    try std.testing.expect(input.files[0].after == null and input.files[0].after_omitted);
    try std.testing.expect(std.mem.indexOf(u8, input.files[0].change.?, "+yaaa") != null);
    try std.testing.expectEqual(@as(u8, 'y'), input.files[1].after.?[0]);
    try std.testing.expect(!input.files[1].after_omitted);
    try std.testing.expectEqualStrings("src/main.zig", input.files[2].path);
    try std.testing.expectEqual(@as(u8, 'x'), input.files[2].after.?[0]);
    try std.testing.expect(!input.support_omitted);
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
    files[0].after = "source";
    files[0].after_omitted = true;
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
    try temp.dir.writeFile(io, .{ .sub_path = "apps/client/scripts/test-nested.mjs", .data = "import '../lib/suite.mjs';\n" });
    try temp.dir.writeFile(io, .{ .sub_path = "apps/client/lib/suite.mjs", .data = "import './view.test.mjs';\n" });
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
    try std.testing.expectEqual(@as(usize, 5), input.files.len);
    var bytes = input.body.len;
    var saw_suite = false;
    for (input.files) |file| {
        bytes += if (file.change) |text| text.len else 0;
        bytes += if (file.after) |text| text.len else 0;
        if (std.mem.eql(u8, file.path, "apps/client/scripts/test-nested.mjs"))
            try std.testing.expectEqualStrings("import '../lib/suite.mjs';\n", file.after.?);
        if (std.mem.eql(u8, file.path, "apps/client/lib/suite.mjs")) {
            saw_suite = true;
            try std.testing.expectEqualStrings("import './view.test.mjs';\n", file.after.?);
        }
    }
    try std.testing.expect(saw_suite);
    try std.testing.expect(bytes <= max_bytes and input.files.len <= max_files);
    try std.testing.expect(!input.support_omitted);
    var files: std.ArrayList(File) = .empty;
    var size: usize = max_bytes;
    var support: Support = .{ .gpa = gpa, .io = io, .arena = a, .cwd = cwd, .head = head, .files = &files, .size = &size, .seen = std.StringHashMap(void).init(a) };
    try std.testing.expect(try support.add("apps/client/package.json") == null);
    try std.testing.expect(support.omitted and files.items.len == 0 and size == max_bytes);
}
