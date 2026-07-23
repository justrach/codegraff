//! Tests for main.zig (600-line goal). Reached through the `test { _ = ... }`
//! hook in main.zig, mirroring the mcp.zig pattern.

const std = @import("std");
const Io = std.Io;
const main_mod = @import("main.zig");

const Agent = main_mod.Agent;
const Keys = main_mod.Keys;
const prewarmCaBundle = main_mod.prewarmCaBundle;
const handleCommand = main_mod.handleCommand;

test "/bash slash command runs the bash tool and frees its gpa-allocated result" {
    // Regression guard for PR #38: the /bash slash handler routes through execTool, whose result.text is gpa-owned (NOT arena-owned — every other
    // caller frees it). Forgetting `defer root.gpa.free(result.text)` in handleCommand leaks on every /bash call; std.testing.allocator catches it here.
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    prewarmCaBundle(&client, gpa, io);

    var root: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = &client,
        .provider = .{
            .id = "test",
            .kind = .openai,
            .auth = .bearer,
            .url = "",
            .api_key = "",
            .model = "m",
            .context = 100_000,
        },
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "test",
        .out = null,
    };
    var keys: Keys = .{ .values = @splat(null) };
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    defer root.tools_used.deinit(gpa);
    try handleCommand(&root, &keys, arena, "/bash echo leak-guard-XYZ", &aw.writer);

    const written = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "leak-guard-XYZ") != null);
}
