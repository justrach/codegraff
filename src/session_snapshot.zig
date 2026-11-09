//! Immutable, independently owned message snapshots for the session writer.
//! The cache holds only the latest vector; queued snapshots keep their own
//! references, so replacement, coalescing and reset cannot invalidate a worker.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Fingerprint = @import("session_fingerprint.zig").Fingerprint;
const cache_allocator = std.heap.page_allocator;
const spaces: [4096]u8 = @splat(' ');

pub const Chunk = struct {
    data: []const u8,
    hash: u64,
    refs: std.atomic.Value(usize),

    fn retain(self: *Chunk) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    fn release(self: *Chunk) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            cache_allocator.free(self.data);
            cache_allocator.destroy(self);
        }
    }
};

pub const Snapshot = struct {
    metadata: []u8,
    header_end: usize,
    messages: []*Chunk,
    /// Includes both array brackets and every separating comma.
    message_bytes: usize,
    gpa: Allocator,

    /// Takes ownership of a complete metadata object containing "messages":[].
    /// header_end is immediately after the colon, before the empty array.
    pub fn setMetadata(self: *Snapshot, bytes: []u8, header_end: usize) void {
        const token = "\"messages\":";
        std.debug.assert(header_end >= token.len);
        std.debug.assert(header_end + 2 <= bytes.len);
        std.debug.assert(std.mem.eql(u8, bytes[header_end - token.len .. header_end], token));
        std.debug.assert(std.mem.eql(u8, bytes[header_end .. header_end + 2], "[]"));
        self.gpa.free(self.metadata);
        self.metadata = bytes;
        self.header_end = header_end;
    }

    /// Only the slice vector is arena-owned. All byte slices refer to this
    /// snapshot or static literals, including arbitrarily large head padding.
    pub fn parts(self: Snapshot, arena: Allocator, header_capacity: usize) ![]const []const u8 {
        if (self.header_end + 2 > self.metadata.len) return error.InvalidMetadata;
        if (header_capacity < self.header_end) return error.HeaderCapacityTooSmall;
        var result: std.ArrayList([]const u8) = .empty;
        errdefer result.deinit(arena);
        try result.append(arena, self.metadata[0..self.header_end]);
        var padding = header_capacity - self.header_end;
        while (padding > 0) {
            const n = @min(padding, spaces.len);
            try result.append(arena, spaces[0..n]);
            padding -= n;
        }
        try result.append(arena, "[");
        for (self.messages, 0..) |chunk, i| {
            if (i != 0) try result.append(arena, ",");
            try result.append(arena, chunk.data);
        }
        try result.append(arena, "]");
        try result.append(arena, self.metadata[self.header_end + 2 ..]);
        return try result.toOwnedSlice(arena);
    }

    /// Content comparison also works across reset or independently built chunks.
    pub fn commonPrefix(self: Snapshot, other: Snapshot) usize {
        const n = @min(self.messages.len, other.messages.len);
        for (self.messages[0..n], other.messages[0..n], 0..) |a, b, i| {
            if (a != b and !std.mem.eql(u8, a.data, b.data)) return i;
        }
        return n;
    }

    /// Immediately after the final common message, BEFORE a comma or ']'.
    pub fn tailOffset(self: Snapshot, prefix_count: usize, header_capacity: usize) usize {
        std.debug.assert(prefix_count <= self.messages.len);
        std.debug.assert(header_capacity >= self.header_end);
        var offset = header_capacity + 1;
        for (self.messages[0..prefix_count], 0..) |chunk, i| {
            if (i != 0) offset += 1;
            offset += chunk.data.len;
        }
        return offset;
    }

    /// Must not race another operation on this same snapshot. Different
    /// snapshots may be retired concurrently, including shared chunks.
    pub fn deinit(self: *Snapshot) void {
        self.gpa.free(self.metadata);
        for (self.messages) |chunk| chunk.release();
        self.gpa.free(self.messages);
        self.* = undefined;
    }
};

pub const Stats = struct { serializations: usize };
var cache_lock: std.atomic.Value(bool) = .init(false);
var cached: []*Chunk = &.{};
var serializations: usize = 0;

fn acquire() void {
    while (cache_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null)
        std.atomic.spinLoopHint();
}

fn release() void {
    cache_lock.store(false, .release);
}

fn clearCache() void {
    for (cached) |chunk| chunk.release();
    cache_allocator.free(cached);
    cached = &.{};
}

/// Release the cache's references only; outstanding snapshots remain valid.
/// Also starts a fresh statistics interval. Safe against prepare/stats.
pub fn reset() void {
    acquire();
    defer release();
    clearCache();
    serializations = 0;
}

pub fn stats() Stats {
    acquire();
    defer release();
    return .{ .serializations = serializations };
}

/// Hash EVERY live value, not just the vector identity or its final element:
/// earlier messages can be edited in place without moving either anchor.
/// The caller must keep items stable during this call. Nothing borrows items
/// afterwards. Cache bookkeeping is serialized; chunk lifetimes are atomic.
pub fn prepare(gpa: Allocator, items: []const Value) !Snapshot {
    acquire();
    defer release();

    const messages = try gpa.alloc(*Chunk, items.len);
    errdefer gpa.free(messages);
    var initialized: usize = 0;
    errdefer for (messages[0..initialized]) |chunk| chunk.release();
    const next_cache = try cache_allocator.alloc(*Chunk, items.len);
    errdefer cache_allocator.free(next_cache);

    var message_bytes: usize = 2;
    var reused_chunks: usize = 0;
    var reused_bytes: usize = 0;
    for (items, 0..) |item, i| {
        var fp = Fingerprint.init();
        fp.json(item);
        const hash = fp.final();
        const chunk = if (i < cached.len and cached[i].hash == hash) reuse: {
            cached[i].retain();
            reused_chunks += 1;
            reused_bytes += cached[i].data.len;
            break :reuse cached[i];
        } else create: {
            const chunk = try cache_allocator.create(Chunk);
            errdefer cache_allocator.destroy(chunk);
            const data = try std.json.Stringify.valueAlloc(cache_allocator, item, .{});
            chunk.* = .{ .data = data, .hash = hash, .refs = .init(1) };
            serializations += 1;
            break :create chunk;
        };
        messages[i] = chunk;
        initialized += 1;
        message_bytes += chunk.data.len;
        if (i != 0) message_bytes += 1;
        next_cache[i] = chunk;
    }

    // Commit only after all allocation/serialization succeeds. A failed
    // prepare leaves the previous cache usable and releases its partial work.
    for (next_cache) |chunk| chunk.retain();
    clearCache();
    cached = next_cache;
    @import("megaharness.zig").recordSnapshotReuse(reused_chunks, reused_bytes);
    return .{
        .metadata = &.{},
        .header_end = 0,
        .messages = messages,
        .message_bytes = message_bytes,
        .gpa = gpa,
    };
}

test {
    _ = @import("session_snapshot_test.zig");
}
