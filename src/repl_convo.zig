//! The chat session's conversation, owned by the ENGINE (#551).
//!
//! Before this file the TUI rebuilt the model's history out of its own
//! rendered rows every turn: `.user`/`.assistant` text only, every tool row
//! dropped, into a throwaway Agent. So the model never saw the tool_use /
//! tool_result blocks from its own previous turns — it could not remember what
//! it had read or run — and because the prefix was re-materialized each time,
//! prompt caching had nothing stable to hit.
//!
//! Now the conversation lives here for the life of the session, exactly as
//! mainloop's root agent keeps `root.messages`, and the frontend's transcript
//! is a PROJECTION of it. The per-turn Agent borrows these messages and hands
//! them back, so assistant turns and tool blocks accumulate in place.
//!
//! Allocation: message content must outlive the turn that created it, so this
//! owns a dedicated arena and the turn agent uses it as its `arena` (the
//! allocator `messageMutationAlloc` writes provider responses into). Per-turn
//! parse garbage goes to the agent's `scratch_arena`, which is reset per
//! request — the same split the root agent has had since #124.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const messages_mod = @import("messages.zig");
const repl = @import("repl.zig");

pub const Conversation = struct {
    arena: std.heap.ArenaAllocator,
    /// Initialized lazily by `list()`: the arena's allocator embeds a pointer
    /// to the arena, so nothing may allocate from it until the Conversation
    /// has settled at its final address.
    messages: std.json.Array = undefined,
    live: bool = false,

    pub fn init(gpa: Allocator) Conversation {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    }

    pub fn deinit(self: *Conversation) void {
        self.arena.deinit();
    }

    pub fn alloc(self: *Conversation) Allocator {
        return self.arena.allocator();
    }

    pub fn list(self: *Conversation) *std.json.Array {
        if (!self.live) {
            self.messages = std.json.Array.init(self.arena.allocator());
            self.live = true;
        }
        return &self.messages;
    }

    pub fn len(self: *Conversation) usize {
        return if (self.live) self.messages.items.len else 0;
    }

    /// `/new` and `/clear`: the session starts over, and the memory goes with
    /// it. Everything the old messages pointed at lived in this arena.
    pub fn reset(self: *Conversation) void {
        _ = self.arena.reset(.free_all);
        self.live = false;
    }

    /// `/rewind`: drop back to just before the last human prompt, so the
    /// engine's history matches the transcript the frontend just truncated.
    /// A tool result is a user-role message with ARRAY content, so it is never
    /// mistaken for the prompt.
    pub fn rewind(self: *Conversation) void {
        if (!self.live) return;
        var i = self.messages.items.len;
        while (i > 0) {
            i -= 1;
            if (isUserPrompt(self.messages.items[i])) {
                self.messages.shrinkRetainingCapacity(i);
                return;
            }
        }
        self.messages.clearRetainingCapacity();
    }

    /// Fold the frontend's flattened transcript into the session conversation.
    /// An empty conversation adopts all of it — the first turn, or a transcript
    /// replayed after a compaction. A live one takes only the trailing user
    /// message: everything before it is already here, in richer form than the
    /// frontend could hand back.
    pub fn adopt(self: *Conversation, history: []const repl.Turn) !void {
        const msgs = self.list();
        if (msgs.items.len == 0) {
            for (history) |t| try msgs.append(try textOf(self.alloc(), t));
            return;
        }
        if (history.len == 0) return;
        const last = history[history.len - 1];
        if (last.role != .user) return;
        try msgs.append(try textOf(self.alloc(), last));
    }

    /// Put a line into the conversation that the model did not produce and did
    /// not ask for — a `!cmd` the user ran, and what it printed. The model has
    /// to see it: the user is talking about that output on the next turn.
    pub fn note(self: *Conversation, text: []const u8) !void {
        const msgs = self.list();
        try msgs.append(try messages_mod.textMessage(self.alloc(), "user", text));
    }

    /// Replace the whole conversation (compaction rewrote it). The messages
    /// must already be allocated from this conversation's arena.
    pub fn replace(self: *Conversation, rewritten: []const Value) !void {
        const msgs = self.list();
        msgs.clearRetainingCapacity();
        try msgs.appendSlice(rewritten);
    }
};

fn textOf(a: Allocator, t: repl.Turn) !Value {
    return messages_mod.textMessage(a, switch (t.role) {
        .user => "user",
        .assistant => "assistant",
    }, t.text);
}

fn isUserPrompt(v: Value) bool {
    if (v != .object) return false;
    const role = v.object.get("role") orelse return false;
    if (role != .string or !std.mem.eql(u8, role.string, "user")) return false;
    const content = v.object.get("content") orelse return false;
    return content == .string;
}

const testing = std.testing;

fn roleOf(v: Value) []const u8 {
    return v.object.get("role").?.string;
}

test "adopt takes the whole transcript once, then only the new prompt" {
    var convo = Conversation.init(testing.allocator);
    defer convo.deinit();

    // Turn 1: nothing here yet, so the frontend's transcript seeds it.
    try convo.adopt(&.{.{ .role = .user, .text = "one" }});
    try testing.expectEqual(@as(usize, 1), convo.len());

    // The engine then writes what only it knows: a tool call and its result.
    const msgs = convo.list();
    try msgs.append(try messages_mod.textMessage(convo.alloc(), "assistant", "TOOL_USE_BLOCK"));

    // Turn 2: the frontend hands back its flattened rows. The tool block must
    // survive, and "one" must not be duplicated.
    try convo.adopt(&.{
        .{ .role = .user, .text = "one" },
        .{ .role = .assistant, .text = "answer" },
        .{ .role = .user, .text = "two" },
    });
    try testing.expectEqual(@as(usize, 3), convo.len());
    try testing.expectEqualStrings("TOOL_USE_BLOCK", msgs.items[1].object.get("content").?.string);
    try testing.expectEqualStrings("two", msgs.items[2].object.get("content").?.string);
}

test "reset clears the conversation; rewind drops back to before the last prompt" {
    var convo = Conversation.init(testing.allocator);
    defer convo.deinit();
    try convo.adopt(&.{.{ .role = .user, .text = "first" }});
    const msgs = convo.list();
    try msgs.append(try messages_mod.textMessage(convo.alloc(), "assistant", "reply"));
    try convo.adopt(&.{ .{ .role = .user, .text = "first" }, .{ .role = .assistant, .text = "reply" }, .{ .role = .user, .text = "second" } });
    try testing.expectEqual(@as(usize, 3), convo.len());

    convo.rewind();
    try testing.expectEqual(@as(usize, 2), convo.len());
    try testing.expectEqualStrings("assistant", roleOf(convo.list().items[1]));

    convo.reset();
    try testing.expectEqual(@as(usize, 0), convo.len());
    // Usable again after a reset — the arena was freed, not poisoned.
    try convo.adopt(&.{.{ .role = .user, .text = "fresh" }});
    try testing.expectEqual(@as(usize, 1), convo.len());
    try testing.expectEqualStrings("fresh", convo.list().items[0].object.get("content").?.string);
}

test "a tool result is not mistaken for the human prompt on rewind" {
    var convo = Conversation.init(testing.allocator);
    defer convo.deinit();
    try convo.adopt(&.{.{ .role = .user, .text = "run it" }});
    const a = convo.alloc();
    const msgs = convo.list();
    try msgs.append(try messages_mod.textMessage(a, "assistant", "calling"));
    // Anthropic wraps a tool_result in a USER message whose content is an array.
    var blocks = std.json.Array.init(a);
    try blocks.append(try messages_mod.toolResultMessage(a, .anthropic, "id-1", "ok", false));
    var wrapper: std.json.ObjectMap = .empty;
    try wrapper.put(a, "role", .{ .string = "user" });
    try wrapper.put(a, "content", .{ .array = blocks });
    try msgs.append(.{ .object = wrapper });

    convo.rewind();
    // Back to before "run it" — not to just before the tool result.
    try testing.expectEqual(@as(usize, 0), convo.len());
}
