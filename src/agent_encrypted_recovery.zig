//! Rejected opaque state is recoverable only from exact retained input.
//! Never retry the same blob unchanged or infer its contents from a summary.
const Agent = @import("agent.zig").Agent;
const checkpoint = @import("compaction_checkpoint.zig");
const window = @import("compaction_window.zig");

pub const max_restores = 8;

pub fn recover(self: *Agent, message: []const u8, code: ?[]const u8, restores: *u8) bool {
    if (!window.rejectedByProvider(message, code) or restores.* >= max_restores) return false;
    if (!(checkpoint.restore(self) catch false)) return false;
    restores.* += 1;
    self.closeCodexWs();
    self.last_context_tokens = 0;
    self.context_local_tokens = 0;
    self.last_usage_includes_output = false;
    self.goal_note_fp = 0;
    self.history_rewrites +%= 1;
    if (self.tracer) |tr| tr.note("encrypted_state_recovery", "restored exact pre-compaction input; subsequent conversation retained");
    return true;
}
