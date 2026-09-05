//! The interface, shipped inside the app.
//!
//! A downloaded app has no repository to serve the UI from, so the bundle
//! carries a standalone build of it (`Resources/ui`), the JS runtime that
//! runs it (`Resources/bun`) and the harness it drives (`Resources/graff`).
//! This starts that server and hands the window back a port.
//!
//! A developer's own `npm run dev` still wins: main.zig only calls this
//! when nothing is already listening, so a checkout keeps its live reload
//! and never has two servers fighting over the same sessions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Ports to try, in order. 3777 and 3000 belong to a developer's own dev
/// server; binding one here would collide the moment they start it.
const first_port: u16 = 3778;
const port_attempts: u16 = 40;

/// Nothing is compiled at startup — the build already happened — but a JS
/// runtime still has to boot and load the server. Past this the window
/// gives up and shows the "not running" page rather than a blank frame.
const boot_timeout_ms: u64 = 20_000;
const poll_ms: u64 = 100;

/// The process group the server runs in, so the app can take it down on
/// the way out. A group rather than a pid: the server spawns a harness per
/// chat tab, and killing only its parent would leave those running.
var group: std.posix.pid_t = 0;

/// libc's. Registering here means the group dies with any ordinary exit,
/// including ⌘Q, which ends in `exit()` inside `-[NSApplication terminate:]`.
extern "c" fn atexit(func: *const fn () callconv(.c) void) c_int;

/// Kill the server and everything it spawned. Idempotent, and safe when
/// nothing was ever started.
pub fn stop() callconv(.c) void {
    if (group == 0) return;
    // A negative pid is "the whole process group" to kill(2).
    std.posix.kill(-group, .TERM) catch {};
    group = 0;
}

/// A signal skips `atexit` entirely, so Ctrl-C on a shell started from a
/// terminal would otherwise leave the server behind. Stop it, then die the
/// way the signal asked: re-raising through the default handler keeps the
/// exit status honest for whatever started us.
fn onSignal(sig: std.posix.SIG) callconv(.c) void {
    stop();
    std.posix.sigaction(sig, &.{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);
    std.posix.raise(sig) catch {};
}

fn catchSignals() void {
    const action = std.posix.Sigaction{
        .handler = .{ .handler = &onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for ([_]std.posix.SIG{ .INT, .TERM, .HUP }) |sig| {
        std.posix.sigaction(sig, &action, null);
    }
}

/// Start the interface that ships inside `bundle`, and return the port it
/// answers on. Null means this build has no interface inside it — a loose
/// dev binary, or one built with `SKIP_UI=1` — which is not an error: the
/// caller falls back to the page that says what to start.
pub fn start(gpa: Allocator, io: Io, env: *std.process.Environ.Map, bundle: []const u8) ?u16 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = std.fmt.allocPrint(arena, "{s}/Contents/Resources", .{bundle}) catch return null;
    const ui = std.fmt.allocPrint(arena, "{s}/ui", .{res}) catch return null;
    const entry = std.fmt.allocPrint(arena, "{s}/server.js", .{ui}) catch return null;
    const runtime = std.fmt.allocPrint(arena, "{s}/bun", .{res}) catch return null;
    const harness = std.fmt.allocPrint(arena, "{s}/graff", .{res}) catch return null;

    const cwd = Io.Dir.cwd();
    cwd.access(io, entry, .{}) catch return null;
    cwd.access(io, runtime, .{}) catch {
        // The interface is here but its runtime is not, which is a packaging
        // fault rather than a loose binary. Say so instead of silently
        // showing the "start it yourself" page.
        std.log.warn("the bundled interface has no runtime beside it", .{});
        return null;
    };

    if (pidPath(arena, env)) |path| reap(gpa, io, path, runtime);

    const port = freePort(io) orelse {
        std.log.warn("no free port for the bundled interface", .{});
        return null;
    };

    var port_buf: [8]u8 = undefined;
    const port_text = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch return null;
    env.put("PORT", port_text) catch return null;
    // Loopback only. This server spawns processes and reads the disk on
    // request; it is the app's own back end, not something to put on a
    // network the machine happens to be on.
    env.put("HOSTNAME", "127.0.0.1") catch return null;
    env.put("GRAFF_BIN", harness) catch return null;
    // Without this the workspace would default to the server's own cwd,
    // which inside a bundle is a signed, read-only directory. An existing
    // value wins: someone who pinned a workspace meant it.
    if (env.get("GRAFF_CWD") == null) {
        if (env.get("HOME")) |home| env.put("GRAFF_CWD", home) catch return null;
    }

    const child = std.process.spawn(io, .{
        .argv = &.{ runtime, entry },
        .cwd = .{ .path = ui },
        .environ_map = env,
        // Its own group, so one kill takes the server and every harness it
        // started. Killing just the server would orphan those.
        .pgid = 0,
    }) catch |err| {
        std.log.warn("the bundled interface did not start: {t}", .{err});
        return null;
    };
    group = child.id orelse return null;

    _ = atexit(&stop);
    catchSignals();
    if (pidPath(arena, env)) |path| remember(io, path, group);

    if (!ready(io, port)) {
        std.log.warn("the bundled interface did not answer on {d}", .{port});
        stop();
        return null;
    }
    return port;
}

/// Where the running server's group id is left for the next launch. A
/// crash takes the atexit handler with it, so without this a killed shell
/// would leave a server — and its harnesses — running for good.
fn pidPath(arena: Allocator, env: *std.process.Environ.Map) ?[]const u8 {
    const home = env.get("HOME") orelse return null;
    return std.fmt.allocPrint(arena, "{s}/Library/Caches/dev.codegraff.native.pid", .{home}) catch null;
}

fn remember(io: Io, path: []const u8, pid: std.posix.pid_t) void {
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch {};
}

/// Kill a server left behind by a previous run. Guarded by `ps`: pids are
/// recycled, and killing a stranger's process group because it inherited
/// an old number would be a genuinely bad bug.
fn reap(gpa: Allocator, io: Io, path: []const u8, runtime: []const u8) void {
    const text = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64)) catch return;
    defer gpa.free(text);
    const pid = std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, text, " \t\r\n"), 10) catch return;
    if (pid <= 1) return;

    var buf: [16]u8 = undefined;
    const arg = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch return;
    const seen = std.process.run(gpa, io, .{
        .argv = &.{ "ps", "-o", "command=", "-p", arg },
        .stdout_limit = .limited(8 * 1024),
        .stderr_limit = .limited(8 * 1024),
    }) catch return;
    defer gpa.free(seen.stdout);
    defer gpa.free(seen.stderr);
    // Only ours: the command has to be the very runtime we are about to
    // start, out of this same bundle.
    if (std.mem.indexOf(u8, seen.stdout, runtime) == null) return;
    std.posix.kill(-pid, .TERM) catch {};
}

/// A port nothing is bound to. Tested by binding it rather than by
/// connecting to it: a port can refuse connections and still be taken.
fn freePort(io: Io) ?u16 {
    var port = first_port;
    while (port < first_port + port_attempts) : (port += 1) {
        const address = Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return null;
        var probe = Io.net.IpAddress.listen(&address, io, .{}) catch continue;
        probe.deinit(io);
        return port;
    }
    return null;
}

/// Wait for the server to answer. Polling a connect is the only honest
/// signal: the child exists long before it is listening, and loading the
/// window early just shows WebKit's connection error.
fn ready(io: Io, port: u16) bool {
    const address = Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return false;
    var waited: u64 = 0;
    while (waited < boot_timeout_ms) : (waited += poll_ms) {
        if (Io.net.IpAddress.connect(&address, io, .{ .mode = .stream })) |stream| {
            stream.close(io);
            return true;
        } else |_| {}
        Io.sleep(io, Io.Duration.fromMilliseconds(poll_ms), .awake) catch return false;
    }
    return false;
}
