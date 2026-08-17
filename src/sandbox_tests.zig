//! #554: the Docker backend's orchestration, proven WITHOUT Docker.
//!
//! A shim directory holds an executable `docker` that appends its argv to
//! `docker.log` beside itself and emits canned bytes, and the backend is
//! pointed at that directory instead of the real PATH (`Docker.path_env`).
//! Every claim the backend makes about the CLI — that a snapshot is
//! commit + save + image rm, that a restore evicts the warm container BEFORE
//! it loads, that it runs the ref `docker load` reported, that the payload
//! reaches `docker load` on stdin — is then an assertion about that log rather
//! than something only a machine with a daemon could check.
//!
//! Reachability is wired in test_hooks.zig: an unreferenced module's tests
//! compile to nothing and the suite still reports green.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const Agent = @import("agent.zig").Agent;
const commands_sandbox = @import("commands_sandbox.zig");
const main_mod = @import("main.zig");
const sandbox = @import("sandbox.zig");
const sandbox_docker = @import("sandbox_docker.zig");

/// What the fake `docker save` writes. Short, but its exact bytes have to come
/// back out of payload.bin or the stdout redirect is not doing what it claims.
const canned_tar = "GRAFF-FAKE-IMAGE-TAR";
/// What the fake `docker load` reports it loaded. The restore must `run` THIS,
/// not the tag recorded in the manifest, when the daemon names one.
const loaded_ref = "graff-snap-restored";

const shim_script =
    \\#!/bin/sh
    \\dir=$(dirname "$0")
    \\printf '%s\n' "$*" >> "$dir/docker.log"
    \\case "$1" in
    \\  save) printf '%s' 'GRAFF-FAKE-IMAGE-TAR' ;;
    \\  load) printf 'loadbytes=%s\n' "$(wc -c | tr -d ' ')" >> "$dir/docker.log"
    \\        printf 'Loaded image: graff-snap-restored\n' ;;
    \\  run)  printf 'ctr0123456789\n' ;;
    \\  exec) printf 'ran in the sandbox\n' ;;
    \\esac
    \\exit 0
    \\
;

const Shim = struct {
    tmp: std.testing.TmpDir,
    /// Absolute path of the directory holding the fake `docker`.
    bin_dir: []const u8,
    buf: [4096]u8 = undefined,

    fn init(self: *Shim) !void {
        const io = std.testing.io;
        self.tmp = std.testing.tmpDir(.{ .iterate = true });
        try self.tmp.dir.createDirPath(io, "bin");
        try self.tmp.dir.writeFile(io, .{
            .sub_path = "bin/docker",
            .data = shim_script,
            .flags = .{ .permissions = .executable_file },
        });
        const abs = try self.tmp.dir.realPathFile(io, "bin/docker", &self.buf);
        self.bin_dir = std.fs.path.dirname(self.buf[0..abs]) orelse return error.NoShimDir;
    }

    fn deinit(self: *Shim) void {
        self.tmp.cleanup();
    }

    fn backend(self: *Shim, docker: *sandbox_docker.Docker) sandbox.Backend {
        docker.* = .{ .io = std.testing.io, .path_env = self.bin_dir };
        return docker.backend();
    }

    /// Everything the fake docker has been asked to do so far.
    fn log(self: *Shim, arena: Allocator) []const u8 {
        return self.tmp.dir.readFileAlloc(std.testing.io, "bin/docker.log", arena, .limited(64 * 1024)) catch "";
    }

    fn clearLog(self: *Shim) void {
        self.tmp.dir.deleteFile(std.testing.io, "bin/docker.log") catch {};
    }
};

/// Detach AND release: a rewind replaces the attached handle, so the sandbox
/// a test has to give back is whichever one is active when it ends.
fn releaseActive() void {
    if (sandbox.active()) |a| a.handle.release();
    sandbox.detach();
}

fn skipOnWindows() bool {
    return builtin.os.tag == .windows or builtin.os.tag == .wasi;
}

/// `needle` appears in `haystack`, and before `after` does.
fn orderedBefore(haystack: []const u8, first: []const u8, second: []const u8) bool {
    const a = std.mem.indexOf(u8, haystack, first) orelse return false;
    const b = std.mem.indexOf(u8, haystack, second) orelse return false;
    return a < b;
}

test "#554: a snapshot commits, streams the tar to payload.bin, and drops the scratch image" {
    if (skipOnWindows()) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var shim: Shim = undefined;
    try shim.init();
    defer shim.deinit();
    var docker: sandbox_docker.Docker = undefined;
    const backend = shim.backend(&docker);
    try std.testing.expect(backend.available());

    const handle = try backend.acquire(gpa, "lane");
    defer handle.release();
    // A fresh acquire evicts whatever was warm on this key BEFORE it starts one.
    try std.testing.expect(orderedBefore(shim.log(arena), "rm -f graff-sbx-lane", "run -d --name graff-sbx-lane"));

    const id = try sandbox.newId(arena, io);
    const rel = try sandbox.payloadPath(arena, "s", id);
    const payload = try handle.snapshot(gpa, .{ .io = io, .dir = shim.tmp.dir, .rel = rel });
    try sandbox.writeManifest(io, shim.tmp.dir, arena, "s", .{
        .id = id,
        .backend = backend.name(),
        .kind = payload.kind.tag(),
        .ref = payload.ref,
        .len = payload.len,
        .created_ms = 1700,
    });

    // The tar came out of the child's stdout and landed on disk untouched.
    const blob = try shim.tmp.dir.readFileAlloc(io, rel, arena, .limited(64 * 1024));
    try std.testing.expectEqualStrings(canned_tar, blob);
    try std.testing.expectEqual(@as(u64, canned_tar.len), payload.len);
    try std.testing.expect(std.mem.startsWith(u8, payload.ref, sandbox_docker.snapshot_prefix));

    const log = shim.log(arena);
    try std.testing.expect(std.mem.indexOf(u8, log, "commit -p graff-sbx-lane graff-snap-") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "save graff-snap-") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "image rm graff-snap-") != null);

    // The manifest is beside the payload and lists it.
    const listed = try sandbox.list(io, shim.tmp.dir, arena, "s");
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings(id, listed[0].id);
    try std.testing.expectEqualStrings("docker", listed[0].backend);
    try std.testing.expectEqualStrings(payload.ref, listed[0].ref);
    try std.testing.expectEqual(@as(u64, canned_tar.len), listed[0].len);
    try std.testing.expectEqual(sandbox.Kind.docker_image_tar, listed[0].payload().kind);
    _ = sandbox.find(io, shim.tmp.dir, arena, "s", id) orelse return error.SnapshotNotFound;
}

test "#554: a rewind evicts the warm container, feeds the payload to docker load, and runs the loaded ref" {
    if (skipOnWindows()) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var shim: Shim = undefined;
    try shim.init();
    defer shim.deinit();
    var docker: sandbox_docker.Docker = undefined;
    const backend = shim.backend(&docker);

    const rel = try sandbox.payloadPath(arena, "s", "snap1");
    try shim.tmp.dir.createDirPath(io, try sandbox.snapshotDir(arena, "s", "snap1"));
    try shim.tmp.dir.writeFile(io, .{ .sub_path = rel, .data = canned_tar });
    shim.clearLog();

    const handle = try backend.acquireFromSnapshot(gpa, "lane", .{
        .kind = .docker_image_tar,
        .len = canned_tar.len,
        .ref = "graff-snap-from-manifest",
    }, .{ .io = io, .dir = shim.tmp.dir, .rel = rel });
    defer handle.release();

    const log = shim.log(arena);
    // Eviction first: a restore that started before removing the warm
    // container would collide with the live one on its own key.
    try std.testing.expect(orderedBefore(log, "rm -f graff-sbx-lane", "load"));
    // The payload reached the child on STDIN, all of it.
    var byte_count: [32]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, log, std.fmt.bufPrint(&byte_count, "loadbytes={d}", .{canned_tar.len}) catch unreachable) != null);
    // And the container came up on the ref docker load REPORTED, not the one
    // the manifest happened to record.
    try std.testing.expect(std.mem.indexOf(u8, log, "run -d --name graff-sbx-lane " ++ loaded_ref ++ " sleep infinity") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "graff-snap-from-manifest") == null);
}

test "#554: exec runs inside the container and reports its output" {
    if (skipOnWindows()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var shim: Shim = undefined;
    try shim.init();
    defer shim.deinit();
    var docker: sandbox_docker.Docker = undefined;
    const backend = shim.backend(&docker);
    const handle = try backend.acquire(gpa, "lane");
    defer handle.release();

    const result = try handle.exec(gpa, &.{ "echo", "hi" });
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "ran in the sandbox") != null);
    try std.testing.expect(std.mem.indexOf(u8, shim.log(arena), "exec graff-sbx-lane echo hi") != null);
}

test "#554: no docker on PATH is an explanation, not a crash" {
    const gpa = std.testing.allocator;
    var docker: sandbox_docker.Docker = .{ .io = std.testing.io, .path_env = "" };
    const backend = docker.backend();
    try std.testing.expect(!backend.available());
    try std.testing.expectError(error.SandboxUnavailable, backend.acquire(gpa, "lane"));
    try std.testing.expectError(error.SandboxUnavailable, backend.acquireFromSnapshot(gpa, "lane", .{}, .{
        .io = std.testing.io,
        .dir = Io.Dir.cwd(),
        .rel = "nope/payload.bin",
    }));
}

// The REPL surface end to end: the command writes the manifest and payload
// itself, and its own listing then finds them.
test "#554: /snapshot captures through the command surface and /rewind restores it" {
    if (skipOnWindows()) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var shim: Shim = undefined;
    try shim.init();
    defer shim.deinit();
    var docker: sandbox_docker.Docker = undefined;
    const backend = shim.backend(&docker);

    sandbox.setWorkspace(shim.tmp.dir);
    defer sandbox.setWorkspace(null);
    sandbox.attach(.{ .backend = backend, .handle = try backend.acquire(gpa, "lane") });
    defer releaseActive();

    var root: Agent = undefined;
    root.io = io;
    root.gpa = gpa;
    root.session_name = "s";

    var aw: Io.Writer.Allocating = .init(arena);
    try std.testing.expect(try commands_sandbox.tryHandle(&root, arena, "/snapshot", &aw.writer));
    const captured = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, captured, "snapshot ") != null);
    try std.testing.expect(std.mem.indexOf(u8, captured, commands_sandbox.log_note) != null);

    const listed = try sandbox.list(io, shim.tmp.dir, arena, "s");
    try std.testing.expectEqual(@as(usize, 1), listed.len);

    var rewound: Io.Writer.Allocating = .init(arena);
    const line = try std.fmt.allocPrint(arena, "/rewind {s}", .{listed[0].id});
    try std.testing.expect(try commands_sandbox.tryHandle(&root, arena, line, &rewound.writer));
    const text = rewound.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "sandbox rewound to") != null);
    // The one thing a rewind must never let a user believe.
    try std.testing.expect(std.mem.indexOf(u8, text, commands_sandbox.log_note) != null);
    // The restored container must still be the LAST thing standing: releasing
    // the old handle after the restore would have evicted the very container
    // the restore had just brought up, since both sit on the same key.
    const log = shim.log(arena);
    const ran = std.mem.indexOf(u8, log, "run -d --name graff-sbx-lane " ++ loaded_ref) orelse return error.RestoredContainerNeverStarted;
    try std.testing.expect((std.mem.lastIndexOf(u8, log, "rm -f graff-sbx-lane") orelse 0) < ran);
}

test "#554: /rewind with a prompt number is left to the conversation rewind" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: Agent = undefined;
    root.io = std.testing.io;
    root.gpa = gpa;
    root.session_name = "s";
    var aw: Io.Writer.Allocating = .init(arena);
    try std.testing.expect(!try commands_sandbox.tryHandle(&root, arena, "/rewind", &aw.writer));
    try std.testing.expect(!try commands_sandbox.tryHandle(&root, arena, "/rewind 3", &aw.writer));
    try std.testing.expectEqual(@as(usize, 0), aw.writer.buffered().len);
}

test "#554: /snapshot with nothing attached explains itself instead of failing" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    sandbox.setWorkspace(tmp.dir);
    defer sandbox.setWorkspace(null);
    sandbox.detach();

    var root: Agent = undefined;
    root.io = io;
    root.gpa = gpa;
    root.session_name = "s";
    var aw: Io.Writer.Allocating = .init(arena);
    try std.testing.expect(try commands_sandbox.tryHandle(&root, arena, "/snapshot", &aw.writer));
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "no sandbox is active") != null);

    var missing: Io.Writer.Allocating = .init(arena);
    try std.testing.expect(try commands_sandbox.tryHandle(&root, arena, "/rewind not-a-real-snapshot", &missing.writer));
    try std.testing.expect(std.mem.indexOf(u8, missing.writer.buffered(), "no snapshot not-a-real-snapshot") != null);
}

test "#554: the local backend refuses to snapshot through the command surface" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    sandbox.setWorkspace(tmp.dir);
    defer sandbox.setWorkspace(null);

    var local: sandbox.LocalProcess = .{ .io = io };
    const backend = local.backend();
    sandbox.attach(.{ .backend = backend, .handle = try backend.acquire(gpa, "lane") });
    defer releaseActive();

    var root: Agent = undefined;
    root.io = io;
    root.gpa = gpa;
    root.session_name = "s";
    var aw: Io.Writer.Allocating = .init(arena);
    try std.testing.expect(try commands_sandbox.tryHandle(&root, arena, "/snapshot", &aw.writer));
    const text = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "snapshot failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cannot capture state") != null);
}

test "#554: /snapshot attach drives the seam by hand, and detach gives the sandbox back" {
    if (skipOnWindows()) return error.SkipZigTest;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var shim: Shim = undefined;
    try shim.init();
    defer shim.deinit();
    sandbox.setWorkspace(shim.tmp.dir);
    defer sandbox.setWorkspace(null);
    defer releaseActive();
    const saved_path = main_mod.g_path_env;
    defer main_mod.g_path_env = saved_path;
    main_mod.g_path_env = shim.bin_dir;

    var root: Agent = undefined;
    root.io = io;
    root.gpa = gpa;
    root.session_name = "s";

    var attached: Io.Writer.Allocating = .init(arena);
    try std.testing.expect(try commands_sandbox.tryHandle(&root, arena, "/snapshot attach busybox:latest", &attached.writer));
    try std.testing.expect(std.mem.indexOf(u8, attached.writer.buffered(), "sandbox attached") != null);
    // The session name IS the lane, and the requested image is what came up.
    try std.testing.expect(std.mem.indexOf(u8, shim.log(arena), "run -d --name graff-sbx-s busybox:latest sleep infinity") != null);

    var captured: Io.Writer.Allocating = .init(arena);
    try std.testing.expect(try commands_sandbox.tryHandle(&root, arena, "/snapshot", &captured.writer));
    try std.testing.expect(std.mem.indexOf(u8, captured.writer.buffered(), "snapshot ") != null);

    var released: Io.Writer.Allocating = .init(arena);
    try std.testing.expect(try commands_sandbox.tryHandle(&root, arena, "/snapshot detach", &released.writer));
    try std.testing.expect(std.mem.indexOf(u8, released.writer.buffered(), "sandbox released") != null);
    try std.testing.expect(sandbox.active() == null);
    // The capture outlives the sandbox: that is the whole point of persisting it.
    try std.testing.expectEqual(@as(usize, 1), (try sandbox.list(io, shim.tmp.dir, arena, "s")).len);
}

test "#554: /snapshot attach with no docker installed explains instead of failing" {
    const gpa = std.testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    sandbox.detach();
    const saved_path = main_mod.g_path_env;
    defer main_mod.g_path_env = saved_path;
    main_mod.g_path_env = "";

    var root: Agent = undefined;
    root.io = std.testing.io;
    root.gpa = gpa;
    root.session_name = "s";
    var aw: Io.Writer.Allocating = .init(arena);
    try std.testing.expect(try commands_sandbox.tryHandle(&root, arena, "/snapshot attach", &aw.writer));
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "docker backend:") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "not on PATH") != null);
    try std.testing.expect(sandbox.active() == null);

    var gone: Io.Writer.Allocating = .init(arena);
    try std.testing.expect(try commands_sandbox.tryHandle(&root, arena, "/snapshot detach", &gone.writer));
    try std.testing.expect(std.mem.indexOf(u8, gone.writer.buffered(), "no sandbox is attached") != null);
}
