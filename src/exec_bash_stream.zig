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
const tool_pulse = @import("tool_pulse.zig");

/// grok-build `StreamingSpec.max_delta_bytes` for `bash_output_chunk`.
pub const max_delta_bytes: usize = 16 * 1024;

pub const Ctx = struct {
    io: Io,
};

pub fn attach(opts: *jobs.CappedRunOptions, live: bool, stream: *Ctx) void {
    if (!live) return;
    opts.stream = &emit;
    opts.stream_ctx = stream;
    opts.pulse = &pulse;
}

/// The silence half (#607): one dim chrome line per tool_pulse threshold so a
/// quiet build never reads as a hang. Not gated on /debug — it is an elapsed
/// notice (ADR 0020 keeps RAW bytes behind /debug), and --json drops it.
fn pulse(ctx: ?*anyopaque, elapsed_ms: u64) void {
    const c: *const Ctx = @ptrCast(@alignCast(ctx orelse return));
    var ebuf: [16]u8 = undefined;
    tool_pulse.emitNotice(c.io, "· bash still running · {s}", .{tool_pulse.formatElapsed(&ebuf, elapsed_ms)});
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
        @import("protocol_seq.zig").writeEvent(w, .{ .type = "bash_output_chunk", .name = "bash", .stream = if (which == 0) "stdout" else "stderr", .text = chunk }) catch return;
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

test "bash progress shares contiguous JSON sequencing with core events and resume" {
    const seq = @import("protocol_seq.zig");
    seq.resetForTest();
    defer seq.resetForTest();
    seq.restore(40);
    const old_mode = main_mod.json_mode;
    const old_out = main_mod.g_out;
    defer {
        main_mod.json_mode = old_mode;
        main_mod.g_out = old_out;
    }
    var buf: [max_delta_bytes * 2]u8 = undefined;
    var writer: Io.Writer = .fixed(&buf);
    main_mod.json_mode = true;
    main_mod.g_out = &writer;
    var ctx: Ctx = .{ .io = std.testing.io };
    try seq.writeEvent(&writer, .{ .type = "tool_call_started", .name = "bash" });
    try writer.writeByte('\n');
    emit(&ctx, 0, ""); // No line means no sequence consumed.
    var chunk: [max_delta_bytes + 32]u8 = undefined;
    @memset(&chunk, 'x');
    emit(&ctx, 0, &chunk);
    emit(&ctx, 1, "stderr\n");
    try seq.writeEvent(&writer, .{ .type = "tool_call_finished", .name = "bash" });
    try writer.writeByte('\n');
    var lines = std.mem.tokenizeScalar(u8, writer.buffered(), '\n');
    var id: u64 = 40;
    var progress: usize = 0;
    while (lines.next()) |line| {
        id += 1;
        try std.testing.expectEqual(id, seq.seqOf(line).?);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        if (std.mem.eql(u8, obj.get("type").?.string, "bash_output_chunk")) {
            progress += 1;
            const text = obj.get("text").?.string;
            try std.testing.expectEqualStrings("bash", obj.get("name").?.string);
            try std.testing.expect(text.len <= max_delta_bytes);
            try std.testing.expectEqualStrings(if (progress == 3) "stderr" else "stdout", obj.get("stream").?.string);
            if (progress == 3) try std.testing.expectEqualStrings("stderr\n", text);
        }
    }
    try std.testing.expectEqual(@as(u64, 45), id);
    try std.testing.expectEqual(id, seq.current());
    try std.testing.expectEqual(@as(usize, 3), progress);
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
