//! Offline process-boundary probe used by test-shell-identity.py.
const std = @import("std");
pub fn main(init: std.process.Init) !void {
    const id = try @import("shell_identity.zig").reserve(init.io, init.environ_map.get("HOME") orelse "");
    std.debug.print("{d}\n", .{id});
    if (init.environ_map.get("GRAFF_TEST_RESERVATION_HOLD") != null)
        while (true) try init.io.sleep(.fromSeconds(60), .awake);
}
