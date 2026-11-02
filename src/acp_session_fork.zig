//! ACP `session/fork` (draft RFD) for the live CLI Agent: branch a saved
//! session into a new one and make the branch this process's session. The
//! source keeps its save, so the client can still load it in another process.
//! Forking this process's own session saves it first (session_fork.zig); any
//! other session must be a save in the selected workspace, as for session/load.
//! The result has session/new's shape; `replayFrom: {type: start}` also
//! replays the branch's history, the same opt-in v2 session/resume takes.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const proto = @import("acp_protocol.zig");
const engine = @import("acp_engine.zig");
const session = @import("session.zig");
const session_fork = @import("session_fork.zig");
const load = @import("acp_session_load.zig");
const acp_workspace = @import("acp_workspace.zig");
const LiveTurn = @import("acp_live_turn.zig").LiveTurn;
const util = @import("util.zig");

const invalid_params: i32 = -32602;

fn reject(w: *Io.Writer, req: proto.Request, message: []const u8) !bool {
    if (req.id != null) try proto.writeError(w, req.id, invalid_params, message);
    return true;
}

fn failText(err: anyerror) []const u8 {
    return switch (err) {
        error.NothingToFork => "Session has nothing to fork yet",
        error.InvalidSessionName => "Invalid session ID",
        error.BranchAlreadyExists => "A session with the fork's name already exists",
        else => @errorName(err),
    };
}

/// True when `req` was session/fork (answered here either way).
pub fn handle(live: *LiveTurn, arena: Allocator, w: *Io.Writer, req: proto.Request) !bool {
    if (!std.mem.eql(u8, req.method, "session/fork")) return false;
    const d = live.dispatch orelse return reject(w, req, "Session forking is unavailable");
    const env = d.workspace orelse return reject(w, req, "Session forking is unavailable");
    const params = req.params orelse return reject(w, req, "Invalid session/fork parameters");
    if (params != .object) return reject(w, req, "Invalid session/fork parameters");
    const sid = util.strFieldObj(params.object, "sessionId") orelse return reject(w, req, "Invalid session ID");
    if (util.strFieldObj(params.object, "cwd") == null) return reject(w, req, "Invalid session workspace");
    if (!session.validSessionName(sid)) return reject(w, req, "Invalid session ID");
    acp_workspace.adopt(env, arena, params) catch |err| return reject(w, req, acp_workspace.errorText(err));
    if (d.mcp_servers) |attach| attach(d.ctx, arena, req.params) catch {};
    const root = live.root;
    const own = std.mem.eql(u8, sid, root.session_name) or (d.session_id != null and std.mem.eql(u8, sid, d.session_id.?));
    if (own) {
        _ = session_fork.forkCurrent(root, live.keys, arena, null, null) catch |err| return reject(w, req, failText(err));
    } else {
        switch (load.savedHere(live, env, arena, sid)) {
            .provider => {},
            .rejected => |message| return reject(w, req, message),
        }
        // Flush the outgoing conversation before the branch replaces it.
        session.saveSession(root, arena, root.session_name) catch |err| {
            try proto.writeError(w, req.id, engine.err_internal, @errorName(err));
            return true;
        };
        const target = try session_fork.autoName(root, arena, sid);
        _ = @import("session_branch.zig").restore(root, live.keys, arena, sid, target, live.model_override) catch |err|
            return reject(w, req, failText(err));
    }
    live.session_id = root.session_name;
    d.session_id = live.session_id;
    d.durable_session_id = live.session_id;
    if (load.replayFromStart(params)) try load.replayHistory(arena, root, w, live.session_id);
    const options = engine.configOptions(d, arena) catch |err| {
        try proto.writeError(w, req.id, engine.err_internal, @errorName(err));
        return true;
    };
    try proto.writeResult(w, req.id, .{ .sessionId = live.session_id, .configOptions = options, ._meta = acp_workspace.meta(env, arena) });
    try proto.writeAvailableCommands(w, live.session_id, try @import("acp_t3.zig").commands(arena, proto.slashCommands()));
    return true;
}

test "session/fork without a live workspace or a session ID is refused, not dropped" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var out: Io.Writer.Allocating = .init(a);
    var live: LiveTurn = undefined;
    live.dispatch = null;
    const other = proto.parseRequest(a, "{\"id\":1,\"method\":\"session/load\"}").?;
    try std.testing.expect(!try handle(&live, a, &out.writer, other));
    const fork = proto.parseRequest(a, "{\"id\":2,\"method\":\"session/fork\",\"params\":{\"cwd\":\"/tmp\"}}").?;
    try std.testing.expect(try handle(&live, a, &out.writer, fork));
    try std.testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "\"id\":2,\"error\"") != null);
}
