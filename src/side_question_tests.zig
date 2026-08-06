//! side_question.zig's tests (#415). A separate file for the 600-line cap,
//! mirroring compact_note_glue_tests.zig, and hooked from test_hooks.zig —
//! side_question.zig itself is reached in production from commands_misc, but
//! nothing references THIS file, which is what would make its tests compile to
//! nothing and still report green (AGENTS.md).
//!
//! WHAT IS NOT COVERED, stated plainly: `ask` issues a real provider request,
//! which a unit test cannot drive. Everything up to and including the exact
//! bytes that request would put on the wire IS covered, through the same
//! `build` the production path calls; so is everything after it that could
//! touch the session. The refusal path is driven through the real `command`
//! entry point with `provider`/`client` undefined, so a pass there is itself
//! the proof that no call was attempted.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const Provider = @import("provider.zig").Provider;
const messages_mod = @import("messages.zig");
const pricing = @import("pricing.zig");
const session = @import("session.zig");
const session_transcript = @import("session_transcript.zig");
const session_writer = @import("session_writer.zig");
const side_question = @import("side_question.zig");

const question = "btw, what did that linker error actually mean?";

fn provider(kind: Provider.Kind) Provider {
    return .{
        .id = switch (kind) {
            .anthropic => "anthropic",
            .openai => "openai",
            .responses => "codex",
        },
        .kind = kind,
        .auth = .bearer,
        .url = "",
        .api_key = "",
        .model = "test-model",
        .context = 200_000,
    };
}

/// A root mid-conversation: two messages the side question must be able to see.
/// `client` stays undefined — nothing here may reach the network.
fn root(arena: Allocator, kind: Provider.Kind) !Agent {
    var msgs = std.json.Array.init(arena);
    try msgs.append(try messages_mod.textMessage(arena, "user", "build it"));
    try msgs.append(try messages_mod.textMessage(arena, "assistant", "undefined symbol _graff_main"));
    return .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = provider(kind),
        .messages = msgs,
        .sub = false,
        .label = "root",
        .out = null,
        .session_name = "btw",
        .sys_normal = "ROOT-BASE",
        .sys_strict = "ROOT-BASE-STRICT",
        .tools_anthropic = "[{\"name\":\"bash\"}]",
        .tools_openai = "[{\"name\":\"bash\"}]",
        .tools_responses = "[{\"name\":\"bash\"}]",
    };
}

fn serialize(arena: Allocator, msgs: std.json.Array) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(Value{ .array = msgs });
    return aw.writer.buffered();
}

test "/btw (#415): the side request carries the live context and the question, with NO tools" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Every wire format, because "no tools" is written three times in buildBody
    // and a fourth caller getting one of them wrong is exactly how a `/btw`
    // would quietly grow the ability to edit files.
    for ([_]Provider.Kind{ .anthropic, .openai, .responses }) |kind| {
        var r = try root(arena, kind);
        var agent = try side_question.build(&r, arena, question);
        defer agent.tools_used.deinit(std.testing.allocator);
        const body = try agent.buildBody(null, false, false, false);
        defer std.testing.allocator.free(body);

        // The answer is produced FROM the existing context: the conversation so
        // far is in the request, with the question appended after it.
        try std.testing.expect(std.mem.indexOf(u8, body, "undefined symbol _graff_main") != null);
        const asked = std.mem.indexOf(u8, body, "what did that linker error") orelse
            return error.TestUnexpectedResult;
        try std.testing.expect(asked > std.mem.indexOf(u8, body, "undefined symbol _graff_main").?);

        // No toolset, and not an empty one either — the key is absent.
        try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"bash\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, body, "tool_choice") == null);
        try std.testing.expect(agent.text_only); // and runTurn could not add any

        // The root's own prompt, plus the note that says why this turn is odd.
        try std.testing.expect(std.mem.indexOf(u8, body, "ROOT-BASE") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "You have NO tools on this turn") != null);
        // It is a subagent for every root-only path, the transcript included.
        try std.testing.expect(agent.sub);
    }
}

test "/btw (#415): root.messages is byte-identical before and after, and the clone is deep" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var r = try root(arena, .anthropic);
    const before = try serialize(arena, r.messages);
    const before_len = r.messages.items.len;

    var agent = try side_question.build(&r, arena, question);
    defer agent.tools_used.deinit(std.testing.allocator);

    // Do to the clone everything a real request does to a history: append (the
    // question is already one; #390's landing note is another) and rewrite an
    // existing message in place, which is what capOversizedToolOutputs does.
    try agent.messages.append(try messages_mod.textMessage(arena, "assistant", "it means the entry point was renamed"));
    try agent.messages.items[1].object.put(arena, "content", .{ .string = "TRUNCATED BY THE SIDE REQUEST" });

    try std.testing.expectEqual(before_len, r.messages.items.len);
    try std.testing.expectEqualStrings(before, try serialize(arena, r.messages));
    // Not merely equal — the in-place rewrite above proves the clone does not
    // share the ObjectMaps, which a shallow array copy would.
    try std.testing.expect(std.mem.indexOf(u8, before, "undefined symbol _graff_main") != null);
}

test "/btw (#415): neither the session file nor the append-only transcript sees the exchange" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Both are per-PROCESS state; a test that reaches saveSessionTo resets them.
    session_writer.resetForTest();
    defer session_writer.resetForTest();
    session_transcript.resetForTest();
    defer session_transcript.resetForTest();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    var r = try root(arena, .anthropic);
    r.client = &client;

    // The conversation as it stands, through the REAL save path — which is also
    // the only place the transcript ever observes a message (#441).
    try session.saveSessionTo(&r, arena, tmp.dir, "btw");
    session.flushSaves();
    const transcript_path = session_transcript.activePath(&r, arena) orelse
        return error.TestUnexpectedResult;
    const saved_before = try tmp.dir.readFileAlloc(io, ".graff/sessions/btw.session.json", gpa, .limited(64 * 1024));
    defer gpa.free(saved_before);
    const lines_before = try tmp.dir.readFileAlloc(io, transcript_path, gpa, .limited(64 * 1024));
    defer gpa.free(lines_before);
    const count_before = session_transcript.lineCount();
    const writes_before = session_writer.stats().writes;

    // Now the whole side exchange, in its own arena exactly as `ask` runs it:
    // the question goes in, the model's answer comes back, and the arena dies.
    {
        var side_arena = std.heap.ArenaAllocator.init(gpa);
        defer side_arena.deinit();
        const sa = side_arena.allocator();
        var agent = try side_question.build(&r, sa, question);
        defer agent.tools_used.deinit(gpa);
        try agent.messages.append(try messages_mod.textMessage(sa, "assistant", "SIDE ANSWER: the entry point was renamed"));
        try std.testing.expectEqual(@as(usize, 4), agent.messages.items.len); // it happened
    }

    // The next autosave is the moment either path could leak it. Neither does:
    // there is nothing new in `root.messages`, so #273 skips the write whole and
    // the transcript is never even consulted.
    try session.saveSessionTo(&r, arena, tmp.dir, "btw");
    session.flushSaves();

    // The transcript first, because it is the path that cannot be undone: it is
    // append-only, so a line written here stays written.
    const lines_after = try tmp.dir.readFileAlloc(io, transcript_path, gpa, .limited(64 * 1024));
    defer gpa.free(lines_after);
    try std.testing.expectEqualStrings(lines_before, lines_after);
    try std.testing.expectEqual(count_before, session_transcript.lineCount());

    const saved_after = try tmp.dir.readFileAlloc(io, ".graff/sessions/btw.session.json", gpa, .limited(64 * 1024));
    defer gpa.free(saved_after);
    try std.testing.expectEqualStrings(saved_before, saved_after);
    // And the save was not merely idempotent — #273 skipped the write whole,
    // because nothing in `root.messages` had changed for it to write.
    try std.testing.expectEqual(writes_before, session_writer.stats().writes);

    // And neither file ever held a word of it, which is the claim the byte
    // comparison alone would still allow if the FIRST save had leaked it.
    for ([_][]const u8{ saved_after, lines_after }) |text| {
        try std.testing.expect(std.mem.indexOf(u8, text, "linker error") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "SIDE ANSWER") == null);
        try std.testing.expect(std.mem.indexOf(u8, text, "side question") == null);
    }
    // The conversation itself is still there — this is a no-leak test, not a
    // test that the session file happens to be empty.
    try std.testing.expect(std.mem.indexOf(u8, lines_after, "undefined symbol _graff_main") != null);
}

test "/btw (#415): the side turn's usage lands in the tally the [usage] footer prints" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var r = try root(arena, .anthropic);
    var agent = try side_question.build(&r, arena, question);
    defer agent.tools_used.deinit(std.testing.allocator);

    // Not persisting the exchange is not a reason to hide what it cost: the
    // side agent banks through the same recordUsage every other request does,
    // into the same process-wide tally /cost and the [usage] footer render.
    const before = pricing.g_cost.snap(io);
    var usage: std.json.ObjectMap = .empty;
    try usage.put(arena, "input_tokens", .{ .integer = 1200 });
    try usage.put(arena, "output_tokens", .{ .integer = 40 });
    var response: std.json.ObjectMap = .empty;
    try response.put(arena, "usage", .{ .object = usage });
    agent.recordUsage(response, 4800);
    const after = pricing.g_cost.snap(io);

    try std.testing.expectEqual(before.api_calls + 1, after.api_calls);
    try std.testing.expectEqual(before.in_tokens + 1200, after.in_tokens);
    try std.testing.expectEqual(before.out_tokens + 40, after.out_tokens);
}

test "/btw (#415): an empty question is refused cleanly, without a model call" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("why did that fail?", side_question.questionFromLine("/btw why did that fail?").?);
    try std.testing.expectEqualStrings("why?", side_question.questionFromLine("/btw    why?   ").?);
    try std.testing.expect(side_question.questionFromLine("/btw") == null);
    try std.testing.expect(side_question.questionFromLine("/btw   ") == null);
    // Not a /btw line at all: the chain must fall through to the next handler.
    try std.testing.expect(!side_question.isCommand("/btwixt"));
    try std.testing.expect(!side_question.isCommand("btw, what?"));
    try std.testing.expect(side_question.isCommand("/btw"));

    var r = try root(arena, .anthropic);
    r.client = undefined;
    r.provider = undefined; // a request from here would fault
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    // Handled (so it is not reported as an unknown command) but not asked.
    try std.testing.expect(try side_question.command(&r, arena, "/btw   ", &aw.writer));
    try std.testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "/btw <question>") != null);
    try std.testing.expectEqual(@as(usize, 2), r.messages.items.len); // and nothing appended

    // A line that is not ours is declined without printing anything.
    aw.clearRetainingCapacity();
    try std.testing.expect(!try side_question.command(&r, arena, "/btwixt", &aw.writer));
    try std.testing.expectEqual(@as(usize, 0), aw.writer.buffered().len);
}
