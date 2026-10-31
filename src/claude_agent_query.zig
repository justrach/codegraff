//! Claude Agent one-shot query (ADR 0309): a tools-off completion made
//! without an Agent, such as rlm's `llm_query`. Claude Agent has no HTTP
//! endpoint, so the Messages body runs on a throwaway `claude` process, the
//! way titles and recaps do. The chat's held session (keyed by its Agent in
//! claude_agent_session.zig) is never taken, so its process and prompt cache
//! carry on untouched.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const Provider = @import("provider.zig").Provider;
const Tracer = @import("trace.zig").Tracer;
const agent = @import("claude_agent.zig");
const wire = @import("claude_agent_wire.zig");
const history = @import("claude_agent_history.zig");

/// Without a system prompt Claude Code would run its own coding-agent prompt.
const default_system = "Answer the request directly. You have no tools.";

/// gpa-owned: a Messages response (`{"content":[{"type":"text",...}]}`), or
/// a problem the caller shows as is.
pub const Reply = union(enum) {
    message: []u8,
    problem: []u8,

    pub fn deinit(self: Reply, gpa: Allocator) void {
        switch (self) {
            inline else => |bytes| gpa.free(bytes),
        }
    }
};

pub const Options = struct {
    cwd: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    tracer: ?*Tracer = null,
};

/// Run one Messages request body (`system`, `messages`; any `tools` ignored)
/// on a new `claude` process and stop it afterwards.
pub fn post(gpa: Allocator, io: Io, provider: Provider, body: []const u8, opts: Options) !Reply {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const req = try std.json.parseFromSliceLeaky(Value, a, body, .{ .allocate = .alloc_always });
    if (req != .object) return error.ClaudeAgentBadRequest;
    const messages = req.object.get("messages") orelse return error.ClaudeAgentBadRequest;
    if (messages != .array) return error.ClaudeAgentBadRequest;
    const given = try history.textOf(a, req.object.get("system"));
    const system = if (given.len > 0) given else default_system;
    const exe = if (provider.api_key.len > 0) provider.api_key else "claude";
    const spawn: wire.Spawn = .{ .exe = exe, .model = wire.modelArg(provider.model), .effort = opts.effort, .has_tools = false };
    const owner: agent.Owner = .{ .gpa = gpa, .io = io, .cwd = opts.cwd, .tracer = opts.tracer, .note = "started (llm_query)" };
    const s = agent.open(owner, a, spawn, .graff, system, null, 0, false) catch |e| switch (e) {
        error.Interrupted => return e,
        else => return .{ .problem = try gpa.dupe(u8, agent.startProblem(e)) },
    };
    defer s.stop();
    try s.send(try wire.userLine(a, try history.freshContent(a, messages.array.items)));

    var text: std.ArrayList(u8) = .empty;
    while (true) {
        switch (try wire.classify(a, try s.readLine(false, agent.turn_budget_ms))) {
            .event => |ev| {
                const kind = wire.strField(ev.object, "type") orelse "";
                // Keep only the last response's text, as the chat path does.
                if (std.mem.eql(u8, kind, "message_start")) text.clearRetainingCapacity();
                if (deltaText(ev)) |t| try text.appendSlice(a, t);
            },
            .control => |c| try agent.service(s, a, c, null),
            .result => |r| {
                if (r.is_error) return .{ .problem = try gpa.dupe(u8, try agent.problem(a, r.text)) };
                return .{ .message = try messageJson(gpa, if (text.items.len > 0) text.items else r.text) };
            },
            .cancel, .response, .ignore => {},
        }
    }
}

/// The text of a `content_block_delta` carrying a `text_delta`.
fn deltaText(ev: Value) ?[]const u8 {
    if (ev != .object) return null;
    if (!std.mem.eql(u8, wire.strField(ev.object, "type") orelse "", "content_block_delta")) return null;
    const d = ev.object.get("delta") orelse return null;
    if (d != .object or !std.mem.eql(u8, wire.strField(d.object, "type") orelse "", "text_delta")) return null;
    return wire.strField(d.object, "text");
}

/// A minimal Messages response carrying `text`, for title.assistantText.
fn messageJson(gpa: Allocator, text: []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("type");
    try s.write("message");
    try s.objectField("role");
    try s.write("assistant");
    try s.objectField("content");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("text");
    try s.objectField("text");
    try s.write(text);
    try s.endObject();
    try s.endArray();
    try s.endObject();
    return aw.toOwnedSlice();
}

test "claude agent query reads streamed text deltas and wraps them as a Messages reply" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const line = "{\"type\":\"stream_event\",\"parent_tool_use_id\":null,\"event\":{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"4\\\"2\"}}}";
    const ev = (try wire.classify(a, line)).event;
    try std.testing.expectEqualStrings("4\"2", deltaText(ev).?);
    const thinking = try std.json.parseFromSliceLeaky(Value, a, "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"hm\"}}", .{});
    try std.testing.expect(deltaText(thinking) == null);
    const json = try messageJson(gpa, "4\"2");
    defer gpa.free(json);
    const parsed = try std.json.parseFromSliceLeaky(Value, a, json, .{});
    try std.testing.expectEqualStrings("4\"2", @import("title.zig").assistantText(.anthropic, parsed.object));
}
