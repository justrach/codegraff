//! Bounded child activity, independent of the parent's prompt/stdout lifetime.
const std = @import("std");
const Io = std.Io;
const A = std.mem.Allocator;
const sink = @import("engine_sink.zig");
const util = @import("util.zig");
const proc = @import("proc_identity.zig");
const private_file: Io.File.Permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600);
const private_dir: Io.File.Permissions = if (@import("builtin").os.tag == .windows) .default_dir else .fromMode(0o700);
pub const max_events = 96;
pub const max_text = 2048;
pub const file_limit = 2 * 1024 * 1024;
pub const Meta = struct {
    id: []const u8,
    label: []const u8,
    task: []const u8,
    status: []const u8 = "working",
    updatedAt: i64 = 0,
    truncated: bool = false,
};
pub const InputKey = enum { path, file, command, url, description };
pub const Event = struct { type: []const u8, id: []const u8 = "", name: []const u8 = "", text: []const u8 = "", is_error: bool = false, input_key: InputKey = .description };
pub const Snapshot = struct { agent: Meta, events: []const Event, response: []const u8 };
pub fn directory(buf: []u8, pid: i32, start_id: u64) ![]const u8 {
    return std.fmt.bufPrint(buf, "activity-{d}-{x}", .{ pid, start_id });
}
pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    return true;
}
pub fn cleanup(io: Io, registry: Io.Dir, pid: i32, start_id: u64) void {
    var buf: [80]u8 = undefined;
    registry.deleteTree(io, directory(&buf, pid, start_id) catch return) catch {};
}
fn writeAtomic(io: Io, a: A, dir: Io.Dir, name: []const u8, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    defer a.free(bytes);
    var f = try dir.createFileAtomic(io, name, .{ .permissions = private_file, .replace = true });
    defer f.deinit(io);
    try f.file.writeStreamingAll(io, bytes);
    try f.replace(io);
}

pub const Recorder = struct {
    a: A,
    io: Io,
    dir: Io.Dir,
    meta: Meta,
    events: std.ArrayList(Event) = .empty,
    mu: Io.Mutex = .init,
    last_write: i64 = 0,
    response: []const u8 = "",
    pub fn init(a: A, io: Io, registry_path: []const u8, id: []const u8, label: []const u8, task: []const u8) !Recorder {
        if (!validId(id)) return error.InvalidChildId;
        var registry = try Io.Dir.cwd().openDir(io, registry_path, .{});
        defer registry.close(io);
        const self = proc.selfRecord(io);
        var buf: [80]u8 = undefined;
        const name = try directory(&buf, self.pid, self.start_id);
        registry.createDir(io, name, private_dir) catch |err| if (err != error.PathAlreadyExists) return err;
        const dir = try registry.openDir(io, name, .{ .iterate = true });
        var result: Recorder = .{ .a = a, .io = io, .dir = dir, .meta = .{ .id = id, .label = util.utf8Prefix(label, 256), .task = util.utf8Prefix(task, 2048) } };
        result.publish(true);
        return result;
    }
    pub fn deinit(self: *Recorder) void {
        if (std.mem.eql(u8, self.meta.status, "working")) self.finish(false, "Sub-agent ended before producing a report.");
        for (self.events.items) |event| self.freeEvent(event);
        self.events.deinit(self.a);
        self.dir.close(self.io);
    }
    pub fn engineSink(self: *Recorder) sink.EngineSink {
        return .{ .ctx = self, .vt = &vtable };
    }
    const vtable: sink.VTable = .{ .emit = emit, .durable = false };
    fn emit(ctx: *anyopaque, stamped: sink.Stamped) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const ev: Event = switch (stamped.event) {
            .reasoning_delta => |v| .{ .type = "reasoning", .text = v.text },
            .text_delta => |v| .{ .type = "text", .text = v.text },
            .tool_call_announced => |v| .{ .type = "tool_call", .id = v.id, .name = v.name, .text = inputTitle(v.input), .input_key = inputKey(v.input) },
            .tool_result => |v| .{ .type = "tool_result", .id = v.id, .name = v.name, .text = v.text, .is_error = v.is_error or v.cancelled },
            .tool_rejected => |v| .{ .type = "tool_result", .id = v.id, .name = v.name, .text = v.message, .is_error = true },
            else => return,
        };
        self.append(ev) catch return;
        self.publish(std.mem.eql(u8, ev.type, "tool_call") or std.mem.eql(u8, ev.type, "tool_result"));
    }
    fn inputTitle(input: std.json.Value) []const u8 {
        if (input != .object) return "";
        return util.strFieldObj(input.object, @tagName(inputKey(input))) orelse "";
    }
    fn inputKey(input: std.json.Value) InputKey {
        if (input != .object) return .description;
        inline for (std.meta.tags(InputKey)) |key| {
            if (util.strFieldObj(input.object, @tagName(key)) != null) return key;
        }
        return .description;
    }
    fn freeEvent(self: *Recorder, event: Event) void {
        self.a.free(event.id);
        self.a.free(event.name);
        self.a.free(event.text);
    }
    pub fn append(self: *Recorder, ev: Event) !void {
        const text = util.utf8Prefix(ev.text, max_text);
        if (text.len < ev.text.len) self.meta.truncated = true;
        if ((std.mem.eql(u8, ev.type, "text") or std.mem.eql(u8, ev.type, "reasoning")) and self.events.items.len > 0) {
            const last = &self.events.items[self.events.items.len - 1];
            if (std.mem.eql(u8, last.type, ev.type) and last.text.len + text.len <= max_text) {
                const combined = try std.mem.concat(self.a, u8, &.{ last.text, text });
                self.a.free(last.text);
                last.text = combined;
                return;
            }
        }
        const id = try self.a.dupe(u8, util.utf8Prefix(ev.id, 128));
        errdefer self.a.free(id);
        const name = try self.a.dupe(u8, util.utf8Prefix(ev.name, 128));
        errdefer self.a.free(name);
        const owned = try self.a.dupe(u8, text);
        errdefer self.a.free(owned);
        if (self.events.items.len == max_events) {
            self.freeEvent(self.events.orderedRemove(0));
            self.meta.truncated = true;
        }
        try self.events.append(self.a, .{ .type = ev.type, .id = id, .name = name, .text = owned, .is_error = ev.is_error, .input_key = ev.input_key });
    }
    pub fn finish(self: *Recorder, ok: bool, report: []const u8) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        self.meta.status = if (ok) "completed" else "failed";
        self.response = util.utf8Prefix(report, 32768);
        if (self.response.len != report.len) self.meta.truncated = true;
        self.publish(true);
        self.prune();
        self.response = ""; // report belongs to the worker's arena
    }
    fn prune(self: *Recorder) void {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const a = arena.allocator();
        var completed: std.ArrayList(Meta) = .empty;
        var it = self.dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".meta")) continue;
            const bytes = self.dir.readFileAlloc(self.io, entry.name, a, .limited(16384)) catch continue;
            const meta = std.json.parseFromSliceLeaky(Meta, a, bytes, .{}) catch continue;
            if (!validId(meta.id) or std.mem.eql(u8, meta.status, "working")) continue;
            completed.append(a, meta) catch return;
        }
        std.mem.sort(Meta, completed.items, {}, struct {
            fn less(_: void, x: Meta, y: Meta) bool {
                return x.updatedAt > y.updatedAt;
            }
        }.less);
        for (completed.items[@min(64, completed.items.len)..]) |meta| {
            var buf: [100]u8 = undefined;
            self.dir.deleteFile(self.io, std.fmt.bufPrint(&buf, "{s}.meta", .{meta.id}) catch continue) catch {};
            self.dir.deleteFile(self.io, std.fmt.bufPrint(&buf, "{s}.json", .{meta.id}) catch continue) catch {};
        }
    }
    fn publish(self: *Recorder, force: bool) void {
        const now = util.unixMs(self.io);
        if (!force and now - self.last_write < 500) return;
        self.meta.updatedAt = now;
        var buf: [100]u8 = undefined;
        const data_name = std.fmt.bufPrint(&buf, "{s}.json", .{self.meta.id}) catch return;
        writeAtomic(self.io, self.a, self.dir, data_name, Snapshot{ .agent = self.meta, .events = self.events.items, .response = self.response }) catch return;
        const meta_name = std.fmt.bufPrint(&buf, "{s}.meta", .{self.meta.id}) catch return;
        writeAtomic(self.io, self.a, self.dir, meta_name, self.meta) catch return;
        self.last_write = now;
    }
};

/// Disabled when the parent has no local presence (including lean eval runs).
pub fn start(a: A, io: Io, id: []const u8, label: []const u8, task: []const u8) ?Recorder {
    const dir = @import("presence.zig").registryPath() orelse return null;
    return Recorder.init(a, io, dir, id, label, task) catch null;
}

test "child activity coalesces deltas and bounds retained events and text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var r: Recorder = .{ .a = std.testing.allocator, .io = std.testing.io, .dir = try tmp.dir.openDir(std.testing.io, ".", .{}), .meta = .{ .id = "child", .label = "test", .task = "test", .status = "completed" } };
    defer r.deinit();
    try r.append(.{ .type = "text", .text = "one" });
    try r.append(.{ .type = "text", .text = "two" });
    try std.testing.expectEqualStrings("onetwo", r.events.items[0].text);
    for (0..200) |_| try r.append(.{ .type = "tool_call", .id = "call", .name = "read_file" });
    try std.testing.expectEqual(max_events, r.events.items.len);
    try std.testing.expect(r.meta.truncated);
    try std.testing.expect(!validId("../elsewhere"));
    try std.testing.expect(validId("sa-001-abc"));
}

test "frontendless child SSE reaches its own activity sink and final snapshot" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var recorder = try Recorder.init(a, io, root, "child-one", "Review", "Check the boundary");
    defer recorder.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var agent: @import("agent.zig").Agent = .{
        .gpa = a,
        .arena = arena.allocator(),
        .io = io,
        .client = undefined,
        .out = null,
        .provider = .{ .id = "test", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "test", .context = 0 },
        .messages = std.json.Array.init(arena.allocator()),
        .sub = true,
        .label = "Review",
        .sink = recorder.engineSink(),
    };
    @import("agent_stream.zig").printDelta(&agent, "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"Checking the input\",\"content\":\"I found the boundary\"}}]}");
    try std.testing.expectEqual(@as(usize, 2), recorder.events.items.len);
    try std.testing.expectEqualStrings("reasoning", recorder.events.items[0].type);
    try std.testing.expectEqualStrings("text", recorder.events.items[1].type);
    const call: @import("tools.zig").ToolCall = .{ .id = "call-one", .name = "read_file", .input = .null };
    try @import("agent_tools.zig").sayToolUse(&agent, call);
    @import("agent_tools.zig").sayToolResult(&agent, call, .{ .text = "contents", .is_error = false });
    recorder.finish(true, "Review finished");
    const bytes = try recorder.dir.readFileAlloc(io, "child-one.json", a, .limited(file_limit));
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(Snapshot, a, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("completed", parsed.value.agent.status);
    try std.testing.expectEqualStrings("Review finished", parsed.value.response);
    try std.testing.expectEqual(@as(usize, 4), parsed.value.events.len);
}

test "child retention preserves working children and removes oldest completed snapshots" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var r: Recorder = .{ .a = a, .io = io, .dir = try tmp.dir.openDir(io, ".", .{ .iterate = true }), .meta = .{ .id = "working", .label = "Working", .task = "Review" } };
    defer r.deinit();
    r.publish(true);
    for (0..70) |i| {
        var id_buf: [64]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "completed-{d}", .{i});
        var file_buf: [80]u8 = undefined;
        try writeAtomic(io, a, r.dir, try std.fmt.bufPrint(&file_buf, "{s}.meta", .{id}), Meta{ .id = id, .label = "Done", .task = "Review", .status = "completed", .updatedAt = @intCast(i) });
        try r.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&file_buf, "{s}.json", .{id}), .data = "{}" });
    }
    r.prune();
    try std.testing.expectError(error.FileNotFound, r.dir.openFile(io, "completed-0.json", .{}));
    const kept = try r.dir.openFile(io, "completed-69.json", .{});
    kept.close(io);
    const working = try r.dir.openFile(io, "working.json", .{});
    working.close(io);
    var count: usize = 0;
    var it = r.dir.iterate();
    while (try it.next(io)) |entry| if (std.mem.endsWith(u8, entry.name, ".meta")) {
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, 65), count);
}
