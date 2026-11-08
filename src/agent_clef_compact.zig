//! Clef-driven compaction client: the gateway's server-side POST /v1/compact
//! as this repo's replacement for the client-side summary (agent_compact.zig).
//!
//! The endpoint prunes stale tool calls/results with the Clef decision models
//! instead of summarizing: text messages stay verbatim and in order, only
//! tool calls/results are candidates for removal. Response shape:
//! `{model, mode, messages: [{role, text, toolUses[], toolResults?[]}], decisions[], stats, usage}`.
//!
//! Policy: OpenAI-family server paths are untouched (direct OpenAI standalone
//! `/responses/compact`, Codex/ChatGPT in-stream directive, xAI explicit
//! endpoint) — this arm replaces ONLY the client summarizer. Eligibility is
//! the codegraff gateway provider with a credential; every failure (network,
//! non-2xx, malformed) returns false and the caller falls back to the client
//! summary, so a broken endpoint can never wedge the session.
//!
//! Wire-format note: local history holds provider wire items (Responses
//! function_call/function_call_output, chat tool_calls/role:tool). The gateway
//! wants `{role, text, toolUses[{tool_use_id, tool, input}], toolResults?[{tool_use_id, text}]}`.
//! Translation pairs calls with outputs by call_id/tool_use_id; application
//! maps the returned decisions back the same way (drop_call removes both,
//! drop_result truncates the output to truncateHeadChars).

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const Agent = @import("agent.zig").Agent;
const main_mod = @import("main.zig");
const http = @import("http.zig");
const providers = @import("providers.zig");
const archive = @import("agent_clef_archive.zig"); // GRAFF_CLEF_ARCHIVE: stub + artifact instead of delete

/// GRAFF_CLEF_COMPACT=1 (any value but 0/false/off) arms the gateway
/// /v1/compact path (session_settings.applyEnvKnobs). Default OFF: the client
/// summary is the compactor (ADR 0261). OpenAI-family server paths stay
/// untouched regardless.
pub var g_enabled: bool = false;

pub fn enabled() bool {
    return g_enabled;
}

/// True when this session may compact through the gateway: knob on, provider
/// is the codegraff gateway, and a credential is present. Subagents share the
/// root provider so they inherit eligibility; review turns never compact.
pub fn eligible(self: *const Agent) bool {
    if (!g_enabled) return false;
    if (self.review_mode) return false;
    if (!std.mem.eql(u8, self.provider.id, "codegraff")) return false;
    return self.provider.api_key.len > 0;
}

/// Gateway compact URL derived from the session provider's chat URL:
/// `.../v1/chat/completions` and `.../v1/responses` both trim to `.../v1/compact`.
/// Null when the URL has no recognizable v1 root, so a custom override can
/// never route the transcript somewhere unexpected.
pub fn compactUrl(arena: Allocator, provider_url: []const u8) ?[]const u8 {
    const root = if (std.mem.indexOf(u8, provider_url, "/v1/")) |i| provider_url[0 .. i + 3] else return null;
    return std.fmt.allocPrint(arena, "{s}/compact", .{root}) catch null;
}

/// One translated message in the gateway transcript shape.
pub const GwMessage = struct {
    role: []const u8, // "user" | "assistant"
    text: []const u8,
    toolUses: std.ArrayList(GwUse),
    toolResults: std.ArrayList(GwResult),
};

const GwUse = struct {
    tool_use_id: []const u8,
    tool: []const u8,
    input_json: Value,
};

const GwResult = struct {
    tool_use_id: []const u8,
    text: []const u8,
};

fn strField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

/// Translate wire history items into gateway messages. Responses items carry
/// their own type; chat assistant tool_calls[] fold into uses on their
/// message and role:tool items become pending outputs. Text accumulates onto
/// the current message; reasoning/compaction items are skipped (the gateway
/// decides over tool calls, and opaque blobs must never leave the session).
pub fn translateHistory(arena: Allocator, items: []const Value, out: *std.ArrayList(GwMessage)) !void {
    var pending_outputs: std.ArrayList(GwResult) = .empty;
    for (items) |m| {
        if (m != .object) continue;
        const obj = m.object;
        if (strField(obj, "type")) |t| {
            if (std.mem.eql(u8, t, "function_call")) {
                const cid = strField(obj, "call_id") orelse continue;
                const name = strField(obj, "name") orelse "tool";
                const args_s = strField(obj, "arguments") orelse "{}";
                const input = std.json.parseFromSliceLeaky(Value, arena, args_s, .{}) catch Value{ .object = .empty };
                var msg = GwMessage{ .role = "assistant", .text = "", .toolUses = .empty, .toolResults = .empty };
                try msg.toolUses.append(arena, .{ .tool_use_id = cid, .tool = name, .input_json = input });
                try out.append(arena, msg);
                continue;
            }
            if (std.mem.eql(u8, t, "function_call_output")) {
                const cid = strField(obj, "call_id") orelse continue;
                const text = strField(obj, "output") orelse "";
                try pending_outputs.append(arena, .{ .tool_use_id = cid, .text = text });
                continue;
            }
            if (std.mem.eql(u8, t, "compaction") or std.mem.eql(u8, t, "compaction_summary") or std.mem.eql(u8, t, "reasoning")) continue;
        }
        const role = strField(obj, "role") orelse continue;
        if (!std.mem.eql(u8, role, "user") and !std.mem.eql(u8, role, "assistant") and !std.mem.eql(u8, role, "tool")) continue;
        const text = providers.extractText(arena, m);
        if (std.mem.eql(u8, role, "tool")) {
            const cid = strField(obj, "tool_call_id") orelse "";
            if (cid.len > 0) try pending_outputs.append(arena, .{ .tool_use_id = cid, .text = text });
            continue;
        }
        var msg = GwMessage{ .role = role, .text = text, .toolUses = .empty, .toolResults = .empty };
        if (obj.get("tool_calls")) |tc| {
            if (tc == .array) for (tc.array.items) |call| {
                if (call != .object) continue;
                const f = call.object.get("function") orelse continue;
                if (f != .object) continue;
                const cid = strField(call.object, "id") orelse continue;
                const name = strField(f.object, "name") orelse "tool";
                const args_s = strField(f.object, "arguments") orelse "{}";
                const input = std.json.parseFromSliceLeaky(Value, arena, args_s, .{}) catch Value{ .object = .empty };
                try msg.toolUses.append(arena, .{ .tool_use_id = cid, .tool = name, .input_json = input });
            };
        }
        try out.append(arena, msg);
    }
    // Attach outputs to the message holding their call; orphan outputs ride
    // the nearest following assistant message, else a trailing user message.
    for (pending_outputs.items) |r| {
        var attached = false;
        for (out.items) |*msg| {
            for (msg.toolUses.items) |u| {
                if (std.mem.eql(u8, u.tool_use_id, r.tool_use_id)) {
                    msg.toolResults.append(arena, r) catch continue;
                    attached = true;
                    break;
                }
            }
            if (attached) break;
        }
        if (!attached) {
            for (out.items) |*msg| {
                if (std.mem.eql(u8, msg.role, "assistant")) {
                    msg.toolResults.append(arena, r) catch continue;
                    attached = true;
                    break;
                }
            }
        }
        if (!attached) {
            var msg = GwMessage{ .role = "user", .text = "", .toolUses = .empty, .toolResults = .empty };
            msg.toolResults.append(arena, r) catch continue;
            out.append(arena, msg) catch continue;
        }
    }
}

/// Serialize the translated messages as the /v1/compact `messages` array.
pub fn writeMessages(s: *std.json.Stringify, messages: []const GwMessage) !void {
    try s.beginArray();
    for (messages) |m| {
        try s.beginObject();
        try s.objectField("role");
        try s.write(m.role);
        try s.objectField("text");
        try s.write(m.text);
        try s.objectField("toolUses");
        try s.beginArray();
        for (m.toolUses.items) |u| {
            try s.beginObject();
            try s.objectField("tool_use_id");
            try s.write(u.tool_use_id);
            try s.objectField("tool");
            try s.write(u.tool);
            try s.objectField("input");
            try s.write(u.input_json);
            try s.endObject();
        }
        try s.endArray();
        if (m.toolResults.items.len > 0) {
            try s.objectField("toolResults");
            try s.beginArray();
            for (m.toolResults.items) |r| {
                try s.beginObject();
                try s.objectField("tool_use_id");
                try s.write(r.tool_use_id);
                try s.objectField("text");
                try s.write(r.text);
                try s.endObject();
            }
            try s.endArray();
        }
        try s.endObject();
    }
    try s.endArray();
}

/// Build the POST /v1/compact body: model + translated messages. Hybrid mode
/// is left off — the gateway default (prune) is the arm under trial; the
/// summary leg would reintroduce the summarizer this replaces.
pub fn compactBody(arena: Allocator, messages: []const GwMessage) ![]u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    errdefer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("model");
    try s.write("clef-flash");
    try s.objectField("messages");
    try writeMessages(&s, messages);
    try s.endObject();
    return aw.toOwnedSlice();
}

pub const Decision = struct {
    tool_use_id: []const u8,
    action: []const u8, // "keep" | "drop_result" | "drop_call"
};

/// Parse the gateway response's decisions array. Unknown actions are kept
/// (safety-first, mirroring the gateway's own drop bar): only explicit
/// drop_result/drop_call prune.
pub fn parseDecisions(arena: Allocator, response: []const u8) ![]Decision {
    const parsed = try std.json.parseFromSliceLeaky(Value, arena, response, .{ .allocate = .alloc_always });
    if (parsed != .object) return error.InvalidCompactionResponse;
    const arr = parsed.object.get("decisions") orelse return error.InvalidCompactionResponse;
    if (arr != .array) return error.InvalidCompactionResponse;
    var out: std.ArrayList(Decision) = .empty;
    for (arr.array.items) |d| {
        if (d != .object) continue;
        const id = strField(d.object, "tool_use_id") orelse continue;
        const action = strField(d.object, "action") orelse "keep";
        try out.append(arena, .{ .tool_use_id = id, .action = action });
    }
    return out.toOwnedSlice(arena);
}

fn isListed(ids: []const []const u8, id: []const u8) bool {
    if (id.len == 0) return false;
    for (ids) |known| if (std.mem.eql(u8, known, id)) return true;
    return false;
}

/// Truncate a tool output value in place, keeping valid call/output pairing
/// (the message stays, only its bytes shrink). Mirrors the gateway's own
/// `…[truncated: kept first N of M chars]` marker.
fn truncateOutputValue(alloc: Allocator, m: *Value, field: []const u8, head_chars: usize) usize {
    if (m.* != .object) return 0;
    const obj = &m.object;
    const o = obj.get(field) orelse return 0;
    if (o != .string or o.string.len <= head_chars) return 0;
    const head = o.string[0..head_chars];
    const note = std.fmt.allocPrint(alloc, "{s}…[truncated: kept first {d} of {d} chars]", .{ head, head_chars, o.string.len }) catch return 0;
    if (note.len >= o.string.len) return 0;
    const freed = o.string.len - note.len;
    obj.put(alloc, field, .{ .string = note }) catch return 0;
    return freed;
}

/// What applyDecisions changed: messages removed outright, and outputs
/// shrunk to a stub (truncated, or archived in GRAFF_CLEF_ARCHIVE mode).
pub const Applied = struct {
    removed: usize = 0,
    shrunk: usize = 0,
    bytes_freed: usize = 0,

    pub fn progressed(self: Applied) bool {
        return self.removed > 0 or self.bytes_freed > 0;
    }

    fn shrink(self: *Applied, agent: *Agent, m: *Value, field: []const u8, head_chars: usize, session: []const u8, archiving: bool) void {
        const alloc = agent.messageMutationAlloc();
        const freed = if (archiving)
            archive.stubOutput(alloc, m, field, head_chars, session)
        else
            truncateOutputValue(alloc, m, field, head_chars);
        if (freed == 0) return;
        self.shrunk += 1;
        self.bytes_freed += freed;
    }
};

/// Apply gateway decisions to the live wire history in place. drop_call
/// removes the call AND its paired output; drop_result truncates the output
/// to `head_chars`. Pairing is by call_id/tool_use_id on both wire formats.
/// Returns what changed (removed messages, shrunk outputs, bytes freed).
///
/// Archive mode (GRAFF_CLEF_ARCHIVE=1): every drop_call is applied as a
/// drop_result, and each shrunk output's full bytes are archived to the
/// session's artifact dir with the path in the stub — nothing leaves history
/// unrecoverably, and pairing never changes.
///
/// Atomicity rule (chat wire): an assistant message's tool_calls[] is an
/// all-or-nothing unit for the gateway. Dropping only SOME calls out of one
/// message orphans the surviving results (a role:tool result whose call is
/// gone is a 400 on the next send — the wave-1 clef1 wedge). So a
/// drop_call fires only when EVERY call id in that message is listed; a
/// partial listing degrades to drop_result truncation on the listed outputs.
/// Responses items are already one-call-per-item, so they drop singly.
pub fn applyDecisions(self: *Agent, decisions: []const Decision, head_chars: usize) Applied {
    var drop_calls: std.ArrayList([]const u8) = .empty;
    var drop_results: std.ArrayList([]const u8) = .empty;
    const archiving = archive.g_enabled;
    for (decisions) |d| {
        const is_call = std.mem.eql(u8, d.action, "drop_call");
        if (is_call) drop_calls.append(self.gpa, d.tool_use_id) catch continue;
        // Archive mode: a drop_call is also a drop_result, which the rule
        // below already turns into "keep the call, stub the output".
        if (std.mem.eql(u8, d.action, "drop_result") or (is_call and archiving))
            drop_results.append(self.gpa, d.tool_use_id) catch continue;
    }
    defer drop_calls.deinit(self.gpa);
    defer drop_results.deinit(self.gpa);
    var applied: Applied = .{};
    if (drop_calls.items.len == 0 and drop_results.items.len == 0) return applied;
    const session = if (archiving) @import("tool_spill.zig").sessionFor(self.sub, self.session_name) else "";

    // Degrade partial chat-wire drop_calls to drop_results BEFORE mutating:
    // collect every call id that shares an assistant message with an
    // unlisted sibling; those ids truncate instead of dropping. An explicit
    // gateway drop_result on the same id degrades identically.
    for (self.messages.items) |m| {
        if (m != .object) continue;
        if (strField(m.object, "role")) |role| {
            if (!std.mem.eql(u8, role, "assistant")) continue;
            const tc = m.object.get("tool_calls") orelse continue;
            if (tc != .array or tc.array.items.len < 2) continue;
            var all_listed = true;
            var any_listed = false;
            for (tc.array.items) |call| {
                if (call != .object) continue;
                const cid = strField(call.object, "id") orelse continue;
                if (isListed(drop_calls.items, cid)) {
                    any_listed = true;
                } else {
                    all_listed = false;
                }
            }
            if (any_listed and !all_listed) {
                for (tc.array.items) |call| {
                    if (call != .object) continue;
                    const cid = strField(call.object, "id") orelse continue;
                    if (!isListed(drop_calls.items, cid)) continue;
                    var already = false;
                    for (drop_results.items) |r| if (std.mem.eql(u8, r, cid)) {
                        already = true;
                        break;
                    };
                    if (!already) drop_results.append(self.gpa, cid) catch continue;
                }
            }
        }
    }
    // A drop_call that is also a drop_result (degraded partial above, or an
    // explicit gateway drop_result on the same id) truncates; only a
    // drop_call with NO drop_result on the same id removes its messages.
    var w: usize = 0;
    for (self.messages.items) |*m| {
        if (m.* != .object) {
            self.messages.items[w] = m.*;
            w += 1;
            continue;
        }
        const obj = &m.object;
        // Responses function_call / function_call_output.
        if (strField(obj.*, "type")) |t| {
            if (std.mem.eql(u8, t, "function_call")) {
                const cid = strField(obj.*, "call_id") orelse "";
                if (isListed(drop_calls.items, cid) and !isListed(drop_results.items, cid)) {
                    applied.removed += 1;
                    continue;
                }
            }
            if (std.mem.eql(u8, t, "function_call_output")) {
                const cid = strField(obj.*, "call_id") orelse "";
                if (isListed(drop_calls.items, cid) and !isListed(drop_results.items, cid)) {
                    applied.removed += 1;
                    continue;
                }
                if (isListed(drop_results.items, cid)) applied.shrink(self, m, "output", head_chars, session, archiving);
            }
            self.messages.items[w] = m.*;
            w += 1;
            continue;
        }
        // Chat assistant tool_calls[] + role:tool results. The pre-pass
        // above already degraded every partial listing, so reaching this
        // point with a listed id means the whole message is listed: drop it
        // and its results together, keeping pairing valid.
        if (strField(obj.*, "role")) |role| {
            if (std.mem.eql(u8, role, "assistant")) {
                if (obj.get("tool_calls")) |tc| {
                    if (tc == .array) {
                        var drop_whole = false;
                        for (tc.array.items) |call| {
                            if (call != .object) continue;
                            const cid = strField(call.object, "id") orelse continue;
                            if (isListed(drop_calls.items, cid) and !isListed(drop_results.items, cid)) {
                                drop_whole = true;
                                applied.removed += 1;
                                break;
                            }
                        }
                        if (drop_whole) continue;
                    }
                }
            }
            if (std.mem.eql(u8, role, "tool")) {
                const cid = strField(obj.*, "tool_call_id") orelse "";
                if (isListed(drop_calls.items, cid) and !isListed(drop_results.items, cid)) {
                    applied.removed += 1;
                    continue;
                }
                if (isListed(drop_results.items, cid)) applied.shrink(self, m, "content", head_chars, session, archiving);
            }
        }
        self.messages.items[w] = m.*;
        w += 1;
    }
    self.messages.shrinkRetainingCapacity(w);
    if (applied.progressed() and self.message_mutation_arena == null) self.reclaimMessages();
    return applied;
}

/// Single call-site for compact(): eligible sessions try the gateway first
/// (returns the new history length on a prune); anything else is null and
/// the caller falls through to the client summary. Keeps agent_compact.zig
/// under the 600-line ceiling.
/// POST the translated history to the gateway and apply the returned
/// decisions. True when history was pruned; ANY failure returns false with
/// history untouched, so the caller falls back to the client summary.
pub fn tryCompact(self: *Agent) ?usize {
    if (!eligible(self)) return null;
    if (!compactViaGateway(self)) return null;
    return self.messages.items.len;
}

pub fn compactViaGateway(self: *Agent) bool {
    if (!eligible(self)) return false;
    if (self.messages.items.len == 0) return false;
    var arena_state = std.heap.ArenaAllocator.init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const url = compactUrl(arena, self.provider.url) orelse return false;

    var translated: std.ArrayList(GwMessage) = .empty;
    translateHistory(arena, self.messages.items, &translated) catch return false;
    if (translated.items.len == 0) return false;
    const body = compactBody(arena, translated.items) catch return false;

    var gw = self.provider;
    gw.url = url;
    var conv_buf: [96]u8 = undefined;
    const conv = @import("http_headers.zig").requestCacheKey(self.io, self.label, self, self.provider, &conv_buf);
    const resp = http.postWatched(self.gpa, self.io, self.client, gw, body, conv) catch |err| {
        if (self.tracer) |tr| tr.note("clef_compact_failed", @errorName(err));
        return false;
    };
    defer self.gpa.free(resp);
    const decisions = parseDecisions(arena, resp) catch {
        if (self.tracer) |tr| tr.note("clef_compact_failed", resp[0..@min(resp.len, 200)]);
        return false;
    };
    const applied = applyDecisions(self, decisions, 300);
    if (!applied.progressed()) {
        // Nothing pruned: not a failure, but not progress either. Report it
        // so the caller can decide (the client summary may still shrink text).
        if (self.tracer) |tr| tr.note("clef_compact_noop", "");
        return false;
    }
    self.last_context_tokens = 0;
    self.context_local_tokens = 0;
    self.goal_note_fp = 0;
    self.history_rewrites +%= 1;
    if (self.pending_goal_note == null)
        self.pending_goal_note = @import("goal_flow.zig").compactionSnapshot(self.arena, self) catch null;
    if (self.tracer) |tr| {
        var nb: [96]u8 = undefined;
        tr.note("clef_compact_applied", std.fmt.bufPrint(&nb, "removed={d} shrunk={d} bytes_freed={d} archive={}", .{ applied.removed, applied.shrunk, applied.bytes_freed, archive.g_enabled }) catch "");
    }
    if (!main_mod.json_mode) {
        if (archive.g_enabled)
            self.say("[gateway compacted context: {d} tool output(s) archived by clef, {d} bytes freed]\n", .{ applied.shrunk, applied.bytes_freed }) catch {}
        else
            self.say("[gateway compacted context: {d} tool message(s) pruned by clef]\n", .{applied.removed}) catch {};
    }
    return true;
}

// Tests live in agent_clef_compact_tests.zig (the 600-line ceiling).
