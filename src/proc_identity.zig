//! Process START identity: the half of a lock owner record that a recycled pid
//! cannot forge (#413).
//!
//! A bare pid is not an owner. Pids are a small recycled namespace, so after a
//! crash the OS hands the dead holder's number to something unrelated, and a
//! lock keyed on the pid alone then reads as "still held" forever — or, if the
//! lock is time-based instead, gets stolen from a holder that is very much
//! alive. Recording the process's START time alongside the pid removes both:
//! the pair is unique for as long as the machine is up, so liveness becomes
//! "the pid is alive AND it is still the same process", and a provable
//! mismatch is what makes a stale lock reclaimable.
//!
//! Where the number comes from, one source per platform:
//!
//!   * Linux   `/proc/<pid>/stat` field 22 (`starttime`, clock ticks since
//!             boot). Field 2 is `(comm)` and comm may contain BOTH spaces and
//!             ')' — `(my )weird( proc)` is a legal name — so the fields are
//!             counted from the LAST ')' in the line, never by splitting it.
//!   * macOS   `proc_pidinfo(PROC_PIDTBSDINFO)` -> `pbi_start_tvsec/tvusec`,
//!             the same instant `ps -o lstart= -p <pid>` prints. libproc is a
//!             plain libSystem call, so it beats the `ps` subprocess: no fork
//!             in a lock path, no locale-dependent date parsing, and
//!             microsecond instead of one-second resolution (two graffs
//!             started in the same second must not share an identity).
//!   * Windows `GetProcessTimes` -> `ftCreationTime` (100 ns ticks).
//!   * anything else: no identity is available, so `probe` answers with
//!     pid-only liveness and `selfStartId` returns 0. Records stamped there
//!     carry `start_id = 0` and are read under the legacy rule below, which is
//!     exactly the pre-#413 behaviour. Nothing degrades further than that.
//!
//! Two rules make the upgrade safe, and both live in `ownerState`:
//!
//!   * A record with `start_id == 0` — written by a graff older than #413, or
//!     on a platform with no identity source — keeps the old pid-only
//!     contract. An in-flight lock from an older binary is never bricked, and
//!     never stolen just because the new binary cannot verify it.
//!   * A probe that FAILS (permissions, no /proc, an unexpected errno) is
//!     `.unknown`, and unknown means held. Wrongly reclaiming a live lock
//!     corrupts; wrongly honouring a dead one only waits.
//!
//! `claimOwnerFile`/`releaseOwnerFile` package the whole protocol for locks
//! that cannot lean on `flock` — session_lock.zig's degraded path today, the
//! credential store and any daemon lease next — so a future lock inherits the
//! identity rules instead of reinventing a timeout.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// Opaque per-process value that changes every time the OS starts a process.
/// The units differ per platform, so it is only ever compared against another
/// reading of the SAME pid on the SAME boot — never across machines, never
/// interpreted as a wall clock. 0 means "no identity recorded".
pub const StartId = u64;

/// What the OS says about one pid right now.
pub const Probe = union(enum) {
    /// The pid is alive and this is the start identity of what holds it.
    id: StartId,
    /// Nothing holds the pid: the recorded owner is provably gone.
    gone,
    /// The pid could not be resolved to an identity — it may be alive and
    /// simply opaque to us (another user's process), or the identity source
    /// may be missing. Callers must treat this as live.
    unknown,
};

pub const OwnerState = enum {
    /// Someone still owns this record. Wait, do not take the lock.
    held,
    /// The recorded owner is gone or the pid now belongs to a different
    /// process. The lock is stale and may be taken.
    reclaimable,
};

/// The identity half of an owner record: what every graff lock writes down so
/// the next process can decide whether the holder is real.
pub const Record = struct {
    pid: i32 = 0,
    start_id: StartId = 0,
};

/// The whole #413 decision, pure so it can be tested without a process to kill.
pub fn ownerState(rec_start_id: StartId, live: Probe) OwnerState {
    return switch (live) {
        .gone => .reclaimable,
        // Fail SAFE: an unreadable identity is never evidence of death.
        .unknown => .held,
        // rec_start_id == 0 is a legacy (or identity-less platform) record:
        // pid alive == held, exactly as before #413.
        .id => |v| if (rec_start_id == 0 or v == rec_start_id) .held else .reclaimable,
    };
}

pub fn selfPid() i32 {
    // Mirrors trace.currentPid deliberately: this module is a leaf with no
    // graff imports so that any lock can use it without pulling in telemetry.
    return if (builtin.os.tag == .windows)
        @intCast(std.os.windows.GetCurrentProcessId())
    else
        @intCast(std.posix.system.getpid());
}

/// This process's start identity, or 0 where the platform has no source.
pub fn selfStartId(io: Io) StartId {
    return switch (probe(io, selfPid())) {
        .id => |v| v,
        else => 0,
    };
}

/// The owner record to write when taking a lock.
pub fn selfRecord(io: Io) Record {
    return .{ .pid = selfPid(), .start_id = selfStartId(io) };
}

/// `ownerState` for a record read off disk, probing the OS for the answer.
pub fn stateOf(io: Io, rec: Record) OwnerState {
    return ownerState(rec.start_id, probe(io, rec.pid));
}

pub fn probe(io: Io, pid: i32) Probe {
    if (pid <= 0) return .gone;
    return switch (builtin.os.tag) {
        .linux => probeLinux(io, pid),
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .maccatalyst => probeDarwin(io, pid),
        .windows => probeWindows(io, pid),
        else => probePidOnly(io, pid),
    };
}

/// Liveness with no identity: alive answers `.unknown` (held, never stolen),
/// only a definitively free pid answers `.gone`. This is the pre-#413 contract
/// and the floor every platform degrades to.
fn probePidOnly(io: Io, pid: i32) Probe {
    _ = io;
    if (builtin.os.tag == .windows) return .unknown;
    std.posix.kill(@intCast(pid), @enumFromInt(0)) catch |err| switch (err) {
        error.ProcessNotFound => return .gone,
        // PermissionDenied means alive and owned by someone else.
        else => return .unknown,
    };
    return .unknown;
}

fn probeLinux(io: Io, pid: i32) Probe {
    _ = io;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch return .unknown;
    // Direct openat(FDCWD), not an Io.Dir read: under the io_uring test
    // backend a /proc read can fail with EBADF, which the Io layer panics on
    // as a "programmer bug" instead of surfacing a catchable error (that
    // crashed CI on Linux). procfs reports size 0, so read to EOF.
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{}, 0) catch |err| switch (err) {
        error.FileNotFound => return .gone,
        else => return .unknown,
    };
    defer _ = std.posix.system.close(fd); // raw syscall wrapper (no std.posix.close in this std); returns usize, not an error
    var buf: [4096]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch return .unknown;
    return if (parseLinuxStat(buf[0..n])) |v| .{ .id = v } else .unknown;
}

/// Field 22 of a `/proc/<pid>/stat` line. Field 2 is `(comm)`, which may hold
/// spaces and ')' alike, so the only safe anchor is the LAST ')': everything
/// after it is space separated and positional, starting at field 3.
pub fn parseLinuxStat(text: []const u8) ?StartId {
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    var it = std.mem.tokenizeAny(u8, text[close + 1 ..], " \t\r\n");
    var n: usize = 0;
    while (it.next()) |tok| {
        n += 1; // token 1 is field 3 (state), so field 22 is token 20.
        if (n == 20) return std.fmt.parseInt(StartId, tok, 10) catch null;
    }
    return null;
}

const darwin = struct {
    const PROC_PIDTBSDINFO: c_int = 3;

    /// `struct proc_bsdinfo` from <sys/proc_info.h>. Only the tail is read,
    /// but the whole layout has to be spelled out for the offsets to land; the
    /// comptime assert below is what keeps that honest.
    const ProcBsdInfo = extern struct {
        flags: u32,
        status: u32,
        xstatus: u32,
        pid: u32,
        ppid: u32,
        uid: u32,
        gid: u32,
        ruid: u32,
        rgid: u32,
        svuid: u32,
        svgid: u32,
        rfu_1: u32,
        comm: [16]u8,
        name: [32]u8,
        nfiles: u32,
        pgid: u32,
        pjobc: u32,
        e_tdev: u32,
        e_tpgid: u32,
        nice: i32,
        start_tvsec: u64,
        start_tvusec: u64,
    };

    extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, buffersize: c_int) c_int;
};

fn probeDarwin(io: Io, pid: i32) Probe {
    comptime std.debug.assert(@sizeOf(darwin.ProcBsdInfo) == 136);
    comptime std.debug.assert(@offsetOf(darwin.ProcBsdInfo, "start_tvsec") == 120);
    var info: darwin.ProcBsdInfo = undefined;
    const size: c_int = @sizeOf(darwin.ProcBsdInfo);
    const n = darwin.proc_pidinfo(@intCast(pid), darwin.PROC_PIDTBSDINFO, 0, &info, size);
    // A short answer means ESRCH (dead) or EPERM (alive, another user's).
    // kill(pid, 0) tells those apart without reading errno by hand.
    if (n != size) return probePidOnly(io, pid);
    const usec = info.start_tvsec *% std.time.us_per_s +% info.start_tvusec;
    return if (usec == 0) .unknown else .{ .id = usec };
}

const win = struct {
    const w = std.os.windows;
    const PROCESS_QUERY_LIMITED_INFORMATION: w.DWORD = 0x1000;

    extern "kernel32" fn OpenProcess(dwDesiredAccess: w.DWORD, bInheritHandle: w.BOOL, dwProcessId: w.DWORD) callconv(.winapi) ?w.HANDLE;
    extern "kernel32" fn GetProcessTimes(
        hProcess: w.HANDLE,
        lpCreationTime: *w.FILETIME,
        lpExitTime: *w.FILETIME,
        lpKernelTime: *w.FILETIME,
        lpUserTime: *w.FILETIME,
    ) callconv(.winapi) w.BOOL;
};

fn probeWindows(io: Io, pid: i32) Probe {
    _ = io;
    const w = std.os.windows;
    // QUERY_LIMITED_INFORMATION is the least privilege that still answers
    // GetProcessTimes, and it works across integrity levels.
    const handle = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, .FALSE, @intCast(pid)) orelse {
        // INVALID_PARAMETER is Windows for "no process has that id"; a denial
        // means it exists and is simply out of reach.
        return switch (w.GetLastError()) {
            .INVALID_PARAMETER => .gone,
            else => .unknown,
        };
    };
    defer w.CloseHandle(handle);
    var created: w.FILETIME = undefined;
    var exited: w.FILETIME = undefined;
    var kernel: w.FILETIME = undefined;
    var user: w.FILETIME = undefined;
    if (!win.GetProcessTimes(handle, &created, &exited, &kernel, &user).toBool()) return .unknown;
    const ticks = (@as(u64, created.dwHighDateTime) << 32) | @as(u64, created.dwLowDateTime);
    return if (ticks == 0) .unknown else .{ .id = ticks };
}

/// One line, ASCII, no allocator: a lock file must be writable from a path
/// that is already failing. `formatRecord` needs at least `record_max` bytes.
pub const record_max = 80;

pub fn formatRecord(buf: *[record_max]u8, rec: Record) []const u8 {
    return std.fmt.bufPrint(buf, "graff-owner 1 pid={d} start={d}\n", .{ rec.pid, rec.start_id }) catch unreachable;
}

/// Tolerant on purpose. `start=` missing (a pre-#413 writer) yields
/// `start_id = 0`, which `ownerState` honours under the legacy rule, and a
/// bare number is read as the classic one-line pidfile. Anything else is null:
/// an unparsable record is no record, never a spurious owner.
pub fn parseRecord(text: []const u8) ?Record {
    const line = std.mem.trim(u8, text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len], " \t\r");
    if (line.len == 0) return null;
    if (!std.mem.startsWith(u8, line, "graff-owner")) {
        // The classic one-line pidfile: a number and nothing else.
        const pid = std.fmt.parseInt(i32, line, 10) catch return null;
        return if (pid > 0) .{ .pid = pid } else null;
    }
    var rec: Record = .{};
    var have_pid = false;
    var it = std.mem.tokenizeAny(u8, line, " \t");
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "pid=")) {
            rec.pid = std.fmt.parseInt(i32, tok[4..], 10) catch return null;
            have_pid = true;
        } else if (std.mem.startsWith(u8, tok, "start=")) {
            rec.start_id = std.fmt.parseInt(StartId, tok[6..], 10) catch return null;
        }
    }
    if (!have_pid or rec.pid <= 0) return null;
    return rec;
}

/// A record is worth waiting for only when it names someone ELSE and is still
/// held. Our own record is never contention.
pub fn heldByOther(rec: Record, my_pid: i32, state: OwnerState) bool {
    return rec.pid != my_pid and state == .held;
}

pub fn readOwnerFile(io: Io, dir: Io.Dir, path: []const u8) ?Record {
    var buf: [record_max]u8 = undefined;
    const text = dir.readFile(io, path, &buf) catch return null;
    return parseRecord(text);
}

/// Take an owner file, or report that a live owner still has it. This is the
/// whole cross-process lock protocol for a lock that cannot use `flock` —
/// a filesystem with no working locks, or a lock that must outlive an open
/// file descriptor — and it is what makes the identity worth recording: a
/// crashed owner's record is RECLAIMED because its identity provably no longer
/// matches, with no timeout to tune and no live owner ever robbed.
///
/// Failing to read or write the file itself is deliberately not an error. An
/// owner file is a best-effort stand-in for a lock, and it must never become
/// the reason the operation it guards cannot happen at all.
pub fn claimOwnerFile(io: Io, dir: Io.Dir, path: []const u8) error{LockHeld}!void {
    if (readOwnerFile(io, dir, path)) |rec| {
        if (heldByOther(rec, selfPid(), stateOf(io, rec))) return error.LockHeld;
    }
    var stamp: [record_max]u8 = undefined;
    dir.writeFile(io, .{ .sub_path = path, .data = formatRecord(&stamp, selfRecord(io)) }) catch {};
}

pub fn releaseOwnerFile(io: Io, dir: Io.Dir, path: []const u8) void {
    dir.deleteFile(io, path) catch {};
}

test "ownerState: the same pid holds only while it is the same process (#413)" {
    // Live and unchanged: the lock is genuinely held.
    try std.testing.expectEqual(OwnerState.held, ownerState(4242, .{ .id = 4242 }));
    // Same pid, different process: a recycled pid may never keep the lock.
    try std.testing.expectEqual(OwnerState.reclaimable, ownerState(4242, .{ .id = 4243 }));
    // Nothing holds the pid at all.
    try std.testing.expectEqual(OwnerState.reclaimable, ownerState(4242, .gone));
}

test "ownerState: a record with no start identity keeps the pre-#413 contract" {
    // An older graff's in-flight lock: pid alive means held, and it is never
    // stolen merely because the new binary cannot verify it.
    try std.testing.expectEqual(OwnerState.held, ownerState(0, .{ .id = 999 }));
    try std.testing.expectEqual(OwnerState.held, ownerState(0, .unknown));
    // Only a provably free pid retires it — the old rule, unchanged.
    try std.testing.expectEqual(OwnerState.reclaimable, ownerState(0, .gone));
}

test "ownerState: a failed identity read fails safe and never steals a lock" {
    try std.testing.expectEqual(OwnerState.held, ownerState(4242, .unknown));
    try std.testing.expectEqual(OwnerState.held, ownerState(0, .unknown));
}

test "parseLinuxStat: field 22 survives a comm holding spaces and ')'" {
    // comm is `graff (test) x`: a naive whitespace split answers 1 here, and
    // any anchor but the LAST ')' lands inside the name.
    const weird = "4242 (graff (test) x) S 4241 4242 4242 0 -1 4194304 512 0 0 0 7 3 0 0 20 0 1 0 987654321 12345678 900 18446744073709551615";
    try std.testing.expectEqual(@as(?StartId, 987654321), parseLinuxStat(weird));

    // The ordinary shape, captured from a real /proc/<pid>/stat.
    const plain = "1 (systemd) S 0 1 1 0 -1 4194560 24512 366 89 0 61 213 0 0 20 0 1 0 12 170201088 3221 18446744073709551615 1 1 0 0 0 0 671173123 4096 1260 0 0 0 17 2 0 0 0 0 0\n";
    try std.testing.expectEqual(@as(?StartId, 12), parseLinuxStat(plain));

    // Truncated or nonsense input is no identity rather than a wrong one.
    try std.testing.expectEqual(@as(?StartId, null), parseLinuxStat("4242 (graff) S 1 2 3"));
    try std.testing.expectEqual(@as(?StartId, null), parseLinuxStat("no parens here"));
}

test "parseRecord: round trips, tolerates a legacy pidfile, rejects garbage" {
    var buf: [record_max]u8 = undefined;
    const line = formatRecord(&buf, .{ .pid = 4242, .start_id = 1785994345056160 });
    const back = parseRecord(line) orelse return error.ExpectedRecord;
    try std.testing.expectEqual(@as(i32, 4242), back.pid);
    try std.testing.expectEqual(@as(StartId, 1785994345056160), back.start_id);

    // A record from a graff older than #413: pid, no identity.
    const legacy = parseRecord("graff-owner 1 pid=77\n") orelse return error.ExpectedRecord;
    try std.testing.expectEqual(@as(i32, 77), legacy.pid);
    try std.testing.expectEqual(@as(StartId, 0), legacy.start_id);
    // The classic one-line pidfile, same treatment.
    const bare = parseRecord("77\n") orelse return error.ExpectedRecord;
    try std.testing.expectEqual(@as(i32, 77), bare.pid);
    try std.testing.expectEqual(@as(StartId, 0), bare.start_id);

    try std.testing.expect(parseRecord("") == null);
    try std.testing.expect(parseRecord("graff-owner 1\n") == null);
    try std.testing.expect(parseRecord("graff-owner 1 pid=0 start=5") == null);
    try std.testing.expect(parseRecord("graff-owner 1 pid=nonsense") == null);
    try std.testing.expect(parseRecord("half a written line") == null);
}

test "heldByOther: only a live record belonging to someone else is a holder" {
    const me = selfPid();
    try std.testing.expect(heldByOther(.{ .pid = me + 1, .start_id = 7 }, me, .held));
    // Our own record is not contention, whatever it says.
    try std.testing.expect(!heldByOther(.{ .pid = me, .start_id = 7 }, me, .held));
    // A crashed owner, or one whose pid now belongs to something else.
    try std.testing.expect(!heldByOther(.{ .pid = me + 1, .start_id = 7 }, me, .reclaimable));
}

test "claimOwnerFile: a crashed owner is reclaimed, a live one is waited for" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // no pid 1
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const lock = "engine.owner";
    var buf: [record_max]u8 = undefined;

    // Nobody has it: taking it stamps our own record.
    try claimOwnerFile(io, tmp.dir, lock);
    const mine = readOwnerFile(io, tmp.dir, lock) orelse return error.ExpectedRecord;
    try std.testing.expectEqual(selfPid(), mine.pid);
    // Re-entrant: our own record never locks us out of our own lock.
    try claimOwnerFile(io, tmp.dir, lock);

    // pid 1 (init/launchd) is alive on every unix and is never us. A record
    // with NO start identity is what a graff older than #413 wrote, and it
    // must still be honoured or the upgrade would brick an in-flight lock.
    try tmp.dir.writeFile(io, .{ .sub_path = lock, .data = "graff-owner 1 pid=1\n" });
    try std.testing.expectError(error.LockHeld, claimOwnerFile(io, tmp.dir, lock));

    switch (probe(io, 1)) {
        .id => |live| {
            // Same pid, provably a different process: the record is reclaimed.
            try tmp.dir.writeFile(io, .{ .sub_path = lock, .data = formatRecord(&buf, .{ .pid = 1, .start_id = live +% 1 }) });
            try claimOwnerFile(io, tmp.dir, lock);
            // Same pid AND the same identity: never stolen from.
            try tmp.dir.writeFile(io, .{ .sub_path = lock, .data = formatRecord(&buf, .{ .pid = 1, .start_id = live }) });
            try std.testing.expectError(error.LockHeld, claimOwnerFile(io, tmp.dir, lock));
        },
        // pid 1 is opaque to an unprivileged user on macOS; unreadable is
        // held, which the legacy assertion above already proved here.
        .unknown => {},
        .gone => return error.InitProcessReportedGone,
    }

    // An unreadable or truncated record is no record: it must not lock the
    // world out, and it must not survive the next claim either.
    try tmp.dir.writeFile(io, .{ .sub_path = lock, .data = "half a written l" });
    try claimOwnerFile(io, tmp.dir, lock);
    releaseOwnerFile(io, tmp.dir, lock);
    try std.testing.expect(readOwnerFile(io, tmp.dir, lock) == null);
}

test "probe: this process is alive and stably identified; a free pid is gone" {
    const io = std.testing.io;
    const me = selfPid();
    try std.testing.expect(me > 0);
    switch (probe(io, me)) {
        // Every supported platform must identify the process it is running in.
        .id => |v| {
            try std.testing.expect(v != 0);
            // Stable: a second reading of the same live pid must agree, or
            // every lock would look reclaimable the moment it was checked.
            try std.testing.expectEqual(OwnerState.held, stateOf(io, selfRecord(io)));
            // And a neighbouring identity must not.
            try std.testing.expectEqual(OwnerState.reclaimable, stateOf(io, .{ .pid = me, .start_id = v + 1 }));
        },
        // A platform with no identity source degrades to pid-only liveness.
        .unknown => try std.testing.expectEqual(OwnerState.held, stateOf(io, .{ .pid = me })),
        .gone => return error.LiveProcessReportedGone,
    }
    // pid 0 and negatives are not processes, so nothing can be held by them.
    try std.testing.expectEqual(Probe.gone, probe(io, 0));
    try std.testing.expectEqual(Probe.gone, probe(io, -1));
}
