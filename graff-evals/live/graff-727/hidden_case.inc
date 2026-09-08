
test "printRunning formats a multi-minute wait" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try printRunning(&aw.writer, 5, 125_000, true);
    try std.testing.expectEqualStrings("[job 5: running · 2m05s waited, then interrupted — you are notified on exit; do not call bash_output again]", aw.written());
}
