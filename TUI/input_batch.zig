//! Shared terminal-read decoder/batcher for the live loop and headless composer.
const key = @import("key.zig");
const pacing = @import("pacing.zig");

pub const Decoder = struct {
    batch: pacing.Batch = .{},
    carried: ?key.Key = null,
    done: bool = false,

    pub fn next(self: *Decoder, bytes: []const u8, i: *usize) ?[]const pacing.Item {
        if (self.done) return null;
        self.batch.reset();
        if (self.carried) |k| {
            _ = self.batch.push(k);
            self.carried = null;
        }
        while (key.next(bytes, i)) |k| {
            pacing.events += 1;
            if (pacing.wheelNotch(k) != null) pacing.wheel_events += 1;
            if (self.batch.push(k) == .full) {
                self.carried = k;
                return self.batch.items();
            }
        }
        self.done = true;
        return if (self.batch.len > 0) self.batch.items() else null;
    }
};
