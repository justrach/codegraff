//! Tests split out of subagent.zig, which sits at the 600-line cap (the
//! `<mod>_tests.zig` pattern, wired into the test root by test_hooks.zig).

const std = @import("std");

const util = @import("util.zig");
const repl_glue = @import("repl_glue.zig");
const subagent = @import("subagent.zig");
const subagent_ledger = @import("subagent_ledger.zig");
const subagent_run = @import("subagent_run.zig");

const FailKind = subagent_run.FailKind;
const classifyFailure = subagent_run.classifyFailure;
const feedback = @import("subagent_feedback.zig");

test "background feedback owns ordered messages and delivers once" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var inbox: feedback.Inbox = .{};
    defer inbox.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var history: std.json.Array = .init(arena.allocator());
    var first = [_]u8{ 'o', 'n', 'e' };
    try inbox.enqueue(gpa, io, &first);
    first[0] = 'X';
    try inbox.enqueue(gpa, io, "two\nkeep this line");
    try std.testing.expectEqual(@as(usize, 0), history.items.len);
    try std.testing.expect(!inbox.tryFinish(io));
    try std.testing.expect(try inbox.deliver(gpa, io, arena.allocator(), &history));
    try std.testing.expectEqual(@as(usize, 2), history.items.len);
    try std.testing.expectEqualStrings("user", history.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("[Parent task feedback]\none", history.items[0].object.get("content").?.string);
    try std.testing.expectEqualStrings("[Parent task feedback]\ntwo\nkeep this line", history.items[1].object.get("content").?.string);
    try std.testing.expect(!try inbox.deliver(gpa, io, arena.allocator(), &history));
    try std.testing.expectEqual(@as(usize, 2), inbox.delivered);
    try std.testing.expect(inbox.tryFinish(io));
    try std.testing.expectError(error.AgentFinished, inbox.enqueue(gpa, io, "too late"));
}

test "background feedback is bounded and rejects empty invalid or oversized input" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var inbox: feedback.Inbox = .{};
    defer inbox.deinit(gpa);
    try std.testing.expectError(error.EmptyMessage, inbox.enqueue(gpa, io, " \n\t"));
    try std.testing.expectError(error.InvalidUtf8, inbox.enqueue(gpa, io, "\xff"));
    const large = try gpa.alloc(u8, feedback.max_message_bytes + 1);
    defer gpa.free(large);
    @memset(large, 'a');
    try std.testing.expectError(error.MessageTooLarge, inbox.enqueue(gpa, io, large));
    for (0..4) |_| try inbox.enqueue(gpa, io, large[0..feedback.max_message_bytes]);
    try std.testing.expectError(error.InboxFull, inbox.enqueue(gpa, io, "x"));
    try std.testing.expectEqual(@as(usize, 4), inbox.close(io));
    try std.testing.expectError(error.AgentFinished, inbox.enqueue(gpa, io, "closed"));
}

test "background feedback message-count cap applies independently of byte cap" {
    var inbox: feedback.Inbox = .{};
    defer inbox.deinit(std.testing.allocator);
    for (0..feedback.max_pending_messages) |_| try inbox.enqueue(std.testing.allocator, std.testing.io, "a");
    try std.testing.expectError(error.InboxFull, inbox.enqueue(std.testing.allocator, std.testing.io, "b"));
}

test "background feedback allocation failure leaves the inbox deliverable" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var inbox: feedback.Inbox = .{};
    defer inbox.deinit(gpa);
    try inbox.enqueue(gpa, io, "preserve me");
    var failed = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var history: std.json.Array = .init(failed.allocator());
    defer history.deinit();
    try std.testing.expectError(error.OutOfMemory, inbox.deliver(gpa, io, failed.allocator(), &history));
    try std.testing.expectEqual(@as(usize, 1), inbox.pending.items.len);
    try std.testing.expectEqual(@as(usize, 0), history.items.len);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var recovered: std.json.Array = .init(arena.allocator());
    try std.testing.expect(try inbox.deliver(gpa, io, arena.allocator(), &recovered));
    try std.testing.expect(inbox.tryFinish(io));
}

test "background feedback finishing before enqueue rejects rather than strands a message" {
    var inbox: feedback.Inbox = .{};
    defer inbox.deinit(std.testing.allocator);
    try std.testing.expect(inbox.tryFinish(std.testing.io));
    try std.testing.expectError(error.AgentFinished, inbox.enqueue(std.testing.allocator, std.testing.io, "late final feedback"));
    try std.testing.expectEqual(@as(usize, 0), inbox.pending.items.len);
}

test "background feedback late allocation failures never partly consume a batch" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const large = try gpa.alloc(u8, feedback.max_message_bytes);
    defer gpa.free(large);
    @memset(large, 'a');
    var observed_failure = false;
    var observed_success = false;
    for (0..12) |fail_index| {
        var inbox: feedback.Inbox = .{};
        defer inbox.deinit(gpa);
        try inbox.enqueue(gpa, io, large);
        try inbox.enqueue(gpa, io, large);
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        var arena = std.heap.ArenaAllocator.init(failing.allocator());
        defer arena.deinit();
        var history: std.json.Array = .init(arena.allocator());
        if (inbox.deliver(gpa, io, arena.allocator(), &history)) |delivered| {
            observed_success = true;
            try std.testing.expect(delivered);
            try std.testing.expectEqual(@as(usize, 2), history.items.len);
            try std.testing.expectEqual(@as(usize, 0), inbox.pending.items.len);
        } else |err| {
            observed_failure = true;
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), history.items.len);
            try std.testing.expectEqual(@as(usize, 2), inbox.pending.items.len);
        }
    }
    try std.testing.expect(observed_failure and observed_success);
}

test "agent_message accepts queued children and refuses completed unknown or child callers" {
    const tools = @import("tools.zig");
    const messaging = @import("subagent_messaging.zig");
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var ctx: tools.ToolCtx = .{ .gpa = gpa, .io = io, .client = undefined, .provider = undefined, .registry = null, .from_sub = false, .approvals = null, .tracer = null };
    const saved = subagent.g_agent_jobs;
    subagent.g_agent_jobs = .{};
    defer {
        subagent.g_agent_jobs.list.deinit(gpa);
        subagent.g_agent_jobs = saved;
    }
    var label = [_]u8{'x'};
    var job: subagent.AgentJob = .{ .id = 42, .label = &label, .prompt = &label, .niche = &label, .isolation = .shared_cwd, .isolation_fallback = false, .ctx = ctx };
    defer job.feedback.deinit(gpa);
    try subagent.g_agent_jobs.list.append(gpa, &job);
    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"id\":42,\"message\":\"new scope\"}", .{});
    const queued = try messaging.send(ctx, input);
    defer gpa.free(queued.text);
    try std.testing.expect(!queued.is_error);
    try std.testing.expectEqual(@as(usize, 1), job.feedback.pending.items.len);
    job.done = true;
    const finished = try messaging.send(ctx, input);
    defer gpa.free(finished.text);
    try std.testing.expect(finished.is_error);
    const missing_input = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"id\":999,\"message\":\"new scope\"}", .{});
    const missing = try messaging.send(ctx, missing_input);
    defer gpa.free(missing.text);
    try std.testing.expect(missing.is_error);
    ctx.from_sub = true;
    job.done = false;
    const child = try messaging.send(ctx, input);
    defer gpa.free(child.text);
    try std.testing.expect(child.is_error);
    try std.testing.expectEqual(@as(usize, 1), job.feedback.pending.items.len);
}

test "variantJudgePrompt: bounded, names the phase, keeps the score contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const big_task = util.repeatBytes("T", 4000);
    const big_out = util.repeatBytes("O", 5000);
    const p = try subagent.variantJudgePrompt(a, "code-review", &big_task, &big_out);

    // Names the shared phase so the judge has the tournament context.
    try std.testing.expect(std.mem.indexOf(u8, p, "\"code-review\" phase") != null);
    // Task is prefix-capped and output tail-capped — neither lands verbatim.
    try std.testing.expect(std.mem.indexOf(u8, p, &big_task) == null);
    try std.testing.expect(std.mem.indexOf(u8, p, &big_out) == null);
    // The `score:` contract parseEvalScore depends on is spelled out…
    try std.testing.expect(std.mem.indexOf(u8, p, "score: <N>") != null);
    // …and it round-trips: a judge tail like this parses back to the score.
    try std.testing.expectEqual(@as(?f64, 87), repl_glue.parseEvalScore("ok\nscore: 87"));
    // #367: a prose line is not a score. pytest's summary used to parse as a
    // leading number — 4/100 for a green suite, and "1 failed" → 1 → the
    // [0,1] fraction rule → 100/100 on a FAILING suite.
    try std.testing.expectEqual(@as(?f64, null), repl_glue.parseEvalScore("4 passed in 0.01s"));
    try std.testing.expectEqual(@as(?f64, null), repl_glue.parseEvalScore("2 failed, 2 passed in 0.02s"));
    try std.testing.expectEqual(@as(?f64, null), repl_glue.parseEvalScore("1 failed in 0.01s"));
    // A last line that IS a number still works, as does an explicit fraction.
    try std.testing.expectEqual(@as(?f64, 85), repl_glue.parseEvalScore("all checks done\n85"));
    try std.testing.expectEqual(@as(?f64, 90), repl_glue.parseEvalScore("{\"score\": 0.9}"));
}

test "classifyFailure: maps the child's api-error detail to a category + retry-safety" {
    // A stream stall/drop names itself via the error kind — its stale envelope
    // (if any) must not override the transport verdict.
    try std.testing.expectEqual(FailKind.transport, classifyFailure(error.StreamStalled, null));
    try std.testing.expectEqual(FailKind.transport, classifyFailure(error.StreamDropped, "api error (some_error): stale"));
    // No detail to go on → unknown (and a retry is still allowed to be tried).
    try std.testing.expectEqual(FailKind.unknown, classifyFailure(error.ApiError, null));
    // Real provider envelopes (the shapes sayApiError formats into last_api_error).
    try std.testing.expectEqual(FailKind.quota, classifyFailure(error.ApiError, "api error (rate_limit_error): Number of requests exceeded"));
    try std.testing.expectEqual(FailKind.quota, classifyFailure(error.ApiError, "api error: You have run out of credits or need a Grok subscription."));
    try std.testing.expectEqual(FailKind.auth, classifyFailure(error.ApiError, "api error: The API Key appears to be invalid or may have expired."));
    // invalid_request_error carries "invalid", but a missing-model message is
    // classified as model-availability because that phrase is checked first.
    try std.testing.expectEqual(FailKind.model, classifyFailure(error.ApiError, "api error (invalid_request_error): The model `gpt-foo` does not exist or you do not have access to it."));
    try std.testing.expectEqual(FailKind.invalid, classifyFailure(error.ApiError, "api error (invalid_request_error): This model's maximum context length is 8192 tokens."));
    try std.testing.expectEqual(FailKind.transport, classifyFailure(error.ApiError, "network error: HttpConnectionClosing (gave up after 6 attempts)"));

    // Retry-safety contract: transient failures may retry, structural ones must not.
    try std.testing.expect(FailKind.quota.retrySafe());
    try std.testing.expect(FailKind.transport.retrySafe());
    try std.testing.expect(!FailKind.model.retrySafe());
    try std.testing.expect(!FailKind.invalid.retrySafe());
    try std.testing.expect(!FailKind.auth.retrySafe());
}

// Moved off subagent.zig when the §2c tournament gate needed room there — the
// tests are unchanged, and this is the file that exists for exactly that.

test "agentStatusText: running/completed/failed shapes carry the usage summary, and a failure is never silent (#276 P0-3)" {
    const gpa = std.testing.allocator;

    const running = try subagent.agentStatusText(gpa, 7, false, false, .{}, "");
    defer gpa.free(running);
    try std.testing.expectEqualStrings("[agent 7: running]", running);

    const ok = try subagent.agentStatusText(gpa, 7, true, false, .{ .duration_ms = 1200, .tool_calls = 3, .context_tokens = 4500, .cache_read_tokens = 100 }, "final report");
    defer gpa.free(ok);
    try std.testing.expect(std.mem.indexOf(u8, ok, "completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, ok, "1200ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, ok, "3 tool call") != null);
    try std.testing.expect(std.mem.indexOf(u8, ok, "final report") != null);

    const failed_text = "subagent sa-014-abcd failed before producing a report: connection reset [transport failure, 3 attempts]. retry is likely safe";
    const failed = try subagent.agentStatusText(gpa, 9, true, true, .{ .duration_ms = 300 }, failed_text);
    defer gpa.free(failed);
    try std.testing.expect(std.mem.indexOf(u8, failed, "failed") != null); // status names the failure — never silent
    try std.testing.expect(std.mem.indexOf(u8, failed, failed_text) != null); // the child's own diagnostic rides along verbatim
}

test "agentStatusText: composes with isolation:\"worktree\" — a kept-worktree note in the result survives verbatim (#276 P0-3 design point 5)" {
    const gpa = std.testing.allocator;
    const result_with_worktree = "final report text\n\n[worktree kept (has changes) — path: .graff/worktrees/agent-sa-001-aa11, branch: graff/agents/sa-001-aa11]";
    const out = try subagent.agentStatusText(gpa, 3, true, false, .{ .duration_ms = 500 }, result_with_worktree);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "[worktree kept (has changes) — path:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "branch: graff/agents/sa-001-aa11") != null);
}

test "admitOneLocked: admits up to the cap, queues the rest, FIFO order (#276 P0-3 design point 6)" {
    const gpa = std.testing.allocator;
    var registry: subagent.AgentJobs = .{};
    defer registry.list.deinit(gpa);

    var stub_jobs: [subagent.max_concurrent_background_agents + 3]subagent.AgentJob = undefined;
    for (&stub_jobs, 0..) |*j, i| j.* = .{
        .id = @intCast(i + 1),
        .label = @constCast(""),
        .prompt = @constCast(""),
        .niche = @constCast(""),
        .isolation = .shared_cwd,
        .isolation_fallback = false,
        .ctx = undefined,
    };
    for (&stub_jobs) |*j| try registry.list.append(gpa, j);

    var admitted_order: [stub_jobs.len]u32 = undefined;
    var n: usize = 0;
    while (subagent.admitOneLocked(&registry)) |j| : (n += 1) admitted_order[n] = j.id;

    try std.testing.expectEqual(@as(usize, subagent.max_concurrent_background_agents), n);
    try std.testing.expectEqual(subagent.max_concurrent_background_agents, registry.active);
    for (admitted_order[0..n], 1..) |id, expect| try std.testing.expectEqual(@as(u32, @intCast(expect)), id);

    var still_queued: usize = 0;
    for (stub_jobs) |j| if (!j.admitted) {
        still_queued += 1;
    };
    try std.testing.expectEqual(stub_jobs.len - n, still_queued);

    registry.active -= 1;
    const next = subagent.admitOneLocked(&registry).?;
    try std.testing.expectEqual(@as(u32, subagent.max_concurrent_background_agents + 1), next.id);
}

// The issue report: three run_in_background:true launches returned numeric
// ids; after an API interrupt and a continuation, agent_output said each
// "may never have started". This is that sequence through the model-facing
// tool: persist (ACP save on ApiError), new process (empty ledger + empty
// live table), then agent_output on all three.
test "#753 backtest: three issued handles survive process death through agent_output" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    subagent_ledger.reset(gpa);
    defer subagent_ledger.reset(gpa);

    subagent_ledger.remember(gpa, io, 7531, "scan auth");
    subagent_ledger.remember(gpa, io, 7532, "scan payments");
    subagent_ledger.remember(gpa, io, 7533, "scan sessions");
    // One finished before the interrupt; the other two were still running.
    subagent_ledger.finish(gpa, io, 7531, false, "auth looks fine", .{ .duration_ms = 80, .tool_calls = 1 });

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try subagent_ledger.writeFields(&s, io);
    try s.endObject();

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, aw.writer.buffered(), .{});
    defer parsed.deinit();
    subagent_ledger.reset(gpa);
    const saved = if (parsed.value == .object) parsed.value.object.get("background_agents") else null;
    subagent_ledger.restore(gpa, io, saved);

    const done = try subagent.agentOutput(gpa, io, 7531, 0);
    defer gpa.free(done.text);
    try std.testing.expect(!done.is_error);
    try std.testing.expect(std.mem.indexOf(u8, done.text, "auth looks fine") != null);
    try std.testing.expect(std.mem.indexOf(u8, done.text, "may never have started") == null);

    const pay = try subagent.agentOutput(gpa, io, 7532, 0);
    defer gpa.free(pay.text);
    try std.testing.expect(pay.is_error);
    try std.testing.expect(std.mem.indexOf(u8, pay.text, "interrupted") != null);
    try std.testing.expect(std.mem.indexOf(u8, pay.text, "scan payments") != null);
    try std.testing.expect(std.mem.indexOf(u8, pay.text, "may never have started") == null);

    const ses = try subagent.agentOutput(gpa, io, 7533, 0);
    defer gpa.free(ses.text);
    try std.testing.expect(ses.is_error);
    try std.testing.expect(std.mem.indexOf(u8, ses.text, "interrupted") != null);
    try std.testing.expect(std.mem.indexOf(u8, ses.text, "may never have started") == null);

    const unknown = try subagent.agentOutput(gpa, io, 99, 0);
    defer gpa.free(unknown.text);
    try std.testing.expect(std.mem.indexOf(u8, unknown.text, "may never have started") != null);
}

test "interactive children yield once without cancellation or a model request" {
    const interactive = @import("subagent_interactive.zig");
    interactive.configure(true);
    defer interactive.configure(false);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var root = .{ .sub = false, .arena = arena.allocator() };
    var ctx: @import("tools.zig").ToolCtx = .{ .gpa = std.testing.allocator, .io = std.testing.io, .client = undefined, .provider = undefined, .registry = null, .from_sub = false, .approvals = null, .tracer = null };
    interactive.request(ctx); // headless callers retain wait-until-exit behavior
    try std.testing.expect((try interactive.beforeRequest(&root)) == null);
    ctx.interactive_children = true;
    interactive.request(ctx);
    const text = (try interactive.beforeRequest(&root)).?;
    try std.testing.expect(std.mem.indexOf(u8, text, "keep using the prompt") != null);
    try std.testing.expect(interactive.yielded);
    try std.testing.expect(!@import("agent.zig").Agent.esc_cancel.load(.acquire));
    try std.testing.expect((try interactive.beforeRequest(&root)) == null);
    try std.testing.expect(!interactive.yielded);
}

test "interactive child output never waits and completion wakes only its owner once" {
    const interactive = @import("subagent_interactive.zig");
    interactive.configure(true);
    defer interactive.configure(false);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const ctx: @import("tools.zig").ToolCtx = .{ .gpa = gpa, .io = io, .client = undefined, .provider = undefined, .registry = null, .from_sub = false, .approvals = null, .tracer = null, .interactive_children = true, .session_name = "owner" };
    const saved = subagent.g_agent_jobs;
    subagent.g_agent_jobs = .{};
    defer {
        subagent.g_agent_jobs.list.deinit(gpa);
        subagent.g_agent_jobs = saved;
    }
    var label = [_]u8{'x'};
    var job: subagent.AgentJob = .{ .id = 42, .label = &label, .prompt = &label, .niche = &label, .isolation = .shared_cwd, .isolation_fallback = false, .ctx = ctx, .owner = "owner" };
    try subagent.g_agent_jobs.list.append(gpa, &job);
    const running = try interactive.output(ctx, 42, 1); // used to wait up to 10h
    defer gpa.free(running.text);
    try std.testing.expect(!running.is_error);
    try std.testing.expect(!job.done);
    var buf: [512]u8 = undefined;
    try std.testing.expect(interactive.takeWake(io, "owner", &buf) == null);
    job.done = true;
    job.is_error = true;
    try std.testing.expect(interactive.takeWake(io, "other-session", &buf) == null);
    try std.testing.expect(interactive.takeWake(io, "owner", buf[0..1]) == null);
    try std.testing.expect(!job.notified);
    var owner_storage = @import("subagent_owned.zig").Owned.init(gpa);
    defer owner_storage.arena.deinit();
    job.owned = &owner_storage;
    interactive.rename(io, "owner", "renamed-session");
    try std.testing.expect(interactive.takeWake(io, "owner", &buf) == null);
    try std.testing.expectEqualStrings("renamed-session", job.owner.?);
    const notice = interactive.takeWake(io, "renamed-session", &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, notice, "agent 42 failed") != null);
    try std.testing.expect(interactive.takeWake(io, "renamed-session", &buf) == null);
    job.notified = false;
    const read = try interactive.output(ctx, 42, 1);
    defer gpa.free(read.text);
    try std.testing.expect(read.is_error);
    try std.testing.expect(interactive.takeWake(io, "owner", &buf) == null);
}

test "background children own approvals and provider strings after parent turn ends" {
    const gpa = std.testing.allocator;
    var owner = @import("subagent_owned.zig").Owned.init(gpa);
    defer owner.arena.deinit();
    var source = std.heap.ArenaAllocator.init(gpa);
    const a = source.allocator();
    var approvals: @import("approvals.zig").Approvals = .{ .yolo = true };
    try approvals.prefixes.append(a, try a.dupe(u8, "git"));
    const ctx: @import("tools.zig").ToolCtx = .{ .gpa = gpa, .io = std.testing.io, .client = undefined, .provider = .{ .id = try a.dupe(u8, "local"), .kind = .openai, .auth = .bearer, .url = try a.dupe(u8, "http://localhost"), .api_key = "", .model = try a.dupe(u8, "fixture"), .context = 1000 }, .registry = null, .from_sub = false, .approvals = &approvals, .tracer = null };
    const copy = try owner.context(ctx);
    approvals.yolo = false;
    source.deinit();
    try std.testing.expect(copy.approvals.? != &approvals);
    try std.testing.expect(copy.approvals.?.yolo);
    try std.testing.expectEqualStrings("git", copy.approvals.?.prefixes.items[0]);
    try std.testing.expectEqualStrings("fixture", copy.provider.model);
    try std.testing.expectEqualStrings("http://localhost", copy.provider.url);
    try std.testing.expect(copy.tools_used == null);
}
