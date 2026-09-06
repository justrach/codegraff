//! Turn-backend value types and streaming buffer; no mutable frontend callbacks.
const std = @import("std");
const events_mod = @import("events.zig");

pub const Effort = enum { low, medium, high, xhigh, max, ultra };

/// The session's permission policy. This is ENGINE state, not a badge: the
/// turn backend maps it onto the harness's plan gate and approval policy
/// (repl_glue.replTurnCb). Before #551 round 2 the TUI kept its own copy and
/// the engine was never told, so a footer reading "Plan" sat over a turn that
/// was writing files.
pub const Mode = enum { normal, plan, always_approve };

pub const Turn = struct {
    role: Role,
    text: []const u8,
    pub const Role = enum { user, assistant };
};

pub const Params = struct {
    effort: Effort = .medium,
    fast: bool = false,
    thinking: bool = false,
    ultracode: bool = false,
    /// Permission policy for this turn (Shift+Tab, Ctrl+O, /plan).
    mode: Mode = .normal,
    /// /strict — selects the strict system prompt on the turn's agent.
    strict: bool = false,
    goal: []const u8 = "",
};

/// Lock-free single-writer / single-reader preview buffer (same contract as
/// the zigzag REPL stream). Overflow drops live bytes only.
pub const StreamBuf = struct {
    buf: []u8 = &.{},
    len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    pub fn appendBytes(self: *StreamBuf, bytes: []const u8) void {
        const cur = self.len.load(.monotonic);
        if (cur >= self.buf.len) return;
        var n = @min(bytes.len, self.buf.len - cur);
        // Overflow drops the tail for good, so a clip must not land INSIDE a
        // codepoint: the missing bytes never arrive and the live row would
        // paint replacement garbage that persists for the rest of the turn.
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
            if (b < 0x80) return k; // ASCII byte ends a codepoint
            if (b >= 0xc0) { // lead byte: does its whole sequence fit?
                const len = std.unicode.utf8ByteSequenceLength(b) catch return k - 1;
                return if (k - 1 + len <= n) n else k - 1;
            }
        }
        return 0; // all continuation bytes: nothing whole to keep
    }

    pub fn snapshot(self: *StreamBuf, gpa: std.mem.Allocator) ?[]u8 {
        const n = self.len.load(.acquire);
        if (n == 0) return null;
        return gpa.dupe(u8, self.buf[0..n]) catch null;
    }
};

/// A turn backend gets the live text buffer AND the typed event queue (#551):
/// prose streams into `stream` for the pending row's tail view, while every
/// structured moment (tool call, outcome, refusal, notice, failover) is PUSHED
/// as an event. The TUI used to recover the second kind by parsing the first,
/// which is the defect this seam removes.
pub const TurnFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator, history: []const Turn, params: Params, stream: *StreamBuf, events: *events_mod.Queue) ?[]const u8;
/// How a seat is PAID FOR. The TUI never derives this — src/billing.zig owns
/// the rule and the engine hands the answer over with the catalog, the same
/// way it hands over the model names themselves.
pub const CostClass = enum {
    plan,
    credits,
    api,
    local,

    pub fn badge(self: CostClass) []const u8 {
        return switch (self) {
            .plan => "plan",
            .credits => "credits",
            .api => "api",
            .local => "local",
        };
    }
};

/// One row of the model catalog. A bare name was ambiguous: the same model
/// served by codex (a ChatGPT plan), codegraff (gateway credits) and openai (a
/// metered key) drew three identical rows, and picking one resolved the
/// provider by first-name-match rather than by the row the user chose.
pub const ModelEntry = struct {
    name: []const u8,
    provider: []const u8 = "",
    /// False when this provider has no credential in this session. The row
    /// stays — knowing the seat EXISTS is the point — but it is dimmed.
    has_key: bool = false,
    cost: CostClass = .api,
};

/// What a switch actually landed on. The provider travels back with the model
/// so the current-row marker can tell two same-named seats apart.
pub const Picked = struct { model: []const u8, provider: []const u8 = "" };

/// Switch to `name` ON `provider`. An empty `provider` means "the caller does
/// not know one" (a hand-typed `/model <name>`) and asks the engine to route
/// by name, which is what the picker used to be stuck doing for every pick.
pub const ModelFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator, provider: []const u8, name: []const u8) ?Picked;
pub const CancelFn = *const fn (turn_ctx: ?*anyopaque) void;
/// Fill dest with a staged image path (return >0) or an error line (return <0).
pub const PasteFn = *const fn (turn_ctx: ?*anyopaque, dest: []u8) isize;
/// Run a user-typed `!` shell line; return combined output (caller frees), the
/// gate's refusal, or null when the harness could not produce either. `params`
/// carries the session's policy because `!` goes through the same gate the
/// model's bash tool does — a `!` under /plan must be refused (#551).
pub const BashFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator, cmd: []const u8, params: Params) ?[]const u8;
/// Newline-joined repo-relative paths for @-search (caller frees), or null.
pub const FilesFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator) ?[]const u8;
/// Copy text to the system clipboard; true on success.
pub const CopyFn = *const fn (turn_ctx: ?*anyopaque, text: []const u8) bool;
/// Engine-owned history compaction. Fills `out` with gpa-owned note + turns
/// (caller frees). Returns false when history is unchanged.
pub const CompactOut = struct {
    note: []const u8 = "",
    turns: []Turn = &.{},
};
pub const CompactFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator, history: []const Turn, out: *CompactOut) bool;

/// The frontend just discarded part of its transcript. The engine owns the
/// conversation the model actually sees (#551), so it has to be told: without
/// this, /new left the whole old session in the request body and /rewind left
/// a prompt the user had taken back.
pub const HistoryOp = enum { reset, rewind };
pub const HistoryFn = *const fn (turn_ctx: ?*anyopaque, op: HistoryOp) void;

/// Host-side `/goal` verb. `.none` is a snapshot (strict/ultracode/rename):
/// the host must not re-apply or mint a goal. Typed TUI `/goal` is the same
/// retirable lifecycle as the line REPL — never a standing `--goal` (#716).
pub const GoalOp = enum { none, set, clear, pause, unpause };

pub const SessionState = struct {
    session_name: []const u8 = "",
    goal: []const u8 = "",
    strict: bool = false,
    ultracode: bool = false,
    goal_op: GoalOp = .none,
};
pub const StateFn = *const fn (turn_ctx: ?*anyopaque, state: SessionState) void;

pub const ResumeOut = struct {
    turns: []Turn = &.{},
    session_name: []const u8 = "",
    goal: []const u8 = "",
    strict: bool = false,
    ultracode: bool = false,
    note: []const u8 = "",
};
pub const ResumeFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator, spec: []const u8, out: *ResumeOut) bool;
/// Newline-joined saved-session rows (`base\tlabel\tdesc`) for `/resume` (caller frees), or null.
pub const SessionsFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator) ?[]const u8;

test "StreamBuf: append then snapshot, overflow is silent" {
    var buf: [8]u8 = undefined;
    var s: StreamBuf = .{ .buf = &buf };
    s.appendBytes("hello");
    const snap = s.snapshot(std.testing.allocator).?;
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqualStrings("hello", snap);
    s.appendBytes(" world!!!!");
    try std.testing.expectEqual(@as(usize, 8), s.len.load(.acquire));
}

test "StreamBuf: an overflow clip lands on a codepoint boundary" {
    // The dropped tail never arrives, so a clip inside 🚀 would leave the live
    // row painting replacement garbage for the rest of the turn.
    var buf: [8]u8 = undefined;
    var s: StreamBuf = .{ .buf = &buf };
    s.appendBytes("ab");
    s.appendBytes("🚀🚀"); // 8 bytes: only the first fits whole
    const snap = s.snapshot(std.testing.allocator).?;
    defer std.testing.allocator.free(snap);
    try std.testing.expect(std.unicode.utf8ValidateSlice(snap));
    try std.testing.expectEqualStrings("ab🚀", snap);
    // A chunk that cannot contribute even one whole glyph writes nothing.
    var tiny: [2]u8 = undefined;
    var t: StreamBuf = .{ .buf = &tiny };
    t.appendBytes("日");
    try std.testing.expectEqual(@as(usize, 0), t.len.load(.acquire));
}
