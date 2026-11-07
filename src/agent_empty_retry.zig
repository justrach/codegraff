//! Cancellation-aware empty-reply retry timing and budget admission.
const Agent = @import("agent.zig").Agent;
const main_mod = @import("main.zig");

/// Five retries span 4.5–5.6 minutes, rather than hammering an unhealthy route.
/// Reuse the shared upward-only jitter; each delay is independently randomized.
pub fn retryDelayMs(retries: u8) u64 {
    return @min(@as(u64, 10_000) << @intCast(@min(retries, 4)), 120_000);
}

/// Unlike the legacy short-backoff sleeper, also observe headless/ACP flags
/// and IO cancellation. Keep terminal Esc handling without touching its owner.
pub fn wait(self: *Agent, ms: u64) error{Interrupted}!void {
    const watch = !self.sub and self.in != null and main_mod.use_color and !main_mod.json_mode;
    const orig = if (watch) Agent.rawNonblockStdin() else null;
    defer if (orig) |o| Agent.restoreStdin(o);
    var left = ms;
    while (true) {
        if (Agent.esc_cancel.load(.acquire) or @import("acp_engine.zig").cancel_flag.load(.acquire)) return error.Interrupted;
        if (orig != null and Agent.escPressed(true)) return error.Interrupted;
        if (left == 0) return;
        const chunk = @min(left, 100);
        self.io.sleep(.fromMilliseconds(@intCast(chunk)), .awake) catch return error.Interrupted;
        left -= chunk;
    }
}

pub fn checkBudget(self: *Agent) !void {
    if (self.run_budget) |b| if (!b.canAfford(if (self.depth > 0) 2 else 1)) {
        self.last_api_error = "model-call budget exhausted before empty-completion retry";
        return error.RunBudgetExhausted;
    };
    const cap = @import("turn_chrome.zig").max_turn_model_calls;
    if (cap != 0 and self.model_calls_this_turn >= cap) {
        self.last_api_error = "model-call limit reached before empty-completion retry";
        return error.RunBudgetExhausted;
    }
}
