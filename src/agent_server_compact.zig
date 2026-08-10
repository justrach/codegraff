//! Server-side autocompaction for the Responses wire (codex / OpenAI family).
//!
//! Verified against the live codex backend (gpt-5.6-sol, ChatGPT OAuth,
//! store:false): it honors `context_management: [{"type":"compaction",
//! "compact_threshold":N}]` — when the rendered window crosses N the server
//! runs a compaction pass IN-STREAM and emits opaque `compaction` output items
//! (Fernet-encrypted state blobs). Those items flow through parseResponses and
//! stepResponses into history untouched, so no ingestion change was needed.
//! Sending only the latest blob + a new message continues the conversation
//! with full recall (probe: .graff/scratch/compact_continue.py), which is the
//! docs' "drop items before the most recent compaction item" latency rule.
//!
//! Policy split vs the client-side path (agent_compact.zig):
//!   - .responses providers: autocompact prunes local history to the newest
//!     server blob (zero model calls, near-lossless); the client-side summary
//!     survives only as the near-the-wall (95%) fallback, and manual /compact
//!     stays client-side so the handoff remains inspectable.
//!   - every other provider kind: unchanged legacy policy.
//!
//! The opaque blob's server-side lifetime under store:false is unknown; if a
//! resumed session's blob is ever rejected, the ordinary overflow recovery
//! ladder (agent_overflow.zig) is the safety net.

const std = @import("std");
const Io = std.Io;
const main_mod = @import("main.zig");
const Agent = @import("agent.zig").Agent;
const Provider = @import("provider.zig").Provider;
const telemetry = @import("telemetry.zig");
const keys_cli = @import("keys_cli.zig");

/// GRAFF_SERVER_COMPACT=0/false/off forces the client arm, =1 forces the
/// server arm (session_settings.applyEnvKnobs). Default: A/B assignment.
pub var g_server_compact_override: ?bool = null;

/// A/B assignment (#compact-ab): 50/50, bucketed by the anonymous install id
/// so a person's arm is stable across sessions and machines stay whole-user
/// consistent. Set once per process by assignArm (startup); null means
/// unassigned, which behaves as the client arm (the pre-feature default).
var g_ab_arm: ?bool = null;

/// Pure bucketing: true = server arm. Deterministic on the install id.
pub fn armForId(id: *const [32]u8) bool {
    return (std.hash.Wyhash.hash(0, id) & 1) == 0;
}

/// Startup hook (session_settings.setupSkillsAndTheme): bucket this install.
/// The env override wins outright, so no assignment is made when it is set.
pub fn assignArm(io: Io, arena: std.mem.Allocator, home: []const u8) void {
    if (g_server_compact_override != null or g_ab_arm != null) return;
    const id = keys_cli.loadOrCreateId(io, arena, home, ".simple-harness-install-id");
    g_ab_arm = armForId(&id);
}

/// Is the server-compaction path active for this provider?
pub fn enabled(p: Provider) bool {
    if (p.kind != .responses) return false;
    if (g_server_compact_override) |o| return o;
    return g_ab_arm orelse false;
}

/// One OTLP log record: body="experiment", kind="compact_ab", detail carries
/// the fact ("arm=server", "prune_items=5", "summary_chars=8481"). Static or
/// numeric content only — never user text. No-op without a telemetry sink.
fn pushExp(detail: []const u8) void {
    const t = telemetry.g_telem orelse return;
    if (!t.on()) return;
    const dup = t.gpa.dupe(u8, detail) catch "";
    t.mutex.lockUncancelable(t.io);
    t.push(.{ .t_ms = t.elapsedMsLocked(), .body = "experiment", .kind = "compact_ab", .detail = dup });
    t.mutex.unlock(t.io);
    t.maybeFlushEvents();
}

var g_ab_noted = false; // one exposure record per process; a race double-counts harmlessly

/// Record which arm this session is in (both arms, so the control group is
/// visible). Called from the Responses request-body builder on every build;
/// the flag makes it once per process.
pub fn noteExposure(self: *Agent) void {
    if (g_ab_noted or self.provider.kind != .responses) return;
    g_ab_noted = true;
    pushExp(if (enabled(self.provider)) "arm=server" else "arm=client");
}

/// Session compaction counters (all providers) for per-goal effort diffs in
/// task_outcome.zig. Monotonic per process; saturating adds, never reset.
pub var session_prunes: u64 = 0;
pub var session_summaries: u64 = 0;

/// Record a successful server-side prune (the treatment arm doing work).
fn notePrune(dropped: usize) void {
    session_prunes +|= 1;
    var buf: [24]u8 = undefined;
    const d = std.fmt.bufPrint(&buf, "prune_items={d}", .{dropped}) catch return;
    pushExp(d);
}

/// Record a successful client-side summary on a .responses provider — the
/// control arm doing work (auto at >=95%, or manual /compact on codex).
pub fn noteClientSummary(chars: usize) void {
    session_summaries +|= 1;
    var buf: [28]u8 = undefined;
    const d = std.fmt.bufPrint(&buf, "summary_chars={d}", .{chars}) catch return;
    pushExp(d);
}

/// Emit the compaction directive on a Responses request body. The threshold
/// mirrors the client-side trigger (compactAt: 80% of the window,
/// GRAFF_COMPACT_PCT-aware) so the server compacts at the point graff would
/// have.
pub fn writeContextManagement(self: *const Agent, s: anytype) !void {
    if (!enabled(self.provider)) return;
    try writeContextManagementBody(self, s);
}

fn writeContextManagementBody(self: *const Agent, s: anytype) !void {
    try s.objectField("context_management");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("compaction");
    try s.objectField("compact_threshold");
    try s.write(self.provider.compactAt());
    try s.endObject();
    try s.endArray();
}

/// Drop every item before the most recent server compaction blob; the blob
/// carries the pruned state (verified live). Returns false when there is no
/// usable blob, so the caller falls back to the client-side policy.
///
/// Pair safety: a function_call_output AFTER the blob whose call was pruned
/// would orphan locally (normalizeResponsesHistory doesn't repair pairing), so
/// such histories are left to the client-side path. In practice the trailing
/// blob lands at a response boundary where pairs are complete.
pub fn pruneToLatestBlob(self: *Agent) bool {
    return pruneIf(self, enabled(self.provider));
}

fn pruneIf(self: *Agent, server_arm: bool) bool {
    if (!server_arm or self.provider.kind != .responses) return false;
    const items = self.messages.items;
    var blob_idx: ?usize = null;
    for (items, 0..) |m, i| {
        if (m != .object) continue;
        const t = m.object.get("type") orelse continue;
        if (t != .string) continue;
        if (std.mem.eql(u8, t.string, "compaction") or std.mem.eql(u8, t.string, "compaction_summary")) blob_idx = i;
    }
    const k = blob_idx orelse return false;
    if (k == 0) return false; // already anchored on the blob
    // Collect the call_ids that survive, then reject if any surviving output
    // references a pruned call.
    var surviving: std.ArrayList([]const u8) = .empty;
    defer surviving.deinit(self.gpa);
    for (items[k..]) |m| {
        if (m != .object) continue;
        const t = m.object.get("type") orelse continue;
        if (t != .string or !std.mem.eql(u8, t.string, "function_call")) continue;
        const cid = m.object.get("call_id") orelse continue;
        if (cid == .string) surviving.append(self.gpa, cid.string) catch return false;
    }
    for (items[k..]) |m| {
        if (m != .object) continue;
        const t = m.object.get("type") orelse continue;
        if (t != .string or !std.mem.eql(u8, t.string, "function_call_output")) continue;
        const cid = m.object.get("call_id") orelse continue;
        if (cid != .string) continue;
        for (surviving.items) |sid| {
            if (std.mem.eql(u8, sid, cid.string)) break;
        } else return false; // orphaned output — not safe to prune
    }
    const dropped = k;
    var fresh = std.json.Array.init(self.arena);
    fresh.appendSlice(items[k..]) catch return false;
    self.messages = fresh;
    // Mirror compact()'s post-install meter reset: both anchors recompute
    // lazily, and the goal note died with the pruned prefix (#318).
    self.last_context_tokens = 0;
    self.context_local_tokens = 0;
    self.goal_note_fp = 0;
    self.history_rewrites +%= 1; // breaks the codex chain → next request re-anchors
    notePrune(dropped);
    if (!main_mod.json_mode) self.say("[server compacted context: {d} earlier item(s) now carried by the model's compaction state]\n", .{dropped}) catch {};
    return true;
}

/// The autocompact entry point shared by every automatic compaction site
/// (agent.zig's in-turn pre-send gate, mainloop's post-failure and
/// between-turns checks). Non-responses providers get the legacy policy
/// unchanged.
pub fn autocompact(self: *Agent, recovery_meter: u64) void {
    autocompactIf(self, recovery_meter, enabled(self.provider));
}

fn autocompactIf(self: *Agent, recovery_meter: u64, server_arm: bool) void {
    if (!server_arm or self.provider.kind != .responses) {
        self.compactOrRecover(self.provider.nearContextLimit(recovery_meter));
        return;
    }
    if (pruneIf(self, true)) return;
    // No blob yet: the server compacts in-stream at the same threshold, so
    // trust it at the ordinary compactAt line; the client-side summary (and
    // its destructive fallback) is reserved for genuinely near the wall, where
    // shipping the request itself would risk an over-cap hard failure (#163).
    if (self.provider.nearContextLimit(recovery_meter))
        self.compactOrRecover(true);
}

const test_support = @import("agent_compact_test_support.zig");

fn testAgent(a: std.mem.Allocator, kind: Provider.Kind) Agent {
    var agent = test_support.subAgent(a, false);
    agent.provider.kind = kind;
    agent.gpa = a;
    agent.out = null;
    agent.label = "t";
    agent.goal_note_fp = 0;
    agent.history_rewrites = 0;
    agent.messages = std.json.Array.init(a);
    return agent;
}

fn item(a: std.mem.Allocator, typ: []const u8, call_id: ?[]const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "type", .{ .string = typ });
    if (call_id) |c| try obj.put(a, "call_id", .{ .string = c });
    return .{ .object = obj };
}

test "enabled: responses-only; unassigned defaults to client; override wins" {
    var p: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "k", .model = "m", .context = 272_000 };
    try std.testing.expect(!enabled(p)); // no assignment in tests → client arm
    p.kind = .anthropic;
    try std.testing.expect(!enabled(p));
    p.kind = .openai;
    try std.testing.expect(!enabled(p));
    p.kind = .responses;
    g_server_compact_override = true;
    try std.testing.expect(enabled(p));
    g_server_compact_override = false;
    try std.testing.expect(!enabled(p));
    g_server_compact_override = null;
}

test "armForId: deterministic bucketing of the install id" {
    const id: [32]u8 = "0123456789abcdef0123456789abcdef".*;
    try std.testing.expectEqual(armForId(&id), armForId(&id));
    const other: [32]u8 = "ffffffffffffffffffffffffffffffff".*;
    _ = armForId(&other); // both buckets are reachable outcomes; no crash, pure
}

test "writeContextManagement: threshold mirrors compactAt; silent for other kinds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    var aw: @import("std").Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try writeContextManagementBody(&agent, &s);
    try s.endObject();
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"context_management\":[{\"type\":\"compaction\",\"compact_threshold\":80000}]") != null); // 80% of 100k
    agent.provider.kind = .anthropic;
    var aw2: @import("std").Io.Writer.Allocating = .init(a);
    var s2: std.json.Stringify = .{ .writer = &aw2.writer };
    try s2.beginObject();
    try writeContextManagement(&agent, &s2);
    try s2.endObject();
    try std.testing.expectEqualStrings("{}", aw2.written());
}

test "pruneToLatestBlob: no blob or blob-first leaves history untouched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    try agent.messages.append(try item(a, "message", null));
    try std.testing.expect(!pruneIf(&agent, true));
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);
    // blob already at the head: nothing to prune
    var agent2 = testAgent(a, .responses);
    try agent2.messages.append(try item(a, "compaction", null));
    try agent2.messages.append(try item(a, "message", null));
    try std.testing.expect(!pruneIf(&agent2, true));
    try std.testing.expectEqual(@as(usize, 2), agent2.messages.items.len);
    try std.testing.expectEqual(@as(u32, 0), agent2.history_rewrites);
}

test "pruneToLatestBlob: prunes to the newest blob and resets the meters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    try agent.messages.append(try item(a, "message", null)); // pruned
    try agent.messages.append(try item(a, "compaction", null)); // older blob — superseded
    try agent.messages.append(try item(a, "message", null)); // pruned
    try agent.messages.append(try item(a, "compaction", null)); // newest blob
    try agent.messages.append(try item(a, "function_call", "c1")); // pair survives intact
    try agent.messages.append(try item(a, "function_call_output", "c1"));
    agent.last_context_tokens = 200_000;
    agent.context_local_tokens = 190_000;
    try std.testing.expect(pruneIf(&agent, true));
    try std.testing.expectEqual(@as(usize, 3), agent.messages.items.len);
    try std.testing.expectEqualStrings("compaction", agent.messages.items[0].object.get("type").?.string);
    try std.testing.expectEqual(@as(u32, 1), agent.history_rewrites);
    try std.testing.expectEqual(@as(u64, 0), agent.last_context_tokens);
    try std.testing.expectEqual(@as(u64, 0), agent.context_local_tokens);
}

test "pruneToLatestBlob: an orphaned tool output refuses the prune" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    try agent.messages.append(try item(a, "function_call", "c1")); // pruned by the cut
    try agent.messages.append(try item(a, "compaction", null));
    try agent.messages.append(try item(a, "function_call_output", "c1")); // orphan if pruned
    try std.testing.expect(!pruneIf(&agent, true));
    try std.testing.expectEqual(@as(usize, 3), agent.messages.items.len);
}

test "pruneIf: never fires off the server arm or off responses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .anthropic);
    try agent.messages.append(try item(a, "message", null));
    try agent.messages.append(try item(a, "compaction", null));
    try std.testing.expect(!pruneIf(&agent, true));
    try std.testing.expectEqual(@as(usize, 2), agent.messages.items.len);
}

test "autocompact: responses providers hold at the ordinary threshold without a blob" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses); // context 100_000
    try agent.messages.append(try item(a, "message", null));
    // Over the 80% compactAt line but under the 95% wall, no blob: the server
    // owns compaction now, so history must survive untouched (legacy policy
    // would have run a summary here).
    autocompactIf(&agent, 85_000, true);
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);
    try std.testing.expectEqual(@as(u32, 0), agent.history_rewrites);
}
