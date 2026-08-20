//! Grok-build `read_file` / OpenCode `write` cases, run against graff
//! `read_file` and `write_file`. Mapping and the deliberate deltas live in
//! docs/adr/0015-basic-tools-stay-graff-shaped.md — this file is the proof
//! that those loops do not change.
//!
//! Driven through `exec.execTool` so the catalog names are what is tested.

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

fn runNamed(a: Allocator, name: []const u8, input: Value) tools.ToolOutput {
    var client: std.http.Client = undefined;
    return exec.execTool(toolCtx(a, &client), .{ .id = "t1", .name = name, .input = input });
}

fn readArgs(a: Allocator, path: []const u8, start: ?i64, end: ?i64, contains: ?[]const u8) !Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "path", .{ .string = path });
    if (start) |n| try obj.put(a, "start_line", .{ .integer = n });
    if (end) |n| try obj.put(a, "end_line", .{ .integer = n });
    if (contains) |s| try obj.put(a, "contains", .{ .string = s });
    return .{ .object = obj };
}

fn runRead(a: Allocator, path: []const u8, start: ?i64, end: ?i64, contains: ?[]const u8) !tools.ToolOutput {
    return runNamed(a, "read_file", try readArgs(a, path, start, end, contains));
}

fn runWrite(a: Allocator, path: []const u8, content: []const u8) !tools.ToolOutput {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "path", .{ .string = path });
    try obj.put(a, "content", .{ .string = content });
    return runNamed(a, "write_file", .{ .object = obj });
}

fn expectOk(out: tools.ToolOutput) !void {
    if (out.is_error) {
        std.debug.print("unexpected tool error: {s}\n", .{out.text});
        return error.TestUnexpectedResult;
    }
}

test "grok read_file: whole-file is byte-exact, not sparse-numbered" {
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
    const out = try runRead(a, path, null, null, null);
    try expectOk(out);
    try std.testing.expectEqualStrings("hello world\n", out.text);
}

test "grok read_file: CRLF is kept (display does not strip CR)" {
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
    const out = try runRead(a, path, null, null, null);
    try expectOk(out);
    try std.testing.expectEqualStrings("hello\r\nworld\r\n", out.text);
}

test "grok read_file: start_line/end_line is the offset/limit window" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const g = Guard.arm();
    defer g.disarm();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "test.txt", .data = "line1\nline2\nline3\nline4\n" });
    const path = try relPath(a, tmp, "test.txt");
    // grok offset=2, limit=2 → lines 2..3. graff: start_line=2, end_line=3.
    const out = try runRead(a, path, 2, 3, null);
    try expectOk(out);
    try std.testing.expectEqualStrings("line2\nline3\n", out.text);
}

test "grok read_file: negative start_line clamps to 1, not from-end" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const g = Guard.arm();
    defer g.disarm();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "test.txt", .data = "a\nb\nc\n" });
    const path = try relPath(a, tmp, "test.txt");
    // grok offset=-3 on this file starts at line 2. graff clamps to line 1.
    const out = try runRead(a, path, -3, null, null);
    try expectOk(out);
    try std.testing.expectEqualStrings("a\nb\nc\n", out.text);
}

test "grok read_file: file not found" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const g = Guard.arm();
    defer g.disarm();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try relPath(a, tmp, "nonexistent.txt");
    const out = try runRead(a, path, null, null, null);
    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "does not exist") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "read_file") != null);
}

test "grok read_file: rejects a directory" {
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
    const out = try runRead(a, path, null, null, null);
    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "directory") != null);
}

test "grok read_file: contains returns numbered matching lines" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const g = Guard.arm();
    defer g.disarm();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "test.txt", .data = "alpha\nhello world\nomega hello\n" });
    const path = try relPath(a, tmp, "test.txt");
    const out = try runRead(a, path, null, null, "hello");
    try expectOk(out);
    try std.testing.expectEqualStrings("2: hello world\n3: omega hello\n", out.text);
}

test "grok read_file: PDF is bash, not a built-in extractor" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const g = Guard.arm();
    defer g.disarm();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "paper.pdf", .data = "%PDF-1.4\n" });
    const path = try relPath(a, tmp, "paper.pdf");
    const out = try runRead(a, path, null, null, null);
    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "binary") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "pdftotext") != null);
}

test "grok write_file: create then overwrite" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const g = Guard.arm();
    defer g.disarm();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try relPath(a, tmp, "out.txt");
    try expectOk(try runWrite(a, path, "first\n"));
    try expectOk(try runWrite(a, path, "second\n"));
    const on_disk = try tmp.dir.readFileAlloc(io, "out.txt", a, .limited(4096));
    try std.testing.expectEqualStrings("second\n", on_disk);
}

test "grok write_file: missing parent is not mkdir -p" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const g = Guard.arm();
    defer g.disarm();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try relPath(a, tmp, "nope/out.txt");
    const out = try runWrite(a, path, "x\n");
    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "parent directory") != null);
}
