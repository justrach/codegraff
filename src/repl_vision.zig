//! TUI / `graff repl` history → provider messages.
//!
//! The line REPL goes through mainloop, which stages `@[path]` markers as a
//! real vision block. The TUI hosted path (`repl_glue.replTurnCb`) used to
//! copy every turn as a text string, so grok-4.6 (a VLM) only ever saw
//! `@[/tmp/….png] go on` and tried to OCR it with bash/codedb.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const vision = @import("vision.zig");
const textMessage = @import("messages.zig").textMessage;

/// Append one history turn. A user turn that names a readable image via
/// `@[path]` becomes text + image_url (or Anthropic image / Responses
/// input_image). Everything else stays a plain string.
pub fn appendTurn(agent: *Agent, role: []const u8, text: []const u8) !void {
    if (std.mem.eql(u8, role, "user")) {
        vision.stageGuiImageAttachment(agent, text);
        if (agent.pending_image) |img| {
            try agent.messages.append(try vision.imageMessage(agent.arena, agent.provider.kind, text, img));
            agent.pending_image = null;
            return;
        }
    }
    try agent.messages.append(try textMessage(agent.arena, role, text));
}

test "appendTurn: @[png] becomes an openai image_url block for grok-4.6" {
    const testing = std.testing;
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const png = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xde, 0x00, 0x00, 0x00,
        0x0c, 0x49, 0x44, 0x41, 0x54, 0x08, 0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0x00,
        0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xdd, 0x8d, 0xb0, 0x00, 0x00, 0x00,
        0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    };
    const path = "TUI/testdata-vision-1x1.png";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &png });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var agent: Agent = undefined;
    agent.gpa = testing.allocator;
    agent.arena = arena;
    agent.io = io;
    agent.provider = .{
        .id = "xai",
        .kind = .openai,
        .auth = .bearer,
        .url = "",
        .model = "grok-4.6",
        .context = 0,
        .api_key = "",
        .account = "",
    };
    agent.messages = std.json.Array.init(arena);
    agent.pending_image = null;
    agent.registry = null;

    const prompt = try std.fmt.allocPrint(arena, "@[{s}] go on", .{path});
    try appendTurn(&agent, "user", prompt);
    try testing.expectEqual(@as(usize, 1), agent.messages.items.len);
    const msg = agent.messages.items[0];
    try testing.expect(msg == .object);
    const content = msg.object.get("content").?;
    try testing.expect(content == .array);
    try testing.expectEqual(@as(usize, 2), content.array.items.len);
    try testing.expectEqualStrings("image_url", content.array.items[1].object.get("type").?.string);
    const url = content.array.items[1].object.get("image_url").?.object.get("url").?.string;
    try testing.expect(std.mem.startsWith(u8, url, "data:image/png;base64,"));

    try appendTurn(&agent, "assistant", "ok");
    try testing.expect(agent.messages.items[1].object.get("content").? == .string);
}

test "appendTurn: a missing @[path] stays text so a bad chip does not drop the prompt" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent: Agent = undefined;
    agent.gpa = testing.allocator;
    agent.arena = arena;
    agent.io = testing.io;
    agent.provider = .{
        .id = "xai",
        .kind = .openai,
        .auth = .bearer,
        .url = "",
        .model = "grok-4.6",
        .context = 0,
        .api_key = "",
        .account = "",
    };
    agent.messages = std.json.Array.init(arena);
    agent.pending_image = null;
    agent.registry = null;
    try appendTurn(&agent, "user", "@[/no/such/shot.png] what is this");
    try testing.expect(agent.messages.items[0].object.get("content").? == .string);
}
