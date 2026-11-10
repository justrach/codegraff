//! Cross-process advisory lock and cancellation-shielded HTTP exchange for
//! single-use OAuth refresh grants (#1612).
//!
//! Two invariants protect rotated single-use `refresh_token` grants:
//! 1. Processes sharing `~/.codex/auth.json`, `~/.graff/credentials/*.json`,
//!    `~/.kimi/credentials/graff-oauth.json`, `~/.xai/credentials/graff-oauth.json`,
//!    `~/.anthropic/credentials/graff-oauth.json`, or `~/.simple-harness-mcp/*.json`
//!    acquire an in-process `Io.Mutex`, then an OS advisory lock (`flock` /
//!    `NtLockFile`) on `<cred_path>.lock`, and re-read disk inside the lock so
//!    waiters adopt the winner's freshly written credential with zero HTTP calls.
//!    Read-only or lockless mounts degrade gracefully (`file = null`) rather than
//!    blocking refreshes.
//! 2. Once the token refresh POST begins, `CancelShield` (`swapCancelProtection`)
//!    blocks `error.Canceled` across the HTTP exchange and atomic credential
//!    persistence so user `Esc` / ACP `session/cancel` cannot sever rotation
//!    after the upstream server has invalidated the prior `refresh_token`.
//!    `fetchPostBounded` bounds the HTTP exchange via `Io.Select` (default 30s)
//!    so a stalled socket still times out cleanly while cancel-shielded.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const credential_store = @import("credential_store.zig");

pub const default_exchange_timeout_ms: u64 = 30_000;

pub const Guard = struct {
    io: Io,
    mu: ?*Io.Mutex = null,
    file: ?Io.File = null,

    pub fn release(self: Guard) void {
        if (self.file) |f| f.close(self.io);
        if (self.mu) |m| m.unlock(self.io);
    }
};

pub fn lockPath(arena: Allocator, cred_path: []const u8) ?[]const u8 {
    if (cred_path.len == 0) return null;
    return std.fmt.allocPrint(arena, "{s}.lock", .{cred_path}) catch null;
}

/// Acquire only the cross-process advisory `<cred_path>.lock`. Returns `null`
/// only when canceled while waiting (leaving cancelation armed via `recancel`);
/// filesystem errors degrade to `.file = null`.
pub fn acquireFile(io: Io, arena: Allocator, cred_path: []const u8) ?Guard {
    const path = lockPath(arena, cred_path) orelse return .{ .io = io };
    const file = Io.Dir.cwd().createFile(io, path, .{
        .truncate = false,
        .lock = .exclusive,
        .permissions = credential_store.private_file,
    }) catch |err| switch (err) {
        error.Canceled => {
            io.recancel();
            return null;
        },
        else => return .{ .io = io, .file = null },
    };
    return .{ .io = io, .file = file };
}

/// Acquire `mu` (in-process) and then `<cred_path>.lock` (cross-process).
/// Returns `null` if canceled before entering the critical section.
pub fn acquire(io: Io, arena: Allocator, mu: *Io.Mutex, cred_path: []const u8) ?Guard {
    mu.lock(io) catch {
        io.recancel();
        return null;
    };
    const fg = acquireFile(io, arena, cred_path) orelse {
        mu.unlock(io);
        return null;
    };
    return .{ .io = io, .mu = mu, .file = fg.file };
}

/// Shields an in-flight OAuth refresh POST + credential write from caller
/// task cancelation (`Esc` / `Future.cancel`), restoring the prior protection
/// state (and any unconsumed cancelation signal) on `leave()`.
pub const CancelShield = struct {
    io: Io,
    prev: Io.CancelProtection,

    pub fn enter(io: Io) CancelShield {
        return .{ .io = io, .prev = io.swapCancelProtection(.blocked) };
    }

    pub fn leave(self: CancelShield) void {
        _ = self.io.swapCancelProtection(self.prev);
    }
};

pub const PostSpec = struct {
    url: []const u8,
    payload: []const u8,
    content_type: []const u8 = "application/x-www-form-urlencoded",
    user_agent: ?[]const u8 = null,
    extra_headers: []const std.http.Header = &.{},
    disallow_redirects: bool = false,
    max_bytes: usize = 1024 * 1024,
    timeout_ms: u64 = default_exchange_timeout_ms,
};

pub const RawResponse = struct {
    status: std.http.Status,
    body: []u8,
};

fn sleepDeadline(io: Io, timeout_ms: u64) void {
    io.sleep(.fromMilliseconds(@intCast(@min(timeout_ms, std.math.maxInt(i63)))), .awake) catch {};
}

fn runPost(client: *std.http.Client, writer: *Io.Writer, spec: PostSpec) anyerror!std.http.Status {
    const res = try client.fetch(.{
        .location = .{ .url = spec.url },
        .method = .POST,
        .payload = spec.payload,
        .response_writer = writer,
        .redirect_behavior = if (spec.disallow_redirects) .not_allowed else null,
        .headers = .{
            .content_type = .{ .override = spec.content_type },
            .user_agent = if (spec.user_agent) |ua| .{ .override = ua } else .default,
        },
        .extra_headers = spec.extra_headers,
    });
    return res.status;
}

/// Execute an OAuth HTTP POST bounded by `spec.timeout_ms`. Safe under
/// `CancelShield`: child `Select` tasks start `.unblocked`, so a stalled socket
/// is canceled and joined at the deadline (`error.OAuthTimeout`) while caller
/// cancelation remains shielded.
pub fn fetchPostBounded(io: Io, gpa: Allocator, arena: Allocator, spec: PostSpec) !RawResponse {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const storage = try gpa.alloc(u8, spec.max_bytes);
    defer gpa.free(storage);
    var writer: Io.Writer = .fixed(storage);

    const Done = union(enum) { fetched: anyerror!std.http.Status, timeout: void };
    var done: [2]Done = undefined;
    var select: Io.Select(Done) = .init(io, &done);
    if (select.concurrent(.timeout, sleepDeadline, .{ io, spec.timeout_ms })) |_| {
        select.concurrent(.fetched, runPost, .{ &client, &writer, spec }) catch {
            select.cancelDiscard();
            const status = try runPost(&client, &writer, spec);
            return .{ .status = status, .body = try arena.dupe(u8, writer.buffered()) };
        };
        const first = select.await() catch |err| {
            select.cancelDiscard();
            return err;
        };
        select.cancelDiscard();
        const status = switch (first) {
            .fetched => |r| try r,
            .timeout => return error.OAuthTimeout,
        };
        return .{ .status = status, .body = try arena.dupe(u8, writer.buffered()) };
    } else |_| {
        const status = try runPost(&client, &writer, spec);
        return .{ .status = status, .body = try arena.dupe(u8, writer.buffered()) };
    }
}

test "oauth_lock: advisory lock contends across open file descriptions and degrades on read-only dir" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = real_buf[0..try tmp.dir.realPath(io, &real_buf)];
    const cred_path = try std.fmt.allocPrint(arena, "{s}/auth.json", .{dir_path});
    const lpath = lockPath(arena, cred_path).?;

    var mu: Io.Mutex = .init;
    const held = acquire(io, arena, &mu, cred_path) orelse return error.UnexpectedCancel;
    try std.testing.expect(held.file != null);
    try std.testing.expectError(error.WouldBlock, Io.Dir.cwd().createFile(io, lpath, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }));
    held.release();

    const probe = try Io.Dir.cwd().createFile(io, lpath, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    });
    probe.close(io);

    if (builtin.os.tag != .windows) {
        try tmp.dir.createDir(io, "ro", @fromBackingInt(@intCast(0o500)));
        defer {
            if (tmp.dir.openDir(io, "ro", .{ .iterate = true })) |d| {
                d.setPermissions(io, @fromBackingInt(@intCast(0o700))) catch {};
                d.close(io);
            } else |_| {}
        }
        const ro_cred = try std.fmt.allocPrint(arena, "{s}/ro/auth.json", .{dir_path});
        const degraded = acquire(io, arena, &mu, ro_cred) orelse return error.UnexpectedCancel;
        defer degraded.release();
        try std.testing.expect(degraded.file == null);
    }
}

test "oauth_lock: CancelShield completes in-flight write under Future.cancel and preserves cancelation" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = real_buf[0..try tmp.dir.realPath(io, &real_buf)];
    const target = try std.fmt.allocPrint(std.testing.allocator, "{s}/auth.json", .{dir_path});
    defer std.testing.allocator.free(target);

    const Worker = struct {
        entered: std.atomic.Value(bool) = .init(false),
        saw_post_leave_cancel: bool = false,
        path: []const u8,

        fn run(self: *@This(), wio: Io) !void {
            {
                const shield = CancelShield.enter(wio);
                defer shield.leave();
                self.entered.store(true, .release);
                try wio.sleep(.fromMilliseconds(60), .awake);
                try credential_store.replaceFile(wio, Io.Dir.cwd(), self.path, "{\"refresh_token\":\"r-rotated\"}", credential_store.private_file);
            }
            wio.checkCancel() catch |err| switch (err) {
                error.Canceled => {
                    self.saw_post_leave_cancel = true;
                    return;
                },
            };
        }
    };

    var worker: Worker = .{ .path = target };
    var future = try io.concurrent(Worker.run, .{ &worker, io });
    while (!worker.entered.load(.acquire)) {
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try future.cancel(io);
    const saved = try Io.Dir.cwd().readFileAlloc(io, target, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqualStrings("{\"refresh_token\":\"r-rotated\"}", saved);
    try std.testing.expect(worker.saw_post_leave_cancel);
}

test "oauth_lock: fetchPostBounded times out stalled socket even inside CancelShield" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    const Staller = struct {
        srv: *Io.net.Server,
        fn run(self: *@This(), sio: Io) void {
            const stream = self.srv.accept(sio) catch return;
            defer stream.close(sio);
            sio.sleep(.fromSeconds(10), .awake) catch {};
        }
    };
    var staller: Staller = .{ .srv = &server };
    var group: Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, Staller.run, .{ &staller, io });

    const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/oauth/token", .{server.socket.address.getPort()});
    const shield = CancelShield.enter(io);
    defer shield.leave();
    try std.testing.expectError(error.OAuthTimeout, fetchPostBounded(io, std.testing.allocator, arena, .{
        .url = url,
        .payload = "grant_type=refresh_token",
        .timeout_ms = 100,
    }));
}
