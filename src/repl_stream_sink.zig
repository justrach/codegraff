//! The turn writer that publishes into a REPL/TUI live pane. Split out of
//! repl_glue.zig (the move+alias pattern from #123) when the typed-event sink
//! landed there.

const std = @import("std");
const Io = std.Io;

const repl = @import("repl.zig");

/// A thread-safe sink the worker writes the agent's output to and the repl's
/// render loop polls — this is what makes `graff repl` stream live. Custom
/// Io.Writer whose drain appends (under the StreamBuf mutex) to the repl buffer.
pub const ReplStreamSink = struct {
    target: *repl.StreamBuf,
    buf: [4096]u8 = undefined,
    writer: Io.Writer = undefined,

    const vtable: Io.Writer.VTable = .{ .drain = drain };

    pub fn init(self: *ReplStreamSink, target: *repl.StreamBuf) void {
        self.target = target;
        self.writer = .{ .vtable = &vtable, .buffer = &self.buf, .end = 0 };
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *ReplStreamSink = @alignCast(@fieldParentPtr("writer", w));
        self.target.appendBytes(w.buffer[0..w.end]);
        w.end = 0;
        const slices = data[0 .. data.len - 1];
        const pattern = data[data.len - 1];
        var written: usize = 0;
        for (slices) |b| {
            self.target.appendBytes(b);
            written += b.len;
        }
        var i: usize = 0;
        while (i < splat) : (i += 1) self.target.appendBytes(pattern);
        written += pattern.len * splat;
        return written;
    }
};
