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
//! drain here mirrors serveMessage with the socket replaced by the coalesced
//! uploads in remote_upload.zig. The relay keeps a bounded recent window; the
//! tape here is complete, so a viewer whose cursor fell behind asks for
//! `reattach` and gets a replay.
//!
//! Trust: the relay only carries what an account key with the `remote` scope
//! sent, and this process is the last word — a viewer cannot make it run an
//! unattended (`yolo`) session unless it was started with --yolo itself.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const root = @import("main.zig");
const serve = @import("serve.zig");
const serve_create = @import("serve_create.zig");
const events = @import("serve_events.zig");
const upload = @import("remote_upload.zig");
const util = @import("util.zig");

const ServeState = serve.ServeState;
const ServeSession = serve.ServeSession;
const harness_version = root.harness_version;

pub const Config = struct {
    base: []const u8, // gateway base URL (GRAFF_REMOTE_BASE overrides for a local relay)
    key: []const u8, // the account's cg_sk_ key
    home: []const u8,
    name: ?[]const u8, // display name for this machine; default hostname
    hostname_env: ?[]const u8, // COMPUTERNAME / HOSTNAME: the only source on Windows
    serve: serve.ServeConfig,
};

/// Where this machine's stable relay identity lives (16 hex chars).
pub const device_file = ".graff/remote-device.json";
/// Longest one poll is held server-side before an empty answer.
const poll_wait_ms: u64 = 25_000;
const backoff_min_ms: i64 = 1_000;
const backoff_max_ms: i64 = 30_000;

const State = struct {
    st: ServeState,
    cfg: Config,
    client: std.http.Client,
    agent_id: [16]u8 = undefined,
    hostname_buf: [256]u8 = undefined,
    hostname: []const u8 = "",
};

/// The kernel's idea of this machine's name where std has one (libc /
/// Linux); Windows has no std.posix.gethostname, so the environment's
/// COMPUTERNAME stands in there (the comptime branch keeps it unanalyzed).
fn hostName(buf: *[256]u8, from_env: ?[]const u8) []const u8 {
    if (builtin.os.tag != .windows) {
        var raw: [std.posix.HOST_NAME_MAX]u8 = undefined;
        if (std.posix.gethostname(&raw)) |h| {
            const n = @min(h.len, buf.len);
            @memcpy(buf[0..n], h[0..n]);
            return buf[0..n];
        } else |_| {}
    }
    return from_env orelse "unknown";
}

fn link(self: *State, client: *std.http.Client) upload.Link {
    return .{ .io = self.st.io, .base = self.cfg.base, .key = self.cfg.key, .agent_id = self.agent_id, .client = client };
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
    self.hostname = hostName(&self.hostname_buf, cfg.hostname_env);
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
            serve.serveLog(io, "graff remote-control · {s} ({s}) · device {s} · relay {s} · unattended sessions: {s} · sessions are `{s} --json` children · Ctrl-C disconnects", .{
                label, self.hostname, &self.agent_id, cfg.base, if (cfg.serve.yolo) "allowed (--yolo)" else "refused (start with --yolo to allow)", exe,
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

/// The key was refused: revoked, or missing the `remote` scope. Nothing this
/// process can do fixes that, and retrying forever would just hammer the
/// gateway with a dead credential — exit and say what to run.
fn refused(arena: Allocator, code: u16, body: []const u8) noreturn {
    std.process.fatal("remote-control: gateway refused the key (HTTP {d}: {s}) — run `graff login` again (keys need the `remote` scope)", .{ code, upload.errorMessage(arena, body) });
}

fn register(self: *State, arena: Allocator, label: []const u8) !void {
    // AT_FDCWD has no path of its own; resolve "." through it instead.
    const cwd: []const u8 = Io.Dir.cwd().realPathFileAlloc(self.st.io, ".", arena) catch "";
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(.{ .hostname = self.hostname, .name = label, .cwd = cwd, .version = harness_version });
    const path = try std.fmt.allocPrint(arena, "/v1/remote/agents/{s}/register", .{&self.agent_id});
    const r = try upload.post(link(self, &self.client), arena, path, aw.writer.buffered());
    if (r.code == 401 or r.code == 403) refused(arena, r.code, r.body);
    if (r.code < 200 or r.code >= 300) {
        serve.serveLog(self.st.io, "remote-control: HTTP {d}: {s}", .{ r.code, upload.errorMessage(arena, r.body) });
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
    const r = try upload.post(link(self, &self.client), arena, path, payload);
    if (r.code == 401 or r.code == 403) refused(arena, r.code, r.body);
    if (r.code == 404) return error.UnknownDevice;
    if (r.code < 200 or r.code >= 300) {
        serve.serveLog(self.st.io, "remote-control: HTTP {d}: {s}", .{ r.code, upload.errorMessage(arena, r.body) });
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

/// Does a create request ask for an unattended session? Only a real JSON
/// `true` counts; anything unparseable reads as "no".
pub fn yoloRequested(arena: Allocator, body: []const u8) bool {
    const v = std.json.parseFromSliceLeaky(Value, arena, body, .{ .allocate = .alloc_always }) catch return false;
    if (v != .object) return false;
    const y = v.object.get("yolo") orelse return false;
    return y == .bool and y.bool;
}

fn runCommand(self: *State, arena: Allocator, cmd: Command) void {
    const io = self.st.io;
    const client = &self.client;
    if (std.mem.eql(u8, cmd.kind, "create")) {
        // The machine's own flag is the ceiling: a viewer cannot escalate a
        // session past what whoever started this process allowed.
        if (yoloRequested(arena, cmd.body) and !self.cfg.serve.yolo)
            return sendResult(self, client, arena, cmd.id, null, 403, "{\"error\":\"this machine refuses unattended sessions — start `graff remote-control --yolo` there to allow them\"}");
        const made = serve_create.createFromBody(&self.st, arena, cmd.body) catch |err| {
            serve.serveLog(io, "remote-control: create failed ({t})", .{err});
            return sendResult(self, client, arena, cmd.id, null, 500, "{\"error\":\"failed to create session\"}");
        };
        return sendResult(self, client, arena, cmd.id, null, @intFromEnum(made.status), made.body);
    }
    const sid = cmd.session_id orelse return sendResult(self, client, arena, cmd.id, null, 400, "{\"error\":\"session_id required\"}");
    if (std.mem.eql(u8, cmd.kind, "close")) return spawn(self, .close, null, cmd.id, sid, "", null);
    if (!std.mem.eql(u8, cmd.kind, "request")) return sendResult(self, client, arena, cmd.id, sid, 400, "{\"error\":\"unknown command kind\"}");

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
        var up = upload.Uploader.init(link(self, client), arena, cmd.id, sid);
        replayTape(self, arena, &up, sid, from orelse 1);
        return up.finish(200, "{\"ok\":true,\"type\":\"reattach\"}");
    }
    self.st.mutex.lockUncancelable(io);
    const found = self.st.find(sid);
    self.st.mutex.unlock(io);
    const s = found orelse return sendResult(self, client, arena, cmd.id, sid, 404, "{\"error\":\"no such session\"}");
    // answer/cancel bypass the per-session busy lock exactly as serve's do:
    // they are how a viewer reaches a turn that is running right now.
    if (std.mem.eql(u8, rtype, "answer")) {
        s.answer_mu.lockUncancelable(io);
        defer s.answer_mu.unlock(io);
        if (!s.awaiting_answer) return sendResult(self, client, arena, cmd.id, sid, 409, "{\"error\":\"no active ask_user prompt\"}");
        serve.writeChildLine(io, s, cmd.body) catch return sendResult(self, client, arena, cmd.id, sid, 502, "{\"error\":\"session process is gone\"}");
        s.awaiting_answer = false;
        s.answer_call_id_len = 0;
        return sendResult(self, client, arena, cmd.id, sid, 200, "{\"ok\":true,\"type\":\"answer\"}");
    }
    if (std.mem.eql(u8, rtype, "cancel")) {
        if (!s.in_flight.load(.acquire)) return sendResult(self, client, arena, cmd.id, sid, 409, "{\"error\":\"no request is in flight\"}");
        serve.writeChildLine(io, s, cmd.body) catch return sendResult(self, client, arena, cmd.id, sid, 502, "{\"error\":\"session process is gone\"}");
        return sendResult(self, client, arena, cmd.id, sid, 200, "{\"ok\":true,\"type\":\"cancel\"}");
    }
    spawn(self, .drain, s, cmd.id, sid, cmd.body, from);
}

/// A streamed request or a close runs as its own task: both can block on a
/// turn for minutes, and the poll loop must keep its heartbeat and keep
/// delivering `cancel` / `answer` meanwhile — serve gets the same property
/// from one connection per request. The job owns gpa copies of everything
/// the poll arena would otherwise free under it.
const Job = struct {
    self: *State,
    kind: enum { drain, close },
    s: ?*ServeSession,
    cmd_id: []const u8 = "",
    sid: []const u8 = "",
    line: []const u8 = "",
    from: ?u64,
};

/// An OOM here drops the command: the relay reports the device did not answer.
fn spawn(self: *State, kind: @FieldType(Job, "kind"), s: ?*ServeSession, cmd_id: []const u8, sid: []const u8, line: []const u8, from: ?u64) void {
    const gpa = self.st.gpa;
    const job = gpa.create(Job) catch return;
    job.* = .{ .self = self, .kind = kind, .s = s, .from = from };
    job.cmd_id = gpa.dupe(u8, cmd_id) catch return freeJob(job);
    job.sid = gpa.dupe(u8, sid) catch return freeJob(job);
    job.line = gpa.dupe(u8, line) catch return freeJob(job);
    self.st.group.concurrent(self.st.io, runJob, .{job}) catch runJob(job);
}

fn freeJob(job: *Job) void {
    const gpa = job.self.st.gpa;
    gpa.free(job.cmd_id);
    gpa.free(job.sid);
    gpa.free(job.line);
    gpa.destroy(job);
}

fn runJob(job: *Job) void {
    const self = job.self;
    const gpa = self.st.gpa;
    defer freeJob(job);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var client: std.http.Client = .{ .allocator = gpa, .io = self.st.io };
    defer client.deinit();
    switch (job.kind) {
        .drain => drain(self, &client, arena, job.s.?, job.cmd_id, job.line, job.from),
        .close => closeSession(self, &client, arena, job.cmd_id, job.sid),
    }
}

/// Mirror of serveMessage: one request in, its events out until the terminal
/// one — persisted to the tape BEFORE they go upstream, so a relay hiccup
/// never costs the run its history.
fn drain(self: *State, client: *std.http.Client, arena: Allocator, s: *ServeSession, cmd_id: []const u8, line: []const u8, from: ?u64) void {
    const io = self.st.io;
    var dead = false;
    // Our own copy of the name: `s` may be closed and freed by another task
    // the moment busy is released below, and finish() still names it.
    const sid = arena.dupe(u8, s.name) catch s.name;
    var up = upload.Uploader.init(link(self, client), arena, cmd_id, sid);
    {
        s.busy.lockUncancelable(io); // serialize requests per session
        defer s.busy.unlock(io);
        s.in_flight.store(true, .release);
        defer s.in_flight.store(false, .release);

        serve.writeChildLine(io, s, line) catch return up.finish(502, "{\"error\":\"session process is gone\"}");
        if (from) |n| replayTape(self, arena, &up, sid, n);
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
fn abort(s: *ServeSession, up: *upload.Uploader, message: []const u8, dead: *bool) void {
    s.last_seq += 1;
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{{\"seq\":{d},\"type\":\"error\",\"message\":\"{s}\"}}", .{ s.last_seq, message }) catch
        "{\"type\":\"error\",\"message\":\"session process exited mid-request\"}";
    s.log.append(line);
    up.push(line);
    dead.* = true;
}

/// Every complete tape line with seq >= from, in order.
fn replayTape(self: *State, arena: Allocator, up: *upload.Uploader, sid: []const u8, from: u64) void {
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
fn closeSession(self: *State, client: *std.http.Client, arena: Allocator, cmd_id: []const u8, sid: []const u8) void {
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
    const sess = found orelse return sendResult(self, client, arena, cmd_id, sid, 404, "{\"error\":\"no such session\"}");
    sess.busy.lockUncancelable(io);
    sess.busy.unlock(io);
    if (sess.child.stdin) |f| {
        f.close(io);
        sess.child.stdin = null;
    }
    self.st.group.concurrent(io, serve.serveReap, .{ &self.st, sess }) catch serve.serveReap(&self.st, sess);
    serve.serveLog(io, "remote-control: session {s} closed", .{sid});
    sendResult(self, client, arena, cmd_id, sid, 200, "{\"ok\":true}");
}

fn sendResult(self: *State, client: *std.http.Client, arena: Allocator, cmd_id: []const u8, sid: ?[]const u8, status: u16, body: []const u8) void {
    var up = upload.Uploader.init(link(self, client), arena, cmd_id, sid orelse "");
    up.finish(status, body);
}

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

test "yoloRequested: only a JSON true asks for an unattended session" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(yoloRequested(arena, "{\"yolo\":true}"));
    try std.testing.expect(!yoloRequested(arena, "{\"yolo\":false}"));
    try std.testing.expect(!yoloRequested(arena, "{\"yolo\":\"true\"}"));
    try std.testing.expect(!yoloRequested(arena, "{\"model\":\"m\"}"));
    try std.testing.expect(!yoloRequested(arena, "not json"));
}

test "validCommandId keeps relay ids inside a JSON string" {
    try std.testing.expect(validCommandId("3f2a9c1e-7b4d-4e6f-9a0b-1c2d3e4f5a6b"));
    try std.testing.expect(!validCommandId(""));
    try std.testing.expect(!validCommandId("has\"quote"));
    try std.testing.expect(!validCommandId("has space"));
}
