//! Hand probe: batch file reads via io_uring vs serial pread.
//! Not wired into `zig build test`. Linux only.
//!
//!   zig run scripts/io-uring-probe.zig
//!
//! Answers whether swapping process Io from Threaded to Evented/Uring
//! would move the SWE needle (ADR 0025).

const std = @import("std");
const linux = std.os.linux;

const n_files: usize = 64;
const file_bytes: usize = 4096;
const rounds: usize = 200;

pub fn main(init: std.process.Init) !void {
    if (@import("builtin").os.tag != .linux) {
        std.debug.print("linux only\n", .{});
        return;
    }
    const io = init.io;
    var tmp_buf: [65]u8 = undefined;
    const tmp = try zprint(&tmp_buf, "/tmp/graff-uring-{d}", .{linux.getpid()});
    _ = linux.unlink(tmp);
    const mk = linux.mkdir(tmp, 0o755);
    if (linux.errno(mk) != .SUCCESS) return error.Mkdir;

    var payload: [file_bytes]u8 = undefined;
    @memset(&payload, 'a');
    var fds: [n_files]std.posix.fd_t = undefined;
    for (0..n_files) |i| {
        var name_buf: [81]u8 = undefined;
        const name = try zprint(&name_buf, "{s}/f{d}", .{ tmp, i });
        const fd = linux.open(name, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
        if (linux.errno(fd) != .SUCCESS) return error.Open;
        fds[i] = @intCast(fd);
        const wrote = linux.write(fds[i], &payload, payload.len);
        if (linux.errno(wrote) != .SUCCESS or wrote != payload.len) return error.Write;
    }
    defer {
        for (fds) |fd| _ = linux.close(fd);
        for (0..n_files) |i| {
            var name_buf: [81]u8 = undefined;
            const name = zprint(&name_buf, "{s}/f{d}", .{ tmp, i }) catch continue;
            _ = linux.unlink(name);
        }
        _ = linux.rmdir(tmp);
    }

    var dest: [n_files][file_bytes]u8 = undefined;
    const serial_ns = try timeSerial(io, &fds, &dest);
    const uring_ns = try timeUring(io, &fds, &dest);
    std.debug.print(
        "n={d} size={d} rounds={d}\nserial_pread  {d} us/round\nio_uring batch {d} us/round\n",
        .{ n_files, file_bytes, rounds, serial_ns / rounds / 1000, uring_ns / rounds / 1000 },
    );
}

fn zprint(buf: []u8, comptime fmt: []const u8, args: anytype) ![:0]const u8 {
    const n = try std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args);
    buf[n.len] = 0;
    return buf[0..n.len :0];
}

fn timeSerial(io: std.Io, fds: *const [n_files]std.posix.fd_t, dest: *[n_files][file_bytes]u8) !u64 {
    const t0 = std.Io.Timestamp.now(io, .awake);
    for (0..rounds) |_| {
        for (fds, 0..) |fd, i| {
            const n = linux.pread(fd, &dest[i], dest[i].len, 0);
            if (linux.errno(n) != .SUCCESS or n != file_bytes) return error.ShortRead;
        }
    }
    return @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds - t0.nanoseconds);
}

fn timeUring(io: std.Io, fds: *const [n_files]std.posix.fd_t, dest: *[n_files][file_bytes]u8) !u64 {
    var ring = try linux.IoUring.init(128, 0);
    defer ring.deinit();
    const t0 = std.Io.Timestamp.now(io, .awake);
    for (0..rounds) |_| {
        for (fds, 0..) |fd, i| {
            _ = try ring.read(@intCast(i), fd, .{ .buffer = &dest[i] }, 0);
        }
        _ = try ring.submit_and_wait(n_files);
        var cqes: [n_files]linux.io_uring_cqe = undefined;
        const got = try ring.copy_cqes(&cqes, n_files);
        if (got != n_files) return error.ShortCq;
        for (cqes[0..got]) |c| {
            if (c.res != file_bytes) return error.ShortRead;
        }
    }
    return @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds - t0.nanoseconds);
}
