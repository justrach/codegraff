//! Lifecycle hooks (codex/Claude-style): the Hook/Hooks config types, the
//! settings.json "hooks" loader, and the per-hook subprocess runner. Split out
//! of main.zig (#123). Takes the settings-file path from harness_policy.zig
//! and the Windows stderr-pipe peek from win_api.zig — both leaves, so this
//! file imports nothing that draws to a terminal (#429). The pre/post/turn-end
//! dispatch stays in main. The codedb-guard (issue #626) per-file index cache
//! (CodedbFileCheck/codedbFileIndexed) also lives here (600-line goal); the
//! guard's on/off + PATH-presence globals (g_codedb_guard/g_codedb_present)
//! stay in main since they're read/written externally (tools.zig,
//! commands_session.zig) as main_mod.g_x.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const root = @import("main.zig");
const harness_policy = @import("harness_policy.zig");
const win = @import("win_api.zig");

/// Lifecycle hooks (codex/Claude-style), loaded once at startup from
/// .harness/settings.json's "hooks" object. Three events:
///
///   pre_tool  — runs BEFORE a tool executes (root and subagents, MCP
///               included). Exit 2 blocks the call: the hook's stderr is
///               returned to the model as the tool result. Any other exit
///               allows. The event JSON arrives on the hook's stdin.
///   post_tool — runs after a tool executed (formatters, notifications);
///               best-effort, exit code ignored.
///   turn_end  — runs after each root turn completes; best-effort.
///
/// Shape: {"hooks": {"pre_tool": [{"match": "bash|edit_file",
/// "command": "./guard.sh", "timeout_ms": 10000}], ...}}. `match` is "*"
/// (default) or pipe-separated tool names. A hung hook is killed at its
/// timeout and treated as allow — hooks must never brick the loop.
pub const Hook = struct {
    match: []const u8,
    command: []const u8,
    timeout_ms: u64,
    /// Optional sanctioned replacement named in the denial the model sees
    /// (#369): converts a blocked call into a 1-call recovery instead of a
    /// guess-and-probe spiral.
    suggest: []const u8 = "",

    pub fn matches(self: Hook, tool: []const u8) bool {
        if (std.mem.eql(u8, self.match, "*")) return true;
        var it = std.mem.splitScalar(u8, self.match, '|');
        while (it.next()) |m| {
            if (std.mem.eql(u8, std.mem.trim(u8, m, " "), tool)) return true;
        }
        return false;
    }
};

pub const Hooks = struct {
    pre_tool: []const Hook = &.{},
    post_tool: []const Hook = &.{},
    turn_end: []const Hook = &.{},

    pub fn total(self: Hooks) usize {
        return self.pre_tool.len + self.post_tool.len + self.turn_end.len;
    }
};
fn parseHookList(arena: Allocator, v: ?Value) []const Hook {
    const arr = v orelse return &.{};
    if (arr != .array) return &.{};
    var list: std.ArrayList(Hook) = .empty;
    for (arr.array.items) |item| {
        if (item != .object) continue;
        const cmd = item.object.get("command") orelse continue;
        if (cmd != .string or cmd.string.len == 0) continue;
        const match: []const u8 = if (item.object.get("match")) |m|
            (if (m == .string and m.string.len > 0) m.string else "*")
        else
            "*";
        const timeout: u64 = if (item.object.get("timeout_ms")) |t|
            (if (t == .integer and t.integer > 0) @intCast(t.integer) else 10_000)
        else
            10_000;
        const suggest: []const u8 = if (item.object.get("suggest")) |sg|
            (if (sg == .string) sg.string else "")
        else
            "";
        list.append(arena, .{ .match = match, .command = cmd.string, .timeout_ms = timeout, .suggest = suggest }) catch continue;
    }
    return list.items;
}

/// Parse the "hooks" section of .harness/settings.json (arena-owned slices;
/// call once at startup with the session arena).
pub fn loadHooks(io: Io, arena: Allocator) Hooks {
    const data = Io.Dir.cwd().readFileAlloc(io, harness_policy.settings_path, arena, .limited(1 << 20)) catch return .{};
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return .{};
    if (v != .object) return .{};
    const hooks = v.object.get("hooks") orelse return .{};
    if (hooks != .object) return .{};
    return .{
        .pre_tool = parseHookList(arena, hooks.object.get("pre_tool")),
        .post_tool = parseHookList(arena, hooks.object.get("post_tool")),
        .turn_end = parseHookList(arena, hooks.object.get("turn_end")),
    };
}

const HookRun = struct { code: ?u8, stderr: []u8 };

/// Denial text for a blocking pre_tool hook: the hook's stderr (or a stock
/// phrase), plus its configured `suggest` replacement when present (#369).
/// Null only on OOM; the caller substitutes an empty error result.
pub fn denialText(gpa: Allocator, h: Hook, stderr: []const u8) ?[]u8 {
    const msg: []const u8 = if (stderr.len > 0) stderr else "denied by hook";
    const sep: []const u8 = if (h.suggest.len > 0) " — use instead: " else "";
    return std.fmt.allocPrint(gpa, "blocked by pre_tool hook: {s}{s}{s}", .{ msg, sep, h.suggest }) catch null;
}

/// Run one hook command: /bin/sh -c, event JSON on stdin, stderr captured
/// (capped), killed at its timeout. Returns the exit code (null on timeout
/// or spawn failure) and the trimmed stderr (gpa-owned).
pub fn runHookCmd(gpa: Allocator, io: Io, command: []const u8, payload: []const u8, timeout_ms: u64) HookRun {
    const none: HookRun = .{ .code = null, .stderr = &.{} };
    var child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", command },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .pipe,
    }) catch return none;
    {
        var wbuf: [4096]u8 = undefined;
        var w = child.stdin.?.writerStreaming(io, &wbuf);
        w.interface.writeAll(payload) catch {};
        w.interface.flush() catch {};
        child.stdin.?.close(io);
        child.stdin = null;
    }
    var rbuf: [16 * 1024]u8 = undefined;
    var r = child.stderr.?.readerStreaming(io, &rbuf);
    var err_text: std.ArrayList(u8) = .empty;
    defer err_text.deinit(gpa);
    const t0: Io.Timestamp = .now(io, .awake);
    var timed_out = false;
    while (true) {
        // Bounded read pump: stderr is tiny in practice; the deadline is the
        // real guard. takeDelimiter would block, so poll the fd instead.
        if (t0.untilNow(io, .awake).toMilliseconds() >= timeout_ms) {
            timed_out = true;
            child.kill(io);
            break;
        }
        if (r.interface.buffered().len == 0) {
            if (builtin.os.tag == .windows) {
                // No pollfd on Windows; peek the pipe for available bytes.
                var avail: u32 = 0;
                if (win.PeekNamedPipe(child.stderr.?.handle, null, 0, null, &avail, null) == 0) break; // broken pipe = EOF
                if (avail == 0) {
                    io.sleep(.fromMilliseconds(50), .awake) catch {};
                    continue;
                }
            } else {
                var fds = [_]std.posix.pollfd{.{ .fd = child.stderr.?.handle, .events = std.posix.POLL.IN, .revents = 0 }};
                const ready = std.posix.poll(&fds, 100) catch break;
                if (ready == 0) continue;
                if (fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0 and fds[0].revents & std.posix.POLL.IN == 0) break;
            }
        }
        const b = r.interface.takeByte() catch break; // EOF: hook exited
        if (err_text.items.len < 4096) err_text.append(gpa, b) catch break;
    }
    const code: ?u8 = if (timed_out) null else switch (child.wait(io) catch return none) {
        .exited => |c| c,
        else => null,
    };
    const trimmed = std.mem.trim(u8, err_text.items, " \t\r\n");
    return .{ .code = code, .stderr = gpa.dupe(u8, trimmed) catch &.{} };
}
test "Hook.matches: wildcard, pipe lists, exact" {
    const star = Hook{ .match = "*", .command = "", .timeout_ms = 0 };
    try std.testing.expect(star.matches("bash"));
    try std.testing.expect(star.matches("anything"));
    const multi = Hook{ .match = "bash|edit_file | write_file", .command = "", .timeout_ms = 0 };
    try std.testing.expect(multi.matches("bash"));
    try std.testing.expect(multi.matches("edit_file"));
    try std.testing.expect(multi.matches("write_file")); // spaces trimmed
    try std.testing.expect(!multi.matches("read_file"));
    try std.testing.expect(!multi.matches("bas")); // no prefix matching
}

test "parseHookList: defaults, malformed entries skipped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try std.json.parseFromSliceLeaky(Value, a,
        \\[{"command": "./guard.sh"},
        \\ {"match": "bash", "command": "lint", "timeout_ms": 500, "suggest": "use mcp edit"},
        \\ {"match": "no-command-key"},
        \\ "not-an-object",
        \\ {"command": ""}]
    , .{});
    const hooks = parseHookList(a, v);
    try std.testing.expectEqual(@as(usize, 2), hooks.len);
    try std.testing.expectEqualStrings("*", hooks[0].match); // default match
    try std.testing.expectEqual(@as(u64, 10_000), hooks[0].timeout_ms); // default timeout
    try std.testing.expectEqualStrings("bash", hooks[1].match);
    try std.testing.expectEqual(@as(u64, 500), hooks[1].timeout_ms);
    try std.testing.expectEqualStrings("", hooks[0].suggest); // default: no suggestion
    try std.testing.expectEqualStrings("use mcp edit", hooks[1].suggest);
}

test "denialText: stderr, stock phrase, suggest suffix" {
    const gpa = std.testing.allocator;
    const plain = Hook{ .match = "*", .command = "", .timeout_ms = 0 };
    const t1 = denialText(gpa, plain, "nope").?;
    defer gpa.free(t1);
    try std.testing.expectEqualStrings("blocked by pre_tool hook: nope", t1);
    const t2 = denialText(gpa, plain, "").?;
    defer gpa.free(t2);
    try std.testing.expectEqualStrings("blocked by pre_tool hook: denied by hook", t2);
    const sug = Hook{ .match = "*", .command = "", .timeout_ms = 0, .suggest = "mcp__codedbpro__replace" };
    const t3 = denialText(gpa, sug, "native edit off").?;
    defer gpa.free(t3);
    try std.testing.expectEqualStrings("blocked by pre_tool hook: native edit off — use instead: mcp__codedbpro__replace", t3);
}

const jobs = @import("jobs.zig");

/// Per-file cache for the codedb guard: `codedb outline <path>` is run once
/// per source file to check whether codedb actually indexed it (large files
/// are silently skipped — e.g. a 13K-line main.zig). A mutex guards concurrent
/// tool-thread access; a miss is benign (duplicate probe).
pub const CodedbFileCheck = struct { path: []const u8, indexed: bool };
var g_codedb_file_checks: std.ArrayList(CodedbFileCheck) = .empty;
var g_codedb_file_mu: Io.Mutex = .init;

pub fn deinitCodedbCache(gpa: Allocator, io: Io) void {
    g_codedb_file_mu.lockUncancelable(io);
    const entries = g_codedb_file_checks.toOwnedSlice(gpa) catch {
        g_codedb_file_mu.unlock(io);
        return;
    };
    g_codedb_file_mu.unlock(io);
    for (entries) |entry| gpa.free(entry.path);
    gpa.free(entries);
}

/// True when `path` is in codedb's symbol index. Runs `codedb outline <path>`
/// (cached): returns "not indexed: <path>" when the file is too large or
/// otherwise skipped, so the guard knows to let bash through instead of
/// trapping the agent between a blocked grep and an empty codedb result.
pub fn codedbFileIndexed(io: Io, gpa: Allocator, path: []const u8) bool {
    g_codedb_file_mu.lockUncancelable(io);
    for (g_codedb_file_checks.items) |e| {
        if (std.mem.eql(u8, e.path, path)) {
            g_codedb_file_mu.unlock(io);
            return e.indexed;
        }
    }
    g_codedb_file_mu.unlock(io);
    // Cache miss: probe once, then store. On error, assume indexed (safe:
    // the guard still redirects to codedb, which is the status-quo behavior).
    const run = jobs.runCapped(gpa, io, &.{ "codedb", "outline", path }, 512, 256, 0) catch return true;
    defer gpa.free(run.stdout);
    defer gpa.free(run.stderr);
    const not_indexed = std.mem.indexOf(u8, run.stdout, "not indexed") != null or
        std.mem.indexOf(u8, run.stderr, "not indexed") != null;
    const result: bool = !not_indexed;
    g_codedb_file_mu.lockUncancelable(io);
    defer g_codedb_file_mu.unlock(io);
    const dup = gpa.dupe(u8, path) catch return result;
    g_codedb_file_checks.append(gpa, .{ .path = dup, .indexed = result }) catch gpa.free(dup);
    return result;
}
