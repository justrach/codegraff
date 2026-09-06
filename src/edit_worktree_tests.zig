//! #747: after a workspace switch, edit_file must write the selected tree.
//!
//! The persistence check already refuses a false success. The miss was the
//! write resolving a different root than the verify (relative path + a
//! stale Threaded-Io cwd after `chdir`, #721). Both paths now go through
//! `sessionAbs`, which follows the session display cwd — not `Io.Dir.cwd()`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const edit_verify = @import("edit_verify.zig");
const codedbpro_paths = @import("codedbpro_paths.zig");
const main_mod = @import("main.zig");

fn tmpAbs(io: Io, dir: anytype) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = dir.dir.realPath(io, &buf) catch return error.SkipZigTest;
    return std.testing.allocator.dupe(u8, buf[0..n]);
}

test "#747: editing the same relative name after a tree switch lands on the selected root" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var dir_a = std.testing.tmpDir(.{});
    defer dir_a.cleanup();
    var dir_b = std.testing.tmpDir(.{});
    defer dir_b.cleanup();
    try dir_a.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "alpha\n" });
    try dir_b.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "beta\n" });
    const path_a = try tmpAbs(io, &dir_a);
    defer gpa.free(path_a);
    const path_b = try tmpAbs(io, &dir_b);
    defer gpa.free(path_b);

    const saved = main_mod.g_cwd_display;
    defer main_mod.g_cwd_display = saved;

    var client: std.http.Client = undefined;
    const ctx = edit_verify.testCtx(&client);

    var a_obj: std.json.ObjectMap = .empty;
    defer a_obj.deinit(gpa);
    try a_obj.put(gpa, "path", .{ .string = "note.txt" });
    try a_obj.put(gpa, "old_string", .{ .string = "alpha\n" });
    try a_obj.put(gpa, "new_string", .{ .string = "ALPHA\n" });

    main_mod.g_cwd_display = path_a;
    const out_a = try edit_verify.execEdit(ctx, .{ .object = a_obj });
    defer gpa.free(out_a.text);
    try std.testing.expect(!out_a.is_error);

    var b_obj: std.json.ObjectMap = .empty;
    defer b_obj.deinit(gpa);
    try b_obj.put(gpa, "path", .{ .string = "note.txt" });
    try b_obj.put(gpa, "old_string", .{ .string = "beta\n" });
    try b_obj.put(gpa, "new_string", .{ .string = "BETA\n" });

    main_mod.g_cwd_display = path_b;
    const out_b = try edit_verify.execEdit(ctx, .{ .object = b_obj });
    defer gpa.free(out_b.text);
    try std.testing.expect(!out_b.is_error);

    const on_a = try dir_a.dir.readFileAlloc(io, "note.txt", gpa, .limited(64));
    defer gpa.free(on_a);
    const on_b = try dir_b.dir.readFileAlloc(io, "note.txt", gpa, .limited(64));
    defer gpa.free(on_b);
    try std.testing.expectEqualStrings("ALPHA\n", on_a);
    try std.testing.expectEqualStrings("BETA\n", on_b);
}

test "#747: sessionAbs of a relative name follows the selected cwd, not a sibling tree" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const a = try codedbpro_paths.sessionAbs(gpa, io, "/tmp/graff-747-tree-a", "note.txt");
    defer gpa.free(a);
    const b = try codedbpro_paths.sessionAbs(gpa, io, "/tmp/graff-747-tree-b", "note.txt");
    defer gpa.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
    try std.testing.expect(std.mem.endsWith(u8, a, "note.txt"));
    try std.testing.expect(std.mem.endsWith(u8, b, "note.txt"));

    const saved = main_mod.g_cwd_display;
    defer main_mod.g_cwd_display = saved;
    main_mod.g_cwd_display = "/tmp/graff-747-tree-a";
    const via_display = try codedbpro_paths.sessionAbs(gpa, io, null, "note.txt");
    defer gpa.free(via_display);
    try std.testing.expect(std.mem.indexOf(u8, via_display, "graff-747-tree-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, via_display, "graff-747-tree-b") == null);
}
