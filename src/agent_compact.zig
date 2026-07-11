//! Context management: client-side history compaction (compact/
//! compactOrRecover) and emergency-trim recovery when compaction itself
//! can't run, plus the --eval/--until eval-driven loop (runEval/
//! appendEvalLog) and its optional LLM-as-judge scorer (runJudge). Split
//! out of the Agent struct (#123, 600-line goal).

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const utf8Prefix = @import("util.zig").utf8Prefix;

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

const provider_mod = @import("provider.zig"); // codex-ws regression tests below
const Provider = provider_mod.Provider;
const ws = @import("ws.zig");
const agent_ws = @import("agent_ws.zig"); // codexWsIdleExpired/codex_ws_idle_ms (#codex-ws)

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
    // #163: reclaim room BEFORE the summarization request so it fits under the
    // model's input cap. On codex/gpt-5.x an over-cap request fails to WRITE
    // (WriteFailed) rather than returning a clean overflow, so compaction could
    // never run once near the cap. Old tool outputs are superseded by the summary
    // anyway; truncating them keeps the request sendable + all pairing intact.
    _ = trimOldestToolOutputs(self);
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

/// True if `m` is a tool-output message whose payload can be truncated to
/// reclaim context: responses `function_call_output`, openai `role:"tool"`, or an
/// anthropic user message carrying `tool_result` blocks (#163).
fn isToolOutputMsg(m: Value) bool {
    if (m != .object) return false;
    if (m.object.get("type")) |t| if (t == .string and std.mem.eql(u8, t.string, "function_call_output")) return true;
    if (m.object.get("role")) |r| if (r == .string) {
        if (std.mem.eql(u8, r.string, "tool")) return true;
        if (std.mem.eql(u8, r.string, "user")) if (m.object.get("content")) |c| if (c == .array)
            for (c.array.items) |blk| {
                if (blk == .object) if (blk.object.get("type")) |bt|
                    if (bt == .string and std.mem.eql(u8, bt.string, "tool_result")) return true;
            };
    };
    return false;
}

fn truncateStrField(arena: Allocator, o: *std.json.ObjectMap, key: []const u8, cap: usize) usize {
    const v = o.get(key) orelse return 0;
    if (v != .string or v.string.len <= cap) return 0;
    const orig = v.string.len;
    const stub = std.fmt.allocPrint(arena, "{s}\n[old tool output truncated to recover context (#163)]", .{utf8Prefix(v.string, cap)}) catch return 0;
    o.put(arena, key, .{ .string = stub }) catch return 0;
    return orig -| stub.len;
}

/// Truncate an over-large tool-output payload in `m` in place to ~`cap` bytes,
/// preserving the message and its call/output pairing. Returns bytes reclaimed.
fn truncateToolOutput(arena: Allocator, m: *Value, cap: usize) usize {
    if (m.* != .object) return 0;
    if (m.object.get("type")) |t| if (t == .string and std.mem.eql(u8, t.string, "function_call_output"))
        return truncateStrField(arena, &m.object, "output", cap);
    if (m.object.get("role")) |r| if (r == .string) {
        if (std.mem.eql(u8, r.string, "tool")) return truncateStrField(arena, &m.object, "content", cap);
        if (std.mem.eql(u8, r.string, "user")) if (m.object.get("content")) |c| if (c == .array) {
            var saved: usize = 0;
            for (m.object.get("content").?.array.items) |*blk| {
                if (blk.* != .object) continue;
                const bt = blk.object.get("type") orelse continue;
                if (bt == .string and std.mem.eql(u8, bt.string, "tool_result"))
                    saved += truncateStrField(arena, &blk.object, "content", cap);
            }
            return saved;
        };
    };
    return 0;
}

/// #163: reclaim context when it has overflowed and there is no clean user turn
/// to cut at (a runaway tool loop is all tool_call/tool_result after the last
/// user turn). Truncate the OLDEST tool outputs in place, keeping the most recent
/// `keep_recent` verbatim (opencode-style) and every call/output pair intact
/// (codex's trim_function_call_history). Never drops a message, so no orphaned
/// tool_result can reach the API. Returns bytes reclaimed.
pub fn trimOldestToolOutputs(self: *Agent) usize {
    const keep_recent: usize = 4;
    const stub_cap: usize = 400;
    var total: usize = 0;
    for (self.messages.items) |m| {
        if (isToolOutputMsg(m)) total += 1;
    }
    if (total <= keep_recent) return 0;
    var seen: usize = 0;
    var reclaimed: usize = 0;
    for (self.messages.items) |*m| {
        if (!isToolOutputMsg(m.*)) continue;
        seen += 1;
        if (seen > total - keep_recent) break; // keep the most recent verbatim
        reclaimed += truncateToolOutput(self.arena, m, stub_cap);
    }
    if (reclaimed > 0) self.last_context_tokens = 0; // force a re-measure next turn
    return reclaimed;
}

/// Last-resort context recovery when compact() itself can't run — typically
/// because the history already overflows the window, so the summarization
/// request overflows too and fails. Drops the oldest messages at a safe
/// boundary; returns the count dropped (0 if none). The next turn re-measures
/// context from the provider usage.
pub fn emergencyTrim(self: *Agent) usize {
    if (emergencyCutIndex(self.messages.items)) |cut| {
        var fresh = std.json.Array.init(self.arena);
        for (self.messages.items[cut..]) |m| fresh.append(m) catch return 0;
        self.messages = fresh;
        self.last_context_tokens = 0;
        return cut;
    }
    // #163: no clean user turn to cut at (a runaway tool loop). Don't wedge the
    // session — reclaim context by truncating the oldest tool outputs in place,
    // keeping every call/output pair valid. Nonzero = recovered.
    return if (trimOldestToolOutputs(self) > 0) 1 else 0;
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

test "trimOldestToolOutputs recovers a runaway tool-loop history (#163)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    try msgs.append(try textMessage(a, "user", "babysit the CI")); // the only clean user turn
    const big = try a.alloc(u8, 5000);
    @memset(big, 'x');
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "type", .{ .string = "function_call_output" });
        try o.put(a, "call_id", .{ .string = "c" });
        try o.put(a, "output", .{ .string = big });
        try msgs.append(.{ .object = o });
    }
    var agent: Agent = undefined;
    agent.messages = msgs;
    agent.arena = a;
    agent.last_context_tokens = 100000;
    // no clean user turn after the midpoint -> the old emergencyTrim would give up
    try std.testing.expect(emergencyCutIndex(agent.messages.items) == null);
    const reclaimed = trimOldestToolOutputs(&agent);
    try std.testing.expect(reclaimed > 0); // recovered instead of wedging
    try std.testing.expectEqual(@as(usize, 0), agent.last_context_tokens); // forces a re-measure
    var truncated: usize = 0;
    var full: usize = 0;
    for (agent.messages.items) |m| {
        if (m == .object) if (m.object.get("output")) |out| if (out == .string) {
            if (out.string.len < 1000) truncated += 1 else full += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 6), truncated); // 10 outputs, oldest 6 truncated
    try std.testing.expectEqual(@as(usize, 4), full); // 4 most-recent kept verbatim
    try std.testing.expectEqual(@as(usize, 11), agent.messages.items.len); // no message dropped
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

// (#codex-ws) The delta-body detection string check in agent_ws.zig's
// postLive() gates the WS-reanchor path (never SSE-replay a delta): it
// looks for the literal `"previous_response_id"` key that buildBody's
// .responses branch emits. Pin the exact substring so the two stay in
// sync — a future rename of the JSON key on either side breaks this test
// instead of silently reopening the SSE-replay bug.
test "postLive's delta-body detection matches the key buildBody emits (codex-ws)" {
    const delta_body = "{\"model\":\"gpt-5\",\"previous_response_id\":\"resp_1\",\"input\":[]}";
    const full_body = "{\"model\":\"gpt-5\",\"input\":[]}";
    try std.testing.expect(std.mem.indexOf(u8, delta_body, "\"previous_response_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, full_body, "\"previous_response_id\"") == null);
}

// (#codex-ws) The preemptive idle re-anchor decision (postResponsesWs closes a
// held WS the server has likely already killed instead of eating a failed
// round trip). Pure helper so no socket is needed: exactly-at-limit must NOT
// expire (only strictly past it), and a WS used moments ago must survive.
// opencode pools at 5 min; ours defaults to 4 (the backend killed a real
// session within 8.5 min idle).
test "codexWsIdleExpired: fires only strictly past the idle limit (codex-ws)" {
    const limit = agent_ws.codex_ws_idle_ms;
    try std.testing.expectEqual(@as(i64, 4 * std.time.ms_per_min), limit); // default: stay under the observed server kill
    try std.testing.expect(!agent_ws.codexWsIdleExpired(1_000_000, 1_000_000)); // just used
    try std.testing.expect(!agent_ws.codexWsIdleExpired(1_000_000 + limit, 1_000_000)); // exactly at the limit — keep
    try std.testing.expect(agent_ws.codexWsIdleExpired(1_000_000 + limit + 1, 1_000_000)); // past it — re-anchor
    try std.testing.expect(agent_ws.codexWsIdleExpired(1_000_000 + 510 * std.time.ms_per_s, 1_000_000)); // the real 8.5-min trace gap
}

// (#codex-ws) End-to-end regression for the reanchor fix: buildBody's
// .responses branch must emit previous_response_id + a message-slice delta
// while a WS session + prev id are held, and after closeCodexWs (called by
// postLive on a delta transport error, and again by request()'s
// error.CodexWsReanchor handler) a rebuilt body must carry the FULL
// message history with no previous_response_id — never a stale delta
// replayed against a dead session.
test "buildBody (.responses): delta while WS live; full input after closeCodexWs (codex-ws)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var msgs = std.json.Array.init(a);
    try msgs.append(try textMessage(a, "user", "first"));
    try msgs.append(try textMessage(a, "assistant", "second"));
    try msgs.append(try textMessage(a, "user", "third — not yet sent"));

    var dummy_ws: ws.WsClient = undefined; // buildBody only checks != null, never dereferences
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = a,
        .io = undefined, // unused by buildBody
        .client = undefined, // unused by buildBody
        .provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "https://x/responses", .api_key = "k", .model = "gpt-5", .context = 100_000 },
        .messages = msgs,
        .sub = false,
        .label = "",
        .out = null,
        .codex_ws = &dummy_ws,
        .codex_prev_id = try std.testing.allocator.dupe(u8, "resp_live"),
        .codex_sent_upto = 2, // server already holds messages[0..2]; delta = [2..]
    };

    const delta_body = try agent.buildBody(null, false, false, false);
    defer std.testing.allocator.free(delta_body);
    try std.testing.expect(std.mem.indexOf(u8, delta_body, "\"previous_response_id\":\"resp_live\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, delta_body, "third — not yet sent") != null);
    try std.testing.expect(std.mem.indexOf(u8, delta_body, "\"first\"") == null); // NOT resent — already on the server

    // Simulate closeCodexWs's effect (covered by its own unit test above)
    // without invoking it directly: it would call ws.WsClient.deinit on
    // codex_ws, which sends a real close frame over `dummy_ws`'s
    // uninitialized io/fd — fine for a live connection, unsafe for this
    // struct-literal stand-in. What matters here is buildBody's behavior
    // given the post-close state postLive/request() leave it in.
    std.testing.allocator.free(agent.codex_prev_id.?);
    agent.codex_ws = null;
    agent.codex_prev_id = null;
    agent.codex_sent_upto = 0;
    const rebuilt_body = try agent.buildBody(null, false, false, false);
    defer std.testing.allocator.free(rebuilt_body);
    try std.testing.expect(std.mem.indexOf(u8, rebuilt_body, "\"previous_response_id\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, rebuilt_body, "\"first\"") != null); // full history restored
    try std.testing.expect(std.mem.indexOf(u8, rebuilt_body, "third — not yet sent") != null);
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
