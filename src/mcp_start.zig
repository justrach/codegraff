//! One server's background connect (split from mcp_boot.zig under the 600-line
//! ceiling), with the two things a failed start used to lose:
//!
//! - A transient failure (the process closed during the handshake, a timeout,
//!   a refused or reset connection) is retried once after a short pause. A
//!   server that is still starting up the first time a session asks no longer
//!   stays down for the whole session.
//! - The reason is recorded by name (`failure`), so `/mcp`, `graff mcp status`
//!   and the desktop app's MCP page can say *why* a server is not connected
//!   instead of folding it into "not connected — /mcp trust".

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mcp = @import("mcp.zig");
const mcp_rpc = @import("mcp_rpc.zig");
const StartOutcome = @import("mcp_boot.zig").StartOutcome;

pub const Ctx = struct {
    gpa: Allocator,
    io: Io,
    home: []const u8,
    show_diagnostics: bool,
    stdio_probe: bool,
    lazy_stdio: bool = true,
    ready: ?*std.atomic.Value(bool) = null,
    /// Pause before the one retry of a transient failure.
    retry_ms: u32 = 1_500,
    /// The owning registry's teardown signal (`Registry.retry_abort`). Set,
    /// it ends the pause at once and skips the retry, so exit never waits
    /// out the pause (the registry still joins the task: nothing outlives
    /// `io`, #325). Heap-owned: the registry value moves after tasks start.
    abort: ?*Io.Event = null,
};

pub fn task(ctx: Ctx, name: []const u8, cfg: std.json.ObjectMap) StartOutcome {
    defer if (ctx.ready) |flag| flag.store(true, .release);
    return attempt(ctx, name, cfg) catch |first| {
        if (transient(first) and pauseBeforeRetry(ctx)) {
            if (attempt(ctx, name, cfg)) |outcome| return outcome else |again| return failed(ctx, name, cfg, again);
        }
        return failed(ctx, name, cfg, first);
    };
}

/// False when the pause was cut short: the registry is tearing down, or the
/// task was canceled. The first failure is then the one recorded.
pub fn pauseBeforeRetry(ctx: Ctx) bool {
    const event = ctx.abort orelse {
        ctx.io.sleep(.fromMilliseconds(ctx.retry_ms), .awake) catch return false;
        return true;
    };
    event.waitTimeout(ctx.io, .{ .duration = .{ .raw = .fromMilliseconds(ctx.retry_ms), .clock = .awake } }) catch |err| return err == error.Timeout;
    return false;
}

fn failed(ctx: Ctx, name: []const u8, cfg: std.json.ObjectMap, err: anyerror) StartOutcome {
    if (ctx.show_diagnostics) std.debug.print("  [mcp:{s}] failed to start: {t}\n", .{ name, err });
    note(name, err);
    @import("mcp_failures.zig").recordErr(ctx.io, ctx.gpa, ctx.home, cfg, err, null);
    return .{};
}

fn attempt(ctx: Ctx, name: []const u8, cfg: std.json.ObjectMap) !StartOutcome {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    errdefer arena_state.deinit();
    const a = arena_state.allocator();
    var servers: std.ArrayList(*mcp_rpc.Server) = .empty;
    var tools: std.ArrayList(mcp.Tool) = .empty;
    // Task-local Registry: only gpa/io/home/flags are read by startServer.
    // Must not point at init()'s stack `reg` — that dies when defer_join returns.
    var tmp: mcp.Registry = .{
        .gpa = ctx.gpa,
        .io = ctx.io,
        .home = ctx.home,
        .arena_state = std.heap.ArenaAllocator.init(ctx.gpa),
        .stdio_probe = ctx.stdio_probe,
        .lazy_stdio = ctx.lazy_stdio,
        .show_diagnostics = ctx.show_diagnostics,
    };
    defer tmp.arena_state.deinit();
    try tmp.startServer(a, &servers, &tools, name, cfg);
    clear(name);
    // Restored dormant from the cache is not a start: it proves nothing.
    if (servers.items[0].transport != .dormant) @import("mcp_failures.zig").clearCfg(ctx.io, ctx.gpa, ctx.home, cfg);
    return .{ .server = servers.items[0], .tools = tools.items, .arena_state = arena_state };
}

/// Failures worth one more try: the server may simply not have been ready.
/// A missing binary, a bad config or a sign-in will fail the same way again.
pub fn transient(err: anyerror) bool {
    return switch (err) {
        error.McpClosed,
        error.McpHandshakeTimeout,
        error.McpRequestTimedOut,
        error.McpHttpStatus,
        error.McpSessionExpired,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.BrokenPipe,
        error.EndOfStream,
        => true,
        else => false,
    };
}

/// Why each server last failed to start in this process, by name. Written by
/// connect tasks on pool threads; read by `/mcp` on the session thread.
var mutex: std.atomic.Mutex = .unlocked;
var names: [32][64]u8 = undefined;
var name_lens: [32]u8 = @splat(0);
var errors: [32]anyerror = undefined;
var count: usize = 0;

fn lock() void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

fn slotLocked(name: []const u8) ?usize {
    for (0..count) |i| if (std.mem.eql(u8, names[i][0..name_lens[i]], name)) return i;
    return null;
}

pub fn note(name: []const u8, err: anyerror) void {
    if (name.len > 64) return;
    lock();
    defer mutex.unlock();
    const i = slotLocked(name) orelse blk: {
        if (count == names.len) return;
        count += 1;
        break :blk count - 1;
    };
    @memcpy(names[i][0..name.len], name);
    name_lens[i] = @intCast(name.len);
    errors[i] = err;
}

pub fn clear(name: []const u8) void {
    lock();
    defer mutex.unlock();
    if (slotLocked(name)) |i| name_lens[i] = 0;
}

/// The last start failure recorded for `name`, if it has not since connected.
pub fn failure(name: []const u8) ?anyerror {
    lock();
    defer mutex.unlock();
    const i = slotLocked(name) orelse return null;
    return if (name_lens[i] == 0) null else errors[i];
}

test "a transient start failure is retried once; a missing binary is not" {
    try std.testing.expect(transient(error.McpClosed));
    try std.testing.expect(transient(error.McpHandshakeTimeout));
    try std.testing.expect(!transient(error.FileNotFound));
    try std.testing.expect(!transient(error.McpAuthenticationRequired));
    try std.testing.expect(!transient(error.BadMcpConfig));
}

test "a retry pause ends at once when the registry tears down, or runs when it does not" {
    const io = std.testing.io;
    var event: Io.Event = .unset;
    const ctx: Ctx = .{ .gpa = std.testing.allocator, .io = io, .home = "", .show_diagnostics = false, .stdio_probe = false, .retry_ms = 5, .abort = &event };
    try std.testing.expect(pauseBeforeRetry(ctx)); // not tearing down: pause, then retry
    event.set(io);
    var slow = ctx;
    slow.retry_ms = 60_000;
    const t0 = Io.Timestamp.now(io, .awake);
    try std.testing.expect(!pauseBeforeRetry(slow));
    try std.testing.expect(t0.untilNow(io, .awake).toMilliseconds() < 200);
}

test "teardown with a pending transient retry returns in well under the pause" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // /bin/sh
    const io = std.testing.io;
    var reg = mcp.Registry.empty(std.testing.allocator, io);
    reg.stdio_probe = false;
    reg.lazy_stdio = false;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var cfg: std.json.ObjectMap = .empty;
    try cfg.put(a, "command", .{ .string = "/bin/sh" });
    var argv = std.json.Array.init(a);
    try argv.appendSlice(&.{ .{ .string = "-c" }, .{ .string = "exit 1" } }); // closes during the handshake: transient
    try cfg.put(a, "args", .{ .array = argv });
    try std.testing.expect(@import("mcp_boot.zig").queueConfig(&reg, "teardown-retry-fixture", cfg));
    try io.sleep(.fromMilliseconds(300), .awake); // first attempt fails; the task is in its 1.5s pause
    const t0 = Io.Timestamp.now(io, .awake);
    reg.deinit(); // joins the task: nothing is left holding `io` (#325)
    try std.testing.expect(t0.untilNow(io, .awake).toMilliseconds() < 200);
    try std.testing.expect(failure("teardown-retry-fixture") != null); // the first failure is still named
}

test "start failures are remembered by name until the server connects" {
    note("fixture-a", error.FileNotFound);
    note("fixture-b", error.McpClosed);
    try std.testing.expectEqual(@as(?anyerror, error.FileNotFound), failure("fixture-a"));
    note("fixture-a", error.McpHandshakeTimeout);
    try std.testing.expectEqual(@as(?anyerror, error.McpHandshakeTimeout), failure("fixture-a"));
    clear("fixture-a");
    try std.testing.expect(failure("fixture-a") == null);
    try std.testing.expectEqual(@as(?anyerror, error.McpClosed), failure("fixture-b"));
    try std.testing.expect(failure("never-seen") == null);
}
