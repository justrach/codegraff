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
//!     survives only as the near-the-wall (95%) fallback. Manual /compact uses
//!     OpenAI's standalone endpoint or Codex's forced in-stream directive.
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
const http = @import("http.zig");
const telemetry = @import("telemetry.zig");
const keys_cli = @import("keys_cli.zig");
const goal_flow = @import("goal_flow.zig");

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
    if (manualRoute(p) == .local) return false;
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
/// control arm doing automatic fallback work near the context wall.
pub fn noteClientSummary(chars: usize) void {
    session_summaries +|= 1;
    var buf: [28]u8 = undefined;
    const d = std.fmt.bufPrint(&buf, "summary_chars={d}", .{chars}) catch return;
    pushExp(d);
}

/// Emit the automatic directive at compactAt, or force an explicit Codex pass
/// independently of the experiment assignment. The backend's minimum threshold
/// of 1,000 guarantees every real graff context crosses it; the flag is route-
/// gated so a non-OpenAI Responses provider can never enter this path.
pub fn writeContextManagement(self: *const Agent, s: anytype) !void {
    // #502: an explicit-compact provider (xAI) ignores the in-stream directive
    // — probed live; compaction goes through explicitCompact instead.
    if (self.provider.serverCompactUrl() != null) return;
    const threshold = if (self.server_compaction_request and manualRoute(self.provider) == .in_stream)
        @as(u64, 1_000)
    else if (enabled(self.provider))
        self.provider.compactAt()
    else
        return;
    try writeContextManagementBody(s, threshold);
}

fn writeContextManagementBody(s: anytype, threshold: u64) !void {
    try s.objectField("context_management");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("compaction");
    try s.objectField("compact_threshold");
    try s.write(threshold);
    try s.endObject();
    try s.endArray();
}

const ManualRoute = enum { local, standalone, in_stream };

/// Only first-party OpenAI Responses providers get server-side manual compact:
/// direct API traffic uses `/responses/compact`; ChatGPT/Codex forces the
/// supported in-stream directive. Every other provider stays on local summary.
fn manualRoute(p: Provider) ManualRoute {
    if (p.kind != .responses) return .local;
    if (std.mem.eql(u8, p.id, "openai")) return .standalone;
    if (std.mem.eql(u8, p.id, "codex")) return .in_stream;
    return .local;
}

pub fn manualServerEligible(p: Provider) bool {
    return manualRoute(p) != .local;
}

fn compactEndpoint(arena: std.mem.Allocator, responses_url: []const u8) ![]const u8 {
    if (!std.mem.endsWith(u8, responses_url, "/responses")) return error.UnsupportedServerCompaction;
    return std.fmt.allocPrint(arena, "{s}/compact", .{responses_url});
}

fn compactBody(self: *const Agent) ![]u8 {
    var aw: Io.Writer.Allocating = .init(self.gpa);
    errdefer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("model");
    try s.write(self.provider.model);
    try s.objectField("input");
    try s.write(std.json.Value{ .array = self.messages });
    try s.objectField("instructions");
    try s.write(self.systemPrompt());
    try s.endObject();
    return aw.toOwnedSlice();
}

fn installItems(self: *Agent, items: []const std.json.Value) !void {
    var fresh = std.json.Array.init(self.arena);
    try fresh.appendSlice(items);
    self.messages = fresh;
    self.last_context_tokens = 0;
    self.context_local_tokens = 0;
    self.last_usage_includes_output = false;
    self.goal_note_fp = 0;
    self.history_rewrites +%= 1;
    session_prunes +|= 1; // manual compaction is not an A/B treatment exposure
}

fn installCompactedOutput(self: *Agent, response: std.json.Value) !usize {
    if (response != .object) return error.InvalidCompactionResponse;
    const output = response.object.get("output") orelse return error.InvalidCompactionResponse;
    if (output != .array or output.array.items.len == 0) return error.InvalidCompactionResponse;
    try installItems(self, output.array.items);
    return output.array.items.len;
}

fn installInStreamCompaction(self: *Agent, response: std.json.ObjectMap) !usize {
    if (response.get("incomplete")) |v| {
        if (v == .bool and v.bool) return error.IncompleteCompactionResponse;
    }
    const output = response.get("output") orelse return error.InvalidCompactionResponse;
    if (output != .array) return error.InvalidCompactionResponse;
    var compact_idx: ?usize = null;
    var payload_len: usize = 1;
    for (output.array.items, 0..) |v, i| {
        if (v != .object) continue;
        const kind = v.object.get("type") orelse continue;
        if (kind != .string) continue;
        if (!std.mem.eql(u8, kind.string, "compaction") and !std.mem.eql(u8, kind.string, "compaction_summary")) continue;
        compact_idx = i;
        payload_len = if (v.object.get("encrypted_content")) |state|
            if (state == .string and state.string.len > 0) state.string.len else 1
        else
            1;
    }
    const k = compact_idx orelse return error.MissingCompactionItem;
    try installItems(self, output.array.items[k .. k + 1]); // discard any quiet post-blob reply
    return payload_len;
}

fn compactStandalone(self: *Agent) !usize {
    const body = try compactBody(self);
    defer self.gpa.free(body);
    var compact_provider = self.provider;
    compact_provider.url = try compactEndpoint(self.arena, self.provider.url);
    const response_body = try http.postWatched(self.gpa, self.io, self.client, compact_provider, body);
    defer self.gpa.free(response_body);
    const response = std.json.parseFromSliceLeaky(std.json.Value, self.arena, response_body, .{ .allocate = .alloc_always }) catch {
        if (self.tracer) |tr| tr.note("server_compact_error", response_body[0..@min(response_body.len, 400)]);
        return error.InvalidCompactionResponse;
    };
    const items = installCompactedOutput(self, response) catch |err| {
        if (self.tracer) |tr| tr.note("server_compact_error", response_body[0..@min(response_body.len, 400)]);
        return err;
    };
    if (!main_mod.json_mode) try self.say("[OpenAI compacted context into {d} canonical item(s)]\n", .{items});
    return response_body.len;
}

fn compactInStream(self: *Agent) !usize {
    const live_context_tokens = self.last_context_tokens;
    const live_context_local_tokens = self.context_local_tokens;
    const live_effective_context = self.effectiveContextTokens();
    const live_usage_includes_output = self.last_usage_includes_output;
    const live_context_overflow = self.last_request_context_overflow;
    const live_write_failed = self.last_request_write_failed;
    self.last_request_context_overflow = false;
    errdefer {
        if (self.last_request_context_overflow) {
            self.context_local_tokens = self.fullRequestEstimateTokens();
            self.last_context_tokens = @max(live_effective_context, self.provider.context);
        } else {
            self.last_context_tokens = live_context_tokens;
            self.context_local_tokens = live_context_local_tokens;
            self.last_request_context_overflow = live_context_overflow;
        }
        self.last_usage_includes_output = live_usage_includes_output;
        self.last_request_write_failed = live_write_failed;
    }
    const was_quiet = self.stream_quiet;
    const was_compaction_request = self.compaction_request;
    const was_server_compaction = self.server_compaction_request;
    self.stream_quiet = true;
    self.compaction_request = true;
    self.server_compaction_request = true;
    defer self.stream_quiet = was_quiet;
    defer self.compaction_request = was_compaction_request;
    defer self.server_compaction_request = was_server_compaction;
    const response = try self.request(null);
    const payload_len = try installInStreamCompaction(self, response);
    self.closeCodexWs();
    if (!main_mod.json_mode) try self.say("[OpenAI compacted context into server state]\n", .{});
    return payload_len;
}

fn fallbackLocal(self: *Agent, err: anyerror) anyerror!usize {
    if (err == error.Interrupted or err == error.OutOfMemory) return err;
    if (self.tracer) |tr| tr.note("server_compact_fallback", @errorName(err));
    if (!main_mod.json_mode) try self.say("[OpenAI server compaction unavailable; falling back to local summary]\n", .{});
    return self.compact();
}

/// Explicit `/compact` selects the first-party server mechanism when one
/// exists. A failed or malformed server result never touches live history and
/// falls back to the existing inspectable local summary.
pub fn manualCompact(self: *Agent) anyerror!usize {
    const route = manualRoute(self.provider);
    if (route == .local) return self.compact();
    self.closeCodexWs();
    if (self.messages.items.len == 0) {
        if (!main_mod.json_mode) try self.say("nothing to compact\n", .{});
        return 0;
    }
    const pending_tokens = self.effectiveContextTokens();
    if (!main_mod.json_mode) try self.say("[compacting ~{d} tokens with OpenAI…]\n", .{pending_tokens});
    const result = switch (route) {
        .standalone => compactStandalone(self),
        .in_stream => compactInStream(self),
        .local => unreachable,
    } catch |err| return fallbackLocal(self, err);
    return result;
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
pub fn autocompactResumed(self: *Agent) void {
    autocompactIf(self, 0, enabled(self.provider));
}

fn autocompactIf(self: *Agent, recovery_meter: u64, server_arm: bool) void {
    // #502: an explicit-compact provider (xAI) gets first-party compaction —
    // one POST folds the whole history into an opaque blob, no summary model
    // call. Any failure falls through to the client policy so a broken
    // endpoint can never wedge the session.
    if (self.provider.serverCompactUrl() != null) {
        if (explicitCompact(self)) return;
        self.compactOrRecover(self.provider.nearContextLimit(recovery_meter));
        return;
    }
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

fn buildCompactBody(self: *Agent) ![]u8 {
    var aw: Io.Writer.Allocating = .init(self.gpa);
    errdefer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("model");
    try s.write(self.provider.model);
    try s.objectField("input");
    try s.write(std.json.Value{ .array = self.messages });
    try s.endObject();
    return aw.toOwnedSlice();
}

/// #502: explicit first-party compaction (xAI POST /v1/responses/compact):
/// ship the current input items, then restart history from the returned
/// opaque compaction item — the docs' "treat the compaction as the new
/// start". True when history was replaced; ANY failure leaves it untouched
/// so the caller can fall back to the client-side summary.
pub fn explicitCompact(self: *Agent) bool {
    const compact_url = self.provider.serverCompactUrl() orelse return false;
    if (self.messages.items.len == 0) return false;
    // Anti-thrash: a history already anchored on a blob with only a few items
    // after it cannot meaningfully shrink — when the threshold sits below the
    // standing prompt overhead (a tiny GRAFF_COMPACT_PCT), re-compacting every
    // step pays one API call per step forever. Let the client policy decide.
    const items = self.messages.items;
    if (items.len < 8 and items[0] == .object) {
        if (items[0].object.get("type")) |t| {
            if (t == .string and std.mem.eql(u8, t.string, "compaction")) return false;
        }
    }
    const body = buildCompactBody(self) catch return false;
    defer self.gpa.free(body);
    var cp = self.provider;
    cp.url = compact_url;
    if (!main_mod.json_mode) self.say("[compacting server-side: {d} item(s)…]\n", .{self.messages.items.len}) catch {};
    const resp = http.postWatched(self.gpa, self.io, self.client, cp, body) catch |err| {
        if (self.tracer) |tr| tr.note("compact", @errorName(err));
        return false;
    };
    defer self.gpa.free(resp);
    return installCompactionItem(self, resp);
}

/// Parse a compact-endpoint response and restart history from output[0].
/// Split from explicitCompact so a fixture response drives it in tests.
pub fn installCompactionItem(self: *Agent, resp: []const u8) bool {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, self.arena, resp, .{ .allocate = .alloc_always }) catch return false;
    if (parsed != .object) return false;
    const output = parsed.object.get("output") orelse return false;
    if (output != .array or output.array.items.len == 0) return false;
    const blob = output.array.items[0];
    if (blob != .object) return false;
    const t = blob.object.get("type") orelse return false;
    if (t != .string or !std.mem.eql(u8, t.string, "compaction")) return false;
    if (blob.object.get("encrypted_content") == null) return false;
    const dropped = self.messages.items.len;
    var fresh = std.json.Array.init(self.arena);
    fresh.append(blob) catch return false;
    self.messages = fresh;
    // Mirror pruneIf's meter/goal reset: both anchors recompute lazily, the
    // goal note died with the folded history (#318), and pasted-state readers
    // re-carry off history_rewrites.
    self.last_context_tokens = 0;
    self.context_local_tokens = 0;
    self.goal_note_fp = 0;
    self.history_rewrites +%= 1;
    if (self.pending_goal_note == null)
        self.pending_goal_note = goal_flow.compactionSnapshot(self.arena, self) catch null;
    notePrune(dropped);
    if (!main_mod.json_mode) self.say("[server compacted context: {d} item(s) folded into the model's compaction state]\n", .{dropped}) catch {};
    return true;
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

test "manual server compaction routes direct OpenAI and Codex only" {
    var p: Provider = .{ .id = "openai", .kind = .responses, .auth = .bearer, .url = "https://api.openai.com/v1/responses", .api_key = "k", .model = "m", .context = 272_000 };
    try std.testing.expectEqual(ManualRoute.standalone, manualRoute(p));
    p.id = "codex";
    try std.testing.expectEqual(ManualRoute.in_stream, manualRoute(p));
    try std.testing.expect(manualServerEligible(p));
    p.id = "openai-compatible-router";
    try std.testing.expectEqual(ManualRoute.local, manualRoute(p));
    p.id = "openai";
    p.kind = .openai;
    try std.testing.expect(!manualServerEligible(p));
    p.kind = .anthropic;
    try std.testing.expect(!manualServerEligible(p));
}

test "manual compact endpoint appends compact and rejects non-Responses URLs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("http://127.0.0.1:8765/responses/compact", try compactEndpoint(a, "http://127.0.0.1:8765/responses"));
    try std.testing.expectError(error.UnsupportedServerCompaction, compactEndpoint(a, "http://127.0.0.1:8765/chat/completions"));
}

test "manual compact body sends model, canonical Responses input, and instructions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    agent.provider.model = "gpt-test";
    agent.sys_normal = "system-test";
    try agent.messages.append(try item(a, "message", null));
    const body = try compactBody(&agent);
    defer a.free(body);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    try std.testing.expectEqualStrings("gpt-test", parsed.object.get("model").?.string);
    try std.testing.expectEqualStrings("system-test", parsed.object.get("instructions").?.string);
    try std.testing.expectEqual(@as(usize, 1), parsed.object.get("input").?.array.items.len);
}

test "installCompactedOutput transactionally replaces history and resets meters" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    try agent.messages.append(try item(a, "message", null));
    agent.last_context_tokens = 99;
    agent.context_local_tokens = 88;
    agent.goal_note_fp = 77;
    const invalid = std.json.Value{ .object = .empty };
    try std.testing.expectError(error.InvalidCompactionResponse, installCompactedOutput(&agent, invalid));
    try std.testing.expectError(error.InvalidCompactionResponse, installInStreamCompaction(&agent, .empty));
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);

    var output = std.json.Array.init(a);
    try output.append(try item(a, "message", null));
    var obj: std.json.ObjectMap = .empty;
    try obj.put(a, "output", .{ .array = output });
    try std.testing.expectError(error.MissingCompactionItem, installInStreamCompaction(&agent, obj));
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);
    try output.append(try item(a, "compaction", null));
    try output.append(try item(a, "message", null));
    try obj.put(a, "output", .{ .array = output });
    try std.testing.expectEqual(@as(usize, 3), try installCompactedOutput(&agent, .{ .object = obj }));
    try std.testing.expectEqual(@as(usize, 3), agent.messages.items.len);
    try std.testing.expectEqual(@as(usize, 1), try installInStreamCompaction(&agent, obj));
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);
    try std.testing.expectEqualStrings("compaction", agent.messages.items[0].object.get("type").?.string);
    try std.testing.expectEqual(@as(u64, 0), agent.last_context_tokens);
    try std.testing.expectEqual(@as(u64, 0), agent.context_local_tokens);
    try std.testing.expectEqual(@as(u64, 0), agent.goal_note_fp);
    try std.testing.expectEqual(@as(u64, 2), agent.history_rewrites);
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

test "writeContextManagement: automatic threshold and forced Codex pass stay OpenAI-only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    var aw: @import("std").Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try writeContextManagementBody(&s, 80_000);
    try s.endObject();
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"compact_threshold\":80000") != null);
    agent.provider.id = "codex";
    agent.server_compaction_request = true;
    var aw2: @import("std").Io.Writer.Allocating = .init(a);
    var s2: std.json.Stringify = .{ .writer = &aw2.writer };
    try s2.beginObject();
    try writeContextManagement(&agent, &s2);
    try s2.endObject();
    try std.testing.expect(std.mem.indexOf(u8, aw2.written(), "\"compact_threshold\":1000") != null);
    agent.provider.id = "openai-compatible-router";
    var aw3: @import("std").Io.Writer.Allocating = .init(a);
    var s3: std.json.Stringify = .{ .writer = &aw3.writer };
    try s3.beginObject();
    try writeContextManagement(&agent, &s3);
    try s3.endObject();
    try std.testing.expectEqualStrings("{}", aw3.written());
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

test "installCompactionItem restarts history from the blob and resets the meters (#502)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    agent.arena = a;
    try agent.messages.append(try item(a, "message", null));
    try agent.messages.append(try item(a, "function_call", "c1"));
    try agent.messages.append(try item(a, "function_call_output", "c1"));
    agent.last_context_tokens = 400_000;
    const resp =
        \\{"id":"cmp_1","object":"response.compaction","output":[{"type":"compaction","id":"cmp_1","encrypted_content":"BLOB"}],
        \\ "usage":{"input_tokens":9000,"output_tokens":400,"dropped_message_count":3}}
    ;
    try std.testing.expect(installCompactionItem(&agent, resp));
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);
    try std.testing.expectEqualStrings("compaction", agent.messages.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("BLOB", agent.messages.items[0].object.get("encrypted_content").?.string);
    try std.testing.expectEqual(@as(u64, 0), agent.last_context_tokens);
    try std.testing.expectEqual(@as(u32, 1), agent.history_rewrites);
}

test "installCompactionItem refuses malformed responses and leaves history intact (#502)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    agent.arena = a;
    try agent.messages.append(try item(a, "message", null));
    for ([_][]const u8{
        "not json",
        "{\"output\":[]}",
        "{\"output\":[{\"type\":\"message\"}]}",
        "{\"output\":[{\"type\":\"compaction\"}]}", // no encrypted_content
    }) |bad| {
        try std.testing.expect(!installCompactionItem(&agent, bad));
        try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);
        try std.testing.expectEqual(@as(u32, 0), agent.history_rewrites);
    }
}

test "explicitCompact anti-thrash: a fresh blob head with little growth refuses (#502)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    agent.arena = a;
    agent.provider.id = "xai"; // serverCompactUrl fires for xai + .responses
    try agent.messages.append(try item(a, "compaction", null));
    try agent.messages.append(try item(a, "message", null));
    // Guard trips BEFORE any network I/O — false, history untouched.
    try std.testing.expect(!explicitCompact(&agent));
    try std.testing.expectEqual(@as(usize, 2), agent.messages.items.len);
    try std.testing.expectEqual(@as(u32, 0), agent.history_rewrites);
}
