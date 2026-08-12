//! Server-side autocompaction for the Responses wire (codex / OpenAI family).
//!
//! OpenAI Codex parity uses the standalone `/responses/compact` transaction:
//! send the complete Responses history, then install the endpoint's complete
//! `output` array. Keeping only an in-stream encrypted item is not equivalent:
//! repeated tool-history replay retained 10/10 facts only 1/3 times, while the
//! endpoint's retained messages + compaction_summary restored 10/10.
//!
//! Policy split vs the client-side path (agent_compact.zig):
//!   - the first-party `codex` Responses provider: automatic compaction calls
//!     the standalone endpoint and transactionally replaces the full history;
//!     local prose compaction remains the failure fallback and manual path.
//!   - every other provider kind/id: unchanged legacy policy.

const std = @import("std");
const Io = std.Io;
const main_mod = @import("main.zig");
const Agent = @import("agent.zig").Agent;
const Provider = @import("provider.zig").Provider;
const telemetry = @import("telemetry.zig");
const keys_cli = @import("keys_cli.zig");
const http = @import("http.zig");

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
/// Restrict this to OpenAI's two first-party providers, not merely the Responses
/// wire, so a future compatible gateway cannot inherit the opaque compaction
/// protocol accidentally.
pub fn enabled(p: Provider) bool {
    if (p.kind != .responses or !(std.mem.eql(u8, p.id, "codex") or std.mem.eql(u8, p.id, "openai"))) return false;
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

/// Automatic compaction is a standalone transaction. Do not also request
/// in-stream compaction: its single opaque item is not the full replacement
/// history returned by `/responses/compact`.
pub fn writeContextManagement(_: *const Agent, _: anytype) !void {}

const ReplacementCounts = struct { old: usize, new: usize };

fn compactEndpoint(gpa: std.mem.Allocator, response_url: []const u8) ![]u8 {
    const base = std.mem.trimEnd(u8, response_url, "/");
    if (std.mem.endsWith(u8, base, "/responses/compact")) return gpa.dupe(u8, base);
    if (!std.mem.endsWith(u8, base, "/responses")) return error.InvalidCompactEndpoint;
    return std.fmt.allocPrint(gpa, "{s}/compact", .{base});
}

fn compactRequestBody(self: *Agent) ![]u8 {
    var aw: Io.Writer.Allocating = .init(self.gpa);
    errdefer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("model");
    try s.write(self.provider.model);
    try s.objectField("instructions");
    try s.write(self.systemPrompt());
    try s.objectField("input");
    try s.write(std.json.Value{ .array = self.messages });
    try s.endObject();
    return aw.toOwnedSlice();
}

fn cloneJsonValue(arena: std.mem.Allocator, value: std.json.Value) std.mem.Allocator.Error!std.json.Value {
    return switch (value) {
        .string => |src| .{ .string = try arena.dupe(u8, src) },
        .number_string => |src| .{ .number_string = try arena.dupe(u8, src) },
        .array => |src| blk: {
            var out = std.json.Array.init(arena);
            try out.ensureTotalCapacity(src.items.len);
            for (src.items) |item_value| try out.append(try cloneJsonValue(arena, item_value));
            break :blk .{ .array = out };
        },
        .object => |src| blk: {
            var out: std.json.ObjectMap = .empty;
            var it = src.iterator();
            while (it.next()) |entry| {
                const key = try arena.dupe(u8, entry.key_ptr.*);
                try out.put(arena, key, try cloneJsonValue(arena, entry.value_ptr.*));
            }
            break :blk .{ .object = out };
        },
        else => value,
    };
}

/// Validate and install the endpoint's complete replacement history. Parsing
/// happens in a temporary arena; no live field changes until every returned item
/// has been validated and cloned into the session arena.
fn installCompactResponse(self: *Agent, body: []const u8) !ReplacementCounts {
    var parse_state = std.heap.ArenaAllocator.init(self.gpa);
    defer parse_state.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, parse_state.allocator(), body, .{ .allocate = .alloc_always }) catch
        return error.InvalidCompactResponse;
    if (parsed != .object) return error.InvalidCompactResponse;
    const output = parsed.object.get("output") orelse return error.InvalidCompactResponse;
    if (output != .array) return error.InvalidCompactResponse;
    if (output.array.items.len == 0) return error.EmptyCompactOutput;
    for (output.array.items) |response_item| {
        if (response_item != .object) return error.InvalidCompactResponse;
        const item_type = response_item.object.get("type") orelse return error.InvalidCompactResponse;
        if (item_type != .string or item_type.string.len == 0) return error.InvalidCompactResponse;
    }

    var replacement = std.json.Array.init(self.arena);
    try replacement.ensureTotalCapacity(output.array.items.len);
    for (output.array.items) |response_item|
        try replacement.append(try cloneJsonValue(self.arena, response_item));

    const counts: ReplacementCounts = .{ .old = self.messages.items.len, .new = replacement.items.len };
    self.closeCodexWs();
    self.messages = replacement;
    self.last_context_tokens = 0;
    self.context_local_tokens = 0;
    self.goal_note_fp = 0;
    self.history_rewrites +%= 1;
    notePrune(counts.old -| counts.new);
    return counts;
}

fn remoteCompact(self: *Agent) !ReplacementCounts {
    const body = try compactRequestBody(self);
    defer self.gpa.free(body);
    const url = try compactEndpoint(self.gpa, self.provider.url);
    defer self.gpa.free(url);
    var compact_provider = self.provider;
    compact_provider.url = url;
    const response = try http.postWatched(self.gpa, self.io, self.client, compact_provider, body);
    defer self.gpa.free(response);
    return installCompactResponse(self, response);
}

/// The autocompact entry point shared by every automatic compaction site
/// (agent.zig's in-turn pre-send gate and mainloop's between-turn checks).
/// Non-responses providers get the legacy policy unchanged.
pub fn autocompact(self: *Agent, recovery_meter: u64) void {
    autocompactIf(self, recovery_meter, enabled(self.provider));
}

/// Restored sessions compact before their first turn, but resume alone must
/// never authorize destructive recovery. A failed server transaction therefore
/// takes the same local-summary fallback with `trim_on_fail = false`.
pub fn autocompactResumed(self: *Agent) void {
    autocompactIf(self, 0, enabled(self.provider));
}

fn autocompactIf(self: *Agent, recovery_meter: u64, server_arm: bool) void {
    const near_limit = self.provider.nearContextLimit(recovery_meter);
    if (!server_arm or self.provider.kind != .responses) {
        self.compactOrRecover(near_limit);
        return;
    }
    const counts = remoteCompact(self) catch |err| {
        if (err == error.Interrupted) return;
        if (main_mod.json_mode)
            self.emit(.{ .type = "compact", .ok = false, .mechanism = "server", .message = @errorName(err), .fallback = "local" })
        else
            self.say("[server compaction unavailable: {t}; falling back to local summary]\n", .{err}) catch {};
        self.compactOrRecover(near_limit);
        return;
    };
    if (main_mod.json_mode)
        self.emit(.{ .type = "compact", .ok = true, .mechanism = "server", .items_before = counts.old, .items_after = counts.new })
    else
        self.say("[server compacted context: replaced {d} history item(s) with {d}]\n", .{ counts.old, counts.new }) catch {};
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

test "enabled: OpenAI Responses only; unassigned defaults to client; override wins" {
    var p: Provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "k", .model = "m", .context = 272_000 };
    try std.testing.expect(!enabled(p)); // no assignment in tests → client arm
    p.kind = .anthropic;
    try std.testing.expect(!enabled(p));
    p.kind = .openai;
    try std.testing.expect(!enabled(p));
    p.kind = .responses;
    p.id = "compatible-gateway";
    g_server_compact_override = true;
    try std.testing.expect(!enabled(p));
    p.id = "codex";
    try std.testing.expect(enabled(p));
    p.id = "openai";
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

test "compactEndpoint: derives only the standalone Responses endpoint" {
    const a = std.testing.allocator;
    const derived = try compactEndpoint(a, "https://chatgpt.com/backend-api/codex/responses/");
    defer a.free(derived);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex/responses/compact", derived);
    try std.testing.expectError(error.InvalidCompactEndpoint, compactEndpoint(a, "https://example.com/v1/chat/completions"));
}

test "compactRequestBody: sends model, instructions, and the complete history" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    agent.provider.model = "gpt-test";
    agent.sys_normal = "system-test";
    try agent.messages.append(try item(a, "message", null));
    try agent.messages.append(try item(a, "function_call", "call-1"));
    const body = try compactRequestBody(&agent);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    try std.testing.expectEqualStrings("gpt-test", parsed.object.get("model").?.string);
    try std.testing.expectEqualStrings("system-test", parsed.object.get("instructions").?.string);
    try std.testing.expectEqual(@as(usize, 2), parsed.object.get("input").?.array.items.len);
    try std.testing.expect(parsed.object.get("context_management") == null);
}

test "writeContextManagement: standalone transaction emits no in-stream directive" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    var aw: Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try writeContextManagement(&agent, &s);
    try s.endObject();
    try std.testing.expectEqualStrings("{}", aw.written());
}

test "installCompactResponse: installs the complete retained history and resets its anchors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    try agent.messages.append(try item(a, "message", null));
    agent.last_context_tokens = 200_000;
    agent.context_local_tokens = 190_000;
    const body =
        "{\"output\":[" ++
        "{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"kept user\"}]}," ++
        "{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"kept assistant\"}]}," ++
        "{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"recent user\"}]}," ++
        "{\"type\":\"compaction_summary\",\"encrypted_content\":\"opaque\"}]}";
    const counts = try installCompactResponse(&agent, body);
    try std.testing.expectEqual(@as(usize, 1), counts.old);
    try std.testing.expectEqual(@as(usize, 4), counts.new);
    try std.testing.expectEqual(@as(usize, 4), agent.messages.items.len);
    try std.testing.expectEqualStrings("message", agent.messages.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("kept user", agent.messages.items[0].object.get("content").?.array.items[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("compaction_summary", agent.messages.items[3].object.get("type").?.string);
    try std.testing.expectEqual(@as(u32, 1), agent.history_rewrites);
    try std.testing.expectEqual(@as(u64, 0), agent.last_context_tokens);
    try std.testing.expectEqual(@as(u64, 0), agent.context_local_tokens);
}

test "installCompactResponse: malformed or empty output preserves the original history" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    try agent.messages.append(try item(a, "message", null));
    agent.last_context_tokens = 88_000;
    try std.testing.expectError(error.InvalidCompactResponse, installCompactResponse(&agent, "{not json"));
    try std.testing.expectError(error.EmptyCompactOutput, installCompactResponse(&agent, "{\"output\":[]}"));
    try std.testing.expectError(error.InvalidCompactResponse, installCompactResponse(&agent, "{\"output\":{}}"));
    try std.testing.expectError(error.InvalidCompactResponse, installCompactResponse(&agent, "{\"output\":[{}]}"));
    try std.testing.expectError(error.InvalidCompactResponse, installCompactResponse(&agent, "{\"output\":[{\"type\":7}]}"));
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);
    try std.testing.expectEqualStrings("message", agent.messages.items[0].object.get("type").?.string);
    try std.testing.expectEqual(@as(u32, 0), agent.history_rewrites);
    try std.testing.expectEqual(@as(u64, 88_000), agent.last_context_tokens);
}

test "installCompactResponse: a non-item output element preserves the original history" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a, .responses);
    try agent.messages.append(try item(a, "message", null));
    try std.testing.expectError(error.InvalidCompactResponse, installCompactResponse(&agent, "{\"output\":[42]}"));
    try std.testing.expectEqual(@as(usize, 1), agent.messages.items.len);
    try std.testing.expectEqual(@as(u32, 0), agent.history_rewrites);
}
