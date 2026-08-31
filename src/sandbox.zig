//! #554: the pluggable sandbox seam — acquire a sandbox, run things in it,
//! capture its filesystem state, and bring that state back up later (on this
//! backend or another one).
//!
//! Two roles, both the `ctx`/`vt` pair engine_sink.zig uses:
//!   - `Backend`: `acquire(key)` for a fresh sandbox, `acquireFromSnapshot`
//!     for one restored from a captured payload. One WARM sandbox per key —
//!     acquiring a key that already has one evicts it first, so a key names a
//!     lane rather than an ever-growing pile of containers.
//!   - `Handle`: `exec(argv)` inside it, `snapshot()` to capture it.
//!
//! THE PAYLOAD NEVER ENTERS THIS ADDRESS SPACE. A `Payload` carries the blob's
//! KIND, LENGTH and backend REF, not its bytes: the backend streams the blob
//! straight through a file handle at `Blob.rel` (the child's stdout on
//! capture, its stdin on restore). A container image tar is routinely
//! gigabytes, and holding one in memory is the exo limitation #554 names as
//! the thing not to repeat.
//!
//! WHAT A REWIND IS NOT. Restoring a snapshot puts FILESYSTEM state back. The
//! conversation and the event log are canonical and are never rewound with it
//! — commands_sandbox.zig says so in the user-facing output, because a user
//! who believed both had moved would read the transcript as the record of a
//! run that never happened.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const session_index = @import("session_index.zig");
const tool_spill = @import("tool_spill.zig");
const util = @import("util.zig");

/// Every way a sandbox operation can fail, flat: the vtable entries below are
/// function POINTERS, so every backend has to name exactly this set.
pub const Error = error{
    /// The backend's CLI is absent (no `docker` on PATH) or refused to run.
    /// The one error a REPL command must render as an explanation, never a crash.
    SandboxUnavailable,
    /// This backend cannot capture state at all (LocalProcess).
    SnapshotUnsupported,
    SnapshotFailed,
    RestoreFailed,
    ExecFailed,
    OutOfMemory,
};

/// What a captured payload IS. One kind in the MVP; a second (an AppleContainer
/// or Daytona-native blob) is the same wire with a different producer, which is
/// why the manifest records the kind rather than assuming it.
pub const Kind = enum {
    docker_image_tar,

    pub fn tag(k: Kind) []const u8 {
        return @tagName(k);
    }

    pub fn parse(s: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, s);
    }
};

/// A captured snapshot, minus its bytes (see the file header). `ref` is what
/// the blob names inside itself — for `.docker_image_tar`, the image tag
/// `docker load` brings back.
pub const Payload = struct {
    kind: Kind = .docker_image_tar,
    len: u64 = 0,
    ref: []const u8 = "",
};

/// Where a snapshot's blob lives on disk. `dir` is the directory `.graff` sits
/// under (the cwd in production, a tmp dir in tests) and `rel` is the
/// forward-slashed relative path of `payload.bin` under it — the `.graff/`
/// path invariant in session_index.zig governs every path built here.
pub const Blob = struct {
    io: Io,
    dir: Io.Dir,
    rel: []const u8,
};

pub const ExecResult = struct {
    exit_code: i32 = 0,
    stdout: []u8 = &.{},
    stderr: []u8 = &.{},

    pub fn deinit(self: ExecResult, gpa: Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

pub const HandleVTable = struct {
    exec: *const fn (ctx: *anyopaque, gpa: Allocator, argv: []const []const u8) Error!ExecResult,
    /// Capture this sandbox into `blob`, returning what to record. The blob is
    /// written by the backend; the caller only supplies where it goes.
    snapshot: *const fn (ctx: *anyopaque, gpa: Allocator, blob: Blob) Error!Payload,
    release: *const fn (ctx: *anyopaque) void,
};

pub const Handle = struct {
    ctx: *anyopaque,
    vt: *const HandleVTable,
    /// The lane this sandbox occupies. One warm sandbox per key.
    key: []const u8 = "default",
    /// Backend-assigned identity (a container id), for display.
    id: []const u8 = "",

    pub fn exec(self: Handle, gpa: Allocator, argv: []const []const u8) Error!ExecResult {
        return self.vt.exec(self.ctx, gpa, argv);
    }

    pub fn snapshot(self: Handle, gpa: Allocator, blob: Blob) Error!Payload {
        return self.vt.snapshot(self.ctx, gpa, blob);
    }

    pub fn release(self: Handle) void {
        self.vt.release(self.ctx);
    }
};

pub const BackendVTable = struct {
    name: []const u8,
    /// False when the backend cannot run here at all (its CLI is missing).
    /// Checked before acquiring so the caller can explain rather than fail.
    available: *const fn (ctx: *anyopaque) bool,
    acquire: *const fn (ctx: *anyopaque, gpa: Allocator, key: []const u8) Error!Handle,
    acquireFromSnapshot: *const fn (
        ctx: *anyopaque,
        gpa: Allocator,
        key: []const u8,
        payload: Payload,
        blob: Blob,
    ) Error!Handle,
};

pub const Backend = struct {
    ctx: *anyopaque,
    vt: *const BackendVTable,

    pub fn name(self: Backend) []const u8 {
        return self.vt.name;
    }

    pub fn available(self: Backend) bool {
        return self.vt.available(self.ctx);
    }

    pub fn acquire(self: Backend, gpa: Allocator, key: []const u8) Error!Handle {
        return self.vt.acquire(self.ctx, gpa, key);
    }

    pub fn acquireFromSnapshot(
        self: Backend,
        gpa: Allocator,
        key: []const u8,
        payload: Payload,
        blob: Blob,
    ) Error!Handle {
        return self.vt.acquireFromSnapshot(self.ctx, gpa, key, payload, blob);
    }
};

// ── Persistence layout ─────────────────────────────────────────────────────
// .graff/sessions/<session>/snapshots/<id>/{manifest.json,payload.bin}
// A sibling of #409's artifacts/ dir under the same session, so one session's
// leftovers stay one subtree and tool_spill's sweep reclaims them together.

pub const snapshots_leaf = "snapshots";
pub const manifest_name = "manifest.json";
pub const payload_name = "payload.bin";

/// True when `s` can only ever name something INSIDE the session subtree.
/// Session names come from /save and from generated titles, snapshot ids from
/// `newId`, and neither may become a write outside `.graff/sessions`.
pub fn safeName(s: []const u8) bool {
    return tool_spill.safeName(s);
}

pub fn snapshotsDir(arena: Allocator, session: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ session_index.sessions_dir, session, snapshots_leaf });
}

pub fn snapshotDir(arena: Allocator, session: []const u8, id: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ try snapshotsDir(arena, session), id });
}

pub fn manifestPath(arena: Allocator, session: []const u8, id: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ try snapshotDir(arena, session, id), manifest_name });
}

pub fn payloadPath(arena: Allocator, session: []const u8, id: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ try snapshotDir(arena, session, id), payload_name });
}

/// A fresh snapshot id: sortable by capture time, unique per process.
/// `io.random` rather than a counter, so two graffs sharing a session dir
/// cannot collide inside the same millisecond.
pub fn newId(arena: Allocator, io: Io) Allocator.Error![]const u8 {
    var raw: [4]u8 = undefined;
    io.random(&raw);
    const nonce = std.fmt.bytesToHex(raw, .lower);
    return std.fmt.allocPrint(arena, "{d}-{s}", .{ util.unixMs(io), &nonce });
}

/// What `manifest.json` holds. Everything a restore needs WITHOUT the blob:
/// which backend produced it, what shape the payload is, what it refers to,
/// and how big it is.
pub const Manifest = struct {
    id: []const u8 = "",
    backend: []const u8 = "",
    kind: []const u8 = "docker_image_tar",
    ref: []const u8 = "",
    len: u64 = 0,
    created_ms: i64 = 0,

    pub fn payload(m: Manifest) Payload {
        return .{
            .kind = Kind.parse(m.kind) orelse .docker_image_tar,
            .len = m.len,
            .ref = m.ref,
        };
    }
};

pub fn renderManifest(arena: Allocator, m: Manifest) Allocator.Error![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    s.write(m) catch return error.OutOfMemory;
    return aw.writer.buffered();
}

/// Null for anything that is not a manifest we wrote — a half-written file, a
/// directory someone dropped in by hand. Listing must skip those, not fail.
pub fn parseManifest(arena: Allocator, bytes: []const u8) ?Manifest {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{ .allocate = .alloc_always }) catch return null;
    if (parsed != .object) return null;
    const obj = parsed.object;
    const id = util.strFieldObj(obj, "id") orelse return null;
    if (id.len == 0) return null;
    return .{
        .id = id,
        .backend = util.strFieldObj(obj, "backend") orelse "",
        .kind = util.strFieldObj(obj, "kind") orelse "docker_image_tar",
        .ref = util.strFieldObj(obj, "ref") orelse "",
        .len = @intCast(@max(0, util.intFieldObj(obj, "len", 0))),
        .created_ms = util.intFieldObj(obj, "created_ms", 0),
    };
}

/// Write `manifest.json` beside a blob the backend has already streamed out.
pub fn writeManifest(io: Io, dir: Io.Dir, arena: Allocator, session: []const u8, m: Manifest) !void {
    try dir.writeFile(io, .{
        .sub_path = try manifestPath(arena, session, m.id),
        .data = try renderManifest(arena, m),
    });
}

/// Every snapshot this session has on disk, oldest capture first. Unreadable
/// or unparseable entries are skipped: a listing is a convenience and must
/// never be the thing that fails a command.
pub fn list(io: Io, dir: Io.Dir, arena: Allocator, session: []const u8) Allocator.Error![]Manifest {
    var found: std.ArrayList(Manifest) = .empty;
    if (!safeName(session)) return found.items;
    var d = dir.openDir(io, try snapshotsDir(arena, session), .{ .iterate = true }) catch return found.items;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const id = arena.dupe(u8, entry.name) catch continue;
        const path = manifestPath(arena, session, id) catch continue;
        const bytes = dir.readFileAlloc(io, path, arena, .limited(64 * 1024)) catch continue;
        const m = parseManifest(arena, bytes) orelse continue;
        try found.append(arena, m);
    }
    std.mem.sort(Manifest, found.items, {}, byCapture);
    return found.items;
}

fn byCapture(_: void, a: Manifest, b: Manifest) bool {
    if (a.created_ms != b.created_ms) return a.created_ms < b.created_ms;
    return std.mem.lessThan(u8, a.id, b.id);
}

pub fn find(io: Io, dir: Io.Dir, arena: Allocator, session: []const u8, id: []const u8) ?Manifest {
    if (!safeName(session) or !safeName(id)) return null;
    const path = manifestPath(arena, session, id) catch return null;
    const bytes = dir.readFileAlloc(io, path, arena, .limited(64 * 1024)) catch return null;
    return parseManifest(arena, bytes);
}

/// Delete one snapshot tree (manifest + payload). Missing is success: GC is
/// idempotent and must not fail a command because a half-written dir vanished.
pub fn remove(io: Io, dir: Io.Dir, arena: Allocator, session: []const u8, id: []const u8) bool {
    if (!safeName(session) or !safeName(id)) return false;
    const path = snapshotDir(arena, session, id) catch return false;
    dir.access(io, path, .{}) catch return true;
    dir.deleteTree(io, path) catch return false;
    return true;
}

pub const GcResult = struct {
    kept: usize = 0,
    removed: usize = 0,
    bytes: u64 = 0,
};

/// Keep the newest `keep` snapshots (list is oldest-first); delete the rest.
/// `keep == 0` deletes every snapshot this session has on disk.
pub fn gc(io: Io, dir: Io.Dir, arena: Allocator, session: []const u8, keep: usize) Allocator.Error!GcResult {
    const items = try list(io, dir, arena, session);
    var result: GcResult = .{ .kept = items.len };
    if (items.len <= keep) return result;
    for (items[0 .. items.len - keep]) |m| {
        if (remove(io, dir, arena, session, m.id)) {
            result.removed += 1;
            result.bytes += m.len;
            result.kept -= 1;
        }
    }
    return result;
}

// ── The active sandbox ─────────────────────────────────────────────────────
// A process-wide pair rather than an Agent field: nothing in the MVP attaches
// a sandbox automatically, so the REPL commands need a seam they can read that
// is EMPTY by default and that a test (or a future `--sandbox` launch flag)
// can fill. Empty is the normal state and must render as an explanation.

/// The directory `.graff` sits under. The cwd in production; tool_spill.zig's
/// sink carries the same seam for the same reason — a test must be able to
/// write a session subtree without touching the developer's working copy.
var g_workspace: ?Io.Dir = null;

pub fn setWorkspace(dir: ?Io.Dir) void {
    g_workspace = dir;
}

pub fn workspace() Io.Dir {
    return g_workspace orelse Io.Dir.cwd();
}

pub const Active = struct {
    backend: Backend,
    handle: Handle,
};

var g_active: ?Active = null;

pub fn attach(a: Active) void {
    g_active = a;
}

pub fn detach() void {
    g_active = null;
}

pub fn active() ?Active {
    return g_active;
}

// ── LocalProcess: the no-isolation backend ─────────────────────────────────
// Runs argv in this very process's world. It exists so the seam has a second
// implementation that is not Docker (a one-implementation interface proves
// nothing), and so dev/test paths can hold a Handle without a container
// runtime. It cannot capture state, and says so rather than pretending.

pub const LocalProcess = struct {
    io: Io,

    const handle_vtable: HandleVTable = .{
        .exec = localExec,
        .snapshot = localSnapshot,
        .release = localRelease,
    };
    const backend_vtable: BackendVTable = .{
        .name = "local",
        .available = localAvailable,
        .acquire = localAcquire,
        .acquireFromSnapshot = localAcquireFromSnapshot,
    };

    pub fn backend(self: *LocalProcess) Backend {
        return .{ .ctx = @ptrCast(self), .vt = &backend_vtable };
    }

    fn localAvailable(_: *anyopaque) bool {
        return true;
    }

    fn localAcquire(ctx: *anyopaque, gpa: Allocator, key: []const u8) Error!Handle {
        _ = gpa;
        return .{ .ctx = ctx, .vt = &handle_vtable, .key = key, .id = "local" };
    }

    fn localAcquireFromSnapshot(_: *anyopaque, _: Allocator, _: []const u8, _: Payload, _: Blob) Error!Handle {
        return error.SnapshotUnsupported;
    }

    fn localExec(ctx: *anyopaque, gpa: Allocator, argv: []const []const u8) Error!ExecResult {
        const self: *LocalProcess = @ptrCast(@alignCast(ctx));
        const run = process_runner.runCapped(gpa, self.io, argv, 64 * 1024, 64 * 1024, 120_000) catch
            return error.ExecFailed;
        return .{
            .exit_code = if (run.term == .exited) @intCast(run.term.exited) else -1,
            .stdout = run.stdout,
            .stderr = run.stderr,
        };
    }

    fn localSnapshot(_: *anyopaque, _: Allocator, _: Blob) Error!Payload {
        return error.SnapshotUnsupported;
    }

    fn localRelease(_: *anyopaque) void {}
};

const process_runner = @import("process_runner.zig");

test "snapshot paths are forward-slashed and rooted in the session subtree" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(".graff/sessions/wf/snapshots", try snapshotsDir(arena, "wf"));
    try std.testing.expectEqualStrings(".graff/sessions/wf/snapshots/a1", try snapshotDir(arena, "wf", "a1"));
    try std.testing.expectEqualStrings(".graff/sessions/wf/snapshots/a1/manifest.json", try manifestPath(arena, "wf", "a1"));
    try std.testing.expectEqualStrings(".graff/sessions/wf/snapshots/a1/payload.bin", try payloadPath(arena, "wf", "a1"));
}

test "a session or snapshot name can never escape the sessions dir" {
    try std.testing.expect(safeName("wf"));
    try std.testing.expect(!safeName(".."));
    try std.testing.expect(!safeName("a/b"));
    try std.testing.expect(!safeName(""));
}

test "a sandbox manifest round-trips through JSON" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const m: Manifest = .{
        .id = "17-abcd",
        .backend = "docker",
        .kind = "docker_image_tar",
        .ref = "graff-snap-17-abcd",
        .len = 4096,
        .created_ms = 17,
    };
    const back = parseManifest(arena, try renderManifest(arena, m)) orelse return error.ManifestUnparseable;
    try std.testing.expectEqualStrings(m.id, back.id);
    try std.testing.expectEqualStrings(m.ref, back.ref);
    try std.testing.expectEqual(m.len, back.len);
    try std.testing.expectEqual(Kind.docker_image_tar, back.payload().kind);
    try std.testing.expect(parseManifest(arena, "not json") == null);
    try std.testing.expect(parseManifest(arena, "{}") == null); // no id: not ours
}

test "LocalProcess acquires but refuses to snapshot" {
    var local: LocalProcess = .{ .io = std.testing.io };
    const backend = local.backend();
    try std.testing.expect(backend.available());
    try std.testing.expectEqualStrings("local", backend.name());
    const handle = try backend.acquire(std.testing.allocator, "k");
    try std.testing.expectEqualStrings("k", handle.key);
    const blob: Blob = .{ .io = std.testing.io, .dir = Io.Dir.cwd(), .rel = "payload.bin" };
    try std.testing.expectError(error.SnapshotUnsupported, handle.snapshot(std.testing.allocator, blob));
    try std.testing.expectError(error.SnapshotUnsupported, backend.acquireFromSnapshot(std.testing.allocator, "k", .{}, blob));
    handle.release();
}

test "snapshot GC keeps the newest N and deletes the rest" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    inline for (.{
        .{ .id = "old", .ms = 10, .len = 100 },
        .{ .id = "mid", .ms = 20, .len = 200 },
        .{ .id = "new", .ms = 30, .len = 300 },
    }) |row| {
        try tmp.dir.createDirPath(io, try snapshotDir(arena, "s", row.id));
        try tmp.dir.writeFile(io, .{ .sub_path = try payloadPath(arena, "s", row.id), .data = "x" });
        try writeManifest(io, tmp.dir, arena, "s", .{
            .id = row.id,
            .backend = "docker",
            .kind = "docker_image_tar",
            .ref = row.id,
            .len = row.len,
            .created_ms = row.ms,
        });
    }
    try std.testing.expectEqual(@as(usize, 3), (try list(io, tmp.dir, arena, "s")).len);

    const trimmed = try gc(io, tmp.dir, arena, "s", 1);
    try std.testing.expectEqual(@as(usize, 2), trimmed.removed);
    try std.testing.expectEqual(@as(usize, 1), trimmed.kept);
    try std.testing.expectEqual(@as(u64, 300), trimmed.bytes);
    const left = try list(io, tmp.dir, arena, "s");
    try std.testing.expectEqual(@as(usize, 1), left.len);
    try std.testing.expectEqualStrings("new", left[0].id);
    try std.testing.expect(find(io, tmp.dir, arena, "s", "old") == null);
    try std.testing.expect(remove(io, tmp.dir, arena, "s", "missing"));
    try std.testing.expect(!remove(io, tmp.dir, arena, "s", ".."));
}

test "the active sandbox is empty until something attaches one" {
    detach();
    try std.testing.expect(active() == null);
    var local: LocalProcess = .{ .io = std.testing.io };
    const backend = local.backend();
    attach(.{ .backend = backend, .handle = try backend.acquire(std.testing.allocator, "k") });
    try std.testing.expect(active() != null);
    try std.testing.expectEqualStrings("local", active().?.backend.name());
    detach();
    try std.testing.expect(active() == null);
}
