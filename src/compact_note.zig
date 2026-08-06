//! #391 — pre-compaction notes-to-self: the handoff the agent writes for
//! ITSELF, in its own words, just before compaction rewrites its history.
//!
//! Codex reserves `auto_compact_fallback_buffer_tokens` and fires
//! `auto_compact_fallback_prompt` right before context rollover, for a reason
//! graff has its own evidence of: a summarizer optimizes for a readable
//! account of what happened, and the things a working agent cannot cheaply
//! re-derive — the exact line it was editing, the approach it already ruled
//! out, why it picked B over A — are precisely the details a summary drops as
//! uninteresting. The my-website post-mortem is that failure at scale: 221
//! calls, 66 over 128k, constraint recall decaying with every rollover.
//!
//! THE NOTE IS STATE, NOT CONVERSATION. Three properties follow from that and
//! every design choice here serves one of them:
//!
//!   * DETERMINISTIC RE-INJECTION. `blockNow` reads the file on disk at the
//!     moment a prompt is assembled. There is no in-context copy for the next
//!     compaction to paraphrase away, which is the same mechanism — and the
//!     same one-line reason — the #383 playbook survives compaction with no
//!     extra machinery.
//!   * IT RIDES THE SYSTEM PROMPT. prompts.setSystemPrompts composes this
//!     beside the HARD CONSTRAINTS block, so it is re-sent verbatim on every
//!     request. A user-turn note would land in the NEXT compaction's input
//!     and be summarized on the spot (#326's lesson).
//!   * NOTHING REWRITES IT. The model proposes the text once; this file caps
//!     and stores it. Nothing merges, re-summarizes or edits a stored note.
//!     A newer note supersedes an older one wholesale, because the agent that
//!     wrote it had the older one in front of it when it did.
//!
//! WHY A SESSION-SCOPED FILE AND NOT `playbook` ITEMS WITH `source=session`.
//! The issue floats both. The playbook is the wrong container on four counts,
//! all of which are about scope rather than taste: it is PROJECT-scoped and
//! deliberately cross-session (a note about the refactor in flight is noise
//! in tomorrow's session); its items are capped at 240 bytes and its block at
//! 2 KB (a note carrying anchors, decisions and dead ends is neither); every
//! item rides EVERY subagent and workflow brief through `rideBrief`, and #391
//! requires the opposite; and items are permanent until a user retires one by
//! id, whereas a note is superseded by the next note. What is worth borrowing
//! is the MECHANISM, and it is borrowed exactly: append-only JSONL written
//! whole-or-not-at-all, replayed in order, assembled from the file and never
//! from conversation memory.
//!
//! ON-DISK FORMAT — `.graff/notes/<session>.notes.jsonl`, one self-describing
//! object per line, appended positionally so a concurrent reader sees either
//! the old state or the new one:
//!
//!   {"v":1,"session":"last","gen":3,"text":"…","created_at":1754…}
//!
//! `gen` is the writing agent's `history_rewrites` counter — the history
//! generation the note describes. It is what makes "at most one note per
//! compaction" checkable after the fact rather than only in memory.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const util = @import("util.zig");
// #390/#391: the ONE reservation ledger over the shared RunBudget pool. The
// note turn is charged here rather than against a reserve of its own — see
// `decideCalls` below.
const phase_budget = @import("phase_budget.zig");

pub const dir = ".graff/notes";
pub const ext = ".notes.jsonl";

/// Whole-file read cap. A note store is a handful of records; past this it is
/// something else and injecting from it would be the bug.
pub const max_file_bytes = 256 * 1024;
/// Longest single note kept on disk and injected (~1k tokens). The turn that
/// produces it is bounded on the wire too (compact_note_glue.askModel).
pub const max_text = 4000;
/// Below this a reply is a fragment, not a handoff.
pub const min_text = 16;

/// The token buffer held back for the note turn, the direct analogue of
/// codex's `auto_compact_fallback_buffer_tokens`. Compaction fires at 80% of
/// the window, so this is normally free; the check exists for the case that
/// is not true — a window already past the wall, where spending the last
/// tokens on a note would cost the compaction that has to happen anyway.
pub const note_reserve_tokens: u64 = 2_000;

pub const header = "NOTES TO SELF (you wrote this yourself just before the last compaction; stored verbatim outside the conversation, not a summary):";

pub const Note = struct {
    session: []const u8 = "",
    text: []const u8,
    /// The writer's `history_rewrites` at the time — the history generation
    /// this note describes.
    generation: u32 = 0,
    created_at: i64 = 0,
};

/// Why the note turn did or did not fire. Every refusal is named: a silent
/// skip and a skip we chose are indistinguishable in a trace, and this is a
/// feature whose whole value is that it happened at the right moment.
pub const Decision = enum {
    fire,
    /// #391: workers never write notes. A subagent's context is disposable by
    /// design — it exists to produce one report and die — so a note it wrote
    /// would outlive the only reader it could ever have.
    skip_worker,
    /// No durable session to hang the note on (a `-p` one-shot, a scratch
    /// agent). Nothing would ever read it back.
    skip_no_session,
    /// A note already covers this history generation. Compaction can be
    /// retried after a transient failure; the note must not be re-bought.
    skip_already,
    /// The call would come out of #390's landing reserve.
    skip_budget,
    /// No token buffer left for the note turn under this model's window.
    skip_no_headroom,
    /// The turn ran and produced nothing usable — a transport failure, an
    /// explicit "none", or a store that could not be written. Distinct from
    /// the gates above because this one COST a call; compaction proceeds
    /// regardless, which is the point.
    skip_failed,
};

pub const Inputs = struct {
    sub: bool,
    session_name: []const u8,
    history_rewrites: u32,
    /// `history_rewrites` at the last note this agent wrote, if any.
    last_written: ?u32,
    /// The run's `--max-model-calls` (0 = unlimited) and what is left of it.
    cap: u64,
    remaining: u64,
};

/// Everything decidable without measuring the context. Split from the token
/// half so the cheap refusals — a worker above all — never pay for a full
/// history serialization to learn they are refusals.
///
/// THE BUDGET GATE IS #390'S LEDGER, NOT A SECOND ONE. `phase_budget.Ledger`
/// already holds back the calls the ROOT needs to land and narrate the work;
/// #391 adds a second harness-owned liability against the same pool. Giving
/// it a reserve of its own would double-count that pool — two ledgers each
/// believing they had protected the last call — so the note is charged as an
/// OPTIONAL cost that must fit ON TOP of the landing reserve, the same P3
/// gate judges pass. A note can therefore never be the reason a run dies
/// narrating, which is the exact failure #390 exists to prevent. The note
/// call itself then goes through the shared RunBudget like every other call,
/// so it is counted where it is spent; `remaining` is a plain load and racy
/// against a concurrent sibling, exactly as phase_budget's own gates are.
pub fn decideCalls(in: Inputs) Decision {
    if (in.sub) return .skip_worker;
    if (in.session_name.len == 0) return .skip_no_session;
    if (in.last_written) |written| if (written == in.history_rewrites) return .skip_already;
    const ledger = phase_budget.Ledger.init(in.cap);
    if (!ledger.affordsHarnessNote(in.remaining)) return .skip_budget;
    return .fire;
}

/// The token half: is there room under the window for the note turn's reply?
/// An unknown window (0) cannot prove there is not, and the summary request
/// this precedes is about to ship the same input anyway.
pub fn decideRoom(window_tokens: u64, effective_tokens: u64) Decision {
    if (window_tokens == 0) return .fire;
    return if (effective_tokens +| note_reserve_tokens > window_tokens) .skip_no_headroom else .fire;
}

/// The whole ladder, in the order the call site runs it.
pub fn decide(in: Inputs, window_tokens: u64, effective_tokens: u64) Decision {
    const calls = decideCalls(in);
    if (calls != .fire) return calls;
    return decideRoom(window_tokens, effective_tokens);
}

/// A model reply that carries no note. The prompt asks for exactly "none"
/// when nothing is in flight; an empty or whitespace reply means the same
/// thing. Either way nothing is stored and compaction proceeds — losing a
/// note is much cheaper than wedging the session over one.
pub fn isEmptyReply(reply: []const u8) bool {
    const t = std.mem.trim(u8, reply, " \t\r\n.");
    if (t.len < min_text) return true;
    // A model handed an explicit way out takes it, but rarely at exactly four
    // bytes ("none — nothing in flight"). Same prefix test the #383 reflector
    // uses on its own opt-out, and for the same reason.
    return std.ascii.eqlIgnoreCase(util.utf8Prefix(t, 4), "none");
}

/// This session's store. Null for a name that could escape `.graff/notes`:
/// session names reach here from `/save <name>` and are user input.
pub fn pathFor(arena: Allocator, session: []const u8) ?[]const u8 {
    if (session.len == 0) return null;
    if (std.mem.indexOfAny(u8, session, "/\\") != null) return null;
    if (std.mem.indexOf(u8, session, "..") != null) return null;
    return std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ dir, session, ext }) catch null;
}

/// Append one already-serialized record at the current end of file, so a
/// whole line lands at once (playbook.appendLine's shape, and serve_events'
/// before it).
fn appendLine(io: Io, path: []const u8, line: []const u8) bool {
    Io.Dir.cwd().createDirPath(io, dir) catch {};
    const f = Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return false;
    defer f.close(io);
    const st = f.stat(io) catch return false;
    f.writePositionalAll(io, line, st.size) catch return false;
    return true;
}

/// Store one note. Total and best-effort: every refusal returns false and
/// writes nothing, because every caller is on the compaction path and must
/// keep going without a note.
pub fn record(io: Io, arena: Allocator, session: []const u8, generation: u32, text_in: []const u8) bool {
    const trimmed = std.mem.trim(u8, text_in, " \t\r\n");
    if (isEmptyReply(trimmed)) return false;
    const text = util.utf8Prefix(trimmed, max_text);
    const path = pathFor(arena, session) orelse return false;
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.write(.{
        .v = @as(u8, 1),
        .session = session,
        .gen = generation,
        .text = text,
        .created_at = util.unixMs(io),
    }) catch return false;
    aw.writer.writeByte('\n') catch return false;
    return appendLine(io, path, aw.writer.buffered());
}

fn strOf(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn u32Of(o: std.json.ObjectMap, key: []const u8) u32 {
    const v = o.get(key) orelse return 0;
    if (v != .integer or v.integer < 0) return 0;
    return std.math.cast(u32, v.integer) orelse 0;
}

/// Replay the log oldest-first. A malformed line costs at most its own
/// record: a half-written tail from a killed process must not take the note
/// before it down with it.
pub fn parse(arena: Allocator, data: []const u8) []const Note {
    var list: std.ArrayList(Note) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
        if (v != .object) continue;
        const text = strOf(v.object, "text") orelse continue;
        if (text.len == 0) continue;
        const created = v.object.get("created_at");
        list.append(arena, .{
            .session = strOf(v.object, "session") orelse "",
            .text = text,
            .generation = u32Of(v.object, "gen"),
            .created_at = if (created) |c| (if (c == .integer) c.integer else 0) else 0,
        }) catch break;
    }
    return list.items;
}

/// Every note this session ever wrote. An absent or unreadable file is an
/// empty store, never an error.
pub fn load(io: Io, arena: Allocator, session: []const u8) []const Note {
    const path = pathFor(arena, session) orelse return &.{};
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_bytes)) catch return &.{};
    return parse(arena, data);
}

/// NEWEST WINS, wholesale. The agent that wrote note N+1 had note N in its
/// system prompt while it did, so N+1 already carries whatever of N still
/// mattered. Injecting both would grow without bound and re-state dead ends
/// the agent has since left behind.
pub fn latest(notes: []const Note) ?Note {
    return if (notes.len == 0) null else notes[notes.len - 1];
}

pub fn blockFrom(arena: Allocator, note: Note) []const u8 {
    if (note.text.len == 0) return "";
    return std.fmt.allocPrint(arena, "{s}\n{s}", .{ header, note.text }) catch "";
}

/// The block for the store as it exists on disk RIGHT NOW. Reading the file
/// here rather than caching a copy in the conversation IS the compaction
/// survival mechanism — there is nothing in the history for a summarizer to
/// paraphrase.
pub fn blockNow(io: Io, arena: Allocator, session: []const u8) []const u8 {
    const note = latest(load(io, arena, session)) orelse return "";
    return blockFrom(arena, note);
}

/// Compose the block onto a system-prompt base. Identity when there is no
/// note, so a session that never compacted pays nothing.
pub fn compose(io: Io, arena: Allocator, base: []const u8, session: []const u8) []const u8 {
    const b = blockNow(io, arena, session);
    if (b.len == 0) return base;
    return std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ base, b }) catch base;
}

/// The one bounded turn. Names what the note is FOR — the things a summary
/// reliably drops — and gives the model an explicit way out, so a compaction
/// with nothing in flight costs a short reply instead of invented state.
pub const instruction =
    \\Your context is about to be compacted: everything above this point will be
    \\replaced by a summary, and whatever that summary judges unimportant is gone.
    \\
    \\Before that happens, write a note to your FUTURE SELF. It is stored verbatim
    \\outside the conversation and re-injected after the compaction — no summarizer
    \\rewrites it. Cover only these, in this order:
    \\
    \\1. SUBGOAL — the one thing you are in the middle of right now.
    \\2. ANCHORS — the exact file:line locations you would otherwise have to find
    \\   again (paths with line numbers, not descriptions).
    \\3. DECISIONS — what you chose and why, so you do not relitigate it.
    \\4. DEAD ENDS — what you already tried that did not work, so you do not
    \\   try it again.
    \\
    \\Terse fragments. No preamble, no narration of the conversation, no apology,
    \\nothing you could re-derive in one tool call. If there is genuinely nothing
    \\in flight, reply with exactly: none
;

pub const persona = "You are writing a private note to your future self, moments before your context window is compacted. Reply with the note and nothing else.";

test {
    _ = @import("compact_note_tests.zig");
}
