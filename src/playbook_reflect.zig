//! #383 Reflector — the one place a MODEL is allowed near the playbook, and
//! only ever as a proposer.
//!
//! ACE's Generator → Reflector → Curator, mapped onto machinery graff already
//! has: the Generator is a normal eval-scored run (the trajectory archive
//! already captures it), the Reflector is the single bounded call below, and
//! the Curator is playbook.add — deterministic code that dedupes, caps, and
//! decides. The model returns candidate bullets; it never sees the ledger,
//! never edits it, and cannot retire anything. That asymmetry is the whole
//! point of the ACE result: iterative model REWRITES of a prompt-sized
//! artifact collapse, iterative deterministic MERGES of identified items do
//! not.
//!
//! COST DISCIPLINE (v1). Exactly ONE extra model call per process, fired on
//! the FIRST eval that meets its target — the moment a run is verifiably
//! finished and there is a real outcome to distil. Not every turn, not every
//! eval, not every subagent report. The call carries no tools (`request(null)`
//! — the title-generation shape), so it cannot fan out, and it runs on the
//! WORKER seat (childProvider), inheriting the same routing every subagent
//! gets rather than reserving a model of its own.
//!
//! SCOPE CUT, stated: distilling from FAILED runs, and per-item fitness
//! attribution (retiring bullets whose attributed score goes negative), are
//! follow-up. v1 records which item ids were active per run — playbook's
//! `kind:"playbook"` trajectory row — which is precisely the join a later
//! change needs and cannot reconstruct after the fact.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const playbook = @import("playbook.zig");
const playbook_glue = @import("playbook_glue.zig");
const subagent_run = @import("subagent_run.zig");
const title = @import("title.zig");
const trace = @import("trace.zig");
const util = @import("util.zig");
const textMessage = @import("messages.zig").textMessage;

/// At most this many bullets are taken from one reflection, however many the
/// model returns. Three is the issue's own number and it is also the point
/// past which a "lesson" is really a summary of the run.
pub const max_candidates = 3;
/// Shortest useful bullet. Below this a line is a fragment ("yes", "done"),
/// not a durable insight, and normalizing it would collide with anything.
const min_candidate_len = 12;

/// One model call per process, latched here. A session that evals ten times
/// distils once.
var g_reflected: bool = false;

/// Reset seam for the tests — production never calls it.
pub fn resetForTest() void {
    g_reflected = false;
}

fn stripBullet(line_in: []const u8) []const u8 {
    var s = std.mem.trim(u8, line_in, " \t\r");
    // "- x", "* x", "• x", "1. x", "2) x" — every shape a model reaches for.
    if (s.len > 1 and (s[0] == '-' or s[0] == '*')) s = s[1..];
    if (std.mem.startsWith(u8, s, "\xe2\x80\xa2")) s = s[3..];
    if (s.len > 2 and std.ascii.isDigit(s[0]) and (s[1] == '.' or s[1] == ')')) s = s[2..];
    return std.mem.trim(u8, s, " \t\r");
}

/// Pull up to `max_candidates` bullet lines out of a model reply. Pure and
/// total: any text at all yields a (possibly empty) list, so the reflector
/// degrades to "learned nothing" instead of failing a finished eval run.
///
/// Deliberately strict about what counts as a bullet. A model asked for
/// bullets also emits a preamble ("Here are three insights:"), and a
/// preamble curated into the playbook would be injected into every future
/// brief forever — the cost of a false positive is permanent, so only lines
/// that actually look like list items are taken.
pub fn parseCandidates(out: *[max_candidates][]const u8, reply: []const u8) [][]const u8 {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, reply, '\n');
    while (lines.next()) |raw| {
        if (n == max_candidates) break;
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        const bulleted = trimmed.len > 1 and (trimmed[0] == '-' or trimmed[0] == '*' or
            std.mem.startsWith(u8, trimmed, "\xe2\x80\xa2") or
            (std.ascii.isDigit(trimmed[0]) and (trimmed[1] == '.' or trimmed[1] == ')')));
        if (!bulleted) continue;
        const text = stripBullet(trimmed);
        if (text.len < min_candidate_len) continue;
        // A model that has nothing to say tends to say so in list form.
        if (std.ascii.eqlIgnoreCase(util.utf8Prefix(text, 4), "none")) continue;
        out[n] = util.utf8Prefix(text, playbook.max_text);
        n += 1;
    }
    return out[0..n];
}

fn reflectPrompt(arena: Allocator, note: []const u8, score: f64, target: u8, output: []const u8) ?[]const u8 {
    const evidence = util.utf8Prefix(if (output.len > 1200) output[output.len - 1200 ..] else output, 1200);
    return std.fmt.allocPrint(arena,
        \\A coding run in this repository just finished and its automated check scored {d:.0}/100 against a target of {d}.
        \\
        \\What the author said they changed: {s}
        \\
        \\Tail of the check's output:
        \\---
        \\{s}
        \\---
        \\
        \\Write at most {d} bullets of DURABLE, REPO-SPECIFIC knowledge worth keeping for future work here — the kind of thing a fresh agent with no memory of this run would waste time rediscovering ("this repo's tests need X before Y", "module Z is generated, edit the template instead", "the build fails unless W is regenerated").
        \\
        \\Rules: one short imperative line per bullet, starting with "- ". No preamble, no summary of what happened, nothing that is only true of this one change, nothing already obvious from the repository's own README. If there is no durable lesson here, reply with exactly: none
    , .{ score, target, if (note.len > 0) note else "(no note given)", evidence, max_candidates }) catch null;
}

/// The distillation call itself: a throwaway one-message agent with NO tools,
/// on the worker seat. Mirrors title.titleTask, which is the established
/// shape in this codebase for "one cheap auxiliary completion".
fn askModel(self: *Agent, prompt: []const u8) ?[]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const seat = subagent_run.childProvider(self.provider, self.subagent_provider, self.subagent_cross_provider);
    var agent: Agent = .{
        .gpa = self.gpa,
        .arena = arena,
        .io = self.io,
        .client = self.client,
        .provider = seat,
        .messages = std.json.Array.init(arena),
        .sub = true, // never touches stdout or the root's state
        .label = "reflect",
        .out = null,
        .tracer = self.tracer,
        .run_budget = self.run_budget,
        .call_kind = .judge, // an auxiliary, bounded, non-recursive call — the judge's class
        .responses_output_limit = 512,
        .sys_override = "You distil durable engineering lessons from a finished run. Reply with terse imperative bullets and nothing else.",
    };
    defer agent.tools_used.deinit(self.gpa);
    agent.messages.append(textMessage(arena, "user", prompt) catch return null) catch return null;
    const root = agent.request(null) catch return null;
    return self.arena.dupe(u8, title.assistantText(seat.kind, root)) catch null;
}

/// Called from agent_eval.runEval once a scored run has met its target.
///
/// The `trace.g_traj` gate is load-bearing twice over: it is where the run id
/// used as provenance comes from, AND it is the same null-sink guard the
/// local DGM capture above it uses, which is what keeps agent_eval_tests'
/// stub Agent (`.provider = undefined`, `.client = undefined`, and a target
/// that IS met) from being dragged into a live model call.
pub fn afterEval(self: *Agent, note: []const u8, score: f64, output: []const u8) void {
    const tj = trace.g_traj orelse return;
    if (g_reflected or self.sub) return;
    g_reflected = true;
    const prompt = reflectPrompt(self.arena, note, score, self.eval_target, output) orelse return;
    const reply = askModel(self, prompt) orelse return;
    var buf: [max_candidates][]const u8 = undefined;
    const candidates = parseCandidates(&buf, reply);
    if (self.tracer) |tr| {
        var detail: [64]u8 = undefined;
        tr.note("playbook", std.fmt.bufPrint(&detail, "reflector proposed {d} candidate(s)", .{candidates.len}) catch "");
    }
    if (candidates.len == 0) return;
    const provenance = std.fmt.allocPrint(self.arena, "run:{s}", .{tj.identity.run_id}) catch "run";
    var kept: usize = 0;
    for (candidates) |text| {
        // The Curator. Every rejection here — duplicate, over the learned
        // cap, unwritable ledger — is a deterministic decision, and the
        // model that proposed the bullet has no say in it.
        if (playbook.add(self.io, self.arena, text, .learned, provenance).ok) kept += 1;
    }
    if (kept == 0) return;
    playbook_glue.refreshRoot(self, self.arena);
    self.say("  📗 playbook: kept {d} learned insight(s) from this run\n", .{kept}) catch {};
}
