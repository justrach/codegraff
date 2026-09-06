//! Simulator input uses the production parser, read-burst latch, bounded
//! pacing batch and handleBatchItem seam (run.zig), not direct key dispatch.
const app = @import("app.zig");
const keys = @import("keys.zig");
const paste = @import("key_paste.zig");

pub fn apply(m: *app.Model, bytes: []const u8, i: *usize, now_ms: u64) app.Effect {
    paste.setBurstRead(paste.burstRead(bytes, now_ms));
    var last: app.Effect = .stay;
    var batch: @import("input_batch.zig").Decoder = .{};
    while (batch.next(bytes, i)) |items| {
        for (items) |item| {
            last = keys.handleBatchItem(m, item);
            if (last != .stay) return last;
        }
    }
    return last;
}
