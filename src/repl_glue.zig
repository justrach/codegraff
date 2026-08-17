//! The `graff repl` (chat-mode) bridge — run a full root-agent turn (tools +
//! MCP) per repl.TurnFn call, plus the model-switch/cancel adapters — and the
//! goal/eval steering-note assembly shared by both the REPL and interactive
//! loops. Also the steering queue drain and /effort /fast /ultracode
//! persistence (save/loadThinkingSettings). Split out of main.zig (#123).
//!
//! The mutable steer/thinking globals (g_steer_buf, g_steer_queue,
//! g_steer_echoed, g_steer_visible, g_out) stay declared in main.zig and are
//! reached via `main_mod.g_x`, never a local alias (would freeze its value).
//!
//! parseEvalScore/steerEcho/saveThinkingSettings stay pub — subagent.zig,
//! agent_compact.zig, agent_interrupt.zig, commands_model.zig back-import them.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const Agent = agent_mod.Agent;
const Provider = provider_mod.Provider;
const Keys = provider_mod.Keys;
const ReasoningEffort = main_mod.ReasoningEffort;

const mcp = @import("mcp.zig");
const repl = @import("repl.zig");
const approvals_mod = @import("approvals.zig");
const Approvals = approvals_mod.Approvals;
const pricing = @import("pricing.zig");
const trace = @import("trace.zig");
const serde = @import("serde.zig");
const fallback_config = @import("fallback_config.zig");

pub const ReplCtx = struct {
    io: Io,
    client: *std.http.Client,
    keys: Keys,
    home: []const u8,
    provider: Provider,
    fallback_allow: []const []const u8,
    fallback_active: bool,
    fallback_blocked: bool,
    registry: ?*mcp.Registry,
    tracer: ?*trace.Tracer,
    run_budget: ?*@import("run_budget.zig").RunBudget,
    sys_normal: []const u8,
    tools_anthropic: []const u8,
    tools_openai: []const u8,
    tools_responses: []const u8,
    /// The session's conversation, when the frontend wants the engine to own
    /// it (#551). Null = the caller has no session memory and each turn is
    /// built from the transcript it passes in, which is what `graff repl`'s
    /// scripted path still does.
    convo: ?*repl_convo.Conversation = null,
    /// The context meter, carried between turns (#551). A chat frontend builds
    /// a fresh Agent per turn, so leaving these on it reset the meter every
    /// turn — and with them the pre-send compaction gate, which reads exactly
    /// these numbers to decide when the window is nearly full.
    last_context_tokens: u64 = 0,
    context_local_tokens: u64 = 0,
    last_cache_read: u64 = 0,
};

/// The engine-owned conversation, in repl_convo.zig (move+alias, #123).
pub const Conversation = repl_convo.Conversation;
const repl_convo = @import("repl_convo.zig");

test { // or their tests silently never run (unit_tests' root is main.zig)
    _ = repl_convo;
    _ = @import("repl_model_pick_test.zig");
}

/// The live-pane writer, in repl_stream_sink.zig (move+alias, #123).
pub const ReplStreamSink = @import("repl_stream_sink.zig").ReplStreamSink;

/// The standing-goal steering note for a turn when /goal is set. The checklist
/// itself is deliberately NOT embedded (#318): the model sees it in todo_write
/// results, and re-pasting it every turn is how a dead goal's items kept
/// steering later work. The ONE exception is compaction, where those results
/// are gone - goal_flow.compactionSnapshot restates the list into the new
/// history instead, so this text (and its fingerprint) never moves. Returns ""
/// when goal is null/inactive; injection is diff-gated by goal_state.steeringGate.
pub fn goalSteeringNote(arena: Allocator, goal: ?agent_mod.Goal) ![]const u8 {
    const g = goal orelse return "";
    if (g.status != .active) return ""; // paused/blocked/complete/budget_limited never steer (#223)
    // A --goal objective is the user's policy for the session, so its note must
    // not coach the model into ending it: the old text told every turn to call
    // attempt_completion "to end this steering", and one such call left the rest
    // of a headless/SDK session running unsteered (#318).
    if (g.standing)
        return std.fmt.allocPrint(arena, "[standing goal: {s} - keep this objective in view on every task; track multi-step work as a live todo_write checklist (todo_read shows the current one; todo_write REPLACES it - completed items you omit are kept, open items you omit are dropped), marking each item in_progress when you start and completed when done. This steering persists for the whole session.]", .{g.objective});
    return std.fmt.allocPrint(arena, "[standing goal: {s} - track this as a live todo_write checklist and work through it (todo_read shows the current one; todo_write REPLACES it - completed items you omit are kept, open items you omit are dropped), marking each item in_progress when you start and completed when done. When the objective is verifiably done, call attempt_completion - that completes the goal and ends this steering.]", .{g.objective});
}

/// Extract a 0-100 score from eval output ([0,1] scales up): a `score` key
/// (JSON or key=val) if present, else a last line that IS a number — whole
/// line, never a leading prefix (#367: pytest's "4 passed in 0.01s" scored a
/// green suite 4/100, and "1 failed" → 1 → the fraction rule → a false 100;
/// prose is not a score — plain runners ride runEval's exit-code fallback).
pub fn parseEvalScore(out: []const u8) ?f64 {
    if (std.mem.indexOf(u8, out, "score")) |i| {
        var j = i + 5;
        while (j < out.len and out[j] != ':' and out[j] != '=' and out[j] != '\n') j += 1;
        if (j < out.len and (out[j] == ':' or out[j] == '=')) {
            j += 1;
            while (j < out.len and (out[j] == ' ' or out[j] == '\t' or out[j] == '"')) j += 1;
            if (parseLeadingNumber(out[j..])) |v| return normalizeScore(v);
        }
    }
    const trimmed = std.mem.trimEnd(u8, out, " \t\r\n");
    const last = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |k| trimmed[k + 1 ..] else trimmed;
    return normalizeScore(std.fmt.parseFloat(f64, std.mem.trim(u8, last, " \t\r\n")) catch return null);
}

fn parseLeadingNumber(s: []const u8) ?f64 {
    var end: usize = 0;
    while (end < s.len and (std.ascii.isDigit(s[end]) or s[end] == '.' or s[end] == '-' or s[end] == '+')) end += 1;
    if (end == 0) return null;
    return std.fmt.parseFloat(f64, s[0..end]) catch null;
}

fn normalizeScore(v: f64) f64 {
    if (v >= 0.0 and v <= 1.0) return v * 100.0;
    return v;
}

/// Steering injected each turn when --eval is set: the eval-driven loop
/// discipline (score -> one focused change -> re-score -> log -> stop at
/// target). Returns "" when no eval command is configured.
pub fn evalSteeringNote(
    arena: Allocator,
    eval_cmd: ?[]const u8,
    target: u8,
    has_judge: bool,
    verified: bool,
    repair_pending: bool,
    notes: []const u8,
) ![]const u8 {
    if (eval_cmd == null) return "";
    const gate = if (has_judge)
        " An LLM judge is also configured, so the target is met only when BOTH the deterministic score AND the judge score reach it - read both numbers the `eval` tool reports."
    else
        "";
    const state = if (repair_pending)
        "RED: the last committed expectation was contradicted. The prior plan is dropped; make one repair and re-run eval. attempt_completion is blocked."
    else if (verified)
        "GREEN: the latest workspace state met the target. Any workspace-changing tool makes this state stale and requires another eval."
    else
        "UNVERIFIED: establish or refresh the verifier baseline before completion.";
    return std.fmt.allocPrint(arena,
        \\[eval-driven loop active. A scoring command is configured. Verifier state: {s}
        \\Work it as a predict→act→verify→repair loop: (1) call `eval` to score the current state—the harness runs the command and logs it, so do NOT run it via bash; (2) state one hypothesis; (3) make ONE focused change; (4) call `eval` again. Continue until the latest eval reaches {d}/100.{s} A failed eval drops the prior plan. Use the eval `note` field to append CONFIRMED/GUESS/HYPOTHESIS/FACT belief updates; this task-class memory is re-injected after compaction.
        \\
        \\Local run-scoped notes (never uploaded by this mechanism):
        \\{s}]
    , .{ state, target, gate, notes });
}

test "goalSteeringNote: active-only gate, completion contract, and no embedded checklist (#318)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    // No goal -> empty note, caller skips the append.
    try std.testing.expectEqualStrings("", try goalSteeringNote(ar, null));

    // A paused (non-active) goal never steers (#223): empty note.
    try std.testing.expectEqualStrings("", try goalSteeringNote(ar, .{ .objective = "close all issues", .status = .paused }));

    // Active goal -> bracket note with the completion contract; the checklist
    // is never embedded (it reaches the model via todo_write results).
    const n1 = try goalSteeringNote(ar, .{ .objective = "close all issues" });
    try std.testing.expect(std.mem.startsWith(u8, n1, "[standing goal: close all issues - track this as a live todo_write checklist"));
    try std.testing.expect(std.mem.indexOf(u8, n1, "attempt_completion") != null);
    try std.testing.expect(std.mem.indexOf(u8, n1, "Checklist so far") == null);
    try std.testing.expect(std.mem.indexOf(u8, n1, "(no todos)") == null);

    // A --goal standing objective keeps the checklist guidance but drops the
    // self-termination clause: the model cannot retire it, so telling it to
    // "call attempt_completion and end this steering" was a lie that cost every
    // later turn of a headless/SDK session its goal (#318).
    const n2 = try goalSteeringNote(ar, .{ .objective = "close all issues", .standing = true });
    try std.testing.expect(std.mem.startsWith(u8, n2, "[standing goal: close all issues - keep this objective in view"));
    try std.testing.expect(std.mem.indexOf(u8, n2, "todo_write checklist") != null);
    try std.testing.expect(std.mem.indexOf(u8, n2, "attempt_completion") == null);
    try std.testing.expect(std.mem.indexOf(u8, n2, "persists for the whole session") != null);
    // Still gated on .active: /goal pause silences a standing goal too.
    try std.testing.expectEqualStrings("", try goalSteeringNote(ar, .{ .objective = "x", .standing = true, .status = .paused }));
}

/// #226 continuation gate — the outcome when a /loop turn finishes: the loop
/// either runs another turn or stops with a NAMED terminal state (surfaced in
/// the transcript so #219's ledger can later record it verbatim). Budget-free.
/// One sentence per outcome, because the tag alone misleads: a user reading a
/// dim "idle" at the end of an unattended run assumes success, when it means
/// the model stopped WITHOUT finishing. Success and the four failure modes
/// must not differ by one word.
pub fn outcomeText(outcome: ContinuationOutcome, iter_cap: u32) []const u8 {
    _ = iter_cap;
    return switch (outcome) {
        .accepted => "done - the work was completed",
        .idle => "idle - the model stopped without finishing; the work is NOT done",
        .exhausted => "out of turns - the iteration cap was reached with work still open",
        .expired => "out of time - the budget ran out with work still open",
        .blocked => "blocked - it needs you before it can continue",
        .cancelled => "paused - you stepped in",
    };
}

pub const ContinuationOutcome = enum {
    accepted, // the goal's checklist is complete (or the goal itself is complete)
    idle, // the turn did no tool work and asserted nothing - the loop stops, but nothing is done (#318)
    exhausted, // hit the hard per-/loop iteration bound with work still open
    expired, // the run's wall-clock budget (`/loop 30m ...`) ran out with work still open
    blocked, // the goal is blocked and needs the user
    cancelled, // the goal was paused — the user stepped in
};

pub const ContinuationDecision = union(enum) {
    continue_turn, // run another /loop turn without reading a new user line
    stop: ContinuationOutcome, // return control to the prompt with this named outcome
};

/// Pure controller decision for /loop continuation (#226): continuation is
/// authorized by CONTROLLER STATE, never by the model merely stopping. An active
/// goal with the checklist still open and iterations left keeps going; a
/// paused or blocked goal, or a spent iteration bound, yields the matching
/// named terminal outcome. No budgets. `accepted` is reserved for real evidence
/// of completion: a turn that merely did nothing stops as `idle` (#318), and a
/// goal that was already complete when the run started decides nothing at all.
pub fn continuationDecision(
    goal_status: agent_mod.GoalStatus,
    work_done: bool,
    model_stopped: bool,
    iters_left: u32,
) ContinuationDecision {
    if (work_done) return .{ .stop = .accepted };
    switch (goal_status) {
        .paused => return .{ .stop = .cancelled },
        .blocked => return .{ .stop = .blocked },
        // A goal completed DURING this run already stopped it through work_done
        // (attempt_completion sets root.completed) or through mainloop's
        // flip-then-stop, so .complete here is a LEFTOVER objective from an
        // earlier run or a resume reconciliation. It must not label a fresh
        // /loop `accepted` at iteration 1 before anything happened (#318).
        .complete, .active => {},
    }
    if (model_stopped) return .{ .stop = .idle };
    if (iters_left == 0) return .{ .stop = .exhausted };
    return .continue_turn;
}

/// Did this turn genuinely stop working? Zero tool calls is the model declining
/// to act - but a REFUSED attempt_completion is exempt from the tool counter,
/// and that is exactly a turn where the model acted and got an is_error back to
/// react to. Reading it as silence killed the /loop on the very turn the
/// completion gate meant to keep alive (#318).
pub fn turnStopped(tool_calls: u64, completion_refused: bool) bool {
    return tool_calls == 0 and !completion_refused;
}

test "continuationDecision: one assertion per branch (#226)" {
    // work asserted or the checklist finished -> accepted, regardless of iters.
    try std.testing.expectEqual(ContinuationOutcome.accepted, continuationDecision(.active, true, false, 5).stop);
    // active + open todos + iterations left -> continue.
    try std.testing.expect(std.meta.activeTag(continuationDecision(.active, false, false, 5)) == .continue_turn);
    // active + open todos + iteration bound spent -> exhausted.
    try std.testing.expectEqual(ContinuationOutcome.exhausted, continuationDecision(.active, false, false, 0).stop);
    // paused -> cancelled (the user stepped in).
    try std.testing.expectEqual(ContinuationOutcome.cancelled, continuationDecision(.paused, false, false, 5).stop);
    // blocked -> blocked.
    try std.testing.expectEqual(ContinuationOutcome.blocked, continuationDecision(.blocked, false, false, 5).stop);
    // a LEFTOVER complete goal governs nothing: work decides, exactly as .active.
    try std.testing.expect(std.meta.activeTag(continuationDecision(.complete, false, false, 5)) == .continue_turn);
    try std.testing.expectEqual(ContinuationOutcome.accepted, continuationDecision(.complete, true, false, 5).stop);
}

test "a zero-tool turn stops as idle, not accepted; a refused completion keeps the loop (#318)" {
    // The model stopped with the checklist still open: the loop ends, but
    // labelling that `accepted` claimed a goal was done that nobody finished.
    try std.testing.expectEqual(ContinuationOutcome.idle, continuationDecision(.active, false, true, 5).stop);
    // Real evidence still earns `accepted`.
    try std.testing.expectEqual(ContinuationOutcome.accepted, continuationDecision(.active, true, true, 5).stop);
    // A refused attempt_completion is work, so the turn is not "stopped" ...
    try std.testing.expect(turnStopped(0, false));
    try std.testing.expect(!turnStopped(0, true));
    try std.testing.expect(!turnStopped(3, false));
    // ... and the loop runs another turn so the model can react to the refusal.
    try std.testing.expect(std.meta.activeTag(continuationDecision(.active, false, turnStopped(0, true), 5)) == .continue_turn);
}

/// repl.TurnFn — one full ROOT agent turn. The body lives in repl_turn.zig
/// (move+alias, 600-line cap); `repl_glue.replTurnCb` still resolves, and
/// repl_turn.Policy is where a turn's mode/strict becomes engine behavior.
pub const replTurnCb = @import("repl_turn.zig").replTurnCb;

test {
    // An alias does not pull a sibling's tests in — name it so the policy
    // regressions in repl_turn.zig are actually compiled and run.
    _ = @import("repl_turn.zig");
}

/// repl.ModelFn adapter — switch the active model by name. Resolve its provider
/// using the same model-routing rules as /model, then persist that
/// explicit choice for the next launch. Automatic turn fallback updates only
/// `c.provider`, never this preference file.
pub fn replModelCb(ctx_ptr: ?*anyopaque, gpa: Allocator, name: []const u8) ?[]const u8 {
    const picked = replModelPick(ctx_ptr, gpa, "", name) orelse return null;
    return picked.model;
}

/// What a model switch settled on. The provider id travels back because the
/// caller may have asked for a model TWO providers serve, and which one it
/// landed on is the difference between spending a plan and spending a key.
pub const Picked = struct { model: []const u8, provider: []const u8 };

/// The catalog's own copy of this seat's model name. Borrowing it rather than
/// duplicating keeps the switched Provider pointing at storage that outlives
/// the caller's buffer, which is what the name-routed path has always done.
fn catalogName(provider_id: []const u8, name: []const u8) ?[]const u8 {
    for (pricing.models()) |m|
        if (std.mem.eql(u8, m.provider, provider_id) and std.mem.eql(u8, m.name, name)) return m.name;
    return null;
}

/// Switch to `name` on a NAMED provider. An empty `provider_id` means the
/// caller does not know one (a hand-typed `/model <name>`) and the router
/// picks, which is the old behaviour. When it IS known — the catalog row the
/// user clicked — that seat is honoured or the switch fails; silently
/// rerouting to whichever provider the router prefers is the bug this closes,
/// because choosing between two seats for one model name is the picker's whole
/// job.
pub fn replModelPick(ctx_ptr: ?*anyopaque, gpa: Allocator, provider_id: []const u8, name: []const u8) ?Picked {
    const c: *ReplCtx = @ptrCast(@alignCast(ctx_ptr orelse return null));
    if (provider_id.len > 0 and provider_mod.specFor(provider_id) != null) {
        // Off-catalog names (a live LM Studio id) have no table slice to
        // borrow, so those — and only those — are copied.
        const owned = catalogName(provider_id, name) == null;
        const model = if (owned) (gpa.dupe(u8, name) catch return null) else catalogName(provider_id, name).?;
        c.provider = c.keys.providerById(provider_id, model) catch {
            if (owned) gpa.free(model);
            return null;
        };
    } else {
        // `resolveModelName` answers with the catalog's own slice, never with
        // a piece of the query, so there is nothing to copy here either.
        const resolved = pricing.resolveModelName(c.keys, name) orelse return null;
        c.provider = c.keys.providerFor(resolved) catch return null;
    }
    c.fallback_active = false;
    c.fallback_blocked = false;
    serde.saveModel(c.io, c.home, c.provider.id, c.provider.model);
    return .{ .model = gpa.dupe(u8, c.provider.model) catch return null, .provider = c.provider.id };
}

/// repl.CancelFn adapter — force-interrupt the running repl turn. Sets the
/// Agent-wide esc_cancel flag the streaming loops + watchdog poll, so the
/// in-flight runTurn unwinds (error.Interrupted) and the repl drains its steer
/// queue. Cross-thread safe (atomic) — the same signal the TTY esc-watch uses.
pub fn replCancelCb(ctx_ptr: ?*anyopaque) void {
    _ = ctx_ptr;
    Agent.esc_cancel.store(true, .release);
}

pub const SteerEntry = struct { text: []const u8, force: bool };

/// Spin-lock guarding g_steer_buf/g_steer_queue mutations. The concurrent steer
/// drainers (the main reader + pool esc-watch/watchdog arms, #129) hold it only
/// for the tiny queue/buffer critical sections — never across a stdin read/poll
/// — so it stays uncontended and needs no Io handle (unlike the Io.Mutex used
/// elsewhere, which the io-less escPressed cannot reach).
pub fn steerLock() void {
    while (main_mod.g_steer_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}
pub fn steerUnlock() void {
    main_mod.g_steer_lock.store(false, .release);
}

/// #129: a completed steer line should be DROPPED (not queued) when it is empty
/// (another drainer emptied the buffer first) or byte-identical to the entry
/// already at the tail of the queue — exactly the shape a racing double-flush or
/// a paste burst produces, which is what enqueued one submit as N re-steered
/// copies. Pure so it can be unit-tested away from the io-bound escPressed.
pub fn steerFlushRedundant(queue: []const SteerEntry, text: []const u8) bool {
    return text.len == 0 or (queue.len > 0 and std.mem.eql(u8, queue[queue.len - 1].text, text));
}

test "steerFlushRedundant drops empty + consecutive-identical flushes (#129)" {
    const E = SteerEntry;
    const none: []const E = &.{};
    try std.testing.expect(steerFlushRedundant(none, "")); // empty flush
    try std.testing.expect(!steerFlushRedundant(none, "hello")); // first real line queues
    const one = [_]E{.{ .text = "hello", .force = false }};
    try std.testing.expect(steerFlushRedundant(&one, "hello")); // identical to tail -> drop
    try std.testing.expect(!steerFlushRedundant(&one, "hello world")); // different -> queue
    const two = [_]E{ .{ .text = "a", .force = false }, .{ .text = "b", .force = false } };
    try std.testing.expect(steerFlushRedundant(&two, "b")); // identical to TAIL -> drop
    try std.testing.expect(!steerFlushRedundant(&two, "a")); // matches head not tail -> queue
}

/// Pops the next queued steering prompt (FIFO), or null if none.
pub fn popSteer() ?SteerEntry {
    steerLock();
    defer steerUnlock();
    if (main_mod.g_steer_queue.items.len == 0) return null;
    return main_mod.g_steer_queue.orderedRemove(0);
}

/// Drops any half-typed steering line (no Enter yet) — called at the top
/// of each REPL iteration so a partial mid-turn draft never leaks into the
/// next prompt.
pub fn resetSteerPartial() void {
    steerLock();
    defer steerUnlock();
    main_mod.g_steer_buf.clearRetainingCapacity();
    main_mod.g_steer_echoed = false;
    main_mod.g_steer_visible.store(false, .release);
}

/// Writes steering echo to the stdout writer (the same buffered writer the
/// streaming text uses, already flushed before escPressed runs, so ordering
/// stays correct) and flushes so the user sees queued keystrokes live.
pub fn steerEcho(bytes: []const u8) void {
    if (main_mod.g_out) |w| {
        w.writeAll(bytes) catch {};
        w.flush() catch {};
    }
}

/// Persist the thinking controls (/effort, /fast) to .harness/settings.json,
/// preserving every other key. Default values (medium effort, fast off) are
/// removed rather than written so the file stays clean. Best-effort.
pub fn saveThinkingSettings(io: Io, gpa: Allocator, effort: ReasoningEffort, fast: bool, ultracode: bool, show_thinking: bool, ai_title: bool) bool {
    Io.Dir.cwd().createDir(io, Approvals.settings_dir, .default_dir) catch {}; // already-exists is fine
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var root_obj: std.json.ObjectMap = .empty;
    if (Io.Dir.cwd().readFileAlloc(io, Approvals.settings_path, a, .limited(1 << 20))) |data| {
        if (std.json.parseFromSliceLeaky(Value, a, data, .{ .allocate = .alloc_always })) |v| {
            if (v == .object) root_obj = v.object;
        } else |_| {}
    } else |_| {}
    if (effort == .medium) {
        _ = root_obj.orderedRemove("effort");
    } else {
        root_obj.put(a, "effort", .{ .string = @tagName(effort) }) catch return false;
    }
    if (!fast) {
        _ = root_obj.orderedRemove("fast");
    } else {
        root_obj.put(a, "fast", .{ .bool = true }) catch return false;
    }
    if (!ultracode) {
        _ = root_obj.orderedRemove("ultracode");
    } else {
        root_obj.put(a, "ultracode", .{ .bool = true }) catch return false;
    }
    if (show_thinking) {
        _ = root_obj.orderedRemove("show_thinking");
    } else {
        root_obj.put(a, "show_thinking", .{ .bool = false }) catch return false;
    }
    if (ai_title) {
        _ = root_obj.orderedRemove("ai_title");
    } else {
        root_obj.put(a, "ai_title", .{ .bool = false }) catch return false;
    }
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    s.write(Value{ .object = root_obj }) catch return false;
    const f = Io.Dir.cwd().createFile(io, Approvals.settings_path, .{}) catch return false;
    defer f.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    fw.interface.writeAll(aw.writer.buffered()) catch return false;
    fw.interface.writeAll("\n") catch return false;
    fw.interface.flush() catch return false;
    return true;
}

/// Load persisted thinking controls into the root agent at startup:
/// {"effort": "low|medium|high|xhigh|max|ultra"} and {"fast": true}. Best-effort — a missing
/// or garbled file just leaves the defaults (medium, off).
pub fn loadThinkingSettings(io: Io, arena: Allocator, root: *Agent) void {
    root.fallback_allow = fallback_config.load(io, arena);
    const data = Io.Dir.cwd().readFileAlloc(io, Approvals.settings_path, arena, .limited(1 << 20)) catch return;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return;
    if (v != .object) return;
    if (v.object.get("effort")) |e| if (e == .string) {
        root.reasoning = std.meta.stringToEnum(ReasoningEffort, e.string) orelse root.reasoning;
    };
    if (v.object.get("fast")) |fv| if (fv == .bool) {
        root.fast = fv.bool;
    };
    if (v.object.get("ultracode")) |uv| if (uv == .bool) {
        root.ultracode_mode = uv.bool;
    };
    if (v.object.get("show_thinking")) |sv| if (sv == .bool) {
        root.show_thinking = sv.bool;
    };
    if (v.object.get("ai_title")) |tv| if (tv == .bool) {
        root.ai_title = tv.bool;
    };
    if (v.object.get("session_recap")) |rv| {
        if (rv == .bool) root.ai_recap = rv.bool;
    }
}

/// REPL slash commands share the leading `/` with absolute POSIX paths. Only
/// treat the line as command syntax when the first token is command-shaped;
/// `/System/Library/... explain this` should be sent to the model as a prompt,
/// not rejected as an unknown slash command.
pub fn isSlashCommandLine(line: []const u8) bool {
    if (line.len == 0 or line[0] != '/') return false;
    if (line.len == 1) return true; // bare `/` opens the command picker

    const token_end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    const token = line[0..token_end];
    // Absolute paths with more than one component are prompts/attachments.
    if (token.len > 1 and std.mem.indexOfScalar(u8, token[1..], '/') != null) return false;

    return true;
}

/// `/goal <objective>` sets the standing goal AND runs it as the first turn, so the caller needs the
/// objective back as a prompt; a bare `/goal` and the lifecycle words stay commands. Extracted from
/// mainloop (600-line cap), and kept beside isSlashCommandLine: both settle "command, or prompt?".
pub fn goalPromptFromLine(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "/goal ")) return null;
    const g = std.mem.trim(u8, line["/goal".len..], " \t");
    if (g.len == 0) return null;
    for ([_][]const u8{ "clear", "off", "pause", "resume", "status" }) |sub|
        if (std.ascii.eqlIgnoreCase(g, sub)) return null;
    return g;
}
