//! Frontend-agnostic types the TUI uses to talk to a turn backend.
//! The package never imports the harness: session glue supplies callbacks.

const std = @import("std");

pub const Effort = enum { low, medium, high, xhigh, max, ultra };

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
        const n = @min(bytes.len, self.buf.len - cur);
        @memcpy(self.buf[cur .. cur + n], bytes[0..n]);
        self.len.store(cur + n, .release);
    }

    pub fn snapshot(self: *StreamBuf, gpa: std.mem.Allocator) ?[]u8 {
        const n = self.len.load(.acquire);
        if (n == 0) return null;
        return gpa.dupe(u8, self.buf[0..n]) catch null;
    }
};

pub const TurnFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator, history: []const Turn, params: Params, stream: *StreamBuf) ?[]const u8;
pub const ModelFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator, name: []const u8) ?[]const u8;
pub const CancelFn = *const fn (turn_ctx: ?*anyopaque) void;
/// Fill dest with a staged image path (return >0) or an error line (return <0).
pub const PasteFn = *const fn (turn_ctx: ?*anyopaque, dest: []u8) isize;
/// Run a user-typed `!` shell line in the session cwd; return combined
/// output (caller frees) or null when the spawn itself failed.
pub const BashFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator, cmd: []const u8) ?[]const u8;
/// Newline-joined repo-relative paths for @-search (caller frees), or null.
pub const FilesFn = *const fn (turn_ctx: ?*anyopaque, gpa: std.mem.Allocator) ?[]const u8;
/// Copy text to the system clipboard; true on success.
pub const CopyFn = *const fn (turn_ctx: ?*anyopaque, text: []const u8) bool;

pub const Job = struct {
    thread: std.Thread = undefined,
    threaded: bool = true,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result: ?[]const u8 = null,
    gpa: std.mem.Allocator,
    history: []Turn,
    params: Params,
    stream: StreamBuf,
};

pub const HudKind = enum { debug, usage };
pub const HudFn = *const fn (kind: HudKind, buf: []u8) usize;

pub var g_turn_fn: ?TurnFn = null;
pub var g_turn_ctx: ?*anyopaque = null;
pub var g_model_fn: ?ModelFn = null;
pub var g_cancel_fn: ?CancelFn = null;
pub var g_hud_fn: ?HudFn = null;
pub var g_paste_fn: ?PasteFn = null;
pub var g_bash_fn: ?BashFn = null;
pub var g_files_fn: ?FilesFn = null;
pub var g_copy_fn: ?CopyFn = null;
pub var g_model_name: []const u8 = "";
pub var g_models: []const u8 = "";
pub var g_cwd: []const u8 = ".";

pub fn jobRun(job: *Job) void {
    const reply = if (g_turn_fn) |f| f(g_turn_ctx, job.gpa, job.history, job.params, &job.stream) else null;
    job.result = reply;
    job.done.store(true, .release);
}

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
