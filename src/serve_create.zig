//! `POST /v1/sessions`: option parsing, the durable-session naming rules, and
//! the child spawn. Split out of serve.zig, which is at the 600-line cap.
//!
//! #330: the session id IS the graff session name. The child is always spawned
//! with `--resume <name>`, so the conversation autosaves under that name from
//! the first turn and a REPLACEMENT bridge that posts the same name restores it
//! instead of starting an empty one. The reply tells the client where the
//! persisted event tape currently ends (`last_seq`) so it can reconnect with
//! `?from=last_seq+1` without guessing.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const serve = @import("serve.zig"); // back-import: shared state + HTTP helpers
const events = @import("serve_events.zig");

const ServeState = serve.ServeState;
const ServeSession = serve.ServeSession;

pub fn create(st: *ServeState, req: *std.http.Server.Request) !void {
    const io = st.io;
    const gpa = st.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bbuf: [4096]u8 = undefined;
    const br = req.readerExpectContinue(&bbuf) catch return error.WriteFailed;
    const body = br.allocRemaining(arena, .limited(64 * 1024)) catch
        return serve.respondJson(st, req, .payload_too_large, "{\"error\":\"body too large\"}");

    var model = st.cfg.model;
    var subagent_provider = st.cfg.subagent_provider;
    var subagent_model = st.cfg.subagent_model;
    var allow_cross_provider_subagents = st.cfg.allow_cross_provider_subagents;
    var yolo = st.cfg.yolo;
    var sys = st.cfg.system_prompt;
    var append_sys = st.cfg.append_system_prompt;
    var max_tools = st.cfg.max_tool_calls;
    var max_models: ?u64 = st.cfg.max_model_calls;
    var dedupe_tools = st.cfg.dedupe_tool_calls;
    var name = try newSessionName(io, arena);
    if (std.mem.trim(u8, body, " \t\r\n").len > 0) {
        const v = std.json.parseFromSliceLeaky(Value, arena, body, .{ .allocate = .alloc_always }) catch
            return serve.respondJson(st, req, .bad_request, "{\"error\":\"body must be a JSON object\"}");
        if (v != .object) return serve.respondJson(st, req, .bad_request, "{\"error\":\"body must be a JSON object\"}");
        if (v.object.get("session") orelse v.object.get("session_id") orelse v.object.get("resume")) |n| if (n == .string) {
            if (!events.validName(n.string))
                return serve.respondJson(st, req, .bad_request, "{\"error\":\"session must be 1-64 chars of [A-Za-z0-9._-] and must not start with . or -\"}");
            name = n.string;
        };
        if (v.object.get("model")) |m| if (m == .string) {
            model = m.string;
        };
        if (v.object.get("subagentModel") orelse v.object.get("subagent_model")) |m| if (m == .string) {
            subagent_model = m.string;
        };
        if (v.object.get("subagentProvider") orelse v.object.get("subagent_provider")) |p| if (p == .string) {
            subagent_provider = p.string;
        };
        if (v.object.get("allowCrossProviderSubagents") orelse v.object.get("allow_cross_provider_subagents")) |a| if (a == .bool) {
            allow_cross_provider_subagents = a.bool;
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
        if (v.object.get("maxModelCalls") orelse v.object.get("max_model_calls")) |m| if (m == .integer and m.integer >= 0) {
            max_models = @intCast(m.integer);
        };
        if (v.object.get("dedupeToolCalls") orelse v.object.get("dedupe_tool_calls")) |d| if (d == .bool) {
            dedupe_tools = d.bool;
        };
    }

    // Attaching to a session this bridge already runs is idempotent: report it
    // (and where its tape ends) rather than spawning a second child onto the
    // same session file.
    st.mutex.lockUncancelable(io);
    const live = st.find(name);
    const live_seq = if (live) |s| s.last_seq else 0;
    st.mutex.unlock(io);
    if (live != null) return serve.respondJson(st, req, .ok, try createdBody(arena, name, true, live_seq));

    const log_path = try events.logPath(arena, name);
    const resumed = sessionOnDisk(io, arena, name);
    const last_seq = events.lastSeqOnDisk(io, .cwd(), arena, log_path);

    var argv: std.ArrayList([]const u8) = .empty;
    // `--resume <name>` on a name with no file yet is how a session becomes
    // durable from its very first turn: the child autosaves under that name.
    try argv.appendSlice(arena, &.{ st.exe, "--json", "--resume", name });
    if (yolo) try argv.append(arena, "--yolo");
    if (model) |m| try argv.appendSlice(arena, &.{ "--model", m });
    if (subagent_provider) |p| try argv.appendSlice(arena, &.{ "--subagent-provider", p });
    if (subagent_model) |m| try argv.appendSlice(arena, &.{ "--subagent-model", m });
    if (allow_cross_provider_subagents) try argv.append(arena, "--allow-cross-provider-subagents");
    if (max_tools) |n| try argv.appendSlice(arena, &.{ "--max-tool-calls", try std.fmt.allocPrint(arena, "{d}", .{n}) });
    if (max_models) |n| try argv.appendSlice(arena, &.{ "--max-model-calls", try std.fmt.allocPrint(arena, "{d}", .{n}) });
    if (dedupe_tools) try argv.append(arena, "--dedupe-tool-calls");
    if (sys) |s| try argv.appendSlice(arena, &.{ "--system-prompt", s });
    if (append_sys) |s| try argv.appendSlice(arena, &.{ "--append-system-prompt", s });

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit, // tool progress → the server's terminal
    }) catch return serve.respondJson(st, req, .internal_server_error, "{\"error\":\"failed to spawn harness child\"}");

    const sess = newSession(st, &child, name, log_path, last_seq) catch {
        child.kill(io);
        return error.WriteFailed;
    };

    st.mutex.lockUncancelable(io);
    const appended = blk: {
        st.sessions.append(gpa, sess) catch break :blk false;
        break :blk true;
    };
    st.mutex.unlock(io);
    if (!appended) {
        sess.child.kill(io);
        serve.freeSession(st, sess);
        return error.WriteFailed;
    }
    serve.serveLog(io, "serve: session {s} {s} (model={s} yolo={} last_seq={d})", .{
        sess.name, if (resumed) "resumed" else "created", model orelse "default", yolo, last_seq,
    });
    return serve.respondJson(st, req, .created, try createdBody(arena, sess.name, resumed, last_seq));
}

fn createdBody(arena: Allocator, name: []const u8, resumed: bool, last_seq: u64) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"session_id\":\"{s}\",\"resumed\":{},\"last_seq\":{d}}}", .{ name, resumed, last_seq });
}

fn newSessionName(io: Io, arena: Allocator) ![]const u8 {
    var raw: [8]u8 = undefined;
    io.random(&raw);
    return std.fmt.allocPrint(arena, "{x:0>16}", .{std.mem.readInt(u64, &raw, .big)});
}

fn sessionOnDisk(io: Io, arena: Allocator, name: []const u8) bool {
    const path = std.fmt.allocPrint(arena, ".graff/sessions/{s}.session.json", .{name}) catch return false;
    if (Io.Dir.cwd().statFile(io, path, .{})) |_| return true else |_| return false;
}

/// Allocate the per-session state (all gpa-owned so it outlives the request
/// arena) and open its durable event log.
fn newSession(st: *ServeState, child: *std.process.Child, name: []const u8, log_path: []const u8, last_seq: u64) !*ServeSession {
    const gpa = st.gpa;
    const rbuf = try gpa.alloc(u8, serve.serve_line_cap);
    errdefer gpa.free(rbuf);
    const owned_name = try gpa.dupe(u8, name);
    errdefer gpa.free(owned_name);
    const owned_path = try gpa.dupe(u8, log_path);
    errdefer gpa.free(owned_path);
    const sess = try gpa.create(ServeSession);
    sess.* = .{
        .name = owned_name,
        .log_path = owned_path,
        .log = events.EventLog.open(st.io, .cwd(), owned_path),
        .last_seq = last_seq,
        .child = child.*,
        .rdr = undefined,
        .rbuf = rbuf,
    };
    sess.rdr = sess.child.stdout.?.readerStreaming(st.io, sess.rbuf);
    return sess;
}

test "createdBody reports the durable id, whether it resumed, and the tape end (#330)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "{\"session_id\":\"nightly\",\"resumed\":true,\"last_seq\":42}",
        try createdBody(arena, "nightly", true, 42),
    );
    try std.testing.expectEqualStrings(
        "{\"session_id\":\"00ff\",\"resumed\":false,\"last_seq\":0}",
        try createdBody(arena, "00ff", false, 0),
    );
}

test "a generated session name is a valid durable id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const name = try newSessionName(std.testing.io, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 16), name.len);
    try std.testing.expect(events.validName(name)); // usable as a path AND a URL segment
}
