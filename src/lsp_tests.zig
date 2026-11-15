const std = @import("std");
const config = @import("lsp_config.zig");
const registry_json =
    \\{"lsp":{"servers":[{"id":"fixture","command":["fixture-server","--stdio"],"extensions":[".cpp"],"language_id":"cpp","timeout_ms":1000}]}}
;

test "LSP configuration is off by default and malformed commands fail closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(!(try config.parse(a, "{}")).enabled());
    try std.testing.expect(!(try config.parse(a, "{\"lsp\":false}")).enabled());
    const registry = try config.parse(a, registry_json);
    try std.testing.expect(registry.enabled());
    try std.testing.expectEqualStrings("fixture", registry.select("src/file.cpp", null).?.id);
    try std.testing.expect(registry.select("src/file.py", null) == null);
    try std.testing.expect(registry.select("src/file.cpp", "other") == null);
    for ([_][]const u8{
        "{\"lsp\":true}",
        "{\"lsp\":{\"servers\":[{\"id\":\"bad\",\"command\":\"sh -c run\",\"extensions\":[\".cpp\"],\"language_id\":\"cpp\"}]}}",
        "{\"lsp\":{\"servers\":[{\"id\":\"bad\",\"command\":[],\"extensions\":[\".cpp\"],\"language_id\":\"cpp\"}]}}",
        "{\"lsp\":{\"servers\":[{\"id\":\"bad\",\"command\":[\"server\"],\"extensions\":[\"../cpp\"],\"language_id\":\"cpp\"}]}}",
    }) |bad| try std.testing.expectError(error.InvalidLspConfig, config.parse(a, bad));
}

test "LSP detached registration snapshots own every command and extension byte" {
    var destination = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer destination.deinit();
    var source = std.heap.ArenaAllocator.init(std.testing.allocator);
    const registry = try config.parse(source.allocator(), registry_json);
    const copy = try config.clone(destination.allocator(), registry);
    try std.testing.expect(copy.servers.ptr != registry.servers.ptr);
    try std.testing.expect(copy.servers[0].command[0].ptr != registry.servers[0].command[0].ptr);
    source.deinit();
    try std.testing.expectEqualStrings("fixture-server", copy.select("file.cpp", null).?.command[0]);
    try std.testing.expectEqualStrings("cpp", copy.servers[0].language_id);
}

test "LSP optional catalogs are absent by default and workers inherit without MCP" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const catalog = @import("lsp_catalog.zig");
    const registry = try config.parse(a, registry_json);
    try std.testing.expectEqualStrings("[]", catalog.append(a, .responses, "[]", .{}));
    inline for (.{ .openai, .anthropic, .responses, .interactions }) |kind| {
        const wire = catalog.append(a, kind, "[]", registry);
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, wire, .{});
        try std.testing.expectEqual(@as(usize, 1), parsed.array.items.len);
        var matches: usize = 0;
        for (parsed.array.items) |entry| {
            if (entry != .object) continue;
            const obj = if (entry.object.get("function")) |f| (if (f == .object) f.object else entry.object) else entry.object;
            if (obj.get("name")) |name| if (name == .string and std.mem.eql(u8, name.string, "lsp")) {
                matches += 1;
            };
        }
        try std.testing.expectEqual(@as(usize, 1), matches);
    }
    var child: @import("agent.zig").Agent = .{
        .gpa = a,
        .arena = a,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "fixture", .url = "", .api_key = "", .model = "fixture", .kind = .responses, .auth = .bearer, .context = 10000 },
        .messages = .init(a),
        .sub = true,
        .label = "fixture",
        .out = null,
        .lsp_registry = registry,
    };
    @import("worker_mcp.zig").inherit(&child);
    try std.testing.expect(std.mem.indexOf(u8, child.toolsJson(), "\"lsp\"") != null);
}

fn context(a: std.mem.Allocator) @import("tools.zig").ToolCtx {
    return .{ .gpa = a, .io = std.testing.io, .client = undefined, .provider = .{ .id = "fixture", .url = "", .api_key = "", .model = "fixture", .kind = .openai, .auth = .bearer, .context = 10000 }, .registry = null, .from_sub = false, .approvals = null, .tracer = null };
}

test "LSP execution respects inherited denial and the no-local-tools backstop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = context(a);
    const policy: @import("hard_policy.zig").Document = .{ .statements = &.{.{ .action = "tool.use", .resource = "lsp", .effect = .deny }} };
    ctx.hard_policy = &policy;
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"operation\":\"status\"}", .{});
    const blocked = try @import("lsp.zig").execute(ctx, input);
    try std.testing.expect(blocked.is_error);
    try std.testing.expect(std.mem.indexOf(u8, blocked.text, "lsp") != null);
    ctx.hard_policy = null;
    const gate = @import("no_local_tools.zig");
    const saved = gate.enabled;
    defer gate.enabled = saved;
    gate.enabled = true;
    try std.testing.expect(gate.blocks("lsp"));
    try std.testing.expect((try @import("lsp.zig").execute(ctx, input)).is_error);
}

test "LSP status never needs a server and positional queries validate before spawn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = context(a);
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"operation\":\"status\"}", .{});
    const status = try @import("lsp.zig").execute(ctx, input);
    try std.testing.expect(!status.is_error);
    try std.testing.expect(std.mem.indexOf(u8, status.text, "\"enabled\":false") != null);
    ctx.lsp_registry = try config.parse(a, registry_json);
    const bad = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"operation\":\"hover\",\"path\":\"file.cpp\",\"line\":0,\"character\":0}", .{});
    const output = try @import("lsp.zig").execute(ctx, bad);
    try std.testing.expect(output.is_error);
    try std.testing.expect(std.mem.indexOf(u8, output.text, "position") != null);
}

test "LSP config supports extended timeout_ms up to 30000 and bounded warm_ttl_ms" {
    var source = std.heap.ArenaAllocator.init(std.testing.allocator);
    var dest = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer dest.deinit();
    const warm_json =
        \\{"lsp":{"servers":[{"id":"ra","command":["rust-analyzer"],"extensions":[".rs"],"language_id":"rust","timeout_ms":25000,"warm_ttl_ms":30000}]}}
    ;
    const reg = try config.parse(source.allocator(), warm_json);
    const copy = try config.clone(dest.allocator(), reg);
    source.deinit();
    try std.testing.expectEqual(@as(u64, 25_000), copy.servers[0].timeout_ms);
    try std.testing.expectEqual(@as(u64, 30_000), copy.servers[0].warm_ttl_ms);
    for ([_][]const u8{
        "{\"lsp\":{\"servers\":[{\"id\":\"bad\",\"command\":[\"s\"],\"extensions\":[\".rs\"],\"language_id\":\"rust\",\"timeout_ms\":35000}]}}",
        "{\"lsp\":{\"servers\":[{\"id\":\"bad\",\"command\":[\"s\"],\"extensions\":[\".rs\"],\"language_id\":\"rust\",\"warm_ttl_ms\":50}]}}",
        "{\"lsp\":{\"servers\":[{\"id\":\"bad\",\"command\":[\"s\"],\"extensions\":[\".rs\"],\"language_id\":\"rust\",\"warm_ttl_ms\":300001}]}}",
        "{\"lsp\":{\"servers\":[{\"id\":\"bad\",\"command\":[\"s\"],\"extensions\":[\".rs\"],\"language_id\":\"rust\",\"warm_ttl_ms\":\"fast\"}]}}",
    }) |bad| try std.testing.expectError(error.InvalidLspConfig, config.parse(dest.allocator(), bad));
}

test "LSP folds under native_fold on root only when configured and auto-loads in plan mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fold = @import("native_fold.zig");
    const gate = @import("mcp_schema_gate.zig");
    const main_mod = @import("main.zig");
    const saved_root = config.root_enabled;
    const saved_fold = fold.enabled;
    const saved_plan = main_mod.plan_mode;
    const saved_stable = gate.g_stable_catalog;
    defer {
        config.root_enabled = saved_root;
        fold.enabled = saved_fold;
        main_mod.plan_mode = saved_plan;
        gate.g_stable_catalog = saved_stable;
        fold.clearLoadedSession();
    }
    fold.enabled = true;
    gate.g_stable_catalog = true;
    fold.clearLoadedSession();

    // Unconfigured: lsp absent from advertisedFolded and rendered root catalog.
    config.root_enabled = false;
    for (try fold.advertisedFolded(a)) |name| try std.testing.expect(!std.mem.eql(u8, name, "lsp"));

    // Configured: listed in Folded native, omitted from eager head before load, auto-loads in plan_mode.
    const reg = try config.parse(a, registry_json);
    var agent: @import("agent.zig").Agent = .{
        .gpa = a,
        .arena = a,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "fixture", .url = "", .api_key = "", .model = "fixture", .kind = .responses, .auth = .bearer, .context = 10000 },
        .messages = .init(a),
        .sub = false,
        .label = "fixture",
        .out = null,
        .tools_responses = "",
        .lsp_registry = reg,
    };
    try agent.ensureRootTools(.responses);
    try std.testing.expect(config.root_enabled);
    var listed = false;
    for (try fold.advertisedFolded(a)) |name| if (std.mem.eql(u8, name, "lsp")) {
        listed = true;
    };
    try std.testing.expect(listed);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, agent.tools_responses, .{});
    for (parsed.array.items) |entry| {
        if (entry != .object) continue;
        if (entry.object.get("name")) |n| if (n == .string) {
            try std.testing.expect(!std.mem.eql(u8, n.string, "lsp"));
        };
    }
    main_mod.plan_mode = true;
    try std.testing.expect(fold.gateExec(a, "lsp", false) == null);
    try std.testing.expect(fold.isLoaded("lsp"));
}
