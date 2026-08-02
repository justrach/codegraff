//! #352: the one place the imagegen tool starts a child process.
//!
//! Both engines (codex exec, the image_gen.py CLI) and the sips helpers spawn
//! through `run`, which exists mostly so the unit tests can replace it. The
//! tool's whole job is deciding whether a generator really produced an image,
//! and those decisions have to be testable without a network, an API key, a
//! codex login, or a 6-minute timeout — so the seam sits at the process
//! boundary rather than inside each engine.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const jobs = @import("jobs.zig");

pub const Outcome = struct {
    /// null when the child did not exit normally (signal, timeout, cancel).
    exit_code: ?u8 = null,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    timed_out: bool = false,
    cancelled: bool = false,

    /// Exit 0 and nothing external ended it. NOT proof an image exists —
    /// #352 was a generator exiting 0 with a fabricated success transcript.
    pub fn ranClean(self: Outcome) bool {
        return !self.timed_out and !self.cancelled and self.exit_code != null and self.exit_code.? == 0;
    }
};

pub const Fn = *const fn (Allocator, Io, []const []const u8, u64, ?[]const u8) anyerror!Outcome;

/// Test seam. Set by a test, restored by its defer; never set in production.
pub var hook: ?Fn = null;

const stdout_cap = 64 * 1024;
const stderr_cap = 32 * 1024;

/// Run `argv` to completion under `deadline_ms`, optionally in `cwd`. Output
/// is capped and allocated from `arena`, so callers free nothing.
pub fn run(arena: Allocator, io: Io, argv: []const []const u8, deadline_ms: u64, cwd: ?[]const u8) !Outcome {
    if (hook) |f| return f(arena, io, argv, deadline_ms, cwd);
    // toolRunOptions owns the child's process group, so a deadline or an Esc
    // takes the whole tree down instead of orphaning a running generation.
    const r = try jobs.runCappedWithOptions(arena, io, argv, stdout_cap, stderr_cap, deadline_ms, jobs.toolRunOptions(cwd));
    return .{
        .exit_code = if (r.term == .exited) r.term.exited else null,
        .stdout = r.stdout,
        .stderr = r.stderr,
        .timed_out = r.timed_out,
        .cancelled = r.cancelled,
    };
}

/// The LAST bytes of a generator's output: a Python traceback and a codex
/// error both put the useful line at the end.
pub fn tail(text: []const u8, cap: usize) []const u8 {
    if (text.len <= cap) return text;
    const cut = text[text.len - cap ..];
    // Start on a line boundary so the excerpt never opens mid-UTF-8.
    return if (std.mem.indexOfScalar(u8, cut, '\n')) |nl| cut[nl + 1 ..] else cut;
}

test "#352: ranClean is exit 0 only, and never confuses a timeout or a cancel for success" {
    try std.testing.expect((Outcome{ .exit_code = 0 }).ranClean());
    try std.testing.expect(!(Outcome{ .exit_code = 1 }).ranClean());
    try std.testing.expect(!(Outcome{ .exit_code = null }).ranClean()); // signalled
    try std.testing.expect(!(Outcome{ .exit_code = 0, .timed_out = true }).ranClean());
    try std.testing.expect(!(Outcome{ .exit_code = 0, .cancelled = true }).ranClean());
}

test "#352: tail keeps the end of a traceback and starts on a line boundary" {
    try std.testing.expectEqualStrings("short", tail("short", 100));
    const long = "line one\nline two\nline three\n";
    const cut = tail(long, 14);
    try std.testing.expect(std.mem.indexOf(u8, cut, "line three") != null);
    try std.testing.expect(std.mem.indexOf(u8, cut, "line one") == null);
    try std.testing.expect(cut.len == 0 or cut[0] != '\n');
}

test "#352: the hook replaces the spawn entirely, so tests never start a process" {
    const S = struct {
        var seen_argv: []const []const u8 = &.{};
        var seen_cwd: ?[]const u8 = null;
        fn fake(_: Allocator, _: Io, argv: []const []const u8, _: u64, cwd: ?[]const u8) anyerror!Outcome {
            seen_argv = argv;
            seen_cwd = cwd;
            return .{ .exit_code = 0, .stdout = "faked" };
        }
    };
    const saved = hook;
    defer hook = saved;
    hook = S.fake;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try run(arena_state.allocator(), std.testing.io, &.{ "codex", "exec" }, 1, "/tmp/scratch");
    try std.testing.expectEqualStrings("faked", out.stdout);
    try std.testing.expectEqualStrings("codex", S.seen_argv[0]);
    try std.testing.expectEqualStrings("/tmp/scratch", S.seen_cwd.?);
}
