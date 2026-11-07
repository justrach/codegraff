//! Private, verbatim pre-compaction history. No summaries and no network IO.
//! A checkpoint only reverses an exact prefix replacement; changed windows
//! fail closed. Root recovery owns transport/meter resets after installation.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Value = std.json.Value;
const Agent = @import("agent.zig").Agent;
const Allocator = std.mem.Allocator;
const windows = @import("compaction_window.zig");

pub const max_checkpoint_bytes = 64 * 1024 * 1024;
const private_file: Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
const private_dir: Io.File.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
const Payload = struct { before: []const Value, window: []const Value };
const Snapshot = struct {
    version: u32,
    blob_sha256: []const u8,
    history_sha256: []const u8,
    before: []const Value,
    window: []const Value,
};

pub fn safeSessionName(name: []const u8) bool {
    if (name.len == 0 or name.len > 160 or name[0] == '.') return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    return true;
}

fn hash(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn valueHash(a: Allocator, value: anytype) ![64]u8 {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    defer a.free(bytes);
    return hash(bytes);
}

fn openChild(io: Io, parent: Io.Dir, name: []const u8, create: bool) !Io.Dir {
    if (create) {
        parent.createDir(io, name, private_dir) catch |err| if (err != error.PathAlreadyExists) return err;
        try syncDirectory(io, parent);
    }
    // Walk one component at a time, never following a symlink, so even an
    // existing .graff/sessions tree cannot redirect a checkpoint outside cwd.
    return parent.openDir(io, name, .{ .follow_symlinks = false });
}

fn directory(io: Io, session: []const u8, create: bool) !Io.Dir {
    const graff = try openChild(io, .cwd(), ".graff", create);
    defer graff.close(io);
    const sessions = try openChild(io, graff, "sessions", create);
    defer sessions.close(io);
    const session_dir = try openChild(io, sessions, session, create);
    defer session_dir.close(io);
    return openChild(io, session_dir, "compaction", create);
}

/// Move ONLY the checkpoint subtree when the root session acquires its AI
/// title. No history/name mutation here. Existing destinations are never
/// replaced, even when empty or created concurrently. Fork/save-as needs a
/// separate copy policy: moving these checkpoints would strand the source.
pub fn rename(self: *Agent, old_name: []const u8, new_name: []const u8) !void {
    if (self.sub or old_name.len == 0) return;
    if (!safeSessionName(old_name) or !safeSessionName(new_name)) return error.UnsafeCheckpointSession;
    if (std.mem.eql(u8, old_name, new_name)) return;
    const graff = openChild(self.io, .cwd(), ".graff", false) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer graff.close(self.io);
    const sessions = openChild(self.io, graff, "sessions", false) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer sessions.close(self.io);
    const old_dir = openChild(self.io, sessions, old_name, false) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer old_dir.close(self.io);
    const source = openChild(self.io, old_dir, "compaction", false) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer source.close(self.io);
    const new_dir = try openChild(self.io, sessions, new_name, true);
    defer new_dir.close(self.io);
    try old_dir.renamePreserve("compaction", new_dir, "compaction", self.io);
    // If durability fails, retain the old name's mapping when rollback is
    // possible. Never overwrite a concurrently installed mapping on rollback.
    errdefer new_dir.renamePreserve("compaction", old_dir, "compaction", self.io) catch {};
    try syncDirectory(self.io, new_dir);
    try syncDirectory(self.io, old_dir);
}

fn readBounded(io: Io, dir: Io.Dir, a: Allocator, name: []const u8) ![]u8 {
    const file = try dir.openFile(io, name, .{ .follow_symlinks = false, .resolve_beneath = true });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > max_checkpoint_bytes) return error.InvalidCheckpointFile;
    if (builtin.os.tag != .windows and (stat.permissions.toMode() & 0o077) != 0) return error.InsecureCheckpointFile;
    const bytes = try a.alloc(u8, @intCast(stat.size));
    errdefer a.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.TruncatedCheckpoint;
    const after = try file.stat(io);
    if (after.kind != .file or after.size != stat.size) return error.CheckpointChanged;
    return bytes;
}

fn syncDirectory(io: Io, dir: Io.Dir) !void {
    if (builtin.os.tag == .windows) return;
    const file = try dir.openFile(io, ".", .{ .allow_directory = true, .follow_symlinks = false, .resolve_beneath = true });
    defer file.close(io);
    try file.sync(io);
}

fn filename(buf: []u8, digest: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}.json", .{digest});
}

fn containsBlob(a: Allocator, items: []const Value, digest: []const u8) !bool {
    for (items) |item| {
        if (windows.latestBlob(&.{item}) == null) continue;
        const existing = try valueHash(a, item);
        if (std.mem.eql(u8, &existing, digest)) return true;
    }
    return false;
}

/// Call BEFORE replacing history. A duplicate blob is not sufficient evidence
/// of identical ancestry: the complete immutable payload must also agree.
/// Non-durable test/auxiliary agents and subagents have no root-session mapping.
pub fn preserve(self: *Agent, before: []const Value, window: []const Value) !void {
    if (self.sub or self.session_name.len == 0) return;
    if (!safeSessionName(self.session_name)) return error.UnsafeCheckpointSession;
    const k = windows.latestBlob(window) orelse return error.MissingCompactionItem;
    const digest = try valueHash(self.gpa, window[k]);
    if (try containsBlob(self.gpa, before, &digest)) return error.NonExpandingCheckpoint;
    const history_digest = try valueHash(self.gpa, Payload{ .before = before, .window = window });
    const bytes = try std.json.Stringify.valueAlloc(self.gpa, Snapshot{
        .version = 1,
        .blob_sha256 = &digest,
        .history_sha256 = &history_digest,
        .before = before,
        .window = window,
    }, .{});
    defer self.gpa.free(bytes);
    if (bytes.len > max_checkpoint_bytes) return error.CheckpointTooLarge;
    const dir = try directory(self.io, self.session_name, true);
    defer dir.close(self.io);
    var name_buf: [69]u8 = undefined;
    const name = try filename(&name_buf, &digest);
    var atomic = try dir.createFileAtomic(self.io, name, .{ .permissions = private_file, .replace = false });
    defer atomic.deinit(self.io);
    try atomic.file.writeStreamingAll(self.io, bytes);
    try atomic.file.sync(self.io);
    atomic.link(self.io) catch |err| switch (err) {
        error.PathAlreadyExists => {
            const existing = try readBounded(self.io, dir, self.gpa, name);
            defer self.gpa.free(existing);
            if (!std.mem.eql(u8, existing, bytes)) return error.ImmutableCheckpointConflict;
        },
        else => return err,
    };
    try syncDirectory(self.io, dir);
}

fn sameValues(a: Allocator, lhs: []const Value, rhs: []const Value) !bool {
    const left = try std.json.Stringify.valueAlloc(a, lhs, .{});
    defer a.free(left);
    const right = try std.json.Stringify.valueAlloc(a, rhs, .{});
    defer a.free(right);
    return std.mem.eql(u8, left, right);
}

/// Expands exactly the newest opaque item, preserving its entire later tail.
/// Missing, unsafe, corrupt or changed checkpoints never change live history.
/// Allocation failures propagate; callers may bound repeated ancestor restores.
/// Only messages/provenance change here; the root recovery coordinator must
/// closeCodexWs and reset meters, goal fingerprint and history_rewrites.
pub fn restore(self: *Agent) !bool {
    if (self.sub or self.session_name.len == 0 or !safeSessionName(self.session_name)) return false;
    const latest = windows.latestBlob(self.messages.items) orelse return false;
    const digest = try valueHash(self.gpa, self.messages.items[latest]);
    const dir = directory(self.io, self.session_name, false) catch return false;
    defer dir.close(self.io);
    var name_buf: [69]u8 = undefined;
    const name = try filename(&name_buf, &digest);
    const bytes = readBounded(self.io, dir, self.gpa, name) catch |err| {
        if (err == error.OutOfMemory) return err;
        return false;
    };
    defer self.gpa.free(bytes);
    var parsed = std.json.parseFromSlice(Snapshot, self.gpa, bytes, .{ .allocate = .alloc_always }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return false;
    };
    defer parsed.deinit();
    const saved = parsed.value;
    if (saved.version != 1 or !std.mem.eql(u8, saved.blob_sha256, &digest)) return false;
    const blob = windows.latestBlob(saved.window) orelse return false;
    const saved_digest = try valueHash(self.gpa, saved.window[blob]);
    if (!std.mem.eql(u8, &saved_digest, &digest)) return false;
    const history_digest = try valueHash(self.gpa, Payload{ .before = saved.before, .window = saved.window });
    if (!std.mem.eql(u8, saved.history_sha256, &history_digest)) return false;
    if (try containsBlob(self.gpa, saved.before, &digest)) return false;
    // Canonical windows may retain items on BOTH sides of the blob. Match
    // the whole prefix, not merely the blob, and never guess about prepends.
    if (latest != blob or saved.window.len > self.messages.items.len) return false;
    if (!try sameValues(self.gpa, saved.window, self.messages.items[0..saved.window.len])) return false;

    // Stage every fallible allocation before installing. Parsed values belong
    // to the temporary parser arena; transfer via an owned session-arena copy.
    var staged = std.json.Array.init(self.gpa);
    defer staged.deinit();
    try staged.appendSlice(saved.before);
    try staged.appendSlice(self.messages.items[saved.window.len..]);
    const encoded = try std.json.Stringify.valueAlloc(self.gpa, staged.items, .{});
    defer self.gpa.free(encoded);
    const fresh = try std.json.parseFromSliceLeaky(Value, self.arena, encoded, .{ .allocate = .alloc_always });
    self.messages = fresh.array;
    self.compaction_window = .{};
    return true;
}
