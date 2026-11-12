//! Fixtures and tests for `boot_prewarm.zig`, split out so that module stays
//! inside the 600-line ceiling (ADR 0339 added the join budget there), pulled
//! in by its trailing `test { _ = @import("boot_prewarm_tests.zig"); }`.
//!
//! Everything here uses the module's public surface: `start` / `startWithin`,
//! `take` (directly and through `connect`), `discard`, `stopAtExit`, `pending`,
//! `budgetMs`, and `testSetCwdKey` for the one case a test cannot stage by
//! moving the process cwd.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const args = @import("args.zig");
const mcp = @import("mcp.zig");
const bp = @import("boot_prewarm.zig");

const start = bp.start;
const startWithin = bp.startWithin;
const take = bp.take;
const connect = bp.connect;
const discard = bp.discard;
const stopAtExit = bp.stopAtExit;
const pending = bp.pending;
const budgetMs = bp.budgetMs;
const wantsCompanion = bp.wantsCompanion;
const default_budget_ms = bp.default_budget_ms;
const budget_env = bp.budget_env;
const Spec = bp.Spec;

/// A legacy stdio MCP server in /bin/sh, as in mcp_restart.zig's fixture.
const fixture_script =
    \\while read -r l; do
    \\  id=$(printf '%s' "$l" | sed -n 's/^{"jsonrpc":"2.0","id":\([0-9]*\),.*/\1/p')
    \\  [ -z "$id" ] && continue
    \\  case "$l" in
    \\    *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"f","version":"1"}}}\n' "$id" ;;
    \\    *'"method":"tools/list"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"search","description":"Search","inputSchema":{"type":"object","properties":{"q":{"type":"string"}},"required":["q"]}},{"name":"read","description":"Read","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":true}}]}}\n' "$id" ;;
    \\    *) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"no"}}\n' "$id" ;;
    \\  esac
    \\done
;

fn fixtureSpec(name: []const u8, argv: []const []const u8) Spec {
    return .{ .name = name, .command = "/bin/sh", .args = argv, .stdio_probe = false, .lazy_stdio = false, .show_diagnostics = false };
}

const fixture_argv = [_][]const u8{ "-c", fixture_script };

fn testRegistry() mcp.Registry {
    var reg = mcp.Registry.empty(testing.allocator, testing.io);
    reg.stdio_probe = false;
    reg.lazy_stdio = false;
    return reg;
}

fn toolsJson(a: Allocator, reg: *mcp.Registry) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    for (reg.tools) |t| {
        try out.writer.print("{s}|{s}|{s}|{d}|{any}|", .{ t.qualified_name, t.serverName(), t.description, t.server_index, t.read_only });
        try std.json.Stringify.value(t.input_schema, .{}, &out.writer);
        try out.writer.writeByte('\n');
    }
    for (reg.servers) |s| try out.writer.print("server {s} {s}\n", .{ s.name, s.protocol_version });
    return out.written();
}

test "boot prewarm: the adopted companion matches the inline addServer catalog byte for byte" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // /bin/sh
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var inline_reg = testRegistry();
    defer inline_reg.deinit();
    _ = try inline_reg.addServer("codedbpro", "/bin/sh", &.{ "-c", fixture_script });

    var warm_reg = testRegistry();
    defer warm_reg.deinit();
    start(testing.io, testing.allocator, fixtureSpec("codedbpro", &fixture_argv));
    try testing.expect(pending());
    try testing.expect(take(&warm_reg, "other") == null); // another name leaves the slot alone
    const joined = take(&warm_reg, "codedbpro") orelse return error.TestExpectedPrewarm;
    try joined;
    try testing.expect(!pending());
    try testing.expectEqual(@as(usize, 2), warm_reg.tools.len);
    try testing.expectEqualStrings(try toolsJson(a, &inline_reg), try toolsJson(a, &warm_reg));
}

test "boot prewarm: a registry with other settings is not adopted" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var reg = testRegistry();
    defer reg.deinit();
    reg.stdio_probe = true; // what GRAFF_MCP_PROBE would change
    start(testing.io, testing.allocator, fixtureSpec("codedbpro", &fixture_argv));
    try testing.expect(take(&reg, "codedbpro") == null);
    try testing.expect(!pending());
    try testing.expectEqual(@as(usize, 0), reg.tools.len);
}

/// A scratch directory with a spawn log the fixtures append their pid to.
const SpawnLog = struct {
    tmp: testing.TmpDir,
    path: []u8,

    fn init() !SpawnLog {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(dir);
        return .{ .tmp = tmp, .path = try std.fmt.allocPrint(testing.allocator, "{s}/spawns", .{dir}) };
    }

    fn deinit(l: *SpawnLog) void {
        testing.allocator.free(l.path);
        l.tmp.cleanup();
    }

    fn pids(l: *const SpawnLog, buf: []std.posix.pid_t) []std.posix.pid_t {
        var raw: [512]u8 = undefined;
        const data = l.tmp.dir.readFile(testing.io, "spawns", &raw) catch return buf[0..0];
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, data, " \n");
        while (it.next()) |w| : (n += 1) {
            if (n == buf.len) break;
            buf[n] = std.fmt.parseInt(std.posix.pid_t, w, 10) catch return buf[0..n];
        }
        return buf[0..n];
    }
};

fn processAlive(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, @fromBackingInt(@intCast(0))) catch |err| return err != error.ProcessNotFound;
    return true;
}

/// `sh -c <script> <log>`: the script sees the log path as `$0`.
const failing_script = "echo $$ >> \"$0\"; exit 1";

test "boot prewarm: a cwd change between start and consumer discards it and the inline path runs" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var reg = testRegistry();
    defer reg.deinit();
    start(testing.io, testing.allocator, fixtureSpec("codedbpro", &fixture_argv));
    try testing.expect(pending());
    bp.testSetCwdKey(1); // as if recorded in another directory ("/")
    try testing.expect(take(&reg, "codedbpro") == null);
    try testing.expect(!pending());
    try testing.expectEqual(@as(usize, 0), reg.servers.len); // nothing adopted; caller connects inline
    _ = try reg.addServer("codedbpro", "/bin/sh", &.{ "-c", fixture_script });
    try testing.expectEqual(@as(usize, 2), reg.tools.len);
}

test "boot prewarm: a failing companion is started exactly as often as the inline path starts it" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var inline_log = try SpawnLog.init();
    defer inline_log.deinit();
    var warm_log = try SpawnLog.init();
    defer warm_log.deinit();
    var buf: [8]std.posix.pid_t = undefined;

    var inline_reg = testRegistry(); // the serial path: no prewarm slot
    defer inline_reg.deinit();
    const inline_err = connect(&inline_reg, "codedbpro", "/bin/sh", &.{ "-c", failing_script, inline_log.path });
    try testing.expectError(error.McpClosed, inline_err);
    const inline_spawns = inline_log.pids(&buf).len;
    try testing.expectEqual(@as(usize, 1), inline_spawns);

    var warm_reg = testRegistry();
    defer warm_reg.deinit();
    const argv = [_][]const u8{ "-c", failing_script, warm_log.path };
    start(testing.io, testing.allocator, fixtureSpec("codedbpro", &argv));
    try testing.expect(pending());
    // The consumer takes the attempt's error; it does not start the companion again.
    try testing.expectError(error.McpClosed, connect(&warm_reg, "codedbpro", "/bin/sh", &argv));
    try testing.expect(!pending());
    try testing.expectEqual(inline_spawns, warm_log.pids(&buf).len);
    try testing.expectEqual(@as(usize, 0), warm_reg.servers.len);
}

/// `main` between the prewarm start and the registry's deferred teardown:
/// any error return runs the deferred `discard`.
fn bootUntilRegistry(io: Io, spec: Spec, log: *const SpawnLog) !void {
    start(io, testing.allocator, spec);
    defer discard(io);
    var buf: [8]std.posix.pid_t = undefined;
    var waited: usize = 0;
    while (log.pids(&buf).len == 0 and waited < 400) : (waited += 1) try io.sleep(.fromMilliseconds(5), .awake);
    if (log.pids(&buf).len == 0) return error.TestExpectedSpawn;
    return error.InjectedBootFailure; // e.g. a failed `try` before `initRegistryConsent` returns
}

test "boot prewarm: an error return before the registry exists discards promptly and leaves no child" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var log = try SpawnLog.init();
    defer log.deinit();
    // Stuck in its handshake: one reads its stdin and never answers, one
    // ignores stdin altogether. Repeated: the stop races the handshake.
    const scripts = [_][]const u8{ "echo $$ >> \"$0\"; exec cat > /dev/null", "echo $$ >> \"$0\"; exec sleep 30" };
    for (scripts) |script| for (0..8) |_| {
        log.tmp.dir.deleteFile(testing.io, "spawns") catch {};
        const argv = [_][]const u8{ "-c", script, log.path };
        const t0 = Io.Timestamp.now(testing.io, .awake);
        try testing.expectError(error.InjectedBootFailure, bootUntilRegistry(testing.io, fixtureSpec("codedbpro", &argv), &log));
        const ms = t0.untilNow(testing.io, .awake).toMilliseconds();
        try testing.expect(!pending());
        var buf: [8]std.posix.pid_t = undefined;
        const pids = log.pids(&buf);
        try testing.expectEqual(@as(usize, 1), pids.len);
        try testing.expect(!processAlive(pids[0])); // stopped and reaped
        try testing.expect(ms < 500); // the spawn wait above included; the handshake timeout is 15 s
    };
}

test "boot prewarm: discard joins a pending handshake and tears it down" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    start(testing.io, testing.allocator, fixtureSpec("codedbpro", &.{ "-c", "cat > /dev/null" })); // never answers
    try testing.expect(pending());
    const t0 = Io.Timestamp.now(testing.io, .awake);
    discard(testing.io);
    try testing.expect(!pending());
    try testing.expect(t0.untilNow(testing.io, .awake).toMilliseconds() < 2_000);
    discard(testing.io); // idempotent
}

test "boot prewarm: main starts it after credentials and the banner, and defers its discard" {
    // A run that fails on credentials (`resolveKeys` exits through
    // `std.process.fatal`, which runs no defer) or in the banner (`--add-dir`,
    // isolation, `--experiment`) must not have spawned the companion: the
    // serial path never did. Every return after the start runs `discard`.
    const src = @embedFile("main.zig");
    const keys = std.mem.indexOf(u8, src, "startup.resolveKeysOrRunAcpPreAuth(") orelse return error.TestExpectedHook;
    const banner = std.mem.indexOf(u8, src, "session_start.setupWorktreeAndBanner(") orelse return error.TestExpectedHook;
    const hook = std.mem.indexOf(u8, src, "@import(\"boot_prewarm.zig\").startCompanion(") orelse return error.TestExpectedHook;
    const registry = std.mem.indexOf(u8, src, "session_start.initRegistryConsent(") orelse return error.TestExpectedHook;
    try testing.expect(keys < banner and banner < hook and hook < registry);
    const next_line = std.mem.indexOfScalarPos(u8, src, hook, '\n') orelse return error.TestExpectedHook;
    try testing.expect(std.mem.startsWith(u8, std.mem.trimStart(u8, src[next_line + 1 ..], " "), "defer @import(\"boot_prewarm.zig\").discard(io);"));
    try testing.expect(std.mem.indexOf(u8, @embedFile("startup.zig"), "startCompanion") == null);
}

test "boot prewarm: the settings opt-out is read the way loadSkillSettings reads it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expect(bp.optedOutIn(a, "{\"skills\":{\"codedbpro\":false}}", "codedbpro"));
    try testing.expect(!bp.optedOutIn(a, "{\"skills\":{\"codedbpro\":true}}", "codedbpro"));
    try testing.expect(!bp.optedOutIn(a, "{\"skills\":{\"muonry\":false}}", "codedbpro"));
    try testing.expect(!bp.optedOutIn(a, "not json", "codedbpro"));
}

/// Tools the registry currently advertises, taken under its mutex.
fn toolCount(reg: *mcp.Registry) !usize {
    const snap = try reg.snapshotTools(testing.allocator);
    defer testing.allocator.free(snap);
    return snap.len;
}

fn serverCount(reg: *mcp.Registry) usize {
    reg.mutex.lockUncancelable(reg.io);
    defer reg.mutex.unlock(reg.io);
    return reg.servers.len;
}

/// The fixture, silent for a while before it answers: over budget at the
/// join, then lands.
const slow_argv = [_][]const u8{ "-c", "sleep 0.4\n" ++ fixture_script };

fn waitForTools(reg: *mcp.Registry, want: usize) !void {
    var waited: u32 = 0;
    while (waited < 4_000) : (waited += 10) {
        if (try toolCount(reg) >= want) return;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.TestExpectedLateMerge;
}

test "boot prewarm: over budget the join returns and the companion still lands (ADR 0339)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // /bin/sh
    var reg = testRegistry();
    defer reg.deinit();
    startWithin(testing.io, testing.allocator, fixtureSpec("codedbpro", &slow_argv), 40);
    try testing.expect(pending());

    const t0 = Io.Timestamp.now(testing.io, .awake);
    try connect(&reg, "codedbpro", "/bin/sh", &slow_argv); // returns; no inline second spawn
    const ms = t0.untilNow(testing.io, .awake).toMilliseconds();
    try testing.expect(ms < 300); // the 40 ms budget, not the 400 ms handshake
    try testing.expectEqual(@as(usize, 0), try toolCount(&reg)); // missed the first catalog

    // It keeps running and merges into this registry when it lands — once.
    try waitForTools(&reg, 2);
    try testing.expectEqual(@as(usize, 2), try toolCount(&reg));
    try testing.expectEqual(@as(usize, 1), serverCount(&reg)); // one start, not two
    stopAtExit(testing.io); // what Registry.deinitAtExit calls
    try testing.expect(!pending());
}

test "boot prewarm: a late merge cannot duplicate a companion that connected meanwhile" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var reg = testRegistry();
    defer reg.deinit();
    startWithin(testing.io, testing.allocator, fixtureSpec("codedbpro", &slow_argv), 20);
    const joined = take(&reg, "codedbpro") orelse return error.TestExpectedPrewarm;
    try joined; // over budget: success, still connecting
    // Something else connects the same server while the attempt is in flight
    // (an eager pin, `/mcp add`, a `-i` deferred start).
    _ = try reg.addServer("codedbpro", "/bin/sh", &fixture_argv);
    try testing.expectEqual(@as(usize, 2), try toolCount(&reg));

    // When the attempt lands, `adoptStarted` finds the name taken and tears
    // the latecomer down instead of appending it: every tool twice makes a
    // strict Responses endpoint reject the whole request (#505). A dropped
    // latecomer leaves no trace to poll for, so wait past its 400 ms fixture.
    try testing.io.sleep(.fromMilliseconds(800), .awake);
    try testing.expectEqual(@as(usize, 2), try toolCount(&reg));
    try testing.expectEqual(@as(usize, 1), serverCount(&reg));
    stopAtExit(testing.io);
    try testing.expect(!pending());
}

test "boot prewarm: the join budget is a real knob, not an inert one (ADR 0339)" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    try testing.expectEqual(default_budget_ms, budgetMs(&env));
    try env.put(budget_env, "80");
    try testing.expectEqual(@as(u32, 80), budgetMs(&env));
    try env.put(budget_env, "0"); // not "wait forever"
    try testing.expectEqual(default_budget_ms, budgetMs(&env));
    try env.put(budget_env, "nonsense");
    try testing.expectEqual(default_budget_ms, budgetMs(&env));
    try env.put(budget_env, "999999"); // a typo cannot restore the unbounded join
    try testing.expectEqual(default_budget_ms, budgetMs(&env));
    // The default is the ACP `attach_budget_ms` order, not the probe plus
    // handshake caps the unbounded join used to pay.
    try testing.expectEqual(withWindows(250, 1_500), default_budget_ms);
}

fn withWindows(posix: u32, windows: u32) u32 {
    return if (@import("builtin").os.tag == .windows) windows else posix;
}

test "boot prewarm: an unresolved-key run never reaches the start" {
    // A run that is going to fatal on credentials must prewarm nothing, as the
    // serial path did: `main` starts the prewarm only after
    // `resolveKeysOrRunAcpPreAuth` returned, and that call is a `orelse return`
    // — the fatal path returns before any spawn.
    const src = @embedFile("main.zig");
    const guarded = std.mem.indexOf(u8, src, "resolveKeysOrRunAcpPreAuth(io, gpa, arena, init, flags)) orelse return") orelse return error.TestExpectedHook;
    const hook = std.mem.indexOf(u8, src, "@import(\"boot_prewarm.zig\").startCompanion(") orelse return error.TestExpectedHook;
    try testing.expect(guarded < hook);
}
