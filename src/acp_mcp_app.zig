//! Host-mediated MCP App `tools/call` over ACP (`session/mcp_call`).
//! Native engine tools are refused; only `mcp__` catalog entries run.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("acp_protocol.zig");
const Agent = @import("agent.zig").Agent;

fn strField(params: ?std.json.Value, key: []const u8) []const u8 {
    const p = params orelse return "";
    if (p != .object) return "";
    const v = p.object.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

pub fn allowedMcpName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "mcp__") and std.mem.indexOf(u8, name["mcp__".len..], "__") != null;
}

pub fn handle(arena: Allocator, w: *std.Io.Writer, req: proto.Request, root: *Agent) !bool {
    if (!std.mem.eql(u8, req.method, "session/mcp_call")) return false;
    if (req.id == null) return true;
    const name = strField(req.params, "name");
    if (!allowedMcpName(name)) {
        try proto.writeError(w, req.id, proto.err_auth_required, "MCP Apps can only call mcp__ tools");
        return true;
    }
    const registry = root.registry orelse {
        try proto.writeError(w, req.id, proto.err_internal, "No MCP session is live");
        return true;
    };
    const empty: std.json.ObjectMap = .empty;
    const args: std.json.Value = if (req.params) |p| (if (p == .object) (p.object.get("arguments") orelse .{ .object = empty }) else .{ .object = empty }) else .{ .object = empty };
    const called = registry.call(arena, name, args) catch |err| {
        try proto.writeError(w, req.id, proto.err_internal, @errorName(err));
        return true;
    };
    try proto.writeResult(w, req.id, .{ .content = called.text, .isError = called.is_error });
    return true;
}

test "MCP Apps cannot invoke native engine tools" {
    try std.testing.expect(!allowedMcpName("write_file"));
    try std.testing.expect(!allowedMcpName("bash"));
    try std.testing.expect(!allowedMcpName("mcp__incomplete"));
    try std.testing.expect(allowedMcpName("mcp__docs__search"));
}
