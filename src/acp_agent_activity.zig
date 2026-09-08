//! Read-only child inspection through graff/agents, with standard ACP updates.
const std = @import("std");
const Io = std.Io;
const A = std.mem.Allocator;
const activity = @import("subagent_activity.zig");
const proto = @import("acp_protocol.zig");
const stream = @import("acp_stream.zig");

pub fn list(a: A, io: Io, dir: Io.Dir) ![]activity.Meta {
    var rows: std.ArrayList(activity.Meta) = .empty;
    var scan = dir.iterate();
    var count: usize = 0;
    while (try scan.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".meta")) continue;
        count += 1;
        if (count > 256) break;
        const bytes = dir.readFileAlloc(io, entry.name, a, .limited(16384)) catch continue;
        const row = std.json.parseFromSliceLeaky(activity.Meta, a, bytes, .{ .ignore_unknown_fields = true }) catch continue;
        if (activity.validId(row.id)) try rows.append(a, row);
    }
    std.mem.sort(activity.Meta, rows.items, {}, struct {
        fn less(_: void, x: activity.Meta, y: activity.Meta) bool {
            return x.updatedAt > y.updatedAt;
        }
    }.less);
    return rows.items;
}

pub fn updates(a: A, snapshot: activity.Snapshot) ![]std.json.Value {
    var rows: std.ArrayList(std.json.Value) = .empty;
    for (snapshot.events) |event| {
        var out: Io.Writer.Allocating = .init(a);
        defer out.deinit();
        const w = &out.writer;
        if (std.mem.eql(u8, event.type, "reasoning")) {
            try stream.writeThought(w, snapshot.agent.id, event.text);
        } else if (std.mem.eql(u8, event.type, "text")) {
            try stream.writeMessage(w, snapshot.agent.id, event.text);
        } else if (std.mem.eql(u8, event.type, "tool_call")) {
            var input: std.json.ObjectMap = .empty;
            try input.put(a, @tagName(event.input_key), .{ .string = event.text });
            try stream.writeToolCall(w, snapshot.agent.id, event.id, event.name, .{ .object = input });
        } else if (std.mem.eql(u8, event.type, "tool_result")) {
            try stream.writeToolDone(w, snapshot.agent.id, event.id, event.is_error, event.text);
        } else continue;
        try rows.append(a, try std.json.parseFromSliceLeaky(std.json.Value, a, w.buffered(), .{}));
    }
    return rows.items;
}

/// Parent identity and workspace scope have already been verified by acp_agents.
pub fn handle(a: A, io: Io, registry: Io.Dir, out: *Io.Writer, req: proto.Request, pid: i32, start: u64, child: []const u8) !void {
    var buf: [80]u8 = undefined;
    var dir = registry.openDir(io, try activity.directory(&buf, pid, start), .{ .iterate = true }) catch {
        if (child.len == 0) try proto.writeResult(out, req.id, .{ .children = &.{}, .available = false }) else try proto.writeError(out, req.id, -32001, "Sub-agent activity is unavailable; this session may use an older binary");
        return;
    };
    defer dir.close(io);
    if (child.len == 0) {
        const children = try list(a, io, dir);
        try proto.writeResult(out, req.id, .{ .children = children[0..@min(children.len, 128)], .available = true, .truncated = children.len > 128 });
        return;
    }
    if (!activity.validId(child)) {
        try proto.writeError(out, req.id, -32602, "Invalid sub-agent identifier");
        return;
    }
    const name = try std.fmt.allocPrint(a, "{s}.json", .{child});
    const bytes = dir.readFileAlloc(io, name, a, .limited(activity.file_limit)) catch {
        try proto.writeError(out, req.id, -32001, "Sub-agent activity is no longer available");
        return;
    };
    const snapshot = std.json.parseFromSliceLeaky(activity.Snapshot, a, bytes, .{ .ignore_unknown_fields = true }) catch {
        try proto.writeError(out, req.id, -32001, "Sub-agent activity could not be read");
        return;
    };
    if (!std.mem.eql(u8, snapshot.agent.id, child) or snapshot.events.len > activity.max_events) {
        try proto.writeError(out, req.id, -32602, "Sub-agent snapshot does not match the selected child");
        return;
    }
    try proto.writeResult(out, req.id, .{ .agent = snapshot.agent, .updates = try updates(a, snapshot), .response = snapshot.response });
}

test "child updates retain identity and reuse ACP thought tool and response shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const snapshot: activity.Snapshot = .{ .agent = .{ .id = "child-a", .label = "Review", .task = "Review" }, .response = "Done", .events = &.{
        .{ .type = "reasoning", .text = "Checking the boundary" },
        .{ .type = "tool_call", .id = "call-1", .name = "read_file", .text = "example.ts", .input_key = .path },
        .{ .type = "tool_result", .id = "call-1", .text = "file body" },
        .{ .type = "text", .text = "Done" },
    } };
    const result = try updates(a, snapshot);
    try std.testing.expectEqual(@as(usize, 4), result.len);
    for (result) |row| try std.testing.expectEqualStrings("child-a", row.object.get("params").?.object.get("sessionId").?.string);
    const update = result[1].object.get("params").?.object.get("update").?;
    try std.testing.expectEqualStrings("call-1", update.object.get("toolCallId").?.string);
    try std.testing.expectEqualStrings("read", update.object.get("kind").?.string);
    try std.testing.expectEqualStrings("example.ts", update.object.get("rawInput").?.object.get("path").?.string);
}

test "child inspection verifies parent identity scope and child without consuming messages" {
    const presence = @import("presence.zig");
    const peers = @import("acp_agents.zig");
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, presence.registry_subdir);
    var live = try tmp.dir.openDir(io, presence.registry_subdir, .{});
    defer live.close(io);
    const self = @import("proc_identity.zig").selfRecord(io);
    if (self.start_id == 0) return error.SkipZigTest;
    try live.writeFile(io, .{ .sub_path = "peer.json", .data = try presence.formatRecord(a, .{ .pid = self.pid, .start_id = self.start_id, .session_id = "parent", .identity = "different-workspace" }) });
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);
    const registry = try live.realPathFileAlloc(io, ".", a);
    var first = try activity.Recorder.init(std.testing.allocator, io, registry, "child-a", "First child", "Inspect");
    defer first.deinit();
    var second = try activity.Recorder.init(std.testing.allocator, io, registry, "child-b", "Second child", "Review");
    defer second.deinit();
    first.finish(true, "First child result");
    second.finish(false, "Second child failed");
    const cases = .{
        .{ "children", "device", self.start_id, "", "First child", "Second child" },
        .{ "activity", "device", self.start_id, "child-a", "First child result", "!Second child failed" },
        .{ "activity", "device", self.start_id, "child-b", "Second child failed", "!First child result" },
        .{ "activity", "workspace", self.start_id, "child-a", "Parent session changed", "!First child result" },
        .{ "activity", "device", @as(u64, 0), "child-a", "Parent session changed", "!First child result" },
        .{ "activity", "device", self.start_id, "../child-a", "Invalid sub-agent", "!First child result" },
    };
    inline for (cases) |case| {
        const line = try std.json.Stringify.valueAlloc(a, .{ .id = 1, .method = "graff/agents", .params = .{ .action = case[0], .scope = case[1], .target = "parent", .startId = try std.fmt.allocPrint(a, "{d}", .{case[2]}), .child = case[3] } }, .{});
        var out: Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try std.testing.expect(try peers.handle(a, io, home, &out.writer, proto.parseRequest(a, line).?));
        try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), case[4]) != null);
        if (case[5][0] == '!') {
            try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), case[5][1..]) == null);
        } else try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), case[5]) != null);
    }
    try std.testing.expectEqual(@as(usize, 0), (try peers.tail(a, io, live, presence.device_room)).len);
}
