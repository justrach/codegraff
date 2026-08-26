//! The `--json` control fields mainloop applies inline: a request that changes
//! state, or answers something, WITHOUT becoming a turn.
//!
//! Split out of mainloop.zig, which sits at the 600-line ceiling (AGENTS.md),
//! so #415's `{"type":"btw"}` had somewhere to land. The per-request tool knobs
//! moved with it because they are the same shape — a field read off the parsed
//! request and applied on the spot — and moving them is what made the room.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const json_inbox = @import("json_inbox.zig");
const main_mod = @import("main.zig");
const side_question = @import("side_question.zig");
const remote_images = @import("remote_images.zig");

/// `{"type":"btw","text":"…"}` — #415's side question, the GUI's half of the
/// feature. True when the request WAS a side question and is now fully
/// answered, so the caller must not go on to run a turn for it.
///
/// `text` is the caller's already-validated non-empty text field. The answer
/// event carries `persisted:false` explicitly: a client that logs the stream
/// must be able to tell this apart from an ordinary assistant turn, because
/// the session it is mirroring does not contain it.
pub fn sideQuestion(root: *Agent, arena: Allocator, rtype: []const u8, text: []const u8) bool {
    if (!std.mem.eql(u8, rtype, "btw")) return false;
    if (side_question.ask(root, arena, text)) |answer| {
        root.emit(.{ .type = "btw", .ok = true, .text = answer.text, .persisted = false, .cache_read_tokens = answer.cache_read });
    } else {
        root.emit(.{ .type = "error", .message = "side question failed; the conversation is unchanged" });
    }
    return true;
}

/// The per-request tool ceilings, in both the camelCase the GUI sends and the
/// snake_case the CLI's own JSON uses. An explicit `null` clears the ceiling;
/// anything else is ignored rather than guessed at.
pub fn applyToolKnobs(obj: std.json.ObjectMap) void {
    if (obj.get("maxToolCalls") orelse obj.get("max_tool_calls")) |v| switch (v) {
        .integer => |n| main_mod.max_tool_calls = if (n >= 0) @intCast(n) else null,
        .null => main_mod.max_tool_calls = null,
        else => {},
    };
    if (obj.get("dedupeToolCalls") orelse obj.get("dedupe_tool_calls")) |v| {
        if (v == .bool) main_mod.dedupe_tool_calls = v.bool;
    }
}

/// Turn-scoped JSON options: tool ceilings plus native image parts. False
/// means image validation already emitted the request error.
pub fn applyTurnOptions(root: *Agent, obj: std.json.ObjectMap) bool {
    if (!remote_images.stage(root, obj)) return false;
    applyToolKnobs(obj);
    return true;
}

/// Claim the dequeued JSON turn, then validate and stage all of its options.
/// A rejected request releases inbox ownership before the next request.
pub fn beginTurn(root: *Agent, obj: std.json.ObjectMap) bool {
    if (!json_inbox.beginTurn(root)) return false;
    if (applyTurnOptions(root, obj)) return true;
    json_inbox.endTurn();
    return false;
}

pub fn rejectTurn(root: *Agent, message: []const u8) void {
    root.emit(.{ .type = "error", .message = message });
    json_inbox.endTurn();
}

test "applyToolKnobs reads both spellings and ignores junk" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Process-wide knobs: restore them or the next test inherits this one's.
    const max_before = main_mod.max_tool_calls;
    const dedupe_before = main_mod.dedupe_tool_calls;
    defer main_mod.max_tool_calls = max_before;
    defer main_mod.dedupe_tool_calls = dedupe_before;

    const camel = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"maxToolCalls":7,"dedupeToolCalls":true}
    , .{});
    applyToolKnobs(camel.object);
    try std.testing.expectEqual(@as(?u64, 7), main_mod.max_tool_calls);
    try std.testing.expect(main_mod.dedupe_tool_calls);

    const snake = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"max_tool_calls":null,"dedupe_tool_calls":false}
    , .{});
    applyToolKnobs(snake.object);
    try std.testing.expect(main_mod.max_tool_calls == null);
    try std.testing.expect(!main_mod.dedupe_tool_calls);

    // A wrong-typed knob leaves the current value alone rather than resetting it.
    main_mod.max_tool_calls = 3;
    const junk = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"maxToolCalls":"lots","dedupeToolCalls":"yes"}
    , .{});
    applyToolKnobs(junk.object);
    try std.testing.expectEqual(@as(?u64, 3), main_mod.max_tool_calls);
    try std.testing.expect(!main_mod.dedupe_tool_calls);
}

test "sideQuestion claims only its own control type" {
    // `root` is undefined on purpose: a case that reached the agent would be a
    // case that made a network call, and this one must not.
    var root: Agent = undefined;
    try std.testing.expect(!sideQuestion(&root, std.testing.allocator, "review", "look at HEAD"));
    try std.testing.expect(!sideQuestion(&root, std.testing.allocator, "user", "btw"));
    try std.testing.expect(!sideQuestion(&root, std.testing.allocator, "", "anything"));
}
