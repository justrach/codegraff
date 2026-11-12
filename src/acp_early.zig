//! `graff acp` answers the client's `initialize` during boot instead of after
//! the root Agent exists (ADR 0338). Single-threaded: at
//! each boot phase boundary the main thread asks stdin, without blocking,
//! whether a complete first line is buffered. If it is an `initialize`
//! request, the line is taken off the ONE stdin reader the dispatch loop later
//! reads, answered through the engine's own `handleLine`, and kept. At loop
//! start that line is dispatched again through the normal handler with its
//! output discarded, so the live `Dispatch` and the process latches are rebuilt
//! by the code that builds them on the late path.
//!
//! `step` is the decision the Lean kernel `Graff.AcpEarlyInit` models; nothing
//! here decides without it. A first line that is incomplete, not `initialize`,
//! or larger than the stdin buffer is left in place for the loop. So is an
//! `initialize` whose answer could not be rendered, written and flushed whole:
//! the line is taken off stdin only after the client has the full answer.
//!
//! A build without ACP (`-Dacp=false`, `-Dminimal`) compiles none of the
//! engine: `boundary` declines at comptime before anything reaches it.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const engine = @import("acp_engine.zig");
const proto = @import("acp_protocol.zig");
const startup_timing = @import("startup_timing.zig");

// ── the kernel: lean-proofs/Graff/AcpEarlyInit.lean `step` ─────────────────

/// `answering`: the answer is being written; the line is still on stdin.
pub const State = enum { booting, answering, answered, passed, loop };
/// What the shared stdin buffer holds at a check. `none`/`incomplete`: no
/// complete first line yet; `initialize`: a complete `initialize` request
/// with an id; `other`: any other complete first line.
pub const Line = enum { none, incomplete, initialize, other };
/// `acp` is ACP mode with a clean protocol stdout; false declines for good.
/// `sent`: whether the whole framed answer reached the transport.
pub const Event = union(enum) { boundary: struct { acp: bool, line: Line }, sent: bool, loop_start };
/// `answer`: write the answer, consume nothing; `take`: consume and keep the
/// line; `replay`: hand the kept line to the loop.
pub const Action = enum { none, answer, take, replay };
pub const Step = struct { next: State, action: Action };

pub fn step(s: State, e: Event) Step {
    return switch (e) {
        .boundary => |b| switch (s) {
            .booting => if (!b.acp) .{ .next = .passed, .action = .none } else switch (b.line) {
                .none, .incomplete => .{ .next = .booting, .action = .none },
                .initialize => .{ .next = .answering, .action = .answer },
                .other => .{ .next = .passed, .action = .none },
            },
            .answering, .answered, .passed, .loop => .{ .next = s, .action = .none },
        },
        // A failed answer leaves the line to the loop, which then fails or
        // answers exactly as it would have without the early attempt.
        .sent => |ok| if (s != .answering) .{ .next = s, .action = .none } else if (ok) .{ .next = .answered, .action = .take } else .{ .next = .passed, .action = .none },
        .loop_start => .{ .next = .loop, .action = if (s == .answered) .replay else .none },
    };
}

// ── the response ───────────────────────────────────────────────────────────

/// What the live CLI dispatch advertises as `can_load`: `acp_session_load.
/// configure` always installs a loader (pinned by a test below).
pub const live_can_load = true;

fn noTurn(_: *anyopaque, _: Allocator, _: []const u8) anyerror![]const u8 {
    return "";
}

fn noLoad(_: *anyopaque, _: Allocator, _: *Io.Writer, _: proto.Request) anyerror!void {}

/// The `initialize` answer, written by the engine's `handleLine` on a fresh
/// dispatch whose only setting the response reads (`load_session != null`)
/// matches the live one. The process latches it sets are overwritten by the
/// replay at loop start (last writer wins, ADR 0206 latch).
///
/// True only when the whole answer, one complete line, was written and
/// flushed. It is rendered aside first, so an engine or allocation failure
/// writes nothing. On a write failure the bytes still buffered in `w` are
/// dropped (`w` was empty on entry); bytes the OS already accepted cannot be
/// recalled, and the transport is then broken for the loop's write as well.
pub fn respond(gpa: Allocator, w: *Io.Writer, line: []const u8, can_load: bool) bool {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var rendered: Io.Writer.Allocating = .init(arena.allocator());
    var scratch: engine.Dispatch = .{ .turn = noTurn, .ctx = undefined, .load_session = if (can_load) noLoad else null };
    engine.implementation_version = build_options.version;
    engine.handleLine(&scratch, arena.allocator(), &rendered.writer, line) catch return false;
    const bytes = rendered.written();
    if (!std.mem.endsWith(u8, bytes, "\n")) return false;
    w.writeAll(bytes) catch return dropBuffered(w);
    w.flush() catch return dropBuffered(w);
    return true;
}

fn dropBuffered(w: *Io.Writer) bool {
    w.undo(w.end);
    return false;
}

// ── the runtime ────────────────────────────────────────────────────────────

pub const Early = struct {
    gpa: Allocator,
    in: *Io.Reader,
    out: *Io.Writer,
    acp: bool,
    /// Polled for readiness; null reads only what is already buffered.
    fd: ?Io.File.Handle = null,
    can_load: bool = live_can_load,
    state: State = .booting,
    /// The consumed `initialize`, owned until the loop has dispatched it.
    stash: ?[]u8 = null,
    handed: ?[]u8 = null,

    const max_reads_per_check = 8;

    /// One phase boundary: classify the first line, then do what `step` says.
    pub fn boundary(self: *Early) bool {
        if (comptime !build_options.acp) return false;
        if (self.state != .booting) return false;
        const ready = self.acp and self.out.buffered().len == 0;
        var copy: ?[]u8 = null;
        const line: Line = if (ready) self.probe(&copy) else .none;
        const s = step(self.state, .{ .boundary = .{ .acp = ready, .line = line } });
        self.state = s.next;
        if (s.action != .answer) {
            if (copy) |c| self.gpa.free(c);
            return false;
        }
        const taken = copy.?;
        const t = step(self.state, .{ .sent = respond(self.gpa, self.out, taken, self.can_load) });
        self.state = t.next;
        if (t.action != .take) {
            self.gpa.free(taken);
            return false;
        }
        self.in.toss(taken.len + 1);
        self.stash = taken;
        return true;
    }

    /// Loop start: the line to dispatch with its output discarded, or null.
    /// A slice handed out stays valid until the next call.
    pub fn loopStart(self: *Early) ?[]const u8 {
        if (self.handed) |h| self.gpa.free(h);
        self.handed = null;
        const s = step(self.state, .loop_start);
        self.state = s.next;
        if (s.action != .replay) return null;
        self.handed = self.stash;
        self.stash = null;
        return self.handed;
    }

    /// Never blocks: reads only while poll says stdin is readable, and never
    /// past a full buffer. `copy` receives the line only for `.initialize`.
    fn probe(self: *Early, copy: *?[]u8) Line {
        const in = self.in;
        var reads: usize = 0;
        while (true) {
            if (std.mem.indexOfScalar(u8, in.buffered(), '\n')) |n| return self.classify(in.buffered()[0..n], copy);
            if (in.bufferedLen() == in.buffer.len) return .incomplete;
            if (reads == max_reads_per_check or !self.readable()) break;
            in.fillMore() catch break;
            reads += 1;
        }
        return if (in.bufferedLen() == 0) .none else .incomplete;
    }

    fn classify(self: *Early, line: []const u8, copy: *?[]u8) Line {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const req = proto.parseRequest(arena.allocator(), line) orelse return .other;
        if (!std.mem.eql(u8, req.method, "initialize") or req.id == null) return .other;
        // Out of memory: not consumed, so the loop still answers it.
        copy.* = self.gpa.dupe(u8, line) catch return .incomplete;
        return .initialize;
    }

    fn readable(self: *Early) bool {
        if (comptime builtin.os.tag == .windows or builtin.os.tag == .wasi) return false;
        const fd = self.fd orelse return false;
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const n = std.posix.poll(&fds, 0) catch return false;
        return n > 0 and fds[0].revents != 0;
    }
};

// ── process wiring (main.zig, acp.zig) ─────────────────────────────────────

var stdin_buf: [64 * 1024]u8 = undefined;
var stdin_reader: Io.File.Reader = undefined;
var g: ?Early = null;

pub fn isAcp(positionals: []const []const u8) bool {
    return (comptime build_options.acp) and positionals.len > 0 and std.mem.eql(u8, positionals[0], "acp");
}

/// Creates the process stdin reader (every frontend reads this one) and runs
/// the first check. Outside ACP the first `step` declines without reading.
pub fn arm(io: Io, gpa: Allocator, out: *Io.Writer, positionals: []const []const u8) *Io.Reader {
    stdin_reader = Io.File.stdin().reader(io, &stdin_buf);
    g = .{ .gpa = gpa, .in = &stdin_reader.interface, .out = out, .acp = isAcp(positionals), .fd = Io.File.stdin().handle };
    _ = g.?.boundary();
    return &stdin_reader.interface;
}

/// The ACP loop's first-iteration hook; null outside a process that armed.
pub fn loopStart() ?[]const u8 {
    if (g) |*e| return e.loopStart();
    return null;
}

/// The boot tracker with a check at every phase boundary.
pub const Boot = struct {
    inner: startup_timing.Tracker,
    told: bool = false,

    /// With `GRAFF_BOOT_DEBUG`, names where the early answer happened: the
    /// mark it followed, or the check `arm` runs when stdin is opened.
    pub fn mark(self: *Boot, io: Io, label: []const u8) void {
        self.inner.mark(io, label);
        const e = if (g) |*e| e else return;
        const now = e.boundary();
        if (!self.inner.debug or self.told or e.state != .answered) return;
        self.told = true;
        std.debug.print("[boot] acp initialize answered {s}{s}\n", .{ if (now) "after " else "when stdin was opened, before ", label });
    }

    pub fn attach(self: *Boot, tracer: anytype) void {
        self.inner.attach(tracer);
    }
};

test {
    _ = @import("acp_early_tests.zig");
}
