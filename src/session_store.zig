//! In-place canonical JSON saves with a checksummed write-ahead journal.
//! Retained history is neither read nor rewritten on the incremental path.
//! Synced files and directory entries order recovery for process crashes;
//! power-loss guarantees still depend on the filesystem/device (and Windows
//! cannot portably sync directory handles). The snapshot inode is never swapped.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Sha = std.crypto.hash.sha2.Sha256;
const lock = @import("session_lock.zig");

pub const Mark = struct { inode: Io.File.INode, size: u64, mtime_ns: i96 };
pub const Delta = struct { old_parts: []const []const u8, old_mark: Mark, prefix: usize, tail: usize };
pub const Stats = struct { bytes_written: u64 = 0, journal_bytes: u64 = 0, full_writes: u64 = 0, delta_writes: u64 = 0 };
/// Snapshot bytes only, excluding journal I/O. Each writer thread owns its counters.
pub threadlocal var stats: Stats = .{};

pub fn observe(io: Io, dir: Io.Dir, path: []const u8) !Mark {
    return markOf(try dir.statFile(io, path, .{}));
}
fn markOf(st: Io.File.Stat) Mark {
    return .{ .inode = st.inode, .size = st.size, .mtime_ns = st.mtime.nanoseconds };
}
pub fn matches(a: Mark, b: Mark) bool {
    return a.inode == b.inode and a.size == b.size and a.mtime_ns == b.mtime_ns;
}

const header_len = 120;
const magic = "GRAFFSJ1";
// Fixed header + length-framed binary ranges + SHA-256 of all preceding bytes.
// No JSON/base64 expansion, recursive parser, or allocation driven by payloads.
const max_size: u64 = 256 * 1024 * 1024;
const Header = struct {
    inode: Io.File.INode,
    old_size: u64,
    new_size: u64,
    prefix: u64,
    tail: u64,
    before: [32]u8,
    after: [32]u8,

    fn oldTail(self: Header) u64 {
        return header_len + self.prefix;
    }
    fn newPrefix(self: Header) u64 {
        return self.oldTail() + self.old_size - self.tail;
    }
    fn newTail(self: Header) u64 {
        return self.newPrefix() + self.prefix;
    }
    fn end(self: Header) u64 {
        return self.newTail() + self.new_size - self.tail;
    }
    fn encode(self: Header) [header_len]u8 {
        var b: [header_len]u8 = undefined;
        @memcpy(b[0..8], magic);
        std.mem.writeInt(u128, b[8..24], @intCast(self.inode), .little);
        std.mem.writeInt(u64, b[24..32], self.old_size, .little);
        std.mem.writeInt(u64, b[32..40], self.new_size, .little);
        std.mem.writeInt(u64, b[40..48], self.prefix, .little);
        std.mem.writeInt(u64, b[48..56], self.tail, .little);
        @memcpy(b[56..88], &self.before);
        @memcpy(b[88..120], &self.after);
        return b;
    }
    fn decode(b: *const [header_len]u8) !Header {
        if (!std.mem.eql(u8, b[0..8], magic)) return error.BadSessionJournal;
        const h: Header = .{
            .inode = std.math.cast(Io.File.INode, std.mem.readInt(u128, b[8..24], .little)) orelse return error.BadSessionJournal,
            .old_size = std.mem.readInt(u64, b[24..32], .little),
            .new_size = std.mem.readInt(u64, b[32..40], .little),
            .prefix = std.mem.readInt(u64, b[40..48], .little),
            .tail = std.mem.readInt(u64, b[48..56], .little),
            .before = b[56..88].*,
            .after = b[88..120].*,
        };
        if (h.old_size > max_size or h.new_size > max_size or h.prefix > h.tail or
            h.tail > @min(h.old_size, h.new_size)) return error.BadSessionJournal;
        return h;
    }
};

fn size(parts: []const []const u8) !u64 {
    var n: u64 = 0;
    for (parts) |p| n = try std.math.add(u64, n, p.len);
    if (n > max_size) return error.SessionTooLarge;
    return n;
}
fn digest(parts: []const []const u8) [32]u8 {
    var hash = Sha.init(.{});
    for (parts) |p| hash.update(p);
    return hash.finalResult();
}
fn rangeDigest(parts: []const []const u8, start: u64, end: u64) [32]u8 {
    var hash = Sha.init(.{});
    var pos: u64 = 0;
    for (parts) |p| {
        const lo = @max(pos, start);
        const hi = @min(pos + p.len, end);
        if (lo < hi) hash.update(p[@intCast(lo - pos)..@intCast(hi - pos)]);
        pos += p.len;
    }
    return hash.finalResult();
}
fn writeParts(io: Io, file: Io.File, parts: []const []const u8, start: u64, end: u64, offset: u64, hash: ?*Sha) !u64 {
    var pos: u64 = 0;
    var written: u64 = 0;
    for (parts) |p| {
        const lo = @max(pos, start);
        const hi = @min(pos + p.len, end);
        if (lo < hi) {
            const bytes = p[@intCast(lo - pos)..@intCast(hi - pos)];
            try file.writePositionalAll(io, bytes, offset + written);
            if (hash) |h| h.update(bytes);
            written += bytes.len;
        }
        pos += p.len;
    }
    return written;
}
fn readExact(io: Io, file: Io.File, bytes: []u8, offset: u64) !void {
    if (try file.readPositionalAll(io, bytes, offset) != bytes.len) return error.BadSessionJournal;
}
fn hashFileRange(io: Io, file: Io.File, start: u64, end: u64, first: *Sha, second: ?*Sha) !void {
    var buf: [16384]u8 = undefined;
    var pos = start;
    while (pos < end) {
        const bytes = buf[0..@intCast(@min(buf.len, end - pos))];
        try readExact(io, file, bytes, pos);
        first.update(bytes);
        if (second) |h| h.update(bytes);
        pos += bytes.len;
    }
}
fn syncParent(io: Io, dir: Io.Dir, path: []const u8) !void {
    if (builtin.os.tag == .windows) return;
    const parent = try dir.openFile(io, std.fs.path.dirname(path) orelse ".", .{ .allow_directory = true });
    defer parent.close(io);
    try parent.sync(io);
}
fn journalName(gpa: Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}.journal", .{path});
}

/// Called only with the snapshot lock held. Memory is proportional to the old
/// snapshot only for full-save fallback; incremental saves use immutable parts.
fn prepare(io: Io, gpa: Allocator, dir: Io.Dir, path: []const u8, file: Io.File, parts: []const []const u8, delta: ?Delta) !Header {
    const current = markOf(try file.stat(io));
    const new_size = try size(parts);
    var old_owned: ?[]u8 = null;
    defer if (old_owned) |p| gpa.free(p);
    var fallback: [1][]const u8 = undefined;
    var old: []const []const u8 = undefined;
    var prefix: u64 = 0;
    var tail: u64 = 0;
    var incremental = false;
    if (delta) |d| {
        if (matches(current, d.old_mark) and try size(d.old_parts) == current.size and
            d.prefix <= d.tail and d.tail <= @min(current.size, new_size) and
            std.mem.eql(u8, &rangeDigest(d.old_parts, d.prefix, d.tail), &rangeDigest(parts, d.prefix, d.tail)))
        {
            old = d.old_parts;
            prefix = d.prefix;
            tail = d.tail;
            incremental = true;
        }
    }
    if (!incremental) {
        if (current.size > max_size) return error.SessionTooLarge;
        const bytes = try gpa.alloc(u8, @intCast(current.size));
        old_owned = bytes;
        try readExact(io, file, bytes, 0);
        fallback = .{bytes};
        old = &fallback;
    }
    const h: Header = .{ .inode = current.inode, .old_size = current.size, .new_size = new_size, .prefix = prefix, .tail = tail, .before = digest(old), .after = digest(parts) };
    const name = try journalName(gpa, path);
    defer gpa.free(name);
    const staging = try std.fmt.allocPrint(gpa, "{s}.tmp", .{name});
    defer gpa.free(staging);
    const journal = try dir.createFile(io, staging, .{});
    defer journal.close(io);
    var hash = Sha.init(.{});
    const header = h.encode();
    try journal.writePositionalAll(io, &header, 0);
    hash.update(&header);
    _ = try writeParts(io, journal, old, 0, prefix, header_len, &hash);
    _ = try writeParts(io, journal, old, tail, h.old_size, h.oldTail(), &hash);
    _ = try writeParts(io, journal, parts, 0, prefix, h.newPrefix(), &hash);
    _ = try writeParts(io, journal, parts, tail, new_size, h.newTail(), &hash);
    try journal.writePositionalAll(io, &hash.finalResult(), h.end());
    try journal.sync(io); // Never publish an incomplete transaction.
    try dir.rename(staging, dir, name, io);
    try syncParent(io, dir, path);
    stats.journal_bytes += h.end() + 32;
    if (incremental) stats.delta_writes += 1 else stats.full_writes += 1;
    return h;
}

/// Returns the final mark while the same lock still protects the snapshot.
pub fn write(io: Io, gpa: Allocator, dir: Io.Dir, path: []const u8, new_parts: []const []const u8, delta: ?Delta) !Mark {
    const held = try lock.open(io, dir, path);
    defer held.close(io);
    try recoverLocked(io, gpa, dir, path, held.file);
    const h = try prepare(io, gpa, dir, path, held.file, new_parts, delta);
    stats.bytes_written += try writeParts(io, held.file, new_parts, 0, h.prefix, 0, null);
    stats.bytes_written += try writeParts(io, held.file, new_parts, h.tail, h.new_size, h.tail, null);
    try held.file.setLength(io, h.new_size);
    try finish(io, gpa, dir, path, held.file);
    return markOf(try held.file.stat(io));
}
fn finish(io: Io, gpa: Allocator, dir: Io.Dir, path: []const u8, file: Io.File) !void {
    try file.sync(io); // The snapshot must be durable before retiring its WAL.
    try syncParent(io, dir, path);
    const name = try journalName(gpa, path);
    defer gpa.free(name);
    try dir.deleteFile(io, name);
    try syncParent(io, dir, path);
}

pub fn recover(io: Io, gpa: Allocator, dir: Io.Dir, path: []const u8) !void {
    const name = try journalName(gpa, path);
    defer gpa.free(name);
    _ = dir.statFile(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    // Do not create a missing snapshot when recovering a committed journal.
    _ = dir.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.SessionJournalConflict,
        else => return err,
    };
    const held = try lock.open(io, dir, path);
    defer held.close(io);
    try recoverLocked(io, gpa, dir, path, held.file);
}

fn recoverLocked(io: Io, gpa: Allocator, dir: Io.Dir, path: []const u8, file: Io.File) !void {
    const name = try journalName(gpa, path);
    defer gpa.free(name);
    const journal = dir.openFile(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer journal.close(io);
    var raw: [header_len]u8 = undefined;
    try readExact(io, journal, &raw, 0);
    const h = try Header.decode(&raw);
    if ((try journal.stat(io)).size != h.end() + 32) return error.BadSessionJournal;
    var hash = Sha.init(.{});
    try hashFileRange(io, journal, 0, h.end(), &hash, null);
    var checksum: [32]u8 = undefined;
    try readExact(io, journal, &checksum, h.end());
    if (!std.mem.eql(u8, &checksum, &hash.finalResult())) return error.BadSessionJournal;
    const st = try file.stat(io);
    if (st.inode != h.inode or st.size < @min(h.old_size, h.new_size) or
        st.size > @max(h.old_size, h.new_size)) return error.SessionJournalConflict;
    // Reconstruct both virtual files before touching anything. Only retained
    // bytes come from the possibly torn snapshot; all changed bytes are in WAL.
    var before = Sha.init(.{});
    var after = Sha.init(.{});
    try hashFileRange(io, journal, header_len, h.oldTail(), &before, null);
    try hashFileRange(io, journal, h.newPrefix(), h.newTail(), &after, null);
    try hashFileRange(io, file, h.prefix, h.tail, &before, &after);
    try hashFileRange(io, journal, h.oldTail(), h.newPrefix(), &before, null);
    try hashFileRange(io, journal, h.newTail(), h.end(), &after, null);
    if (!std.mem.eql(u8, &h.before, &before.finalResult()) or
        !std.mem.eql(u8, &h.after, &after.finalResult())) return error.SessionJournalConflict;
    // Also reject edits inside changed ranges: every surviving byte must be
    // from the recorded before or after image (partial pwrite is permitted).
    try validateChanged(io, file, journal, h, 0, h.prefix, header_len, h.newPrefix(), st.size);
    try validateChanged(io, file, journal, h, h.tail, @max(h.old_size, h.new_size), h.oldTail(), h.newTail(), st.size);
    try replay(io, file, journal, h.newPrefix(), h.prefix, 0);
    try replay(io, file, journal, h.newTail(), h.new_size - h.tail, h.tail);
    try file.setLength(io, h.new_size);
    try finish(io, gpa, dir, path, file);
}
fn validateChanged(io: Io, file: Io.File, journal: Io.File, h: Header, start: u64, end: u64, old_offset: u64, new_offset: u64, actual_size: u64) !void {
    var actual: [4096]u8 = undefined;
    var old: [4096]u8 = undefined;
    var new: [4096]u8 = undefined;
    var pos = start;
    while (pos < @min(end, actual_size)) {
        const n: usize = @intCast(@min(actual.len, @min(end, actual_size) - pos));
        const old_n: usize = @intCast(@min(n, h.old_size -| pos));
        const new_n: usize = @intCast(@min(n, h.new_size -| pos));
        try readExact(io, file, actual[0..n], pos);
        try readExact(io, journal, old[0..old_n], old_offset + pos - start);
        try readExact(io, journal, new[0..new_n], new_offset + pos - start);
        for (actual[0..n], 0..) |byte, i| {
            if (!(i < old_n and byte == old[i]) and !(i < new_n and byte == new[i])) return error.SessionJournalConflict;
        }
        pos += n;
    }
}
fn replay(io: Io, file: Io.File, journal: Io.File, from: u64, len: u64, to: u64) !void {
    var buf: [16384]u8 = undefined;
    var pos: u64 = 0;
    while (pos < len) {
        const bytes = buf[0..@intCast(@min(buf.len, len - pos))];
        try readExact(io, journal, bytes, from + pos);
        try file.writePositionalAll(io, bytes, to + pos);
        pos += bytes.len;
    }
}

pub const testing = if (builtin.is_test) struct {
    /// Simulate a process dying after publishing WAL, optionally after prefix.
    pub fn stage(io: Io, gpa: Allocator, dir: Io.Dir, path: []const u8, parts: []const []const u8, delta: ?Delta, prefix_only: bool) !void {
        const held = try lock.open(io, dir, path);
        defer held.close(io);
        try recoverLocked(io, gpa, dir, path, held.file);
        const h = try prepare(io, gpa, dir, path, held.file, parts, delta);
        if (prefix_only) _ = try writeParts(io, held.file, parts, 0, h.prefix, 0, null);
    }
} else struct {};

test {
    _ = @import("session_store_tests.zig");
}
