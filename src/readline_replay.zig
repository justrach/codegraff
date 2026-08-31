//! History-step replay for the raw readline composer.
//!
//! Replacing the draft invalidates semantic paste spans: history stores their
//! display labels, not their hidden bodies, so a replayed lookalike must remain
//! ordinary text rather than resurrecting an attachment (#673).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Agent = @import("agent.zig").Agent;
const input_util = @import("input_util.zig");
const PasteStore = @import("readline_paste.zig").Store;
const Step = @import("readline_history.zig").Step;

pub fn apply(
    root: *Agent,
    gpa: Allocator,
    buf: *std.ArrayList(u8),
    cursor: *usize,
    marks: *std.ArrayList([]const u8),
    pastes: *PasteStore,
    step: Step,
) void {
    pastes.clear(gpa);
    input_util.setLine(gpa, buf, step.text);
    cursor.* = buf.items.len;
    root.pending_image = step.image;
    if (step.image != null) input_util.markImageChips(gpa, marks, buf.items);
}
