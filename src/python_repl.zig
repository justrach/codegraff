//! Persistent stateful Python 3 REPL tool (`python_repl` / `python`) backed by
//! a long-lived worker per owner (`root` or subagent id) speaking JSONL over
//! stdio pipes.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;
const schema = @import("schema.zig");
const http = @import("http.zig");
const codedbpro_paths = @import("codedbpro_paths.zig");
const mcp_stdio = @import("mcp_stdio.zig");
const no_local_tools = @import("no_local_tools.zig");
const native_fold = @import("native_fold.zig");

pub const tool_name = "python_repl";
pub const unharnessed_tool_name = "python";

pub const default_timeout_ms: u64 = 75_000;
pub const min_timeout_ms: u64 = 1_000;
pub const max_timeout_ms: u64 = 300_000;
const watchdog_grace_ms: u64 = 2_500;
const in_buf_len: usize = 64 << 10;
const out_buf_len: usize = 256 << 10;

pub const input_schema =
    \\{"type":"object","properties":{"code":{"type":"string","description":"Python 3 source code to run in the persistent session REPL."},"timeout_ms":{"type":["integer","null"],"description":"Optional per-call timeout in milliseconds (1000..300000, default 75000)."},"reset":{"type":["boolean","null"],"description":"Clear all REPL globals before running code (code may be empty when reset is true)."}},"required":["code"],"additionalProperties":false}
;

pub const desc = "Execute Python 3 code in a persistent stateful session REPL rooted at the workspace directory. Globals, imports, helper functions, in-memory datasets or models, and working-directory changes persist across calls until reset or session end; stdout/stderr are captured, and a trailing expression's repr() is returned and bound to `_`.";

pub const spec: schema.ToolSpec = .{
    .name = tool_name,
    .desc = desc,
    .schema = input_schema,
};

pub fn isTool(name: []const u8) bool {
    return std.mem.eql(u8, name, tool_name) or std.mem.eql(u8, name, unharnessed_tool_name);
}

pub fn catalogExtras() []const schema.ToolSpec {
    if (no_local_tools.enabled or @import("unharnessed_mode.zig").enabled()) return &.{};
    if (no_local_tools.lean and !native_fold.isLoaded(tool_name)) return &.{};
    return &.{spec};
}

const worker_script = @embedFile("python_repl_worker.py");

const macos_dev_pythons = [_][]const u8{
    "/Library/Developer/CommandLineTools/usr/bin/python3",
    "/Applications/Xcode.app/Contents/Developer/usr/bin/python3",
};

fn canUseCandidate(io: Io, path: []const u8) bool {
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(io, path, &real_buf) catch return false;
    const real = real_buf[0..n];
    if (builtin.os.tag == .macos and std.mem.eql(u8, real, "/usr/bin/python3")) {
        for (macos_dev_pythons) |dev| {
            if (Io.Dir.cwd().access(io, dev, .{})) |_| return true else |_| {}
        }
        return false;
    }
    return true;
}

fn pathEnv() ?[]const u8 {
    if (@import("tool_env.zig").get()) |m| {
        if (m.get("PATH")) |p| return p;
    }
    const g = @import("main.zig").g_path_env;
    if (g.len > 0) return g;
    if (builtin.os.tag != .windows and builtin.os.tag != .wasi) {
        if (std.c.getenv("PATH")) |p| return std.mem.span(p);
    }
    return null;
}

/// Resolve a runnable Python 3 interpreter without triggering macOS's
/// developer-tools GUI install stub on `/usr/bin/python3`.
pub fn findPython(io: Io, arena: Allocator) ?[]const u8 {
    if (pathEnv()) |paths| {
        const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
        const bins = if (builtin.os.tag == .windows)
            [_][]const u8{ "python3.exe", "python3", "python.exe", "python" }
        else
            [_][]const u8{ "python3", "python" };
        for (bins) |bin| {
            var it = std.mem.tokenizeScalar(u8, paths, sep);
            while (it.next()) |dir| {
                const cand = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, bin }) catch continue;
                if (canUseCandidate(io, cand)) return cand;
            }
        }
    }
    if (builtin.os.tag == .windows) return null;
    for ([_][]const u8{ "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3" }) |abs| {
        if (canUseCandidate(io, abs)) return abs;
    }
    return null;
}

const Worker = struct {
    gpa: Allocator,
    io: Io,
    key: []u8,
    child: std.process.Child,
    in_buf: []u8,
    out_buf: []u8,
    writer: Io.File.Writer,
    reader: Io.File.Reader,

    fn start(gpa: Allocator, io: Io, owner: []const u8, prog: []const u8, cwd: []const u8) !*Worker {
        const self = try gpa.create(Worker);
        errdefer gpa.destroy(self);
        const key = try gpa.dupe(u8, owner);
        errdefer gpa.free(key);
        const in_buf = try gpa.alloc(u8, in_buf_len);
        errdefer gpa.free(in_buf);
        const out_buf = try gpa.alloc(u8, out_buf_len);
        errdefer gpa.free(out_buf);

        var child = try std.process.spawn(io, .{
            .argv = &.{ prog, "-u", "-c", worker_script },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
            .environ_map = @import("tool_env.zig").get(),
            .cwd = .{ .path = cwd },
        });
        errdefer mcp_stdio.stopChild(io, &child);

        self.* = .{
            .gpa = gpa,
            .io = io,
            .key = key,
            .child = child,
            .in_buf = in_buf,
            .out_buf = out_buf,
            .writer = undefined,
            .reader = undefined,
        };
        self.writer = self.child.stdin.?.writerStreaming(io, self.in_buf);
        self.reader = self.child.stdout.?.readerStreaming(io, self.out_buf);
        return self;
    }

    fn send(self: *Worker, line: []const u8) !void {
        const w = &self.writer.interface;
        w.writeAll(line) catch return error.PythonWorkerExited;
        w.writeByte('\n') catch return error.PythonWorkerExited;
        w.flush() catch return error.PythonWorkerExited;
    }

    fn readLine(self: *Worker, budget_ms: u64) ![]u8 {
        const Done = union(enum) { line: anyerror![]u8, stall: http.WatchdogFired };
        var buf: [2]Done = undefined;
        var sel: Io.Select(Done) = .init(self.io, &buf);
        sel.concurrent(.line, readLineTask, .{&self.reader.interface}) catch return error.StreamStalled;
        sel.concurrent(.stall, http.deadlineStallTask, .{ self.io, false, budget_ms }) catch {
            const only = sel.await() catch |e| {
                sel.cancelDiscard();
                return e;
            };
            sel.cancelDiscard();
            return only.line;
        };
        const first = sel.await() catch |e| {
            sel.cancelDiscard();
            return e;
        };
        sel.cancelDiscard();
        return switch (first) {
            .line => |l| l,
            .stall => |w| http.watchdogError(w, error.StreamStalled),
        };
    }

    fn stop(self: *Worker) void {
        const gpa = self.gpa;
        mcp_stdio.stopChild(self.io, &self.child);
        gpa.free(self.key);
        gpa.free(self.in_buf);
        gpa.free(self.out_buf);
        gpa.destroy(self);
    }
};

fn readLineTask(r: *Io.Reader) anyerror![]u8 {
    const line = r.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => {
            _ = r.discardDelimiterInclusive('\n') catch return error.PythonWorkerExited;
            return error.PythonResponseTooLarge;
        },
        error.ReadFailed => return error.PythonWorkerExited,
    };
    return line orelse error.PythonWorkerExited;
}

var mutex: Io.Mutex = .init;
var workers: std.StringHashMapUnmanaged(*Worker) = .empty;
var map_gpa: ?Allocator = null;

fn takeWorker(io: Io, key: []const u8) ?*Worker {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const kv = workers.fetchRemove(key) orelse return null;
    return kv.value;
}

fn putWorker(io: Io, w: *Worker) void {
    var displaced: ?*Worker = null;
    var stop_new = false;
    {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        const gpa = map_gpa orelse blk: {
            map_gpa = w.gpa;
            break :blk w.gpa;
        };
        if (workers.fetchRemove(w.key)) |old| displaced = old.value;
        workers.put(gpa, w.key, w) catch {
            stop_new = true;
        };
    }
    if (displaced) |old| old.stop();
    if (stop_new) w.stop();
}

pub fn resetOwner(io: Io, key: []const u8) void {
    if (takeWorker(io, key)) |w| w.stop();
}

pub fn resetSession(io: Io) void {
    resetOwner(io, "root");
}

pub fn stopAll(io: Io) void {
    var all: std.ArrayList(*Worker) = .empty;
    mutex.lockUncancelable(io);
    const gpa = map_gpa;
    if (gpa) |g| {
        var it = workers.valueIterator();
        while (it.next()) |w| all.append(g, w.*) catch {};
        workers.deinit(g);
        workers = .empty;
        map_gpa = null;
    }
    mutex.unlock(io);
    for (all.items) |w| w.stop();
    if (gpa) |g| all.deinit(g);
}

fn fail(gpa: Allocator, msg: []const u8) !ToolOutput {
    return .{ .text = try gpa.dupe(u8, msg), .is_error = true };
}

pub fn execute(ctx: ToolCtx, call_name: []const u8, input: Value) !ToolOutput {
    if (no_local_tools.enabled) return fail(ctx.gpa, no_local_tools.refusal_text);
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    if (@import("hard_policy_context.zig").check(ctx.io, a, ctx.agent_cwd, ctx.hard_policy, "tool.use", call_name)) |denied| {
        return fail(ctx.gpa, denied);
    }
    if (input != .object) return fail(ctx.gpa, "python REPL requires a JSON object");

    const reset = tools.json_args.flag(input, "reset");
    const code_raw = tools.strField(input, "code");
    if (code_raw == null and !reset) return tools.missingArg(ctx.gpa, "code");
    const code = code_raw orelse "";

    const timeout_ms: u64 = if (tools.intField(input, "timeout_ms")) |raw_t|
        @intCast(std.math.clamp(raw_t, @as(i64, min_timeout_ms), @as(i64, max_timeout_ms)))
    else
        default_timeout_ms;

    const root_abs = try codedbpro_paths.sessionAbs(a, ctx.io, ctx.agent_cwd, ".");
    const owner: []const u8 = if (ctx.from_sub) (ctx.worker_id orelse "sub") else "root";
    const req = try std.json.Stringify.valueAlloc(a, .{
        .code = code,
        .workspace_root = root_abs,
        .timeout_ms = timeout_ms,
        .reset = reset,
    }, .{});

    const worker = takeWorker(ctx.io, owner) orelse blk: {
        const prog = findPython(ctx.io, a) orelse return fail(ctx.gpa, "python3 interpreter not found on PATH");
        break :blk Worker.start(ctx.gpa, ctx.io, owner, prog, root_abs) catch |err| {
            return .{ .text = try std.fmt.allocPrint(ctx.gpa, "failed to start python REPL worker: {t}", .{err}), .is_error = true };
        };
    };
    var returned = false;
    defer if (!returned) worker.stop();

    worker.send(req) catch {
        return fail(ctx.gpa, "python REPL worker exited before receiving input; namespace reset for the next call");
    };
    const raw_line = worker.readLine(timeout_ms + watchdog_grace_ms) catch |err| {
        return switch (err) {
            error.Canceled, error.Interrupted => .{ .text = try ctx.gpa.dupe(u8, "Python REPL execution cancelled"), .is_error = true, .cancelled = true },
            error.StreamStalled => fail(ctx.gpa, "python REPL worker hung past deadline; worker terminated and namespace reset"),
            error.PythonResponseTooLarge => fail(ctx.gpa, "python REPL response exceeded framing buffer; worker reset"),
            else => fail(ctx.gpa, "python REPL worker exited unexpectedly; namespace reset for the next call"),
        };
    };
    const parsed = std.json.parseFromSliceLeaky(Value, a, raw_line, .{}) catch {
        return fail(ctx.gpa, "invalid JSON response from python REPL worker");
    };
    if (parsed != .object) {
        return fail(ctx.gpa, "malformed response from python REPL worker");
    }
    const ok = if (parsed.object.get("ok")) |v| v == .bool and v.bool else false;
    const text = if (parsed.object.get("output")) |v| (if (v == .string) v.string else "") else "";
    const out_copy = try ctx.gpa.dupe(u8, text);
    returned = true;
    putWorker(ctx.io, worker);
    return .{ .text = out_copy, .is_error = !ok };
}
