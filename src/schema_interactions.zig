//! Google Interactions tool catalogs, and the subagent catalog selector for
//! every wire. Parked out of schema.zig, which sits at the 600-line ceiling.
//!
//! Interactions declares a tool in the Responses shape minus `strict` (the
//! endpoint rejects the whole request on an unknown field), so it needs its
//! own comptime catalogs rather than borrowing the Responses ones.

const schema = @import("schema.zig");
const render = @import("schema_render.zig");
const no_local_tools = @import("no_local_tools.zig");
const tool_gates = @import("tool_gates.zig");
const Provider = @import("provider.zig").Provider;

const interactionsToolsJson = render.interactionsToolsJson;
const ToolSpec = schema.ToolSpec;

const base = schema.base_specs;
const base_remote = no_local_tools.remoteSpecs(ToolSpec, &base);
const base_optional = base ++ schema.optional_specs;
const base_optional_remote = no_local_tools.remoteSpecs(ToolSpec, &base_optional);

pub const tools_interactions_sub = interactionsToolsJson(&base);
pub const tools_interactions_sub_remote = interactionsToolsJson(base_remote);
pub const tools_interactions_sub_optional = interactionsToolsJson(&base_optional);
pub const tools_interactions_sub_optional_remote = interactionsToolsJson(base_optional_remote);

/// The catalog a SUBAGENT is served, across both gates: `--no-local-tools`
/// subtracts, an available optional tool adds. Sole caller is Agent.toolsJson.
pub fn subToolsJson(kind: Provider.Kind, gated: bool) []const u8 {
    const optional = tool_gates.anyAvailable();
    return switch (kind) {
        .anthropic => if (gated)
            (if (optional) schema.tools_anthropic_sub_optional_remote else schema.tools_anthropic_sub_remote)
        else
            (if (optional) schema.tools_anthropic_sub_optional else schema.tools_anthropic_sub),
        .openai => if (gated)
            (if (optional) schema.tools_openai_sub_optional_remote else schema.tools_openai_sub_remote)
        else
            (if (optional) schema.tools_openai_sub_optional else schema.tools_openai_sub),
        .responses => if (gated)
            (if (optional) schema.tools_responses_sub_optional_remote else schema.tools_responses_sub_remote)
        else
            (if (optional) schema.tools_responses_sub_optional else schema.tools_responses_sub),
        .interactions => if (gated)
            (if (optional) tools_interactions_sub_optional_remote else tools_interactions_sub_remote)
        else
            (if (optional) tools_interactions_sub_optional else tools_interactions_sub),
    };
}

const std = @import("std");

test "the interactions catalog is the responses catalog without strict" {
    // Same tools, same order, same schemas — only the field Google rejects differs.
    try std.testing.expect(std.mem.indexOf(u8, schema.tools_responses_sub, "\"strict\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_interactions_sub, "strict") == null);
    try std.testing.expect(std.mem.indexOf(u8, tools_interactions_sub, "\"type\":\"function\",\"name\":\"bash\"") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, tools_interactions_sub, .{});
    defer parsed.deinit();
    var responses_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, schema.tools_responses_sub, .{});
    defer responses_parsed.deinit();
    try std.testing.expectEqual(responses_parsed.value.array.items.len, parsed.value.array.items.len);
}
