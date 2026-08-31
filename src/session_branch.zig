//! Clone-on-write session resume shared by the line REPL, TUI, and startup.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const session = @import("session.zig");
const http_headers = @import("http_headers.zig");
const prompts = @import("prompts.zig");
const goal_flow = @import("goal_flow.zig");
const util = @import("util.zig");

pub const Error = error{
    InvalidSessionName,
    BranchMatchesSource,
    BranchAlreadyExists,
};

pub const Result = struct {
    source: []const u8,
    target: []const u8,
    branched: bool,
};

pub const Spec = struct { source: []const u8, branch: ?[]const u8 };

pub fn parseSpec(raw: []const u8) ?Spec {
    const arg = std.mem.trim(u8, raw, " \t");
    const marker = " --branch ";
    if (std.mem.endsWith(u8, arg, " --branch")) return null;
    const split = std.mem.indexOf(u8, arg, marker) orelse return .{ .source = arg, .branch = null };
    const source = std.mem.trim(u8, arg[0..split], " \t");
    const branch = std.mem.trim(u8, arg[split + marker.len ..], " \t");
    if (source.len == 0 or branch.len == 0 or std.mem.indexOf(u8, branch, marker) != null) return null;
    return .{ .source = source, .branch = branch };
}

pub fn restore(root: *agent_mod.Agent, keys: *provider_mod.Keys, arena: Allocator, source_raw: []const u8, branch_raw: ?[]const u8) !Result {
    const source = try arena.dupe(u8, source_raw);
    if (!session.validSessionName(source)) return Error.InvalidSessionName;
    const branch = if (branch_raw) |raw| try arena.dupe(u8, raw) else null;
    var reserved_path: ?[]const u8 = null;
    if (branch) |dest| {
        if (!session.validSessionName(dest)) return Error.InvalidSessionName;
        if (std.mem.eql(u8, source, dest)) return Error.BranchMatchesSource;
        if (session.sessionExists(root, arena, dest)) return Error.BranchAlreadyExists;
        try Io.Dir.cwd().createDirPath(root.io, session.sessions_dir);
        const path = try session.sessionPath(arena, dest);
        const claim = Io.Dir.cwd().createFile(root.io, path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => return Error.BranchAlreadyExists,
            else => return err,
        };
        claim.close(root.io);
        reserved_path = path;
    }
    errdefer if (reserved_path) |path| Io.Dir.cwd().deleteFile(root.io, path) catch {};

    root.ensureStoredKeys(keys);
    try session.loadSession(root, keys, arena, source);
    root.session_name = branch orelse source;
    if (branch) |dest| {
        root.session_parent = source;
        _ = http_headers.renewSessionId(root.io);
        try session.saveSession(root, arena, dest);
        reserved_path = null;
    }
    prompts.resetSessionCompacted(root, arena);
    if (root.goal_flag) |g| {
        root.pending_goal_note = goal_flow.reapplyFlagGoal(arena, root, g, util.unixMs(root.io)) catch null;
        prompts.pinStandingGoal(root, arena);
    }
    return .{ .source = source, .target = root.session_name, .branched = branch != null };
}
