//! Session writer lifecycle, fingerprint and coalescing regressions.
const std = @import("std");
const Io = std.Io;
const writer = @import("session_writer.zig");
const Fingerprint = writer.Fingerprint;
const resetForTest = writer.resetForTest;
const submit = writer.submit;
const drain = writer.drain;
const stats = writer.stats;
const alreadySaved = writer.alreadySaved;
const setPausedForTest = writer.setPausedForTest;
const stop = writer.stop;
const errorFor = writer.errorFor;

test "fingerprint tracks every mutation the session file records (#273)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var msgs = std.json.Array.init(a);
    var user: std.json.ObjectMap = .empty;
    try user.put(a, "role", .{ .string = "user" });
    try user.put(a, "content", .{ .string = "ship #273" });
    try msgs.append(.{ .object = user });

    const of = struct {
        fn fp(m: std.json.Array, title: []const u8) u64 {
            var f: Fingerprint = .init();
            f.text(title);
            f.json(.{ .array = m });
            return f.final();
        }
    }.fp;

    const base = of(msgs, "t");
    // Unchanged state hashes identically — this is what makes the skip safe.
    try std.testing.expectEqual(base, of(msgs, "t"));
    // A field OUTSIDE the history still counts (title, goal, todos, flags).
    try std.testing.expect(base != of(msgs, "t2"));

    // An appended turn.
    var reply: std.json.ObjectMap = .empty;
    try reply.put(a, "role", .{ .string = "assistant" });
    try reply.put(a, "content", .{ .string = "done" });
    try msgs.append(.{ .object = reply });
    const appended = of(msgs, "t");
    try std.testing.expect(base != appended);

    // An IN-PLACE edit of an existing message (compaction/truncation shape):
    // same message count, different content. A length-only or count-only dirty
    // check would miss exactly this and lose the rewrite.
    try msgs.items[0].object.put(a, "content", .{ .string = "ship #273 now" });
    try std.testing.expect(appended != of(msgs, "t"));
}

fn expectFile(dir: Io.Dir, path: []const u8, want: []const u8) !void {
    const got = try dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "a queued save reaches disk and drain waits for it (#273)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    resetForTest();
    defer resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    _ = submit(gpa, io, tmp.dir, try gpa.dupe(u8, "s/a.json"), try gpa.dupe(u8, "{\"m\":1}"), 1);
    drain();
    try expectFile(tmp.dir, "s/a.json", "{\"m\":1}");
    try std.testing.expectEqual(@as(usize, 1), stats().writes);
    // The write landed, so an identical save is now skippable.
    try std.testing.expect(alreadySaved(io, tmp.dir, "s/a.json", 1));
    try std.testing.expect(!alreadySaved(io, tmp.dir, "s/a.json", 2)); // other state
    try std.testing.expect(!alreadySaved(io, tmp.dir, "s/other.json", 1)); // other file
}

test "the skip needs the bytes to still be on disk, not just to have been written (#273)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    resetForTest();
    defer resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    _ = submit(gpa, io, tmp.dir, try gpa.dupe(u8, "s/e.json"), try gpa.dupe(u8, "ten turns"), 3);
    drain();
    try std.testing.expect(alreadySaved(io, tmp.dir, "s/e.json", 3));

    // A second graff in the same workspace writes its own snapshot over ours
    // (#289: the lock is only held during the write). The state we would skip
    // on is no longer what the file holds, so the skip must not happen — the
    // exit save has to rewrite and win, as it did before #273.
    try tmp.dir.writeFile(io, .{ .sub_path = "s/e.json", .data = "another graff" });
    try std.testing.expect(!alreadySaved(io, tmp.dir, "s/e.json", 3));
    // Invalidated for good: not a one-shot that re-trusts itself next call.
    try std.testing.expect(!alreadySaved(io, tmp.dir, "s/e.json", 3));

    // Same for a session file that is deleted out from under us.
    _ = submit(gpa, io, tmp.dir, try gpa.dupe(u8, "s/e.json"), try gpa.dupe(u8, "ten turns"), 3);
    drain();
    try std.testing.expect(alreadySaved(io, tmp.dir, "s/e.json", 3));
    try tmp.dir.deleteFile(io, "s/e.json");
    try std.testing.expect(!alreadySaved(io, tmp.dir, "s/e.json", 3));
}

test "a newer save supersedes an older queued one (#273)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    resetForTest();
    defer resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    setPausedForTest(io, true);
    _ = submit(gpa, io, tmp.dir, try gpa.dupe(u8, "s/b.json"), try gpa.dupe(u8, "old"), 1);
    _ = submit(gpa, io, tmp.dir, try gpa.dupe(u8, "s/b.json"), try gpa.dupe(u8, "newest"), 2);
    try std.testing.expectEqual(@as(usize, 1), stats().superseded);
    setPausedForTest(io, false);
    drain();
    // One write, of the newest state: a burst never costs a write per save.
    try std.testing.expectEqual(@as(usize, 1), stats().writes);
    try expectFile(tmp.dir, "s/b.json", "newest");
}

test "no queued save is lost at shutdown (#273)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    resetForTest();
    defer resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    setPausedForTest(io, true);
    _ = submit(gpa, io, tmp.dir, try gpa.dupe(u8, "s/c.json"), try gpa.dupe(u8, "last turn"), 7);
    // Provably still queued: nothing is on disk yet.
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "s/c.json", .{}));
    stop(); // the exit path: drain, then retire the worker
    try expectFile(tmp.dir, "s/c.json", "last turn");
}

test "a failed write clears the skip mark so the next save retries (#273)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    resetForTest();
    defer resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A regular file where the session directory would go: createDirPath and
    // the create both fail, so the write cannot land.
    try tmp.dir.writeFile(io, .{ .sub_path = "blocked", .data = "" });
    const ticket = submit(gpa, io, tmp.dir, try gpa.dupe(u8, "blocked/d.json"), try gpa.dupe(u8, "x"), 5);
    drain();
    try std.testing.expectEqual(@as(usize, 0), stats().writes);
    try std.testing.expect(!alreadySaved(io, tmp.dir, "blocked/d.json", 5)); // never skip on a write that failed
    try std.testing.expect(errorFor(ticket) != null);
    try std.testing.expect(errorFor(ticket) == null); // reported once
}

test "a background failure is never charged to a later save (#273)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    resetForTest();
    defer resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Turn 5's autosave loses the race and fails in the background.
    try tmp.dir.writeFile(io, .{ .sub_path = "blocked", .data = "" });
    const autosave = submit(gpa, io, tmp.dir, try gpa.dupe(u8, "blocked/f.json"), try gpa.dupe(u8, "turn 5"), 8);
    drain();

    // `/save release-notes` writes its own file, successfully. It must report
    // ITS outcome — reporting the autosave's error made /save print "save
    // failed" and skip the rename for a file it had just written correctly.
    const named = submit(gpa, io, tmp.dir, try gpa.dupe(u8, "s/release-notes.json"), try gpa.dupe(u8, "everything"), 9);
    drain();
    try std.testing.expect(errorFor(named) == null);
    try expectFile(tmp.dir, "s/release-notes.json", "everything");
    // And the older ticket cannot resurrect it either: the newer write means
    // the failure no longer describes the disk.
    try std.testing.expect(errorFor(autosave) == null);
}

test "#1859 saves for different names or directories cannot supersede each other" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    resetForTest();
    defer resetForTest();
    var first = std.testing.tmpDir(.{});
    defer first.cleanup();
    var second = std.testing.tmpDir(.{});
    defer second.cleanup();
    _ = submit(gpa, io, first.dir, try gpa.dupe(u8, "a.json"), try gpa.dupe(u8, "first"), 1);
    _ = submit(gpa, io, first.dir, try gpa.dupe(u8, "b.json"), try gpa.dupe(u8, "second"), 2);
    _ = submit(gpa, io, first.dir, try gpa.dupe(u8, "shared.json"), try gpa.dupe(u8, "here"), 3);
    _ = submit(gpa, io, second.dir, try gpa.dupe(u8, "shared.json"), try gpa.dupe(u8, "there"), 4);
    drain();
    try expectFile(first.dir, "a.json", "first");
    try expectFile(first.dir, "b.json", "second");
    try expectFile(first.dir, "shared.json", "here");
    try expectFile(second.dir, "shared.json", "there");
    try std.testing.expectEqual(@as(usize, 4), stats().writes);
    try std.testing.expectEqual(@as(usize, 0), stats().superseded);
}
