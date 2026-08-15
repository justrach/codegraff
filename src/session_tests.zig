//! session.zig's tests. The file itself sits at the 600-line cap (#273 needed
//! room there for the save fingerprint and the background-write hand-off), so
//! its unit tests live here and are reached through test_hooks.zig, mirroring
//! goal_persist_tests.zig.
//!
//! The #273 cases at the bottom are the ones that keep the new save path
//! honest: an unchanged conversation must not touch the file at all, ANY change
//! must produce a write, and a queued write must never be lost at shutdown.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const session = @import("session.zig");
const session_writer = @import("session_writer.zig");
// #441: the save path now also appends to the session transcript, and that
// state is per-PROCESS. Every test that reaches saveSessionTo resets it, or the
// digests it holds outlive the testing allocator that owns them.
const session_transcript = @import("session_transcript.zig");
const prompts = @import("prompts.zig");
const protocol_seq = @import("protocol_seq.zig");
const builtin = @import("builtin");
const Agent = agent_mod.Agent;
const util = @import("util.zig");

test "todos round-trip: appendTodosFromValue parses content/status/epoch, skips junk (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const parsed = try std.json.parseFromSliceLeaky(Value, a,
        \\[{"content":"wire epochs","status":"completed","epoch":2},
        \\ {"content":"add test","status":"pending","epoch":2},
        \\ {"status":"orphan, no content"}, 17]
    , .{});
    var todos: std.ArrayList(agent_mod.TodoItem) = .empty;
    try session.appendTodosFromValue(a, &todos, parsed);
    try std.testing.expectEqual(@as(usize, 2), todos.items.len);
    try std.testing.expectEqualStrings("wire epochs", todos.items[0].content);
    try std.testing.expectEqual(@as(u64, 2), todos.items[1].epoch);
    // Legacy sessions (no todos field / wrong type): nothing appended.
    try session.appendTodosFromValue(a, &todos, .null);
    try std.testing.expectEqual(@as(usize, 2), todos.items.len);
    // #394: `retired` round-trips, and its absence means live - a pre-#394
    // session restores an ordinary checklist, not a silently invisible one.
    try std.testing.expect(!todos.items[0].retired);
    const retired = try std.json.parseFromSliceLeaky(Value, a,
        \\[{"content":"the previous ask","status":"completed","epoch":2,"retired":true}]
    , .{});
    try session.appendTodosFromValue(a, &todos, retired);
    try std.testing.expectEqual(@as(usize, 3), todos.items.len);
    try std.testing.expect(todos.items[2].retired);
}

test "goalFromValue: legacy string -> active; object round-trips; paused stays paused (#223)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Legacy bare string -> active, stamped with now_ms (backward compat).
    const legacy = try std.json.parseFromSliceLeaky(Value, a, "\"ship 0.0.202\"", .{ .allocate = .alloc_always });
    const g1 = session.goalFromValue(legacy, 4242).?;
    try std.testing.expectEqualStrings("ship 0.0.202", g1.objective);
    try std.testing.expectEqual(agent_mod.GoalStatus.active, g1.status);
    try std.testing.expectEqual(@as(i64, 4242), g1.created_ms);

    // New object with a paused status round-trips as paused (survives resume).
    const paused = try std.json.parseFromSliceLeaky(Value, a, "{\"objective\":\"land #223\",\"status\":\"paused\",\"created_ms\":10,\"updated_ms\":20}", .{ .allocate = .alloc_always });
    const g2 = session.goalFromValue(paused, 999).?;
    try std.testing.expectEqualStrings("land #223", g2.objective);
    try std.testing.expectEqual(agent_mod.GoalStatus.paused, g2.status);
    try std.testing.expectEqual(@as(i64, 10), g2.created_ms);
    try std.testing.expectEqual(@as(i64, 20), g2.updated_ms);

    // Empty string -> null (no goal).
    const empty = try std.json.parseFromSliceLeaky(Value, a, "\"\"", .{ .allocate = .alloc_always });
    try std.testing.expect(session.goalFromValue(empty, 1) == null);

    // An unknown status string falls back to active (forward-compat with future variants).
    const unknown = try std.json.parseFromSliceLeaky(Value, a, "{\"objective\":\"x\",\"status\":\"zzz\"}", .{ .allocate = .alloc_always });
    try std.testing.expectEqual(agent_mod.GoalStatus.active, session.goalFromValue(unknown, 1).?.status);
}

test "slugifyTitle makes a filesystem-safe slug from an AI title" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("fixing-the-login-bug", session.slugifyTitle(a, "Fixing the login bug"));
    try std.testing.expectEqualStrings("add-dark-mode", session.slugifyTitle(a, "Add dark mode!!"));
    try std.testing.expectEqualStrings("planning-v2", session.slugifyTitle(a, "  Planning — v2  ")); // trim + collapse
    try std.testing.expectEqualStrings("", session.slugifyTitle(a, "🎉 ✨")); // symbol-only → "" (keeps the session-<ts> name)
}

test "hasMeaningfulState gates the blank-draft write (#184)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Only the fields hasMeaningfulState reads are set; the rest stay untouched.
    var root: Agent = undefined;
    root.goal = null;
    root.todos = .empty;
    root.tools_used = .{};
    root.messages = std.json.Array.init(arena);

    // Truly blank: no user turn, no goal, no todos, no tools → not persisted.
    try std.testing.expect(!session.hasMeaningfulState(&root));

    // A standing /goal alone is meaningful (goal-only sessions are still saved).
    root.goal = .{ .objective = "ship the release" };
    try std.testing.expect(session.hasMeaningfulState(&root));

    // One user message alone is meaningful.
    root.goal = null;
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "role", .{ .string = "user" });
    try obj.put(arena, "content", .{ .string = "hi" });
    try root.messages.append(.{ .object = obj });
    try std.testing.expect(session.hasMeaningfulState(&root));
}

// ── #273: the save path itself ────────────────────────────────────────────

const Fixture = struct {
    client: std.http.Client,
    root: Agent,
};

/// A root agent with a one-turn conversation — enough state that saveSession
/// considers it worth persisting (#184). Every field the save path reads is
/// set explicitly; nothing is left `undefined`.
fn fixture(gpa: Allocator, arena: Allocator, io: Io) !*Fixture {
    const f = try gpa.create(Fixture);
    f.client = .{ .allocator = gpa, .io = io };
    var msgs = std.json.Array.init(arena);
    var user: std.json.ObjectMap = .empty;
    try user.put(arena, "role", .{ .string = "user" });
    try user.put(arena, "content", .{ .string = "first prompt" });
    try msgs.append(.{ .object = user });
    f.root = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = &f.client,
        .provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 100_000 },
        .messages = msgs,
        .sub = false,
        .label = "root",
        .out = null,
        .session_title = "persistence test",
    };
    return f;
}

fn appendTurn(arena: Allocator, root: *Agent, text: []const u8) !void {
    var m: std.json.ObjectMap = .empty;
    try m.put(arena, "role", .{ .string = "assistant" });
    try m.put(arena, "content", .{ .string = text });
    try root.messages.append(.{ .object = m });
}

fn readSaved(dir: Io.Dir, gpa: Allocator) ![]u8 {
    return dir.readFileAlloc(std.testing.io, ".graff/sessions/wf.session.json", gpa, .limited(64 * 1024));
}

test "an unchanged conversation skips the save entirely (#273)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    session_writer.resetForTest();
    defer session_writer.resetForTest();
    session_transcript.resetForTest();
    defer session_transcript.resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try fixture(gpa, arena, io);
    defer gpa.destroy(f);

    try session.saveSessionTo(&f.root, arena, tmp.dir, "wf");
    session.flushSaves();
    const first = try readSaved(tmp.dir, gpa);
    defer gpa.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "first prompt") != null);
    try std.testing.expectEqual(@as(usize, 1), session_writer.stats().writes);

    // Nothing changed and nothing touched the file: the save is skipped whole.
    // The write counter is the proof — not that the bytes match (they would
    // even if we had re-serialized and rewritten them), but that no write
    // happened at all.
    try session.saveSessionTo(&f.root, arena, tmp.dir, "wf");
    session.flushSaves();
    try std.testing.expectEqual(@as(usize, 1), session_writer.stats().writes);
}

test "the skip never fires over a session file something else rewrote (#273/#289)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    session_writer.resetForTest();
    defer session_writer.resetForTest();
    session_transcript.resetForTest();
    defer session_transcript.resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try fixture(gpa, arena, io);
    defer gpa.destroy(f);
    try session.saveSessionTo(&f.root, arena, tmp.dir, "wf");
    session.flushSaves();

    // A second graff resumed on the same name writes its own snapshot over
    // ours — the advisory lock is only held during the write, so this lands.
    // Our next save (the exit save, or a /save with nothing new since the last
    // turn) must NOT skip on "we already wrote this state": the file no longer
    // holds our conversation, and a skip would silently drop every turn we have.
    try tmp.dir.writeFile(io, .{ .sub_path = ".graff/sessions/wf.session.json", .data = "{\"messages\":[\"the other graff\"]}" });
    try session.saveSessionTo(&f.root, arena, tmp.dir, "wf");
    session.flushSaves();
    const repaired = try readSaved(tmp.dir, gpa);
    defer gpa.free(repaired);
    try std.testing.expect(std.mem.indexOf(u8, repaired, "first prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, repaired, "the other graff") == null);
    try std.testing.expectEqual(@as(usize, 2), session_writer.stats().writes);
}

test "any change to the conversation produces a save (#273)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    session_writer.resetForTest();
    defer session_writer.resetForTest();
    session_transcript.resetForTest();
    defer session_transcript.resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try fixture(gpa, arena, io);
    defer gpa.destroy(f);
    try session.saveSessionTo(&f.root, arena, tmp.dir, "wf");
    session.flushSaves();

    // A new turn.
    try appendTurn(arena, &f.root, "the reply");
    try session.saveSessionTo(&f.root, arena, tmp.dir, "wf");
    session.flushSaves();
    const two = try readSaved(tmp.dir, gpa);
    defer gpa.free(two);
    try std.testing.expect(std.mem.indexOf(u8, two, "the reply") != null);
    try std.testing.expectEqual(@as(usize, 2), session_writer.stats().writes);

    // An IN-PLACE rewrite of an existing message (what compaction and the
    // tool-output truncator do): the message count is unchanged, and the save
    // must still happen.
    try f.root.messages.items[1].object.put(arena, "content", .{ .string = "compacted" });
    try session.saveSessionTo(&f.root, arena, tmp.dir, "wf");
    session.flushSaves();
    const three = try readSaved(tmp.dir, gpa);
    defer gpa.free(three);
    try std.testing.expect(std.mem.indexOf(u8, three, "compacted") != null);
    try std.testing.expectEqual(@as(usize, 3), session_writer.stats().writes);

    // State outside the history counts too (a /rename here).
    f.root.session_title = "renamed";
    try session.saveSessionTo(&f.root, arena, tmp.dir, "wf");
    session.flushSaves();
    try std.testing.expectEqual(@as(usize, 4), session_writer.stats().writes);
}

test "a turn's queued save is not lost when the session ends (#273)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    session_writer.resetForTest();
    defer session_writer.resetForTest();
    session_transcript.resetForTest();
    defer session_transcript.resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const f = try fixture(gpa, arena, io);
    defer gpa.destroy(f);

    // Hold the writer so the save is provably still queued, exactly as it can
    // be when the loop is about to return.
    session_writer.setPausedForTest(io, true);
    try appendTurn(arena, &f.root, "the last thing the model said");
    try session.saveSessionTo(&f.root, arena, tmp.dir, "wf");
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, ".graff/sessions/wf.session.json", .{}));

    // What mainloop.run defers and finalizeSession repeats.
    session_writer.setPausedForTest(io, false);
    session.flushSaves();
    const saved = try readSaved(tmp.dir, gpa);
    defer gpa.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "the last thing the model said") != null);
}

test "the autosave is where the transcript sees a new message (#441)" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    session_writer.resetForTest();
    defer session_writer.resetForTest();
    session_transcript.resetForTest();
    defer session_transcript.resetForTest();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const f = try fixture(gpa, arena, io);
    defer gpa.destroy(f);
    try session.saveSessionTo(&f.root, arena, tmp.dir, "wf");
    try appendTurn(arena, &f.root, "the reply");
    try session.saveSessionTo(&f.root, arena, tmp.dir, "wf");
    session.flushSaves();

    // The real save path wrote the transcript beside the session file, one line
    // per message, with no hook of its own at any of the history's mutation
    // sites. #411's note gets the path from the accessor, not by rebuilding it,
    // and the assertion goes through that accessor rather than a hand-written
    // separator: the path is forward-slashed on every platform by design
    // (session_index.zig), but what matters here is that it names a real file.
    f.root.session_name = "wf";
    const path = session_transcript.activePath(&f.root, arena) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("wf.transcript.jsonl", std.fs.path.basename(path));
    const lines = try tmp.dir.readFileAlloc(io, path, gpa, .limited(64 * 1024));
    defer gpa.free(lines);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, lines, "\n"));
    try std.testing.expectEqual(@as(usize, 2), session_transcript.lineCount());
    try std.testing.expect(std.mem.indexOf(u8, lines, "first prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines, "the reply") != null);

    // An unchanged conversation skips the save whole (#273), and therefore the
    // transcript too: a repeated autosave never re-appends a message.
    try session.saveSessionTo(&f.root, arena, tmp.dir, "wf");
    session.flushSaves();
    try std.testing.expectEqual(@as(usize, 2), session_transcript.lineCount());
}

test "cache_key round-trips: parsed on load, garbage and absence rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const good = try std.json.parseFromSliceLeaky(Value, a,
        \\{"cache_key":"00000000-0000-4000-8000-000000000000"}
    , .{});
    try std.testing.expectEqualStrings("00000000-0000-4000-8000-000000000000", session.cacheKeyFromSession(good.object).?);
    // Legacy sessions (no field), wrong types, and non-UUID strings all read
    // as absent: the resume then mints a fresh key, exactly as before.
    const legacy = try std.json.parseFromSliceLeaky(Value, a, "{}", .{});
    try std.testing.expect(session.cacheKeyFromSession(legacy.object) == null);
    const short = try std.json.parseFromSliceLeaky(Value, a,
        \\{"cache_key":"short"}
    , .{});
    try std.testing.expect(session.cacheKeyFromSession(short.object) == null);
    const wrong_type = try std.json.parseFromSliceLeaky(Value, a,
        \\{"cache_key":42}
    , .{});
    try std.testing.expect(session.cacheKeyFromSession(wrong_type.object) == null);
}

test "session context meter restores hidden delta and legacy sessions re-estimate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const current = try std.json.parseFromSliceLeaky(Value, a, "{\"context_tokens\":90000,\"context_local_tokens\":20000}", .{});
    try std.testing.expectEqual(@as(u64, 90_000), session.contextTokensFromSession(current.object));
    try std.testing.expectEqual(@as(u64, 20_000), session.contextLocalTokensFromSession(current.object).?);
    const legacy = try std.json.parseFromSliceLeaky(Value, a, "{}", .{});
    try std.testing.expectEqual(@as(u64, 0), session.contextTokensFromSession(legacy.object));
    try std.testing.expect(session.contextLocalTokensFromSession(legacy.object) == null);
    const invalid = try std.json.parseFromSliceLeaky(Value, a, "{\"context_tokens\":-1}", .{});
    try std.testing.expectEqual(@as(u64, 0), session.contextTokensFromSession(invalid.object));
    const invalid_local = try std.json.parseFromSliceLeaky(Value, a, "{\"context_local_tokens\":-1}", .{});
    try std.testing.expect(session.contextLocalTokensFromSession(invalid_local.object) == null);

    // Model a resumed Responses history whose compact encrypted-reasoning handle
    // serializes much smaller than the authoritative server token reading.
    var msgs = std.json.Array.init(a);
    const reasoning = "{\"type\":\"reasoning\",\"encrypted_content\":\"" ++ util.repeatBytes("x", 8192) ++ "\"}";
    try msgs.append(try std.json.parseFromSliceLeaky(Value, a, reasoning, .{}));
    var root: Agent = undefined;
    root.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 100_000 };
    root.messages = msgs;
    root.sub = false;
    root.strict = false;
    root.sys_normal = "";
    root.sys_strict = "";
    root.tools_responses = "";
    root.last_cache_read = 12_345;

    const local_estimate = root.fullRequestEstimateTokens();
    try std.testing.expect(local_estimate < 90_000);
    session.restoreContextMeter(&root, session.contextTokensFromSession(current.object), session.contextLocalTokensFromSession(current.object));
    try std.testing.expectEqual(local_estimate + 70_000, root.last_context_tokens);
    try std.testing.expectEqual(@as(u64, 0), root.last_cache_read);
    try std.testing.expect(root.last_context_tokens > local_estimate);

    // A legitimate over-window reading remains evidence when its paired local
    // estimate matches the current request.
    session.restoreContextMeter(&root, 150_000, local_estimate);
    try std.testing.expectEqual(@as(u64, 150_000), root.last_context_tokens);

    // An unknown window still preserves the paired hidden delta; no clamping is
    // needed or safe.
    root.provider.context = 0;
    session.restoreContextMeter(&root, 90_000, local_estimate);
    try std.testing.expectEqual(root.fullRequestEstimateTokens() + (90_000 - local_estimate), root.last_context_tokens);
    root.provider.context = 100_000;

    // A legacy session has no saved meter, but non-empty restored history must
    // still produce a live local reading rather than resetting to zero.
    root.last_cache_read = 99;
    session.restoreContextMeter(&root, session.contextTokensFromSession(legacy.object), session.contextLocalTokensFromSession(legacy.object));
    try std.testing.expectEqual(local_estimate, root.last_context_tokens);
    try std.testing.expectEqual(@as(u64, 0), root.last_cache_read);

    // A meter from an intermediate build without the paired local component is
    // also ungrounded and must not force destructive recovery after resume.
    const unpaired = try std.json.parseFromSliceLeaky(Value, a, "{\"context_tokens\":99000}", .{});
    session.restoreContextMeter(&root, session.contextTokensFromSession(unpaired.object), session.contextLocalTokensFromSession(unpaired.object));
    try std.testing.expectEqual(local_estimate, root.last_context_tokens);
}

test "event_seq round-trips so a replacement graff continues the sequence (#330)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const saved = try std.json.parseFromSliceLeaky(Value, a, "{\"event_seq\":41}", .{});
    try std.testing.expectEqual(@as(u64, 41), session.eventSeqFromSession(saved.object));
    // Legacy sessions and corrupt values leave the live counter alone.
    const legacy = try std.json.parseFromSliceLeaky(Value, a, "{}", .{});
    try std.testing.expectEqual(@as(u64, 0), session.eventSeqFromSession(legacy.object));
    const bad = try std.json.parseFromSliceLeaky(Value, a, "{\"event_seq\":-3}", .{});
    try std.testing.expectEqual(@as(u64, 0), session.eventSeqFromSession(bad.object));

    protocol_seq.resetForTest();
    defer protocol_seq.resetForTest();
    protocol_seq.restore(session.eventSeqFromSession(saved.object));
    try std.testing.expectEqual(@as(u64, 42), protocol_seq.next()); // no id is ever reissued
    protocol_seq.restore(session.eventSeqFromSession(legacy.object));
    try std.testing.expectEqual(@as(u64, 43), protocol_seq.next());
}

test "#453: renameSession re-arms the transcript line to the live session file" {
    if (builtin.os.tag == .windows) return;
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    session_writer.resetForTest();
    defer session_writer.resetForTest();
    session_transcript.resetForTest();
    defer session_transcript.resetForTest();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var orig_dir = try Io.Dir.cwd().openDir(io, ".", .{});
    defer orig_dir.close(io);
    defer _ = std.posix.system.fchdir(orig_dir.handle);
    if (std.posix.system.fchdir(tmp.dir.handle) != 0) return error.ChdirFailed;

    const f = try fixture(gpa, arena, io);
    defer gpa.destroy(f);
    f.root.session_name = "session-1234567890";
    prompts.g_session_compacted = true;
    defer {
        prompts.g_session_compacted = false;
        prompts.armSessionTranscript(arena, "", .{}, false);
    }
    prompts.armSessionTranscript(arena, f.root.session_name, .{ .local_tools = true }, true);
    try prompts.setSystemPrompts(&f.root, "BASE", arena);
    try std.testing.expect(std.mem.indexOf(u8, f.root.sys_normal, "session-1234567890") != null);

    session.renameSession(&f.root, arena, "hello-world");
    try std.testing.expectEqualStrings("hello-world", f.root.session_name);
    const after = prompts.transcriptNoteForTest();
    try std.testing.expect(std.mem.indexOf(u8, after, "hello-world") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "session-1234567890") == null);
    // Production apply() never calls setSystemPrompts after renameSession.
    // sys_normal must already name the live file.
    try std.testing.expect(std.mem.indexOf(u8, f.root.sys_normal, "hello-world") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.root.sys_normal, "session-1234567890") == null);
}
