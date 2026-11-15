//! Execution backstop shared by agent/meta dispatch and RLM/native dispatch.
const std = @import("std");
const policy = @import("hard_policy.zig");
const tools = @import("tools.zig");
const shell = @import("shell_tool.zig");

pub fn denial(io: std.Io, arena: std.mem.Allocator, call: tools.ToolCall, registry: ?*@import("mcp.zig").Registry) ?[]const u8 {
    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const doc = policy.loadAt(io, a, std.Io.Dir.cwd());
    const reason = callDenial(doc, a, call.name, registry) orelse return null;
    return arena.dupe(u8, reason) catch "hard policy denied operation";
}

pub fn denialAgent(agent: anytype, arena: std.mem.Allocator, call: tools.ToolCall) ?[]const u8 {
    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const doc = @import("hard_policy_context.zig").load(agent.io, a, agent.agent_cwd, agent.hard_policy);
    const reason = callDenial(doc, a, call.name, agent.registry) orelse return null;
    return arena.dupe(u8, reason) catch "hard policy denied operation";
}

pub fn callDenial(doc: policy.Document, a: std.mem.Allocator, name: []const u8, registry: ?*@import("mcp.zig").Registry) ?[]const u8 {
    if (doc.denial(a, "tool.use", name)) |reason| return reason;
    // Legacy/RLM spellings are not a second shell capability.
    if (shell.isFamily(name)) {
        for ([_][]const u8{ "shell", "bash", "bash_output", "bash_kill" }) |alias| {
            if (doc.denial(a, "tool.use", alias)) |reason| return reason;
        }
    }
    if (std.mem.startsWith(u8, name, "mcp__")) {
        const server = if (registry) |reg| blk: {
            for (reg.tools) |t| if (std.mem.eql(u8, t.qualified_name, name)) break :blk t.serverName();
            break :blk @import("mcp_names.zig").serverOf(name);
        } else @import("mcp_names.zig").serverOf(name);
        if (doc.denial(a, "mcp.use", server)) |reason| return reason;
    }
    return null;
}

pub fn exec(ctx: tools.ToolCtx, call: tools.ToolCall) ?tools.ToolOutput {
    var scratch = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer scratch.deinit();
    const doc = @import("hard_policy_context.zig").load(ctx.io, scratch.allocator(), ctx.agent_cwd, ctx.hard_policy);
    const reason = callDenial(doc, scratch.allocator(), call.name, ctx.registry) orelse return null;
    return .{ .text = ctx.gpa.dupe(u8, reason) catch &.{}, .is_error = true };
}

test "hard policy shell aliases and MCP are independent restrictive gates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = policy.parse(a,
        \\{"policies":[{"action":"tool.use","resource":"shell","effect":"deny"},{"action":"tool.use","resource":"mcp__fixture__*","effect":"allow"},{"action":"mcp.use","resource":"fixture","effect":"deny"}]}
    );
    try std.testing.expect(callDenial(doc, a, "bash", null) != null);
    try std.testing.expect(callDenial(doc, a, "shell", null) != null);
    try std.testing.expect(callDenial(doc, a, "bash_kill", null) != null);
    try std.testing.expect(callDenial(doc, a, "mcp__fixture__read", null) != null);
    try std.testing.expect(callDenial(doc, a, "read_file", null) == null);
}
