//! Clone-on-write session resume shared by the line REPL, TUI, and startup.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const providers = @import("providers.zig");
const session = @import("session.zig");
const session_discovery = @import("session_discovery.zig");
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
    workspace: []const u8 = "",
    entered: bool = false,
    enter_failed: bool = false,
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

/// `model_override` is an explicit startup `--model`, already resolved to a
/// provider by startup: see the block after loadSession for why it wins.
/// `/resume` has no such flag and passes null.
pub fn restore(root: *agent_mod.Agent, keys: *provider_mod.Keys, arena: Allocator, source_raw: []const u8, branch_raw: ?[]const u8, model_override: ?provider_mod.Provider) !Result {
    const source = try arena.dupe(u8, source_raw);
    if (!session.validSessionName(source)) return Error.InvalidSessionName;
    const branch = if (branch_raw) |raw| try arena.dupe(u8, raw) else null;
    const origin = session_discovery.enterOrigin(root, arena, source);
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
    // An explicit --model outranks the model the session file carries: the flag
    // is the user's live intent, the saved model is only what the conversation
    // last ran on. Without this the restore silently reverted the flag, so a
    // host that respawns to switch models (the desktop picker) came back up on
    // the OLD model and the switch looked like a no-op. Same precedence the
    // --goal flag gets below. `keep_context` still decides whether the restored
    // conversation is translated or dropped across a wire-format change,
    // exactly as a mid-session /model does.
    if (model_override) |p| applyModelOverride(root, arena, p);
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
    return .{
        .source = source,
        .target = root.session_name,
        .branched = branch != null,
        .workspace = origin.workspace,
        .entered = origin.kind == .entered,
        .enter_failed = origin.kind == .failed,
    };
}

/// Shared by CLI resume and ACP session/load so a host's --model respawn lands
/// on the same model through either path.
pub fn applyModelOverride(root: *agent_mod.Agent, arena: Allocator, p: provider_mod.Provider) void {
    _ = providers.applyProviderInner(root, arena, p, false) catch {};
    root.fallback_active = false; // an explicit choice, never a repaired credential
}

test "--model outranks the model a resumed session saved" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var keys: provider_mod.Keys = .{ .values = @splat("test-key") };

    var root: agent_mod.Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = &client,
        .provider = try keys.providerById("anthropic", "sonnet"),
        .messages = (try std.json.parseFromSliceLeaky(std.json.Value, arena, "[{\"role\":\"user\",\"content\":\"switch me\"}]", .{})).array,
        .subagent_provider_explicit = true,
        .sub = false,
        .label = "root",
        .out = null,
        .home = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path}),
    };
    try session.saveSessionTo(&root, arena, tmp.dir, "switch-1");
    session.flushSaves();

    // What the desktop picker does: respawn this conversation onto another
    // model with `--model <new> --resume <session>`. Before the fix the session
    // file's own model won, so the worker came back on the old one.
    const deepseek = try keys.providerById("deepseek", "deepseek-chat");
    const resumed = try restore(&root, &keys, arena, "switch-1", null, deepseek);
    try std.testing.expectEqualStrings("switch-1", resumed.target);
    try std.testing.expectEqualStrings("deepseek", root.provider.id);
    try std.testing.expectEqualStrings("deepseek-chat", root.provider.model);
    try std.testing.expectEqual(@as(usize, 1), root.messages.items.len); // the conversation rides along
    try std.testing.expect(!root.fallback_active); // an explicit choice, not failover

    // No flag: the saved model still wins, exactly as before.
    _ = try restore(&root, &keys, arena, "switch-1", null, null);
    try std.testing.expectEqualStrings("anthropic", root.provider.id);
    try std.testing.expectEqualStrings("sonnet", root.provider.model);
}
