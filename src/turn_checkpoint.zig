//! Mid-turn durability before and after an executed tool batch (#602).
//! `beforeToolBatch` flushes the accepted assistant tool-call proposal to the
//! append-only `.transcript.jsonl` before any tool executes (`CoveredBeforeDrive`),
//! and `afterToolBatch` checkpoints both the transcript and `.session.json`.

const std = @import("std");
const session = @import("session.zig");
const session_transcript = @import("session_transcript.zig");
const vision_queue = @import("vision_queue.zig");

pub fn beforeToolBatch(self: anytype) void {
    if (self.sub or self.session_name.len == 0) return;
    session_transcript.record(self, std.Io.Dir.cwd(), self.session_name);
}

pub fn afterToolBatch(self: anytype) !void {
    try vision_queue.flushPending(self);
    if (self.sub or self.session_name.len == 0) return;
    session.saveSessionAsync(self, self.arena, self.session_name) catch {};
}
