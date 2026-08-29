//! TUI `/tell` and `/peek`: thin client of the engine mailbox.
//! Posting lives in `src/peer_channel.zig`; this file only routes the slash.

const std = @import("std");

const app = @import("app.zig");
const engine = @import("engine.zig");
const Model = app.Model;

pub const tell_usage = "usage: /tell <session|all> <text> — all reaches every live session on this device, any folder";
pub const peek_usage = "usage: /peek <session> — what a live session is doing right now";
pub const offline_note = "peer talk needs a live session (offline)";

pub fn run(self: *Model, canon: []const u8, arg: []const u8) void {
    if (engine.g_peer_fn) |f| {
        var buf: [2048]u8 = undefined;
        const line = if (arg.len == 0) canon else (std.fmt.bufPrint(&buf, "{s} {s}", .{ canon, arg }) catch canon);
        if (f(engine.g_turn_ctx, self.alloc, line)) |text| {
            defer self.alloc.free(text);
            const trimmed = std.mem.trimEnd(u8, text, " \t\r\n");
            if (trimmed.len > 0) self.push(.system, trimmed) catch {};
        }
        return;
    }
    if (arg.len == 0) {
        self.push(.system, if (std.mem.eql(u8, canon, "/peek")) peek_usage else tell_usage) catch {};
    } else {
        self.push(.system, offline_note) catch {};
    }
}
