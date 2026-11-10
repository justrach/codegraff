//! ADR 0246: Jev in the flow (opt-in via GRAFF_JEV_AUTO=1). When a root turn
//! starts on an eligible model with a cold cache, graff asks Jev for the turn's
//! reasoning effort itself; the model was offered the jev_effort tool and never
//! called it. The request runs alongside the turn's first model call, so it adds
//! no wait: its pick applies from the turn's next request (agent_request.zig
//! applies pending picks there). Jev sees a summary built here: the request's
//! words with code, paths, file names, URLs, emails, identifiers and
//! number-heavy or long tokens dropped. The pick holds for that turn only and is
//! never saved, an effort the user chose (including an explicit medium) or a
//! warm prompt cache (#1320) is never overridden, and a pick still in flight
//! when the turn ends is canceled and dropped.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ReasoningEffort = @import("main.zig").ReasoningEffort;
const jev_tool = @import("jev_tool.zig");

/// GRAFF_JEV_AUTO=1 (or on/true/yes) turns the per-turn selection on. Default
/// is off (#1320): flipping reasoning.effort between request 1 and request 2 on
/// Responses rewrites token 0 of the Harmony system message and invalidates the
/// prompt cache mid-turn.
pub var enabled: bool = false;
/// How long a turn waits for Jev before it goes ahead at the default effort.
pub const timeout_ms: u32 = 4_000;
pub const max_summary = 280;

/// jev_tool.configure passes GRAFF_JEV_AUTO's value.
pub fn setEnabled(value: ?[]const u8) void {
    const v = value orelse "";
    enabled = std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "on") or
        std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "yes");
}

/// The words Jev may see: no code, paths, file names, URLs, emails,
/// identifiers, ids or long tokens. Empty when nothing safe is left.
pub fn summary(arena: Allocator, prompt: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_fence = false;
    var lines = std.mem.splitScalar(u8, prompt, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "```")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;
        var words = std.mem.tokenizeAny(u8, t, " \t");
        while (words.next()) |w| {
            if (!keep(w)) continue;
            if (out.items.len + w.len + 1 > max_summary) return out.items;
            if (out.items.len != 0) try out.append(arena, ' ');
            try out.appendSlice(arena, w);
        }
    }
    return out.items;
}

fn keep(w: []const u8) bool {
    if (w.len > 24) return false; // keys, hashes, long identifiers
    if (std.mem.indexOfAny(u8, w, "/\\`@<>{}[]=$|_#~") != null) return false; // paths, code, emails, markup, identifiers
    var digits: usize = 0;
    for (w) |c| digits += @intFromBool(std.ascii.isDigit(c));
    if (digits >= 4) return false; // ids and numbers that identify something
    const core = std.mem.trimEnd(u8, w, ".,;:!?)\"'");
    if (std.mem.lastIndexOfScalar(u8, core, '.')) |dot| if (dot > 0 and dot + 1 < core.len) return false; // file.ext, a.b.c
    return true;
}

fn lastUserText(agent: anytype) ?[]const u8 {
    const items = agent.messages.items;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const m = items[i];
        if (m != .object) continue;
        const role = m.object.get("role") orelse continue;
        if (role != .string or !std.mem.eql(u8, role.string, "user")) continue;
        if (m.object.get(@import("session_wake.zig").origin_key) != null) return null; // a harness message, not a request
        const content = m.object.get("content") orelse return null;
        switch (content) {
            .string => |s| return s,
            .array => |parts| for (parts.items) |part| {
                if (part != .object) continue;
                const text = part.object.get("text") orelse continue;
                if (text == .string and text.string.len != 0) return text.string;
            },
            else => {},
        }
        return null;
    }
    return null;
}

/// Start this turn's pick alongside its first request. Root turns at the
/// untouched session default with a cold prompt cache only; never blocks.
pub fn beginTurn(agent: anytype) void {
    const pending = &agent.jev_effort_pending;
    pending.auto = .{};
    if (!enabled or agent.sub or pending.user_pinned or agent.reasoning != .medium) return;
    if (@hasField(@TypeOf(agent.*), "last_cache_read") and agent.last_cache_read > 0) return;
    if (!jev_tool.available(agent.provider)) return;
    const prompt = lastUserText(agent) orelse return;
    var scratch = std.heap.ArenaAllocator.init(agent.gpa);
    defer scratch.deinit();
    const task = summary(scratch.allocator(), prompt) catch return;
    if (task.len == 0) return;
    const owned = agent.gpa.dupe(u8, task) catch return;
    const token = pending.beginTurn(agent.io, agent.provider) orelse {
        agent.gpa.free(owned);
        return;
    };
    pending.auto.task = owned;
    pending.auto.saved = agent.reasoning;
    pending.auto.future = agent.io.concurrent(pickTask, .{ agent.gpa, agent.io, agent.client, agent.provider, owned, pending, token }) catch {
        pending.abort(agent.io, token);
        agent.gpa.free(owned);
        pending.auto = .{};
        return;
    };
}

fn pickTask(gpa: Allocator, io: Io, client: *std.http.Client, provider: @import("provider.zig").Provider, task: []const u8, pending: *@import("jev_effort_state.zig").Pending, token: u64) void {
    const t0 = Io.Timestamp.now(io, .awake).nanoseconds;
    const chosen = jev_tool.chooseForTurn(gpa, io, client, provider, task, timeout_ms);
    const ms = @divTrunc(Io.Timestamp.now(io, .awake).nanoseconds - t0, std.time.ns_per_ms);
    pending.auto.ms.store(@intCast(std.math.clamp(ms, 0, std.math.maxInt(u32))), .release);
    if (chosen) |effort| {
        pending.auto.picked = effort;
        _ = pending.commit(io, token, effort);
        pending.auto.outcome.store(1, .release);
    } else {
        pending.abort(io, token);
        pending.auto.outcome.store(2, .release);
    }
}

/// Cancel a pick still in flight, drop one no request applied, and put the
/// session effort back unless someone changed it during the turn.
pub fn endTurn(agent: anytype) void {
    const pending = &agent.jev_effort_pending;
    if (pending.auto.future == null and pending.auto.saved == null) return;
    if (pending.auto.future) |*f| f.cancel(agent.io);
    pending.dropTurn(agent.io);
    if (pending.auto.applied) |a| if (agent.reasoning == a) {
        if (pending.auto.saved) |s| {
            if (!agent.sub and agent.reasoning != s) @import("prompt_cache_hud.zig").noteBust(.effort);
            agent.reasoning = s;
        }
    };
    if (agent.tracer) |tr| {
        var buf: [96]u8 = undefined;
        const outcome = pending.auto.outcome.load(.acquire);
        const line = std.fmt.bufPrint(&buf, "turn effort {s} in {d}ms{s}", .{
            if (outcome == 1) @tagName(pending.auto.picked) else "unavailable",
            pending.auto.ms.load(.acquire),
            if (outcome == 1 and pending.auto.applied == null) " (late, dropped)" else "",
        }) catch "turn effort";
        tr.note("jev", line);
    }
    if (pending.auto.task.len != 0) agent.gpa.free(pending.auto.task);
    pending.auto = .{};
}

test "ADR 0246: the summary keeps the request's words and drops what could identify the work" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("Fix the failing test in and run", try summary(a, "Fix the failing test in src/app/main.py and run `pytest -q`."));
    try std.testing.expectEqualStrings("Count the errors per service, then write", try summary(a, "Count the errors per service, then write summary.json\n```python\nsecret = 'sk-live-1234'\n```"));
    try std.testing.expectEqualStrings("Email about the outage", try summary(a, "Email bob@example.com about https://status.example.com the outage"));
    try std.testing.expectEqualStrings("Rename to in every caller", try summary(a, "Rename get_user to fetch_user in every caller"));
    try std.testing.expectEqualStrings("Close issue as done.", try summary(a, "Close issue 48213 as done."));
    try std.testing.expectEqualStrings("", try summary(a, "ghp_0123456789abcdefghijklmnopqrstuvwxyz"));
    var long: std.ArrayList(u8) = .empty;
    for (0..100) |_| try long.appendSlice(a, "word ");
    const cut = try summary(a, long.items);
    try std.testing.expect(cut.len <= max_summary and cut.len > max_summary - 10);
}

const TestAgent = struct {
    gpa: Allocator,
    io: Io,
    client: *std.http.Client,
    provider: @import("provider.zig").Provider,
    reasoning: ReasoningEffort = .medium,
    last_cache_read: i64 = 0,
    sub: bool = false,
    fast: bool = false,
    ultracode_mode: bool = false,
    show_thinking: bool = false,
    ai_title: bool = false,
    messages: std.json.Array,
    tracer: ?*@import("trace.zig").Tracer = null,
    jev_effort_pending: @import("jev_effort_state.zig").Pending = .{},
};

fn testAgent(arena: Allocator, client: *std.http.Client, prompt: []const u8) !TestAgent {
    var messages = std.json.Array.init(arena);
    var user: std.json.ObjectMap = .empty;
    try user.put(arena, "role", .{ .string = "user" });
    try user.put(arena, "content", .{ .string = prompt });
    try messages.append(.{ .object = user });
    return .{ .gpa = std.testing.allocator, .io = std.testing.io, .client = client, .messages = messages, .provider = .{ .id = "chatgpt-new", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-6.1-sol", .context = 272_000 } };
}

fn waitPick(agent: *TestAgent) void {
    if (agent.jev_effort_pending.auto.future) |*f| f.await(agent.io);
}

test "ADR 0246: the pick runs alongside the turn, applies at the next request, and the turn's end puts the default back" {
    const Env = struct {
        mode: []const u8,
        auto: ?[]const u8 = null,
        pub fn get(self: @This(), key: []const u8) ?[]const u8 {
            if (std.mem.eql(u8, key, "JEV_BACKEND")) return self.mode;
            if (std.mem.eql(u8, key, "GRAFF_JEV_AUTO")) return self.auto;
            return null;
        }
    };
    // Default is off (#1320): without GRAFF_JEV_AUTO=1, configure leaves enabled false.
    jev_tool.configure(Env{ .mode = "mock" });
    try std.testing.expect(!enabled);
    jev_tool.configure(Env{ .mode = "mock", .auto = "1" });
    defer jev_tool.configure(Env{ .mode = "" });
    _ = jev_tool.setCodegraffLoginKey(std.testing.io, "synthetic-login");
    defer _ = jev_tool.setCodegraffLoginKey(std.testing.io, null);
    const state = @import("jev_effort_state.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var client: std.http.Client = undefined;

    // beginTurn returns before the pick lands: the first request runs at the default.
    var agent = try testAgent(arena_state.allocator(), &client, "Refactor the session store and keep the tests green");
    beginTurn(&agent);
    try std.testing.expectEqual(ReasoningEffort.medium, agent.reasoning);
    waitPick(&agent);
    state.apply(&agent); // the next request boundary
    try std.testing.expectEqual(ReasoningEffort.high, agent.reasoning); // the mock answers high
    endTurn(&agent);
    try std.testing.expectEqual(ReasoningEffort.medium, agent.reasoning);

    // A pick no request applied is dropped at the turn's end, not applied or saved.
    var late = try testAgent(arena_state.allocator(), &client, "Refactor the session store");
    beginTurn(&late);
    waitPick(&late);
    endTurn(&late);
    try std.testing.expectEqual(ReasoningEffort.medium, late.reasoning);
    state.apply(&late);
    try std.testing.expectEqual(ReasoningEffort.medium, late.reasoning);

    // An effort changed during the turn stays.
    var changed = try testAgent(arena_state.allocator(), &client, "Refactor the session store");
    beginTurn(&changed);
    waitPick(&changed);
    state.apply(&changed);
    changed.reasoning = .xhigh;
    endTurn(&changed);
    try std.testing.expectEqual(ReasoningEffort.xhigh, changed.reasoning);

    // A user-chosen effort (including explicit medium), a warm cache, a subagent, and the off switch start no pick.
    var pinned = try testAgent(arena_state.allocator(), &client, "Refactor the session store");
    pinned.reasoning = .low;
    beginTurn(&pinned);
    try std.testing.expect(pinned.jev_effort_pending.auto.future == null);
    var pinned_medium = try testAgent(arena_state.allocator(), &client, "Refactor the session store");
    pinned_medium.jev_effort_pending.pinUserEffort(std.testing.io);
    beginTurn(&pinned_medium);
    try std.testing.expect(pinned_medium.jev_effort_pending.auto.future == null);
    var warm = try testAgent(arena_state.allocator(), &client, "Refactor the session store");
    warm.last_cache_read = 12_544;
    beginTurn(&warm);
    try std.testing.expect(warm.jev_effort_pending.auto.future == null);
    var child = try testAgent(arena_state.allocator(), &client, "Refactor the session store");
    child.sub = true;
    beginTurn(&child);
    try std.testing.expect(child.jev_effort_pending.auto.future == null);
    setEnabled("0");
    var off = try testAgent(arena_state.allocator(), &client, "Refactor the session store");
    beginTurn(&off);
    try std.testing.expect(off.jev_effort_pending.auto.future == null);
}
