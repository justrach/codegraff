//! Tests for the #391 note turn's PRODUCTION entry point and for the claim
//! that makes the whole feature worth having: the note is state, not
//! conversation, so destroying the history cannot destroy the note.
//!
//! WHAT IS NOT COVERED, stated plainly. `maybeWrite`'s `.fire` branch issues a
//! real provider request, which a unit test cannot drive — so every case here
//! exercises a REFUSAL through the real entry point, plus the gate that would
//! have admitted the call. The request itself, and the model's reply, are
//! covered only by the shapes it borrows wholesale from playbook_reflect
//! (a throwaway agent, no tools) and compact() (a container-deep history
//! clone in a throwaway arena).

const std = @import("std");
const Io = std.Io;

const Agent = @import("agent.zig").Agent;
const compact_note = @import("compact_note.zig");
const glue = @import("compact_note_glue.zig");
const messages_mod = @import("messages.zig");
const prompts = @import("prompts.zig");
const run_budget = @import("run_budget.zig");

fn inScratch(comptime body: fn (Io, std.mem.Allocator) anyerror!void) !void {
    if (@import("builtin").os.tag == .windows) return;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var orig = try Io.Dir.cwd().openDir(io, ".", .{});
    defer orig.close(io);
    defer _ = std.posix.system.fchdir(orig.handle);
    if (std.posix.system.fchdir(tmp.dir.handle) != 0) return error.ChdirFailed;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try body(io, arena_state.allocator());
}

/// An agent with exactly the fields the gate reads. `provider`/`client` stay
/// undefined on purpose: a case that reached them would be a case that made a
/// network call, and none of these may.
fn stub(arena: std.mem.Allocator, budget: *run_budget.RunBudget) Agent {
    return .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = null,
        .session_name = "last",
        .run_budget = budget,
    };
}

test "maybeWrite (#391): a WORKER is refused at the production entry point, before anything is measured" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var budget: run_budget.RunBudget = .{ .max_model_calls = 0 }; // unlimited: budget is not the reason
    var agent = stub(arena_state.allocator(), &budget);
    agent.sub = true;
    // Reaching a network call here would fault on `provider`/`client`, so a
    // pass is itself the proof that no request was attempted.
    try std.testing.expectEqual(compact_note.Decision.skip_worker, glue.maybeWrite(&agent));
    try std.testing.expect(agent.precompact_note_gen == null); // nothing latched either
}

test "maybeWrite (#391): the other refusals also come back named, and none of them writes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // No durable session: nothing would read the note back.
    var unlimited: run_budget.RunBudget = .{ .max_model_calls = 0 };
    var homeless = stub(arena, &unlimited);
    homeless.session_name = "";
    try std.testing.expectEqual(compact_note.Decision.skip_no_session, glue.maybeWrite(&homeless));

    // This history generation already has a note; a retried compaction of the
    // same unchanged history must not buy a second one.
    var noted = stub(arena, &unlimited);
    noted.history_rewrites = 7;
    noted.precompact_note_gen = 7;
    try std.testing.expectEqual(compact_note.Decision.skip_already, glue.maybeWrite(&noted));

    // The pool is down to #390's landing reserve: those calls belong to
    // landing and narrating the work, and the note is junior to both.
    var tight: run_budget.RunBudget = .{ .max_model_calls = 30 };
    tight.model_calls = .init(30);
    var broke = stub(arena, &tight);
    try std.testing.expectEqual(compact_note.Decision.skip_budget, glue.maybeWrite(&broke));
    try std.testing.expect(broke.precompact_note_gen == null);

    // And the case that WOULD fire, proven at the gate rather than by making
    // the call: a root, with a session, on a fresh generation, in budget.
    var ready = stub(arena, &unlimited);
    try std.testing.expectEqual(compact_note.Decision.fire, glue.gateCalls(&ready));
}

test "#391: the note is STATE — a wiped history cannot touch it, and it re-injects verbatim" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            // Arm the injection for this session and disarm on the way out:
            // every other test in the suite relies on the funnel staying a
            // pure string function with an `undefined` Io.
            prompts.armCompactNotes("last");
            defer prompts.armCompactNotes("");

            var budget: run_budget.RunBudget = .{ .max_model_calls = 0 };
            var agent = stub(arena, &budget);
            agent.messages = std.json.Array.init(arena);
            try agent.messages.append(try messages_mod.textMessage(arena, "user", "please finish the retry ladder"));
            try agent.messages.append(try messages_mod.textMessage(arena, "assistant", "on it — reading agent_request.zig"));

            const note =
                \\SUBGOAL: finish the retry ladder in agent_request.zig
                \\ANCHORS: src/agent_request.zig:273, src/provider.zig:137
                \\DECISIONS: Retry-After over exponential backoff — the gateway sends it
                \\DEAD ENDS: closeCodexWs before the trim wedges the chain
            ;
            // The same store call maybeWrite makes once the model has replied.
            try std.testing.expect(compact_note.record(io, arena, "last", 0, note));

            try prompts.setSystemPrompts(&agent, "ROOT-BASE", arena);
            const before = try arena.dupe(u8, agent.sys_normal);
            try std.testing.expect(std.mem.indexOf(u8, before, "ROOT-BASE") != null);
            try std.testing.expect(std.mem.indexOf(u8, before, compact_note.header) != null);
            try std.testing.expect(std.mem.indexOf(u8, before, note) != null); // verbatim, every line

            // Now do the worst thing compaction can possibly do: replace the
            // entire conversation with a summary that mentions none of it.
            agent.messages = std.json.Array.init(arena);
            try agent.messages.append(try messages_mod.textMessage(arena, "user",
                \\Context: the earlier conversation was compacted to save space.
                \\Summary of the earlier work: the user asked for some changes.
            ));
            agent.history_rewrites += 1;

            // The note was never in the history, so there was nothing there to
            // summarize away.
            for (agent.messages.items) |m| {
                const c = m.object.get("content").?;
                try std.testing.expect(std.mem.indexOf(u8, c.string, "DEAD ENDS") == null);
            }

            // And the next prompt the model sees carries it back BYTE-FOR-BYTE:
            // deterministic re-injection, no summarizer in the path.
            try prompts.setSystemPrompts(&agent, "ROOT-BASE", arena);
            try std.testing.expectEqualStrings(before, agent.sys_normal);
            try std.testing.expect(std.mem.indexOf(u8, agent.sys_normal, note) != null);
            // Exactly one copy — recomposition replaces the block, never stacks it.
            try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, agent.sys_normal, compact_note.header));

            // The strict/ultra variants carry it too, so /strict and /ultracode
            // cannot be a way to lose it.
            for ([_][]const u8{ agent.sys_strict, agent.sys_ultra, agent.sys_ultra_strict }) |v|
                try std.testing.expect(std.mem.indexOf(u8, v, "DEAD ENDS: closeCodexWs") != null);
            // The BASE is remembered unpolluted, so the next refresh composes
            // from it rather than stacking a second block on the first.
            try std.testing.expectEqualStrings("ROOT-BASE", agent.sys_base);
        }
    }.body);
}

test "#391: a session with no note pays nothing, armed or not" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            _ = io;
            prompts.armCompactNotes("last");
            defer prompts.armCompactNotes("");
            var budget: run_budget.RunBudget = .{ .max_model_calls = 0 };
            var agent = stub(arena, &budget);
            agent.messages = std.json.Array.init(arena);
            try prompts.setSystemPrompts(&agent, "ROOT-BASE", arena);
            try std.testing.expectEqualStrings("ROOT-BASE", agent.sys_normal);
        }
    }.body);
}
