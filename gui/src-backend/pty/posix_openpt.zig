// Adapted from PaNDa2code/zig_openpty (https://github.com/PaNDa2code/zig_openpty).
// Verified base commit: dbd62ff200cf9e1fee36d71175945016e0c54c6a.
// Vendored intentionally: Codegraff keeps PTY support dependency-free.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;

const os_tag = builtin.os.tag;

pub fn posix_openpt(flags: posix.O) posix.OpenError!posix.fd_t {
    return if (os_tag == .linux)
        @bitCast(@as(u32, @truncate(linux.open("/dev/ptmx", flags, 0))))
    else
        @intCast(std.c.open("/dev/ptmx", flags));
}
