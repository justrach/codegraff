//! Google Interactions tool catalogs, and the subagent catalog selector for
//! every wire. Parked out of schema.zig, which sits at the 600-line ceiling.
//!
//! Interactions declares a tool in the Responses shape minus `strict` (the
//! endpoint rejects the whole request on an unknown field), so it needs its
//! own catalogs rather than borrowing the Responses ones.

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
    return catalogFor(kind, gated, tool_gates.anyAvailable());
}

/// The plain catalogs stay comptime constants: they are also Agent's field
/// defaults, so the binary carries them anyway. Every gated or optional
/// variant is rendered on first use instead of compiled in, which keeps
/// twelve near-copies of the catalog out of the binary.
fn catalogFor(kind: Provider.Kind, gated: bool, optional: bool) []const u8 {
    if (!gated and !optional) return switch (kind) {
        .anthropic => schema.tools_anthropic_sub,
        .openai => schema.tools_openai_sub,
        .responses => schema.tools_responses_sub,
        .interactions => tools_interactions_sub,
    };
    const variant: usize = if (!gated) 0 else if (optional) 1 else 2;
    const specs: []const ToolSpec = switch (variant) {
        0 => &base_optional,
        1 => base_optional_remote,
        else => base_remote,
    };
    return rendered(&cache[@backingInt(kind)][variant], kind, specs);
}

/// One rendered catalog per wire and variant, kept for the life of the
/// process. Subagents start on worker threads, so the first render is
/// published with a compare-and-swap and a losing racer frees its copy.
var cache: [std.enums.values(Provider.Kind).len][3]std.atomic.Value(?*const []const u8) = @splat(@splat(.init(null)));

fn rendered(cell: *std.atomic.Value(?*const []const u8), kind: Provider.Kind, specs: []const ToolSpec) []const u8 {
    if (cell.load(.acquire)) |hit| return hit.*;
    const gpa = std.heap.smp_allocator;
    const shape = switch (kind) {
        .anthropic => render.anthropic,
        .openai => render.openai,
        .responses => render.responses,
        .interactions => render.interactions,
    };
    var aw: std.Io.Writer.Allocating = .init(gpa);
    render.writeToolsJson(&aw.writer, shape, specs) catch @panic("out of memory");
    const box = gpa.create([]const u8) catch @panic("out of memory");
    box.* = aw.toOwnedSlice() catch @panic("out of memory");
    if (cell.cmpxchgStrong(null, box, .acq_rel, .acquire)) |winner| {
        gpa.free(box.*);
        gpa.destroy(box);
        return winner.?.*;
    }
    return box.*;
}

const std = @import("std");

test "the interactions catalog is the responses catalog without strict" {
    // Same tools, same order, same schemas — only the field Google rejects differs.
    try std.testing.expect(std.mem.indexOf(u8, schema.tools_responses_sub, "\"strict\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, tools_interactions_sub, "strict") == null);
    try std.testing.expect(std.mem.indexOf(u8, tools_interactions_sub, "\"type\":\"function\",\"name\":\"shell\"") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, tools_interactions_sub, .{});
    defer parsed.deinit();
    var responses_parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, schema.tools_responses_sub, .{});
    defer responses_parsed.deinit();
    try std.testing.expectEqual(responses_parsed.value.array.items.len, parsed.value.array.items.len);
}

test "runtime-rendered subagent catalogs match the comptime ones byte for byte" {
    const Case = struct { kind: Provider.Kind, gated: bool, optional: bool, want: []const u8 };
    const cases = [_]Case{
        .{ .kind = .anthropic, .gated = false, .optional = true, .want = schema.tools_anthropic_sub_optional },
        .{ .kind = .anthropic, .gated = true, .optional = true, .want = schema.tools_anthropic_sub_optional_remote },
        .{ .kind = .anthropic, .gated = true, .optional = false, .want = schema.tools_anthropic_sub_remote },
        .{ .kind = .openai, .gated = false, .optional = true, .want = schema.tools_openai_sub_optional },
        .{ .kind = .openai, .gated = true, .optional = true, .want = schema.tools_openai_sub_optional_remote },
        .{ .kind = .openai, .gated = true, .optional = false, .want = schema.tools_openai_sub_remote },
        .{ .kind = .responses, .gated = false, .optional = true, .want = schema.tools_responses_sub_optional },
        .{ .kind = .responses, .gated = true, .optional = true, .want = schema.tools_responses_sub_optional_remote },
        .{ .kind = .responses, .gated = true, .optional = false, .want = schema.tools_responses_sub_remote },
        .{ .kind = .interactions, .gated = false, .optional = true, .want = tools_interactions_sub_optional },
        .{ .kind = .interactions, .gated = true, .optional = true, .want = tools_interactions_sub_optional_remote },
        .{ .kind = .interactions, .gated = true, .optional = false, .want = tools_interactions_sub_remote },
    };
    for (cases) |c| {
        try std.testing.expectEqualStrings(c.want, catalogFor(c.kind, c.gated, c.optional));
        // The second call is served from the cache, unchanged.
        try std.testing.expectEqual(catalogFor(c.kind, c.gated, c.optional).ptr, catalogFor(c.kind, c.gated, c.optional).ptr);
    }
}
