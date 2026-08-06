//! #391 — the Agent side of the pre-compaction note: the gate evaluated
//! against a live agent, the one bounded model call, and the system-prompt
//! refresh that makes the note visible to the very next request.
//!
//! Split from compact_note.zig for the same reason playbook_glue.zig is split
//! from playbook.zig: the store stays a leaf over std/util/phase_budget, so
//! prompts.zig can compose it into the ROOT system prompt without dragging
//! the Agent type into the prompt funnel.
//!
//! THE CALL IS THE COMPACTION'S OWN. It runs on the root's provider (the
//! history it reads is in that wire format), carries NO tools so it cannot
//! fan out, and sets `compaction_request` — which bounds the reply, drops
//! reasoning effort to low, charges the call to `CallKind.compaction`, and,
//! load-bearing here, disables the in-request overflow recovery that would
//! otherwise let a note turn recurse back into emergencyTrim mid-compaction
//! (agent_overflow.applyOverflowRecovery's `compaction_request` early-out).
//!
//! IT IS TRANSACTIONAL. The note request runs against a container-deep clone
//! of history in a throwaway arena, exactly as compact() builds its summary
//! request, so send-time normalization cannot touch the live conversation. If
//! anything at all fails — the clone, the request, an empty reply, an
//! unwritable store — the function returns a named skip and compaction
//! proceeds untouched. Losing a note is much cheaper than wedging a session.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const agent_compact = @import("agent_compact.zig");
const compact_note = @import("compact_note.zig");
const main_mod = @import("main.zig");
const phase_budget = @import("phase_budget.zig");
const playbook_glue = @import("playbook_glue.zig");
const prompts = @import("prompts.zig");
const textMessage = @import("messages.zig").textMessage;
const title = @import("title.zig");

pub const Decision = compact_note.Decision;

/// The cheap half of the gate, over a live agent. Never serializes history:
/// a worker, a session-less scratch agent, an already-noted generation and an
/// exhausted budget are all answered before anything measures context.
pub fn gateCalls(self: *const Agent) Decision {
    return compact_note.decideCalls(.{
        .sub = self.sub,
        .session_name = self.session_name,
        .history_rewrites = self.history_rewrites,
        .last_written = self.precompact_note_gen,
        .cap = phase_budget.capOf(self.run_budget),
        .remaining = phase_budget.remainingOf(self.run_budget),
    });
}

/// Write one note to self, if this is a moment that deserves one. Returns the
/// decision so a caller (and a test) can see WHICH refusal happened rather
/// than only that nothing was written. Never throws: every failure below is a
/// skip, because the caller is compaction and compaction must still run.
pub fn maybeWrite(self: *Agent) Decision {
    const cheap = gateCalls(self);
    if (cheap != .fire) return cheap;
    const room = compact_note.decideRoom(self.provider.context, self.effectiveContextTokens());
    if (room != .fire) return room;

    // Latch the generation BEFORE the call. A note turn that fails has still
    // spent one, and re-buying it on every retried compaction of the same
    // unchanged history is exactly the runaway #379 taught us to avoid — an
    // over-cap session compacts in a loop, and each lap would cost a note.
    self.precompact_note_gen = self.history_rewrites;
    const reply = askModel(self) orelse return .skip_failed;
    if (!compact_note.record(self.io, self.arena, self.session_name, self.history_rewrites, reply))
        return .skip_failed;
    // The note is in the SYSTEM prompt, beside HARD CONSTRAINTS, so it has to
    // be re-composed to reach the next request — the same refresh a mid-
    // session `/never` performs, and for the same reason.
    prompts.armCompactNotes(self.session_name);
    playbook_glue.refreshRoot(self, self.arena);
    if (!main_mod.json_mode) self.say("  📝 wrote a pre-compaction note to self ({d} chars)\n", .{reply.len}) catch {};
    if (self.tracer) |tr| tr.note("compact", "wrote a pre-compaction note to self (#391)");
    return .fire;
}

/// The bounded turn. Mirrors playbook_reflect.askModel — a throwaway agent in
/// its own arena — but on the ROOT's provider and over a clone of the ROOT's
/// history, because a note about work in flight can only be written by
/// something that can still see the work.
fn askModel(self: *Agent) ?[]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var messages = agent_compact.cloneJsonArray(arena, self.messages) catch return null;
    messages.append(textMessage(arena, "user", compact_note.instruction) catch return null) catch return null;
    var agent: Agent = .{
        .gpa = self.gpa,
        .arena = arena,
        .io = self.io,
        .client = self.client,
        .provider = self.provider,
        .messages = messages,
        .sub = true, // never touches stdout or the root's state
        .label = "note",
        .out = null,
        .tracer = self.tracer,
        .run_budget = self.run_budget,
        .reasoning = self.reasoning,
        .stream_quiet = true,
        .compaction_request = true, // bounded reply, low effort, no recursive recovery
        .message_mutation_arena = arena,
        .sys_override = compact_note.persona,
    };
    defer agent.tools_used.deinit(self.gpa);
    const root = agent.request(null) catch return null;
    const text = std.mem.trim(u8, title.assistantText(self.provider.kind, root), " \t\r\n");
    if (compact_note.isEmptyReply(text)) return null;
    return self.arena.dupe(u8, text) catch null;
}

test {
    _ = @import("compact_note_glue_tests.zig");
}
