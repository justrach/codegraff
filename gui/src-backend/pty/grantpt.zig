// Adapted from PaNDa2code/zig_openpty (https://github.com/PaNDa2code/zig_openpty).
// Verified base commit: dbd62ff200cf9e1fee36d71175945016e0c54c6a.
// Vendored intentionally: Codegraff keeps PTY support dependency-free.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;

const pictl = @import("ioctl.zig");

const IoCtlError = pictl.IoCtlError;

pub fn grantpt(fd: posix.fd_t) IoCtlError!void {
    var ptyno: u32 = 0;

    const rc = switch (builtin.os.tag) {
        .linux => linux.ioctl(fd, pictl.TIOCGPTN, @intFromPtr(&ptyno)),
        .macos => std.c.ioctl(fd, 0x20007454),
        else => @compileError("Unsupported os"),
    };

    switch (posix.errno(rc)) {
        .SUCCESS => {},
        .BADF => return IoCtlError.InvalidFileDescriptor,
        .FAULT => return IoCtlError.InaccessibleMemory,
        .INVAL => return IoCtlError.BadRequistOrFlag,
        .NOTTY => return IoCtlError.NotTTY,
        else => return IoCtlError.Unexpcted,
    }
}
