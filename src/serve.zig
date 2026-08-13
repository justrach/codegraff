//! The `graff serve` HTTP bridge: one POST = one --json protocol request,
//! streamed back as NDJSON. Manages a pool of `<exe> --json` child processes
//! and bridges HTTP <-> the stdio protocol. Split out of main.zig (#123).
//!
//! #330 (embedder mode): a session is DURABLE. Its id doubles as the graff
//! session name, the child is spawned with `--resume <id>` so the conversation
//! autosaves after every turn, and every forwarded event line is appended to
//! `.graff/serve/<id>.events.jsonl` with the monotonic `seq` the child stamped.
//! A supervisor that drops the socket reconnects with `?from=N`; a supervisor
//! whose whole bridge died starts a REPLACEMENT process, POSTs the same session
//! id, and picks the run up from the last persisted turn. The log plumbing and
//! replay filter live in serve_events.zig.
//!
//! std-only except for three things that stay in main and are back-imported:
//! emitSchema (GET /v1/schema) and harness_version + schema_version (/healthz).

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

// Back-import the root module for the few helpers that remain in main.zig. Zig
// resolves the main<->serve import cycle fine (all runtime, no comptime dep).
const root = @import("main.zig");
const schema = @import("schema.zig");
const events = @import("serve_events.zig");
const serve_create = @import("serve_create.zig"); // POST /v1/sessions (durable naming + spawn)
const emitSchema = schema.emitSchema;
const harness_version = root.harness_version;
const schema_version = schema.schema_version;

const ServeConfig = struct {
    host: []const u8,
    port: u16,
    token: ?[]const u8,
    yolo: bool,
    model: ?[]const u8,
    subagent_provider: ?[]const u8,
    subagent_model: ?[]const u8,
    allow_cross_provider_subagents: bool,
    no_subagent_tier: bool,
    system_prompt: ?[]const u8,
    append_system_prompt: ?[]const u8,
    max_tool_calls: ?u64,
    max_model_calls: u64,
    dedupe_tool_calls: bool,
};

/// Cap on one child event line (a tool_result event carrying a big tool
/// output is the realistic worst case). Also the per-session reader buffer.
pub const serve_line_cap = 1024 * 1024;
/// Cap on one request body (a user prompt; pasted files can be large).
const serve_body_cap = 8 * 1024 * 1024;
/// Follow poll cadence and ceiling: a reattached client waits for live events
/// at 25ms, and gives up after ~10 minutes rather than pinning a connection.
const follow_poll_ms = 25;
const follow_max_polls = 10 * 60 * 1000 / follow_poll_ms;

pub const ServeSession = struct {
    name: []const u8, // gpa-owned; the HTTP id AND the graff --resume session name
    log_path: []const u8, // gpa-owned; .graff/serve/<name>.events.jsonl
    log: events.EventLog,
    last_seq: u64 = 0, // highest seq forwarded/persisted; bridge-generated errors continue it
    child: std.process.Child,
    rdr: Io.File.Reader, // persistent reader over child stdout — must not move (gpa.create)
    rbuf: []u8, // gpa-owned backing buffer for rdr
    busy: Io.Mutex = .init, // one in-flight protocol request per session
    in_flight: std.atomic.Value(bool) = .init(false), // a request is streaming: followers keep tailing
    stdin_mu: Io.Mutex = .init, // answer/cancel bypass busy but never interleave child writes
    answer_mu: Io.Mutex = .init,
    awaiting_answer: bool = false,
    answer_call_id: [128]u8 = undefined,
    answer_call_id_len: usize = 0,
};

pub const ServeState = struct {
    gpa: Allocator,
    io: Io,
    exe: []const u8, // this binary, re-spawned as `<exe> --json …` per session
    cfg: ServeConfig,
    mutex: Io.Mutex = .init, // guards sessions
    sessions: std.ArrayList(*ServeSession) = .empty,
    group: *Io.Group, // detached reapers for closed sessions

    pub fn find(self: *ServeState, id: []const u8) ?*ServeSession {
        for (self.sessions.items) |s| if (std.mem.eql(u8, s.name, id)) return s;
        return null;
    }
};

/// Constant-time bytes comparison for the bearer token.
fn ctEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

pub fn serveLog(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    var w = Io.File.stderr().writer(io, &buf);
    w.interface.print(fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
}

pub fn serveMain(gpa: Allocator, io: Io, cfg: ServeConfig, exe: []const u8) !void {
    const loopback = std.mem.eql(u8, cfg.host, "127.0.0.1") or std.mem.eql(u8, cfg.host, "::1");
    if (!loopback and cfg.token == null)
        std.process.fatal("serve: refusing to bind {s} without auth — pass --token <secret> or set HARNESS_SERVE_TOKEN", .{cfg.host});

    var addr = std.Io.net.IpAddress.parse(cfg.host, cfg.port) catch
        std.process.fatal("serve: --host needs an IP literal, got '{s}'", .{cfg.host});
    var server = std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true }) catch |err|
        std.process.fatal("serve: cannot listen on {s}:{d}: {t}", .{ cfg.host, cfg.port, err });
    defer server.deinit(io);

    var group: Io.Group = .init;
    defer group.cancel(io);
    var st: ServeState = .{ .gpa = gpa, .io = io, .exe = exe, .cfg = cfg, .group = &group };

    serveLog(io, "simple-harness serve · http://{s}:{d} · auth: {s} · sessions are `{s} --json` children", .{
        cfg.host, cfg.port, if (cfg.token != null) "bearer token" else "none (loopback)", exe,
    });
    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.Canceled => return,
            else => continue,
        };
        group.concurrent(io, serveConn, .{ &st, stream }) catch serveConn(&st, stream);
    }
}

/// One connection: HTTP/1.1 with keep-alive, requests handled in sequence.
fn serveConn(st: *ServeState, stream: std.Io.net.Stream) void {
    const io = st.io;
    defer stream.close(io);
    var rbuf: [32 * 1024]u8 = undefined;
    var wbuf: [32 * 1024]u8 = undefined;
    var sr = std.Io.net.Stream.Reader.init(stream, io, &rbuf);
    var sw = std.Io.net.Stream.Writer.init(stream, io, &wbuf);
    var http_server = std.http.Server.init(&sr.interface, &sw.interface);
    while (true) {
        var req = http_server.receiveHead() catch return;
        serveRequest(st, &req, &sw.interface) catch return;
    }
}

const serve_json_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/json" },
};

/// CORS headers, sent only when a bearer token is configured (see the module
/// comment above): with a token the token is the gate and cross-origin
/// browser clients are legitimate; without one, silence keeps browsers out.
const serve_cors_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/json" },
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "access-control-allow-methods", .value = "GET, POST, DELETE, OPTIONS" },
    .{ .name = "access-control-allow-headers", .value = "authorization, content-type" },
};

const serve_ndjson_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/x-ndjson" },
};
const serve_ndjson_cors_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/x-ndjson" },
    .{ .name = "access-control-allow-origin", .value = "*" },
};

fn serveJsonHeaders(st: *ServeState) []const std.http.Header {
    return if (st.cfg.token != null) &serve_cors_headers else &serve_json_headers;
}

fn serveNdjsonHeaders(st: *ServeState) []const std.http.Header {
    return if (st.cfg.token != null) &serve_ndjson_cors_headers else &serve_ndjson_headers;
}

pub fn respondJson(st: *ServeState, req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    // A body-less POST/DELETE (neither content-length nor transfer-encoding)
    // trips an assert in std's keep-alive discardBody path — just close the
    // connection for those instead.
    const keep = !req.head.method.requestHasBody() or
        req.head.transfer_encoding != .none or req.head.content_length != null;
    try req.respond(body, .{ .status = status, .keep_alive = keep, .extra_headers = serveJsonHeaders(st) });
}

fn serveRequest(st: *ServeState, req: *std.http.Server.Request, transport: *Io.Writer) !void {
    const io = st.io;
    const gpa = st.gpa;
    // head strings are invalidated once the body reader starts — copy now.
    var target_buf: [256]u8 = undefined;
    if (req.head.target.len > target_buf.len) return respondJson(st, req, .uri_too_long, "{\"error\":\"target too long\"}");
    const target = target_buf[0..req.head.target.len];
    @memcpy(target, req.head.target);
    const method = req.head.method;
    const split = events.splitTarget(target);
    const path = split.path;
    // #330: `?from=N` asks for persisted events with seq >= N before the live
    // stream. Same meaning on the reattach GET and on a request POST.
    const from_query = events.queryU64(split.query, "from");

    if (method == .OPTIONS) // CORS preflight
        return req.respond("", .{ .status = .no_content, .extra_headers = serveJsonHeaders(st) });

    if (st.cfg.token) |tok| {
        if (!std.mem.eql(u8, path, "/healthz")) {
            var authed = false;
            var it = req.iterateHeaders();
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
                    if (h.value.len > 7 and std.ascii.eqlIgnoreCase(h.value[0..7], "Bearer ") and ctEql(h.value[7..], tok))
                        authed = true;
                }
            }
            if (!authed) return respondJson(st, req, .unauthorized, "{\"error\":\"unauthorized — send Authorization: Bearer <token>\"}");
        }
    }

    if (method == .GET and std.mem.eql(u8, path, "/healthz")) {
        st.mutex.lockUncancelable(io);
        const n = st.sessions.items.len;
        st.mutex.unlock(io);
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"harness\":\"{s}\",\"schema\":\"{s}\",\"sessions\":{d}}}", .{ harness_version, schema_version, n }) catch unreachable;
        return respondJson(st, req, .ok, body);
    }
    if (method == .GET and std.mem.eql(u8, path, "/v1/schema")) {
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        emitSchema(&aw.writer) catch return respondJson(st, req, .internal_server_error, "{\"error\":\"schema emit failed\"}");
        return respondJson(st, req, .ok, aw.writer.buffered());
    }
    if (method == .POST and std.mem.eql(u8, path, "/v1/sessions"))
        return serve_create.create(st, req);
    const sess_prefix = "/v1/sessions/";
    if (std.mem.startsWith(u8, path, sess_prefix)) {
        var id = path[sess_prefix.len..];
        const events_suffix = "/events";
        if (method == .GET and std.mem.endsWith(u8, id, events_suffix)) {
            id = id[0 .. id.len - events_suffix.len];
            return serveFollow(st, req, transport, id, from_query orelse 1);
        }
        if (method == .POST) return serveMessage(st, req, transport, id, from_query);
        if (method == .DELETE) return serveDelete(st, req, id);
    }
    return respondJson(st, req, .not_found, "{\"error\":\"not found — see /v1/schema\"}");
}

pub fn freeSession(st: *ServeState, sess: *ServeSession) void {
    sess.log.close();
    st.gpa.free(sess.rbuf);
    st.gpa.free(sess.name);
    st.gpa.free(sess.log_path);
    st.gpa.destroy(sess);
}

/// POST /v1/sessions/<id>: forward one protocol request line to the child and
/// stream its stdout events back as chunked NDJSON until the terminal event
/// for that request (every type in serve_events.terminal_events).
/// `?from=N` (or `"resume_from": N` in the body) replays persisted events with
/// seq >= N first, so a reconnecting supervisor never has a hole.
fn serveMessage(st: *ServeState, req: *std.http.Server.Request, transport: *Io.Writer, id: []const u8, from_query: ?u64) !void {
    const io = st.io;
    const gpa = st.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bbuf: [64 * 1024]u8 = undefined;
    const br = req.readerExpectContinue(&bbuf) catch return error.WriteFailed;
    const body = br.allocRemaining(arena, .limited(serve_body_cap)) catch
        return respondJson(st, req, .payload_too_large, "{\"error\":\"body too large\"}");
    const line = std.mem.trim(u8, body, " \t\r\n");
    const parsed = std.json.parseFromSliceLeaky(Value, arena, line, .{ .allocate = .alloc_always }) catch
        return respondJson(st, req, .bad_request, "{\"error\":\"body must be one protocol request object, e.g. {\\\"type\\\":\\\"user\\\",\\\"text\\\":\\\"...\\\"}\"}");
    if (parsed != .object or std.mem.indexOfScalar(u8, line, '\n') != null)
        return respondJson(st, req, .bad_request, "{\"error\":\"body must be a single-line JSON object\"}");

    const from = from_query orelse blk: {
        const v = parsed.object.get("resume_from") orelse break :blk null;
        break :blk if (v == .integer and v.integer > 0) @as(u64, @intCast(v.integer)) else null;
    };
    const rtype = if (parsed.object.get("type")) |v| (if (v == .string) v.string else "") else "";
    // A pure reconnect: replay + tail, send nothing new to the child. Answered
    // before the live-session lookup, because the session this client is
    // catching up on may belong to a bridge that is already dead.
    if (std.mem.eql(u8, rtype, "reattach")) return serveFollow(st, req, transport, id, from orelse 1);

    st.mutex.lockUncancelable(io);
    const sess = st.find(id);
    st.mutex.unlock(io);
    const s = sess orelse return respondJson(st, req, .not_found, "{\"error\":\"no such session\"}");
    if (std.mem.eql(u8, rtype, "answer")) return serveAnswer(st, req, s, line, parsed.object);
    if (std.mem.eql(u8, rtype, "cancel")) return serveCancel(st, req, s, line);

    // `dead` rather than dropping inline: serveDrop FREES the session, and the
    // busy/in_flight defers below would then run through a dangling pointer.
    var dead = false;
    {
        s.busy.lockUncancelable(io); // serialize requests per session
        defer s.busy.unlock(io);
        s.in_flight.store(true, .release);
        defer s.in_flight.store(false, .release);

        writeChildLine(io, s, line) catch return respondJson(st, req, .bad_gateway, "{\"error\":\"session process is gone\"}");

        var stream_buf: [16 * 1024]u8 = undefined;
        var bw = req.respondStreaming(&stream_buf, .{
            .respond_options = .{ .extra_headers = serveNdjsonHeaders(st) },
        }) catch return error.WriteFailed;
        transport.flush() catch return error.WriteFailed;
        // Replayed events all predate the request we just sent, so the client
        // sees one ordered, gap-free sequence: the tail it missed, then the
        // live turn.
        var client_alive = true;
        if (from) |n| {
            if (Io.Dir.cwd().readFileAlloc(io, s.log_path, arena, .limited(events.max_log_bytes))) |data| {
                _ = events.replay(&bw.writer, data, n) catch {
                    client_alive = false;
                };
                bw.writer.flush() catch {
                    client_alive = false;
                };
                if (client_alive) bw.flush() catch {
                    client_alive = false;
                };
                if (client_alive) transport.flush() catch {
                    client_alive = false;
                };
            } else |_| {}
        }

        while (true) {
            const ev_line = s.rdr.interface.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => break serveAbort(s, &bw, client_alive, "event line exceeded the 1 MiB serve cap — session closed", &dead),
                error.ReadFailed => break serveAbort(s, &bw, client_alive, "session process exited mid-request", &dead),
            } orelse break serveAbort(s, &bw, client_alive, "session process exited mid-request", &dead);
            const trimmed = std.mem.trim(u8, ev_line, " \t\r");
            if (trimmed.len == 0) continue;
            serveUpdateAnswerState(io, s, trimmed);
            // Persist BEFORE the socket: the tape has to survive a client that
            // is already gone, or a reconnect would find the run stalled at the
            // moment the supervisor died.
            s.log.append(trimmed);
            if (events.seqOf(trimmed)) |q| s.last_seq = @max(s.last_seq, q);
            if (client_alive) {
                bw.writer.writeAll(trimmed) catch {
                    client_alive = false;
                };
                if (client_alive) bw.writer.writeByte('\n') catch {
                    client_alive = false;
                };
                if (client_alive) bw.writer.flush() catch {
                    client_alive = false;
                };
                if (client_alive) bw.flush() catch {
                    client_alive = false;
                };
                if (client_alive) transport.flush() catch {
                    client_alive = false;
                }; // deliver each event as it happens
            }
            if (events.terminalEvent(trimmed)) {
                serveClearAnswerState(io, s);
                break;
            }
        }
        if (client_alive and !dead) {
            bw.end() catch {};
            transport.flush() catch {};
        }
    }
    if (dead) serveDrop(st, s); // after the defers above are done with `s`
}

/// The child died (or overran the line cap) mid-request: record a terminal
/// error on the tape with the next sequence id — a reconnecting client must
/// see the failure, not a hole — and flag the session for removal once the
/// caller's locks are released.
fn serveAbort(s: *ServeSession, bw: anytype, client_alive: bool, message: []const u8, dead: *bool) void {
    s.last_seq += 1;
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{{\"seq\":{d},\"type\":\"error\",\"message\":\"{s}\"}}", .{ s.last_seq, message }) catch
        "{\"type\":\"error\",\"message\":\"session process exited mid-request\"}";
    s.log.append(line);
    if (client_alive) {
        bw.writer.writeAll(line) catch {};
        bw.writer.writeByte('\n') catch {};
        bw.end() catch {};
    }
    dead.* = true;
}

/// GET /v1/sessions/<id>/events?from=N (and the `{"type":"reattach"}` POST):
/// replay the persisted tape from seq N, then keep tailing it live while a
/// request is in flight. Takes no protocol lock and never writes to the child,
/// so it works while another connection is mid-turn — that connection keeps
/// draining the child into the log even after ITS socket dies.
fn serveFollow(st: *ServeState, req: *std.http.Server.Request, transport: *Io.Writer, id: []const u8, from: u64) !void {
    const io = st.io;
    const gpa = st.gpa;
    if (!events.validName(id)) return respondJson(st, req, .bad_request, "{\"error\":\"bad session id\"}");

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The tape path is derived, not borrowed: a follower must never hold a
    // pointer into a ServeSession another connection may drop and free while
    // this one is still tailing. `inFlight` re-looks the session up under the
    // mutex each poll for the same reason.
    const log_path = try events.logPath(arena, id);
    // A session this bridge never spawned is still replayable from its tape:
    // that is exactly the supervisor-crash case.
    if (Io.Dir.cwd().statFile(io, log_path, .{})) |_| {} else |_| {
        return respondJson(st, req, .not_found, "{\"error\":\"no such session\"}");
    }

    const buf = gpa.alloc(u8, serve_line_cap + 4096) catch return error.WriteFailed;
    defer gpa.free(buf);
    var follower = events.Follower.open(io, .cwd(), log_path, buf, 0);
    defer follower.close();

    var stream_buf: [16 * 1024]u8 = undefined;
    var bw = req.respondStreaming(&stream_buf, .{
        .respond_options = .{ .extra_headers = serveNdjsonHeaders(st) },
    }) catch return error.WriteFailed;
    transport.flush() catch return error.WriteFailed;
    var next_from = from;
    var idle: usize = 0;
    // A terminal event ends this client's watch, but only once the tape is
    // drained: a cold replay of a multi-turn session arrives in buffer-sized
    // chunks, and one of those can END on a turn/ack with later turns still to
    // come. Stopping there would silently truncate the replay.
    var ended = false;
    while (true) {
        const chunk = follower.poll();
        if (chunk.len > 0) {
            const replayed = events.replay(&bw.writer, chunk, next_from) catch break;
            if (replayed.emitted > 0) {
                next_from = replayed.last_seq + 1;
                bw.writer.flush() catch break;
                bw.flush() catch break;
                transport.flush() catch break;
                ended = replayed.terminal;
            }
            idle = 0;
            continue;
        }
        if (ended) break; // drained, and the last event closed a request
        // Idle session (or one this bridge never ran): the tape is complete.
        if (!inFlight(st, id)) break;
        idle += 1;
        if (idle > follow_max_polls) break;
        io.sleep(.fromMilliseconds(follow_poll_ms), .awake) catch break;
    }
    bw.end() catch return;
    transport.flush() catch return;
}

/// Is a request streaming on this session right now? Read under the session
/// mutex, which serveDrop also takes before removing a session, so the answer
/// can never come from freed storage.
fn inFlight(st: *ServeState, id: []const u8) bool {
    st.mutex.lockUncancelable(st.io);
    defer st.mutex.unlock(st.io);
    const s = st.find(id) orelse return false;
    return s.in_flight.load(.acquire);
}

fn serveAnswer(st: *ServeState, req: *std.http.Server.Request, s: *ServeSession, line: []const u8, obj: std.json.ObjectMap) !void {
    const io = st.io;
    s.answer_mu.lockUncancelable(io);
    defer s.answer_mu.unlock(io);

    if (!s.awaiting_answer) {
        return respondJson(st, req, .conflict, "{\"error\":\"no active ask_user prompt\"}");
    }
    const req_call_id = if (obj.get("call_id")) |v| (if (v == .string) v.string else "") else "";
    const active_call_id = s.answer_call_id[0..s.answer_call_id_len];
    if (req_call_id.len > 0 and active_call_id.len > 0 and !std.mem.eql(u8, req_call_id, active_call_id)) {
        return respondJson(st, req, .conflict, "{\"error\":\"answer call_id does not match active ask_user prompt\"}");
    }

    writeChildLine(io, s, line) catch return respondJson(st, req, .bad_gateway, "{\"error\":\"session process is gone\"}");
    s.awaiting_answer = false;
    s.answer_call_id_len = 0;
    return respondJson(st, req, .ok, "{\"ok\":true,\"type\":\"answer\"}");
}

fn serveCancel(st: *ServeState, req: *std.http.Server.Request, s: *ServeSession, line: []const u8) !void {
    if (!s.in_flight.load(.acquire))
        return respondJson(st, req, .conflict, "{\"error\":\"no request is in flight\"}");
    writeChildLine(st.io, s, line) catch
        return respondJson(st, req, .bad_gateway, "{\"error\":\"session process is gone\"}");
    return respondJson(st, req, .ok, "{\"ok\":true,\"type\":\"cancel\"}");
}

fn writeChildLine(io: Io, s: *ServeSession, line: []const u8) !void {
    s.stdin_mu.lockUncancelable(io);
    defer s.stdin_mu.unlock(io);
    var buf: [1024]u8 = undefined;
    var writer = s.child.stdin.?.writerStreaming(io, &buf);
    try writer.interface.writeAll(line);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

fn serveUpdateAnswerState(io: Io, s: *ServeSession, line: []const u8) void {
    const ty = events.stringField(line, "type") orelse return;
    if (!std.mem.eql(u8, ty, "ask_user")) return;
    const call_id = events.stringField(line, "call_id") orelse "";
    s.answer_mu.lockUncancelable(io);
    defer s.answer_mu.unlock(io);
    const n = @min(call_id.len, s.answer_call_id.len);
    @memcpy(s.answer_call_id[0..n], call_id[0..n]);
    s.answer_call_id_len = n;
    s.awaiting_answer = true;
}

fn serveClearAnswerState(io: Io, s: *ServeSession) void {
    s.answer_mu.lockUncancelable(io);
    defer s.answer_mu.unlock(io);
    s.awaiting_answer = false;
    s.answer_call_id_len = 0;
}

/// Remove a dead session and free it (child already gone or being killed).
fn serveDrop(st: *ServeState, sess: *ServeSession) void {
    const io = st.io;
    st.mutex.lockUncancelable(io);
    for (st.sessions.items, 0..) |p, i| {
        if (p == sess) {
            _ = st.sessions.swapRemove(i);
            break;
        }
    }
    st.mutex.unlock(io);
    sess.child.kill(io); // reaps; harmless if already exited
    freeSession(st, sess);
}

/// Background reaper for a gracefully-closed session: the child exits on
/// stdin EOF (after finishing any in-flight turn) and flushes telemetry and
/// trajectory records on the way out — kill would race (and lose) that flush.
fn serveReap(st: *ServeState, sess: *ServeSession) void {
    _ = sess.child.wait(st.io) catch {};
    freeSession(st, sess);
}

/// DELETE /v1/sessions/<id>: graceful close. Waits for an in-flight request
/// to finish streaming (the busy lock), then EOFs the child's stdin and
/// reaps it in the background. The event log and the session file stay on
/// disk: closing a session ends the process, not the run's resumability.
fn serveDelete(st: *ServeState, req: *std.http.Server.Request, id: []const u8) !void {
    const io = st.io;
    st.mutex.lockUncancelable(io);
    const found = st.find(id);
    if (found) |sess| {
        for (st.sessions.items, 0..) |p, i| {
            if (p == sess) {
                _ = st.sessions.swapRemove(i);
                break;
            }
        }
    }
    st.mutex.unlock(io);
    const sess = found orelse return respondJson(st, req, .not_found, "{\"error\":\"no such session\"}");
    sess.busy.lockUncancelable(io);
    sess.busy.unlock(io);
    if (sess.child.stdin) |f| {
        f.close(io);
        sess.child.stdin = null;
    }
    st.group.concurrent(io, serveReap, .{ st, sess }) catch serveReap(st, sess);
    serveLog(io, "serve: session {s} closed", .{id});
    return respondJson(st, req, .ok, "{\"ok\":true}");
}

test "ctEql: constant-time compare matches std.mem.eql semantics" {
    try std.testing.expect(ctEql("secret-token", "secret-token"));
    try std.testing.expect(!ctEql("secret-token", "secret-tokeX"));
    try std.testing.expect(!ctEql("short", "longer-string"));
    try std.testing.expect(ctEql("", ""));
}
