//! Local peer inspection and explicit human DMs. Reading never drains an inbox.
const std = @import("std");
const Io = std.Io;
const A = std.mem.Allocator;
const proto = @import("acp_protocol.zig");
const presence = @import("presence.zig");
const chan = @import("presence_chan.zig");
const proc = @import("proc_identity.zig");
const lease = @import("worktree_lease.zig");

fn field(params: ?std.json.Value, key: []const u8) []const u8 {
    const p = params orelse return "";
    if (p != .object) return "";
    const v = p.object.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

pub fn verified(owner: lease.Owner, probe: proc.Probe) bool {
    return owner.start_id != 0 and switch (probe) {
        .id => |id| id == owner.start_id,
        else => false,
    };
}

/// Bounded tail, including logs larger than the ordinary inbox read limit.
pub fn tail(a: A, io: Io, dir: Io.Dir, name: []const u8) ![]const chan.Message {
    const f = dir.openFile(io, name, .{}) catch return &.{};
    defer f.close(io);
    const size = (try f.stat(io)).size;
    const start = size -| (64 * 1024);
    const bytes = try a.alloc(u8, @intCast(size - start));
    const n = try f.readPositionalAll(io, bytes, start);
    var pos: usize = if (start == 0) 0 else (std.mem.indexOfScalar(u8, bytes[0..n], '\n') orelse return &.{}) + 1;
    var messages: std.ArrayList(chan.Message) = .empty;
    while (std.mem.indexOfScalarPos(u8, bytes[0..n], pos, '\n')) |end| {
        const line = bytes[pos..end];
        pos = end + 1;
        const m = std.json.parseFromSliceLeaky(chan.Message, a, line, .{ .ignore_unknown_fields = true }) catch continue;
        if (m.text.len > 8192 or m.text.len == 0) continue;
        try messages.append(a, m);
    }
    return messages.items[messages.items.len -| 100..];
}

pub fn handle(a: A, io: Io, home: []const u8, out: *Io.Writer, req: proto.Request) !bool {
    if (!std.mem.eql(u8, req.method, "graff/agents")) return false;
    if (req.id == null) return true;
    const root = lease.currentIdentity(a, io, a).id;
    const dir_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ home, presence.registry_subdir });
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
        if (std.mem.eql(u8, field(req.params, "action"), "send"))
            try proto.writeError(out, req.id, -32001, "Peer registry unavailable; start a Graff session first")
        else
            try proto.writeResult(out, req.id, .{ .agents = &.{}, .messages = &.{}, .delivery = "No connected Graffs" });
        return true;
    };
    defer dir.close(io);
    const all = presence.listPeersBounded(io, a, dir, 128);
    const action = field(req.params, "action");
    if (std.mem.eql(u8, action, "send")) {
        const target = field(req.params, "target");
        const text = std.mem.trim(u8, field(req.params, "text"), " \r\n\t");
        const kind = field(req.params, "kind");
        const start = field(req.params, "startId");
        for (all.records, all.probes) |owner, probe| {
            if (!verified(owner, probe) or !std.mem.eql(u8, target, owner.session_id)) continue;
            const expected = std.fmt.parseInt(u64, start, 10) catch 0;
            if (expected != owner.start_id or text.len == 0 or text.len > 8192 or (!std.mem.eql(u8, kind, "message") and !std.mem.eql(u8, kind, "handoff"))) break;
            // Legacy receivers match session-name substrings. Refuse a name
            // that could reach another live peer instead of guessing.
            for (all.records, all.probes) |other, other_probe| {
                if (other.pid != owner.pid and verified(other, other_probe) and @import("peer_target.zig").addressedTo(target, other.session_id)) {
                    try proto.writeError(out, req.id, -32602, "Recipient names overlap; rename a session before sending");
                    return true;
                }
            }
            const self = proc.selfRecord(io);
            const ok = chan.postMessage(io, a, dir, presence.device_room, .{
                .from_pid = self.pid,
                .from_start = self.start_id,
                .from_session = "GUI",
                .from_user = true,
                .to = owner.session_id,
                .text = if (std.mem.eql(u8, kind, "handoff")) try std.fmt.allocPrint(a, "Handoff request: {s}", .{text}) else text,
                .kind = kind,
                .ts_ms = @import("util.zig").unixMs(io),
            });
            if (ok) try proto.writeResult(out, req.id, .{ .delivery = "queued" }) else try proto.writeError(out, req.id, -32001, "Message could not be queued");
            return true;
        }
        try proto.writeError(out, req.id, -32602, "Recipient changed or message invalid; refresh and select the recipient again");
        return true;
    }
    if (action.len != 0 and !std.mem.eql(u8, action, "list")) {
        try proto.writeError(out, req.id, -32602, "Unknown agents action");
        return true;
    }
    const device = std.mem.eql(u8, field(req.params, "scope"), "device");
    const Row = struct { session: []const u8, startId: []const u8, pid: i32, title: []const u8, task: []const u8, workspace: []const u8, status: []const u8 };
    var rows: std.ArrayList(Row) = .empty;
    var identities: std.StringHashMap(void) = .init(a);
    try identities.put(root, {});
    for (all.records, all.probes) |owner, probe| {
        if (!verified(owner, probe) or (!device and !std.mem.eql(u8, root, owner.identity))) continue;
        try rows.append(a, .{ .session = owner.session_id, .startId = try std.fmt.allocPrint(a, "{d}", .{owner.start_id}), .pid = owner.pid, .title = owner.title, .task = owner.goal, .workspace = owner.identity, .status = owner.activity });
        try identities.put(owner.identity, {});
    }
    if (std.mem.eql(u8, field(req.params, "history"), "off")) {
        try proto.writeResult(out, req.id, .{ .agents = rows.items });
        return true;
    }
    var messages: std.ArrayList(chan.Message) = .empty;
    var it = identities.keyIterator();
    while (it.next()) |identity| {
        var buf: [chan.chan_name_max]u8 = undefined;
        try messages.appendSlice(a, try tail(a, io, dir, chan.chanName(&buf, identity.*)));
    }
    for (try tail(a, io, dir, presence.device_room)) |m| {
        const relevant = device or blk: {
            for (rows.items) |row| if (std.mem.eql(u8, row.session, m.to) or std.mem.eql(u8, row.session, m.from_session)) break :blk true;
            break :blk false;
        };
        if (relevant) try messages.append(a, m);
    }
    std.mem.sort(chan.Message, messages.items, {}, struct {
        fn less(_: void, x: chan.Message, y: chan.Message) bool {
            return x.ts_ms < y.ts_ms;
        }
    }.less);
    try proto.writeResult(out, req.id, .{ .agents = rows.items, .messages = messages.items[messages.items.len -| 100..], .delivery = "Queued messages are read at a peer's next step boundary. Handoffs are coordination requests, not ownership transfers." });
    return true;
}

/// Dedicated observer: no model, credentials, MCP, session files or presence entry.
pub fn run(init: std.process.Init) !void {
    var input_buf: [65536]u8 = undefined;
    var output_buf: [4096]u8 = undefined;
    var input = Io.File.stdin().reader(init.io, &input_buf);
    var output = Io.File.stdout().writer(init.io, &output_buf);
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    while (try input.interface.takeDelimiter('\n')) |line| {
        defer _ = arena.reset(.retain_capacity);
        const req = proto.parseRequest(arena.allocator(), line);
        if (req) |r| {
            if (!try handle(arena.allocator(), init.io, init.environ_map.get("HOME") orelse "", &output.interface, r))
                try proto.writeError(&output.interface, r.id, -32601, "Observer supports graff/agents only");
        }
        try output.interface.flush();
    }
}

test "agent inspection rejects recycled and unverifiable processes" {
    try std.testing.expect(verified(.{ .start_id = 4 }, .{ .id = 4 }));
    try std.testing.expect(!verified(.{ .start_id = 4 }, .{ .id = 5 }));
    try std.testing.expect(!verified(.{ .start_id = 4 }, .unknown));
    try std.testing.expect(!verified(.{}, .{ .id = 4 }));
}

test "agent history does not consume inbox cursors or torn records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "room", .data = "{\"text\":\"hello\"}\n{\"text\":\"torn" });
    try std.testing.expectEqual(@as(usize, 1), (try tail(arena.allocator(), io, tmp.dir, "room")).len);
    try std.testing.expectEqual(@as(usize, 1), (try tail(arena.allocator(), io, tmp.dir, "room")).len);
}

test "explicit GUI messages revalidate recipient and queue only to a temporary room" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, presence.registry_subdir);
    var live = try tmp.dir.openDir(io, presence.registry_subdir, .{});
    defer live.close(io);
    const self = proc.selfRecord(io);
    if (self.start_id == 0) return error.SkipZigTest;
    const record = try presence.formatRecord(a, .{ .pid = self.pid, .start_id = self.start_id, .session_id = "test-peer" });
    try live.writeFile(io, .{ .sub_path = "peer.json", .data = record });
    const home = try tmp.dir.realPathFileAlloc(io, ".", a);
    var storage: [4096]u8 = undefined;
    var writer: Io.Writer = .fixed(&storage);
    const stale = proto.parseRequest(a, "{\"id\":1,\"method\":\"graff/agents\",\"params\":{\"action\":\"send\",\"target\":\"test-peer\",\"startId\":\"0\",\"text\":\"review please\",\"kind\":\"handoff\"}}\n").?;
    try std.testing.expect(try handle(a, io, home, &writer, stale));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Recipient changed") != null);
    try std.testing.expectEqual(@as(usize, 0), (try tail(a, io, live, presence.device_room)).len);
    writer = .fixed(&storage);
    const valid = proto.parseRequest(a, try std.fmt.allocPrint(a, "{{\"id\":2,\"method\":\"graff/agents\",\"params\":{{\"action\":\"send\",\"target\":\"test-peer\",\"startId\":\"{d}\",\"text\":\"review please\",\"kind\":\"handoff\"}}}}", .{self.start_id})).?;
    try std.testing.expect(try handle(a, io, home, &writer, valid));
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "queued") != null);
    const posted = try tail(a, io, live, presence.device_room);
    try std.testing.expectEqual(@as(usize, 1), posted.len);
    try std.testing.expectEqualStrings("test-peer", posted[0].to);
    try std.testing.expectEqualStrings("handoff", posted[0].kind);
    try std.testing.expect(posted[0].from_user);
}

test "agent history reads recent bounded records even after a large old log" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old = try a.alloc(u8, 300 * 1024);
    @memset(old, ' ');
    try tmp.dir.writeFile(io, .{ .sub_path = "room", .data = old });
    try std.testing.expect(chan.postMessage(io, a, tmp.dir, "room", .{ .text = "old partial line" }));
    try std.testing.expect(chan.postMessage(io, a, tmp.dir, "room", .{ .text = "recent complete line" }));
    const messages = try tail(a, io, tmp.dir, "room");
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("recent complete line", messages[0].text);
}
