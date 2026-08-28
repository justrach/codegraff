//! Companion auto-connect (codedb-pro / muonry), split out of session_start
//! so the TUI boot path can name the hang and stay under 600 lines.
//!
//! Interactive `--yolo` used to call `Registry.addServer` on the main thread
//! after the plugin receipt. The registry is still empty on a deferred MCP
//! boot (ADR 0035), so a PATH-installed companion looked "not connected" and
//! the handshake (stdio probe + 15s cap) sat in front of the first paint.
//! Queue it onto `pending_starts` instead; native tools run now.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const args = @import("args.zig");
const engine_events = @import("engine_events.zig");
const engine_sink = @import("engine_sink.zig");
const mcp = @import("mcp.zig");
const mcp_boot = @import("mcp_boot.zig");
const mcp_schema_gate = @import("mcp_schema_gate.zig");
const skills = @import("skills.zig");

/// Same gate as MCP `defer_join`: interactive yolo, not `--json` / `-p`.
pub fn deferCompanion(flags: args.Flags, json_mode: bool) bool {
    return flags.effectiveYolo() and flags.oneshot_prompt == null and !json_mode;
}

pub fn probeLicensed(gpa: Allocator, io: Io) bool {
    return skills.probeCodedbproLicensed(gpa, io);
}

/// A licensed codedb-pro still pins these tools eager (search/batch extras;
/// ADR 0040: not the default reader). Skipping that pin costs a measured
/// ~2 load_tool_schemas discovery turns per task that does need pro search.
pub fn pinCompanionEager(arena: Allocator) void {
    if (mcp_schema_gate.pinnedEager("codedbpro")) return;
    const gate = &mcp_schema_gate.g_policy;
    const eager = arena.alloc([]const u8, gate.eager.len + 1) catch return;
    @memcpy(eager[0..gate.eager.len], gate.eager);
    eager[gate.eager.len] = "codedbpro";
    gate.eager = eager;
}

pub fn probeLicensedPinningEager(gpa: Allocator, io: Io, arena: Allocator) bool {
    const licensed = probeLicensed(gpa, io);
    if (licensed) pinCompanionEager(arena);
    return licensed;
}

fn dimNotice(text: []const u8) engine_events.EngineEvent {
    return .{ .session_notice = .{ .text = text, .tone = .dim } };
}

fn interactive(flags: args.Flags, json_mode: bool) bool {
    return !json_mode and flags.oneshot_prompt == null;
}

/// Spawn the first PATH-installed companion that is not already connected
/// or queued. Interactive `--yolo` queues a background handshake (ADR 0035);
/// every other path still `addServer`s on this thread.
pub fn connectCompanion(io: Io, arena: Allocator, registry: *mcp.Registry, flags: args.Flags, out: *Io.Writer, json_mode: bool, environ_map: anytype) !void {
    const sink = engine_sink.writerSink(out);
    const speak = interactive(flags, json_mode);
    const background = deferCompanion(flags, json_mode);
    _ = environ_map;
    connect: {
        for (skills.companion_servers) |c| {
            if (mcp_boot.alreadyStarting(registry, c.server)) break :connect;
            if (skills.mcpServerConnected(registry.tools, c.server)) break :connect;
        }
        for (skills.companion_servers) |c| {
            if (skills.companionDisabled(c.server) or !skills.binOnPath(io, c.bin)) continue;
            if (background) {
                if (speak) sink.emit(io, dimNotice(try std.fmt.allocPrint(arena, "companion: {s} (background)", .{c.bin})));
                mcp_boot.queueStdio(registry, c.server, c.bin, &.{"--mcp"});
                break;
            }
            if (speak) sink.emit(io, dimNotice(try std.fmt.allocPrint(arena, "companion: connecting {s}...", .{c.bin})));
            if (registry.addServer(c.server, c.bin, &.{"--mcp"})) |_| {
                break;
            } else |err| {
                if (speak) sink.emit(io, dimNotice(try std.fmt.allocPrint(arena, "[mcp:{s}] auto-connect failed ({t}) — native tools only", .{ c.server, err })));
            }
        }
    }
}

test "deferCompanion: interactive yolo only" {
    try std.testing.expect(deferCompanion(.{ .yolo_flag = true }, false));
    try std.testing.expect(!deferCompanion(.{ .yolo_flag = true }, true));
    try std.testing.expect(!deferCompanion(.{ .yolo_flag = true, .oneshot_prompt = "hi" }, false));
    try std.testing.expect(!deferCompanion(.{}, false));
    try std.testing.expect(!deferCompanion(.{ .oneshot_prompt = "hi" }, false));
}

test "a licensed companion is pinned eager, once, so no discovery round-trip is needed" {
    const saved = mcp_schema_gate.g_policy;
    defer mcp_schema_gate.g_policy = saved;
    mcp_schema_gate.g_policy = .{};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expect(!mcp_schema_gate.pinnedEager("codedbpro"));
    pinCompanionEager(arena);
    try std.testing.expect(mcp_schema_gate.pinnedEager("codedbpro"));
    pinCompanionEager(arena);
    try std.testing.expectEqual(@as(usize, 1), mcp_schema_gate.g_policy.eager.len);
}
