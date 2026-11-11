//! write_file (ADR 0231). Creates a file, or replaces one this session has
//! already read, edited or written; replacing any other existing file takes
//! `replace: true`. The guard is what lets a model write a new file straight
//! away: without it a careful model spent a whole round trip checking that the
//! path was free. The result says what happened (created or replaced, and for
//! a .json path whether the content parses), so a successful write needs no
//! read-back either.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const tools = @import("tools.zig");
const approvals = @import("approvals.zig");
const codedbpro_paths = @import("codedbpro_paths.zig");
const edit_verify = @import("edit_verify.zig");
const syntax_note = @import("syntax_note.zig");

const page = std.heap.page_allocator;

/// Canonical paths whose content this process has seen. Process-wide, so a
/// subagent's read counts for its parent and the other way round.
var known: std.StringHashMapUnmanaged(void) = .empty;
var known_lock: std.atomic.Value(bool) = .init(false);

fn lock() void {
    while (known_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlock() void {
    known_lock.store(false, .release);
}

/// #1487: one key per file. A symlinked directory, a `..` segment, or an
/// absolute spelling of a relative path all name the same file; keying on the
/// spelling let a read under one form leave a write under another refused as
/// "not read". A path that does not resolve keeps its own spelling.
fn keyFor(io: Io, abs_path: []const u8, buf: *[std.fs.max_path_bytes]u8) []const u8 {
    const n = Io.Dir.cwd().realPathFile(io, abs_path, buf) catch return abs_path;
    return buf[0..n];
}

pub fn noteKnown(io: Io, abs_path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const k = keyFor(io, abs_path, &buf);
    lock();
    defer unlock();
    if (known.contains(k)) return;
    const key = page.dupe(u8, k) catch return;
    known.put(page, key, {}) catch page.free(key);
}

fn isKnown(io: Io, abs_path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const k = keyFor(io, abs_path, &buf);
    lock();
    defer unlock();
    return known.contains(k);
}

/// After a successful read_file or edit_file: the model has seen this path.
pub fn noteInput(ctx: tools.ToolCtx, input: std.json.Value) void {
    const raw_path = tools.strField(input, "path") orelse return;
    const path = codedbpro_paths.normalizeInCwd(ctx.io, ctx.agent_cwd, raw_path, false);
    const resolved = codedbpro_paths.sessionAbs(ctx.gpa, ctx.io, ctx.agent_cwd, path) catch return;
    defer ctx.gpa.free(resolved);
    noteKnown(ctx.io, resolved);
}

pub fn exec(ctx: tools.ToolCtx, input: std.json.Value) !tools.ToolOutput {
    const gpa = ctx.gpa;
    const io = ctx.io;
    const raw_path = tools.strField(input, "path") orelse return tools.missingArg(gpa, "path");
    const path = codedbpro_paths.normalizeInCwd(io, ctx.agent_cwd, raw_path, false);
    const content = tools.strField(input, "content") orelse return tools.missingArg(gpa, "content");
    if (!approvals.confinedPath(path) or !approvals.noSymlinkEscape(io, path, ctx.agent_cwd)) return tools.outsideCwd(gpa, raw_path);
    if (approvals.protectsGitMetadata(path) or approvals.symlinkEntersGitMetadata(io, path, ctx.agent_cwd))
        return .{ .text = try gpa.dupe(u8, approvals.git_metadata_refusal), .is_error = true };
    // #747: share sessionAbs with edit_file so a write cannot land in
    // posix cwd while the next edit looks at a stale display cwd.
    const resolved = try codedbpro_paths.sessionAbs(gpa, io, ctx.agent_cwd, path);
    defer gpa.free(resolved);
    // #337: a write_file racing an edit_file on the same path in the same
    // assistant turn (agent_tools.zig runs them concurrently) would drop
    // one of the two. Same stripe as edit_file, so they take turns.
    const path_lock = edit_verify.lockPath(io, resolved);
    defer path_lock.unlock(io);
    // #179: an existing file keeps its mode (e.g. 0755) across the overwrite;
    // a brand-new file (prev_stat == null) keeps the default.
    const prev_stat = Io.Dir.cwd().statFile(io, resolved, .{}) catch null;
    if (prev_stat) |st| if (st.kind == .file and st.size > 0 and !isKnown(io, resolved) and !tools.json_args.flag(input, "replace")) return .{
        .text = try std.fmt.allocPrint(gpa, "{s} already exists ({d} bytes) and has not been read in this session; nothing was written. Read it first, or pass replace: true to overwrite it.", .{ path, st.size }),
        .is_error = true,
    };
    if (ctx.snapshots) |snaps| if (!ctx.from_sub) {
        // capture the prior content (or absence) before overwriting, for /rewind.
        // beforeFromRead keeps a merely UNREADABLE file (over the cap, permissions)
        // distinct from a missing one — only the latter is a rewind-deletes-it.
        const before = tools.beforeFromRead(Io.Dir.cwd().readFileAlloc(io, resolved, gpa, .limited(4 * 1024 * 1024)));
        defer if (before == .content) gpa.free(before.content);
        snaps.record(path, before);
    };
    const made_dir = writeCreating(io, resolved, content, prev_stat == null) catch |err| {
        if (edit_verify.fsErrorText(gpa, .write, path, err)) |t| return .{ .text = t, .is_error = true };
        return err;
    };
    edit_verify.preserveMode(io, resolved, prev_stat);
    noteKnown(io, resolved);
    const dir = if (made_dir) std.fs.path.dirname(path) else null;
    return .{ .text = try resultText(gpa, io, path, resolved, content, if (prev_stat) |st| st.size else null, dir) };
}

/// A new file whose directory is missing gets the directory first, as
/// `mkdir -p` would. Refusing it cost the model a second generation of the
/// whole content, which is most of what a large write costs. True when the
/// directory was made.
fn writeCreating(io: Io, resolved: []const u8, data: []const u8, new_file: bool) !bool {
    Io.Dir.cwd().writeFile(io, .{ .sub_path = resolved, .data = data }) catch |err| {
        if (err != error.FileNotFound or !new_file) return err;
        const parent = std.fs.path.dirname(resolved) orelse return err;
        try Io.Dir.cwd().createDirPath(io, parent);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = resolved, .data = data });
        return true;
    };
    return false;
}

fn resultText(gpa: Allocator, io: Io, path: []const u8, resolved: []const u8, content: []const u8, prev_size: ?u64, made_dir: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    if (prev_size) |was| {
        try w.print("replaced {s} ({d} bytes; was {d})", .{ path, content.len, was });
    } else try w.print("created {s} ({d} bytes)", .{ path, content.len });
    if (made_dir) |d| try w.print(" in new directory {s}", .{d});
    try syntax_note.append(gpa, io, w, path, resolved, content);
    return out.toOwnedSlice();
}

test "write_file creates, refuses to clobber an unread file, and replaces a known one (ADR 0231)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // same write path as the /rewind tests, which skip there too
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const out_json = try std.fmt.allocPrint(a, "{s}/out.json", .{dir});
    const theirs = try std.fmt.allocPrint(a, "{s}/theirs.txt", .{dir});
    var client: std.http.Client = undefined;
    const ctx: tools.ToolCtx = .{ .gpa = gpa, .io = io, .client = &client, .provider = undefined, .registry = null, .from_sub = false, .approvals = null, .tracer = null };

    var args: std.json.ObjectMap = .empty;
    try args.put(a, "path", .{ .string = out_json });
    try args.put(a, "content", .{ .string = "{\"n\": 1}" });
    const created = try exec(ctx, .{ .object = args });
    defer gpa.free(created.text);
    try std.testing.expect(!created.is_error);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "created {s} (8 bytes); parses as JSON", .{out_json}), created.text);

    // A file this session never saw is refused and left untouched.
    try tmp.dir.writeFile(io, .{ .sub_path = "theirs.txt", .data = "keep me" });
    args.getPtr("path").?.* = .{ .string = theirs };
    args.getPtr("content").?.* = .{ .string = "{\"n\": " };
    const refused = try exec(ctx, .{ .object = args });
    defer gpa.free(refused.text);
    try std.testing.expect(refused.is_error);
    const kept = try tmp.dir.readFileAlloc(io, "theirs.txt", gpa, .limited(64));
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("keep me", kept);

    // replace: true overwrites it; a file this session wrote needs no flag.
    try args.put(a, "replace", .{ .bool = true });
    const replaced = try exec(ctx, .{ .object = args });
    defer gpa.free(replaced.text);
    try std.testing.expect(!replaced.is_error);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "replaced {s} (6 bytes; was 7)", .{theirs}), replaced.text);
    _ = args.swapRemove("replace");
    args.getPtr("path").?.* = .{ .string = out_json };
    const again = try exec(ctx, .{ .object = args });
    defer gpa.free(again.text);
    try std.testing.expect(!again.is_error);
    try std.testing.expect(std.mem.startsWith(u8, again.text, try std.fmt.allocPrint(a, "replaced {s} (6 bytes; was 8); NOT valid JSON (", .{out_json})));

    // A new file in a missing directory gets the directory, not a refusal
    // the model answers by generating the whole content again.
    const nested = try std.fmt.allocPrint(a, "{s}/docs/deep/FORMAT.md", .{dir});
    args.getPtr("path").?.* = .{ .string = nested };
    args.getPtr("content").?.* = .{ .string = "# x\n" };
    const made = try exec(ctx, .{ .object = args });
    defer gpa.free(made.text);
    try std.testing.expect(!made.is_error);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "created {s} (4 bytes) in new directory {s}/docs/deep", .{ nested, dir }), made.text);
    const landed = try tmp.dir.readFileAlloc(io, "docs/deep/FORMAT.md", gpa, .limited(64));
    defer gpa.free(landed);
    try std.testing.expectEqualStrings("# x\n", landed);
}

test "#1487: a read under one spelling of a path lets write_file replace it under another" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // symlinks need privileges there
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "real");
    try tmp.dir.writeFile(io, .{ .sub_path = "real/f.txt", .data = "old" });
    try tmp.dir.writeFile(io, .{ .sub_path = "real/g.txt", .data = "old" });
    try tmp.dir.symLink(io, "real", "link", .{});
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    var client: std.http.Client = undefined;
    const ctx: tools.ToolCtx = .{ .gpa = gpa, .io = io, .client = &client, .provider = undefined, .registry = null, .from_sub = false, .approvals = null, .tracer = null };

    // Read through the symlinked directory, then write the real path.
    var read_args: std.json.ObjectMap = .empty;
    try read_args.put(a, "path", .{ .string = try std.fmt.allocPrint(a, "{s}/link/f.txt", .{dir}) });
    noteInput(ctx, .{ .object = read_args });
    var args: std.json.ObjectMap = .empty;
    try args.put(a, "path", .{ .string = try std.fmt.allocPrint(a, "{s}/real/f.txt", .{dir}) });
    try args.put(a, "content", .{ .string = "new" });
    const out = try exec(ctx, .{ .object = args });
    defer gpa.free(out.text);
    try std.testing.expect(!out.is_error);

    // An absolute spelling with a `..` segment names the same file as the
    // relative path the write uses.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    read_args.getPtr("path").?.* = .{ .string = try std.fmt.allocPrint(a, "{s}/{s}/real/../real/g.txt", .{ cwd_buf[0..cwd_len], dir }) };
    noteInput(ctx, .{ .object = read_args });
    args.getPtr("path").?.* = .{ .string = try std.fmt.allocPrint(a, "{s}/real/g.txt", .{dir}) };
    const out2 = try exec(ctx, .{ .object = args });
    defer gpa.free(out2.text);
    try std.testing.expect(!out2.is_error);
    const landed = try tmp.dir.readFileAlloc(io, "real/g.txt", gpa, .limited(64));
    defer gpa.free(landed);
    try std.testing.expectEqualStrings("new", landed);
}

test "write_file and edit_file refuse .git metadata and symlinks into .git while allowing .github/.githooks" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".git/hooks");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/config", .data = "[core]\n" });
    try tmp.dir.symLink(io, ".git", "gitlink", .{ .is_directory = true });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);

    var client: std.http.Client = undefined;
    const ctx: tools.ToolCtx = .{ .gpa = gpa, .io = io, .client = &client, .provider = undefined, .registry = null, .from_sub = true, .approvals = null, .tracer = null, .agent_cwd = dir };

    for ([_][]const u8{ ".git/hooks/post-checkout", "sub/.git/config", "gitlink/hooks/pre-commit" }) |blocked| {
        var args: std.json.ObjectMap = .empty;
        try args.put(a, "path", .{ .string = blocked });
        try args.put(a, "content", .{ .string = "#!/bin/sh\n" });
        const res = try exec(ctx, .{ .object = args });
        defer gpa.free(res.text);
        try std.testing.expect(res.is_error);
        try std.testing.expect(std.mem.indexOf(u8, res.text, ".git metadata") != null);
    }

    var edit_args: std.json.ObjectMap = .empty;
    try edit_args.put(a, "path", .{ .string = ".git/config" });
    try edit_args.put(a, "old_string", .{ .string = "[core]" });
    try edit_args.put(a, "new_string", .{ .string = "[core]\nfsmonitor = evil" });
    const ed = try edit_verify.execEdit(ctx, .{ .object = edit_args });
    defer gpa.free(ed.text);
    try std.testing.expect(ed.is_error);
    try std.testing.expect(std.mem.indexOf(u8, ed.text, ".git metadata") != null);

    const batch_in = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"path":".git/config","edits":[{"old_string":"[core]","new_string":"[user]"}]}
    , .{});
    const batch_ed = try @import("edit_batch.zig").execBatch(ctx, batch_in);
    defer gpa.free(batch_ed.text);
    try std.testing.expect(batch_ed.is_error);

    for ([_][]const u8{ ".github/workflows/ci.yml", ".gitignore", ".githooks/pre-push" }) |ok_path| {
        var args: std.json.ObjectMap = .empty;
        try args.put(a, "path", .{ .string = ok_path });
        try args.put(a, "content", .{ .string = "ok\n" });
        const ok = try exec(ctx, .{ .object = args });
        defer gpa.free(ok.text);
        try std.testing.expect(!ok.is_error);
    }
}
