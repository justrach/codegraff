//! ADR 0243: on the Responses wires whose backend caches the instructions as
//! one unit, the per-repo context (the project-instructions block and the
//! layout) rides as its own developer input item, ahead of the conversation,
//! so the instructions are byte-identical in every repo and turn 1 in a new
//! repo reads them from the cache. Other wires keep them in the instructions.
//!
//! ADR 0258: Gemini on the Codegraff chat wire continues each conversation on
//! the server and sends only the new turn, while the system prompt goes again
//! with every request. There the context rides as the conversation's first
//! user message instead (a developer or system message would join the system
//! prompt), so it is sent once rather than with every request.

const std = @import("std");
const Agent = @import("agent.zig").Agent;

pub const Split = struct { instructions: []const u8, context: []const u8 = "" };

/// Root turns on the ChatGPT plan and the OpenAI platform. Their backend
/// renders the tools and then the instructions, and caches the instructions
/// as one unit: a per-repo byte inside them forfeits all of it in a new repo.
pub fn eligible(self: *const Agent) bool {
    if (self.sub) return false;
    if (statefulChat(self)) return true;
    if (self.provider.kind != .responses) return false;
    for ([_][]const u8{ "codex", "chatgpt-new", "openai" }) |id| if (std.mem.eql(u8, self.provider.id, id)) return true;
    return false;
}

/// ADR 0258: the Codegraff chat wire's Gemini models, which the gateway
/// continues server-side.
pub fn statefulChat(self: *const Agent) bool {
    if (self.provider.kind != .openai or !std.mem.eql(u8, self.provider.id, "codegraff")) return false;
    const model = self.provider.model;
    const bare = model[if (std.mem.lastIndexOfScalar(u8, model, '/')) |i| i + 1 else 0..];
    return std.ascii.startsWithIgnoreCase(bare, "gemini-");
}

/// `instructions` without the per-repo blocks, and the blocks as one text, in
/// prompt order: the instructions section the prefix holds now (hot_context
/// keeps it in step with compaction folds, ADR 0208) and the layout in the
/// current base (resume may have swapped it, ADR 0109). Unchanged when the
/// agent is not eligible or neither block is present.
pub fn split(self: *Agent, instructions: []const u8) !Split {
    if (!eligible(self)) return .{ .instructions = instructions };
    const arena = self.scratchAlloc();
    var rest = instructions;
    var ctx: std.ArrayList(u8) = .empty;
    const baked = @import("hot_context.zig").bakedSection();
    const blocks = [_]?[]const u8{ if (baked.len != 0) baked else null, @import("session_prompt.zig").snapshot(self) };
    for (blocks) |maybe| {
        const block = maybe orelse continue;
        var at = std.mem.indexOf(u8, rest, block) orelse continue;
        const end = at + block.len;
        // A section composed as "\n\n" ++ section leaves with its separator.
        if (block[0] != '\n' and at >= 2 and std.mem.eql(u8, rest[at - 2 .. at], "\n\n")) at -= 2;
        rest = try std.mem.concat(arena, u8, &.{ rest[0..at], rest[end..] });
        if (ctx.items.len != 0) try ctx.appendSlice(arena, "\n\n");
        try ctx.appendSlice(arena, std.mem.trim(u8, block, "\n"));
    }
    if (ctx.items.len == 0) return .{ .instructions = instructions };
    return .{ .instructions = rest, .context = ctx.items };
}

/// ADR 0282: the offset where the per-repo blocks begin in `instructions`
/// (the same blocks `split` moves), or `instructions.len` when neither is
/// present. The Anthropic wire ends its cached system block here, so every
/// repo shares the tools + instructions prefix and only the rest is written.
pub fn staticEnd(self: *Agent, instructions: []const u8) usize {
    var end = instructions.len;
    const baked = @import("hot_context.zig").bakedSection();
    const blocks = [_]?[]const u8{ if (baked.len != 0) baked else null, @import("session_prompt.zig").snapshot(self) };
    for (blocks) |maybe| {
        const block = maybe orelse continue;
        if (block.len == 0) continue;
        var at = std.mem.indexOf(u8, instructions, block) orelse continue;
        if (block[0] != '\n' and at >= 2 and std.mem.eql(u8, instructions[at - 2 .. at], "\n\n")) at -= 2;
        end = @min(end, at);
    }
    return end;
}

/// The context as a developer message, the role ADR 0208 gives mid-session
/// context on Responses. Written with the conversation's first item only:
/// chained requests already hold it server-side.
pub fn writeItem(s: *std.json.Stringify, text: []const u8) !void {
    try s.beginObject();
    try s.objectField("type");
    try s.write("message");
    try s.objectField("role");
    try s.write("developer");
    try s.objectField("content");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("input_text");
    try s.objectField("text");
    try s.write(text);
    try s.endObject();
    try s.endArray();
    try s.endObject();
}

/// ADR 0258: the context as the chat conversation's first user message,
/// framed so the model reads it as standing context rather than a request.
pub const chat_frame = "Repository context for this session (standing instructions and layout, not a request):\n\n";

/// Gemini's implicit cache reuses a request's prefix only up to the start of
/// a later turn: the system prompt and tools alone never count, and the repo
/// context plus the first prompt is one user turn, so every new session's
/// first call read nothing from the cache. One fixed exchange ahead of the
/// context gives every session, in any repo, the same turn boundary after the
/// system prompt and tools, so a first call in a new repo reads them from the
/// cache.
pub const opening_user = "A new coding session is starting.";
pub const opening_model = "Ready.";

pub fn writeOpening(s: *std.json.Stringify) !void {
    for ([_][2][]const u8{ .{ "user", opening_user }, .{ "assistant", opening_model } }) |m| {
        try s.beginObject();
        try s.objectField("role");
        try s.write(m[0]);
        try s.objectField("content");
        try s.write(m[1]);
        try s.endObject();
    }
}

pub fn writeChatMessage(s: *std.json.Stringify, arena: std.mem.Allocator, text: []const u8) !void {
    try s.beginObject();
    try s.objectField("role");
    try s.write("user");
    try s.objectField("content");
    try s.write(try std.mem.concat(arena, u8, &.{ chat_frame, text }));
    try s.endObject();
}
