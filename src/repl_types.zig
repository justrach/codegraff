//! The turn-backend vocabulary shared by every chat frontend: what a turn is
//! asked to do (Params), what it is given (Turn history), and where its prose
//! streams (StreamBuf). Moved out of repl.zig, which is at the 600-line cap
//! (#123's move+alias pattern) — `repl.Params` and friends still resolve, and
//! the mutable `g_*` hooks deliberately stay declared in repl.zig, because an
//! alias would freeze their value.
//!
//! Nothing here imports the harness. `src/repl_glue.zig` is the one place that
//! translates these into an Agent, and #551 is why `mode`/`strict` live on
//! Params at all: a frontend's permission policy has to REACH the engine, not
//! sit beside it as a label.

const std = @import("std");

pub const Effort = enum { low, medium, high, xhigh, max, ultra };

pub const Turn = struct {
    role: Role,
    text: []const u8,
    pub const Role = enum { user, assistant };
};

/// The session's permission policy, as a turn backend must apply it: `.plan`
/// arms main.plan_mode (the read-only gate), `.always_approve` is --yolo.
pub const Mode = enum { normal, plan, always_approve };

pub const Params = struct {
    effort: Effort = .medium,
    fast: bool = false,
    thinking: bool = false,
    ultracode: bool = false,
    /// always_approve by default: the scripted chat REPL has no mode surface.
    /// A frontend that has one (the TUI) sends its real mode instead.
    mode: Mode = .always_approve,
    /// /strict — selects the strict system prompt for the turn.
    strict: bool = false,
    goal: []const u8 = "", // "" = none
};

pub const StreamBuf = struct {
    // Single-writer (worker thread) / single-reader (render loop), lock-free: a
    // fixed pre-allocated buffer (no realloc → stable pointer) + an atomic
    // length. The worker appends bytes then release-stores the new length; the
    // reader acquire-loads it and reads the committed prefix. Overflow drops
    // extra bytes — only the live preview is affected (the final reply uses
    // runTurn's return value).
    buf: []u8 = &.{},
    len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    pub fn appendBytes(self: *StreamBuf, bytes: []const u8) void {
        const cur = self.len.load(.monotonic);
        if (cur >= self.buf.len) return;
        var n = @min(bytes.len, self.buf.len - cur);
        // The dropped tail never comes back, so a clip must not land INSIDE a
        // codepoint or the live preview keeps half a glyph for the whole turn.
        // Mirrors TUI/engine.zig's StreamBuf — tui_launch.liveStream overlays
        // one struct on the other, so their semantics have to match too.
        if (n < bytes.len) n = utf8Floor(bytes, n);
        if (n == 0) return;
        @memcpy(self.buf[cur .. cur + n], bytes[0..n]);
        self.len.store(cur + n, .release);
    }
    /// Largest k <= n where `s[0..k]` ends on a whole UTF-8 codepoint.
    fn utf8Floor(s: []const u8, n: usize) usize {
        if (n == 0 or n >= s.len) return n;
        var k = n;
        while (k > 0) : (k -= 1) {
            const b = s[k - 1];
            if (b < 0x80) return k;
            if (b >= 0xc0) {
                const len = std.unicode.utf8ByteSequenceLength(b) catch return k - 1;
                return if (k - 1 + len <= n) n else k - 1;
            }
        }
        return 0;
    }
    pub fn snapshot(self: *StreamBuf, gpa: std.mem.Allocator) ?[]u8 {
        const n = self.len.load(.acquire);
        if (n == 0) return null;
        return gpa.dupe(u8, self.buf[0..n]) catch null;
    }
};

pub const TurnFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator, history: []const Turn, params: Params, stream: *StreamBuf) ?[]const u8;

test "Params defaults keep the scripted REPL auto-approving, and plan is opt-in" {
    const p: Params = .{};
    try std.testing.expectEqual(Mode.always_approve, p.mode);
    try std.testing.expect(!p.strict);
    const planning: Params = .{ .mode = .plan, .strict = true };
    try std.testing.expectEqual(Mode.plan, planning.mode);
    try std.testing.expect(planning.strict);
}

test "StreamBuf: append publishes length, overflow drops silently" {
    var buf: [8]u8 = undefined;
    var s: StreamBuf = .{ .buf = &buf };
    s.appendBytes("hi");
    try std.testing.expectEqual(@as(usize, 2), s.len.load(.acquire));
    s.appendBytes("0123456789");
    try std.testing.expectEqual(@as(usize, 8), s.len.load(.acquire));
    const snap = s.snapshot(std.testing.allocator) orelse return error.NoSnapshot;
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqualStrings("hi012345", snap);
}
