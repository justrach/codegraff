// Adapted from PaNDa2code/zig_openpty (https://github.com/PaNDa2code/zig_openpty).
// Verified base commit: dbd62ff200cf9e1fee36d71175945016e0c54c6a.
// Vendored intentionally: Codegraff keeps PTY support dependency-free.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;

const pictl = @import("ioctl.zig");

const IoCtlError = pictl.IoCtlError;

pub const ptsname_max_size = 128;

pub fn ptsname(fd: posix.fd_t, buffer: [:0]u8) ![]const u8 {
    var ptyno: u32 = 0;
    var name: []const u8 = undefined;

    @memset(buffer, 0);

    switch (builtin.os.tag) {
        .linux => {
            const rc = linux.ioctl(fd, pictl.TIOCGPTN, @intFromPtr(&ptyno));
            try switch (posix.errno(rc)) {
                .SUCCESS => {},
                .BADF => IoCtlError.InvalidFileDescriptor,
                .FAULT => IoCtlError.InaccessibleMemory,
                .INVAL => IoCtlError.BadRequistOrFlag,
                .NOTTY => IoCtlError.NotTTY,
                else => IoCtlError.Unexpcted,
            };
            name = try std.fmt.bufPrintZ(buffer, "/dev/pts/{}", .{ptyno});
        },
        .macos => {
            const rc = std.c.ioctl(fd, pictl.TIOCPTYGNAME, @intFromPtr(buffer.ptr));
            try switch (posix.errno(rc)) {
                .SUCCESS => {},
                .BADF => IoCtlError.InvalidFileDescriptor,
                .FAULT => IoCtlError.InaccessibleMemory,
                .INVAL => IoCtlError.BadRequistOrFlag,
                .NOTTY => IoCtlError.NotTTY,
                else => IoCtlError.Unexpcted,
            };
            name = std.mem.sliceTo(buffer.ptr, 0);
        },
        else => {},
    }

    return name;
}
