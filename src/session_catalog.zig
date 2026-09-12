//! Persist schema selections, never schemas, credentials, or permission grants.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const native = @import("native_fold.zig");
const gate = @import("mcp_schema_gate.zig");
const Tool = @import("mcp.zig").Tool;

test "#867 session save load preserves the loaded catalog and clears legacy selections" {
    const session = @import("session.zig");
    const writer = @import("session_writer.zig");
    const transcript = @import("session_transcript.zig");
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    writer.resetForTest();
    defer writer.resetForTest();
    transcript.resetForTest();
    defer transcript.resetForTest();
    native.resetRlmDiscovery();
    native.clearLoadedSession();
    defer native.clearLoadedSession();
    gate.reset();
    defer gate.reset();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var keys: @import("provider.zig").Keys = .{ .values = @splat("test-key") };
    var root: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = &client,
        .provider = try keys.providerById("anthropic", "sonnet"),
        .messages = (try std.json.parseFromSliceLeaky(std.json.Value, arena, "[{\"role\":\"user\",\"content\":\"catalog regression\"}]", .{})).array,
        .sub = false,
        .label = "root",
        .out = null,
        .home = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path}),
    };
    var registry: @import("mcp.zig").Registry = undefined;
    const spec = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"type\":\"object\",\"properties\":{}}", .{});
    var tools = [_]Tool{
        .{ .server_index = 0, .original_name = "a", .qualified_name = "mcp__fixture__a", .description = "A", .input_schema = spec },
        .{ .server_index = 0, .original_name = "b", .qualified_name = "mcp__fixture__b", .description = "B", .input_schema = spec },
    };
    registry.tools = &tools;
    root.registry = &registry;
    // Save before loading schemas: unchanged messages must not suppress the next save.
    try session.saveSessionTo(&root, arena, tmp.dir, "catalog-867");
    session.flushSaves();
    native.markLoaded("webfetch");
    gate.autoLoad(arena, &tools, tools[1].qualified_name);
    native.markLoaded("skill");
    gate.autoLoad(arena, &tools, tools[0].qualified_name);
    native.showcaseRlm();
    root.invalidateRootTools();
    try root.ensureRootTools(root.provider.kind);
    const before = try arena.dupe(u8, root.toolsJson());
    try session.saveSessionTo(&root, arena, tmp.dir, "catalog-867");
    session.flushSaves();
    native.clearLoadedSession();
    gate.reset();
    root.invalidateRootTools();
    // Simulate a fresh process, then an already-materialized other session.
    try root.ensureRootTools(root.provider.kind);
    try session.loadSession(&root, &keys, arena, "catalog-867");
    try std.testing.expectEqualStrings(before, root.toolsJson());
    native.markLoaded("workflow");
    root.invalidateRootTools();
    try root.ensureRootTools(root.provider.kind);
    try session.loadSession(&root, &keys, arena, "catalog-867");
    try std.testing.expectEqualStrings(before, root.toolsJson());
    try tmp.dir.writeFile(io, .{ .sub_path = ".graff/sessions/catalog-legacy-867.session.json", .data = "{\"provider\":\"anthropic\",\"model\":\"sonnet\",\"messages\":[]}" });
    try session.loadSession(&root, &keys, arena, "catalog-legacy-867");
    try std.testing.expectEqual(@as(usize, 0), native.loadedNames().len);
    try std.testing.expect(!native.listed());
    try std.testing.expect(!gate.isLoaded(tools[0].qualified_name));
    try std.testing.expect(!gate.isLoaded(tools[1].qualified_name));
}

test "#867 malformed catalog state resets selections and validates saved names" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    native.resetRlmDiscovery();
    native.clearLoadedSession();
    defer native.clearLoadedSession();
    gate.reset();
    defer gate.reset();
    var client: std.http.Client = .{ .allocator = gpa, .io = std.testing.io };
    defer client.deinit();
    const keys: @import("provider.zig").Keys = .{ .values = @splat("test-key") };
    var root: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = std.testing.io,
        .client = &client,
        .provider = try keys.providerById("anthropic", "sonnet"),
        .messages = .init(arena),
        .sub = false,
        .label = "root",
        .out = null,
    };
    var registry: @import("mcp.zig").Registry = undefined;
    const spec = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"type\":\"object\",\"properties\":{}}", .{});
    var tools = [_]Tool{
        .{ .server_index = 0, .original_name = "current", .qualified_name = "mcp__fixture__current", .description = "Current registry schema", .input_schema = spec },
    };
    registry.tools = &tools;
    root.registry = &registry;
    for ([_][]const u8{
        "{}",
        "{\"loaded_tools\":null}",
        "{\"loaded_tools\":[]}",
        "{\"loaded_tools\":{\"native\":false,\"mcp\":{},\"rlm_showcased\":\"true\"}}",
        "{\"loaded_tools\":{\"native\":[null,7,\"unknown-tool\"],\"mcp\":[false,\"mcp__missing__tool\"],\"schemas\":{\"injected\":{}}}}",
    }) |json| {
        native.markLoaded("webfetch");
        gate.autoLoad(arena, &tools, tools[0].qualified_name);
        native.showcaseRlm();
        root.tools_anthropic = "stale";
        const saved = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
        try restore(&root, saved.object);
        try std.testing.expectEqual(@as(usize, 0), native.loadedNames().len);
        try std.testing.expect(!native.listed());
        try std.testing.expectEqualStrings("", root.tools_anthropic);
        try std.testing.expect(!gate.isLoaded("mcp__missing__tool"));
        try std.testing.expect(!gate.isLoaded(tools[0].qualified_name));
    }
    const saved = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"loaded_tools\":{\"native\":[\"webfetch\",7,\"webfetch\",\"unknown-tool\"]}}", .{});
    try restore(&root, saved.object);
    try std.testing.expectEqual(@as(usize, 1), native.loadedNames().len);
    try std.testing.expectEqualStrings("webfetch", native.loadedNames()[0]);
    const mcp_saved = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"loaded_tools":{"mcp":["mcp__missing__tool",null,"mcp__fixture__current","mcp__fixture__current"],"schemas":{"mcp__fixture__current":{"saved_schema_867_must_not_render":true}}}}
    , .{});
    try restore(&root, mcp_saved.object);
    try std.testing.expect(gate.isLoaded(tools[0].qualified_name));
    try std.testing.expect(!gate.isLoaded("mcp__missing__tool"));
    try std.testing.expectEqual(@as(usize, 1), gate.rendersForTest());
    try root.ensureRootTools(root.provider.kind);
    try std.testing.expect(std.mem.indexOf(u8, root.toolsJson(), "Current registry schema") != null);
    try std.testing.expect(std.mem.indexOf(u8, root.toolsJson(), "saved_schema_867_must_not_render") == null);
}

fn connected(root: *const Agent) []const Tool {
    return if (root.registry) |r| r.tools else &.{};
}

pub fn mixFingerprint(root: *const Agent, f: anytype) void {
    f.flag(native.listed());
    for (native.loadedNames()) |name| f.text(name);
    for (connected(root)) |tool| {
        if (gate.loadSeq(tool.qualified_name)) |seq| {
            f.text(tool.qualified_name);
            f.num(seq);
        }
    }
}

pub fn write(root: *const Agent, s: *std.json.Stringify) !void {
    try s.objectField("loaded_tools");
    try s.beginObject();
    try s.objectField("native");
    try s.write(native.loadedNames());
    try s.objectField("rlm_showcased");
    try s.write(native.listed());
    try s.objectField("mcp");
    try s.beginArray();
    // Match the existing native-first, MCP-by-sequence catalog tail.
    var previous: usize = 0;
    while (true) {
        var next: ?Tool = null;
        var best: usize = std.math.maxInt(usize);
        for (connected(root)) |tool| {
            const seq = gate.loadSeq(tool.qualified_name) orelse continue;
            if (seq > previous and seq < best) {
                next = tool;
                best = seq;
            }
        }
        const tool = next orelse break;
        try s.write(tool.qualified_name);
        previous = best;
    }
    try s.endArray();
    try s.endObject();
}

pub fn restore(root: *Agent, obj: std.json.ObjectMap) !void {
    native.clearLoadedSession();
    gate.reset();
    root.invalidateRootTools();
    const saved = obj.get("loaded_tools") orelse return;
    if (saved != .object) return;
    if (saved.object.get("rlm_showcased")) |v| {
        if (v == .bool and v.bool) native.showcaseRlm();
    }
    if (saved.object.get("native")) |names| {
        if (names == .array) for (names.array.items) |name| {
            if (name != .string or !native.isFolded(name.string)) continue;
            if (try native.findRootSpec(root.arena, name.string) != null)
                native.markLoaded(name.string);
        };
    }
    if (saved.object.get("mcp")) |names| {
        if (names == .array) for (names.array.items) |name| {
            if (name != .string) continue;
            for (connected(root)) |tool| {
                if (!std.mem.eql(u8, tool.qualified_name, name.string)) continue;
                var input: std.json.ObjectMap = .empty;
                var list: std.json.Array = .init(root.arena);
                try list.append(name);
                try input.put(root.arena, "tools", .{ .array = list });
                _ = try gate.loadInto(root.arena, connected(root), .{ .object = input });
                break;
            }
        };
    }
}
