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
    settleAfterRestore(self, "restored exact pre-compaction input; subsequent conversation retained");
    return true;
}

/// A blob decrypts only where it was minted, so carrying one across a provider
/// or model switch guarantees a rejection. codex binds a compaction to the
/// model that produced it and re-compacts when that hash changes
/// (`compact_remote_v2_installation.rs`, `CompactionReason::CompHashChanged`);
/// reaching the same end state from exact retained input keeps the history
/// portable without replaying foreign ciphertext.
pub fn expandForSeatChange(self: *Agent) bool {
    if (window.latestBlob(self.messages.items) == null) return false;
    if (!(checkpoint.restore(self) catch false)) return false;
    settleAfterRestore(self, "expanded opaque compaction state before a provider or model switch; subsequent conversation retained");
    // The expanded history is real again: drop the fingerprint, or re-derive it
    // if the restored input itself still ends in an opaque item.
    self.compaction_window = window.State.canonical(self.gpa, self.messages.items) catch .{};
    return true;
}

fn settleAfterRestore(self: *Agent, note: []const u8) void {
    self.closeCodexWs();
    self.last_context_tokens = 0;
    self.context_local_tokens = 0;
    self.last_usage_includes_output = false;
    self.goal_note_fp = 0;
    self.history_rewrites +%= 1;
    if (self.tracer) |tr| tr.note("encrypted_state_recovery", note);
}
