//! Durable-session projection for the fullscreen in-process ACP client.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const agent_mod = @import("agent.zig");
const repl_glue = @import("repl_glue.zig");
const session = @import("session.zig");
const session_branch = @import("session_branch.zig");
const tui = @import("tui");

pub fn seed(convo: *repl_glue.Conversation, root: *agent_mod.Agent) !void {
    try convo.seed(root.messages);
}

pub fn syncRoot(convo: *repl_glue.Conversation, root: *agent_mod.Agent) !void {
    root.messages = try convo.cloneInto(root.arena);
}

pub fn visibleTurns(arena: Allocator, messages: std.json.Array) ![]tui.Turn {
    var turns: std.ArrayList(tui.Turn) = .empty;
    for (messages.items) |message| {
        const role = visibleRole(message) orelse continue;
        const text = try visibleText(arena, message);
        if (text.len == 0) continue;
        try turns.append(arena, .{ .role = role, .text = text });
    }
    return try turns.toOwnedSlice(arena);
}

fn visibleRole(message: Value) ?tui.Turn.Role {
    if (message != .object) return null;
    const role = message.object.get("role") orelse return null;
    if (role != .string) return null;
    if (std.mem.eql(u8, role.string, "user")) {
        if (message.object.get("content")) |content| if (content == .array) for (content.array.items) |block| {
            if (block != .object) continue;
            const ty = block.object.get("type") orelse continue;
            if (ty == .string and std.mem.eql(u8, ty.string, "tool_result")) return null;
        };
        return .user;
    }
    if (std.mem.eql(u8, role.string, "assistant")) return .assistant;
    return null;
}

fn visibleText(arena: Allocator, message: Value) ![]const u8 {
    const content = message.object.get("content") orelse return "";
    if (content == .string) return arena.dupe(u8, content.string);
    if (content != .array) return "";
    var out: std.ArrayList(u8) = .empty;
    for (content.array.items) |block| {
        if (block != .object) continue;
        const text = block.object.get("text") orelse continue;
        if (text != .string or text.string.len == 0) continue;
        if (out.items.len > 0) try out.append(arena, '\n');
        try out.appendSlice(arena, text.string);
    }
    return try out.toOwnedSlice(arena);
}

fn failure(gpa: Allocator, out: *tui.ResumeOut, err: anyerror) bool {
    out.note = std.fmt.allocPrint(gpa, "resume failed: {t}", .{err}) catch &.{};
    return false;
}

pub fn resumeCb(ctx_ptr: ?*anyopaque, gpa: Allocator, raw: []const u8, out: *tui.ResumeOut) bool {
    const ctx: *repl_glue.ReplCtx = @ptrCast(@alignCast(ctx_ptr orelse return failure(gpa, out, error.NoSession)));
    const root = ctx.root orelse return failure(gpa, out, error.NoSession);
    const spec = session_branch.parseSpec(raw) orelse return failure(gpa, out, error.InvalidSessionName);
    if (spec.source.len == 0) return failure(gpa, out, error.InvalidSessionName);

    if (ctx.convo) |convo| {
        syncRoot(convo, root) catch |err| return failure(gpa, out, err);
        session.saveSession(root, root.arena, root.session_name) catch |err| return failure(gpa, out, err);
    }
    const resumed = session_branch.restore(root, &ctx.keys, root.arena, spec.source, spec.branch) catch |err| return failure(gpa, out, err);
    if (ctx.convo) |convo| seed(convo, root) catch |err| return failure(gpa, out, err);
    ctx.provider = root.provider;
    ctx.last_context_tokens = root.last_context_tokens;
    ctx.context_local_tokens = root.context_local_tokens;
    ctx.last_cache_read = root.last_cache_read;
    tui.setCurrentModel(root.provider.model, root.provider.id);
    out.turns = visibleTurns(gpa, root.messages) catch |err| return failure(gpa, out, err);
    out.session_name = gpa.dupe(u8, resumed.target) catch return failure(gpa, out, error.OutOfMemory);
    out.goal = if (root.goal) |goal| gpa.dupe(u8, goal.objective) catch return failure(gpa, out, error.OutOfMemory) else "";
    out.strict = root.strict;
    out.ultracode = root.ultracode_mode;
    out.note = if (resumed.branched)
        std.fmt.allocPrint(gpa, "branched {s} → {s}", .{ resumed.source, resumed.target }) catch &.{}
    else
        std.fmt.allocPrint(gpa, "resumed {s}", .{resumed.source}) catch &.{};
    return true;
}

test "visible turns keep human text and omit provider tool envelopes" {
    const arena = std.testing.allocator;
    var messages = std.json.Array.init(arena);
    defer messages.deinit();
    var user: std.json.ObjectMap = .empty;
    defer user.deinit(arena);
    try user.put(arena, "role", .{ .string = "user" });
    try user.put(arena, "content", .{ .string = "baseline" });
    try messages.append(.{ .object = user });
    var tool_result: std.json.ObjectMap = .empty;
    defer tool_result.deinit(arena);
    try tool_result.put(arena, "type", .{ .string = "tool_result" });
    try tool_result.put(arena, "content", .{ .string = "secret tool output" });
    var tool_content = std.json.Array.init(arena);
    defer tool_content.deinit();
    try tool_content.append(.{ .object = tool_result });
    var provider_user: std.json.ObjectMap = .empty;
    defer provider_user.deinit(arena);
    try provider_user.put(arena, "role", .{ .string = "user" });
    try provider_user.put(arena, "content", .{ .array = tool_content });
    try messages.append(.{ .object = provider_user });
    const turns = try visibleTurns(arena, messages);
    defer arena.free(turns);
    defer arena.free(turns[0].text);
    try std.testing.expectEqual(@as(usize, 1), turns.len);
    try std.testing.expectEqualStrings("baseline", turns[0].text);
}
