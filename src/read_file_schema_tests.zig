//! #761: optional `read_file` fields must stay optional, and a path-only
//! (or null/empty optional) call is a whole-file read. Reached from
//! exec.zig's test block.

const std = @import("std");
const builtin = @import("builtin");
const Value = std.json.Value;

const exec = @import("exec.zig");
const tools = @import("tools.zig");

fn testCtx(client: *std.http.Client, cwd: []const u8) tools.ToolCtx {
    return .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .client = client,
        .provider = undefined,
        .registry = null,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
        .agent_cwd = cwd,
    };
}

fn readFile(cwd: []const u8, input_json: []const u8) !tools.ToolOutput {
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, input_json, .{});
    defer parsed.deinit();
    var client: std.http.Client = undefined;
    return exec.execTool(testCtx(&client, cwd), .{
        .id = "call_1",
        .name = "read_file",
        .input = parsed.value,
    });
}

test "read_file (#761): a call with only path is a whole-file read" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "hello whole file\n" });
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &real_buf);
    const cwd = real_buf[0..n];

    const only_path = try readFile(cwd, "{\"path\":\"note.txt\"}");
    defer gpa.free(only_path.text);
    try std.testing.expect(!only_path.is_error);
    try std.testing.expectEqualStrings("hello whole file\n", only_path.text);

    const nulls = try readFile(cwd,
        \\{"path":"note.txt","start_line":null,"end_line":null,"contains":null,"compact":null}
    );
    defer gpa.free(nulls.text);
    try std.testing.expect(!nulls.is_error);
    try std.testing.expectEqualStrings("hello whole file\n", nulls.text);

    const empty_contains = try readFile(cwd, "{\"path\":\"note.txt\",\"contains\":\"\"}");
    defer gpa.free(empty_contains.text);
    try std.testing.expect(!empty_contains.is_error);
    try std.testing.expectEqualStrings("hello whole file\n", empty_contains.text);

    const combined = try readFile(cwd, "{\"path\":\"note.txt\",\"contains\":\"hello\",\"start_line\":1}");
    defer gpa.free(combined.text);
    try std.testing.expect(combined.is_error);
    try std.testing.expect(std.mem.indexOf(u8, combined.text, "cannot be combined") != null);
}
