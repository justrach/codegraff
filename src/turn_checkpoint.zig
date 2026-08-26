//! Mid-turn durability after an executed tool batch (#602). The append-only
//! transcript is written synchronously by queueSave; only the replaceable
//! session snapshot's disk write remains on the existing background writer.

const session = @import("session.zig");
const vision_queue = @import("vision_queue.zig");

pub fn afterToolBatch(self: anytype) !void {
    try vision_queue.flushPending(self);
    if (self.sub or self.session_name.len == 0) return;
    session.saveSessionAsync(self, self.arena, self.session_name) catch {};
}
