//! THROWAWAY — do not commit. Proves whether restore.zig's fatal-signal set
//! covers a hardware fault (SIGSEGV) in the mode graff actually ships
//! (release.yml: -Doptimize=ReleaseFast).
const std = @import("std");
const restore = @import("restore.zig");
const tty = @import("tty.zig");

const enable_seq = "\x1b[?1049h\x1b[?25l\x1b[?2004h\x1b[?1000h\x1b[?1003h\x1b[?1006h\x1b[?7l\x1b[>11u\x1b[>4;2m";

pub fn main() !void {
    const raw = tty.enterRaw() orelse {
        _ = std.posix.system.write(2, "not a tty\n", 10);
        return;
    };
    restore.arm(raw);
    _ = std.posix.system.write(1, enable_seq.ptr, enable_seq.len);
    // Hardware fault: null deref, no runtime safety check in ReleaseFast.
    const p: *volatile u64 = @ptrFromInt(0x8);
    p.* = 1;
}
