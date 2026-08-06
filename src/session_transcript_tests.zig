//! session_transcript.zig's tests (#441). They live here for the 600-line cap,
//! mirroring session_tests.zig and agent_overflow_tests.zig; the module they
//! cover is reached in production from session.queueSave, but nothing
//! references THIS file outside test_hooks.zig, which is what makes its tests
//! run at all (AGENTS.md).
//!
//! The cases that earn their keep: a rewrite of the history leaves every line
//! already on disk byte-identical and in place, a repeated autosave adds
//! nothing, a resume re-seeds from the file instead of re-appending, a subagent
//! writes nothing, and the cap rotates TWICE so a rename that refused an
//! existing target could not pass.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const tool_spill = @import("tool_spill.zig");
const transcript = @import("session_transcript.zig");
const activePath = transcript.activePath;
const lineCount = transcript.lineCount;
const record = transcript.record;
const resetForTest = transcript.resetForTest;
const rotatedPath = transcript.rotatedPath;
const transcriptPath = transcript.transcriptPath;
const transcript_ext = transcript.transcript_ext;

const testing = std.testing;

fn msg(arena: Allocator, role: []const u8, text: []const u8) !Value {
    var o: std.json.ObjectMap = .empty;
    try o.put(arena, "role", .{ .string = role });
    try o.put(arena, "content", .{ .string = text });
    return .{ .object = o };
}

/// The fields `record` reads, and nothing else.
fn agentFor(gpa: Allocator, arena: Allocator, io: Io, name: []const u8) Agent {
    var root: Agent = undefined;
    root.gpa = gpa;
    root.io = io;
    root.sub = false;
    root.session_name = name;
    root.messages = std.json.Array.init(arena);
    return root;
}

/// Read a generation through the SAME builder the writer uses, so the test can
/// never disagree with the code about where the file is — and so no separator
/// is ever written by hand here (session_index.zig's invariant).
fn readGen(dir: Io.Dir, gpa: Allocator, arena: Allocator, name: []const u8, rotated: bool) ![]u8 {
    const rel = if (rotated) try rotatedPath(arena, name) else try transcriptPath(arena, name);
    return dir.readFileAlloc(testing.io, rel, gpa, .limited(1 << 20));
}

/// Lines are '\n'-terminated by construction. The '\r' check is the guard: a
/// writer that ever picked up a platform line ending would break the digests
/// silently (every line would stop matching and the history would be
/// re-appended), so make it a hard failure here instead.
fn countLines(data: []const u8) !usize {
    try testing.expect(std.mem.indexOfScalar(u8, data, '\r') == null);
    return std.mem.count(u8, data, "\n");
}

/// `activePath` asserted portably: it is the path of a file that really exists,
/// and its basename is the one we expect. Matching a '/'-joined literal would
/// pass today (the builder is forward-slashed on every platform, deliberately)
/// but it asserts the separator rather than the behaviour — ee28d8c's lesson.
fn expectActive(root: *Agent, arena: Allocator, dir: Io.Dir, name: []const u8) !void {
    const p = activePath(root, arena) orelse return error.TestUnexpectedResult;
    const want = try std.fmt.allocPrint(arena, "{s}{s}", .{ name, transcript_ext });
    try testing.expectEqualStrings(want, std.fs.path.basename(p));
    _ = try dir.statFile(testing.io, p, .{}); // the cited file is really there
}

test "one line per message, however many times the autosave runs (#441)" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    resetForTest();
    tool_spill.resetForTest();
    defer resetForTest();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = agentFor(gpa, a, io, "s");
    try root.messages.append(try msg(a, "user", "why did the build fail?"));
    record(&root, tmp.dir, "s");
    // The autosave runs again over an unchanged history: no second line.
    record(&root, tmp.dir, "s");
    record(&root, tmp.dir, "s");
    const one = try readGen(tmp.dir, gpa, a, "s", false);
    defer gpa.free(one);
    try testing.expectEqual(@as(usize, 1), try countLines(one));
    try testing.expect(std.mem.indexOf(u8, one, "why did the build fail?") != null);

    // A new turn adds exactly its own lines.
    try root.messages.append(try msg(a, "assistant", "error: undefined symbol GRAFF_441"));
    record(&root, tmp.dir, "s");
    record(&root, tmp.dir, "s");
    const two = try readGen(tmp.dir, gpa, a, "s", false);
    defer gpa.free(two);
    try testing.expectEqual(@as(usize, 2), try countLines(two));
    // Append-only at the byte level: the first line is untouched where it was.
    try testing.expect(std.mem.startsWith(u8, two, one));

    // A genuine repeat is a real message, not a duplicate: forward-only
    // matching must not swallow it.
    try root.messages.append(try msg(a, "user", "why did the build fail?"));
    record(&root, tmp.dir, "s");
    const three = try readGen(tmp.dir, gpa, a, "s", false);
    defer gpa.free(three);
    try testing.expectEqual(@as(usize, 3), try countLines(three));
}

test "compaction discards the history; the transcript still has it (#441)" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    resetForTest();
    tool_spill.resetForTest();
    defer resetForTest();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = agentFor(gpa, a, io, "c");
    // The exact wording that a summary would paraphrase away.
    const detail = "ld: symbol(s) not found for architecture arm64: _graff_441_probe";
    try root.messages.append(try msg(a, "user", "build it"));
    try root.messages.append(try msg(a, "tool", detail));
    try root.messages.append(try msg(a, "assistant", "fixing the link order"));
    try root.messages.append(try msg(a, "user", "and now?"));
    record(&root, tmp.dir, "c");
    const before = try readGen(tmp.dir, gpa, a, "c", false);
    defer gpa.free(before);
    try testing.expectEqual(@as(usize, 4), try countLines(before));

    // compact()'s shape: a fresh array of [handoff summary] ++ the recent
    // suffix verbatim. The detail is now unreachable from `messages` — the very
    // next autosave rewrites the session file without it.
    const tail = root.messages.items[3];
    var fresh = std.json.Array.init(a);
    try fresh.append(try msg(a, "user", "[summary] we were fixing a link error"));
    try fresh.append(tail);
    root.messages = fresh;
    record(&root, tmp.dir, "c");

    const after = try readGen(tmp.dir, gpa, a, "c", false);
    defer gpa.free(after);
    // (a) every earlier line survived, byte for byte, in place
    try testing.expect(std.mem.startsWith(u8, after, before));
    // (b) the discarded detail is still greppable
    try testing.expect(std.mem.indexOf(u8, after, detail) != null);
    // (c) only the summary was added — the verbatim tail is not duplicated
    try testing.expectEqual(@as(usize, 5), try countLines(after));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, after, "and now?"));
    try testing.expect(std.mem.indexOf(u8, after, "[summary] we were fixing") != null);

    // And the turn after the compaction keeps appending normally.
    try root.messages.append(try msg(a, "assistant", "linked clean"));
    record(&root, tmp.dir, "c");
    const later = try readGen(tmp.dir, gpa, a, "c", false);
    defer gpa.free(later);
    try testing.expectEqual(@as(usize, 6), try countLines(later));
    try testing.expect(std.mem.startsWith(u8, later, after));
}

test "a resumed session does not re-append its restored history (#441)" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    resetForTest();
    tool_spill.resetForTest();
    defer resetForTest();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = agentFor(gpa, a, io, "r");
    try root.messages.append(try msg(a, "user", "first"));
    try root.messages.append(try msg(a, "assistant", "second"));
    record(&root, tmp.dir, "r");

    // A new process resumes "r": same history, no in-memory state at all. The
    // digests are re-seeded from the file, so nothing is written twice.
    resetForTest();
    record(&root, tmp.dir, "r");
    const data = try readGen(tmp.dir, gpa, a, "r", false);
    defer gpa.free(data);
    try testing.expectEqual(@as(usize, 2), try countLines(data));
    try testing.expectEqual(@as(usize, 2), lineCount());
    // The accessor #411 uses answers for the attached session only.
    try expectActive(&root, a, tmp.dir, "r");
    root.session_name = "somewhere-else";
    try testing.expect(activePath(&root, a) == null);
}

test "a subagent writes no transcript (#441)" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    resetForTest();
    tool_spill.resetForTest();
    defer resetForTest();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = agentFor(gpa, a, io, "sub-session");
    root.sub = true;
    try root.messages.append(try msg(a, "user", "delegated mandate"));
    record(&root, tmp.dir, "sub-session");
    try testing.expectError(error.FileNotFound, readGen(tmp.dir, gpa, a, "sub-session", false));
    try testing.expect(activePath(&root, a) == null);

    // A name that could escape the sessions dir writes nothing either.
    root.sub = false;
    record(&root, tmp.dir, "../escape");
    try testing.expectEqual(@as(usize, 0), lineCount());
}

test "the size cap rotates the generation instead of rewriting it (#441)" {
    const io = testing.io;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    resetForTest();
    tool_spill.resetForTest();
    const saved_cap = transcript.cap_bytes;
    defer {
        transcript.cap_bytes = saved_cap;
        resetForTest();
    }
    transcript.cap_bytes = 400;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var root = agentFor(gpa, a, io, "rot");
    try root.messages.append(try msg(a, "user", "the oldest thing said, worth keeping"));
    record(&root, tmp.dir, "rot");
    const first = try readGen(tmp.dir, gpa, a, "rot", false);
    defer gpa.free(first);

    // Enough turns to pass the cap.
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try root.messages.append(try msg(a, "assistant", "0123456789012345678901234567890123456789"));
        record(&root, tmp.dir, "rot");
    }

    // The previous generation holds the old bytes UNCHANGED — nothing was read,
    // trimmed and written back — and the oldest line is still greppable there.
    const prev = try readGen(tmp.dir, gpa, a, "rot", true);
    defer gpa.free(prev);
    try testing.expect(std.mem.startsWith(u8, prev, first));
    try testing.expect(std.mem.indexOf(u8, prev, "the oldest thing said") != null);
    // Both generations respect the cap, so the session is bounded at 2x it.
    try testing.expect(prev.len <= transcript.cap_bytes);
    const live = try readGen(tmp.dir, gpa, a, "rot", false);
    defer gpa.free(live);
    try testing.expect(live.len > 0 and live.len <= transcript.cap_bytes);
    // Rotation is a file operation, not an identity reset: the messages already
    // written are still not re-appended to the fresh generation.
    const lines_before = lineCount();
    record(&root, tmp.dir, "rot");
    try testing.expectEqual(lines_before, lineCount());

    // A SECOND rotation, over a previous generation that already exists. This
    // is the case a rename that refuses a taken target would fail — POSIX
    // replaces, Windows natively does not, and Io.Dir.rename is the replacing
    // variant on both. Without this the suite only ever rotated onto a free
    // name and could not tell the difference.
    while (i < 40) : (i += 1) {
        try root.messages.append(try msg(a, "assistant", "0123456789012345678901234567890123456789"));
        record(&root, tmp.dir, "rot");
    }
    const prev2 = try readGen(tmp.dir, gpa, a, "rot", true);
    defer gpa.free(prev2);
    const live2 = try readGen(tmp.dir, gpa, a, "rot", false);
    defer gpa.free(live2);
    // The previous generation really was REPLACED: it used to be the one
    // holding the oldest line, and is not any more. A rename that refused a
    // taken target would have left the first generation sitting there and
    // stalled the live file past its cap instead.
    try testing.expect(std.mem.indexOf(u8, prev, "the oldest thing said") != null);
    try testing.expect(std.mem.indexOf(u8, prev2, "the oldest thing said") == null);
    // Both generations still hold whole lines, and the cap still binds.
    try testing.expect(prev2.len > 0 and prev2.len <= transcript.cap_bytes);
    try testing.expect(live2.len > 0 and live2.len <= transcript.cap_bytes);
    try testing.expect(std.mem.endsWith(u8, prev2, "\n"));
    try testing.expect(std.mem.endsWith(u8, live2, "\n"));
    // 1 + 8 + 32 messages ever entered the history, and every one was recorded
    // exactly once — no rotation re-appended anything.
    try testing.expectEqual(@as(usize, 41), lineCount());
}
