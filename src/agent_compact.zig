//! Context management: client-side history compaction (compact/
//! compactOrRecover) and emergency-trim recovery when compaction itself
//! can't run, plus the --eval/--until eval-driven loop (runEval/
//! appendEvalLog) and its optional LLM-as-judge scorer (runJudge). Split
//! out of the Agent struct (#123, 600-line goal).

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const repl_glue = @import("repl_glue.zig");
const Agent = agent_mod.Agent;
const ToolCall = tools_mod.ToolCall;
const ExecResult = tools_mod.ExecResult;
const parseEvalScore = repl_glue.parseEvalScore;
const prompts = @import("prompts.zig");
const compact_instruction = prompts.compact_instruction;

const messages_mod = @import("messages.zig");
const textMessage = messages_mod.textMessage;

const title_mod = @import("title.zig");
const assistantText = title_mod.assistantText;

const scoring = @import("scoring.zig");
const promptFingerprint = scoring.promptFingerprint;
const providerClass = scoring.providerClass;
const signScore = scoring.signScore;

const telemetry = @import("telemetry.zig");

const jobs = @import("jobs.zig");
const runCapped = jobs.runCapped;

const tools_mod = @import("tools.zig");
const ToolCtx = tools_mod.ToolCtx;
const ToolOutput = tools_mod.ToolOutput;

const subagent = @import("subagent.zig");
const judgeTask = subagent.judgeTask;

/// Run the configured --eval scoring command, append the result to the
/// scores log (.graff/eval-log.tsv), and return a verdict for the model:
/// score (0-100), best so far, target, and whether the target is met. The
/// harness runs the command, so the model cannot fake the number. (eval tool)
pub fn runEval(self: *Agent, note: []const u8) !ExecResult {
    const cmd = self.eval_cmd orelse return .{
        .text = "no eval command configured - relaunch graff with --eval <scoring cmd> and --until <N>, or ask the user to set one",
        .is_error = true,
    };
    const run = runCapped(self.gpa, self.io, &.{ "/bin/sh", "-c", cmd }, 64 * 1024, 16 * 1024, 0) catch |e|
        return .{ .text = try std.fmt.allocPrint(self.arena, "eval command could not run: {t}", .{e}), .is_error = true };
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
    self.appendEvalLog(note, det, judge, combined, exit_code, met) catch {};

    // Feed the eval-driven score into the fleet (docs/hyperagents.md §9.B):
    // on a NEW BEST, submit the genome (this agent's persona) with its achieved
    // score on the pinned eval set (the eval command's fingerprint). Without this
    // the score only ever reached .graff/eval-log.tsv and the DGM/fleet never saw
    // real eval-driven work — only darwincode/JSON-proto runs ever submitted.
    if (combined) |s| {
        if (improved and s > 0) { // s>0: skip the initial-state / total-failure 0 (don't pollute the cell mean)
            if (telemetry.g_telem) |t| {
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
                const niche = self.eval_niche;
                // Genome-send (graff-dgm.md §B): the eval genome is this agent's own
                // persona, never spawned via runSub, so its prompt_text never reached
                // the worker. A cell only promotes when harness_scores joins to a
                // harness_genomes row, so ride the genome text over on a `propose`
                // (deduped by prompt_sha) before the score — else a winning eval cell
                // has nothing to serve. Gated on a niche: a "" cell is unpromotable.
                if (niche.len > 0) t.fleetEvent("propose", niche, genome, "", pclass, "", 0, sys);
                const sig = signScore(genome, "", s, run_id, "", "", esh);
                const sig_s: []const u8 = if (scoring.g_score_key != null) &sig else "";
                var provbuf: [512]u8 = undefined;
                const prov = std.fmt.bufPrint(&provbuf, "{s}\t{s}\t{s}\t{s}\t{s}", .{ "", "", esh, pclass, niche }) catch "";
                t.scoreEvent(genome, "", s, run_id, sig_s, prov);
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
            try w.writeAll("TARGET MET - finish and report the final scores.")
        else if (improved)
            try w.writeAll("Improved - keep going: fix the next biggest failure with one focused change.")
        else
            try w.writeAll("No gain over the best - try a different change; do not build on a regression.");
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

/// Ask the model for a context-handoff summary (no tools), then restart
/// history from that summary.
pub fn compact(self: *Agent) anyerror!usize {
    if (self.messages.items.len == 0) {
        if (!main_mod.json_mode) try self.say("nothing to compact\n", .{});
        return 0;
    }
    if (!main_mod.json_mode) try self.say("[compacting ~{d} tokens…]\n", .{self.last_context_tokens});
    try self.messages.append(try textMessage(self.arena, "user", compact_instruction));
    errdefer _ = self.messages.pop();

    // The handoff summary is internal — don't stream it to the terminal.
    self.stream_quiet = true;
    defer self.stream_quiet = false;
    const root = try self.request(null);
    const summary = assistantText(self.provider.kind, root);
    if (summary.len == 0) {
        if (!main_mod.json_mode) try self.say("[compaction failed: empty summary, history unchanged]\n", .{});
        _ = self.messages.pop();
        return error.EmptySummary;
    }

    var fresh = std.json.Array.init(self.arena);
    const handoff = try std.fmt.allocPrint(self.arena,
        \\Context: the prior conversation was compacted to save space.
        \\Summary of everything so far:
        \\
        \\{s}
        \\
        \\Continue assisting the user based on this summary.
    , .{summary});
    try fresh.append(try textMessage(self.arena, "user", handoff));
    self.messages = fresh;
    self.last_context_tokens = 0;
    if (!main_mod.json_mode) try self.say("[history compacted to a {d}-char summary]\n", .{summary.len});
    return summary.len;
}

pub fn cleanUserTurn(m: Value) bool {
    if (m != .object) return false;
    const role = m.object.get("role") orelse return false;
    if (role != .string or !std.mem.eql(u8, role.string, "user")) return false;
    const content = m.object.get("content") orelse return true;
    switch (content) {
        .string => return true, // a plain-text user turn
        .array => |arr| {
            // An anthropic user message that only carries tool_result blocks
            // is the response half of a tool call — it can't begin a
            // conversation, so it is not a safe trim boundary.
            for (arr.items) |blk| {
                if (blk != .object) continue;
                const t = blk.object.get("type") orelse continue;
                if (t == .string and std.mem.eql(u8, t.string, "tool_result")) return false;
            }
            return true;
        },
        else => return true,
    }
}

/// Index to cut history at for an emergency trim: the first clean user turn
/// at or after the midpoint, so messages[cut..] is always a valid
/// conversation start (never an orphaned tool_result). null when there is no
/// safe cut — too short, or only tool_result user messages remain.
pub fn emergencyCutIndex(items: []const Value) ?usize {
    if (items.len < 4) return null;
    var i: usize = items.len / 2;
    while (i < items.len) : (i += 1) {
        if (cleanUserTurn(items[i])) return i;
    }
    return null;
}

/// Last-resort context recovery when compact() itself can't run — typically
/// because the history already overflows the window, so the summarization
/// request overflows too and fails. Drops the oldest messages at a safe
/// boundary; returns the count dropped (0 if none). The next turn re-measures
/// context from the provider usage.
pub fn emergencyTrim(self: *Agent) usize {
    const cut = emergencyCutIndex(self.messages.items) orelse return 0;
    var fresh = std.json.Array.init(self.arena);
    for (self.messages.items[cut..]) |m| fresh.append(m) catch return 0;
    self.messages = fresh;
    self.last_context_tokens = 0;
    return cut;
}

/// Auto-compaction with recovery. compact() summarizes the whole history in
/// one request; once context overflows the window that request overflows too
/// and fails — historically swallowed silently, wedging the session so every
/// later turn failed at the same huge token count (issue #88). Surface the
/// failure and, when `trim_on_fail`, emergency-trim so the next turn has
/// room. Best-effort; never throws into the REPL loop.
pub fn compactOrRecover(self: *Agent, trim_on_fail: bool) void {
    if (self.compact()) |_| return else |err| {
        switch (err) {
            error.Interrupted => return, // user hit Esc mid-compaction
            error.EmptySummary => {}, // compact() already explained it
            else => {
                if (main_mod.json_mode)
                    self.emit(.{ .type = "error", .message = std.fmt.allocPrint(self.arena, "auto-compaction failed: {s}", .{@errorName(err)}) catch "auto-compaction failed" })
                else
                    self.say("[auto-compaction failed: {t}]\n", .{err}) catch {};
            },
        }
        if (!trim_on_fail) return;
        const dropped = self.emergencyTrim();
        if (dropped > 0) {
            if (main_mod.json_mode)
                self.emit(.{ .type = "compact", .ok = true, .trimmed = dropped })
            else
                self.say("[context emergency-trimmed: dropped {d} old message(s) so the session can continue]\n", .{dropped}) catch {};
        } else if (!main_mod.json_mode) {
            self.say("[warning: context too large to compact and could not be trimmed safely]\n", .{}) catch {};
        }
    }
}

test "cleanUserTurn: plain user text yes; assistant/tool_result no" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect(cleanUserTurn(try textMessage(a, "user", "hello")));
    try std.testing.expect(!cleanUserTurn(try textMessage(a, "assistant", "hi")));
    // an anthropic tool_result-only user message is NOT a clean conversation start
    const tr = try std.json.parseFromSliceLeaky(Value, a, "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"ok\"}]}", .{});
    try std.testing.expect(!cleanUserTurn(tr));
}

test "closeCodexWs resets the delta session state + frees the response id (codex-ws)" {
    var agent: Agent = undefined;
    agent.gpa = std.testing.allocator;
    agent.codex_ws = null; // no live WsClient to deinit in a unit test
    agent.codex_prev_id = try std.testing.allocator.dupe(u8, "resp_abc123"); // must be freed (leak-checked)
    agent.codex_sent_upto = 5;
    agent.closeCodexWs();
    try std.testing.expect(agent.codex_prev_id == null); // freed + nulled
    try std.testing.expectEqual(@as(usize, 0), agent.codex_sent_upto); // delta boundary reset
    try std.testing.expect(agent.codex_ws == null);
}

test "emergencyCutIndex: cuts at a clean user turn at/after the midpoint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var items = std.json.Array.init(a);
    const roles = [_][]const u8{ "user", "assistant", "user", "assistant", "user", "assistant", "user", "assistant" };
    for (roles) |r| try items.append(try textMessage(a, r, "x"));
    try std.testing.expectEqual(@as(?usize, 4), emergencyCutIndex(items.items)); // midpoint 4 is a user turn
    try std.testing.expectEqual(@as(?usize, null), emergencyCutIndex(items.items[0..3])); // too short to trim
}

test "emergencyCutIndex: skips a tool_result user message at the midpoint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var items = std.json.Array.init(a);
    try items.append(try textMessage(a, "user", "x")); // 0
    try items.append(try textMessage(a, "assistant", "x")); // 1
    try items.append(try textMessage(a, "user", "x")); // 2
    try items.append(try textMessage(a, "assistant", "x")); // 3
    // 4: an anthropic tool_result-only user message (not a valid conversation start)
    try items.append(try std.json.parseFromSliceLeaky(Value, a, "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"x\"}]}", .{})); // 4 (skip)
    try items.append(try textMessage(a, "assistant", "x")); // 5
    try items.append(try textMessage(a, "user", "x")); // 6 (first clean user >= midpoint)
    try items.append(try textMessage(a, "assistant", "x")); // 7
    try std.testing.expectEqual(@as(?usize, 6), emergencyCutIndex(items.items));
}
