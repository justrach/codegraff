//! Focused native formatter checks. Referenced explicitly by test_hooks.
const std = @import("std");
const f = @import("formatters.zig");
const run = f.runner;
const Io = std.Io;
const supported = @import("builtin").os.tag != .windows;

fn config(a: std.mem.Allocator, text: []const u8) !f.Registry {
    return f.parse(a, try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}), "");
}
fn rootOf(tmp: anytype, a: std.mem.Allocator) ![]const u8 {
    return tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
}
fn scriptRegistry(a: std.mem.Allocator, script: []const u8, timeout_ms: u64) !f.Registry {
    const entries = try a.alloc(f.Formatter, 1);
    entries[0] = .{ .name = "fixture", .custom = true, .command = try a.dupe([]const u8, &.{ "python3", "-I", script, "{file}" }), .extensions = &.{ ".txt", ".json" }, .timeout_ms = timeout_ms };
    return .{ .entries = entries };
}
fn expectBytes(tmp: anytype, path: []const u8, expected: []const u8) !void {
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(f.file_cap));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(expected, bytes);
}

test "formatter registry is off by default and false; disabled mutation needs no filesystem" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]?std.json.Value{ null, .{ .bool = false }, .{ .integer = 1 }, .{ .string = "true" } }) |value| {
        const reg = try f.parse(a, value, "");
        try std.testing.expectEqual(@as(usize, 0), reg.entries.len);
        var result = try run.run(reg, std.testing.allocator, std.testing.io, null, "../not-confined.zig", "/does-not-exist");
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(.skipped, result.status);
        try std.testing.expect(result.bytes == null);
    }
    const enabled = try config(a, "true");
    try std.testing.expectEqual(@as(usize, 6), enabled.entries.len);
}

test "formatter registry extension matches, overrides and timeout clamp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const reg = try config(arena.allocator(),
        \\{"zig":false,"gofmt":{"disabled":true},"custom":{"command":["fmt","{file}"],"extensions":[".zig",".tsx"],"timeout_ms":999999},"bad":{"command":"fmt --write","extensions":[".x"]},"download":{"command":["npx","prettier"],"extensions":[".js"]}}
    );
    try std.testing.expect(!f.matches(reg.entries[0], "f.zig"));
    try std.testing.expect(!f.matches(reg.entries[1], "f.go"));
    const custom = reg.entries[6];
    try std.testing.expect(f.matches(custom, "f.TSX"));
    try std.testing.expect(!f.matches(custom, "f.tsx.bak"));
    try std.testing.expectEqual(f.max_timeout_ms, custom.timeout_ms);
    try std.testing.expect(reg.entries[7].disabled);
    try std.testing.expect(reg.entries[8].disabled);
}

test "formatter registry project detection is nearest and bounded; custom wins" {
    if (comptime !supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "pkg/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "marker.json", .data = "{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "installed", .data = "fixture" });
    const root = try rootOf(tmp, a);
    const file = try std.fs.path.join(a, &.{ root, "pkg/src/a.txt" });
    const entries = [_]f.Formatter{
        .{ .name = "builtin", .command = &.{ "installed", "{file}" }, .extensions = &.{".txt"} },
        .{ .name = "custom", .command = &.{ "fixture", "{file}" }, .extensions = &.{".txt"}, .detect = &.{"marker.json"}, .custom = true },
    };
    const reg: f.Registry = .{ .entries = &entries, .path_env = root };
    const outer = run.select(reg, io, a, root, file).?;
    try std.testing.expectEqualStrings("custom", outer.formatter.name);
    try std.testing.expectEqualStrings(root, outer.cwd);
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/marker.json", .data = "{}" });
    const inner = run.select(reg, io, a, root, file).?;
    try std.testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "pkg" }), inner.cwd);
    const nested_root = try std.fs.path.join(a, &.{ root, "pkg/src" });
    try std.testing.expect(run.select(.{ .entries = entries[1..] }, io, a, nested_root, file) == null);
}

test "formatter registry JS built-ins require an installed in-root binary and never download" {
    if (comptime !supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootOf(tmp, a);
    try tmp.dir.writeFile(io, .{ .sub_path = "package.json", .data = "{}" });
    const file = try std.fs.path.join(a, &.{ root, "a.ts" });
    const reg = try config(a, "true");
    try std.testing.expect(run.select(reg, io, a, root, file) == null);
    try tmp.dir.createDirPath(io, "node_modules/.bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "node_modules/.bin/prettier", .data = "fixture" });
    const selected = run.select(reg, io, a, root, file).?;
    try std.testing.expectEqualStrings("prettier", selected.formatter.name);
    try tmp.dir.deleteFile(io, "node_modules/.bin/prettier");
    try tmp.dir.symLink(io, "/bin/echo", "node_modules/.bin/prettier", .{});
    try std.testing.expect(run.select(reg, io, a, root, file) == null);
}

test "formatter registry runs actual zig fmt and returns final bytes" {
    if (comptime !supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootOf(tmp, a);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "const n=1;\n" });
    const reg = try config(a, "{\"zig\":{\"command\":[\"zig\",\"fmt\",\"{file}\"]}}");
    const file = try std.fs.path.join(a, &.{ root, "a.zig" });
    var result = try run.run(reg, std.testing.allocator, io, root, "a.zig", file);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(.formatted, result.status);
    try std.testing.expectEqualStrings("const n = 1;\n", result.bytes.?);
    try expectBytes(tmp, "a.zig", "const n = 1;\n");
}

test "formatter registry failure timeout and output overflow restore verified bytes" {
    if (comptime !supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootOf(tmp, a);
    const script = try std.fs.path.join(a, &.{ root, "fixture.py" });
    const file = try std.fs.path.join(a, &.{ root, "a.txt" });
    const bodies = [_][]const u8{
        "import sys\nopen(sys.argv[1],'w').write('partial')\nsys.exit(1)\n",
        "import sys,time\nopen(sys.argv[1],'w').write('partial')\ntime.sleep(3)\n",
        "import sys\nopen(sys.argv[1],'w').write('partial')\nprint('x'*20000)\n",
        "import sys,os\nos.unlink(sys.argv[1])\nsys.exit(1)\n",
    };
    for (bodies, 0..) |body, i| {
        try tmp.dir.writeFile(io, .{ .sub_path = "fixture.py", .data = body });
        try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "verified edit\n" });
        const reg = try scriptRegistry(a, script, if (i == 1) 50 else 2000);
        const started: Io.Timestamp = .now(io, .awake);
        var result = try run.run(reg, std.testing.allocator, io, root, "a.txt", file);
        defer result.deinit(std.testing.allocator);
        const expected: @TypeOf(result.status) = switch (i) {
            1 => .timed_out,
            2 => .output_limit,
            else => .failed,
        };
        try std.testing.expectEqual(expected, result.status);
        try std.testing.expect(!result.failed_restore);
        if (i == 1) try std.testing.expect(started.untilNow(io, .awake).toMilliseconds() < 2500);
        try expectBytes(tmp, "a.txt", "verified edit\n");
    }
}

test "formatter registry paths are argv literals and existing in-root symlinks survive" {
    if (comptime !supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootOf(tmp, a);
    try tmp.dir.writeFile(io, .{ .sub_path = "fixture.py", .data = "import sys\nopen(sys.argv[1],'w').write('formatted\\n')\n" });
    const script = try std.fs.path.join(a, &.{ root, "fixture.py" });
    const reg = try scriptRegistry(a, script, 2000);
    const name = "a;$(touch INJECTED).txt";
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "unformatted" });
    try tmp.dir.symLink(io, name, "alias.txt", .{});
    const file = try std.fs.path.join(a, &.{ root, "alias.txt" });
    var result = try run.run(reg, std.testing.allocator, io, root, "alias.txt", file);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(.formatted, result.status);
    try expectBytes(tmp, name, "formatted\n");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_len = try tmp.dir.readLink(io, "alias.txt", &buf);
    try std.testing.expectEqualStrings(name, buf[0..link_len]);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "INJECTED", .{}));
    try tmp.dir.symLink(io, "/etc/passwd", "outside.txt", .{});
    var refused = try run.run(reg, std.testing.allocator, io, root, "outside.txt", try std.fs.path.join(a, &.{ root, "outside.txt" }));
    defer refused.deinit(std.testing.allocator);
    try std.testing.expectEqual(.unsafe_path, refused.status);
}

test "formatter registry syntax notes use final bytes and companion bytes even when disabled" {
    if (comptime !supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootOf(tmp, a);
    try tmp.dir.writeFile(io, .{ .sub_path = "fixture.py", .data = "import sys\nopen(sys.argv[1],'w').write('{}\\n')\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.json", .data = "not json" });
    const reg = try scriptRegistry(a, try std.fs.path.join(a, &.{ root, "fixture.py" }), 2000);
    const file = try std.fs.path.join(a, &.{ root, "a.json" });
    var client: std.http.Client = undefined;
    const ctx: @import("tools.zig").ToolCtx = .{ .gpa = std.testing.allocator, .io = io, .client = &client, .provider = undefined, .registry = null, .from_sub = false, .approvals = null, .tracer = null, .agent_cwd = root };
    const result = try f.finishEditWith(reg, ctx, "a.json", file, try std.testing.allocator.dupe(u8, "verified"), "not json");
    defer std.testing.allocator.free(result.text);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "parses as JSON") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "NOT valid JSON") == null);
    const companion = try f.finishEditWith(.{}, ctx, "a.json", file, try std.testing.allocator.dupe(u8, "verified"), null);
    defer std.testing.allocator.free(companion.text);
    try std.testing.expectEqualStrings("verified; parses as JSON", companion.text);
}

test "formatter registry write integration reports final length and rewind restores pre-write bytes" {
    if (comptime !supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootOf(tmp, a);
    try tmp.dir.writeFile(io, .{ .sub_path = "fixture.py", .data = "import sys\nopen(sys.argv[1],'w').write('{}\\n')\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.json", .data = "before" });
    const reg = try scriptRegistry(a, try std.fs.path.join(a, &.{ root, "fixture.py" }), 2000);
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/a.json", .{&tmp.sub_path});
    var args = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"path\":\"P\",\"content\":\"not json\",\"replace\":true}", .{});
    try args.object.put(a, "path", .{ .string = path });
    var client: std.http.Client = undefined;
    var snapshots: @import("snapshots.zig").Snapshots = .{ .gpa = gpa, .io = io };
    defer snapshots.deinit();
    const ctx: @import("tools.zig").ToolCtx = .{ .gpa = gpa, .io = io, .client = &client, .provider = undefined, .registry = null, .from_sub = false, .approvals = null, .tracer = null, .snapshots = &snapshots };
    const formatted = try @import("write_file.zig").execWithRegistry(ctx, args, reg);
    defer gpa.free(formatted.text);
    try std.testing.expect(!formatted.is_error);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "3 bytes; was 6") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted.text, "parses as JSON") != null);
    try expectBytes(tmp, "a.json", "{}\n");
    try std.testing.expectEqual(@as(usize, 1), snapshots.list.items.len);
    try std.testing.expectEqual(@as(usize, 1), snapshots.restore(0).restored);
    try expectBytes(tmp, "a.json", "before");
    const disabled = try @import("write_file.zig").execWithRegistry(ctx, args, .{});
    defer gpa.free(disabled.text);
    try expectBytes(tmp, "a.json", "not json");
    try std.testing.expect(std.mem.indexOf(u8, disabled.text, "NOT valid JSON") != null);
    try std.testing.expect(std.mem.indexOf(u8, disabled.text, "formatter") == null);
}

test "formatter registry missing executable warns and keeps verified mutation" {
    if (comptime !supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootOf(tmp, a);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "verified\n" });
    const entries = [_]f.Formatter{.{ .name = "missing", .custom = true, .command = &.{ "graff-test-nonexistent-formatter", "{file}" }, .extensions = &.{".txt"} }};
    var result = try run.run(.{ .entries = &entries }, std.testing.allocator, io, root, "a.txt", try std.fs.path.join(a, &.{ root, "a.txt" }));
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(.unavailable, result.status);
    try std.testing.expect(!result.failed_restore);
    try expectBytes(tmp, "a.txt", "verified\n");
}

test "formatter registry refuses formatter-created escaping links without touching external bytes" {
    if (comptime !supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    const root = try rootOf(tmp, a);
    const other = try std.fs.path.join(a, &.{ try rootOf(outside, a), "other.txt" });
    try outside.dir.writeFile(io, .{ .sub_path = "other.txt", .data = "external bytes" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "verified\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "fixture.py", .data = "import os,sys\nos.unlink(sys.argv[2])\nos.symlink(sys.argv[1],sys.argv[2])\n" });
    const script = try std.fs.path.join(a, &.{ root, "fixture.py" });
    const entries = [_]f.Formatter{.{ .name = "unsafe", .custom = true, .command = &.{ "python3", "-I", script, other, "{file}" }, .extensions = &.{".txt"} }};
    var result = try run.run(.{ .entries = &entries }, std.testing.allocator, io, root, "a.txt", try std.fs.path.join(a, &.{ root, "a.txt" }));
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(.unsafe_path, result.status);
    try std.testing.expect(result.failed_restore);
    try expectBytes(outside, "other.txt", "external bytes");
    const text = try result.appendNote(std.testing.allocator, try std.testing.allocator.dupe(u8, "verified"));
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "final bytes unknown") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "verified edit kept") == null);
}

test "formatter built-in PATH lookup preserves multicall symlink basename and skips dangling links" {
    if (comptime !supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try rootOf(tmp, a);
    try tmp.dir.createDirPath(io, "pkg/src");
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.createDirPath(io, "broken");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/Cargo.toml", .data = "[package]\nname = \"pkg\"\nversion = \"0.1.0\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/src/lib.rs", .data = "pub fn x() {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/main.go", .data = "package main\nfunc   x() {}\n" });
    const shim =
        \\#!/bin/sh
        \\if [ "$(basename "$0")" != "gofmt" ]; then exit 2; fi
        \\for last; do :; done
        \\printf 'formatted:%s\n' "$(basename "$last")" > "$last"
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "multicall", .data = shim });
    const mc = try tmp.dir.openFile(io, "multicall", .{ .mode = .read_write });
    defer mc.close(io);
    if (Io.File.Permissions.has_executable_bit) try mc.setPermissions(io, .fromMode(0o755));
    try tmp.dir.symLink(io, "../multicall", "bin/rustfmt", .{});
    try tmp.dir.symLink(io, "../multicall", "bin/gofmt", .{});
    try tmp.dir.symLink(io, "../nonexistent", "broken/rustfmt", .{});

    const bin_dir = try std.fs.path.join(a, &.{ root, "bin" });
    const broken_dir = try std.fs.path.join(a, &.{ root, "broken" });
    const rs_target = try std.fs.path.join(a, &.{ root, "pkg/src/lib.rs" });
    const go_target = try std.fs.path.join(a, &.{ root, "pkg/main.go" });

    const broken_reg = try f.parse(a, .{ .bool = true }, broken_dir);
    try std.testing.expect(run.select(broken_reg, io, a, root, rs_target) == null);

    const reg = try f.parse(a, .{ .bool = true }, bin_dir);
    const rs_sel = run.select(reg, io, a, root, rs_target) orelse return error.TestExpectedSelection;
    try std.testing.expectEqualStrings("rustfmt", rs_sel.formatter.name);
    try std.testing.expectEqualStrings("rustfmt", std.fs.path.basename(rs_sel.executable));
    try std.testing.expect(std.mem.endsWith(u8, rs_sel.cwd, "/pkg"));

    var res = try run.run(reg, std.testing.allocator, io, root, "pkg/main.go", go_target);
    defer res.deinit(std.testing.allocator);
    try std.testing.expectEqual(.formatted, res.status);
    try expectBytes(tmp, "pkg/main.go", "formatted:main.go\n");
}
