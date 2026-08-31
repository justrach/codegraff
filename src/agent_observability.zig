//! Small per-request operational-observability helpers kept out of Agent's
//! already-near-limit definition and the provider-specific stream parsers.

const std = @import("std");
const builtin = @import("builtin");

const main_mod = @import("main.zig");
const style = &@import("ansi.zig").style;

/// `-p` (unattended, not `--json`): emit one stderr progress line at the first
/// model-authored SSE event, including tool-call bytes. Eval `first_out` is
/// the first stdout or stderr line; tool-first turns used to stay silent until
/// the final answer, so first_out ≈ wall. REPL / `--json` stay quiet.
pub fn oneshotShouldMarkProgress(unattended: bool, json_mode: bool) bool {
    return unattended and !json_mode;
}

/// One dim `›` plus newline. Stderr only — stdout stays the answer (the
/// atomic-symlink-write miss captured turn-pulse chrome when it rode `g_out`).
pub fn oneshotProgressLine() []const u8 {
    return "›\n";
}

fn emitOneshotProgress() void {
    if (comptime builtin.is_test) return;
    if (!oneshotShouldMarkProgress(main_mod.unattended, main_mod.json_mode)) return;
    std.debug.print("{s}›{s}\n", .{ style.dim, style.reset });
}

pub fn firstToken(self: anytype) void {
    if (self.first_token_traced) return;
    const started = self.request_started orelse return;
    self.first_token_traced = true;
    emitOneshotProgress();
    const tracer = self.tracer orelse return;
    const ms: i64 = @intCast(@max(0, started.untilNow(self.io, .awake).toMilliseconds()));
    tracer.firstToken(self.label, self.sub, self.provider.model, ms);
}

test "oneshot marks first progress on -p, not --json or the line REPL" {
    try std.testing.expect(oneshotShouldMarkProgress(true, false));
    try std.testing.expect(!oneshotShouldMarkProgress(false, false));
    try std.testing.expect(!oneshotShouldMarkProgress(true, true));
    try std.testing.expectEqualStrings("›\n", oneshotProgressLine());
    try std.testing.expect(std.mem.endsWith(u8, oneshotProgressLine(), "\n"));
}
