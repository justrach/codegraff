// Adapted from PaNDa2code/zig_openpty (https://github.com/PaNDa2code/zig_openpty).
// Verified base commit: dbd62ff200cf9e1fee36d71175945016e0c54c6a.
// Vendored intentionally: Codegraff keeps PTY support dependency-free.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const posix_openpt = @import("posix_openpt.zig").posix_openpt;

pub fn getpt() posix.OpenError!posix.fd_t {
    return posix_openpt(.{
        .ACCMODE = .RDWR,
        .NOCTTY = builtin.os.tag == .macos,
    });
}
