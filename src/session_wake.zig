//! One-line user-role inject used by job_notify, schedule, and channel
//! workers. Same shape as a finished-job wake: history + session_notice.

const std = @import("std");

const agent_mod = @import("agent.zig");
const engine_sink = @import("engine_sink.zig");
const Agent = agent_mod.Agent;

pub fn inject(root: *Agent, text: []const u8) void {
    if (root.sub or text.len == 0) return;
    const owned = root.arena.dupe(u8, text) catch return;
    root.messages.append(message(root.arena, owned) catch return) catch return;
    engine_sink.forAgent(root).emit(root.io, .{ .session_notice = .{ .text = owned, .tone = .dim } });
}

/// Persisted provenance, never a provider API field. Text is not an identity.
pub const origin_key = "_graff_origin";
pub fn isNotice(m: std.json.Value) bool {
    if (m != .object) return false;
    const v = m.object.get(origin_key) orelse return false;
    return v == .string and std.mem.eql(u8, v.string, "notification");
}
pub fn message(a: std.mem.Allocator, text: []const u8) !std.json.Value {
    return mark(a, try @import("messages.zig").textMessage(a, "user", text));
}
pub fn typedMessage(a: std.mem.Allocator, kind: @import("provider.zig").Provider.Kind, text: []const u8) !std.json.Value {
    return mark(a, if (kind == .interactions)
        try @import("interactions_steps.zig").userInput(a, text)
    else
        try @import("messages.zig").textMessage(a, "user", text));
}
pub fn mark(a: std.mem.Allocator, source: std.json.Value) !std.json.Value {
    var m = source;
    try m.object.put(a, origin_key, .{ .string = "notification" });
    return m;
}
pub fn copyOrigin(a: std.mem.Allocator, source: std.json.Value, dest: std.json.Value) !std.json.Value {
    var m = dest;
    if (isNotice(source) and m == .object) try m.object.put(a, origin_key, .{ .string = "notification" });
    return m;
}
/// Preserve provider-native fields and ordering, excluding only our provenance.
pub fn writeWire(s: *std.json.Stringify, m: std.json.Value) !void {
    if (m != .object) return s.write(m);
    try s.beginObject();
    var it = m.object.iterator();
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.key_ptr.*, origin_key)) continue;
        try s.objectField(kv.key_ptr.*);
        try s.write(kv.value_ptr.*);
    }
    try s.endObject();
}
/// writeWire for a Responses request `input`. grok (xAI family) drops reasoning
/// items: their `encrypted_content` blobs only decrypt inside a live chain (ADR
/// 0002), and grok rides full-resend over the held socket, so replaying a blob
/// fails with xAI's "Could not decrypt the provided encrypted_content". Writing
/// nothing omits the item from the enclosing array. grok reasoning is blob-only
/// (no summary), so dropping it costs no readable context — the blob was never
/// decryptable cross-request anyway.
pub fn writeWireInput(s: *std.json.Stringify, m: std.json.Value, model: []const u8) !void {
    if (dropReasoningFor(model, m)) return;
    try writeWire(s, m);
}

fn dropReasoningFor(model: []const u8, m: std.json.Value) bool {
    if (!@import("effort_route.zig").grokFamily(model)) return false;
    if (m != .object) return false;
    const t = m.object.get("type") orelse return false;
    return t == .string and std.mem.eql(u8, t.string, "reasoning");
}

pub fn writeWireArray(s: *std.json.Stringify, items: []const std.json.Value) !void {
    try s.beginArray();
    for (items) |m| try writeWire(s, m);
    try s.endArray();
}

test "inject is a no-op on subagents" {
    var root: Agent = undefined;
    root.sub = true;
    root.messages = std.json.Array.init(std.testing.allocator);
    inject(&root, "hi");
    try std.testing.expectEqual(@as(usize, 0), root.messages.items.len);
}

test "inject appends a user-role line on the root" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const drop = struct {
        fn emit(_: *anyopaque, _: engine_sink.Stamped) void {}
    };
    const vt = engine_sink.VTable{ .emit = drop.emit, .durable = false };
    var root: Agent = undefined;
    root.sub = false;
    root.arena = arena_state.allocator();
    root.messages = std.json.Array.init(arena_state.allocator());
    root.sink = .{ .ctx = undefined, .vt = &vt };
    inject(&root, "wake up");
    try std.testing.expectEqual(@as(usize, 1), root.messages.items.len);
    try std.testing.expect(isNotice(root.messages.items[0]));
    try std.testing.expectEqualStrings("user", root.messages.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("wake up", root.messages.items[0].object.get("content").?.string);
}

test "notification provenance survives saved JSON and conversation adoption without claiming identical user text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var cv = @import("repl_convo.zig").Conversation.init(std.testing.allocator);
    defer cv.deinit();
    try cv.adopt(&.{.{ .role = .user, .text = "wake up", .notification = true }});
    try cv.adopt(&.{.{ .role = .user, .text = "wake up" }});
    try std.testing.expectEqual(@as(usize, 2), cv.len());
    const saved = try @import("session_peer.zig").messagesForSave(a, cv.list().items);
    var aw: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(std.json.Value{ .array = saved });
    const restored = try std.json.parseFromSliceLeaky(std.json.Value, a, aw.written(), .{});
    try std.testing.expect(isNotice(restored.array.items[0]));
    try std.testing.expect(!@import("session_peer.zig").isHumanUserTurn(restored.array.items[0]));
    try std.testing.expect(!isNotice(restored.array.items[1]));
    const turns = try @import("tui_session.zig").visibleTurns(a, restored.array);
    try std.testing.expect(turns[0].notification);
    try std.testing.expect(!turns[1].notification);
}

test "notification metadata stays off chat, responses and anthropic wires including cache branches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const m = try message(a, "wake up");
    var msgs = std.json.Array.init(a);
    try msgs.append(m);
    try msgs.append(m); // exercise both the prefix and final cache breakpoint
    const serde = @import("serde.zig");
    for (0..6) |mode| {
        var aw: std.Io.Writer.Allocating = .init(a);
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        if (mode == 0) try writeWireArray(&s, msgs.items) else if (mode == 1)
            try serde.writeOpenAIMessageNormalized(&s, m)
        else
            try serde.writeAnthropicMessages(&s, msgs, mode & 1 == 1, mode & 2 == 2);
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), origin_key) == null);
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "wake up") != null);
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"role\":\"user\"") != null);
    }
    try std.testing.expect(isNotice(m)); // serialization must not mutate the saved object
}

test "internal notes retain provenance and do not replace the human request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const messages = @import("messages.zig");
    for ([_]@import("provider.zig").Provider.Kind{ .openai, .responses, .anthropic, .interactions }) |kind| {
        const human = try @import("named_work.zig").userNudge(a, kind, "Explain parser.zig");
        const note = try messages.userNote(a, kind, "Internal completion reminder");
        try std.testing.expect(!isNotice(human));
        try std.testing.expect(isNotice(note));
        try std.testing.expectEqualStrings("Explain parser.zig", messages.latestUserText(&.{ human, note }));
        var aw: std.Io.Writer.Allocating = .init(a);
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        try writeWire(&s, note);
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), origin_key) == null);
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), "Internal completion reminder") != null);
        if (kind == .interactions) try std.testing.expectEqualStrings("user_input", note.object.get("type").?.string);
    }
}
