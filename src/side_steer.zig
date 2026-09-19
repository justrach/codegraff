//! Side-request steering: a line starting with `&` queued while a turn is
//! live spawns a background subagent instead of running as the next blocking
//! turn. The session stays interactive; when the child settles, its report is
//! injected as a user message at the next turn boundary, so the model sees it
//! alongside whatever the user asks next.
//!
//! Hooked at the one turn-append chokepoint both hosts share: the REPL/mainloop
//! drain (turn_dedup.enqueueOrSkip) and the ACP live turn (acp_live_turn.run),
//! so REPL, TUI and GUI behave identically. Reports are drained from the
//! g_agent_jobs registry by id — no worker-thread hooks, one consumer.
//!
//! `&` with nothing after it is not a side request (an empty ask yields
//! nothing); any other line is untouched steering.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const messages = @import("messages.zig");
const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;
const subagent = @import("subagent.zig");
const vision_ask = @import("vision_ask.zig");
const ansi = @import("ansi.zig");
const style = &ansi.style;

/// One spawned side request we still owe a report for. Job ids come from
/// subagent.g_agent_jobs (stable incrementing ids), so only the id is held.
var pending: std.ArrayList(u32) = .empty;

/// A queued line is a side request when its first non-blank byte is `&` and a
/// non-blank ask follows it. Pure.
pub fn isSideRequest(text: []const u8) bool {
    const t = std.mem.trimStart(u8, text, " \t\r");
    if (t.len < 2 or t[0] != '&') return false;
    return std.mem.trim(u8, t[1..], " \t\r").len > 0;
}

/// The ask without the `&` marker, trimmed.
pub fn stripMarker(text: []const u8) []const u8 {
    const t = std.mem.trimStart(u8, text, " \t\r");
    return std.mem.trim(u8, t[1..], " \t\r");
}

/// Test hook: drop every pending report (g_agent_jobs itself is managed by
/// each test that touches it).
pub fn resetForTest() void {
    pending.clearRetainingCapacity();
}

/// First line of the ask, cut on a UTF-8 boundary at 40 bytes, as the job
/// label shown in transcripts and the agents panel.
fn labelFor(arena: Allocator, ask: []const u8) ![]const u8 {
    var line = ask;
    if (std.mem.indexOfScalar(u8, ask, '\n')) |nl| line = ask[0..nl];
    line = std.mem.trim(u8, line, " \t");
    var len = @min(line.len, 40);
    while (len > 0 and (line[len - 1] & 0xC0) == 0x80) len -= 1;
    const cut: []const u8 = if (len < line.len and len > 0) "…" else "";
    return std.fmt.allocPrint(arena, "side: {s}{s}", .{ line[0..len], cut });
}

/// The spawn ToolCtx, mirroring the per-tool-call construction in
/// agent_tools.zig — every field comes from the root Agent, never loop state.
fn ctxFromRoot(root: *Agent) ToolCtx {
    return .{
        .gpa = root.gpa,
        .io = root.io,
        .client = root.client,
        .provider = root.provider,
        .subagent_provider = root.subagent_provider,
        .subagent_cross_provider = root.subagent_cross_provider,
        .mcp_context = root.mcp_context.value,
        .registry = root.registry,
        .from_sub = root.sub,
        .interactive_children = !root.sub and @import("subagent_interactive.zig").enabled.load(.acquire),
        .session_name = root.session_name,
        .has_eval = root.eval_cmd != null,
        .approvals = root.approvals,
        .tracer = root.tracer,
        .run_budget = root.run_budget,
        .publication_checks = root.publication_checks,
        .depth = root.depth,
        .snapshots = root.snapshots,
        .tools_used = &root.tools_used,
        .loop_deadline_ms = root.loop_deadline_ms,
        .agent_cwd = root.agent_cwd,
    };
}

fn newestJobMatching(io: Io, ask: []const u8) ?u32 {
    const jobs = &subagent.g_agent_jobs;
    jobs.mutex.lockUncancelable(io);
    defer jobs.mutex.unlock(io);
    var found: ?u32 = null;
    for (jobs.list.items) |j| {
        if (std.mem.eql(u8, j.prompt, ask)) found = j.id; // keep the last (newest)
    }
    return found;
}

fn echo(out: ?*Io.Writer, comptime fmt: []const u8, args: anytype) void {
    const w = out orelse return;
    w.print("{s}" ++ fmt ++ "{s}\n", .{style.accent} ++ args ++ .{style.reset}) catch {};
    w.flush() catch {};
}

/// Spawn the side request as a background subagent and remember its job id for
/// the report drain. Returns the one-line note a host may show as the turn's
/// reply (the ACP live turn returns it; the REPL/TUI drain echoes it here).
pub fn spawnSide(root: *Agent, arena: Allocator, out: ?*Io.Writer, text: []const u8) ![]const u8 {
    const ask = stripMarker(text);
    if (ask.len == 0) return "[side request: '&' with no question — nothing spawned]";
    const label = try labelFor(arena, ask);
    _ = try subagent.spawnSubBackground(ctxFromRoot(root), label, ask, null, "", .shared_cwd, false, null, null, vision_ask.forPrompt(ask));
    const id = newestJobMatching(root.io, ask) orelse 0;
    pending.append(std.heap.page_allocator, id) catch {};
    echo(out, "↳ side agent #{d} spawned ({s}) · report lands at the next turn boundary", .{ id, label });
    return std.fmt.allocPrint(arena, "Spawned side agent #{d} ({s}) in the background. Its report will arrive with a later turn; keep working.", .{ id, label });
}

const Settled = struct { id: u32, label: []const u8, text: []const u8, is_error: bool };

/// Snapshot every pending job that has finished, copying its report text under
/// the registry lock, then mark those ids delivered. Jobs still running stay
/// pending for a later boundary.
fn collectSettled(jobs: *subagent.AgentJobs, io: Io, arena: Allocator) []Settled {
    var settled: std.ArrayList(Settled) = .empty;
    var keep: std.ArrayList(u32) = .empty;
    {
        jobs.mutex.lockUncancelable(io);
        defer jobs.mutex.unlock(io);
        for (pending.items) |id| {
            const job = jobs.find(id) orelse continue; // reaped: drop silently
            if (!job.done) {
                keep.append(std.heap.page_allocator, id) catch {};
                continue;
            }
            const text = arena.dupe(u8, if (job.result.len > 0) job.result else "subagent finished without a report") catch continue;
            const label = arena.dupe(u8, job.label) catch continue;
            settled.append(arena, .{ .id = id, .label = label, .text = text, .is_error = job.is_error }) catch {};
        }
    }
    pending.clearRetainingCapacity();
    for (keep.items) |id| pending.append(std.heap.page_allocator, id) catch {};
    return settled.items;
}

/// Inject completed side-agent reports into the root's history as user
/// messages, mirroring the child-side feedback delivery shape. Called at the
/// top of every turn append, before the new user text is staged.
pub fn deliverReports(root: *Agent, arena: Allocator, out: ?*Io.Writer) !void {
    return deliverReportsFrom(&subagent.g_agent_jobs, root, arena, out);
}

/// Same drain against an explicit registry — the seam tests use so the
/// session-global g_agent_jobs stays untouched by the test allocator.
pub fn deliverReportsFrom(jobs: *subagent.AgentJobs, root: *Agent, arena: Allocator, out: ?*Io.Writer) !void {
    if (pending.items.len == 0) return;
    for (collectSettled(jobs, root.io, arena)) |r| {
        const body = if (r.is_error)
            try std.fmt.allocPrint(arena, "[Side agent #{d} {s} failed]\n{s}", .{ r.id, r.label, r.text })
        else
            try std.fmt.allocPrint(arena, "[Side agent #{d} {s} report]\n{s}", .{ r.id, r.label, r.text });
        try root.messages.append(try messages.textMessage(arena, "user", body));
        echo(out, "↳ side agent #{d} report delivered", .{r.id});
    }
}

test "isSideRequest: marker needs a non-blank ask" {
    try std.testing.expect(isSideRequest("& what causes flaky PTY probes?"));
    try std.testing.expect(isSideRequest("&what causes flaky PTY probes?"));
    try std.testing.expect(isSideRequest("  &\tsummarize docs.typesafe.ai\n"));
    try std.testing.expect(!isSideRequest("&")); // marker alone yields nothing
    try std.testing.expect(!isSideRequest("&   ")); // whitespace-only ask
    try std.testing.expect(!isSideRequest("plain steering line"));
    try std.testing.expect(!isSideRequest(""));
    try std.testing.expectEqualStrings("what causes flaky PTY probes?", stripMarker("  &  what causes flaky PTY probes? "));
}

test "labelFor: first line, UTF-8 boundary, ellipsis on cut" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("side: short ask", try labelFor(a, "short ask\nsecond line ignored"));
    const long = try labelFor(a, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx");
    try std.testing.expect(std.mem.startsWith(u8, long, "side: "));
    try std.testing.expect(std.mem.endsWith(u8, long, "…"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(long));
}

test "deliverReports: settled jobs land as user messages once, running ones wait" {
    resetForTest();
    defer resetForTest();
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var agent: Agent = .{
        .gpa = gpa,
        .arena = a,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "xai", .kind = .openai, .auth = .bearer, .url = "", .api_key = "k", .model = "grok-4.6", .context = 100_000 },
        .messages = .init(a),
        .sub = false,
        .label = "test",
        .out = null,
    };

    var jobs: subagent.AgentJobs = .{};
    defer jobs.list.deinit(gpa);
    const job = try gpa.create(subagent.AgentJob);
    job.* = .{
        .id = 4242,
        .label = try gpa.dupe(u8, "side: docs"),
        .prompt = try gpa.dupe(u8, "ask"),
        .niche = @constCast(&[_]u8{}),
        .isolation = .shared_cwd,
        .isolation_fallback = false,
        .ctx = .{ .gpa = gpa, .io = std.testing.io, .client = undefined, .provider = agent.provider, .registry = null, .from_sub = false, .approvals = null, .tracer = null },
    };
    job.done = true;
    job.result = try gpa.dupe(u8, "TypeSafe is a structured-decision API.");
    try jobs.list.append(gpa, job);
    try pending.append(std.heap.page_allocator, 4242);
    try pending.append(std.heap.page_allocator, 9999); // unknown id: dropped silently

    try deliverReportsFrom(&jobs, &agent, a, null);
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);

    // Nothing left pending: a second drain is a no-op.
    try deliverReportsFrom(&jobs, &agent, a, null);
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);

    gpa.free(job.label);
    gpa.free(job.prompt);
    gpa.free(job.result);
    gpa.destroy(job);
}
