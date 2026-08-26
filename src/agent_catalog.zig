//! Root/worker tool-catalog materialization. Split out of agent.zig (600-line ceiling).

const main_mod = @import("main.zig");
const schema = @import("schema.zig");
const no_local_tools = @import("no_local_tools.zig");
const surface = @import("tool_surface.zig");
const mcp = @import("mcp.zig");
const Provider = @import("provider.zig").Provider;
const Agent = @import("agent.zig").Agent;

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
        try schema.effectiveRootSpecs(self.arena);
    const connected: []const mcp.Tool = if (self.registry) |registry|
        (if (self.sub) try surface.filterWorkerMcp(self.arena, registry.tools) else registry.tools)
    else
        &.{};
    dest.* = try schema.renderRootTools(self.arena, kind, specs, connected);
}
