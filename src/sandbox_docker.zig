//! #554's first sandbox backend: Docker, driven purely through the `docker`
//! CLI as child processes. No SDK, no daemon socket of our own — the same wire
//! an AppleContainer backend would use with a different binary name, which is
//! the point of keeping it CLI-shaped.
//!
//! The four verbs:
//!   acquire              docker rm -f graff-sbx-<key>   (evict the warm one)
//!                        docker run -d --name graff-sbx-<key> <image>
//!   snapshot             docker commit -p <ctr> graff-snap-<uuid>
//!                        docker save graff-snap-<uuid>  -> payload.bin
//!                        docker image rm graff-snap-<uuid>
//!   acquireFromSnapshot  docker rm -f graff-sbx-<key>   (evict FIRST)
//!                        docker load  <- payload.bin
//!                        docker run -d --name graff-sbx-<key> <loaded ref>
//!   exec                 docker exec <ctr> <argv...>
//!
//! `docker save` writes to the payload FILE HANDLE and `docker load` reads from
//! it, so an image tar of any size moves between disk and the daemon without a
//! byte of it living in this process (sandbox.zig's header says why).
//!
//! The binary is resolved against a PATH string rather than left to the
//! spawner: `std.process.spawn` documents that argv[0] resolution always uses
//! the PARENT environment, so an injected PATH would be ignored, and resolving
//! first is also how "docker is not installed" becomes an explanation instead
//! of a spawn error.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const sandbox = @import("sandbox.zig");
const Error = sandbox.Error;

pub const container_prefix = "graff-sbx-";
pub const snapshot_prefix = "graff-snap-";
/// What a fresh sandbox boots from when nothing else is configured. Small,
/// present on most machines, and it has a shell for `exec`.
pub const default_image = "alpine:latest";
/// The command a sandbox container runs so it stays up for `docker exec`.
pub const idle_argv = [_][]const u8{ "sleep", "infinity" };

const output_cap = 64 * 1024;

pub const Docker = struct {
    io: Io,
    /// PATH to resolve `docker` against: `main.g_path_env` in production, a
    /// shim directory in tests.
    path_env: []const u8,
    /// Image a fresh (non-restored) sandbox starts from.
    image: []const u8 = default_image,
    /// Binary name to resolve. `container` would make this an AppleContainer
    /// backend; the wire below is unchanged.
    bin_name: []const u8 = "docker",

    const backend_vtable: sandbox.BackendVTable = .{
        .name = "docker",
        .available = availableImpl,
        .acquire = acquireImpl,
        .acquireFromSnapshot = acquireFromSnapshotImpl,
    };

    const handle_vtable: sandbox.HandleVTable = .{
        .exec = execImpl,
        .snapshot = snapshotImpl,
        .release = releaseImpl,
    };

    pub fn backend(self: *Docker) sandbox.Backend {
        return .{ .ctx = @ptrCast(self), .vt = &backend_vtable };
    }

    /// One live sandbox. Allocated per `acquire` and freed by `release`, so two
    /// keys held at once cannot alias each other's container name or tag.
    pub const Sandbox = struct {
        docker: *Docker,
        gpa: Allocator,
        bin: []const u8,
        /// `graff-sbx-<key>`, which IS the eviction identity: eviction is
        /// `docker rm -f` on this name, so it works across process restarts
        /// without any in-memory bookkeeping to go stale.
        container: []const u8,
        /// The most recent `docker commit` tag. Owned here so a returned
        /// `Payload.ref` stays valid until the next snapshot on this sandbox.
        tag: []const u8 = "",

        fn free(self: *Sandbox) void {
            const gpa = self.gpa;
            gpa.free(self.bin);
            gpa.free(self.container);
            if (self.tag.len > 0) gpa.free(self.tag);
            gpa.destroy(self);
        }
    };

    fn availableImpl(ctx: *anyopaque) bool {
        const self: *Docker = @ptrCast(@alignCast(ctx));
        var buf: [4096]u8 = undefined;
        return resolveInto(self.io, self.path_env, self.bin_name, &buf) != null;
    }

    fn acquireImpl(ctx: *anyopaque, gpa: Allocator, key: []const u8) Error!sandbox.Handle {
        const self: *Docker = @ptrCast(@alignCast(ctx));
        const box = try self.open(gpa, key);
        errdefer box.free();
        try self.start(box, self.image);
        return .{ .ctx = @ptrCast(box), .vt = &handle_vtable, .key = box.container[container_prefix.len..], .id = box.container };
    }

    fn acquireFromSnapshotImpl(
        ctx: *anyopaque,
        gpa: Allocator,
        key: []const u8,
        payload: sandbox.Payload,
        blob: sandbox.Blob,
    ) Error!sandbox.Handle {
        const self: *Docker = @ptrCast(@alignCast(ctx));
        if (payload.kind != .docker_image_tar) return error.RestoreFailed;
        const box = try self.open(gpa, key); // evicts the warm container FIRST
        errdefer box.free();
        const file = blob.dir.openFile(blob.io, blob.rel, .{}) catch return error.RestoreFailed;
        defer file.close(blob.io);
        const loaded = run(gpa, self.io, &.{ box.bin, "load" }, .{ .stdin_file = file }) catch return error.RestoreFailed;
        defer loaded.deinit(gpa);
        if (!loaded.ok()) return error.RestoreFailed;
        const ref = loadedRef(loaded.stdout) orelse payload.ref;
        if (ref.len == 0) return error.RestoreFailed;
        self.start(box, ref) catch return error.RestoreFailed;
        return .{ .ctx = @ptrCast(box), .vt = &handle_vtable, .key = box.container[container_prefix.len..], .id = box.container };
    }

    /// Resolve the binary, name the container, and evict whatever is warm on
    /// that name. Shared by both acquire paths: a restore that skipped the
    /// eviction would collide with the live container on its own key.
    fn open(self: *Docker, gpa: Allocator, key: []const u8) Error!*Sandbox {
        var buf: [4096]u8 = undefined;
        const resolved = resolveInto(self.io, self.path_env, self.bin_name, &buf) orelse return error.SandboxUnavailable;
        const box = try gpa.create(Sandbox);
        errdefer gpa.destroy(box);
        const bin = try gpa.dupe(u8, resolved);
        errdefer gpa.free(bin);
        box.* = .{
            .docker = self,
            .gpa = gpa,
            .bin = bin,
            .container = try containerName(gpa, key),
        };
        evict(gpa, self.io, box.bin, box.container);
        return box;
    }

    fn start(self: *Docker, box: *Sandbox, image: []const u8) Error!void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(box.gpa);
        try argv.appendSlice(box.gpa, &.{ box.bin, "run", "-d", "--name", box.container, image });
        try argv.appendSlice(box.gpa, &idle_argv);
        const started = run(box.gpa, self.io, argv.items, .{}) catch return error.SandboxUnavailable;
        defer started.deinit(box.gpa);
        if (!started.ok()) return error.SandboxUnavailable;
    }

    fn execImpl(ctx: *anyopaque, gpa: Allocator, argv: []const []const u8) Error!sandbox.ExecResult {
        const box: *Sandbox = @ptrCast(@alignCast(ctx));
        var full: std.ArrayList([]const u8) = .empty;
        defer full.deinit(gpa);
        try full.appendSlice(gpa, &.{ box.bin, "exec", box.container });
        try full.appendSlice(gpa, argv);
        const done = run(gpa, box.docker.io, full.items, .{}) catch return error.ExecFailed;
        return .{
            .exit_code = if (done.term == .exited) @intCast(done.term.exited) else -1,
            .stdout = done.stdout,
            .stderr = done.stderr,
        };
    }

    fn snapshotImpl(ctx: *anyopaque, gpa: Allocator, blob: sandbox.Blob) Error!sandbox.Payload {
        const box: *Sandbox = @ptrCast(@alignCast(ctx));
        const io = box.docker.io;
        const tag = try snapshotTag(gpa, io);
        errdefer gpa.free(tag);

        // `tag` is freed by the errdefer on every failure below and adopted by
        // `box.tag` on success — never both, so no branch frees it by hand.
        const committed = run(gpa, io, &.{ box.bin, "commit", "-p", box.container, tag }, .{}) catch return error.SnapshotFailed;
        defer committed.deinit(gpa);
        if (!committed.ok()) return error.SnapshotFailed;

        // The tar goes straight from the daemon into payload.bin: the child's
        // stdout IS the file, so nothing is buffered here at any size.
        ensureBlobDir(blob);
        const file = blob.dir.createFile(blob.io, blob.rel, .{}) catch {
            removeImage(gpa, io, box.bin, tag);
            return error.SnapshotFailed;
        };
        const saved = run(gpa, io, &.{ box.bin, "save", tag }, .{ .stdout_file = file }) catch {
            file.close(blob.io);
            removeImage(gpa, io, box.bin, tag);
            return error.SnapshotFailed;
        };
        defer saved.deinit(gpa);
        file.close(blob.io);
        removeImage(gpa, io, box.bin, tag); // the blob is the artifact; the image was scaffolding
        if (!saved.ok()) return error.SnapshotFailed;
        // Sized by PATH, not by the write handle: `stat` on a write-only handle
        // is ACCESS_DENIED on Windows and only there (#462), and a size read
        // that silently returns 0 on one platform is worse than no size at all.
        const size: u64 = if (blob.dir.statFile(blob.io, blob.rel, .{})) |st| st.size else |_| 0;

        if (box.tag.len > 0) gpa.free(box.tag);
        box.tag = tag;
        return .{ .kind = .docker_image_tar, .len = size, .ref = box.tag };
    }

    fn releaseImpl(ctx: *anyopaque) void {
        const box: *Sandbox = @ptrCast(@alignCast(ctx));
        evict(box.gpa, box.docker.io, box.bin, box.container);
        box.free();
    }
};

fn ensureBlobDir(blob: sandbox.Blob) void {
    // `.graff/` paths are forward-slashed on every platform by invariant
    // (session_index.zig), so the POSIX dirname is the right one everywhere.
    const parent = std.fs.path.dirnamePosix(blob.rel) orelse return;
    blob.dir.createDirPath(blob.io, parent) catch {};
}

fn evict(gpa: Allocator, io: Io, bin: []const u8, container: []const u8) void {
    const removed = run(gpa, io, &.{ bin, "rm", "-f", container }, .{}) catch return;
    removed.deinit(gpa);
}

fn removeImage(gpa: Allocator, io: Io, bin: []const u8, tag: []const u8) void {
    const removed = run(gpa, io, &.{ bin, "image", "rm", tag }, .{}) catch return;
    removed.deinit(gpa);
}

/// `graff-sbx-<key>`, with the key reduced to what Docker accepts in a name
/// ([A-Za-z0-9_.-]). A key is a lane label, not a path, so folding the rest to
/// '-' cannot collide two lanes a user would think of as distinct.
pub fn containerName(gpa: Allocator, key: []const u8) Allocator.Error![]const u8 {
    const use = if (key.len == 0) "default" else key;
    const out = try gpa.alloc(u8, container_prefix.len + @min(use.len, 100));
    @memcpy(out[0..container_prefix.len], container_prefix);
    for (out[container_prefix.len..], use[0 .. out.len - container_prefix.len]) |*slot, c| {
        slot.* = if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-') c else '-';
    }
    return out;
}

pub fn snapshotTag(gpa: Allocator, io: Io) Allocator.Error![]const u8 {
    var raw: [8]u8 = undefined;
    io.random(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    return std.fmt.allocPrint(gpa, snapshot_prefix ++ "{s}", .{&hex});
}

/// The image reference `docker load` reports, or null when its output does not
/// name one (older daemons, an unexpected format). The caller falls back to the
/// ref the manifest recorded, so a parse miss is never fatal.
pub fn loadedRef(stdout: []const u8) ?[]const u8 {
    inline for (.{ "Loaded image: ", "Loaded image ID: " }) |needle| {
        if (std.mem.indexOf(u8, stdout, needle)) |at| {
            const rest = stdout[at + needle.len ..];
            const end = std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len;
            const ref = std.mem.trim(u8, rest[0..end], " \t");
            if (ref.len > 0) return ref;
        }
    }
    return null;
}

/// First `name` on `path_env` that exists, written into `buf`. Null when the
/// binary is not installed — the "docker is absent" answer, decided before any
/// process is spawned.
pub fn resolveInto(io: Io, path_env: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch continue;
        Io.Dir.cwd().access(io, full, .{}) catch continue;
        return full;
    }
    return null;
}

// ── Child-process plumbing ─────────────────────────────────────────────────

pub const Run = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    pub fn ok(self: Run) bool {
        return self.term == .exited and self.term.exited == 0;
    }

    pub fn deinit(self: Run, gpa: Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

/// Which end of the child is a file rather than a pipe. Exactly one of these
/// is ever set: `save` streams stdout out to the payload, `load` streams the
/// payload in on stdin.
pub const Redirect = struct {
    stdin_file: ?Io.File = null,
    stdout_file: ?Io.File = null,
};

fn run(gpa: Allocator, io: Io, argv: []const []const u8, redirect: Redirect) Error!Run {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = if (redirect.stdin_file) |f| .{ .file = f } else .ignore,
        .stdout = if (redirect.stdout_file) |f| .{ .file = f } else .pipe,
        .stderr = .pipe,
    }) catch return error.SandboxUnavailable;
    // `kill` is documented as a no-op once `wait` has returned, so this covers
    // the error paths without a flag and costs nothing on the success path.
    defer child.kill(io);
    if (child.stdout) |out| {
        const both = try collect(2, gpa, io, .{ out, child.stderr.? });
        const term = child.wait(io) catch return error.ExecFailed;
        return .{ .term = term, .stdout = both[0], .stderr = both[1] };
    }
    const only = try collect(1, gpa, io, .{child.stderr.?});
    const term = child.wait(io) catch return error.ExecFailed;
    return .{ .term = term, .stdout = try gpa.alloc(u8, 0), .stderr = only[0] };
}

/// Drain every pipe the child has CONCURRENTLY. Reading one to the end first
/// would deadlock the moment the other filled its pipe buffer, which for
/// `docker save` is a certainty rather than a corner case. Each stream keeps
/// its first `output_cap` bytes and discards the rest.
fn collect(comptime n: usize, gpa: Allocator, io: Io, files: [n]Io.File) Error![n][]u8 {
    var storage: Io.File.MultiReader.Buffer(n) = undefined;
    var mr: Io.File.MultiReader = undefined;
    mr.init(gpa, io, storage.toStreams(), &files);
    defer mr.deinit();
    var saved: [n]?[]u8 = @splat(null);
    errdefer for (saved) |item| if (item) |bytes| gpa.free(bytes);
    while (true) {
        mr.fill(64, .none) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return error.ExecFailed,
        };
        for (0..n) |i| {
            const reader = mr.reader(i);
            const buffered = reader.buffered();
            if (saved[i] == null and buffered.len > output_cap) saved[i] = try gpa.dupe(u8, buffered[0..output_cap]);
            if (saved[i] != null) reader.toss(buffered.len);
        }
    }
    var out: [n][]u8 = undefined;
    var made: usize = 0;
    errdefer for (out[0..made]) |bytes| gpa.free(bytes);
    while (made < n) : (made += 1) {
        out[made] = if (saved[made]) |bytes| bytes else try gpa.dupe(u8, mr.reader(made).buffered());
        saved[made] = null;
    }
    return out;
}

test "a container name is the eviction identity and is Docker-legal" {
    const gpa = std.testing.allocator;
    const plain = try containerName(gpa, "lane1");
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("graff-sbx-lane1", plain);
    const dirty = try containerName(gpa, "a/b c");
    defer gpa.free(dirty);
    try std.testing.expectEqualStrings("graff-sbx-a-b-c", dirty);
    const empty = try containerName(gpa, "");
    defer gpa.free(empty);
    try std.testing.expectEqualStrings("graff-sbx-default", empty);
}

test "the loaded image ref is read back out of docker load's output" {
    try std.testing.expectEqualStrings("graff-snap-ab12", loadedRef("Loaded image: graff-snap-ab12\n").?);
    try std.testing.expectEqualStrings("sha256:beef", loadedRef("Loaded image ID: sha256:beef\n").?);
    try std.testing.expect(loadedRef("nothing here\n") == null);
}

test "a snapshot tag is prefixed and unique" {
    const gpa = std.testing.allocator;
    const a = try snapshotTag(gpa, std.testing.io);
    defer gpa.free(a);
    const b = try snapshotTag(gpa, std.testing.io);
    defer gpa.free(b);
    try std.testing.expect(std.mem.startsWith(u8, a, snapshot_prefix));
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "a missing docker resolves to nothing rather than spawning" {
    var buf: [4096]u8 = undefined;
    try std.testing.expect(resolveInto(std.testing.io, "", "docker", &buf) == null);
    try std.testing.expect(resolveInto(std.testing.io, "/nonexistent-graff-path", "docker", &buf) == null);
}
