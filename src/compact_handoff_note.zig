//! #411: what SURVIVES a compaction, told to the model twice.
//!
//! NOT `compact_note.zig` (#391), which is the other side of the same boundary:
//! that one is the buffer-reserved turn where the MODEL writes notes to itself
//! before rollover. This one is the HARNESS's own ground truth, injected around
//! the handoff - hence the name. Both halves of the boundary, two modules.
//!
//! THE PROBLEM. compact() replaces the history with a summary and never says
//! what the summary does NOT have to carry. The model therefore treats the
//! compaction as total loss and spends the summary hoarding contents - pasted
//! file bodies, quoted tool output - which is both the most expensive thing it
//! can put in a summary and the least necessary, because every one of those
//! bytes is still on disk. Worse, the state the harness itself keeps (the goal,
//! the checklist, the transcript, the spilled artifacts) came back only as the
//! model's recollection of it, which drifts a little more at every compaction.
//!
//! THE TWO HALVES, from prime-agent's compaction design.
//!
//! BEFORE - `summaryRequest`. The summarization request carries a note saying
//! what persists: the files, the goal/checklist, and the append-only transcript
//! (#441). It asks for NAMES rather than contents, and points the summary at
//! what disk genuinely cannot give back - decisions, dead ends, constraints,
//! the state of unfinished work.
//!
//! AFTER - `durableState`. The new history head carries the harness's own
//! ground truth: the files this session modified, the tool outputs spilled to
//! disk by the history that was just discarded, and the transcript path. This
//! is STATE, not conversation. It is re-derived from live harness state at
//! every compaction rather than copied forward, so a later summary that
//! paraphrases it away costs nothing: the next compaction regenerates it
//! exactly, from the ledger and from disk, and it cannot drift.
//!
//! HONESTY RULES. Every field is omitted unless it is real. The transcript line
//! comes from `session_transcript.activePath`, which returns null when no
//! transcript is live, so the note can never cite a file that does not exist.
//! The artifact paths are read back out of the #409 markers in the discarded
//! messages themselves, so each one was written by a spill that succeeded. The
//! file list is `/rewind`'s snapshot ledger, which is exact for the tools that
//! take snapshots and blind to bash - and says so, rather than presenting a
//! partial list as the session's whole diff.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const compact_instruction = @import("prompts.zig").compact_instruction;
const session_transcript = @import("session_transcript.zig");
const tool_spill = @import("tool_spill.zig");

/// Most modified paths named before the list is elided. A compaction runs at
/// the point context is scarce, so this block has to stay a note rather than
/// becoming a manifest.
const max_files: usize = 24;

/// Most spilled artifacts named. Same reason, and the marker for each one is a
/// full absolute path.
const max_handles: usize = 12;

const persists_note =
    \\What SURVIVES this compaction, so you do not spend the summary preserving it:
    \\every file on disk is exactly as you left it, and any goal or todo checklist
    \\is harness state that is restated to you in full immediately after this
    \\summary. Record NAMES, not contents: file paths, directories, artifact paths,
    \\the command lines that worked, identifiers. Spend the words instead on what
    \\disk cannot give back - the decisions and why they were made, what was tried
    \\and failed, the constraints the user set, and the exact state of the
    \\unfinished work.
;

/// The user message compact() sends to ask for the handoff summary: the
/// instruction, unchanged, plus the note above. Unchanged matters - #379
/// classifies the RESPONSE to this request, and an empty or truncated reply is
/// still exactly as unusable as it was before the note existed.
pub fn summaryRequest(arena: Allocator, root: *Agent) ![]const u8 {
    const path = session_transcript.activePath(root, arena) orelse
        return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ compact_instruction, persists_note });
    return std.fmt.allocPrint(arena,
        \\{s}
        \\
        \\{s}
        \\The complete conversation, including every message this summary replaces,
        \\also stays on disk at {s} ({d} messages, one JSON object per line). It is
        \\greppable, so an exact wording you leave out is recoverable rather than
        \\lost - which is another reason to summarize rather than transcribe.
    , .{ compact_instruction, persists_note, path, session_transcript.lineCount() });
}

/// The harness's own answer to "what is still here", assembled from live state
/// at the moment of the compaction. `discarded` is the slice of history the
/// summary replaces, read (not kept) for the artifact paths its markers cite.
/// Null when there is nothing true to report - which keeps a plain session's
/// handoff byte-identical to what it has always been.
pub fn durableState(arena: Allocator, root: *Agent, discarded: []const Value) !?[]const u8 {
    // A subagent has no durable anything: its history is never persisted, it
    // gets no transcript, it never spills, and the /rewind ledger is the root's.
    // A /review turn shares the Agent struct but not the session's work.
    if (root.sub or root.review_mode) return null;
    var lines: std.ArrayList([]const u8) = .empty;
    if (try fileLine(arena, root)) |line| try lines.append(arena, line);
    if (try handleLine(arena, discarded)) |line| try lines.append(arena, line);
    if (try transcriptLine(arena, root)) |line| try lines.append(arena, line);
    if (lines.items.len == 0) return null;
    return try std.fmt.allocPrint(arena,
        \\[durable state, re-derived by the harness at this compaction rather than
        \\recalled, so it cannot drift:
        \\{s}
        \\Everything named above exists on disk right now: read it back instead of
        \\re-deriving it, and do not re-run a tool whose output is already there.]
    , .{try std.mem.join(arena, "\n", lines.items)});
}

/// compact()'s new history head: the model's handoff text, then the standing
/// goal/checklist state (#318), then the durable-state note. Joined with blank
/// lines, and byte-identical to `base` when neither block has anything to say.
pub fn handoff(arena: Allocator, root: *Agent, base: []const u8, standing: ?[]const u8, discarded: []const Value) ![]const u8 {
    var out = base;
    if (standing) |s| out = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ out, s });
    if (try durableState(arena, root, discarded)) |d| out = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ out, d });
    return out;
}

fn fileLine(arena: Allocator, root: *Agent) !?[]const u8 {
    const snaps = root.snapshots orelse return null;
    const paths = snaps.modifiedPaths(arena);
    if (paths.len == 0) return null;
    const shown = @min(paths.len, max_files);
    const joined = try std.mem.join(arena, ", ", paths[0..shown]);
    const more = if (paths.len > shown)
        try std.fmt.allocPrint(arena, ", and {d} more", .{paths.len - shown})
    else
        "";
    // The parenthetical is the honest bound, not boilerplate: presenting this
    // ledger as the session's whole diff would be a lie whenever a `sed`, a
    // `git apply` or a companion CLI did the writing.
    return try std.fmt.allocPrint(arena, "- files this session modified ({d}; write_file/edit_file/imagegen only - edits made through bash are not tracked): {s}{s}", .{ paths.len, joined, more });
}

/// Only the handles THIS compaction is discarding, deliberately. Re-harvesting
/// the previous note's list would fold each compaction's handles into the next
/// without bound - #B3's task-pin rule, one level down. The artifacts stay on
/// disk regardless, and the transcript line above says where every old marker
/// can still be grepped in full.
fn handleLine(arena: Allocator, discarded: []const Value) !?[]const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    for (discarded) |m| try collectHandles(arena, m, &paths);
    if (paths.items.len == 0) return null;
    const shown = @min(paths.items.len, max_handles);
    const joined = try std.mem.join(arena, ", ", paths.items[0..shown]);
    const more = if (paths.items.len > shown)
        try std.fmt.allocPrint(arena, ", and {d} more", .{paths.items.len - shown})
    else
        "";
    return try std.fmt.allocPrint(arena, "- full tool outputs the discarded history spilled to disk (#409), still readable: {s}{s}", .{ joined, more });
}

fn transcriptLine(arena: Allocator, root: *Agent) !?[]const u8 {
    const path = session_transcript.activePath(root, arena) orelse return null;
    return try std.fmt.allocPrint(arena, "- this conversation's full transcript, including everything the summary above replaced: {s} ({d} messages, one JSON object per line) - grep it for an exact wording the summary paraphrased", .{ path, session_transcript.lineCount() });
}

/// Walk a message's JSON for #409 spill markers. Recursive because the marker
/// sits in a different field in each wire format (`output`, `content`, or a
/// `tool_result` block inside a content array), and a shape-blind walk cannot
/// be broken by a format this file has not heard of.
fn collectHandles(arena: Allocator, value: Value, out: *std.ArrayList([]const u8)) !void {
    switch (value) {
        .string => |s| if (handlePath(s)) |p| {
            for (out.items) |seen| if (std.mem.eql(u8, seen, p)) return;
            try out.append(arena, p);
        },
        .array => |a| for (a.items) |item| try collectHandles(arena, item, out),
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |entry| try collectHandles(arena, entry.value_ptr.*, out);
        },
        else => {},
    }
}

/// The artifact path inside a spill marker, or null for any other text. All
/// three fences must be present in order: a tool output that merely happens to
/// contain "bytes are at" is not a marker.
fn handlePath(s: []const u8) ?[]const u8 {
    const head = std.mem.indexOf(u8, s, tool_spill.marker_head) orelse return null;
    const rest = s[head..];
    const open = std.mem.indexOf(u8, rest, tool_spill.marker_path_open) orelse return null;
    const tail = rest[open + tool_spill.marker_path_open.len ..];
    const close = std.mem.indexOf(u8, tail, tool_spill.marker_path_close) orelse return null;
    return if (close == 0) null else tail[0..close];
}

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;
const textMessage = @import("messages.zig").textMessage;
const snapshots_mod = @import("snapshots.zig");

/// The fields the two halves read, and nothing else - every one of them is
/// consulted on the null path too, so an `undefined` here is a crash rather
/// than a silent pass.
fn noteAgent(sub: bool) Agent {
    var root: Agent = undefined;
    root.sub = sub;
    root.review_mode = false;
    root.snapshots = null;
    root.session_name = "";
    root.gpa = testing.allocator;
    root.io = testing.io;
    return root;
}

fn ledger() snapshots_mod.Snapshots {
    return .{ .gpa = testing.allocator, .io = testing.io };
}

test "the summary request says what persists and asks for names, not contents (#411)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    session_transcript.resetForTest();
    defer session_transcript.resetForTest();

    var root = noteAgent(false);
    const req = try summaryRequest(a, &root);
    // The instruction the model has always been given still LEADS the request:
    // #379 classifies the response to it, and that classification must not
    // start depending on a note that was appended after the fact.
    try testing.expect(std.mem.startsWith(u8, req, compact_instruction));
    try testing.expect(std.mem.indexOf(u8, req, "Record NAMES, not contents") != null);
    try testing.expect(std.mem.indexOf(u8, req, "restated to you in full") != null);
    // The ground truth itself belongs on the FAR side of the summary, where the
    // model cannot summarize it away. It must not be in the request.
    try testing.expect(std.mem.indexOf(u8, req, "durable state, re-derived") == null);
    // Nothing is live here, so the request cites no file at all.
    try testing.expect(std.mem.indexOf(u8, req, ".transcript.jsonl") == null);
}

test "a live transcript is named in both halves, by real path and message count (#411)" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    session_transcript.resetForTest();
    tool_spill.resetForTest();
    defer session_transcript.resetForTest();
    defer tool_spill.resetForTest();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var root = noteAgent(false);
    root.session_name = "n411";
    root.messages = std.json.Array.init(a);
    try root.messages.append(try textMessage(a, "user", "why did the build fail?"));
    try root.messages.append(try textMessage(a, "assistant", "the link order"));
    session_transcript.record(&root, tmp.dir, "n411");

    const req = try summaryRequest(a, &root);
    try testing.expect(std.mem.indexOf(u8, req, ".graff/sessions/n411.transcript.jsonl") != null);
    try testing.expect(std.mem.indexOf(u8, req, "(2 messages") != null);

    const note = (try durableState(a, &root, &.{})).?;
    try testing.expect(std.mem.indexOf(u8, note, ".graff/sessions/n411.transcript.jsonl") != null);
    try testing.expect(std.mem.indexOf(u8, note, "(2 messages") != null);
    try testing.expect(std.mem.indexOf(u8, note, "grep it") != null);

    // A session whose transcript is not the live one omits the line entirely,
    // rather than citing a path derived from its own name that nothing wrote.
    // With nothing else durable, that leaves no note at all.
    root.session_name = "someone-else";
    try testing.expect((try durableState(a, &root, &.{})) == null);
    try testing.expect(std.mem.indexOf(u8, try summaryRequest(a, &root), ".transcript.jsonl") == null);
}

test "the note names the files modified and the artifacts the discarded history spilled (#411)" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    session_transcript.resetForTest();
    tool_spill.resetForTest();
    defer session_transcript.resetForTest();
    defer tool_spill.resetForTest();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    tool_spill.enable(.{ .io = testing.io, .dir = tmp.dir, .base_abs = "" });

    var snaps = ledger();
    defer snaps.deinit();
    snaps.record("src/a.zig", .absent);
    snaps.record("src/b.zig", .{ .content = "old bytes" });
    snaps.record("src/a.zig", .{ .content = "newer bytes" }); // edited twice, named once
    var root = noteAgent(false);
    root.snapshots = &snaps;

    // A marker written by the REAL spill writer, so the reader is proved against
    // the format that actually ships rather than against a copy of it here.
    const big = try a.alloc(u8, 4096);
    @memset(big, 'x');
    const spill_note: tool_spill.Note = .{ .fallback = "[truncated]", .session = "s411" };
    const marker = spill_note.text(a, big, 1024);
    try testing.expect(std.mem.indexOf(u8, marker, "tool-0.txt") != null); // the spill really happened
    var fco: std.json.ObjectMap = .empty;
    try fco.put(a, "type", .{ .string = "function_call_output" });
    try fco.put(a, "output", .{ .string = marker });
    var discarded = std.json.Array.init(a);
    try discarded.append(try textMessage(a, "user", "run the big one"));
    try discarded.append(.{ .object = fco });

    const note = (try durableState(a, &root, discarded.items)).?;
    try testing.expect(std.mem.indexOf(u8, note, "src/b.zig") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, note, "src/a.zig"));
    try testing.expect(std.mem.indexOf(u8, note, "(2; write_file") != null);
    // The bound is stated, not implied: this ledger cannot see a bash edit.
    try testing.expect(std.mem.indexOf(u8, note, "bash are not tracked") != null);
    // The handle is the artifact PATH, extracted from the marker - not the
    // marker prose, which would be re-pasting the very bytes compaction dropped.
    try testing.expect(std.mem.indexOf(u8, note, "tool-0.txt") != null);
    try testing.expect(std.mem.indexOf(u8, note, "read or grep") == null);
    // A history with no spill in it gets no handle line.
    var plain = std.json.Array.init(a);
    try plain.append(try textMessage(a, "assistant", "the FULL story bytes are at the office"));
    const no_handles = (try durableState(a, &root, plain.items)).?;
    try testing.expect(std.mem.indexOf(u8, no_handles, "spilled to disk") == null);
}

test "a subagent gets no durable-state note, whatever is hung on it (#411)" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    session_transcript.resetForTest();
    defer session_transcript.resetForTest();

    var snaps = ledger();
    defer snaps.deinit();
    snaps.record("src/child.zig", .absent);
    var sub = noteAgent(true);
    sub.snapshots = &snaps;
    sub.session_name = "n411";
    var discarded = std.json.Array.init(a);
    try discarded.append(try textMessage(a, "user", tool_spill.marker_head ++ " — the FULL 9" ++ tool_spill.marker_path_open ++ "/tmp/x.txt" ++ tool_spill.marker_path_close ++ " it]"));
    // A child's history is never persisted and its outputs are never spilled,
    // so every field here would be a claim about state it does not own.
    try testing.expect((try durableState(a, &sub, discarded.items)) == null);
    try testing.expectEqualStrings("BASE", try handoff(a, &sub, "BASE", null, discarded.items));
    // A /review turn shares the Agent struct but not the session's work.
    sub.sub = false;
    sub.review_mode = true;
    try testing.expect((try durableState(a, &sub, discarded.items)) == null);
}

test "the durable-state note rides the new history head, last, and an empty one changes nothing (#411)" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    session_transcript.resetForTest();
    defer session_transcript.resetForTest();

    var root = noteAgent(false);
    // Nothing durable to report: the handoff is byte-identical to the text a
    // plain session has always had.
    try testing.expectEqualStrings("BASE", try handoff(a, &root, "BASE", null, &.{}));

    var snaps = ledger();
    defer snaps.deinit();
    snaps.record("src/z.zig", .absent);
    root.snapshots = &snaps;
    const out = try handoff(a, &root, "BASE", "[standing state: goal]", &.{});
    try testing.expect(std.mem.startsWith(u8, out, "BASE\n\n[standing state: goal]"));
    try testing.expect(std.mem.indexOf(u8, out, "src/z.zig") != null);
    // Ground truth is the LAST thing read before the model continues.
    const standing_at = std.mem.indexOf(u8, out, "[standing state: goal]").?;
    try testing.expect(std.mem.indexOf(u8, out, "durable state, re-derived").? > standing_at);
}
