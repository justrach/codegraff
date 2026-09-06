//! `graff remote-control`: the serve supervisor with no listener (#722).
//!
//! The machine that runs the agent only ever dials OUT. It registers with the
//! gateway using the `graff login` key, long-polls the account's relay for
//! commands, and streams each session's event tape back as it lands. The
//! commands are exactly serve's request set — create a durable session, one
//! protocol request (user / answer / cancel / reattach), close — so a viewer
//! anywhere sees the same NDJSON a serve client would. Nothing is bound: the
//! only channel is the one this process opened, and revoking the key ends it.
//!
//! Sessions are serve's ServeSession (durable `--resume <id>` children with
//! the seq-stamped tape under .graff/serve/); serve_create spawns them and the
//! drain here mirrors serveMessage with the socket replaced by coalesced
//! uploads. The relay keeps a bounded recent window; the tape here is complete,
//! so a viewer whose cursor fell behind asks for `reattach` and gets a replay.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const root = @import("main.zig");
const serve = @import("serve.zig");
const serve_create = @import("serve_create.zig");
const events = @import("serve_events.zig");
const util = @import("util.zig");

const ServeState = serve.ServeState;
const ServeSession = serve.ServeSession;
const harness_version = root.harness_version;

pub const Config = struct {
    base: []const u8, // gateway base URL (GRAFF_REMOTE_BASE overrides for a local relay)
    key: []const u8, // the account's cg_sk_ key
    home: []const u8,
    name: ?[]const u8, // display name for this machine; default hostname
    serve: serve.ServeConfig,
};

/// Where this machine's stable relay identity lives (16 hex chars).
pub const device_file = ".graff/remote-device.json";
/// Longest one poll is held server-side before an empty answer.
const poll_wait_ms: u64 = 25_000;
/// Event lines above this go upstream as a stub; the local tape stays complete.
pub const upload_line_cap: usize = 256 * 1024;
/// Coalesce uploads: a burst of text deltas becomes one POST per window.
const flush_window_ms: i64 = 60;
const flush_bytes: usize = 32 * 1024;
const backoff_min_ms: i64 = 1_000;
const backoff_max_ms: i64 = 30_000;

const State = struct {
    st: ServeState,
    cfg: Config,
    client: std.http.Client,
    agent_id: [16]u8 = undefined,
    hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined,
    hostname: []const u8 = "",
};

const Reply = struct { code: u16, body: []const u8 };

fn post(self: *State, arena: Allocator, path: []const u8, payload: []const u8) !Reply {
    const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ self.cfg.base, path });
    var aw: Io.Writer.Allocating = .init(arena);
    const res = try self.client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .response_writer = &aw.writer,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = try std.fmt.allocPrint(arena, "Bearer {s}", .{self.cfg.key}) },
            .user_agent = .{ .override = "simple-harness/" ++ harness_version },
        },
    });
    return .{ .code = @intFromEnum(res.status), .body = aw.writer.buffered() };
}

/// The gateway's error message out of a non-2xx body, or the raw body.
fn errorMessage(arena: Allocator, body: []const u8) []const u8 {
    if (std.json.parseFromSliceLeaky(Value, arena, body, .{ .allocate = .alloc_always })) |v| {
        if (v == .object) if (v.object.get("error")) |e| if (e == .object)
            if (util.strFieldObj(e.object, "message")) |m| return m;
    } else |_| {}
    return body[0..@min(body.len, 200)];
}

pub fn remoteControlMain(gpa: Allocator, io: Io, cfg: Config, exe: []const u8) !void {
    var group: Io.Group = .init;
    defer group.cancel(io);
    var self: State = .{
        .st = .{ .gpa = gpa, .io = io, .exe = exe, .cfg = cfg.serve, .group = &group },
        .cfg = cfg,
        .client = .{ .allocator = gpa, .io = io },
    };
    defer self.client.deinit();
    self.hostname = std.posix.gethostname(&self.hostname_buf) catch "unknown";
    self.agent_id = try deviceId(io, gpa, cfg.home);
    const label = cfg.name orelse self.hostname;

    var backoff: i64 = backoff_min_ms;
    var registered = false;
    while (true) {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        if (!registered) {
            register(&self, arena, label) catch |err| {
                serve.serveLog(io, "remote-control: register failed ({t}) — retrying in {d}s", .{ err, @divTrunc(backoff, 1000) });
                io.sleep(.fromMilliseconds(backoff), .awake) catch return;
                backoff = @min(backoff * 2, backoff_max_ms);
                continue;
            };
            registered = true;
            serve.serveLog(io, "graff remote-control · {s} ({s}) · device {s} · relay {s} · sessions are `{s} --json` children · Ctrl-C disconnects", .{
                label, self.hostname, &self.agent_id, cfg.base, exe,
            });
        }
        const cmds = poll(&self, arena) catch |err| {
            if (err == error.UnknownDevice) registered = false;
            serve.serveLog(io, "remote-control: poll failed ({t}) — retrying in {d}s", .{ err, @divTrunc(backoff, 1000) });
            io.sleep(.fromMilliseconds(backoff), .awake) catch return;
            backoff = @min(backoff * 2, backoff_max_ms);
            continue;
        };
        backoff = backoff_min_ms;
        for (cmds) |cmd| runCommand(&self, arena, cmd);
    }
}

/// Read (or mint and persist) the 16-hex device id under $HOME.
fn deviceId(io: Io, gpa: Allocator, home: []const u8) ![16]u8 {
    var out: [16]u8 = undefined;
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ home, device_file });
    defer gpa.free(path);
    if (Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096))) |data| {
        defer gpa.free(data);
        if (parseDeviceId(data)) |id| return id;
    } else |_| {}
    var raw: [8]u8 = undefined;
    io.random(&raw);
    _ = std.fmt.bufPrint(&out, "{x:0>16}", .{std.mem.readInt(u64, &raw, .big)}) catch unreachable;
    if (std.fs.path.dirname(path)) |parent| Io.Dir.cwd().createDirPath(io, parent) catch {};
    var text_buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "{{\"device_id\":\"{s}\"}}\n", .{&out}) catch unreachable;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch |err|
        serve.serveLog(io, "remote-control: cannot persist device id at {s} ({t}) — this run gets a fresh one", .{ path, err });
    return out;
}

/// The stored id, only if it is exactly 16 lowercase hex characters.
pub fn parseDeviceId(data: []const u8) ?[16]u8 {
    const id = events.stringField(data, "device_id") orelse return null;
    if (id.len != 16) return null;
    for (id) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return null;
    var out: [16]u8 = undefined;
    @memcpy(&out, id);
    return out;
}

fn register(self: *State, arena: Allocator, label: []const u8) !void {
    // AT_FDCWD has no path of its own; resolve "." through it instead.
    const cwd: []const u8 = Io.Dir.cwd().realPathFileAlloc(self.st.io, ".", arena) catch "";
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(.{ .hostname = self.hostname, .name = label, .cwd = cwd, .version = harness_version });
    const path = try std.fmt.allocPrint(arena, "/v1/remote/agents/{s}/register", .{&self.agent_id});
    const r = try post(self, arena, path, aw.writer.buffered());
    if (r.code == 401 or r.code == 403) std.process.fatal("remote-control: gateway refused the key (HTTP {d}: {s}) — run `graff login`", .{ r.code, errorMessage(arena, r.body) });
    if (r.code < 200 or r.code >= 300) {
        serve.serveLog(self.st.io, "remote-control: HTTP {d}: {s}", .{ r.code, errorMessage(arena, r.body) });
        return error.RegisterFailed;
    }
}

/// One command the relay handed us. `body` is the object re-serialized to a
/// single line: serve's request set is line-oriented on the child's stdin.
pub const Command = struct {
    id: []const u8,
    kind: []const u8,
    session_id: ?[]const u8,
    body: []const u8,
};

fn poll(self: *State, arena: Allocator) ![]const Command {
    const payload = try pollPayload(self, arena);
    const path = try std.fmt.allocPrint(arena, "/v1/remote/agents/{s}/poll", .{&self.agent_id});
    const r = try post(self, arena, path, payload);
    if (r.code == 404) return error.UnknownDevice;
    if (r.code < 200 or r.code >= 300) {
        serve.serveLog(self.st.io, "remote-control: HTTP {d}: {s}", .{ r.code, errorMessage(arena, r.body) });
        return error.PollFailed;
    }
    return parseCommands(arena, r.body);
}

/// `{"wait_ms":N,"sessions":[{"id","state","last_seq"}…]}` — presence rides
/// on the poll. Names are validName-safe, so they print raw.
fn pollPayload(self: *State, arena: Allocator) ![]const u8 {
    const io = self.st.io;
    var aw: Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("{{\"wait_ms\":{d},\"sessions\":[", .{poll_wait_ms});
    self.st.mutex.lockUncancelable(io);
    defer self.st.mutex.unlock(io);
    for (self.st.sessions.items, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"id\":\"{s}\",\"state\":\"{s}\",\"last_seq\":{d}}}", .{
            s.name, if (s.in_flight.load(.acquire)) "busy" else "idle", s.last_seq,
        });
    }
    try w.writeAll("]}");
    return aw.writer.buffered();
}

/// Command ids are relay-minted; anything outside [A-Za-z0-9_-] is dropped
/// rather than printed back into a JSON body.
pub fn validCommandId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}

pub fn parseCommands(arena: Allocator, text: []const u8) ![]const Command {
    const v = std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch return error.BadReply;
    if (v != .object) return error.BadReply;
    const list = v.object.get("commands") orelse return &.{};
    if (list != .array) return error.BadReply;
    var out: std.ArrayList(Command) = .empty;
    for (list.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const id = util.strFieldObj(o, "id") orelse continue;
        const kind = util.strFieldObj(o, "kind") orelse continue;
        if (!validCommandId(id)) continue;
        const session_id = util.strFieldObj(o, "session_id");
        if (session_id) |sid| if (!events.validName(sid)) continue;
        var aw: Io.Writer.Allocating = .init(arena);
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        try s.write(o.get("body") orelse Value{ .object = .empty });
        try out.append(arena, .{ .id = id, .kind = kind, .session_id = session_id, .body = aw.writer.buffered() });
    }
    return out.items;
}

fn runCommand(self: *State, arena: Allocator, cmd: Command) void {
    const io = self.st.io;
    if (std.mem.eql(u8, cmd.kind, "create")) {
        const made = serve_create.createFromBody(&self.st, arena, cmd.body) catch |err| {
            serve.serveLog(io, "remote-control: create failed ({t})", .{err});
            return sendResult(self, arena, cmd.id, null, 500, "{\"error\":\"failed to create session\"}");
        };
        return sendResult(self, arena, cmd.id, null, @intFromEnum(made.status), made.body);
    }
    const sid = cmd.session_id orelse return sendResult(self, arena, cmd.id, null, 400, "{\"error\":\"session_id required\"}");
    if (std.mem.eql(u8, cmd.kind, "close")) return closeSession(self, arena, cmd.id, sid);
    if (!std.mem.eql(u8, cmd.kind, "request")) return sendResult(self, arena, cmd.id, sid, 400, "{\"error\":\"unknown command kind\"}");

    const rtype = events.stringField(cmd.body, "type") orelse "";
    const from: ?u64 = blk: {
        const v = std.json.parseFromSliceLeaky(Value, arena, cmd.body, .{ .allocate = .alloc_always }) catch break :blk null;
        if (v != .object) break :blk null;
        const f = v.object.get("resume_from") orelse v.object.get("from") orelse break :blk null;
        break :blk if (f == .integer and f.integer > 0) @as(u64, @intCast(f.integer)) else null;
    };
    // A pure reconnect replays the tape and sends nothing to the child — and
    // works for a session this supervisor never ran, straight off the disk.
    if (std.mem.eql(u8, rtype, "reattach")) {
        var up = Uploader.init(self, arena, cmd.id, sid);
        replayTape(self, arena, &up, sid, from orelse 1);
        return up.finish(200, "{\"ok\":true,\"type\":\"reattach\"}");
    }
    self.st.mutex.lockUncancelable(io);
    const found = self.st.find(sid);
    self.st.mutex.unlock(io);
    const s = found orelse return sendResult(self, arena, cmd.id, sid, 404, "{\"error\":\"no such session\"}");
    if (std.mem.eql(u8, rtype, "answer")) {
        s.answer_mu.lockUncancelable(io);
        defer s.answer_mu.unlock(io);
        if (!s.awaiting_answer) return sendResult(self, arena, cmd.id, sid, 409, "{\"error\":\"no active ask_user prompt\"}");
        serve.writeChildLine(io, s, cmd.body) catch return sendResult(self, arena, cmd.id, sid, 502, "{\"error\":\"session process is gone\"}");
        s.awaiting_answer = false;
        s.answer_call_id_len = 0;
        return sendResult(self, arena, cmd.id, sid, 200, "{\"ok\":true,\"type\":\"answer\"}");
    }
    if (std.mem.eql(u8, rtype, "cancel")) {
        if (!s.in_flight.load(.acquire)) return sendResult(self, arena, cmd.id, sid, 409, "{\"error\":\"no request is in flight\"}");
        serve.writeChildLine(io, s, cmd.body) catch return sendResult(self, arena, cmd.id, sid, 502, "{\"error\":\"session process is gone\"}");
        return sendResult(self, arena, cmd.id, sid, 200, "{\"ok\":true,\"type\":\"cancel\"}");
    }
    drain(self, arena, s, cmd.id, cmd.body, from);
}

/// Mirror of serveMessage: one request in, its events out until the terminal
/// one — persisted to the tape BEFORE they go upstream, so a relay hiccup
/// never costs the run its history.
fn drain(self: *State, arena: Allocator, s: *ServeSession, cmd_id: []const u8, line: []const u8, from: ?u64) void {
    const io = self.st.io;
    var dead = false;
    var up = Uploader.init(self, arena, cmd_id, s.name);
    {
        s.busy.lockUncancelable(io); // serialize requests per session
        defer s.busy.unlock(io);
        s.in_flight.store(true, .release);
        defer s.in_flight.store(false, .release);

        serve.writeChildLine(io, s, line) catch return up.finish(502, "{\"error\":\"session process is gone\"}");
        if (from) |n| replayTape(self, arena, &up, s.name, n);
        while (true) {
            const ev_line = s.rdr.interface.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => break abort(s, &up, "event line exceeded the 1 MiB serve cap — session closed", &dead),
                error.ReadFailed => break abort(s, &up, "session process exited mid-request", &dead),
            } orelse break abort(s, &up, "session process exited mid-request", &dead);
            const trimmed = std.mem.trim(u8, ev_line, " \t\r");
            if (trimmed.len == 0) continue;
            serve.serveUpdateAnswerState(io, s, trimmed);
            s.log.append(trimmed);
            if (events.seqOf(trimmed)) |q| s.last_seq = @max(s.last_seq, q);
            up.push(trimmed);
            if (events.terminalEvent(trimmed)) {
                serve.serveClearAnswerState(io, s);
                break;
            }
        }
    }
    up.finish(200, "{\"ok\":true}");
    if (dead) serve.serveDrop(&self.st, s); // after the defers above are done with `s`
}

/// The child died mid-request: a terminal error with the next seq goes on the
/// tape and upstream, so a viewer sees the failure, not a hole.
fn abort(s: *ServeSession, up: *Uploader, message: []const u8, dead: *bool) void {
    s.last_seq += 1;
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{{\"seq\":{d},\"type\":\"error\",\"message\":\"{s}\"}}", .{ s.last_seq, message }) catch
        "{\"type\":\"error\",\"message\":\"session process exited mid-request\"}";
    s.log.append(line);
    up.push(line);
    dead.* = true;
}

/// Every complete tape line with seq >= from, in order.
fn replayTape(self: *State, arena: Allocator, up: *Uploader, sid: []const u8, from: u64) void {
    const path = events.logPath(arena, sid) catch return;
    const data = Io.Dir.cwd().readFileAlloc(self.st.io, path, arena, .limited(events.max_log_bytes)) catch return;
    var rest = data;
    while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        const line = std.mem.trim(u8, rest[0..nl], " \t\r");
        rest = rest[nl + 1 ..];
        if (line.len == 0) continue;
        const seq = events.seqOf(line) orelse continue;
        if (seq >= from) up.push(line);
    }
}

/// Graceful close, as serveDelete: wait out an in-flight request, EOF the
/// child's stdin, reap in the background. Tape and session file stay.
fn closeSession(self: *State, arena: Allocator, cmd_id: []const u8, sid: []const u8) void {
    const io = self.st.io;
    self.st.mutex.lockUncancelable(io);
    const found = self.st.find(sid);
    if (found) |sess| {
        for (self.st.sessions.items, 0..) |p, i| {
            if (p == sess) {
                _ = self.st.sessions.swapRemove(i);
                break;
            }
        }
    }
    self.st.mutex.unlock(io);
    const sess = found orelse return sendResult(self, arena, cmd_id, sid, 404, "{\"error\":\"no such session\"}");
    sess.busy.lockUncancelable(io);
    sess.busy.unlock(io);
    if (sess.child.stdin) |f| {
        f.close(io);
        sess.child.stdin = null;
    }
    self.st.group.concurrent(io, serve.serveReap, .{ &self.st, sess }) catch serve.serveReap(&self.st, sess);
    serve.serveLog(io, "remote-control: session {s} closed", .{sid});
    sendResult(self, arena, cmd_id, sid, 200, "{\"ok\":true}");
}

fn sendResult(self: *State, arena: Allocator, cmd_id: []const u8, sid: ?[]const u8, status: u16, body: []const u8) void {
    var up = Uploader.init(self, arena, cmd_id, sid orelse "");
    up.finish(status, body);
}

/// Event types a viewer must see NOW rather than at the end of a window.
pub fn urgent(line: []const u8) bool {
    const t = events.stringField(line, "type") orelse return false;
    return std.mem.eql(u8, t, "tool_call") or std.mem.eql(u8, t, "ask_user") or events.terminalEvent(line);
}

/// A line too big for the relay window becomes an envelope-only stub. Only the
/// upload shrinks: the tape and a later `reattach` still carry the full line.
pub fn uploadLine(buf: []u8, line: []const u8) []const u8 {
    if (line.len <= upload_line_cap) return line;
    const seq = events.seqOf(line) orelse 0;
    const t = events.stringField(line, "type") orelse "event";
    return std.fmt.bufPrint(buf, "{{\"seq\":{d},\"type\":\"{s}\",\"truncated\":true,\"bytes\":{d}}}", .{ seq, t[0..@min(t.len, 64)], line.len }) catch line[0..0];
}

/// Batches event lines for one command into `POST …/events` bodies:
/// `{"command_id","session_id","events":[<line>,…][,"result":{status,body}]}`.
/// Lines are JSON objects already, so they ride as values, never re-escaped.
const Uploader = struct {
    self: *State,
    arena: Allocator,
    cmd_id: []const u8,
    sid: []const u8,
    aw: Io.Writer.Allocating,
    count: usize = 0,
    last_flush_ms: i64,

    fn init(self: *State, arena: Allocator, cmd_id: []const u8, sid: []const u8) Uploader {
        return .{ .self = self, .arena = arena, .cmd_id = cmd_id, .sid = sid, .aw = .init(arena), .last_flush_ms = util.unixMs(self.st.io) };
    }

    fn open(u: *Uploader) void {
        u.aw.writer.print("{{\"command_id\":\"{s}\",\"session_id\":\"{s}\",\"events\":[", .{ u.cmd_id, u.sid }) catch {};
    }

    fn push(u: *Uploader, line: []const u8) void {
        if (u.count == 0) u.open();
        if (u.count > 0) u.aw.writer.writeByte(',') catch {};
        var stub: [256]u8 = undefined;
        u.aw.writer.writeAll(uploadLine(&stub, line)) catch {};
        u.count += 1;
        const now = util.unixMs(u.self.st.io);
        if (u.aw.writer.buffered().len >= flush_bytes or now - u.last_flush_ms >= flush_window_ms or urgent(line)) u.flush(null);
    }

    /// One POST. A failed upload is logged and dropped: the tape is complete
    /// and the viewer's next `reattach` fills the hole from it.
    fn flush(u: *Uploader, result: ?struct { status: u16, body: []const u8 }) void {
        if (u.count == 0 and result == null) return;
        if (u.count == 0) u.open();
        u.aw.writer.writeByte(']') catch {};
        if (result) |r| u.aw.writer.print(",\"result\":{{\"status\":{d},\"body\":{s}}}", .{ r.status, r.body }) catch {};
        u.aw.writer.writeByte('}') catch {};
        const path = std.fmt.allocPrint(u.arena, "/v1/remote/agents/{s}/events", .{&u.self.agent_id}) catch return;
        var attempt: usize = 0;
        while (attempt < 3) : (attempt += 1) {
            if (post(u.self, u.arena, path, u.aw.writer.buffered())) |r| {
                if (r.code >= 200 and r.code < 300) break;
                serve.serveLog(u.self.st.io, "remote-control: upload HTTP {d}: {s}", .{ r.code, errorMessage(u.arena, r.body) });
                if (r.code < 500) break;
            } else |err| serve.serveLog(u.self.st.io, "remote-control: upload failed ({t})", .{err});
            u.self.st.io.sleep(.fromMilliseconds(250 * @as(i64, @intCast(attempt + 1))), .awake) catch break;
        }
        u.aw = .init(u.arena);
        u.count = 0;
        u.last_flush_ms = util.unixMs(u.self.st.io);
    }

    fn finish(u: *Uploader, status: u16, body: []const u8) void {
        u.flush(.{ .status = status, .body = body });
    }
};

test "parseDeviceId accepts exactly 16 lowercase hex, nothing else" {
    try std.testing.expectEqualStrings("00ff00ff00ff00ff", &(parseDeviceId("{\"device_id\":\"00ff00ff00ff00ff\"}\n").?));
    try std.testing.expect(parseDeviceId("{\"device_id\":\"00FF00FF00FF00FF\"}") == null);
    try std.testing.expect(parseDeviceId("{\"device_id\":\"short\"}") == null);
    try std.testing.expect(parseDeviceId("{}") == null);
}

test "parseCommands: ids validated, session names validated, bodies re-lined" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cmds = try parseCommands(arena,
        \\{"commands":[
        \\ {"id":"c1","kind":"create","body":{"model":"m","yolo":true}},
        \\ {"id":"c2","kind":"request","session_id":"nightly","body":{"type":"user","text":"hi"}},
        \\ {"id":"bad id","kind":"close","session_id":"x","body":{}},
        \\ {"id":"c3","kind":"close","session_id":"../etc","body":{}},
        \\ {"id":"c4","kind":"close","session_id":"ok"}
        \\]}
    );
    try std.testing.expectEqual(@as(usize, 3), cmds.len);
    try std.testing.expectEqualStrings("c1", cmds[0].id);
    try std.testing.expect(cmds[0].session_id == null);
    try std.testing.expectEqualStrings("{\"model\":\"m\",\"yolo\":true}", cmds[0].body);
    try std.testing.expectEqualStrings("nightly", cmds[1].session_id.?);
    try std.testing.expectEqualStrings("{\"type\":\"user\",\"text\":\"hi\"}", cmds[1].body);
    try std.testing.expectEqualStrings("{}", cmds[2].body); // a body-less command still carries one line
    try std.testing.expectEqual(@as(usize, 0), (try parseCommands(arena, "{\"commands\":[]}")).len);
    try std.testing.expectError(error.BadReply, parseCommands(arena, "[]"));
}

test "urgent: tool calls, prompts and terminals flush immediately; deltas batch" {
    try std.testing.expect(urgent("{\"seq\":1,\"type\":\"tool_call\",\"name\":\"bash\"}"));
    try std.testing.expect(urgent("{\"seq\":2,\"type\":\"ask_user\",\"call_id\":\"q\"}"));
    try std.testing.expect(urgent("{\"seq\":3,\"type\":\"turn\"}"));
    try std.testing.expect(!urgent("{\"seq\":4,\"type\":\"text\",\"text\":\"turn\"}"));
    try std.testing.expect(!urgent("{\"seq\":5,\"type\":\"reasoning\",\"text\":\"…\"}"));
}

test "uploadLine: small lines pass through, oversized ones become an envelope stub" {
    var buf: [256]u8 = undefined;
    const small = "{\"seq\":7,\"type\":\"text\",\"text\":\"hi\"}";
    try std.testing.expectEqualStrings(small, uploadLine(&buf, small));
    const big = try std.testing.allocator.alloc(u8, upload_line_cap + 100);
    defer std.testing.allocator.free(big);
    const head = "{\"seq\":9,\"type\":\"tool_result\",\"output\":\"";
    @memset(big, 'x');
    @memcpy(big[0..head.len], head);
    big[big.len - 2] = '"';
    big[big.len - 1] = '}';
    const stub = uploadLine(&buf, big);
    try std.testing.expect(std.mem.startsWith(u8, stub, "{\"seq\":9,\"type\":\"tool_result\",\"truncated\":true,\"bytes\":"));
    try std.testing.expect(events.seqOf(stub).? == 9);
}

test "validCommandId keeps relay ids inside a JSON string" {
    try std.testing.expect(validCommandId("3f2a9c1e-7b4d-4e6f-9a0b-1c2d3e4f5a6b"));
    try std.testing.expect(!validCommandId(""));
    try std.testing.expect(!validCommandId("has\"quote"));
    try std.testing.expect(!validCommandId("has space"));
}
