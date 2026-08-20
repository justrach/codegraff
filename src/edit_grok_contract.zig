//! Grok-build `search_replace` / OpenCode `edit` cases, run against graff
//! `edit_file`. Mapping and the deliberate deltas live in
//! docs/adr/0014-edit-file-is-search-replace.md — this file is the proof.
//!
//! Driven through `exec.execTool` so the catalog name is what is tested.
//! Cases are named after grok-build's `search_replace` tests
//! (`crates/codegen/xai-grok-tools/.../search_replace/mod.rs`).

const std = @import("std");
const builtin = @import("builtin");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const exec = @import("exec.zig");
const tools = @import("tools.zig");
const main_mod = @import("main.zig");
const no_local_tools = @import("no_local_tools.zig");

const Guard = struct {
    plan: bool,
    local: bool,
    fn arm() Guard {
        const g: Guard = .{ .plan = main_mod.plan_mode, .local = no_local_tools.enabled };
        main_mod.plan_mode = false;
        no_local_tools.enabled = false;
        return g;
    }
    fn disarm(self: Guard) void {
        main_mod.plan_mode = self.plan;
        no_local_tools.enabled = self.local;
    }
};

fn relPath(a: Allocator, tmp: anytype, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, name });
}

fn span(a: Allocator, path: []const u8, old: []const u8, new: []const u8, all: bool) !Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "path", .{ .string = path });
    try obj.put(a, "old_string", .{ .string = old });
    try obj.put(a, "new_string", .{ .string = new });
    if (all) try obj.put(a, "replace_all", .{ .bool = true });
    return .{ .object = obj };
}

fn toolCtx(a: Allocator, client: *std.http.Client) tools.ToolCtx {
    return .{
        .gpa = a,
        .io = std.testing.io,
        .client = client,
        .provider = undefined,
        .registry = null,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
    };
}

fn runEdit(a: Allocator, input: Value) tools.ToolOutput {
    var client: std.http.Client = undefined;
    return exec.execTool(toolCtx(a, &client), .{ .id = "t1", .name = "edit_file", .input = input });
}

fn runWrite(a: Allocator, path: []const u8, content: []const u8) !tools.ToolOutput {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "path", .{ .string = path });
    try obj.put(a, "content", .{ .string = content });
    var client: std.http.Client = undefined;
    return exec.execTool(toolCtx(a, &client), .{ .id = "t1", .name = "write_file", .input = .{ .object = obj } });
}

fn expectOk(out: tools.ToolOutput) !void {
    if (out.is_error) {
        std.debug.print("unexpected edit_file error: {s}\n", .{out.text});
        return error.TestUnexpectedResult;
    }
}

test "grok search_replace: basic unique replacement" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const g = Guard.arm();
    defer g.disarm();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "test.txt", .data = "hello world\n" });
    const path = try relPath(a, tmp, "test.txt");
    const out = runEdit(a, try span(a, path, "hello", "goodbye", false));
    try expectOk(out);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "replaced 1") != null);
    const on_disk = try tmp.dir.readFileAlloc(io, "test.txt", a, .limited(4096));
    try std.testing.expectEqualStrings("goodbye world\n", on_disk);
}

test "grok search_replace: empty old_string is refused (write_file creates)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const g = Guard.arm();
    defer g.disarm();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try relPath(a, tmp, "new_file.txt");
    const out = runEdit(a, try span(a, path, "", "new content\n", false));
    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "must not be empty") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "new_file.txt", .{}));
}

test "grok search_replace: write_file is the create path" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const g = Guard.arm();
    defer g.disarm();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try relPath(a, tmp, "new_file.txt");
    const created = try runWrite(a, path, "new content\n");
    try expectOk(created);
    const on_disk = try tmp.dir.readFileAlloc(io, "new_file.txt", a, .limited(4096));
    try std.testing.expectEqualStrings("new content\n", on_disk);
}

test "grok search_replace: consecutive edits without prior read" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const g = Guard.arm();
    defer g.disarm();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "test.txt", .data = "hello world\n" });
    const path = try relPath(a, tmp, "test.txt");
    try expectOk(runEdit(a, try span(a, path, "hello", "hi", false)));
    try expectOk(runEdit(a, try span(a, path, "world", "earth", false)));
    const on_disk = try tmp.dir.readFileAlloc(io, "test.txt", a, .limited(4096));
    try std.testing.expectEqualStrings("hi earth\n", on_disk);
}

test "grok search_replace: file not found" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const g = Guard.arm();
    defer g.disarm();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try relPath(a, tmp, "nonexistent.txt");
    const out = runEdit(a, try span(a, path, "hello", "goodbye", false));
    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "does not exist") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "write_file") != null);
}

test "grok search_replace: rejects a directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const g = Guard.arm();
    defer g.disarm();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "subdir", .default_dir);
    const path = try relPath(a, tmp, "subdir");
    const out = runEdit(a, try span(a, path, "old", "new", false));
    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "directory") != null);
}

test "grok search_replace: rejects same old_string and new_string" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const g = Guard.arm();
    defer g.disarm();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try relPath(a, tmp, "test.txt");
    const out = runEdit(a, try span(a, path, "same", "same", false));
    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "must differ") != null);
}

test "grok search_replace: replace_all" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const g = Guard.arm();
    defer g.disarm();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "test.txt", .data = "aaa bbb aaa bbb aaa\n" });
    const path = try relPath(a, tmp, "test.txt");
    const out = runEdit(a, try span(a, path, "aaa", "ccc", true));
    try expectOk(out);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "replaced 3") != null);
    const on_disk = try tmp.dir.readFileAlloc(io, "test.txt", a, .limited(4096));
    try std.testing.expectEqualStrings("ccc bbb ccc bbb ccc\n", on_disk);
}

test "grok search_replace: multiple matches without replace_all" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const g = Guard.arm();
    defer g.disarm();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "test.txt", .data = "aaa bbb aaa\n" });
    const path = try relPath(a, tmp, "test.txt");
    const out = runEdit(a, try span(a, path, "aaa", "ccc", false));
    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "replace_all") != null);
    const on_disk = try tmp.dir.readFileAlloc(io, "test.txt", a, .limited(4096));
    try std.testing.expectEqualStrings("aaa bbb aaa\n", on_disk);
}

test "grok search_replace: no match mentions read_file" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const g = Guard.arm();
    defer g.disarm();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "test.txt", .data = "hello world\n" });
    const path = try relPath(a, tmp, "test.txt");
    const out = runEdit(a, try span(a, path, "xyz", "abc", false));
    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "read_file") != null);
}

test "grok search_replace: CRLF single-line match preserves endings" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const g = Guard.arm();
    defer g.disarm();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "test.txt", .data = "aaa\r\nbbb\r\nccc\r\n" });
    const path = try relPath(a, tmp, "test.txt");
    try expectOk(runEdit(a, try span(a, path, "bbb", "BBB", false)));
    const on_disk = try tmp.dir.readFileAlloc(io, "test.txt", a, .limited(4096));
    try std.testing.expectEqualStrings("aaa\r\nBBB\r\nccc\r\n", on_disk);
}

test "grok search_replace: LF old_string does not fuzzy-match CRLF" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const g = Guard.arm();
    defer g.disarm();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "test.txt", .data = "hello\r\nworld\r\n" });
    const path = try relPath(a, tmp, "test.txt");
    const out = runEdit(a, try span(a, path, "hello\nworld\n", "goodbye\nearth\n", false));
    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "not found") != null);
    const on_disk = try tmp.dir.readFileAlloc(io, "test.txt", a, .limited(4096));
    try std.testing.expectEqualStrings("hello\r\nworld\r\n", on_disk);
}

test "grok search_replace: batched edits apply in one call" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const g = Guard.arm();
    defer g.disarm();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "test.txt", .data = "hello world\n" });
    const path = try relPath(a, tmp, "test.txt");
    var parsed = try std.json.parseFromSliceLeaky(Value, a,
        \\{"path":"P","edits":[{"old_string":"hello","new_string":"hi"},{"old_string":"world","new_string":"earth"}]}
    , .{ .allocate = .alloc_always });
    parsed.object.put(a, "path", .{ .string = path }) catch unreachable;
    const out = runEdit(a, parsed);
    try expectOk(out);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "2 edit span(s)") != null);
    const on_disk = try tmp.dir.readFileAlloc(io, "test.txt", a, .limited(4096));
    try std.testing.expectEqualStrings("hi earth\n", on_disk);
}
