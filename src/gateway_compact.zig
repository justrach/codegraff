//! Hosted compaction (ADR 0252). With a persisted Codegraff login, compaction
//! runs through the gateway's POST /v1/compact before graff's own summary: a
//! decision model drops stale tool calls and results — text is never
//! rewritten — and when that frees too little the gateway splices a summary of
//! the middle in ("hybrid"). gateway_compact_wire.zig maps the history out and
//! applies the reply back onto graff's own items by call id.
//!
//! Without a login nothing changes. A refused key or exhausted credits switch
//! the hosted path off for the session (`on_credits_exhausted` decides what
//! credits do next); any other failure — a 5xx, a timeout, a reply that does
//! not check out — falls back to the local summary for that compaction only.
//! A gateway problem can cost one compaction its quality, never the session
//! its progress.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const Agent = @import("agent.zig").Agent;
const Provider = @import("provider.zig").Provider;
const main_mod = @import("main.zig");
const wire = @import("gateway_compact_wire.zig");
const compact_cut = @import("compact_cut.zig");
const tool_spill = @import("tool_spill.zig");
const pricing = @import("pricing.zig");
const acp_compaction = @import("acp_compaction.zig");

pub const endpoint = "https://gateway.codegraff.com/v1/compact";
const default_model = "clef";

/// Bytes a trimmed tool result keeps: head and tail around a gap, plus the
/// #409 pointer to the full output when the session is durable.
const stub_cap: usize = 800;
const stub_fallback = "[older tool output trimmed by compaction]";

/// A reply must free at least this share of the estimated context, or the
/// local summary runs instead: installing less would trigger compaction again
/// on the next request and pay for it again.
const min_freed_pct: u64 = 10;

pub const CreditPolicy = enum {
    /// Keep compacting with the local summary; say so once.
    local,
    /// Stop compacting for the rest of the session.
    off,
};
/// What a refusal for credits (insufficient_credits, key_budget_exceeded) does.
pub var on_credits_exhausted: CreditPolicy = .local;

const Trip = enum(u8) { none, credits, auth };

var g_mu: Io.Mutex = .init;
var g_key: []const u8 = "";
var g_url: []const u8 = endpoint;
var g_model: []const u8 = default_model;
var g_disabled = false;
var g_trip = std.atomic.Value(Trip).init(.none);
/// Bumped by every hosted compaction that installs, so `/compact` can tell
/// whether the last line is about the compaction it just asked for.
var g_seq = std.atomic.Value(u32).init(0);
var g_line_buf: [160]u8 = undefined;
var g_line_len: usize = 0;

fn isOff(v: []const u8) bool {
    const t = std.mem.trim(u8, v, " \t");
    return std.mem.eql(u8, t, "0") or std.ascii.eqlIgnoreCase(t, "off") or
        std.ascii.eqlIgnoreCase(t, "false") or std.ascii.eqlIgnoreCase(t, "no");
}

/// GRAFF_HOSTED_COMPACT=0 keeps compaction local. GRAFF_COMPACT_URL and
/// GRAFF_COMPACT_MODEL point it at another gateway or decision model.
pub fn configure(arena: Allocator, env: anytype) !void {
    g_disabled = if (env.get("GRAFF_HOSTED_COMPACT")) |v| isOff(v) else false;
    g_url = if (env.get("GRAFF_COMPACT_URL")) |v| try arena.dupe(u8, v) else endpoint;
    g_model = if (env.get("GRAFF_COMPACT_MODEL")) |v| try arena.dupe(u8, v) else default_model;
    g_trip.store(.none, .release);
}

/// The persisted Codegraff login, the only credential this endpoint takes
/// (the chat provider's key may belong to another vendor entirely). Null
/// clears it. The slice must outlive the session.
pub fn setLoginKey(io: Io, key: ?[]const u8) void {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    g_key = key orelse "";
    g_trip.store(.none, .release); // a new login gets a fresh chance
}

fn loginKey(io: Io) ?[]const u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    return if (g_key.len > 0) g_key else null;
}

pub fn seq() u32 {
    return g_seq.load(.acquire);
}

/// What the latest installed hosted compaction did, copied into `out`.
pub fn lastLine(io: Io, out: []u8) []const u8 {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    const n = @min(g_line_len, out.len);
    @memcpy(out[0..n], g_line_buf[0..n]);
    return out[0..n];
}

fn setLine(io: Io, line: []const u8) void {
    g_mu.lockUncancelable(io);
    defer g_mu.unlock(io);
    g_line_len = @min(line.len, g_line_buf.len);
    @memcpy(g_line_buf[0..g_line_len], line[0..g_line_len]);
    _ = g_seq.fetchAdd(1, .acq_rel);
}

const Stubber = struct {
    note: tool_spill.Note,

    pub fn stub(self: *const Stubber, a: Allocator, full: []const u8) []const u8 {
        if (full.len <= stub_cap) return full;
        const marker = self.note.text(a, full, stub_cap);
        const body = @import("output_elide.zig").headTail(a, full, stub_cap -| (marker.len + 1)) catch return marker;
        return std.fmt.allocPrint(a, "{s}\n{s}", .{ body, marker }) catch marker;
    }
};

fn goalText(self: *const Agent) ?[]const u8 {
    const g = self.goal orelse return null;
    return if (g.status == .complete) null else g.objective;
}

/// Called first by agent_compact.compact(). Null means "not handled here" —
/// no login, the opt-out, a refusal earlier in the session, too little
/// history to decide on, or a failure — and compact() then runs the local
/// summary exactly as before.
pub fn run(self: *Agent) anyerror!?usize {
    if (g_disabled) return null;
    const key = loginKey(self.io) orelse return null;
    switch (g_trip.load(.acquire)) {
        .none => {},
        .auth => return null,
        .credits => return if (on_credits_exhausted == .off) error.CompactionOff else null,
    }
    var scratch = std.heap.ArenaAllocator.init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const msgs = try wire.transcript(a, self.messages.items);
    // The first message and the newest few are pinned: below this the
    // endpoint has nothing to decide, and above its cap it refuses.
    if (msgs.len <= wire.recent_kept + 1 or msgs.len > wire.max_messages) return null;
    const body = try wire.request(a, msgs, g_model, goalText(self));

    self.closeCodexWs(); // the history is about to be rewritten
    @import("agent_compact.zig").pinChildTask(self);
    if (!main_mod.json_mode and @import("repl.zig").g_debug) try self.say("[compacting {d} messages on the gateway…]\n", .{msgs.len});
    var progress = @import("compact_status.zig").begin(self);
    defer progress.end(self);
    var acp_run = acp_compaction.start(!self.sub and self.call_kind != .title);
    defer acp_run.finish(.failed, null, "hosted compaction did not complete"); // no-op once finished

    const provider: Provider = .{ .id = "codegraff", .kind = .openai, .auth = .bearer, .url = g_url, .api_key = key, .model = g_model, .context = 0 };
    const posted = @import("http.zig").postWatched(self.gpa, self.io, self.client, provider, body, null);
    progress.end(self); // the spinner stops before anything below prints
    const raw = posted catch |err| switch (err) {
        error.Interrupted, error.Canceled => {
            acp_run.finish(.cancelled, null, "interrupted");
            return error.Interrupted;
        },
        error.OutOfMemory => return err,
        else => {
            pricing.g_cost.failedWithoutUsage(self.io, 1);
            return fallback(self, &acp_run, @errorName(err));
        },
    };
    defer self.gpa.free(raw);
    const root = std.json.parseFromSliceLeaky(Value, a, raw, .{ .allocate = .alloc_always }) catch {
        pricing.g_cost.failedWithoutUsage(self.io, 1);
        return fallback(self, &acp_run, "unreadable reply");
    };
    if (refusal(root)) |code| return refused(self, &acp_run, code);
    noteUsage(self.io, root);
    const reply = wire.parseReply(a, root) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return fallback(self, &acp_run, "unexpected reply"),
    };
    const outcome = install(self, a, msgs, &reply) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return fallback(self, &acp_run, @errorName(err)),
    };
    acp_run.finish(.completed, if (reply.summarized) reply.summary else outcome.line, null);
    if (!main_mod.json_mode and @import("repl.zig").g_debug) try self.say("[{s}]\n", .{outcome.line});
    return outcome.freed;
}

fn fallback(self: *Agent, acp_run: *acp_compaction.Run, reason: []const u8) ?usize {
    if (self.tracer) |tr| tr.note("hosted_compact_fallback", reason);
    var buf: [128]u8 = undefined;
    const why = std.fmt.bufPrint(&buf, "hosted compaction unavailable ({s}); compacting locally", .{reason}) catch "hosted compaction unavailable; compacting locally";
    acp_run.finish(.failed, null, why);
    if (!main_mod.json_mode) self.say("[{s}]\n", .{why}) catch {};
    return null;
}

/// The gateway's error envelope code, if the reply is a refusal.
pub fn refusal(root: Value) ?[]const u8 {
    if (root != .object) return null;
    const e = root.object.get("error") orelse return null;
    if (e != .object) return "error";
    const code = e.object.get("code") orelse e.object.get("type") orelse return "error";
    return if (code == .string) code.string else "error";
}

fn refused(self: *Agent, acp_run: *acp_compaction.Run, code: []const u8) anyerror!?usize {
    const eql = std.mem.eql;
    const credits = eql(u8, code, "insufficient_credits") or eql(u8, code, "key_budget_exceeded");
    const auth = eql(u8, code, "invalid_api_key") or eql(u8, code, "missing_api_key") or eql(u8, code, "insufficient_scope");
    if (!credits and !auth) return fallback(self, acp_run, code);
    g_trip.store(if (credits) .credits else .auth, .release);
    if (self.tracer) |tr| tr.note("hosted_compact_off", code);
    const off = credits and on_credits_exhausted == .off;
    const why = if (off)
        "compaction is off: Codegraff credits are used up — top up to turn it back on"
    else if (credits)
        "Codegraff credits are used up: compacting locally (a lossy summary) until you top up"
    else
        "hosted compaction unavailable (Codegraff key refused); compacting locally";
    acp_run.finish(.failed, null, why);
    if (!main_mod.json_mode) self.say("[{s}]\n", .{why}) catch {};
    return if (off) error.CompactionOff else null;
}

fn noteUsage(io: Io, root: Value) void {
    const usage = if (root == .object) root.object.get("usage") orelse Value.null else Value.null;
    if (usage == .object) {
        const input = count(usage.object.get("input_tokens"));
        const output = count(usage.object.get("output_tokens"));
        if (input != null and output != null) {
            if (@import("pricing_gateway.zig").settledCharge(root)) |charge|
                pricing.g_cost.addSettled(io, input.?, output.?, charge)
            else
                pricing.g_cost.addForProvider(io, .unpriced, "codegraff", g_model, input.?, 0, 0, output.?);
            return;
        }
    }
    pricing.g_cost.missingUsage(io);
}

fn count(v: ?Value) ?i64 {
    const n = v orelse return null;
    return if (n == .integer and n.integer >= 0) n.integer else null;
}

fn estimate(items: []const Value) u64 {
    var total: u64 = 0;
    for (items) |m| total +|= @import("context_tokens.zig").estimatedTokens(m);
    return total;
}

const Outcome = struct { freed: usize, line: []const u8 };

fn install(self: *Agent, a: Allocator, msgs: []const wire.Msg, reply: *const wire.Reply) !Outcome {
    const items = self.messages.items;
    const p = try wire.plan(a, msgs, reply, compact_cut.pinOpening(items));
    var note: ?Value = null;
    if (reply.summarized) {
        const base = try @import("agent_compact.zig").rootHandoff(self, reply.summary);
        const standing = try @import("goal_flow.zig").compactionSnapshot(self.arena, self);
        const discarded = try wire.replaced(a, items, msgs, p);
        const text = try @import("compact_handoff_note.zig").handoff(self.arena, self, base, standing, discarded);
        note = try @import("messages.zig").userNote(self.arena, self.provider.kind, text);
    }
    const stubber: Stubber = .{ .note = .{ .fallback = stub_fallback, .session = tool_spill.sessionFor(self.sub, self.session_name) } };
    // Earlier turns lose dropped calls outright; the live turn keeps them.
    const removable = compact_cut.turnOpeningUserIndex(items) orelse 0;
    const fresh = try wire.apply(self.arena, items, msgs, p, &reply.decisions, removable, note, &stubber);
    try wire.checkPairs(a, items, fresh.items);
    const before = estimate(items);
    const after = estimate(fresh.items);
    if (after * 100 > before * (100 - min_freed_pct)) return error.TooLittleFreed;
    const line = try outcomeLine(self.arena, reply, p);

    self.messages = fresh;
    self.compact_summary_failures = 0;
    self.last_context_tokens = 0;
    self.context_local_tokens = 0;
    if (reply.summarized) self.goal_note_fp = 0; // the injected goal note may be in the summarized middle (#318)
    self.history_rewrites +%= 1; // trimmed results may hold pasted state, e.g. a todo_write render (#318)
    @import("prompts.zig").noteSessionCompacted(self, self.arena);
    @import("hot_context.zig").afterCompact(self);
    const counters = @import("agent_server_compact.zig");
    if (reply.summarized) counters.session_summaries +|= 1 else counters.session_prunes +|= 1;
    setLine(self.io, line);
    if (self.tracer) |tr| tr.note("hosted_compact", line);
    return .{ .freed = @intCast(before - after), .line = line };
}

fn outcomeLine(a: Allocator, reply: *const wire.Reply, p: wire.Plan) ![]const u8 {
    var trimmed: usize = 0;
    var dropped: usize = 0;
    var it = reply.decisions.valueIterator();
    while (it.next()) |action| switch (action.*) {
        .drop_result => trimmed += 1,
        .drop_call => dropped += 1,
        .keep => {},
    };
    if (!reply.summarized)
        return std.fmt.allocPrint(a, "compacted on the gateway: trimmed {d} tool results, dropped {d} calls", .{ trimmed, dropped });
    var summarized: usize = 0;
    for (p.keep) |k| summarized += @intFromBool(!k);
    return std.fmt.allocPrint(a, "compacted on the gateway: summarized {d} earlier messages, trimmed {d} tool results, dropped {d} calls", .{ summarized, trimmed, dropped });
}
