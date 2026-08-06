//! #415 — `/btw`: a throwaway side question, answered from the LIVE
//! conversation with tools disabled, rendered once, and then dropped.
//!
//! THE POINT. "what did that error actually mean?" is a question ABOUT the work
//! in progress, not a step of it. Asking it the ordinary way costs the session
//! two permanent messages plus their re-send on every turn after, and it is
//! summary input at the next compaction. `/btw` buys the answer and keeps none
//! of the exchange.
//!
//! HOW IT LEAVES NO TRACE. The turn runs on a THROWAWAY agent over a
//! container-deep CLONE of the root's history, in an arena that dies with the
//! call — the shape compact_note_glue.askModel already uses, and for the same
//! reason: send-time normalization mutates `messages` in place (normalization
//! of Responses history, capOversizedToolOutputs, #390's landing note), so only
//! a clone may be handed to it. `root.messages` is read once, to clone, and
//! written never.
//!
//! That single fact is what keeps it out of BOTH persistence paths, which is
//! worth spelling out because they are not the same path:
//!   - the session file is a rewrite of `root.messages` (session.saveSessionTo);
//!   - the append-only transcript (#441) is an OBSERVATION of `root.messages`,
//!     taken inside session.queueSave (session_transcript.record). It is
//!     append-only, so a line written by mistake could never be taken back.
//! Neither runs here, and neither could see the exchange if it did: the side
//! agent's messages live in an arena the root holds no pointer to, and its
//! `sub = true` makes `record` refuse it outright at the first line.
//!
//! NO TOOLS, GENUINELY. `Agent.request(null)` omits the `tools` field from the
//! body entirely rather than sending an empty array, for all three wire
//! formats — the same trick compaction and the title task use. `text_only` is
//! set too, so the agent stays tool-less if it is ever driven through
//! `runTurn` instead.
//!
//! IT IS STILL BILLED. The request goes through `Agent.request` like any
//! other, so recordUsage/recordCost bank it in `pricing.g_cost` — the tally the
//! `[usage]` footer, `/cost` and the telemetry summary all read. Not keeping an
//! exchange is not a reason to hide what it cost.
//!
//! SINGLE-SHOT, deliberately. The issue names multi-turn side threads a
//! possible v2; there is no side history here to continue.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const agent_compact = @import("agent_compact.zig");
const ansi = @import("ansi.zig");
const style = &ansi.style;
const textMessage = @import("messages.zig").textMessage;
const title = @import("title.zig");

/// Bounded reply. A side question wants an answer, not a report; the ceiling
/// also bounds what a `/btw` can cost when the model misreads the brief.
pub const output_limit: u32 = 1024;

/// Shown when `/btw` arrives with nothing to ask. Says what the command is for,
/// because an empty one is nearly always a half-typed line.
pub const usage_hint = "/btw <question> — ask one side question about this conversation; " ++
    "it runs with no tools and is never added to the session";

/// Appended to the ROOT's own system prompt for this one call. The model keeps
/// its identity and its project context — the question is about the work in
/// front of it — and is told the two things that are only true here.
pub const side_note =
    \\[side question: the user has asked something ALONGSIDE the conversation
    \\above, not as the next step of it. Answer it from what is already in this
    \\context. You have NO tools on this turn: do not claim to have read, run or
    \\changed anything, and if the context does not contain the answer, say so
    \\plainly instead of guessing. Be brief. Neither the question nor your answer
    \\is added to the conversation, so do not treat this as work done, do not
    \\update any checklist, and do not refer back to it later.]
;

/// True for the `/btw` command line in any of its forms, including the empty
/// one — telling "not my command" apart from "my command, no question" is what
/// lets the refusal be a message rather than an "unknown command".
pub fn isCommand(line: []const u8) bool {
    return std.mem.eql(u8, line, "/btw") or std.mem.startsWith(u8, line, "/btw ");
}

/// The question in a `/btw` line, or null when there is none. Null covers both
/// "not a /btw line" and "/btw with nothing after it"; `isCommand` separates
/// them for the caller that has to answer differently.
pub fn questionFromLine(line: []const u8) ?[]const u8 {
    if (!isCommand(line)) return null;
    const question = std.mem.trim(u8, line["/btw".len..], " \t\r\n");
    return if (question.len == 0) null else question;
}

/// The throwaway agent the side question runs on, exposed so a test can inspect
/// the exact request this feature would send without making one.
///
/// The ROOT's provider, because the cloned history is in that wire format, and
/// the ROOT's system prompt, because the question is about the work in it.
/// `sub = true` keeps it off stdout and out of every root-only path — including
/// the transcript, which refuses a subagent outright. `message_mutation_arena`
/// points at the same throwaway arena so a mid-request history rewrite cannot
/// allocate out of the session's.
pub fn build(self: *Agent, arena: Allocator, question: []const u8) !Agent {
    var messages = try agent_compact.cloneJsonArray(arena, self.messages);
    try messages.append(try textMessage(arena, "user", question));
    return .{
        .gpa = self.gpa,
        .arena = arena,
        .io = self.io,
        .client = self.client,
        .provider = self.provider,
        .messages = messages,
        .sub = true, // never touches stdout, the root's state, or the transcript
        .text_only = true, // and could not be handed tools even through runTurn
        .label = "btw",
        .out = null,
        .tracer = self.tracer,
        .run_budget = self.run_budget,
        .reasoning = self.reasoning,
        .fast = self.fast,
        .stream_quiet = true,
        .call_kind = .judge, // an auxiliary, bounded, non-recursive call
        .responses_output_limit = output_limit,
        .message_mutation_arena = arena,
        .sys_override = try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ self.systemPrompt(), side_note }),
    };
}

/// One tool-less request over a clone of the live history. The answer is duped
/// into `out_arena` (the caller's turn arena, not the session's) and everything
/// else — the clone, the reply tree, the side agent — dies with the scratch
/// arena before this returns. Null on any failure: a side question that could
/// not be answered must still leave the conversation exactly as it found it.
pub fn ask(self: *Agent, out_arena: Allocator, question: []const u8) ?[]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent = build(self, arena, question) catch return null;
    defer agent.tools_used.deinit(self.gpa);
    defer agent.closeCodexWs(); // its own socket + response-id anchor, gpa-owned
    const root = agent.request(null) catch return null;
    const text = std.mem.trim(u8, title.assistantText(self.provider.kind, root), " \t\r\n");
    if (text.len == 0) return null;
    return out_arena.dupe(u8, text) catch null;
}

/// The `/btw` slash command. Returns false when `line` is not one, so it can sit
/// in a tryHandle chain beside every other command.
pub fn command(root: *Agent, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    if (!isCommand(line)) return false;
    const question = questionFromLine(line) orelse {
        try out.print("{s}\n", .{usage_hint});
        try out.flush();
        return true;
    };
    try out.print("{s}↳ btw ›{s} {s}\n", .{ style.accent, style.reset, question });
    try out.flush();
    const answer = ask(root, arena, question) orelse {
        try out.print("{s}side question failed — the conversation is unchanged{s}\n", .{ style.yellow, style.reset });
        try out.flush();
        return true;
    };
    try out.print("{s}\n{s}(side question — not added to this session){s}\n", .{ answer, style.dim, style.reset });
    try out.flush();
    return true;
}
