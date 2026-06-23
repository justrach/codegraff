const std = @import("std");
const builtin = @import("builtin");
const openpty_mod = @import("openpty.zig");
const ioctl = @import("ioctl.zig");

pub const SpawnOptions = struct {
    shell: []const u8,
    cwd: []const u8,
    cols: u16,
    rows: u16,
};

pub const PtyProcess = struct {
    master_fd: std.posix.fd_t,
    pid: std.c.pid_t,
    name: []const u8,

    pub fn write(self: *PtyProcess, data: []const u8) !usize {
        if (data.len == 0) return 0;
        const written = std.c.write(self.master_fd, data.ptr, data.len);
        if (written < 0) return error.WriteFailed;
        return @intCast(written);
    }

    pub fn writeAll(self: *PtyProcess, data: []const u8) !void {
        var offset: usize = 0;
        while (offset < data.len) {
            const written = try self.write(data[offset..]);
            if (written == 0) return error.WriteFailed;
            offset += written;
        }
    }

    pub fn read(self: *PtyProcess, buffer: []u8) !usize {
        if (buffer.len == 0) return 0;
        const n = std.c.read(self.master_fd, buffer.ptr, buffer.len);
        if (n == 0) return error.EndOfStream;
        if (n < 0) return error.ReadFailed;
        return @intCast(n);
    }

    pub fn resize(self: *PtyProcess, cols: u16, rows: u16) !void {
        var ws: std.posix.winsize = .{
            .row = rows,
            .col = cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        const rc = switch (builtin.os.tag) {
            .linux => std.os.linux.ioctl(self.master_fd, ioctl.TIOCSWINSZ, @intFromPtr(&ws)),
            .macos => std.c.ioctl(self.master_fd, ioctl.TIOCSWINSZ, @intFromPtr(&ws)),
            else => @compileError("Unsupported PTY platform"),
        };
        if (std.posix.errno(rc) != .SUCCESS) return error.ResizeFailed;
    }

    pub fn close(self: *PtyProcess) void {
        closeFd(self.master_fd);
    }

    pub fn terminate(self: *PtyProcess) void {
        _ = std.c.kill(self.pid, .HUP);
    }

    pub fn wait(self: *PtyProcess) ?i64 {
        var status: c_int = 0;
        const rc = std.c.waitpid(self.pid, &status, 0);
        if (rc <= 0) return null;
        if ((status & 0x7f) == 0) return @intCast((status >> 8) & 0xff);
        return null;
    }
};

fn closeFd(fd: std.posix.fd_t) void {
    _ = switch (builtin.os.tag) {
        .linux => std.os.linux.close(fd),
        else => std.c.close(fd),
    };
}

fn dupTo(slave_fd: std.posix.fd_t, target: std.c.fd_t) void {
    if (std.c.dup2(slave_fd, target) < 0) std.c.exit(126);
}

fn allocPrintZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    return try allocator.dupeZ(u8, text);
}

pub fn spawnShell(allocator: std.mem.Allocator, options: SpawnOptions) !PtyProcess {
    var master_fd: std.posix.fd_t = undefined;
    var slave_fd: std.posix.fd_t = undefined;
    var name_buf: [@import("ptsname.zig").ptsname_max_size]u8 = undefined;
    var name_len: usize = 0;
    var ws: std.posix.winsize = .{
        .row = options.rows,
        .col = options.cols,
        .xpixel = 0,
        .ypixel = 0,
    };

    try openpty_mod.openpty(&master_fd, &slave_fd, &name_buf, &name_len, null, &ws);
    errdefer closeFd(master_fd);
    errdefer closeFd(slave_fd);

    const shell_z = try allocator.dupeZ(u8, options.shell);
    const cwd_z = try allocator.dupeZ(u8, options.cwd);
    const shell_env_z = try allocPrintZ(allocator, "SHELL={s}", .{options.shell});
    const cols_z = try allocPrintZ(allocator, "COLUMNS={d}", .{options.cols});
    const lines_z = try allocPrintZ(allocator, "LINES={d}", .{options.rows});

    const argv = try allocator.alloc(?[*:0]const u8, 9);
    argv[0] = "/usr/bin/env";
    argv[1] = "TERM=xterm-256color";
    argv[2] = "COLORTERM=truecolor";
    argv[3] = shell_env_z.ptr;
    argv[4] = cols_z.ptr;
    argv[5] = lines_z.ptr;
    argv[6] = shell_z.ptr;
    argv[7] = "-l";
    argv[8] = null;

    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        closeFd(master_fd);
        if (std.c.setsid() < 0) std.c.exit(126);
        _ = switch (builtin.os.tag) {
            .linux => std.os.linux.ioctl(slave_fd, ioctl.TIOCSCTTY, 0),
            .macos => std.c.ioctl(slave_fd, ioctl.TIOCSCTTY, @as(c_int, 0)),
            else => @compileError("Unsupported PTY platform"),
        };
        dupTo(slave_fd, 0);
        dupTo(slave_fd, 1);
        dupTo(slave_fd, 2);
        if (slave_fd > 2) closeFd(slave_fd);
        if (std.c.chdir(cwd_z.ptr) < 0) {}
        _ = std.c.execve("/usr/bin/env", @ptrCast(argv.ptr), std.c.environ);
        _ = std.c.execve(shell_z.ptr, @ptrCast(argv[6..].ptr), std.c.environ);
        std.c.exit(127);
    }

    closeFd(slave_fd);
    return .{
        .master_fd = master_fd,
        .pid = pid,
        .name = try allocator.dupe(u8, name_buf[0..name_len]),
    };
}
