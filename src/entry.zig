//! The release CLI's root module. It only forwards to graff (src/main.zig,
//! the `graff` module), so graff keeps its own build mode while std, built
//! with the root, can be built for size. See build.zig.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    return @import("graff").main(init);
}
