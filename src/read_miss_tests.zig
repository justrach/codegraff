//! Integration coverage for #1116: guessed incrementing `read_file` paths
//! stop after `miss_limit` not-founds and do not keep executing.

const std = @import("std");
const builtin = @import("builtin");
const Value = std.json.Value;

const Agent = @import("agent.zig").Agent;
const exec = @import("exec.zig");
const read_miss = @import("read_miss.zig");
const rlm = @import("rlm.zig");
const tools = @import("tools.zig");
const ToolCall = tools.ToolCall;

fn jsonCall(arena: std.mem.Allocator, id: []const u8, path: []const u8) !ToolCall {
    const raw = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\"}}", .{path});
    return .{
        .id = id,
        .name = "read_file",
        .input = try std.json.parseFromSliceLeaky(Value, arena, raw, .{}),
    };
}

fn testAgent(arena: std.mem.Allocator, cwd: []const u8, client: *std.http.Client) Agent {
    return .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = client,
        .provider = undefined,
        .messages = undefined,
        .sub = true,
        .label = "test",
        .out = null,
        .agent_cwd = cwd,
    };
}

test "runTools: incrementing invented ADR paths stop after miss_limit (#1116)" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &real_buf);
    const cwd = real_buf[0..n];

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var agent = testAgent(arena, cwd, &client);

    const paths = [_][]const u8{
        "docs/adr/0365-foo.md",
        "docs/adr/0366-bar.md",
        "docs/adr/0367-baz.md",
        "docs/adr/0368-qux.md",
        "docs/adr/0369-quux.md",
        "docs/adr/0370-corge.md",
    };
    var calls: [6]ToolCall = undefined;
    for (paths, 0..) |p, i| calls[i] = try jsonCall(arena, paths[i], p);

    const results = try agent.runTools(&calls);
    var executed_misses: usize = 0;
    var refused: usize = 0;
    for (results) |r| {
        try std.testing.expect(r.is_error);
        if (std.mem.indexOf(u8, r.text, "refused") != null) {
            refused += 1;
            try std.testing.expect(std.mem.indexOf(u8, r.text, "codedb list_dir") != null);
        } else if (std.mem.indexOf(u8, r.text, "does not exist") != null) {
            executed_misses += 1;
        } else return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, read_miss.miss_limit), executed_misses);
    try std.testing.expectEqual(@as(usize, paths.len - read_miss.miss_limit), refused);
    try std.testing.expect(agent.read_miss.shouldRefuse("docs/adr/0371-invented.md"));
}

test "runTools: sequential same-prefix misses refuse the next guess" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &real_buf);
    const cwd = real_buf[0..n];

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var agent = testAgent(arena, cwd, &client);

    const first = [_][]const u8{ "docs/adr/a.md", "docs/adr/b.md", "docs/adr/c.md" };
    var wave1: [3]ToolCall = undefined;
    for (first, 0..) |p, i| wave1[i] = try jsonCall(arena, p, p);
    const r1 = try agent.runTools(&wave1);
    for (r1) |r| {
        try std.testing.expect(r.is_error);
        try std.testing.expect(std.mem.indexOf(u8, r.text, "does not exist") != null);
    }

    const next = try jsonCall(arena, "d", "docs/adr/d.md");
    const r2 = try agent.runTools(&[_]ToolCall{next});
    try std.testing.expect(r2[0].is_error);
    try std.testing.expect(std.mem.indexOf(u8, r2[0].text, "refused") != null);
    try std.testing.expect(std.mem.indexOf(u8, r2[0].text, "codedb list_dir docs/adr") != null);
}

test "execTool refuses a latched prefix without opening the path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tracker: read_miss.Tracker = .{};
    tracker.noteResult("docs/adr/0365-a.md", true);
    tracker.noteResult("docs/adr/0366-b.md", true);
    tracker.noteResult("docs/adr/0367-c.md", true);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const call = try jsonCall(arena, "x", "docs/adr/0368-d.md");
    const out = exec.execTool(.{
        .gpa = gpa,
        .io = io,
        .client = &client,
        .provider = undefined,
        .registry = null,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
        .read_miss = &tracker,
    }, call);
    defer gpa.free(out.text);
    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "refused") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "does not exist") == null);
}

test "rlm host reads refuse incrementing invented paths after miss_limit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &real_buf);
    const cwd = real_buf[0..n];
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var tracker: read_miss.Tracker = .{};
    const saved = rlm.available;
    defer {
        rlm.available = saved;
        rlm.resetLive(gpa, io);
    }
    rlm.available = true;
    const out = try rlm.runScript(.{
        .gpa = gpa,
        .io = io,
        .client = &client,
        .provider = undefined,
        .registry = null,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
        .agent_cwd = cwd,
        .read_miss = &tracker,
    },
        \\a = read_file("docs/adr/0365-a.md")
        \\b = read_file("docs/adr/0366-b.md")
        \\c = read_file("docs/adr/0367-c.md")
        \\d = read_file("docs/adr/0368-d.md")
        \\print(d)
    );
    defer gpa.free(out.text);
    try std.testing.expect(out.is_error or std.mem.indexOf(u8, out.text, "refused") != null);
    try std.testing.expect(tracker.shouldRefuse("docs/adr/0369-e.md"));
}

test "rejectToolCall refuses a latched prefix before the call counts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = .{
        .gpa = a,
        .arena = a,
        .io = std.testing.io,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = null,
    };
    agent.read_miss.noteResult("docs/adr/0365-a.md", true);
    agent.read_miss.noteResult("docs/adr/0366-b.md", true);
    agent.read_miss.noteResult("docs/adr/0367-c.md", true);
    const call = try jsonCall(a, "1", "docs/adr/0368-d.md");
    const denied = (try @import("agent_tools.zig").rejectToolCall(&agent, call)).?;
    try std.testing.expect(denied.is_error);
    try std.testing.expect(std.mem.indexOf(u8, denied.text, "refused") != null);
    try std.testing.expectEqual(@as(u64, 0), agent.tool_calls_this_turn);
}
