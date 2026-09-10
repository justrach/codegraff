//! Fail-closed group stopping. All effects are injected for deterministic tests.
const std = @import("std");
const builtin = @import("builtin");
const identity = @import("proc_identity.zig");
pub const Result = enum { stopped, gone, unverifiable, unsupported };
pub const Signal = enum { term, kill };

/// A command string is not an executable identity (shells may exec arbitrary
/// commands). Records do not store an executable fingerprint, so start identity
/// and verified group leadership are the available ownership evidence.
pub fn stop(pid: i32, start_id: u64, ops: anytype) Result {
    if (pid <= 1 or start_id == 0) return .unverifiable;
    switch (ops.probe(pid)) {
        .gone => return .gone,
        .unknown => return .unverifiable,
        .id => |id| {
            if (id == 0) return .unverifiable;
            if (id != start_id) return .gone;
        },
    }
    if (!eligible(pid, start_id, ops)) return .unverifiable;
    ops.signal(pid, .term) catch return .unverifiable;
    for (0..20) |_| {
        ops.sleep() catch return .unverifiable;
        if (ops.groupGone(pid)) |gone| {
            if (gone) return .stopped;
        } else return .unverifiable;
        // A terminated leader can disappear before its children finish exiting.
        // Keep observing the group, but never grant another signal on that fact.
        switch (ops.probe(pid)) {
            .gone => continue,
            .unknown => return .unverifiable,
            .id => |id| if (id != start_id) return .unverifiable,
        }
        if (!eligible(pid, start_id, ops)) return .unverifiable;
    }
    // Never escalate on a stale pre-TERM identity or process group.
    if (!eligible(pid, start_id, ops)) return .unverifiable;
    ops.signal(pid, .kill) catch return .unverifiable;
    for (0..20) |_| {
        ops.sleep() catch return .unverifiable;
        if (ops.groupGone(pid)) |gone| {
            if (gone) return .stopped;
        } else return .unverifiable;
        if (!eligible(pid, start_id, ops)) return .unverifiable;
    }
    return .unverifiable;
}

fn eligible(pid: i32, start_id: u64, ops: anytype) bool {
    const own = ops.ownGroup() orelse return false;
    if (own <= 0 or own == pid) return false;
    const group = ops.group(pid) orelse return false;
    if (group != pid) return false;
    // Read identity last, immediately before allowing a signal.
    return switch (ops.probe(pid)) {
        .id => |id| id != 0 and id == start_id,
        else => false,
    };
}

pub fn noLiveMembers(text: []const u8, pid: i32) ?bool {
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    var rows: usize = 0;
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const group = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
        const state = fields.next() orelse return null;
        if (fields.next() != null or state.len == 0) return null;
        rows += 1;
        if (group == pid and state[0] != 'Z') return false;
    }
    return if (rows == 0) null else true;
}

extern "c" fn getpgid(pid: c_int) c_int;

pub const Native = struct {
    io: std.Io,
    pub fn probe(self: Native, pid: i32) identity.Probe {
        return identity.probe(self.io, pid);
    }
    pub fn ownGroup(self: Native) ?i32 {
        return self.group(0);
    }
    pub fn group(_: Native, pid: i32) ?i32 {
        if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return null;
        const pgid = getpgid(pid);
        return if (pgid > 0) pgid else null;
    }
    pub fn signal(_: Native, pid: i32, sig: Signal) !void {
        try std.posix.kill(-pid, if (sig == .term) .TERM else .KILL);
    }
    pub fn groupGone(self: Native, pid: i32) ?bool {
        std.posix.kill(-pid, @enumFromInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => return true,
            // Darwin can report EPERM for a zombie-only group. This is not
            // absence evidence: require the independent process inventory.
            error.PermissionDenied => {},
            else => return null,
        };
        // Detached children can remain zombies until the parent exits. They
        // cannot serve sockets and SIGKILL cannot remove them; don't mistake
        // an unreaped process for a live tree. Inspect without reaping a child
        // that another waiter may own.
        const gpa = std.heap.page_allocator;
        const r = @import("process_runner.zig").runCapped(gpa, self.io, &.{ "ps", "-axo", "pgid=,stat=" }, 1024 * 1024, 4096, 500) catch return null;
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        if (r.timed_out or r.cancelled or r.stdout_truncated or r.stderr_truncated or r.stderr.len != 0) return null;
        switch (r.term) {
            .exited => |code| if (code != 0) return null,
            else => return null,
        }
        return noLiveMembers(r.stdout, pid);
    }
    pub fn sleep(self: Native) !void {
        try self.io.sleep(.fromMilliseconds(100), .awake);
    }
};
