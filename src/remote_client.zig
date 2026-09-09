//! `graff remote`: the viewer half of remote control (#722). From any machine
//! where the same `graff login` is valid: list the machines running
//! `graff remote-control` and their sessions, create one, send it a turn and
//! watch the events stream back, tail a live one, answer a prompt, cancel,
//! close. The wire is the gateway's `/v1/remote/*` API; events are the same
//! NDJSON lines serve streams, fetched from a cursor in long-poll batches.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const ansi = @import("ansi.zig");
const style = &ansi.style;
const root = @import("main.zig");
const util = @import("util.zig");
const events = @import("serve_events.zig");
const strFieldObj = util.strFieldObj;
const intFieldObj = util.intFieldObj;
const harness_version = root.harness_version;

pub const Options = struct { model: ?[]const u8 = null, yolo: bool = false };

/// How long one events long-poll is held before an empty answer.
const tail_wait_ms: u64 = 25_000;

const Client = struct {
    io: Io,
    gpa: Allocator,
    base: []const u8,
    key: []const u8,
    http: std.http.Client,

    const Reply = struct { code: u16, body: []const u8 };

    fn fetch(c: *Client, arena: Allocator, method: std.http.Method, path: []const u8, payload: ?[]const u8) !Reply {
        const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ c.base, path });
        var aw: Io.Writer.Allocating = .init(arena);
        const default_payload: ?[]const u8 = if (method == .POST) "{}" else null;
        const res = try c.http.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload orelse default_payload,
            .response_writer = &aw.writer,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = try std.fmt.allocPrint(arena, "Bearer {s}", .{c.key}) },
                .user_agent = .{ .override = "simple-harness/" ++ harness_version },
            },
        });
        return .{ .code = @intFromEnum(res.status), .body = aw.writer.buffered() };
    }

    /// Non-2xx is fatal with the gateway's message: every subcommand here is
    /// one user action, and a half-answer is worse than none.
    fn json(c: *Client, arena: Allocator, method: std.http.Method, path: []const u8, payload: ?[]const u8) !Value {
        const r = try c.fetch(arena, method, path, payload);
        if (r.code < 200 or r.code >= 300) std.process.fatal("remote: HTTP {d}: {s}", .{ r.code, errorMessage(arena, r.body) });
        return std.json.parseFromSliceLeaky(Value, arena, r.body, .{ .allocate = .alloc_always }) catch
            std.process.fatal("remote: gateway sent something that is not JSON", .{});
    }
};

pub fn errorMessage(arena: Allocator, body: []const u8) []const u8 {
    if (std.json.parseFromSliceLeaky(Value, arena, body, .{ .allocate = .alloc_always })) |v| {
        if (v == .object) {
            if (v.object.get("error")) |e| {
                if (e == .object) if (strFieldObj(e.object, "message")) |m| return m;
                if (e == .string) return e.string;
            }
        }
    } else |_| {}
    return body[0..@min(body.len, 200)];
}

const usage =
    \\usage: graff remote                          sessions on every machine running `graff remote-control`
    \\       graff remote agents                   the machines themselves
    \\       graff remote new [session] [agent]    create (or resume) a session on a machine; --model/--yolo apply
    \\       graff remote send <session> <text…>   one turn, events streamed back until it ends
    \\       graff remote answer <session> <text…> answer the session's ask_user prompt
    \\       graff remote tail <session> [from]    watch a session's events from a cursor (default: the recent window)
    \\       graff remote cancel <session>         cancel the in-flight turn
    \\       graff remote close <session>          end the session process (its history stays on that machine)
;

pub fn command(io: Io, gpa: Allocator, arena: Allocator, base: []const u8, key: []const u8, args: []const []const u8, opts: Options) !void {
    var obuf: [4096]u8 = undefined;
    var ow = Io.File.stdout().writer(io, &obuf);
    const out = &ow.interface;
    var c: Client = .{ .io = io, .gpa = gpa, .base = base, .key = key, .http = .{ .allocator = gpa, .io = io } };
    defer c.http.deinit();

    const sub = if (args.len == 0) "sessions" else args[0];
    const rest = if (args.len == 0) args else args[1..];
    if (std.mem.eql(u8, sub, "sessions")) {
        try listSessions(&c, arena, out);
    } else if (std.mem.eql(u8, sub, "agents")) {
        try listAgents(&c, arena, out);
    } else if (std.mem.eql(u8, sub, "new")) {
        try createSession(&c, arena, out, rest, opts);
    } else if (std.mem.eql(u8, sub, "send") or std.mem.eql(u8, sub, "answer")) {
        if (rest.len < 2) std.process.fatal("{s}", .{usage});
        const sid = sessionArg(rest[0]);
        const text = try std.mem.join(arena, " ", rest[1..]);
        const from = try request(&c, arena, sid, if (std.mem.eql(u8, sub, "send")) "user" else "answer", text);
        try tail(&c, arena, out, sid, from, true);
    } else if (std.mem.eql(u8, sub, "tail")) {
        if (rest.len < 1) std.process.fatal("{s}", .{usage});
        const sid = sessionArg(rest[0]);
        const from: u64 = if (rest.len > 1) std.fmt.parseInt(u64, rest[1], 10) catch std.process.fatal("remote tail: from must be a number", .{}) else 1;
        try tail(&c, arena, out, sid, from, false);
    } else if (std.mem.eql(u8, sub, "cancel")) {
        if (rest.len < 1) std.process.fatal("{s}", .{usage});
        _ = try request(&c, arena, sessionArg(rest[0]), "cancel", null);
        try out.print("{s}✓{s} cancel delivered — the turn ends with an error event; `graff remote tail {s}` shows it\n", .{ style.green, style.reset, rest[0] });
    } else if (std.mem.eql(u8, sub, "close")) {
        if (rest.len < 1) std.process.fatal("{s}", .{usage});
        const sid = sessionArg(rest[0]);
        const path = try std.fmt.allocPrint(arena, "/v1/remote/sessions/{s}", .{sid});
        _ = try c.json(arena, .DELETE, path, null);
        try out.print("{s}✓{s} {s} closed (history stays on its machine; `graff remote new {s}` resumes it)\n", .{ style.green, style.reset, sid, sid });
    } else {
        std.process.fatal("{s}", .{usage});
    }
    try out.flush();
}

/// `reply[key]` as a slice of values; missing or not an array reads empty.
fn items(v: Value, key: []const u8) []const Value {
    if (v != .object) return &.{};
    const l = v.object.get(key) orelse return &.{};
    return if (l == .array) l.array.items else &.{};
}

fn sessionArg(s: []const u8) []const u8 {
    if (!events.validName(s)) std.process.fatal("remote: '{s}' is not a session id", .{s});
    return s;
}

fn listAgents(c: *Client, arena: Allocator, out: *Io.Writer) !void {
    const list = items(try c.json(arena, .GET, "/v1/remote/agents", null), "agents");
    if (list.len == 0) {
        try out.writeAll("no machines — run `graff remote-control` on one (same `graff login`)\n");
        return;
    }
    try out.print("{s}{s:<18}  {s:<8}  {s:<20}  {s:<8}  {s}{s}\n", .{ style.dim, "agent", "online", "name", "sessions", "cwd", style.reset });
    for (list) |item| {
        if (item != .object) continue;
        const o = item.object;
        const online = if (o.get("online")) |b| (b == .bool and b.bool) else false;
        const n = if (o.get("sessions")) |s| (if (s == .array) s.array.items.len else 0) else 0;
        try out.print("{s:<18}  {s}{s:<8}{s}  {s:<20}  {d:<8}  {s}\n", .{
            strFieldObj(o, "agent_id") orelse "?",
            if (online) style.green else style.dim,
            if (online) "yes" else "no",
            style.reset,
            strFieldObj(o, "name") orelse strFieldObj(o, "hostname") orelse "?",
            n,
            strFieldObj(o, "cwd") orelse "",
        });
    }
}

fn listSessions(c: *Client, arena: Allocator, out: *Io.Writer) !void {
    const list = items(try c.json(arena, .GET, "/v1/remote/sessions", null), "sessions");
    if (list.len == 0) {
        try out.writeAll("no remote sessions — `graff remote new` starts one on a machine running `graff remote-control`\n");
        return;
    }
    try out.print("{s}{s:<18}  {s:<6}  {s:<18}  {s:<8}  {s}{s}\n", .{ style.dim, "session", "state", "machine", "last_seq", "cwd", style.reset });
    for (list) |item| {
        if (item != .object) continue;
        const o = item.object;
        const online = if (o.get("online")) |b| (b == .bool and b.bool) else false;
        const state = if (!online) "offline" else strFieldObj(o, "state") orelse "?";
        try out.print("{s:<18}  {s}{s:<6}{s}  {s:<18}  {d:<8}  {s}\n", .{
            strFieldObj(o, "session_id") orelse "?",
            if (std.mem.eql(u8, state, "busy")) style.green else style.dim,
            state,
            style.reset,
            strFieldObj(o, "name") orelse strFieldObj(o, "hostname") orelse "?",
            @as(u64, @intCast(@max(intFieldObj(o, "last_seq", 0), 0))),
            strFieldObj(o, "cwd") orelse "",
        });
    }
}

/// `new [session] [agent]`: with one machine online the agent is implied.
fn createSession(c: *Client, arena: Allocator, out: *Io.Writer, rest: []const []const u8, opts: Options) !void {
    const agent = if (rest.len > 1) rest[1] else try onlyOnlineAgent(c, arena);
    var obj: std.json.ObjectMap = .empty;
    if (rest.len > 0) try obj.put(arena, "session", .{ .string = sessionArg(rest[0]) });
    if (opts.model) |m| try obj.put(arena, "model", .{ .string = m });
    if (opts.yolo) try obj.put(arena, "yolo", .{ .bool = true });
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(Value{ .object = obj });
    const path = try std.fmt.allocPrint(arena, "/v1/remote/agents/{s}/sessions", .{agent});
    const v = try c.json(arena, .POST, path, aw.writer.buffered());
    if (v != .object) std.process.fatal("remote new: unexpected reply", .{});
    const sid = strFieldObj(v.object, "session_id") orelse "?";
    const resumed = if (v.object.get("resumed")) |b| (b == .bool and b.bool) else false;
    try out.print("{s}✓{s} session {s} {s} on {s} (last_seq {d})\n  graff remote send {s} <text>\n", .{
        style.green, style.reset, sid, if (resumed) "resumed" else "created", agent, @as(u64, @intCast(@max(intFieldObj(v.object, "last_seq", 0), 0))), sid,
    });
}

fn onlyOnlineAgent(c: *Client, arena: Allocator) ![]const u8 {
    var found: ?[]const u8 = null;
    var n: usize = 0;
    for (items(try c.json(arena, .GET, "/v1/remote/agents", null), "agents")) |item| {
        if (item != .object) continue;
        const online = if (item.object.get("online")) |b| (b == .bool and b.bool) else false;
        if (!online) continue;
        n += 1;
        found = strFieldObj(item.object, "agent_id");
    }
    if (n == 0) std.process.fatal("remote new: no machine is online — run `graff remote-control` there first (`graff remote agents` lists them)", .{});
    if (n > 1) std.process.fatal("remote new: {d} machines are online — name one: graff remote new [session] <agent> (see `graff remote agents`)", .{n});
    return found.?;
}

/// Queue one protocol request; returns the cursor its events start at.
fn request(c: *Client, arena: Allocator, sid: []const u8, rtype: []const u8, text: ?[]const u8) !u64 {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "type", .{ .string = rtype });
    if (text) |t| try obj.put(arena, "text", .{ .string = t });
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(Value{ .object = obj });
    const path = try std.fmt.allocPrint(arena, "/v1/remote/sessions/{s}", .{sid});
    const v = try c.json(arena, .POST, path, aw.writer.buffered());
    return if (v == .object) @intCast(@max(intFieldObj(v.object, "from", 1), 1)) else 1;
}

/// Long-poll the session's events from `from`, painting each as it lands.
/// `until_terminal`: stop at the request's terminal event (send/answer);
/// otherwise stop once the tape is drained and nothing is in flight.
fn tail(c: *Client, arena: Allocator, out: *Io.Writer, sid: []const u8, from: u64, until_terminal: bool) !void {
    var cursor = from;
    var reattached = false;
    var idle_rounds: usize = 0;
    while (true) {
        const path = try std.fmt.allocPrint(arena, "/v1/remote/sessions/{s}/events?from={d}&wait={d}", .{ sid, cursor, tail_wait_ms });
        const v = try c.json(arena, .GET, path, null);
        if (v != .object) std.process.fatal("remote tail: unexpected reply", .{});
        const o = v.object;
        const list = items(v, "events");
        var terminal = false;
        for (list) |ev| {
            if (ev != .string) continue;
            try paint(arena, out, ev.string);
            if (events.terminalEvent(ev.string)) terminal = true;
        }
        try out.flush();
        cursor = @intCast(@max(intFieldObj(o, "next_from", @intCast(cursor)), @as(i64, @intCast(cursor))));
        const in_flight = if (o.get("in_flight")) |b| (b == .bool and b.bool) else false;
        const gap = if (o.get("gap")) |b| (b == .bool and b.bool) else false;
        // The relay's window no longer starts at our cursor: ask the machine
        // to replay its tape from there, once.
        if (gap and !reattached) {
            reattached = true;
            var obj: std.json.ObjectMap = .empty;
            try obj.put(arena, "type", .{ .string = "reattach" });
            try obj.put(arena, "resume_from", .{ .integer = @intCast(cursor) });
            var aw: Io.Writer.Allocating = .init(arena);
            var s: std.json.Stringify = .{ .writer = &aw.writer };
            try s.write(Value{ .object = obj });
            const rpath = try std.fmt.allocPrint(arena, "/v1/remote/sessions/{s}", .{sid});
            _ = try c.json(arena, .POST, rpath, aw.writer.buffered());
            continue;
        }
        if (until_terminal and terminal) return;
        const got = list.len > 0;
        // A plain tail stops as soon as the tape is quiet: a batch that ended a
        // request with nothing else running, or an empty poll on an idle session.
        if (!until_terminal and got and terminal and !in_flight) return;
        if (!until_terminal and !got and !in_flight) {
            idle_rounds += 1;
            if (idle_rounds >= 1) return; // drained and quiet: the tape is complete for now
        } else idle_rounds = 0;
    }
}

/// One event line to the terminal: text streams inline, the rest one-liners.
pub fn paint(arena: Allocator, out: *Io.Writer, line: []const u8) !void {
    const v = std.json.parseFromSliceLeaky(Value, arena, line, .{ .allocate = .alloc_always }) catch return;
    if (v != .object) return;
    const o = v.object;
    const t = strFieldObj(o, "type") orelse return;
    if (std.mem.eql(u8, t, "text")) {
        try out.writeAll(strFieldObj(o, "text") orelse "");
    } else if (std.mem.eql(u8, t, "reasoning")) {
        try out.print("{s}{s}{s}", .{ style.dim, strFieldObj(o, "text") orelse "", style.reset });
    } else if (std.mem.eql(u8, t, "tool_call")) {
        try out.print("\n{s}[tool_call {s}]{s}\n", .{ style.dim, strFieldObj(o, "name") orelse "tool", style.reset });
    } else if (std.mem.eql(u8, t, "ask_user")) {
        try out.print("\n{s}[ask_user]{s} {s}\n  answer with: graff remote answer <session> <text>\n", .{ style.yellow, style.reset, strFieldObj(o, "question") orelse strFieldObj(o, "text") orelse "" });
    } else if (std.mem.eql(u8, t, "turn")) {
        try out.print("\n{s}— turn done · context {d} tokens · ${d:.4}{s}\n", .{ style.dim, intFieldObj(o, "context_tokens", 0), floatField(o, "cost_usd"), style.reset });
    } else if (std.mem.eql(u8, t, "error")) {
        try out.print("\n{s}error:{s} {s}\n", .{ style.red, style.reset, strFieldObj(o, "message") orelse "" });
    } else if (o.get("truncated") != null) {
        try out.print("\n{s}[{s} · {d} bytes, kept on the machine]{s}\n", .{ style.dim, t, intFieldObj(o, "bytes", 0), style.reset });
    }
}

fn floatField(o: std.json.ObjectMap, name: []const u8) f64 {
    const v = o.get(name) orelse return 0;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}

test "paint: text streams inline, control events become one-liners, noise is silent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var aw: Io.Writer.Allocating = .init(arena);
    try paint(arena, &aw.writer, "{\"seq\":1,\"type\":\"text\",\"text\":\"hel\"}");
    try paint(arena, &aw.writer, "{\"seq\":2,\"type\":\"text\",\"text\":\"lo\"}");
    try paint(arena, &aw.writer, "{\"seq\":3,\"type\":\"tool_result\",\"output\":\"ignored\"}");
    try paint(arena, &aw.writer, "{\"seq\":4,\"type\":\"tool_call\",\"name\":\"bash\"}");
    try paint(arena, &aw.writer, "{\"seq\":5,\"type\":\"turn\",\"context_tokens\":1200,\"cost_usd\":0.0021}");
    try paint(arena, &aw.writer, "not json");
    const got = aw.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, got, "hello"));
    try std.testing.expect(std.mem.indexOf(u8, got, "[tool_call bash]") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "ignored") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "context 1200 tokens") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "$0.0021") != null);
}

test "errorMessage prefers the gateway's structured message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("device is offline", errorMessage(arena, "{\"error\":{\"message\":\"device is offline\",\"type\":\"device_offline\"}}"));
    try std.testing.expectEqualStrings("unauthorized", errorMessage(arena, "{\"error\":\"unauthorized\"}"));
    try std.testing.expectEqualStrings("<html>", errorMessage(arena, "<html>"));
}
