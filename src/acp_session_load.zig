//! ACP v1 session/load for the live CLI Agent. Only a saved session in the
//! selected workspace can be loaded; session IDs are plain save basenames.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const proto = @import("acp_protocol.zig");
const engine = @import("acp_engine.zig");
const session = @import("session.zig");
const session_index = @import("session_index.zig");
const replay = @import("acp_replay.zig");
const transcript = @import("session_transcript.zig");
const LiveTurn = @import("acp_live_turn.zig").LiveTurn;
const util = @import("util.zig");

const invalid_params: i32 = -32602;

pub fn configure(d: *engine.Dispatch, live: *LiveTurn) void {
    d.load_session = load;
    d.config = @import("acp_config.zig").option;
    d.set_config = @import("acp_config.zig").set;
    d.durable_session_id = if (session.validSessionName(live.root.session_name)) live.root.session_name else null;
    live.dispatch = d;
}

fn reject(w: *Io.Writer, req: proto.Request, message: []const u8) !void {
    if (req.id != null) try proto.writeError(w, req.id, invalid_params, message);
}

fn replayHistory(arena: Allocator, root: *@import("agent.zig").Agent, w: *Io.Writer, sid: []const u8) !void {
    // The provider context can be compacted. The append-only transcript keeps
    // earlier visible turns; a legacy save without one uses current history.
    var retained: std.ArrayList(std.json.Value) = .empty;
    for ([_][]const u8{
        try transcript.rotatedPath(arena, sid),
        try transcript.transcriptPath(arena, sid),
    }) |path| {
        const bytes = Io.Dir.cwd().readFileAlloc(root.io, path, arena, .limited(transcript.cap_bytes + 1024)) catch continue;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{ .allocate = .alloc_always }) catch continue;
            try retained.append(arena, value);
        }
    }
    try replay.replay(arena, w, sid, if (retained.items.len > 0) retained.items else root.messages.items);
}

pub fn load(ctx: *anyopaque, arena: Allocator, w: *Io.Writer, req: proto.Request) anyerror!void {
    const live: *LiveTurn = @ptrCast(@alignCast(ctx));
    const d = live.dispatch orelse return reject(w, req, "Session loading is unavailable");
    const params = req.params orelse return reject(w, req, "Invalid session/load parameters");
    if (params != .object) return reject(w, req, "Invalid session/load parameters");
    const sid = util.strFieldObj(params.object, "sessionId") orelse return reject(w, req, "Invalid session ID");
    const cwd = util.strFieldObj(params.object, "cwd") orelse return reject(w, req, "Invalid session workspace");
    if (!session.validSessionName(sid)) return reject(w, req, "Invalid session ID");
    if (!std.fs.path.isAbsolute(cwd))
        return reject(w, req, "Session workspace does not match the selected workspace");
    const canonical_cwd = Io.Dir.cwd().realPathFileAlloc(live.root.io, cwd, arena) catch cwd;
    const canonical_active = Io.Dir.cwd().realPathFileAlloc(live.root.io, d.cwd, arena) catch d.cwd;
    if (!session_index.sameWorkspace(canonical_cwd, canonical_active))
        return reject(w, req, "Session workspace does not match the selected workspace");
    // No discovery fallback to the user's home or a sibling checkout. A save
    // with this basename in another workspace is a different conversation.
    const path = try session.sessionPath(arena, sid);
    const stat = Io.Dir.cwd().statFile(live.root.io, path, .{}) catch
        return reject(w, req, "Unknown session ID in the selected workspace");
    if (stat.kind != .file) return reject(w, req, "Unknown session ID in the selected workspace");
    const bytes = Io.Dir.cwd().readFileAlloc(live.root.io, path, arena, .limited(8 * 1024 * 1024)) catch
        return reject(w, req, "Saved session could not be loaded");
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{ .allocate = .alloc_always }) catch
        return reject(w, req, "Saved session could not be loaded");
    if (parsed != .object) return reject(w, req, "Saved session could not be loaded");
    const provider = parsed.object.get("provider") orelse return reject(w, req, "Saved session could not be loaded");
    const model = parsed.object.get("model") orelse return reject(w, req, "Saved session could not be loaded");
    const messages = parsed.object.get("messages") orelse return reject(w, req, "Saved session could not be loaded");
    if (provider != .string or model != .string or messages != .array)
        return reject(w, req, "Saved session could not be loaded");
    if (util.strFieldObj(parsed.object, "workspace")) |saved_workspace| {
        const canonical_saved = Io.Dir.cwd().realPathFileAlloc(live.root.io, saved_workspace, arena) catch saved_workspace;
        if (!session_index.sameWorkspace(canonical_saved, canonical_active))
            return reject(w, req, "Saved session belongs to another workspace");
    }
    // Flush the outgoing conversation before replacing provider-native state.
    session.saveSession(live.root, arena, live.root.session_name) catch |err| {
        return proto.writeError(w, req.id, engine.err_internal, @errorName(err));
    };
    session.loadSession(live.root, live.keys, arena, sid) catch |err| {
        return proto.writeError(w, req.id, invalid_params, if (err == error.FileNotFound) "Unknown session ID in the selected workspace" else "Saved session could not be loaded");
    };
    live.root.session_name = try arena.dupe(u8, sid);
    live.session_id = live.root.session_name;
    d.session_id = live.session_id;
    d.durable_session_id = live.session_id;
    try replayHistory(arena, live.root, w, live.session_id);
    const options = engine.configOptions(d, arena) catch |err| return proto.writeError(w, req.id, engine.err_internal, @errorName(err));
    try proto.writeResult(w, req.id, .{ .configOptions = options });
    try proto.writeAvailableCommands(w, live.session_id, proto.slashCommands());
}
