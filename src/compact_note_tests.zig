//! Tests for the #391 pre-compaction note store, its gate ladder, and its
//! injection block. Reached through the `test { _ = @import(...) }` hook at
//! the bottom of compact_note.zig.
//!
//! Everything that touches the store FILE goes through a real
//! createFile/read round trip in a scratch cwd rather than a hand-built
//! string: the entire claim of #391 is that the note outlives the history
//! that produced it, and a test that never serializes cannot show that.

const std = @import("std");
const Io = std.Io;

const compact_note = @import("compact_note.zig");
const phase_budget = @import("phase_budget.zig");

/// Same fchdir scratch harness playbook_tests.zig uses, and for the same
/// reason: the store takes no Dir parameter.
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

/// A budget that comfortably clears the landing reserve, so the call gate is
/// never the reason a case below skips.
const rich_cap: u64 = 100;
const rich_remaining: u64 = 100;

fn baseInputs() compact_note.Inputs {
    return .{
        .sub = false,
        .session_name = "last",
        .history_rewrites = 0,
        .last_written = null,
        .cap = rich_cap,
        .remaining = rich_remaining,
    };
}

const window: u64 = 200_000;

/// The band the note is FOR: over compact@ (80%, where compaction fires) but
/// under nearContextLimit (95%, where the harness starts salvaging). The codex
/// PTY scenario sits here on purpose — see codex_ws_test.py's own comment,
/// "Cross compact@ (80%) but stay below the destructive recovery boundary".
fn plannedRollover() compact_note.Context {
    return .{
        .window_tokens = window,
        .effective_tokens = window * 9 / 10, // 90%
        .over_window_rejection = false,
        .near_limit = false,
    };
}

test "decide (#391): fires exactly once when compaction is imminent, and not otherwise" {
    // The one case that fires: a root, with a session, on a planned rollover,
    // with budget and window headroom.
    try std.testing.expectEqual(compact_note.Decision.fire, compact_note.decide(baseInputs(), plannedRollover()));

    // ONCE: the same history generation never buys a second note, however
    // often compaction is retried after a transient failure (#379's loop).
    var noted = baseInputs();
    noted.last_written = 0;
    try std.testing.expectEqual(compact_note.Decision.skip_already, compact_note.decide(noted, plannedRollover()));
    // …and the NEXT compaction (history_rewrites has advanced) buys one again.
    noted.history_rewrites = 1;
    try std.testing.expectEqual(compact_note.Decision.fire, compact_note.decide(noted, plannedRollover()));

    // No durable session: nothing would ever read the note back.
    var homeless = baseInputs();
    homeless.session_name = "";
    try std.testing.expectEqual(compact_note.Decision.skip_no_session, compact_note.decide(homeless, plannedRollover()));

    // No token buffer left: the tokens have to go to the compaction that must
    // happen regardless.
    var cramped = plannedRollover();
    cramped.effective_tokens = window - compact_note.note_reserve_tokens + 1;
    try std.testing.expectEqual(compact_note.Decision.skip_no_headroom, compact_note.decide(baseInputs(), cramped));
    // Exactly at the buffer boundary still fires — the reserve is what it says.
    cramped.effective_tokens = window - compact_note.note_reserve_tokens;
    try std.testing.expectEqual(compact_note.Decision.fire, compact_note.decide(baseInputs(), cramped));
    // An unknown window cannot prove there is no room, and the summary request
    // this precedes is about to ship the same input anyway.
    var unknown = plannedRollover();
    unknown.window_tokens = 0;
    unknown.effective_tokens = 10_000_000;
    try std.testing.expectEqual(compact_note.Decision.fire, compact_note.decide(baseInputs(), unknown));
}

test "decideContext (#391): a planned rollover buys a note; a SALVAGE never does" {
    // The whole point of this gate. #391 is about a SCHEDULED rollover: context
    // is filling, so spend one call before the window turns over. Once the
    // harness is rescuing a session, that same call is the last thing it can
    // afford — and the token buffer alone would NOT catch it, because at 95%
    // of a 200k window there are still 10k tokens of nominal room.
    try std.testing.expectEqual(compact_note.Decision.fire, compact_note.decideContext(plannedRollover()));

    // The destructive-recovery boundary: compactOrRecover may drop real
    // history here, so this is damage control, not a rollover.
    var rescuing = plannedRollover();
    rescuing.near_limit = true;
    rescuing.effective_tokens = window * 95 / 100;
    try std.testing.expectEqual(compact_note.Decision.skip_recovering, compact_note.decideContext(rescuing));
    // …refused BEFORE the buffer question, which would have said yes. This is
    // the assertion that would fail if the salvage gate were ever folded into
    // the token arithmetic instead of preceding it.
    var buffer_only = rescuing;
    buffer_only.near_limit = false;
    try std.testing.expectEqual(compact_note.Decision.fire, compact_note.decideContext(buffer_only));

    // A concrete provider rejection — the request already bounced off the wall.
    var bounced = plannedRollover();
    bounced.over_window_rejection = true;
    try std.testing.expectEqual(compact_note.Decision.skip_recovering, compact_note.decideContext(bounced));
    // Salvage outranks even an unknown window, which otherwise always fires.
    bounced.window_tokens = 0;
    try std.testing.expectEqual(compact_note.Decision.skip_recovering, compact_note.decideContext(bounced));

    // And salvage is a CONTEXT verdict, not a call-budget one: the ledger is
    // untouched by it, so the two halves stay independently readable.
    try std.testing.expectEqual(compact_note.Decision.fire, compact_note.decideCalls(baseInputs()));
}

test "decide (#391): a WORKER never writes a note, whatever else is true" {
    var worker = baseInputs();
    worker.sub = true;
    // Checked FIRST, so a subagent is refused even in the case that would
    // otherwise fire — and still refused when every other gate would also
    // have refused, which is what makes the ordering observable.
    try std.testing.expectEqual(compact_note.Decision.skip_worker, compact_note.decide(worker, plannedRollover()));
    try std.testing.expectEqual(compact_note.Decision.skip_worker, compact_note.decideCalls(worker));
    worker.session_name = "child";
    worker.cap = 8;
    worker.remaining = 1;
    var dire = plannedRollover();
    dire.near_limit = true;
    dire.over_window_rejection = true;
    try std.testing.expectEqual(compact_note.Decision.skip_worker, compact_note.decide(worker, dire));
}

test "decideCalls (#391): the budget gate IS #390's landing reserve, not a second one" {
    const cap: u64 = 30;
    // Derived, never hard-coded: the first `remaining` that admits a note is
    // one call above whatever phase_budget holds back for the root to land and
    // narrate the work. A parallel reserve of the note's own would move this.
    const reserve = phase_budget.totalReserve(cap);
    var in = baseInputs();
    in.cap = cap;

    in.remaining = reserve + phase_budget.cost_precompact_note;
    try std.testing.expectEqual(compact_note.Decision.fire, compact_note.decideCalls(in));

    in.remaining = reserve; // exactly the reserve: those calls belong to landing
    try std.testing.expectEqual(compact_note.Decision.skip_budget, compact_note.decideCalls(in));

    in.remaining = 0;
    try std.testing.expectEqual(compact_note.Decision.skip_budget, compact_note.decideCalls(in));

    // The gate delegates to the ledger rather than re-deriving the arithmetic:
    // for every remaining value the two answers agree, by construction.
    const ledger = phase_budget.Ledger.init(cap);
    var r: u64 = 0;
    while (r <= reserve + 4) : (r += 1) {
        in.remaining = r;
        const affords = ledger.affordsHarnessNote(r);
        try std.testing.expectEqual(affords, compact_note.decideCalls(in) == .fire);
    }

    // An unlimited pool (cap 0) is the common case and never gates.
    in.cap = 0;
    in.remaining = std.math.maxInt(u64);
    try std.testing.expectEqual(compact_note.Decision.fire, compact_note.decideCalls(in));
}

test "store round trip (#391): a note survives the process boundary and comes back verbatim" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            try std.testing.expectEqual(@as(usize, 0), compact_note.load(io, arena, "last").len);
            try std.testing.expectEqualStrings("", compact_note.blockNow(io, arena, "last"));

            // Multi-line, with the punctuation a real note carries. Byte
            // equality on the way out is the whole contract: "deterministic
            // re-injection, no summarizer rewrites".
            const note =
                \\SUBGOAL: finish the retry ladder in agent_request.zig
                \\ANCHORS: src/agent_request.zig:273 (rebuild loop), src/provider.zig:137
                \\DECISIONS: chose Retry-After over exponential backoff — the gateway sends it
                \\DEAD ENDS: closeCodexWs before the trim wedges the chain, do NOT re-try that
            ;
            try std.testing.expect(compact_note.record(io, arena, "last", 3, note));

            const notes = compact_note.load(io, arena, "last");
            try std.testing.expectEqual(@as(usize, 1), notes.len);
            try std.testing.expectEqualStrings(note, notes[0].text); // verbatim, newlines and all
            try std.testing.expectEqual(@as(u32, 3), notes[0].generation);
            try std.testing.expectEqualStrings("last", notes[0].session);
            try std.testing.expect(notes[0].created_at > 0);

            // The injection block carries the note whole under a header that
            // says what it is, so the model cannot mistake it for a summary.
            const block = compact_note.blockNow(io, arena, "last");
            try std.testing.expect(std.mem.startsWith(u8, block, compact_note.header));
            try std.testing.expect(std.mem.endsWith(u8, block, note));

            // Sessions do not read each other's working state.
            try std.testing.expectEqualStrings("", compact_note.blockNow(io, arena, "other"));
        }
    }.body);
}

test "store (#391): a newer note supersedes the older one wholesale" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            try std.testing.expect(compact_note.record(io, arena, "last", 1, "SUBGOAL: the first thing entirely"));
            try std.testing.expect(compact_note.record(io, arena, "last", 2, "SUBGOAL: the second thing entirely"));
            const notes = compact_note.load(io, arena, "last");
            try std.testing.expectEqual(@as(usize, 2), notes.len); // the log only ever grows
            const block = compact_note.blockNow(io, arena, "last");
            try std.testing.expect(std.mem.indexOf(u8, block, "the second thing") != null);
            try std.testing.expect(std.mem.indexOf(u8, block, "the first thing") == null);
            try std.testing.expectEqual(@as(u32, 2), compact_note.latest(notes).?.generation);
        }
    }.body);
}

test "record (#391): an empty, absent or refused note degrades to no note at all" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            // The prompt's explicit way out, whitespace, and a fragment too
            // short to be a handoff all store NOTHING — and, crucially, none
            // of them is an error: compaction proceeds either way.
            for ([_][]const u8{ "none", "  none  \n", "None.", "none — nothing is in flight right now", "", "   \n\t ", "ok" }) |reply| {
                try std.testing.expect(!compact_note.record(io, arena, "last", 1, reply));
            }
            try std.testing.expectEqual(@as(usize, 0), compact_note.load(io, arena, "last").len);
            try std.testing.expectEqualStrings("", compact_note.blockNow(io, arena, "last"));
            // A base with no note is returned unchanged — a session that never
            // compacted pays nothing.
            try std.testing.expectEqualStrings("BASE", compact_note.compose(io, arena, "BASE", "last"));

            // A session name that could escape .graff/notes is refused before
            // any write, and reads back as an empty store.
            for ([_][]const u8{ "../../etc/passwd", "a/b", "..", "" }) |bad| {
                try std.testing.expect(compact_note.pathFor(arena, bad) == null);
                try std.testing.expect(!compact_note.record(io, arena, bad, 1, "SUBGOAL: something long enough to store"));
                try std.testing.expectEqual(@as(usize, 0), compact_note.load(io, arena, bad).len);
            }

            // A real note still lands after all of that, and composes.
            try std.testing.expect(compact_note.record(io, arena, "last", 1, "SUBGOAL: something long enough to store"));
            const composed = compact_note.compose(io, arena, "BASE", "last");
            try std.testing.expect(std.mem.startsWith(u8, composed, "BASE\n\n"));
            try std.testing.expect(std.mem.indexOf(u8, composed, "long enough to store") != null);
        }
    }.body);
}

test "parse (#391): a torn tail or a junk line costs at most its own record" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const notes = compact_note.parse(arena,
        \\{"v":1,"session":"last","gen":1,"text":"first note","created_at":10}
        \\not json at all
        \\{"v":1,"session":"last","gen":2,"text":"second note","created_at":20}
        \\
        \\{"v":1,"session":"last","gen":3,"text":"tor
    );
    try std.testing.expectEqual(@as(usize, 2), notes.len);
    try std.testing.expectEqualStrings("first note", notes[0].text);
    try std.testing.expectEqualStrings("second note", compact_note.latest(notes).?.text);
    // Missing/odd fields degrade rather than drop the record or fault.
    const sparse = compact_note.parse(arena,
        \\{"text":"no metadata"}
        \\{"v":1,"gen":-4,"text":"negative generation"}
        \\{"v":1,"gen":1}
        \\{"v":1,"gen":1,"text":""}
        \\[1,2,3]
    );
    try std.testing.expectEqual(@as(usize, 2), sparse.len);
    try std.testing.expectEqual(@as(u32, 0), sparse[0].generation);
    try std.testing.expectEqual(@as(u32, 0), sparse[1].generation);
    try std.testing.expect(compact_note.latest(&.{}) == null);
}

test "record (#391): an oversized reply is capped rather than refused" {
    try inScratch(struct {
        fn body(io: Io, arena: std.mem.Allocator) !void {
            const huge = try arena.alloc(u8, compact_note.max_text * 3);
            @memset(huge, 'x');
            try std.testing.expect(compact_note.record(io, arena, "last", 1, huge));
            const notes = compact_note.load(io, arena, "last");
            try std.testing.expectEqual(@as(usize, 1), notes.len);
            try std.testing.expectEqual(@as(usize, compact_note.max_text), notes[0].text.len);
        }
    }.body);
}
