//! Simulator input uses the production parser, read-burst latch, bounded
//! pacing batch and handleBatchItem seam (run.zig), not direct key dispatch.
const app = @import("app.zig");
const key = @import("key.zig");
const keys = @import("keys.zig");
const pacing = @import("pacing.zig");
const paste = @import("key_paste.zig");

pub fn apply(m: *app.Model, bytes: []const u8, i: *usize, now_ms: u64) app.Effect {
    paste.setBurstRead(paste.burstRead(bytes, now_ms));
    var batch: pacing.Batch = .{};
    while (true) {
        const arrived = key.next(bytes, i);
        if (arrived) |k| {
            if (batch.push(k) == .ok) continue;
        }
        for (batch.items()) |item| {
            const effect = keys.handleBatchItem(m, item);
            if (effect != .stay) return effect;
        }
        batch.reset();
        if (arrived) |k| {
            _ = batch.push(k);
        } else return .stay;
    }
}
