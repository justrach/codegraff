//! Boot prewarm: run the companion handshake (`codedb-pro --mcp`) while the
//! rest of a one-shot boots, and join it where `connectCompanion` would have
//! called `addServer` (DRAFT-boot-prewarm ADR; formal/BootPrewarm.tla).
//!
//! `-p` connects the companion synchronously (ADR 0230 defers only
//! interactive and ACP sessions), so its spawn + handshake used to sit in
//! series with credentials, the plugin scan and the MCP merge. Only the case
//! where the result is known in advance prewarms: lean `-p` (not a
//! subcommand), no `-w`, no project `.mcp.json` and no registry env override. There the
//! registry is the empty one (`oneshotSkipsImportedMcp`), so the companion is
//! the only server that can connect and the adopted outcome fills exactly the
//! slot `addServer` would have. Every other case keeps the serial path.
//!
//! One slot, touched only by the boot thread: `start` after `runSubcommand`,
//! `take` in `connectCompanion` (await, then merge under the registry mutex,
//! ADR 0197), `discard` (cancel, join, tear down) when it is not adopted and
//! at registry teardown. A cwd or registry-setting mismatch discards; a quick
//! failure falls back to the inline `addServer`, a timeout does not repeat.
//! The worker owns copies of everything it reads: `std.process.Init` frees
//! `environ_map` before it joins worker threads.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const args = @import("args.zig");
const mcp = @import("mcp.zig");
const mcp_boot = @import("mcp_boot.zig");
const mcp_rpc = @import("mcp_rpc.zig");
const mcp_teardown = @import("mcp_teardown.zig");
const skills = @import("skills.zig");

/// What `addServer(name, command, args)` would start, plus the registry
/// settings `startServer` reads. `take` adopts only when the live registry
/// carries the same settings.
pub const Spec = struct {
    name: []const u8,
    command: []const u8,
    args: []const []const u8 = &.{},
    home: []const u8 = "",
    stdio_probe: bool = true,
    lazy_stdio: bool = true,
    show_diagnostics: bool = true,
};

const Joined = struct { outcome: mcp_boot.StartOutcome = .{}, err: ?anyerror = null };

const Slot = struct {
    future: Io.Future(Joined),
    owned: std.heap.ArenaAllocator,
    spec: Spec,
    cwd: [std.fs.max_path_bytes]u8 = undefined,
    cwd_len: usize = 0,
};

var slot: ?Slot = null;

/// Settings that only `Registry.init` reads. With any of them set the
/// prewarm could not match the registry, so it does not start.
const registry_env = [_][]const u8{ "GRAFF_MCP_PROBE", "GRAFF_MCP_EAGER", "GRAFF_MCP_HANDSHAKE_SECS", "GRAFF_MCP_PROBE_MS" };

/// The flag/env half of the gate: a lean one-shot that will build the empty
/// registry. Interactive and ACP sessions queue the companion instead.
pub fn wantsCompanion(flags: args.Flags, environ_map: anytype) bool {
    if (flags.oneshot_prompt == null) return false; // the prompt is the positionals; subcommands have none
    if (flags.is_subcommand or flags.worktree_flag != null) return false;
    if (!(flags.effectiveLean() or environ_map.get("GRAFF_LEAN") != null)) return false;
    for (registry_env) |k| if (environ_map.get(k) != null) return false;
    return true;
}

/// Called once boot knows this is a session (after `runSubcommand`). Picks
/// the companion `connectCompanion` would try first and starts it.
pub fn startCompanion(io: Io, gpa: Allocator, environ_map: anytype, flags: args.Flags) void {
    if (!wantsCompanion(flags, environ_map)) return;
    if (Io.Dir.cwd().access(io, ".mcp.json", .{})) |_| return else |_| {} // project servers: not the empty registry
    const path_env = environ_map.get("PATH") orelse "";
    for (skills.companion_servers) |c| {
        if (optedOut(io, c.server)) continue;
        var buf: [1024]u8 = undefined;
        if (@import("path_lookup.zig").resolve(io, path_env, c.bin, &buf) == null) continue;
        start(io, gpa, .{ .name = c.server, .command = c.bin, .args = &.{"--mcp"}, .home = @import("keys_cli.zig").homeEnv(environ_map) orelse "" });
        return;
    }
}

/// `skills.loadSkillSettings` has not run yet at prewarm time; read the same
/// `{"skills": {"<server>": false}}` opt-out it will apply.
fn optedOut(io: Io, server: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const data = Io.Dir.cwd().readFileAlloc(io, @import("harness_policy.zig").settings_path, a, .limited(1 << 20)) catch return false;
    return optedOutIn(a, data, server);
}

fn optedOutIn(a: Allocator, data: []const u8, server: []const u8) bool {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, data, .{ .allocate = .alloc_always }) catch return false;
    if (v != .object) return false;
    const section = v.object.get("skills") orelse return false;
    if (section != .object) return false;
    const entry = section.object.get(server) orelse return false;
    return entry == .bool and !entry.bool;
}

pub fn pending() bool {
    return slot != null;
}

/// Start one prewarm. A second call, an allocation failure or a pool with no
/// thread to spare leaves the slot empty: the consumer then runs inline.
pub fn start(io: Io, gpa: Allocator, spec: Spec) void {
    if (slot != null) return;
    var owned = std.heap.ArenaAllocator.init(gpa);
    const copy = dupSpec(owned.allocator(), spec) catch {
        owned.deinit();
        return;
    };
    var s: Slot = .{ .future = undefined, .owned = owned, .spec = copy };
    s.cwd_len = cwdKey(io, &s.cwd);
    // Never `io.async`: run inline it would serialize the boot again.
    s.future = io.concurrent(connectTask, .{ gpa, io, copy }) catch {
        s.owned.deinit();
        return;
    };
    slot = s;
}

fn dupSpec(a: Allocator, spec: Spec) Allocator.Error!Spec {
    var copy = spec;
    copy.name = try a.dupe(u8, spec.name);
    copy.command = try a.dupe(u8, spec.command);
    copy.home = try a.dupe(u8, spec.home);
    const list = try a.alloc([]const u8, spec.args.len);
    for (spec.args, list) |src, *dst| dst.* = try a.dupe(u8, src);
    copy.args = list;
    return copy;
}

fn cwdKey(io: Io, buf: *[std.fs.max_path_bytes]u8) usize {
    return Io.Dir.cwd().realPath(io, buf) catch 0;
}

/// The worker: `addServer`'s connect on a task-local registry (the pattern
/// `mcp_start.attempt` uses), one attempt, no retry, no failure record.
fn connectTask(gpa: Allocator, io: Io, spec: Spec) Joined {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    const outcome = connectInto(gpa, io, spec, &arena_state) catch |err| {
        arena_state.deinit();
        return .{ .err = err };
    };
    return .{ .outcome = outcome };
}

fn connectInto(gpa: Allocator, io: Io, spec: Spec, arena_state: *std.heap.ArenaAllocator) !mcp_boot.StartOutcome {
    const a = arena_state.allocator();
    var tmp: mcp.Registry = .{
        .gpa = gpa,
        .io = io,
        .home = spec.home,
        .arena_state = std.heap.ArenaAllocator.init(gpa),
        .stdio_probe = spec.stdio_probe,
        .lazy_stdio = spec.lazy_stdio,
        .show_diagnostics = spec.show_diagnostics,
    };
    defer tmp.arena_state.deinit();
    // Same object, same key order as `Registry.addServer`: the cache key and
    // the relaunch config are derived from it.
    var cfg: std.json.ObjectMap = .empty;
    try cfg.put(a, "command", .{ .string = try a.dupe(u8, spec.command) });
    var argv = std.json.Array.init(a);
    for (spec.args) |arg| try argv.append(.{ .string = try a.dupe(u8, arg) });
    try cfg.put(a, "args", .{ .array = argv });
    var servers: std.ArrayList(*mcp_rpc.Server) = .empty;
    var tools: std.ArrayList(mcp.Tool) = .empty;
    try tmp.startServer(a, &servers, &tools, try a.dupe(u8, spec.name), cfg);
    return .{ .server = servers.items[0], .tools = tools.items, .arena_state = arena_state.* };
}

/// The consumer. Null: nothing usable for `name` (none started, or it was
/// discarded) — connect inline as before. Otherwise the joined result: the
/// server merged into `reg`, or the error `addServer` would have returned.
pub fn take(reg: *mcp.Registry, name: []const u8) ?anyerror!void {
    const s = if (slot) |*s| s else return null;
    if (!std.mem.eql(u8, s.spec.name, name)) return null;
    if (!matches(reg, s)) {
        discard(reg.io);
        return null;
    }
    const joined = s.future.await(reg.io);
    release();
    if (joined.err) |err| return if (repeatInline(err)) null else err;
    if (!mcp_boot.adoptStarted(reg, joined.outcome)) return error.McpServerAlreadyConnected;
    return {};
}

fn matches(reg: *const mcp.Registry, s: *const Slot) bool {
    if (reg.stdio_probe != s.spec.stdio_probe or reg.lazy_stdio != s.spec.lazy_stdio) return false;
    if (!std.mem.eql(u8, reg.home, s.spec.home)) return false;
    var now: [std.fs.max_path_bytes]u8 = undefined;
    const n = cwdKey(reg.io, &now);
    return n > 0 and std.mem.eql(u8, now[0..n], s.cwd[0..s.cwd_len]);
}

/// A prewarm that failed fast is retried on the boot thread, which is what
/// the serial path did at this point. A timeout already took the full
/// handshake budget; repeating it would double the worst case.
fn repeatInline(err: anyerror) bool {
    return switch (err) {
        error.McpHandshakeTimeout, error.McpRequestTimedOut, error.Canceled => false,
        else => true,
    };
}

/// Cancel, join and tear down a prewarm nobody adopted. No-op when the slot
/// is empty, so every exit path may call it.
pub fn discard(io: Io) void {
    const s = if (slot) |*s| s else return;
    var joined = s.future.cancel(io);
    release();
    if (joined.outcome.server) |server| mcp_rpc.deinitServer(server, io, .init(io, mcp_teardown.teardown_grace));
    if (joined.outcome.arena_state) |*ta| ta.deinit();
}

fn release() void {
    if (slot) |*s| s.owned.deinit();
    slot = null;
}

const testing = std.testing;

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

test "boot prewarm: a cwd change between start and consumer discards it and the inline path runs" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var reg = testRegistry();
    defer reg.deinit();
    start(testing.io, testing.allocator, fixtureSpec("codedbpro", &fixture_argv));
    try testing.expect(pending());
    slot.?.cwd_len = 1; // as if recorded in another directory ("/")
    try testing.expect(take(&reg, "codedbpro") == null);
    try testing.expect(!pending());
    try testing.expectEqual(@as(usize, 0), reg.servers.len); // nothing adopted; caller connects inline
    _ = try reg.addServer("codedbpro", "/bin/sh", &.{ "-c", fixture_script });
    try testing.expectEqual(@as(usize, 2), reg.tools.len);
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

test "boot prewarm: a failed prewarm falls back to the inline connect, never to a missing tool" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var reg = testRegistry();
    defer reg.deinit();
    start(testing.io, testing.allocator, fixtureSpec("codedbpro", &.{ "-c", "exit 1" }));
    try testing.expect(take(&reg, "codedbpro") == null); // closed fast: inline retry
    try testing.expect(!pending());
    _ = try reg.addServer("codedbpro", "/bin/sh", &.{ "-c", fixture_script });
    try testing.expectEqual(@as(usize, 2), reg.tools.len);
    try testing.expect(!repeatInline(error.McpHandshakeTimeout));
    try testing.expect(repeatInline(error.McpClosed));
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

test "boot prewarm: early-exit and interactive invocations start nothing" {
    const env = std.process.Environ.Map.init(testing.allocator);
    try testing.expect(!wantsCompanion(.{ .help_flag = true }, &env));
    try testing.expect(!wantsCompanion(.{ .version_flag = true }, &env));
    try testing.expect(!wantsCompanion(.{}, &env)); // REPL: ADR 0230 queues it
    // What args.parse builds for `graff -p hi`: the prompt is the positionals.
    var words: [1][]const u8 = .{"hi"};
    const oneshot: args.Flags = .{ .print_flag = true, .positionals = .fromOwnedSlice(&words), .oneshot_prompt = "hi" };
    try testing.expect(wantsCompanion(oneshot, &env));
    var no_lean = oneshot;
    no_lean.no_lean_flag = true;
    try testing.expect(!wantsCompanion(no_lean, &env));
    var worktree = oneshot;
    worktree.worktree_flag = "w";
    try testing.expect(!wantsCompanion(worktree, &env));
    var title: [2][]const u8 = .{ "title", "hi" };
    try testing.expect(!wantsCompanion(.{ .positionals = .fromOwnedSlice(&title), .is_subcommand = true }, &env));
    var probe = std.process.Environ.Map.init(testing.allocator);
    defer probe.deinit();
    try probe.put("GRAFF_MCP_EAGER", "1");
    try testing.expect(!wantsCompanion(oneshot, &probe));
    // --help/--version return from runSubcommand before the hook; the hook
    // itself sits after it in resolveKeysOrRunAcpPreAuth.
    const src = @embedFile("startup.zig");
    const hook = std.mem.indexOf(u8, src, "boot_prewarm.zig\").startCompanion") orelse return error.TestExpectedHook;
    try testing.expect(hook > (std.mem.indexOf(u8, src, "pub fn resolveKeysOrRunAcpPreAuth") orelse return error.TestExpectedHook));
    const main_src = @embedFile("main.zig");
    const early = std.mem.indexOf(u8, main_src, "startup.runSubcommand(") orelse return error.TestExpectedHook;
    try testing.expect(early < (std.mem.indexOf(u8, main_src, "startup.resolveKeysOrRunAcpPreAuth(") orelse return error.TestExpectedHook));
    try testing.expect(!pending());
}

test "boot prewarm: the settings opt-out is read the way loadSkillSettings reads it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expect(optedOutIn(a, "{\"skills\":{\"codedbpro\":false}}", "codedbpro"));
    try testing.expect(!optedOutIn(a, "{\"skills\":{\"codedbpro\":true}}", "codedbpro"));
    try testing.expect(!optedOutIn(a, "{\"skills\":{\"muonry\":false}}", "codedbpro"));
    try testing.expect(!optedOutIn(a, "not json", "codedbpro"));
}
