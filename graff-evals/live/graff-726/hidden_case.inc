
test "dismiss before record spends the id once" {
    const io = std.testing.io;
    count = 0;
    dismissed_len = 0;
    var buf: [256]u8 = undefined;
    dismiss(io, 8);
    record(io, 8, 1, false, "false", false);
    try std.testing.expect(takeWake(io, &buf) == null);
    record(io, 8, 1, false, "false", false);
    try std.testing.expect(std.mem.indexOf(u8, takeWake(io, &buf) orelse "", "[job 8 exited 1: false]") != null);
}
