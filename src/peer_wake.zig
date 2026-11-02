//! Bounded live wake for `graff peer send` (#1718).
//!
//! The durable room post is the contract; the Accord wake that follows it is
//! best effort (presence_accord.zig). A wake used to run an `accord.Session`
//! per recipient, one after another, with no deadline: a recipient whose
//! socket the kernel accepted but that never answered the preface blocked
//! `Session.start` forever, and one that answered but stopped reading blocked
//! `Session.send` forever once the frame outgrew the socket buffer. Either
//! held the command, and the agent turn that ran it, open indefinitely.
//!
//! Here every recipient runs the same client half of the Accord handshake
//! (preface out, preface in, one `msg` frame on stream 1) on its own
//! nonblocking socket, all multiplexed in one `poll` loop under one shared
//! deadline. There is no reader thread to join: when the deadline passes,
//! every unfinished socket is closed and counted as missed, so N stalled
//! recipients cost one deadline, not N, and cannot keep a healthy one from
//! being attempted.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Io = std.Io;
const accord = @import("accord");

/// Whole fan-out budget for one send: connect, handshake, frame and close
/// for every recipient together. A live graff answers in milliseconds.
pub const default_deadline_ms: u32 = 2000;

/// Sent instead of a line too big for the recipient's frame limit: the
/// receiver only needs the frame kind to start draining the durable room.
pub const marker_payload = "{\"kind\":\"wake\"}";

pub const Outcome = struct {
    /// Recipients that completed the handshake and took the frame.
    woke: usize = 0,
    /// Recipients that refused, failed, or ran out of time.
    missed: usize = 0,
};

const Phase = enum { connecting, send_preface, read_preface, send_frame, done, failed };

const Peer = struct {
    fd: posix.fd_t = -1,
    phase: Phase = .failed,
    out: []const u8 = &.{},
    sent: usize = 0,
    in: [accord.preface_size]u8 = undefined,
    got: usize = 0,
};

/// Wake every Unix socket in `paths` with `line` as one Accord `msg` frame,
/// all concurrently, giving up on whatever has not finished after
/// `deadline_ms`. Never blocks past the deadline (plus one close per socket).
pub fn wakeAll(io: Io, gpa: std.mem.Allocator, paths: []const []const u8, line: []const u8, deadline_ms: u32) Outcome {
    if (paths.len == 0) return .{};
    if (builtin.os.tag == .windows) return .{ .missed = paths.len };
    return wakeAllPosix(io, gpa, paths, line, deadline_ms);
}

fn wakeAllPosix(io: Io, gpa: std.mem.Allocator, paths: []const []const u8, line: []const u8, deadline_ms: u32) Outcome {
    const peers = gpa.alloc(Peer, paths.len) catch return .{ .missed = paths.len };
    defer gpa.free(peers);
    const fds = gpa.alloc(posix.pollfd, paths.len) catch return .{ .missed = paths.len };
    defer gpa.free(fds);
    const slots = gpa.alloc(usize, paths.len) catch return .{ .missed = paths.len };
    defer gpa.free(slots);

    var preface: [accord.preface_size]u8 = undefined;
    accord.encodePreface(&preface);
    const full_buf = gpa.alloc(u8, accord.header_size + @min(line.len, accord.max_payload)) catch return .{ .missed = paths.len };
    defer gpa.free(full_buf);
    const full_frame: ?[]const u8 = if (line.len <= accord.max_payload) frameInto(full_buf, line) else null;
    var marker_buf: [accord.header_size + marker_payload.len]u8 = undefined;
    const marker_frame = frameInto(&marker_buf, marker_payload) orelse return .{ .missed = paths.len };

    for (peers, paths) |*p, path| p.* = connect(path, &preface);
    defer for (peers) |p| if (p.fd >= 0) closeFd(p.fd);

    const start = Io.Timestamp.now(io, .awake);
    while (true) {
        var n: usize = 0;
        for (peers, 0..) |*p, i| {
            const events: i16 = switch (p.phase) {
                .connecting, .send_preface, .send_frame => posix.POLL.OUT,
                .read_preface => posix.POLL.IN,
                .done, .failed => continue,
            };
            fds[n] = .{ .fd = p.fd, .events = events, .revents = 0 };
            slots[n] = i;
            n += 1;
        }
        if (n == 0) break;
        const elapsed = @max(0, start.untilNow(io, .awake).toMilliseconds());
        if (elapsed >= deadline_ms) break;
        const left: i32 = @intCast(@as(i64, deadline_ms) - elapsed);
        const ready = posix.poll(fds[0..n], left) catch break;
        if (ready == 0) continue; // the deadline check above ends the loop
        for (fds[0..n], slots[0..n]) |pfd, i| {
            if (pfd.revents == 0) continue;
            step(&peers[i], pfd.revents, &preface, full_frame, marker_frame);
        }
    }

    var out: Outcome = .{};
    for (peers) |p| {
        if (p.phase == .done) out.woke += 1 else out.missed += 1;
    }
    return out;
}

fn frameInto(buf: []u8, payload: []const u8) ?[]const u8 {
    var w: Io.Writer = .fixed(buf);
    accord.writeFrame(&w, 1, .msg, .{}, payload) catch return null;
    return w.buffered();
}

/// Open a nonblocking socket and start connecting. A recipient that refuses
/// or whose accept queue is full fails here, without waiting.
fn connect(path: []const u8, preface: []const u8) Peer {
    var addr: posix.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return .{};
    @memcpy(addr.path[0..path.len], path);
    const rc = posix.system.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (posix.errno(rc) != .SUCCESS) return .{};
    const fd: posix.fd_t = @intCast(rc);
    var p: Peer = .{ .fd = fd };
    _ = posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC));
    const fl = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    if (posix.errno(fl) != .SUCCESS) return p;
    const nonblock: usize = 1 << @bitOffsetOf(posix.O, "NONBLOCK");
    if (posix.errno(posix.system.fcntl(fd, posix.F.SETFL, @as(usize, @intCast(fl)) | nonblock)) != .SUCCESS) return p;
    while (true) switch (posix.errno(posix.system.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)))) {
        .SUCCESS => {
            p.phase = .send_preface;
            p.out = preface;
            return p;
        },
        .INTR => continue,
        .INPROGRESS => {
            p.phase = .connecting;
            return p;
        },
        else => return p, // refused, missing, or a full accept queue (AGAIN)
    };
}

/// Advance one recipient after `poll` reported `revents` on its socket.
fn step(p: *Peer, revents: i16, preface: []const u8, full_frame: ?[]const u8, marker_frame: []const u8) void {
    switch (p.phase) {
        .connecting => {
            var err: i32 = 0;
            var len: posix.socklen_t = @sizeOf(i32);
            if (posix.errno(posix.system.getsockopt(p.fd, posix.SOL.SOCKET, posix.SO.ERROR, @ptrCast(&err), &len)) != .SUCCESS or err != 0) {
                p.phase = .failed;
                return;
            }
            p.phase = .send_preface;
            p.out = preface;
            p.sent = 0;
        },
        .send_preface, .send_frame => {
            if (revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0) {
                p.phase = .failed;
                return;
            }
            while (p.sent < p.out.len) {
                const rest = p.out[p.sent..];
                const rc = posix.system.send(p.fd, rest.ptr, rest.len, posix.MSG.NOSIGNAL);
                switch (posix.errno(rc)) {
                    .SUCCESS => p.sent += @intCast(rc),
                    .INTR => continue,
                    .AGAIN => return, // wait for POLLOUT again
                    else => {
                        p.phase = .failed;
                        return;
                    },
                }
            }
            p.phase = if (p.phase == .send_preface) .read_preface else .done;
        },
        .read_preface => {
            while (p.got < p.in.len) {
                const rc = posix.system.read(p.fd, p.in[p.got..].ptr, p.in.len - p.got);
                switch (posix.errno(rc)) {
                    .SUCCESS => {
                        if (rc == 0) { // closed before answering
                            p.phase = .failed;
                            return;
                        }
                        p.got += @intCast(rc);
                    },
                    .INTR => continue,
                    .AGAIN => return,
                    else => {
                        p.phase = .failed;
                        return;
                    },
                }
            }
            const peer_max = accord.decodePreface(&p.in) catch {
                p.phase = .failed;
                return;
            };
            const frame = full_frame orelse marker_frame;
            p.out = if (frame.len - accord.header_size <= peer_max) frame else marker_frame;
            p.sent = 0;
            p.phase = .send_frame;
        },
        .done, .failed => {},
    }
}

fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}
