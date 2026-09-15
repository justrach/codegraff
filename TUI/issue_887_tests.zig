const std = @import("std");

const app = @import("app.zig");
const chrome = @import("chrome.zig");
const engine = @import("engine.zig");
const sim = @import("sim.zig");
const theme = @import("theme.zig");

const Model = app.Model;

fn footerRow(box: []const u8) ![]const u8 {
    var it = std.mem.splitScalar(u8, box, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "╰") != null) return line;
    }
    return error.NoFooterRow;
}

test "#887 composer footer names the seat, auto-accept mode, and meters" {
    engine.g_model_name = "claude-opus-4-1";
    engine.g_model_provider = "anthropic";
    defer {
        engine.g_model_name = "";
        engine.g_model_provider = "";
    }

    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.mode = .always_approve;
    m.effort = .high;
    m.setStatus(.{
        .model = engine.g_model_name,
        .provider_id = engine.g_model_provider,
        .has_context = true,
        .tokens = 52,
        .window = 100,
        .cache_read = 19,
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const row = try footerRow(try chrome.promptBox(&m, arena.allocator(), 120));

    try std.testing.expect(std.mem.indexOf(u8, row, "anthropic/claude-opus-4-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "high") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "auto-accept") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "ctx  52%") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "cache  36%") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "always-approve") == null);
}

test "#887 composer footer does not invent context before a measured turn" {
    engine.g_model_name = "gpt-5.6";
    engine.g_model_provider = "openai";
    defer {
        engine.g_model_name = "";
        engine.g_model_provider = "";
    }

    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const row = try footerRow(try chrome.promptBox(&m, arena.allocator(), 80));

    try std.testing.expect(std.mem.indexOf(u8, row, "openai/gpt-5.6") != null);
    try std.testing.expect(std.mem.indexOf(u8, row, "ctx") == null);
    try std.testing.expect(std.mem.indexOf(u8, row, "cache") == null);
}

test "#887 simulator exposes the standing footer in a rendered frame" {
    engine.g_model_name = "gpt-5.6-codex";
    engine.g_model_provider = "openai";
    defer {
        engine.g_model_name = "";
        engine.g_model_provider = "";
    }

    var term: sim.Term = undefined;
    term.init(std.testing.allocator, 120, 24);
    defer term.deinit();
    term.model.mode = .always_approve;
    term.model.setStatus(.{
        .model = engine.g_model_name,
        .provider_id = engine.g_model_provider,
        .has_context = true,
        .tokens = 25,
        .window = 100,
        .cache_read = 20,
    });

    const screen = try term.screen();
    defer std.testing.allocator.free(screen);
    try std.testing.expect(std.mem.indexOf(u8, screen, "openai/gpt-5.6-codex") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "auto-accept") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "ctx  25%") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen, "cache  80%") != null);
}

test "#887 composer footer remains exactly one terminal row at supported widths" {
    engine.g_model_name = "grok-4";
    engine.g_model_provider = "xai";
    defer {
        engine.g_model_name = "";
        engine.g_model_provider = "";
    }

    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.setStatus(.{
        .model = engine.g_model_name,
        .provider_id = engine.g_model_provider,
        .has_context = true,
        .tokens = 9,
        .window = 100,
        .cache_read = 4,
    });

    for ([_]usize{ 40, 80, 120 }) |width| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const row = try footerRow(try chrome.promptBox(&m, arena.allocator(), width));
        try std.testing.expectEqual(width, theme.visibleLen(row));
        try std.testing.expect(std.mem.indexOfScalar(u8, row, '\n') == null);
    }
}
