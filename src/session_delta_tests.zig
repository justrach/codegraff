//! Exercise the production save path, not just the cache or disk primitive.
const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Agent = @import("agent.zig").Agent;
const session = @import("session.zig");
const writer = @import("session_writer.zig");
const snapshots = @import("session_snapshot.zig");
const transcript = @import("session_transcript.zig");
const messages = @import("messages.zig");

fn root(a: std.mem.Allocator, client: *std.http.Client) Agent {
    return .{
        .gpa = std.testing.allocator,
        .arena = a,
        .io = std.testing.io,
        .client = client,
        .provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .bearer, .url = "", .api_key = "test", .model = "sonnet", .context = 200_000 },
        .messages = std.json.Array.init(a),
        .sub = false,
        .label = "root",
        .out = null,
    };
}

fn read(a: std.mem.Allocator, dir: Io.Dir, name: []const u8) !Value {
    const path = try session.sessionPath(a, name);
    const bytes = try dir.readFileAlloc(std.testing.io, path, a, .limited(1024 * 1024));
    return std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always });
}

test "#1859 production saves reuse old messages and write only a bounded append transaction" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    writer.resetForTest();
    defer writer.resetForTest();
    transcript.resetForTest();
    defer transcript.resetForTest();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var agent = root(a, &client);
    const history = try a.alloc(u8, 256 * 1024);
    @memset(history, 'x');
    try agent.messages.append(try messages.textMessage(a, "user", history));
    try agent.messages.append(try messages.textMessage(a, "assistant", "saved"));
    try session.saveSessionTo(&agent, a, tmp.dir, "delta-1859");
    writer.drain();
    const before = writer.stats();
    const serialized = snapshots.stats().serializations;

    try agent.messages.append(try messages.textMessage(a, "user", "next"));
    try agent.messages.append(try messages.textMessage(a, "assistant", "done"));
    agent.strict = true;
    try session.saveSessionTo(&agent, a, tmp.dir, "delta-1859");
    writer.drain();
    const after = writer.stats();
    try std.testing.expectEqual(serialized + 2, snapshots.stats().serializations);
    try std.testing.expectEqual(before.delta_writes + 1, after.delta_writes);
    const transaction_bytes = after.bytes_written - before.bytes_written + after.journal_bytes - before.journal_bytes;
    try std.testing.expect(transaction_bytes < history.len / 4);
    var saved = try read(a, tmp.dir, "delta-1859");
    try std.testing.expectEqual(@as(usize, 4), saved.object.get("messages").?.array.items.len);
    try std.testing.expect(saved.object.get("strict").?.bool);
    try std.testing.expectEqualStrings(history, saved.object.get("messages").?.array.items[0].object.get("content").?.string);

    // Earlier in-place edits and compaction must never retain stale disk bytes.
    try agent.messages.items[0].object.put(a, "content", .{ .string = "edited" });
    try session.saveSessionTo(&agent, a, tmp.dir, "delta-1859");
    writer.drain();
    try std.testing.expectEqual(serialized + 3, snapshots.stats().serializations);
    agent.messages.items.len = 1;
    agent.strict = false;
    try session.saveSessionTo(&agent, a, tmp.dir, "delta-1859");
    writer.drain();
    saved = try read(a, tmp.dir, "delta-1859");
    try std.testing.expectEqual(@as(usize, 1), saved.object.get("messages").?.array.items.len);
    try std.testing.expectEqualStrings("edited", saved.object.get("messages").?.array.items[0].object.get("content").?.string);
    try std.testing.expect(!saved.object.get("strict").?.bool);
    const writes = writer.stats().writes;
    try session.saveSessionTo(&agent, a, tmp.dir, "delta-1859");
    writer.drain();
    try std.testing.expectEqual(writes, writer.stats().writes);
}

test "#1859 coalesced production snapshots own their messages until the writer commits" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    writer.resetForTest();
    defer writer.resetForTest();
    transcript.resetForTest();
    defer transcript.resetForTest();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var agent = root(a, &client);
    try agent.messages.append(try messages.textMessage(a, "user", "queued"));
    writer.setPausedForTest(io, true);
    try session.saveSessionTo(&agent, a, tmp.dir, "queued-1859");
    try agent.messages.append(try messages.textMessage(a, "assistant", "newest"));
    try session.saveSessionTo(&agent, a, tmp.dir, "queued-1859");
    try std.testing.expectEqual(@as(usize, 1), writer.stats().superseded);
    // Neither cache eviction nor later live mutations may alter queued bytes.
    snapshots.reset();
    try agent.messages.items[0].object.put(a, "content", .{ .string = "not queued" });
    writer.setPausedForTest(io, false);
    writer.drain();
    const saved = try read(a, tmp.dir, "queued-1859");
    const history = saved.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), history.len);
    try std.testing.expectEqualStrings("queued", history[0].object.get("content").?.string);
    try std.testing.expectEqualStrings("newest", history[1].object.get("content").?.string);

    // Reverting to the last committed state must cancel a different pending
    // save, not skip because the desired bytes happen to be on disk already.
    writer.setPausedForTest(io, true);
    try session.saveSessionTo(&agent, a, tmp.dir, "queued-1859");
    try agent.messages.items[0].object.put(a, "content", .{ .string = "queued" });
    try session.saveSessionTo(&agent, a, tmp.dir, "queued-1859");
    writer.setPausedForTest(io, false);
    writer.drain();
    const reverted = try read(a, tmp.dir, "queued-1859");
    try std.testing.expectEqualStrings("queued", reverted.object.get("messages").?.array.items[0].object.get("content").?.string);
}
