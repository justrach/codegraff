//! Post-write and post-edit syntax notes (#1890, ADR 0231 extension).
//! Keeps disk mutations non-destructive (`is_error = false`) while attaching
//! fast inline parse feedback for `.json`, `.zig`/`.zon`, `.py`, and `.go` so
//! the model repairs syntax mistakes on the immediate next turn.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const jobs = @import("jobs.zig");

const max_check_bytes: usize = 1024 * 1024;
const max_diag_chars: usize = 200;

pub fn append(gpa: Allocator, io: Io, w: *Io.Writer, path: []const u8, resolved: []const u8, content: []const u8) !void {
    if (std.ascii.endsWithIgnoreCase(path, ".json")) return jsonNote(gpa, w, content);
    if (content.len > max_check_bytes or std.mem.indexOfScalar(u8, content, 0) != null) return;
    if (std.ascii.endsWithIgnoreCase(path, ".zig")) return zigNote(gpa, w, content, .zig);
    if (std.ascii.endsWithIgnoreCase(path, ".zon")) return zigNote(gpa, w, content, .zon);
    if (resolved.len == 0) return;
    if (std.ascii.endsWithIgnoreCase(path, ".py")) return pyNote(gpa, io, w, resolved);
    if (std.ascii.endsWithIgnoreCase(path, ".go")) return goNote(gpa, io, w, resolved);
}

pub fn appendToOwned(gpa: Allocator, io: Io, base: []u8, path: []const u8, resolved: []const u8, content: []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try append(gpa, io, &aw.writer, path, resolved, content);
    const suffix = aw.written();
    if (suffix.len == 0) return base;
    const combined = try std.fmt.allocPrint(gpa, "{s}{s}", .{ base, suffix });
    gpa.free(base);
    return combined;
}

pub fn jsonNote(gpa: Allocator, w: *Io.Writer, content: []const u8) !void {
    var scanner = std.json.Scanner.initCompleteInput(gpa, content);
    defer scanner.deinit();
    var diag: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);
    while (true) {
        const token = scanner.next() catch |err| {
            if (err == error.OutOfMemory) return;
            return w.print("; NOT valid JSON ({t} at line {d}, column {d})", .{ err, diag.getLine(), diag.getColumn() });
        };
        if (token == .end_of_document) return w.writeAll("; parses as JSON");
    }
}

fn zigNote(gpa: Allocator, w: *Io.Writer, content: []const u8, mode: std.zig.Ast.Mode) !void {
    const src = gpa.allocSentinel(u8, content.len, 0) catch return;
    defer gpa.free(src);
    @memcpy(src, content);
    var ast = std.zig.Ast.parse(gpa, src, .{ .mode = mode }) catch return;
    defer ast.deinit(gpa);
    if (ast.errors.len == 0) return;
    const err = ast.errors[0];
    const loc = ast.tokenLocation(0, err.token);
    var msg_aw: Io.Writer.Allocating = .init(gpa);
    defer msg_aw.deinit();
    ast.renderError(err, &msg_aw.writer) catch return;
    const raw = std.mem.trim(u8, msg_aw.written(), " \t\r\n");
    const clipped = clipOneLine(raw);
    try w.print("; SYNTAX ERROR at line {d}, column {d}: {s}", .{ loc.line + 1, loc.column + 1, clipped });
}

fn pyNote(gpa: Allocator, io: Io, w: *Io.Writer, resolved: []const u8) !void {
    const script =
        "import ast,sys\ntry:\n ast.parse(open(sys.argv[1],'rb').read(),sys.argv[1])\n" ++
        "except SyntaxError as e:\n sys.stderr.write(f'line {e.lineno or 1}: {e.__class__.__name__}: {e.msg}\\n');sys.exit(1)\n";
    const run = jobs.runCapped(gpa, io, &.{ "python3", "-I", "-c", script, resolved }, 256, 1024, 250) catch return;
    defer {
        gpa.free(run.stdout);
        gpa.free(run.stderr);
    }
    const bad = switch (run.term) {
        .exited => |code| code != 0,
        else => false,
    };
    if (!bad or run.stderr.len == 0) return;
    const clipped = clipOneLine(std.mem.trim(u8, run.stderr, " \t\r\n"));
    if (clipped.len > 0) try w.print("; SYNTAX ERROR: {s}", .{clipped});
}

fn goNote(gpa: Allocator, io: Io, w: *Io.Writer, resolved: []const u8) !void {
    const run = jobs.runCapped(gpa, io, &.{ "gofmt", "-e", resolved }, 256, 1024, 200) catch return;
    defer {
        gpa.free(run.stdout);
        gpa.free(run.stderr);
    }
    const bad = switch (run.term) {
        .exited => |code| code != 0,
        else => false,
    };
    if (!bad or run.stderr.len == 0) return;
    const clipped = clipOneLine(std.mem.trim(u8, run.stderr, " \t\r\n"));
    if (clipped.len > 0) try w.print("; SYNTAX ERROR: {s}", .{clipped});
}

fn clipOneLine(s: []const u8) []const u8 {
    const nl = std.mem.indexOfAny(u8, s, "\r\n") orelse s.len;
    const line = s[0..nl];
    return line[0..@min(line.len, max_diag_chars)];
}

test "#1890 syntax_note reports broken JSON, Zig, and Python syntax while staying quiet on valid source" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    const ok_zig = try appendToOwned(gpa, io, try gpa.dupe(u8, "verified"), "a.zig", "", "pub fn f() usize { return 1; }\n");
    defer gpa.free(ok_zig);
    try std.testing.expectEqualStrings("verified", ok_zig);

    const bad_zig = try appendToOwned(gpa, io, try gpa.dupe(u8, "verified"), "a.zig", "", "pub fn f() usize {\n    return 1\n}\n");
    defer gpa.free(bad_zig);
    try std.testing.expect(std.mem.indexOf(u8, bad_zig, "; SYNTAX ERROR at line ") != null);

    const bad_json = try appendToOwned(gpa, io, try gpa.dupe(u8, "verified"), "a.json", "", "{\"a\": }");
    defer gpa.free(bad_json);
    try std.testing.expect(std.mem.indexOf(u8, bad_json, "; NOT valid JSON (") != null);

    if (@import("builtin").os.tag != .windows) {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "bad.py", .data = "async def gen():\n    yield from [1, 2]\n" });
        var real_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPathFile(io, "bad.py", &real_buf);
        const py_msg = try appendToOwned(gpa, io, try gpa.dupe(u8, "verified"), "bad.py", real_buf[0..n], "async def gen():\n    yield from [1, 2]\n");
        defer gpa.free(py_msg);
        if (std.mem.indexOf(u8, py_msg, "SYNTAX ERROR") != null) {
            try std.testing.expect(std.mem.indexOf(u8, py_msg, "line 2") != null);
        }
    }
}
