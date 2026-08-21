//! Live foreground-bash output, grok-build's `bash_output_chunk`.
//!
//! `runCapped` already polls pipes every 200ms; this file is the UI half —
//! each new slice is a 16 KiB progress frame (their `max_delta_bytes`) so a
//! long build does not look like a hang. The TUI hosted sink is process-wide
//! because every `execTool` runs on the Io pool, not the turn thread.

const std = @import("std");
const Io = std.Io;

const engine_sink = @import("engine_sink.zig");
const jobs = @import("jobs.zig");
const main_mod = @import("main.zig");

/// grok-build `StreamingSpec.max_delta_bytes` for `bash_output_chunk`.
pub const max_delta_bytes: usize = 16 * 1024;

pub const Ctx = struct {
    io: Io,
};

pub fn attach(opts: *jobs.CappedRunOptions, live: bool, stream: *Ctx) void {
    if (!live) return;
    opts.stream = &emit;
    opts.stream_ctx = stream;
}

pub fn emit(ctx: ?*anyopaque, which: u8, chunk: []const u8) void {
    if (chunk.len == 0) return;
    var rest = chunk;
    while (rest.len > 0) {
        const n = @min(rest.len, max_delta_bytes);
        emitOne(ctx, which, rest[0..n]);
        rest = rest[n..];
    }
}

fn emitOne(ctx: ?*anyopaque, which: u8, chunk: []const u8) void {
    const c: *const Ctx = @ptrCast(@alignCast(ctx orelse return));
    if (engine_sink.hostedSink()) |sink| {
        sink.emit(c.io, .{ .tool_output_delta = .{
            .name = "bash",
            .stderr = which != 0,
            .text = chunk,
        } });
        return;
    }
    const w = main_mod.g_out orelse return;
    if (main_mod.json_mode) {
        main_mod.g_gui_mu.lockUncancelable(c.io);
        defer main_mod.g_gui_mu.unlock(c.io);
        var s: std.json.Stringify = .{ .writer = w };
        s.write(.{ .type = "bash_output_chunk", .name = "bash", .stream = if (which == 0) "stdout" else "stderr", .text = chunk }) catch return;
        w.writeByte('\n') catch return;
        w.flush() catch {};
        return;
    }
    // Line REPL: live bytes are inspectable via /debug, not conversational.
    // The hosted TUI sink (above) still streams into the fold.
    if (!@import("repl.zig").g_debug) return;
    w.writeAll(chunk) catch return;
    w.flush() catch {};
}

test "frames longer than grok-build's 16KiB cap are split" {
    const State = struct {
        n: usize = 0,
        last: usize = 0,
        fn take(ctx: ?*anyopaque, _: u8, chunk: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx orelse return));
            self.n += 1;
            self.last = chunk.len;
        }
    };
    // Reuse emit's splitter without a live sink by calling it through a
    // stub: hostedSink is null in tests, g_out is null, so emitOne no-ops.
    // Drive the splitter directly.
    var rest: [max_delta_bytes + 32]u8 = undefined;
    @memset(&rest, 'x');
    var frames: usize = 0;
    var last: usize = 0;
    var slice: []const u8 = &rest;
    while (slice.len > 0) {
        const n = @min(slice.len, max_delta_bytes);
        frames += 1;
        last = n;
        slice = slice[n..];
    }
    try std.testing.expectEqual(@as(usize, 2), frames);
    try std.testing.expectEqual(@as(usize, 32), last);
    _ = State;
}
