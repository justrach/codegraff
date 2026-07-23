//! Eval-driven scoring loop and its optional LLM-as-judge scorer.
//! Tests live in agent_eval_tests.zig.

const std = @import("std");
const Io = std.Io;

const Agent = @import("agent.zig").Agent;
const ExecResult = @import("tools.zig").ExecResult;
const ToolCtx = @import("tools.zig").ToolCtx;
const ToolOutput = @import("tools.zig").ToolOutput;
const parseEvalScore = @import("repl_glue.zig").parseEvalScore;
const utf8Prefix = @import("util.zig").utf8Prefix;

const scoring = @import("scoring.zig");
const promptFingerprint = scoring.promptFingerprint;
const providerClass = scoring.providerClass;
const signScore = scoring.signScore;

const telemetry = @import("telemetry.zig");
const runCapped = @import("jobs.zig").runCapped;
const judgeTask = @import("subagent.zig").judgeTask;
const eval_memory = @import("eval_memory.zig");

test {
    _ = @import("agent_eval_tests.zig");
}

/// Run the configured --eval scoring command, append the result to the
/// scores log (.graff/eval-log.tsv), and return a verdict for the model:
/// score (0-100), best so far, target, and whether the target is met. The
/// harness runs the command, so the model cannot fake the number. (eval tool)
pub fn runEval(self: *Agent, note: []const u8) !ExecResult {
    const cmd = self.eval_cmd orelse return .{
        .text = "no eval command configured - relaunch graff with --eval <scoring cmd> and --until <N>, or ask the user to set one",
        .is_error = true,
    };

    // Behavioral commitment (issue #256): the eval-driven loop is the first
    // production caller of turn_committed/model_mispredicted. The commitment
    // asserts the loop's own belief - the command will meet the target -
    // before the command runs, so a later contradiction is provable rather
    // than reconstructed after the fact. commitment_id is opaque and
    // per-invocation; the command text and its stdout/stderr are content and
    // must never reach either typed field (docs/behavioral-trajectories.md).
    const behavior = if (self.tracer) |tracer| tracer.behavior else null;
    const eval_turn = if (behavior) |bt| bt.currentTurn() else 0;
    var commitment_buf: [48]u8 = undefined;
    const commitment_id = std.fmt.bufPrint(&commitment_buf, "eval-{d}-{d}", .{ eval_turn, self.eval_iter + 1 }) catch "";
    if (behavior) |bt| bt.recordExpectedAction(eval_turn, commitment_id, .{ .kind = "eval" }, .{ .pass = true }, "eval-driven loop verifier");

    const run = runCapped(self.gpa, self.io, &.{ "/bin/sh", "-c", cmd }, 64 * 1024, 16 * 1024, 0) catch |e| {
        // The command never ran, so the commitment can never be verified by
        // the normal exit-code/score path below; resolve it here instead of
        // leaving a dangling turn_committed that a scorer would misread as
        // an unresolved success.
        if (behavior) |bt| bt.recordMisprediction(eval_turn, commitment_id, .{ .pass = true }, .{ .pass = false, .exit = @as(i32, -1) }, "eval command could not run");
        self.eval_verified = false;
        self.eval_repair_pending = true;
        eval_memory.record(self, note, null, -1, false);
        return .{ .text = try std.fmt.allocPrint(self.arena, "eval command could not run: {t}", .{e}), .is_error = true };
    };
    defer self.gpa.free(run.stdout);
    defer self.gpa.free(run.stderr);
    self.eval_iter += 1;
    const exit_code: i32 = switch (run.term) {
        .exited => |c| @intCast(c),
        else => -1,
    };
    const det = parseEvalScore(run.stdout) orelse parseEvalScore(run.stderr);

    // LLM-as-judge (--judge): an independent subagent inspects the actual
    // artifacts against the rubric and returns its own 0-100 score. Both
    // scores must clear the target, so the binding value is their min().
    // Skip the judge when the deterministic command itself produced no
    // score - fix that first rather than burn a judge run.
    const judge: ?f64 = if (self.eval_judge != null and det != null) self.runJudge(self.eval_judge.?, run.stdout, note) else null;
    const combined: ?f64 = if (self.eval_judge == null)
        det
    else if (det != null and judge != null)
        @min(det.?, judge.?)
    else
        null;

    const target_f: f64 = @floatFromInt(self.eval_target);
    const improved = if (combined) |s| (self.eval_best < 0 or s > self.eval_best) else false;
    if (combined) |s| {
        if (self.eval_best < 0 or s > self.eval_best) self.eval_best = s;
    }
    const met = if (combined) |s| s >= target_f else false;
    self.eval_repair_pending = exit_code != 0 or !met;
    self.eval_verified = !self.eval_repair_pending;
    // Resolve the commitment made above: a nonzero exit or an unmet/unparsed
    // target contradicts "this command will meet the target", so it is a
    // misprediction. Meeting the target leaves the commitment unresolved by
    // design - docs/behavioral-trajectories.md: a commitment with no paired
    // misprediction is itself the success signal.
    if (behavior) |bt| if (exit_code != 0 or !met)
        bt.recordMisprediction(eval_turn, commitment_id, .{ .pass = true }, .{ .pass = false, .exit = exit_code }, "target not met");
    self.appendEvalLog(note, det, judge, combined, exit_code, met) catch {};
    eval_memory.record(self, note, combined, exit_code, met);

    // Feed the eval-driven score into the fleet (docs/hyperagents.md §9.B):
    // on a NEW BEST, submit the genome (this agent's persona) with its achieved
    // score on the pinned eval set (the eval command's fingerprint). Without this
    // the score only ever reached .graff/eval-log.tsv and the DGM/fleet never saw
    // real eval-driven work — only darwincode/JSON-proto runs ever submitted.
    if (combined) |s| {
        if (improved and s > 0) { // s>0: skip the initial-state / total-failure 0 (don't pollute the cell mean)
            if (s > 100) {
                // Review F8: parseEvalScore does NOT bound its result (a stray
                // "score: 9000" line parses as 9000) — an out-of-[0,100] score
                // must never be signed or submitted. Skip the score AND its
                // paired propose/submit, mirroring mainloop /score's explicit
                // rejection, so the submit counter stays in sync with stored
                // scores. The local eval verdict below still shows the number.
                if (self.tracer) |tr| tr.note("fleet", "score skipped: eval score outside [0,100]");
            } else if (telemetry.g_telem) |t| {
                const sys = self.systemPrompt();
                const genome_fp = promptFingerprint(sys);
                const esh_fp = promptFingerprint(cmd);
                const genome: []const u8 = &genome_fp;
                const esh: []const u8 = &esh_fp;
                const run_id: []const u8 = &scoring.g_run_id;
                const pclass = providerClass(self.provider.model);
                // --niche tags this score's cell. Without it the score lands in the
                // anonymous "" niche, which pullElites can never match to a builtin —
                // so an eval session that wants to grow a champion must name its role.
                // Truncated to 64 chars and sanitized (tab/newline/CR → ' ', review
                // F7) BEFORE signing (fleetEvent's own niche cap, same as mainloop
                // /score) so signed bytes equal ingested bytes.
                var niche_buf: [64]u8 = undefined;
                const niche = scoring.sanitizeMetaField(&niche_buf, utf8Prefix(self.eval_niche, 64));
                // Genome-send (graff-dgm.md §B): the eval genome is this agent's own
                // persona, never spawned via runSub, so its prompt_text never reached
                // the worker. A cell only promotes when harness_scores joins to a
                // harness_genomes row, so ride the genome text over on a `propose`
                // (deduped by prompt_sha) before the score — else a winning eval cell
                // has nothing to serve. Gated on a niche: a "" cell is unpromotable.
                // Oversized genomes skip the propose (review F6): the server verifies
                // the fingerprint over the carried text, so a truncated genome would
                // be dropped there anyway.
                if (niche.len > 0) {
                    if (sys.len <= telemetry.Telemetry.max_propose_text)
                        t.fleetEvent("propose", niche, genome, "", pclass, "", 0, sys)
                    else if (self.tracer) |tr| tr.note("fleet", "propose skipped: genome > 64KB");
                }
                // SCORE SCALE CONTRACT (issue #168 Gap 4): local UX stays
                // 0-100 (the /100 verdicts below, eval_best, eval_target),
                // but every score that leaves the client is [0,1] — divide at
                // the emission boundary; s01 is what gets signed (v2: niche +
                // provider_class in the envelope) and sent.
                const s01 = s / 100.0;
                const sig = signScore(genome, "", s01, run_id, "", "", esh, niche, pclass);
                const sig_s: []const u8 = if (scoring.g_score_key != null) &sig else "";
                var provbuf: [512]u8 = undefined;
                const prov = std.fmt.bufPrint(&provbuf, "{s}\t{s}\t{s}\t{s}\t{s}", .{ "", "", esh, pclass, niche }) catch "";
                t.scoreEvent(genome, "", s01, run_id, sig_s, prov);
                t.fleetEvent("submit", niche, genome, "", pclass, esh, 0, "");
            }
        }
    }

    var aw: Io.Writer.Allocating = .init(self.arena);
    const w = &aw.writer;
    if (combined) |s| {
        if (self.eval_judge != null) {
            try w.print("eval #{d}: deterministic {d:.1} + judge {d:.1} -> {d:.1}/100 (best {d:.1}, target {d}). ", .{ self.eval_iter, det.?, judge.?, s, self.eval_best, self.eval_target });
        } else {
            try w.print("eval #{d}: score {d:.1}/100 (best {d:.1}, target {d}). ", .{ self.eval_iter, s, self.eval_best, self.eval_target });
        }
        if (met)
            try w.writeAll("TARGET MET - verifier gate is green; finish only if no workspace-changing tool runs after this eval.")
        else if (improved)
            try w.writeAll("Improved, but still red - the prior plan is dropped. Make one focused repair, then run eval again; completion is blocked.")
        else
            try w.writeAll("No gain - the prior plan is dropped. Repair from current evidence and re-run eval; completion is blocked.");
    } else if (self.eval_judge != null and det != null and judge == null) {
        try w.print("eval #{d}: deterministic score {d:.1}/100, but the judge returned no parseable score (it may have errored). Re-run after checking the rubric. ", .{ self.eval_iter, det.? });
    } else {
        try w.print("eval #{d}: command ran but no score parsed - print a bare number, or JSON with a score field (0-100 or 0-1), on the last line. ", .{self.eval_iter});
    }
    const tail = if (run.stdout.len > 1500) run.stdout[run.stdout.len - 1500 ..] else run.stdout;
    try w.print("\n[exit {d}] eval output (tail):\n{s}", .{ exit_code, tail });
    return .{ .text = try self.arena.dupe(u8, aw.writer.buffered()), .is_error = false };
}

/// Append one tab-separated row to the scores log (.graff/eval-log.tsv).
/// Best-effort - a failed write never breaks the loop.
pub fn appendEvalLog(self: *Agent, note: []const u8, det: ?f64, judge: ?f64, score: ?f64, exit_code: i32, met: bool) !void {
    Io.Dir.cwd().createDir(self.io, ".graff", .default_dir) catch {};
    const path = ".graff/eval-log.tsv";
    const existing = Io.Dir.cwd().readFileAlloc(self.io, path, self.arena, .limited(2 * 1024 * 1024)) catch "";
    var aw: Io.Writer.Allocating = .init(self.arena);
    const w = &aw.writer;
    try w.writeAll(existing);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') try w.writeByte('\n');
    try w.print("iter={d}\tscore=", .{self.eval_iter});
    if (score) |s| try w.print("{d:.2}", .{s}) else try w.writeAll("NA");
    try w.writeAll("\tdet=");
    if (det) |d| try w.print("{d:.2}", .{d}) else try w.writeAll("NA");
    try w.writeAll("\tjudge=");
    if (judge) |j| try w.print("{d:.2}", .{j}) else try w.writeAll("NA");
    try w.print("\tbest={d:.2}\ttarget={d}\tmet={s}\texit={d}\tnote=", .{ self.eval_best, self.eval_target, if (met) "yes" else "no", exit_code });
    for (note) |ch| try w.writeByte(if (ch < 0x20) ' ' else ch);
    try w.writeByte('\n');
    Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = aw.writer.buffered() }) catch {};
}

/// Spawn an independent LLM judge (a read-only subagent) to score the
/// current work against the --judge rubric on a 0-100 scale. The judge
/// inspects the real artifacts with its own tools and ends its report with
/// a `score:` line, parsed the same way as a deterministic eval. Runs on a
/// pool thread via judgeTask (mirrors workflowTask) so the eval handler can
/// await it. Returns null if the judge could not run or gave no score.
pub fn runJudge(self: *Agent, rubric: []const u8, eval_output: []const u8, note: []const u8) ?f64 {
    const ctx: ToolCtx = .{
        .gpa = self.gpa,
        .io = self.io,
        .client = self.client,
        .provider = self.provider,
        .registry = if (self.sub) null else self.registry,
        .from_sub = self.sub,
        .approvals = self.approvals,
        .tracer = self.tracer,
        .run_budget = self.run_budget,
        .depth = self.depth,
        .snapshots = self.snapshots,
        .tools_used = &self.tools_used,
    };
    const evidence = if (eval_output.len > 1200) eval_output[eval_output.len - 1200 ..] else eval_output;
    const what = if (note.len > 0) note else "(no note given)";
    const judge_prompt = std.fmt.allocPrint(self.arena,
        \\Score the current state of the work in this directory against the rubric below, on a 0-100 scale.
        \\
        \\RUBRIC:
        \\{s}
        \\
        \\The author's note on the latest change: {s}
        \\
        \\An automated check was also run; its output (tail) is below as evidence. Form your OWN independent judgement of how well the artifacts satisfy the rubric - do not simply echo the check:
        \\---
        \\{s}
        \\---
        \\
        \\Inspect the actual files and artifacts the work produced (read them with your tools; do not modify anything), then score how fully they satisfy the rubric. End your reply with a single final line `score: <N>` where N is an integer from 0 to 100.
    , .{ rubric, what, evidence }) catch return null;
    var fut: Io.Future(ToolOutput) = self.io.async(judgeTask, .{ ctx, judge_prompt });
    const out = fut.await(self.io);
    defer self.gpa.free(out.text);
    if (out.is_error) return null;
    return parseEvalScore(out.text);
}
