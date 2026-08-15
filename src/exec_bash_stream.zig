//! Live foreground-bash output (#472). runCapped already polls pipes every
//! 200ms; this file is the UI half — write each new chunk so a long build
//! does not look like a hang.

const std = @import("std");
const Io = std.Io;

const main_mod = @import("main.zig");
const jobs = @import("jobs.zig");

pub const Ctx = struct {
    io: Io,
    w: ?*Io.Writer,
};

pub fn attach(opts: *jobs.CappedRunOptions, live: bool, stream: *Ctx) void {
    if (!live) return;
    opts.stream = &emit;
    opts.stream_ctx = stream;
}

pub fn emit(ctx: ?*anyopaque, which: u8, chunk: []const u8) void {
    if (chunk.len == 0) return;
    const c: *const Ctx = @ptrCast(@alignCast(ctx orelse return));
    if (main_mod.json_mode) {
        const w = main_mod.g_out orelse return;
        main_mod.g_gui_mu.lockUncancelable(c.io);
        defer main_mod.g_gui_mu.unlock(c.io);
        w.writeAll("{\"type\":\"tool_output\",\"name\":\"bash\",\"stream\":\"") catch return;
        w.writeAll(if (which == 0) "stdout" else "stderr") catch return;
        w.writeAll("\",\"text\":") catch return;
        writeJsonString(w, chunk) catch return;
        w.writeAll("}\n") catch return;
        w.flush() catch {};
        return;
    }
    const w = c.w orelse main_mod.g_out orelse return;
    w.writeAll(chunk) catch return;
    w.flush() catch {};
}

fn writeJsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) try w.print("\\u{d:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}

test "#472: writeJsonString escapes a newline" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeJsonString(&w, "a\nb");
    try std.testing.expectEqualStrings("\"a\\nb\"", w.buffered());
}
