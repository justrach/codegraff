//! Process-global state a session releases before main()'s exit-time leak
//! check. The one-shot path and finalizeSession both end a run, so both call
//! `release` rather than each keeping its own list that can fall out of step.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const presence = @import("presence.zig");

pub fn release(gpa: Allocator, io: Io) void {
    // #469: our presence record leaves the registry with us; a crashed session
    // skips this and gets reaped by the next reader's liveness probe instead.
    presence.retire(io);
    @import("presence_accord.zig").stop(io);
    presence.deinit(gpa);
    // #1196: filled by the first successful MCP tool result.
    @import("mcp_shapes.zig").shutdown(io);
}
