//! Citation filtering belongs to terminal presentation, never the event wire.
const std = @import("std");
const Stream = @import("cite_markup.zig").Stream;
const Agent = @import("agent.zig").Agent;
const main = @import("main.zig");
const render = @import("agent_stream_render.zig");

pub const Channel = enum { reasoning, answer, arguments };
pub const State = struct {
    reasoning: Stream = .{},
    answer: Stream = .{},
    arguments: Stream = .{},
};

/// Bounded scratch space: hidden payloads never allocate or reach render state.
fn feed(stream: *Stream, text: []const u8, ctx: anytype, comptime paint: anytype) void {
    var buf: [1024]u8 = undefined;
    var n: usize = 0;
    for (text) |c| {
        var unit: [3]u8 = undefined;
        const clean = stream.byte(c, &unit);
        if (n + clean.len > buf.len) {
            paint(ctx, buf[0..n]);
            n = 0;
        }
        @memcpy(buf[n..][0..clean.len], clean);
        n += clean.len;
    }
    if (n != 0) paint(ctx, buf[0..n]);
}

pub fn plain(stream: *Stream, w: *std.Io.Writer, text: []const u8) void {
    feed(stream, text, w, struct {
        fn write(out: *std.Io.Writer, clean: []const u8) void {
            out.writeAll(clean) catch {};
        }
    }.write);
    w.flush() catch {};
}

pub fn emit(a: *Agent, comptime channel: Channel, text: []const u8) void {
    feed(&@field(a.cite_stream, @tagName(channel)), text, a, struct {
        fn paint(agent: *Agent, clean: []const u8) void {
            switch (channel) {
                .reasoning => render.streamThinking(agent, clean),
                .answer => {
                    if (agent.thinking_open) render.closeThinkingBlock(agent);
                    render.spinnerStop(agent);
                    agent.streamMarkdown(clean);
                },
                .arguments => {
                    render.spinnerStop(agent);
                    if (main.use_color) {
                        agent.streamMarkdown(clean);
                    } else if (agent.out) |w| {
                        w.writeAll(clean) catch return;
                        w.flush() catch {};
                    }
                },
            }
        }
    }.paint);
}
