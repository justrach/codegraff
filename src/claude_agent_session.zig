//! Claude Agent sessions (ADR 0309): one long-running `claude` child per
//! graff agent, held between model steps so a tool call can stay open while
//! graff's own loop runs it, and between user turns so Claude Code keeps its
//! prompt cache. A session idle past `idle_ms` is stopped; the next request
//! starts a fresh one and replays graff's history as a checkpoint.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const wire = @import("claude_agent_wire.zig");
const http = @import("http.zig");

pub const idle_ms: i64 = 5 * std.time.ms_per_min;
/// Lines carry whole assistant messages and echoed tool results; a line past
/// this is skipped (it is always an echo graff does not read).
const out_buf_len = 8 << 20;
const in_buf_len = 256 << 10;

/// A `tools/call` Claude Code is waiting on.
pub const Pending = struct {
    request_id: []u8,
    /// The JSON-RPC id, raw JSON.
    rpc_id: []u8,
    tool_use_id: []u8,
};

pub const Session = struct {
    gpa: Allocator,
    io: Io,
    child: std.process.Child,
    env: ?std.process.Environ.Map,
    in_buf: []u8,
    out_buf: []u8,
    writer: Io.File.Writer,
    reader: Io.File.Reader,
    /// Model, effort, prompt mode, system prompt, tools and folder: a change
    /// to any of them needs a new process (the CLI takes them at start).
    props_fp: u64,
    /// The tool list Claude Code last read from graff's server.
    tools_fp: u64 = 0,
    /// graff messages Claude Code already holds, and a hash of them.
    seen: usize = 0,
    seen_fp: u64 = 0,
    rewrites: u32 = 0,
    pending: std.ArrayList(Pending) = .empty,
    /// Results graff produced for calls Claude Code has not asked for yet
    /// (it runs a response's calls one after another): tool_use id → MCP
    /// result JSON. gpa-owned keys and values.
    results: std.StringHashMapUnmanaged([]u8) = .empty,
    used_ms: i64 = 0,

    pub fn start(gpa: Allocator, io: Io, argv: []const []const u8, parent_env: ?*const std.process.Environ.Map, cwd: ?[]const u8, props_fp: u64) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);
        var env: ?std.process.Environ.Map = null;
        if (parent_env) |p| {
            var m = try p.clone(gpa);
            errdefer m.deinit();
            var drop: std.ArrayList([]const u8) = .empty;
            defer drop.deinit(gpa);
            for (m.keys()) |k| if (wire.dropsEnv(k)) try drop.append(gpa, k);
            for (drop.items) |k| _ = m.swapRemove(k);
            for (wire.isolation_env) |kv| try m.put(kv[0], kv[1]);
            env = m;
        }
        errdefer if (env) |*m| m.deinit();
        var child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
            .environ_map = if (env) |*m| m else null,
            .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        });
        errdefer @import("mcp_stdio.zig").stopChild(io, &child);
        const in_buf = try gpa.alloc(u8, in_buf_len);
        errdefer gpa.free(in_buf);
        const out_buf = try gpa.alloc(u8, out_buf_len);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .child = child,
            .env = env,
            .in_buf = in_buf,
            .out_buf = out_buf,
            .writer = undefined,
            .reader = undefined,
            .props_fp = props_fp,
        };
        self.writer = self.child.stdin.?.writerStreaming(io, self.in_buf);
        self.reader = self.child.stdout.?.readerStreaming(io, self.out_buf);
        return self;
    }

    pub fn send(self: *Session, line: []const u8) !void {
        const w = &self.writer.interface;
        w.writeAll(line) catch return error.ClaudeAgentExited;
        w.writeByte('\n') catch return error.ClaudeAgentExited;
        w.flush() catch return error.ClaudeAgentExited;
    }

    /// The next line, or a stall/Esc error once `budget_ms` passes silent.
    pub fn readLine(self: *Session, poll_stdin: bool, budget_ms: u64) ![]u8 {
        const Done = union(enum) { line: anyerror![]u8, stall: http.WatchdogFired };
        var buf: [2]Done = undefined;
        var sel: Io.Select(Done) = .init(self.io, &buf);
        sel.concurrent(.line, readLineTask, .{&self.reader.interface}) catch return error.StreamStalled;
        sel.concurrent(.stall, http.deadlineStallTask, .{ self.io, poll_stdin, budget_ms }) catch {
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

    pub fn addPending(self: *Session, request_id: []const u8, rpc_id: []const u8, tool_use_id: []const u8) !void {
        try self.pending.append(self.gpa, .{
            .request_id = try self.gpa.dupe(u8, request_id),
            .rpc_id = try self.gpa.dupe(u8, rpc_id),
            .tool_use_id = try self.gpa.dupe(u8, tool_use_id),
        });
    }

    pub fn dropPending(self: *Session, index: usize) void {
        const p = self.pending.orderedRemove(index);
        self.gpa.free(p.request_id);
        self.gpa.free(p.rpc_id);
        self.gpa.free(p.tool_use_id);
    }

    pub fn putResult(self: *Session, tool_use_id: []const u8, result: []const u8) !void {
        const gop = try self.results.getOrPut(self.gpa, tool_use_id);
        if (gop.found_existing) {
            self.gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = self.gpa.dupe(u8, tool_use_id) catch |e| {
                self.results.removeByPtr(gop.key_ptr);
                return e;
            };
        }
        gop.value_ptr.* = try self.gpa.dupe(u8, result);
    }

    /// Remove and return a stored result (caller frees with gpa).
    pub fn takeResult(self: *Session, tool_use_id: []const u8) ?[]u8 {
        const kv = self.results.fetchRemove(tool_use_id) orelse return null;
        self.gpa.free(kv.key);
        return kv.value;
    }

    pub fn stop(self: *Session) void {
        @import("mcp_stdio.zig").stopChild(self.io, &self.child);
        while (self.pending.items.len > 0) self.dropPending(self.pending.items.len - 1);
        self.pending.deinit(self.gpa);
        var it = self.results.iterator();
        while (it.next()) |kv| {
            self.gpa.free(kv.key_ptr.*);
            self.gpa.free(kv.value_ptr.*);
        }
        self.results.deinit(self.gpa);
        if (self.env) |*m| m.deinit();
        self.gpa.free(self.in_buf);
        self.gpa.free(self.out_buf);
        self.gpa.destroy(self);
    }
};

fn readLineTask(r: *Io.Reader) anyerror![]u8 {
    while (true) {
        const line = r.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                _ = r.discardDelimiterInclusive('\n') catch return error.ClaudeAgentExited;
                continue;
            },
            error.ReadFailed => return error.ClaudeAgentExited,
        };
        return line orelse error.ClaudeAgentExited;
    }
}

// Sessions are keyed by the owning Agent's address. A session is taken out
// while a request uses it, so parallel subagents never share one. A reused
// address is harmless: the history hash no longer matches, and the stale
// session is replaced.
var mutex: Io.Mutex = .init;
var sessions: std.AutoHashMapUnmanaged(usize, *Session) = .empty;
var map_gpa: ?Allocator = null;

pub fn take(io: Io, owner: usize) ?*Session {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const kv = sessions.fetchRemove(owner) orelse return null;
    return kv.value;
}

/// Return a session after a request, stopping any other session left idle
/// past `idle_ms` (a finished subagent's, or the user walked away).
pub fn put(io: Io, owner: usize, s: *Session, now_ms: i64) void {
    var idle: std.ArrayList(*Session) = .empty;
    defer idle.deinit(s.gpa);
    {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        const gpa = map_gpa orelse blk: {
            map_gpa = s.gpa;
            break :blk s.gpa;
        };
        var it = sessions.iterator();
        while (it.next()) |kv| if (now_ms - kv.value_ptr.*.used_ms > idle_ms) idle.append(s.gpa, kv.value_ptr.*) catch {};
        for (idle.items) |old| {
            var it2 = sessions.iterator();
            while (it2.next()) |kv| if (kv.value_ptr.* == old) {
                _ = sessions.remove(kv.key_ptr.*);
                break;
            };
        }
        sessions.put(gpa, owner, s) catch {
            idle.append(s.gpa, s) catch {};
        };
    }
    for (idle.items) |old| old.stop();
}

/// Stop every held session (graff is exiting).
pub fn stopAll(io: Io) void {
    var all: std.ArrayList(*Session) = .empty;
    mutex.lockUncancelable(io);
    const gpa = map_gpa;
    if (gpa) |g| {
        var it = sessions.valueIterator();
        while (it.next()) |s| all.append(g, s.*) catch {};
        sessions.deinit(g);
        sessions = .empty;
    }
    mutex.unlock(io);
    for (all.items) |s| s.stop();
    if (gpa) |g| all.deinit(g);
}

/// The session held for `owner` is past its idle window.
pub fn expired(s: *const Session, now_ms: i64) bool {
    return s.used_ms != 0 and now_ms - s.used_ms > idle_ms;
}
