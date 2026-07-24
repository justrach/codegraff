//! Prompt history + unsent-draft navigation for the line editor (#101).
//! Split out of readline.zig, which sat at 599 of its 600-line cap and so
//! could not absorb any further change. Pure over std — no terminal, agent, or
//! session state — which is what makes it directly unit-testable.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// History + unsent-draft navigation for the line editor (#101). Mirrors the
/// GUI's promptHistoryNavigation.ts: stepping UP out of the fresh slot snapshots
/// the half-typed draft; stepping DOWN past the newest entry restores it instead
/// of clearing the line. `idx == history.len` is the fresh (editing) slot.
pub const HistoryNav = struct {
    idx: usize,
    draft: ?[]const u8 = null, // owned snapshot of the unsent line; freed by the caller

    pub fn init(history_len: usize) HistoryNav {
        return .{ .idx = history_len };
    }

    /// UP / older. `current` is the live buffer. Returns the text the buffer
    /// should show next, or null to leave it unchanged (already at the oldest).
    /// Leaving the fresh slot snapshots `current` as the draft to restore later.
    pub fn up(self: *HistoryNav, gpa: Allocator, history: []const []const u8, current: []const u8) ?[]const u8 {
        if (self.idx == 0) return null;
        if (self.idx == history.len) { // leaving the fresh slot: keep the draft
            if (self.draft) |d| gpa.free(d);
            self.draft = gpa.dupe(u8, current) catch null;
        }
        self.idx -= 1;
        return history[self.idx];
    }

    /// DOWN / newer. Returns the text to show next, or null to leave it
    /// unchanged (already at the fresh slot). Past the newest entry, restores the
    /// snapshotted draft (or "" when there was none) instead of clearing it.
    pub fn down(self: *HistoryNav, history: []const []const u8) ?[]const u8 {
        if (self.idx >= history.len) return null;
        self.idx += 1;
        if (self.idx == history.len) return self.draft orelse "";
        return history[self.idx];
    }
};

test "HistoryNav: up snapshots the draft, down past newest restores it (#101)" {
    const gpa = std.testing.allocator;
    const history = [_][]const u8{ "first", "second" };
    var nav: HistoryNav = .init(history.len);
    defer if (nav.draft) |d| gpa.free(d);

    // up from the fresh slot → newest entry, draft snapshotted
    try std.testing.expectEqualStrings("second", nav.up(gpa, &history, "draft in progress").?);
    // up again → older entry
    try std.testing.expectEqualStrings("first", nav.up(gpa, &history, "second").?);
    // up at the oldest → no change
    try std.testing.expect(nav.up(gpa, &history, "first") == null);
    // down → back to newest
    try std.testing.expectEqualStrings("second", nav.down(&history).?);
    // down past newest → the draft is restored, NOT cleared (the bug)
    try std.testing.expectEqualStrings("draft in progress", nav.down(&history).?);
    // down at the fresh slot → no change
    try std.testing.expect(nav.down(&history) == null);
}

test "HistoryNav: no draft → fresh slot returns empty, no leak (#101)" {
    const gpa = std.testing.allocator;
    const history = [_][]const u8{"only"};
    var nav: HistoryNav = .init(history.len);
    defer if (nav.draft) |d| gpa.free(d);
    try std.testing.expectEqualStrings("only", nav.up(gpa, &history, "").?);
    try std.testing.expectEqualStrings("", nav.down(&history).?); // empty draft → empty line, as today
}
