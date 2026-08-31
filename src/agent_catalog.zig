//! Root/worker tool-catalog materialization. Split out of agent.zig (600-line ceiling).

const std = @import("std");
const Allocator = std.mem.Allocator;
const main_mod = @import("main.zig");
const schema = @import("schema.zig");
const no_local_tools = @import("no_local_tools.zig");
const surface = @import("tool_surface.zig");
const mcp = @import("mcp.zig");
const Provider = @import("provider.zig").Provider;
const Agent = @import("agent.zig").Agent;
const local_tools = @import("local_tools.zig");
const schedule = @import("schedule.zig");

fn withExtras(arena: Allocator, base: []const schema.ToolSpec) ![]const schema.ToolSpec {
    const a = local_tools.catalogExtras(arena);
    const b = schedule.catalogExtras(arena);
    if (a.len == 0 and b.len == 0) return base;
    const out = try arena.alloc(schema.ToolSpec, base.len + a.len + b.len);
    @memcpy(out[0..base.len], base);
    @memcpy(out[base.len..][0..a.len], a);
    @memcpy(out[base.len + a.len ..], b);
    return out;
}

pub fn toolsJson(self: *const Agent) []const u8 {
    if (self.sub) {
        if (main_mod.g_codedbpro_licensed) return slot(self);
        return schema.subToolsJson(self.provider.kind, no_local_tools.enabled);
    }
    return slot(self);
}

fn slot(self: *const Agent) []const u8 {
    return switch (self.provider.kind) {
        .anthropic => self.tools_anthropic,
        .openai => self.tools_openai,
        .responses => self.tools_responses,
    };
}

pub fn ensureRootTools(self: *Agent, kind: Provider.Kind) !void {
    if (self.sub and !main_mod.g_codedbpro_licensed) return;
    const dest = switch (kind) {
        .anthropic => &self.tools_anthropic,
        .openai => &self.tools_openai,
        .responses => &self.tools_responses,
    };
    if (dest.*.len != 0) return;
    const specs = if (self.sub)
        try surface.filterSpecs(@TypeOf(schema.base_specs[0]), self.arena, schema.base_specs[0..])
    else
        try withExtras(self.arena, try schema.effectiveRootSpecs(self.arena));
    const connected: []const mcp.Tool = if (self.registry) |registry|
        (if (self.sub) try surface.filterWorkerMcp(self.arena, registry.tools) else registry.tools)
    else
        &.{};
    dest.* = try schema.renderRootTools(self.arena, kind, specs, connected);
}

test "invalidate without ensure leaves toolsJson empty; rebuild is a JSON array" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent: Agent = undefined;
    agent.arena = arena;
    agent.sub = false;
    agent.registry = null;
    agent.tools_anthropic = "";
    agent.tools_openai = "";
    agent.tools_responses = "";
    agent.provider = .{
        .id = "xai",
        .kind = .responses,
        .auth = .bearer,
        .url = "",
        .api_key = "k",
        .model = "grok-4.6",
        .context = 100_000,
    };
    try agent.ensureRootTools(.responses);
    try std.testing.expect(agent.tools_responses.len > 2);
    agent.invalidateRootTools();
    try std.testing.expectEqual(@as(usize, 0), agent.toolsJson().len);
    try agent.ensureRootTools(.responses);
    try std.testing.expect(agent.tools_responses.len > 2);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, agent.tools_responses, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    try std.testing.expect(parsed.value.array.items.len > 0);
}
