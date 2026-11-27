//! Give the bundled NanoCUA proxy its own transport for each engine turn.
//! The proxy's socket EOF revokes this turn's grant, even if the engine dies.
const std = @import("std");
const mcp = @import("mcp.zig");
const rpc = @import("mcp_rpc.zig");
const shipped = @import("nanocua_default.zig");

pub const Turn = struct {
    memory: ?std.heap.ArenaAllocator = null,
    server: ?rpc.Server = null,

    pub fn connect(turn: *Turn, reg: *mcp.Registry, command: []const u8) !*rpc.Server {
        if (turn.server != null) return &turn.server.?;
        turn.memory = .init(reg.gpa);
        errdefer turn.close(reg.io);
        const a = turn.memory.?.allocator();
        turn.server = .{
            .name = shipped.server_name,
            .era = .legacy,
            .transport = try reg.spawnStdio(a, &.{ command, "mcp", "--turn-scoped" }, null, null),
        };
        // A compatible proxy answers before connecting to or opening the app.
        const answer = try rpc.request(&turn.server.?, a, "{}", "nanocua/turnProtocol", null);
        if (answer != .object or answer.object.get("result") == null)
            return error.NanocuaTurnProtocolUnavailable;
        return &turn.server.?;
    }

    pub fn close(turn: *Turn, io: std.Io) void {
        if (turn.server) |*server| {
            @import("mcp_stdio.zig").stopChild(io, &server.transport.stdio.child);
            turn.server = null;
        }
        if (turn.memory) |*memory| memory.deinit();
        turn.memory = null;
    }
};

pub fn bundledCommand(reg: *mcp.Registry, a: std.mem.Allocator, name: []const u8, cfg: std.json.ObjectMap) ?[]const u8 {
    if (@import("builtin").os.tag != .macos or !std.mem.eql(u8, name, shipped.server_name)) return null;
    const command = cfg.get("command") orelse return null;
    const args = cfg.get("args") orelse return null;
    if (command != .string or args != .array or args.array.items.len != 1) return null;
    const arg = args.array.items[0];
    if (arg != .string or !std.mem.eql(u8, arg.string, "mcp")) return null;
    const installed = shipped.find(reg.io, a, reg.home) orelse return null;
    return if (std.mem.eql(u8, command.string, installed)) installed else null;
}
