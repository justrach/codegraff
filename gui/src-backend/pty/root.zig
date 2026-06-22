const std = @import("std");

pub const openpty = @import("openpty.zig").openpty;
pub const OpenPtyError = @import("openpty.zig").OpenPtyError;
pub const ptyname_max_len = @import("ptsname.zig").ptsname_max_size;

pub const PtyProcess = @import("process.zig").PtyProcess;
pub const SpawnOptions = @import("process.zig").SpawnOptions;
pub const spawnShell = @import("process.zig").spawnShell;

pub fn closeFd(fd: std.posix.fd_t) void {
    _ = switch (@import("builtin").os.tag) {
        .linux => std.os.linux.close(fd),
        else => std.c.close(fd),
    };
}

test "openpty returns fds and a device name" {
    var master_fd: std.posix.fd_t = undefined;
    var slave_fd: std.posix.fd_t = undefined;
    var name: [ptyname_max_len]u8 = undefined;
    var name_len: usize = undefined;

    try openpty(&master_fd, &slave_fd, &name, &name_len, null, null);
    defer closeFd(master_fd);
    defer closeFd(slave_fd);

    try std.testing.expect(master_fd >= 0);
    try std.testing.expect(slave_fd >= 0);
    try std.testing.expect(name_len > 0);
    try std.testing.expect(std.mem.startsWith(u8, name[0..name_len], "/dev/"));
}
