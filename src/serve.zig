//! The `graff serve` HTTP bridge: one POST = one --json protocol request,
//! streamed back as NDJSON. Manages a pool of `<exe> --json` child processes
//! and bridges HTTP <-> the stdio protocol. Split out of main.zig (#123).
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
const emitSchema = schema.emitSchema;
const harness_version = root.harness_version;
const schema_version = schema.schema_version;

const ServeConfig = struct {
    host: []const u8,
    port: u16,
    token: ?[]const u8,
    yolo: bool,
    model: ?[]const u8,
    system_prompt: ?[]const u8,
    append_system_prompt: ?[]const u8,
};

/// Cap on one child event line (a tool_result event carrying a big tool
/// output is the realistic worst case). Also the per-session reader buffer.
const serve_line_cap = 1024 * 1024;
/// Cap on one request body (a user prompt; pasted files can be large).
const serve_body_cap = 8 * 1024 * 1024;

const ServeSession = struct {
    id: [16]u8, // hex
    child: std.process.Child,
    rdr: Io.File.Reader, // persistent reader over child stdout — must not move (gpa.create)
    rbuf: []u8, // gpa-owned backing buffer for rdr
    busy: Io.Mutex = .init, // one in-flight protocol request per session
    answer_mu: Io.Mutex = .init,
    awaiting_answer: bool = false,
    answer_call_id: [128]u8 = undefined,
    answer_call_id_len: usize = 0,
};

const ServeState = struct {
    gpa: Allocator,
    io: Io,
    exe: []const u8, // this binary, re-spawned as `<exe> --json …` per session
    cfg: ServeConfig,
    mutex: Io.Mutex = .init, // guards sessions
    sessions: std.ArrayList(*ServeSession) = .empty,
    group: *Io.Group, // detached reapers for closed sessions

    fn find(self: *ServeState, id: []const u8) ?*ServeSession {
        for (self.sessions.items) |s| if (std.mem.eql(u8, &s.id, id)) return s;
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

fn serveLog(io: Io, comptime fmt: []const u8, args: anytype) void {
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
        serveRequest(st, &req) catch return;
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

fn respondJson(st: *ServeState, req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    // A body-less POST/DELETE (neither content-length nor transfer-encoding)
    // trips an assert in std's keep-alive discardBody path — just close the
    // connection for those instead.
    const keep = !req.head.method.requestHasBody() or
        req.head.transfer_encoding != .none or req.head.content_length != null;
    try req.respond(body, .{ .status = status, .keep_alive = keep, .extra_headers = serveJsonHeaders(st) });
}

fn serveRequest(st: *ServeState, req: *std.http.Server.Request) !void {
    const io = st.io;
    const gpa = st.gpa;
    // head strings are invalidated once the body reader starts — copy now.
    var target_buf: [256]u8 = undefined;
    if (req.head.target.len > target_buf.len) return respondJson(st, req, .uri_too_long, "{\"error\":\"target too long\"}");
    const target = target_buf[0..req.head.target.len];
    @memcpy(target, req.head.target);
    const method = req.head.method;

    if (method == .OPTIONS) // CORS preflight
        return req.respond("", .{ .status = .no_content, .extra_headers = serveJsonHeaders(st) });

    if (st.cfg.token) |tok| {
        if (!std.mem.eql(u8, target, "/healthz")) {
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

    if (method == .GET and std.mem.eql(u8, target, "/healthz")) {
        st.mutex.lockUncancelable(io);
        const n = st.sessions.items.len;
        st.mutex.unlock(io);
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"harness\":\"{s}\",\"schema\":\"{s}\",\"sessions\":{d}}}", .{ harness_version, schema_version, n }) catch unreachable;
        return respondJson(st, req, .ok, body);
    }
    if (method == .GET and std.mem.eql(u8, target, "/v1/schema")) {
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        emitSchema(&aw.writer) catch return respondJson(st, req, .internal_server_error, "{\"error\":\"schema emit failed\"}");
        return respondJson(st, req, .ok, aw.writer.buffered());
    }
    if (method == .POST and std.mem.eql(u8, target, "/v1/sessions"))
        return serveCreate(st, req);
    const sess_prefix = "/v1/sessions/";
    if (std.mem.startsWith(u8, target, sess_prefix)) {
        const id = target[sess_prefix.len..];
        if (method == .POST) return serveMessage(st, req, id);
        if (method == .DELETE) return serveDelete(st, req, id);
    }
    return respondJson(st, req, .not_found, "{\"error\":\"not found — see /v1/schema\"}");
}

/// POST /v1/sessions: spawn a `harness --json` child. Per-session options in
/// the (optional) JSON body override the serve-level defaults.
fn serveCreate(st: *ServeState, req: *std.http.Server.Request) !void {
    const io = st.io;
    const gpa = st.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bbuf: [4096]u8 = undefined;
    const br = req.readerExpectContinue(&bbuf) catch return error.WriteFailed;
    const body = br.allocRemaining(arena, .limited(64 * 1024)) catch
        return respondJson(st, req, .payload_too_large, "{\"error\":\"body too large\"}");

    var model = st.cfg.model;
    var yolo = st.cfg.yolo;
    var sys = st.cfg.system_prompt;
    var append_sys = st.cfg.append_system_prompt;
    var max_tools: ?u64 = null;
    var dedupe_tools = false;
    if (std.mem.trim(u8, body, " \t\r\n").len > 0) {
        const v = std.json.parseFromSliceLeaky(Value, arena, body, .{ .allocate = .alloc_always }) catch
            return respondJson(st, req, .bad_request, "{\"error\":\"body must be a JSON object\"}");
        if (v != .object) return respondJson(st, req, .bad_request, "{\"error\":\"body must be a JSON object\"}");
        if (v.object.get("model")) |m| if (m == .string) {
            model = m.string;
        };
        if (v.object.get("yolo")) |y| if (y == .bool) {
            yolo = y.bool;
        };
        if (v.object.get("system_prompt")) |s| if (s == .string) {
            sys = s.string;
        };
        if (v.object.get("append_system_prompt")) |s| if (s == .string) {
            append_sys = s.string;
        };
        if (v.object.get("maxToolCalls") orelse v.object.get("max_tool_calls")) |m| if (m == .integer and m.integer >= 0) {
            max_tools = @intCast(m.integer);
        };
        if (v.object.get("dedupeToolCalls") orelse v.object.get("dedupe_tool_calls")) |d| if (d == .bool) {
            dedupe_tools = d.bool;
        };
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ st.exe, "--json" });
    if (yolo) try argv.append(arena, "--yolo");
    if (model) |m| try argv.appendSlice(arena, &.{ "--model", m });
    if (max_tools) |n| try argv.appendSlice(arena, &.{ "--max-tool-calls", try std.fmt.allocPrint(arena, "{d}", .{n}) });
    if (dedupe_tools) try argv.append(arena, "--dedupe-tool-calls");
    if (sys) |s| try argv.appendSlice(arena, &.{ "--system-prompt", s });
    if (append_sys) |s| try argv.appendSlice(arena, &.{ "--append-system-prompt", s });

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit, // tool progress → the server's terminal
    }) catch return respondJson(st, req, .internal_server_error, "{\"error\":\"failed to spawn harness child\"}");

    const rbuf = gpa.alloc(u8, serve_line_cap) catch {
        child.kill(io);
        return error.WriteFailed;
    };
    const sess = gpa.create(ServeSession) catch {
        gpa.free(rbuf);
        child.kill(io);
        return error.WriteFailed;
    };
    var raw: [8]u8 = undefined;
    io.random(&raw);
    sess.* = .{ .id = undefined, .child = child, .rdr = undefined, .rbuf = rbuf };
    _ = std.fmt.bufPrint(&sess.id, "{x:0>16}", .{std.mem.readInt(u64, &raw, .big)}) catch unreachable;
    sess.rdr = sess.child.stdout.?.readerStreaming(io, sess.rbuf);

    st.mutex.lockUncancelable(io);
    const appended = blk: {
        st.sessions.append(gpa, sess) catch break :blk false;
        break :blk true;
    };
    st.mutex.unlock(io);
    if (!appended) {
        sess.child.kill(io);
        gpa.free(sess.rbuf);
        gpa.destroy(sess);
        return error.WriteFailed;
    }
    serveLog(io, "serve: session {s} created (model={s} yolo={})", .{ &sess.id, model orelse "default", yolo });
    var obuf: [64]u8 = undefined;
    const out = std.fmt.bufPrint(&obuf, "{{\"session_id\":\"{s}\"}}", .{&sess.id}) catch unreachable;
    return respondJson(st, req, .created, out);
}

/// POST /v1/sessions/<id>: forward one protocol request line to the child and
/// stream its stdout events back as chunked NDJSON until the terminal event
/// for that request (turn/error for user turns; system_prompt/score acks).
fn serveMessage(st: *ServeState, req: *std.http.Server.Request, id: []const u8) !void {
    const io = st.io;
    const gpa = st.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    st.mutex.lockUncancelable(io);
    const sess = st.find(id);
    st.mutex.unlock(io);
    const s = sess orelse return respondJson(st, req, .not_found, "{\"error\":\"no such session\"}");

    var bbuf: [64 * 1024]u8 = undefined;
    const br = req.readerExpectContinue(&bbuf) catch return error.WriteFailed;
    const body = br.allocRemaining(arena, .limited(serve_body_cap)) catch
        return respondJson(st, req, .payload_too_large, "{\"error\":\"body too large\"}");
    const line = std.mem.trim(u8, body, " \t\r\n");
    const parsed = std.json.parseFromSliceLeaky(Value, arena, line, .{ .allocate = .alloc_always }) catch
        return respondJson(st, req, .bad_request, "{\"error\":\"body must be one protocol request object, e.g. {\\\"type\\\":\\\"user\\\",\\\"text\\\":\\\"...\\\"}\"}");
    if (parsed != .object or std.mem.indexOfScalar(u8, line, '\n') != null)
        return respondJson(st, req, .bad_request, "{\"error\":\"body must be a single-line JSON object\"}");

    const rtype = if (parsed.object.get("type")) |v| (if (v == .string) v.string else "") else "";
    if (std.mem.eql(u8, rtype, "answer")) return serveAnswer(st, req, s, line, parsed.object);

    s.busy.lockUncancelable(io); // serialize requests per session
    defer s.busy.unlock(io);

    {
        var wb: [1024]u8 = undefined;
        var cw = s.child.stdin.?.writerStreaming(io, &wb);
        cw.interface.writeAll(line) catch return respondJson(st, req, .bad_gateway, "{\"error\":\"session process is gone\"}");
        cw.interface.writeByte('\n') catch return error.WriteFailed;
        cw.interface.flush() catch return respondJson(st, req, .bad_gateway, "{\"error\":\"session process is gone\"}");
    }

    var stream_buf: [16 * 1024]u8 = undefined;
    var bw = req.respondStreaming(&stream_buf, .{
        .respond_options = .{
            .extra_headers = if (st.cfg.token != null) &serve_ndjson_cors_headers else &serve_ndjson_headers,
        },
    }) catch return error.WriteFailed;
    while (true) {
        const ev_line = s.rdr.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                bw.writer.writeAll("{\"type\":\"error\",\"message\":\"event line exceeded the 1 MiB serve cap — session closed\"}\n") catch {};
                bw.end() catch {};
                serveDrop(st, s);
                return;
            },
            error.ReadFailed => {
                bw.writer.writeAll("{\"type\":\"error\",\"message\":\"session process exited mid-request\"}\n") catch {};
                bw.end() catch {};
                serveDrop(st, s);
                return;
            },
        } orelse {
            bw.writer.writeAll("{\"type\":\"error\",\"message\":\"session process exited mid-request\"}\n") catch {};
            bw.end() catch {};
            serveDrop(st, s);
            return;
        };
        const trimmed = std.mem.trim(u8, ev_line, " \t\r");
        if (trimmed.len == 0) continue;
        serveUpdateAnswerState(io, s, trimmed);
        bw.writer.writeAll(trimmed) catch return;
        bw.writer.writeByte('\n') catch return;
        bw.flush() catch return; // deliver each event as it happens
        if (serveTerminalEvent(trimmed)) {
            serveClearAnswerState(io, s);
            break;
        }
    }
    bw.end() catch return;
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

    var wb: [1024]u8 = undefined;
    var cw = s.child.stdin.?.writerStreaming(io, &wb);
    cw.interface.writeAll(line) catch return respondJson(st, req, .bad_gateway, "{\"error\":\"session process is gone\"}");
    cw.interface.writeByte('\n') catch return error.WriteFailed;
    cw.interface.flush() catch return respondJson(st, req, .bad_gateway, "{\"error\":\"session process is gone\"}");
    s.awaiting_answer = false;
    s.answer_call_id_len = 0;
    return respondJson(st, req, .ok, "{\"ok\":true,\"type\":\"answer\"}");
}

fn serveUpdateAnswerState(io: Io, s: *ServeSession, line: []const u8) void {
    const ty = serveStringField(line, "type") orelse return;
    if (!std.mem.eql(u8, ty, "ask_user")) return;
    const call_id = serveStringField(line, "call_id") orelse "";
    s.answer_mu.lockUncancelable(io);
    defer s.answer_mu.unlock(io);
    const n = @min(call_id.len, s.answer_call_id.len);
    @memcpy(s.answer_call_id[0..n], call_id[0..n]);
    s.answer_call_id_len = n;
    s.awaiting_answer = true;
}

fn serveStringField(line: []const u8, field: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    if (field.len + 4 > needle_buf.len) return null;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":\"", .{field}) catch return null;
    const start = std.mem.indexOf(u8, line, needle) orelse return null;
    var i = start + needle.len;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
            continue;
        }
        if (line[i] == '"') return line[start + needle.len .. i];
    }
    return null;
}

fn serveClearAnswerState(io: Io, s: *ServeSession) void {
    s.answer_mu.lockUncancelable(io);
    defer s.answer_mu.unlock(io);
    s.awaiting_answer = false;
    s.answer_call_id_len = 0;
}

/// Is this child event line the terminal event of a protocol request?
/// turn/error end user turns; system_prompt and score are between-turn acks.
/// Unknown event types stream through (edge-version durability) — a newer
/// child must still terminate every request with one of these four.
fn serveTerminalEvent(line: []const u8) bool {
    var scratch: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    // Only the leading "type" field matters; events put it first, so parsing
    // a truncated prefix is enough even for MiB-sized tool_result lines.
    const head = line[0..@min(line.len, 256)];
    var t: []const u8 = "";
    if (std.json.parseFromSliceLeaky(Value, fba.allocator(), line, .{})) |v| {
        if (v == .object) if (v.object.get("type")) |ty| if (ty == .string) {
            t = ty.string;
        };
    } else |_| {
        // Huge line: fall back to a prefix scan for {"type":"..."}.
        const needle = "\"type\":\"";
        if (std.mem.indexOf(u8, head, needle)) |i| {
            const rest = head[i + needle.len ..];
            if (std.mem.indexOfScalar(u8, rest, '"')) |j| t = rest[0..j];
        }
    }
    return std.mem.eql(u8, t, "turn") or std.mem.eql(u8, t, "error") or
        std.mem.eql(u8, t, "system_prompt") or std.mem.eql(u8, t, "score") or
        std.mem.eql(u8, t, "model") or std.mem.eql(u8, t, "compact") or
        std.mem.eql(u8, t, "mode") or std.mem.eql(u8, t, "agent") or
        std.mem.eql(u8, t, "effort") or std.mem.eql(u8, t, "fast");
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
    st.gpa.free(sess.rbuf);
    st.gpa.destroy(sess);
}

/// Background reaper for a gracefully-closed session: the child exits on
/// stdin EOF (after finishing any in-flight turn) and flushes telemetry and
/// trajectory records on the way out — kill would race (and lose) that flush.
fn serveReap(st: *ServeState, sess: *ServeSession) void {
    const io = st.io;
    _ = sess.child.wait(io) catch {};
    st.gpa.free(sess.rbuf);
    st.gpa.destroy(sess);
}

/// DELETE /v1/sessions/<id>: graceful close. Waits for an in-flight request
/// to finish streaming (the busy lock), then EOFs the child's stdin and
/// reaps it in the background.
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

test "serveStringField: extracts a JSON string field, handles escapes and misses" {
    const line = "{\"type\":\"user\",\"text\":\"hello\"}";
    try std.testing.expectEqualStrings("user", serveStringField(line, "type").?);
    try std.testing.expectEqualStrings("hello", serveStringField(line, "text").?);
    try std.testing.expect(serveStringField(line, "missing") == null);
    // escaped quote inside the value is skipped, not treated as the terminator
    const esc = "{\"text\":\"a\\\"b\"}";
    try std.testing.expectEqualStrings("a\\\"b", serveStringField(esc, "text").?);
}
