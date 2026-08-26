//! `graff-core.wasm` entry: export the libgraff C ABI, no `_start`.
//! Build: `zig build -Dwasm-surface=core`

const std = @import("std");

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    @trap();
}

comptime {
    _ = @import("libgraff.zig");
}
