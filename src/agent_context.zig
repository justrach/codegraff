//! Context-window estimation, usage accounting, and cost metering.

const std = @import("std");
const util = @import("util.zig");
const Value = std.json.Value;

const Agent = @import("agent.zig").Agent;
const context_tokens = @import("context_tokens.zig");
const messages_mod = @import("messages.zig");
const pricing = @import("pricing.zig");
const billing = @import("billing.zig");
const g_cost = &pricing.g_cost;

test "recordUsage (#202): floors the meter from the local estimate when usage is absent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var msgs = std.json.Array.init(a);
    var m: std.json.ObjectMap = .empty;
    try m.put(a, "role", .{ .string = "user" });
    try m.put(a, "content", .{ .string = "the quick brown fox jumps over the lazy dog" });
    try msgs.append(.{ .object = m });

    var agent: Agent = undefined;
    agent.io = std.testing.io;
    agent.arena = a;
    agent.messages = msgs;
    agent.last_context_tokens = 0;
    agent.context_local_tokens = 0;
    agent.provider = .{ .id = "anthropic", .kind = .anthropic, .auth = .x_api_key, .url = "", .api_key = "", .model = "claude", .context = 100_000 };
    agent.sub = false;
    agent.strict = false;
    agent.sys_normal = "";
    agent.sys_strict = "";
    agent.tools_anthropic = "";

    // a response body with NO usage object previously froze the meter at its stale
    // value; now it floors to max(full-input estimate, req_body_len/4) so the
    // between-turns compaction gate can still fire.
    const root: std.json.ObjectMap = .empty;
    recordUsage(&agent, root, 4000);

    try std.testing.expect(agent.last_context_tokens > 0);
    const expected = @max(fullRequestEstimateTokens(&agent), @as(u64, 1000)); // 4000/4
    try std.testing.expectEqual(expected, agent.last_context_tokens);

    // A fresh full-history response can authoritatively correct a stale high
    // meter after an explicit history mutation.
    agent.last_context_tokens = 9_000;
    var usage: std.json.ObjectMap = .empty;
    try usage.put(a, "input_tokens", .{ .integer = 10 });
    try usage.put(a, "output_tokens", .{ .integer = 5 });
    var response: std.json.ObjectMap = .empty;
    try response.put(a, "usage", .{ .object = usage });
    recordUsage(&agent, response, 400);
    try std.testing.expectEqual(@max(fullRequestEstimateTokens(&agent), @as(u64, 15)), agent.last_context_tokens);

    // A malformed smaller total must not override stronger component evidence.
    try usage.put(a, "prompt_tokens", .{ .integer = 220_000 });
    try usage.put(a, "completion_tokens", .{ .integer = 1_000 });
    try usage.put(a, "total_tokens", .{ .integer = 100 });
    try response.put(a, "usage", .{ .object = usage });
    agent.provider.kind = .openai;
    agent.tools_openai = "";
    recordUsage(&agent, response, 400);
    try std.testing.expectEqual(@as(u64, 221_000), agent.last_context_tokens);
}

test "fullInputEstimateTokens (#174): counts retained reasoning the chained usage never reports" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    var agent: Agent = undefined;
    agent.messages = msgs;
    try std.testing.expectEqual(@as(u64, 0), fullInputEstimateTokens(&agent) / 100); // empty history ≈ nothing
    // a fat encrypted-reasoning item — exactly what a WS-chained total_tokens excludes
    const blob = "{\"type\":\"reasoning\",\"encrypted_content\":\"" ++ util.repeatBytes("A", 8192) ++ "\"}";
    try msgs.append(try std.json.parseFromSliceLeaky(Value, a, blob, .{}));
    agent.messages = msgs;
    const est = fullInputEstimateTokens(&agent);
    try std.testing.expect(est > 2000); // ~8KB serialized / 4 bytes-per-token
}

test "context estimate reuses an already-serialized history byte count" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var messages = std.json.Array.init(a);
    try messages.append(try messages_mod.textMessage(a, "user", "measure this once"));

    var agent: Agent = undefined;
    agent.messages = messages;
    agent.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 100_000 };
    agent.sub = false;
    agent.strict = false;
    agent.sys_normal = "system";
    agent.sys_strict = "strict";
    agent.tools_responses = "[]";
    agent.last_context_tokens = 12_000;
    agent.context_local_tokens = 8_000;

    const input_bytes = context_tokens.serializedLen(Value{ .array = messages });
    const estimate = contextEstimateFromInputBytes(&agent, input_bytes);
    try std.testing.expectEqual(fullRequestEstimateTokens(&agent), estimate.local);
    try std.testing.expectEqual(estimate.local + 4_000, estimate.effective);
}

pub fn recordUsage(self: *Agent, root: std.json.ObjectMap, req_body_len: usize) void {
    self.last_cache_read = 0;
    self.last_usage_includes_output = false;
    // #202/#260: keep the context meter live when the provider omits usage.
    // Estimate the serialized body while replacing inline image transport bytes
    // with bounded vision tokens, then floor it at the full-input estimate.
    const fallback = requestBodyEstimateTokens(self, req_body_len);
    const usage = root.get("usage") orelse return floorContextTokens(self, fallback);
    if (usage != .object) return floorContextTokens(self, fallback);
    const u = usage.object;
    switch (self.provider.kind) {
        .anthropic => {
            var total: i64 = 0;
            const fields = [_][]const u8{
                "input_tokens",            "output_tokens",
                "cache_read_input_tokens", "cache_creation_input_tokens",
            };
            for (fields) |f| total +|= usageInt(u, f);
            if (total > 0)
                replaceContextTokens(self, @intCast(total))
            else
                floorContextTokens(self, fallback);
            self.last_usage_includes_output = total > 0 and if (u.get("output_tokens")) |v| v == .integer and v.integer >= 0 else false;
            const cache = usageInt(u, "cache_read_input_tokens");
            if (cache > 0) self.last_cache_read = @intCast(cache);
            // cache writes bill ~like input; fold them into uncached input.
            self.recordCost(usageInt(u, "input_tokens") +| usageInt(u, "cache_creation_input_tokens"), cache, usageInt(u, "output_tokens"));
        },
        .openai => {
            const total = usageInt(u, "total_tokens");
            const computed_total = usageInt(u, "prompt_tokens") +| usageInt(u, "completion_tokens");
            const reported_total = @max(total, computed_total);
            if (reported_total > 0)
                replaceContextTokens(self, @intCast(reported_total))
            else
                floorContextTokens(self, fallback);
            self.last_usage_includes_output = reported_total > 0 and
                (total > 0 or if (u.get("completion_tokens")) |v| v == .integer and v.integer >= 0 else false);
            // deepseek reports prompt_cache_hit_tokens; the OpenAI shape
            // nests cached_tokens under prompt_tokens_details.
            var cache = usageInt(u, "prompt_cache_hit_tokens");
            if (cache == 0) if (u.get("prompt_tokens_details")) |d| if (d == .object) {
                cache = usageInt(d.object, "cached_tokens");
            };
            if (cache > 0) self.last_cache_read = @intCast(cache);
            self.recordCost(@max(usageInt(u, "prompt_tokens") - cache, 0), cache, usageInt(u, "completion_tokens"));
        },
        // codex uses recordUsageResponses on its own path.
        .responses => {},
    }
}

/// #202: floor the context meter at the local estimate (full-input byte/4, or the
/// request-body byte/4 when the history isn't serialized yet) when the API omits
/// usage, so auto-compaction still triggers. Never lowers an existing higher count.
fn floorContextTokens(self: *Agent, est: u64) void {
    const estimate = self.contextEstimate();
    self.last_context_tokens = @max(estimate.effective, @max(estimate.local, est));
    self.context_local_tokens = estimate.local;
}

/// A full-history request's nonzero provider usage is authoritative enough to
/// correct a stale high meter after an explicit trim/provider mutation. Still
/// retain the complete local request estimate as a structural lower bound.
fn replaceContextTokens(self: *Agent, reported: u64) void {
    const local = self.fullRequestEstimateTokens();
    self.last_context_tokens = @max(local, reported);
    self.context_local_tokens = local;
}

/// An integer usage field, or 0 if absent / wrong type.
pub fn usageInt(obj: std.json.ObjectMap, name: []const u8) i64 {
    if (obj.get(name)) |v| if (v == .integer and v.integer > 0) return v.integer;
    return 0;
}

/// Record one request's usage into the session-wide tally (g_cost):
/// token counts always; USD only for metered seats with a price_table row.
/// #471: the seat is classified from the provider AND how its credential was
/// obtained — a flat-rate login (codex/kimi/xai) tallies as sub_calls and adds
/// $0, while an env key on that same provider is metered like any other.
pub fn recordCost(self: *Agent, uncached_in: i64, cache_in: i64, out: i64) void {
    g_cost.add(self.io, billing.forProvider(self.provider), self.provider.model, uncached_in, cache_in, out);
}

/// #174: ~4-bytes/token estimate of the FULL history serialized as Responses
/// `input` items — the cost of the next full-history resend (runTurn closes
/// the WS per turn, so every turn's first request replays everything). The
/// chained WS usage can sit far below this: with previous_response_id the
/// server discards prior-turn reasoning from context, while a resend pays for
/// every retained encrypted reasoning item again. Counting discard writer —
/// no allocation.
pub fn fullInputEstimateTokens(self: *Agent) u64 {
    return context_tokens.estimatedTokens(Value{ .array = self.messages });
}

/// Estimate the complete fixed+history input sent by a normal model request.
/// fullInputEstimateTokens intentionally covers messages only; the pre-send gate
/// must additionally count the mutable system prompt and active tool schema. Keep
/// the old 8k conservative baseline when those serialize smaller, but never let it
/// hide an unbounded set_system_prompt/set_agent payload.
fn requestEstimateFromInputBytes(self: *Agent, input_bytes: usize) u64 {
    const input_tokens = context_tokens.estimatedTokensFromLen(Value{ .array = self.messages }, input_bytes);
    const fixed_bytes = context_tokens.serializedLen(self.systemPrompt()) +| self.toolsJson().len;
    const measured = input_tokens +| @as(u64, @intCast(fixed_bytes / 4));
    const baseline = @min(@as(u64, 8000), self.provider.context / 8);
    return @max(measured, input_tokens +| baseline);
}

pub fn fullRequestEstimateTokens(self: *Agent) u64 {
    return requestEstimateFromInputBytes(self, context_tokens.serializedLen(Value{ .array = self.messages }));
}

fn requestBodyEstimateTokens(self: *Agent, body_bytes: usize) u64 {
    return context_tokens.estimatedTokensFromLen(Value{ .array = self.messages }, body_bytes);
}

pub const ContextEstimate = struct {
    local: u64,
    effective: u64,
};

/// Compute the locally measurable request size and the hidden-token-adjusted
/// occupancy in one history serialization. Callers that need both previously
/// walked the entire JSON history twice.
pub fn contextEstimate(self: *Agent) ContextEstimate {
    return self.contextEstimateFromInputBytes(context_tokens.serializedLen(Value{ .array = self.messages }));
}

/// Variant for callers already serializing the history (session persistence).
/// Reusing the observed byte count avoids a redundant full JSON walk.
pub fn contextEstimateFromInputBytes(self: *Agent, input_bytes: usize) ContextEstimate {
    const local = requestEstimateFromInputBytes(self, input_bytes);
    return .{
        .local = local,
        .effective = local +| (self.last_context_tokens -| self.context_local_tokens),
    };
}

/// Current context occupancy: today's locally measurable request plus the
/// server-only delta paired with the last usage sample. This automatically
/// counts user/tool content appended after that sample without double-counting
/// provider output once step* advances the local anchor.
pub fn effectiveContextTokens(self: *Agent) u64 {
    return self.contextEstimate().effective;
}

/// Pair a fresh provider usage sample with history after its response items
/// have been appended. Those items are already represented in total_tokens;
/// advancing only the local anchor prevents counting them twice.
pub fn pairContextMeterWithCurrentLocal(self: *Agent) void {
    if (!self.last_usage_includes_output) return;
    const local = self.fullRequestEstimateTokens();
    self.last_context_tokens = @max(self.last_context_tokens, local);
    self.context_local_tokens = local;
    self.last_usage_includes_output = false;
}

/// Materialize local input mutations while retaining the server-only delta.
pub fn rebaseContextMeter(self: *Agent) void {
    const estimate = self.contextEstimate();
    self.last_context_tokens = estimate.effective;
    self.context_local_tokens = estimate.local;
    self.last_cache_read = 0;
}

test "rebaseContextMeter preserves hidden context while replacing local input" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = undefined;
    agent.messages = std.json.Array.init(a);
    agent.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 100_000 };
    agent.sub = false;
    agent.strict = false;
    agent.sys_normal = &util.repeatBytes("x", 40_000);
    agent.sys_strict = "";
    agent.tools_responses = "";
    agent.last_cache_read = 99;
    const old_local = agent.fullRequestEstimateTokens();
    agent.last_context_tokens = old_local + 12_345;
    agent.context_local_tokens = old_local;

    agent.sys_normal = "short";
    rebaseContextMeter(&agent);
    try std.testing.expectEqual(agent.fullRequestEstimateTokens() + 12_345, agent.last_context_tokens);
    try std.testing.expectEqual(@as(u64, 0), agent.last_cache_read);
}

test "context anchor counts unsampled growth and pairs provider-covered output" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = undefined;
    agent.messages = std.json.Array.init(a);
    agent.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 100_000 };
    agent.sub = false;
    agent.strict = false;
    agent.sys_normal = "";
    agent.sys_strict = "";
    agent.tools_responses = "";
    const base_local = agent.fullRequestEstimateTokens();
    agent.last_context_tokens = 50_000;
    agent.context_local_tokens = base_local;
    agent.last_usage_includes_output = false;

    try agent.messages.append(try messages_mod.textMessage(a, "assistant", &util.repeatBytes("x", 4000)));
    agent.pairContextMeterWithCurrentLocal();
    try std.testing.expect(agent.effectiveContextTokens() > 50_000);
    try std.testing.expectEqual(base_local, agent.context_local_tokens);

    agent.last_context_tokens = 60_000;
    agent.last_usage_includes_output = true;
    agent.pairContextMeterWithCurrentLocal();
    try std.testing.expectEqual(agent.fullRequestEstimateTokens(), agent.context_local_tokens);
    try std.testing.expectEqual(@max(@as(u64, 60_000), agent.fullRequestEstimateTokens()), agent.effectiveContextTokens());
}

/// Pre-send overflow gate (#193). `last_context_tokens` only updates from the
/// server's returned usage, so it lags tool output appended *within* a turn: a
/// burst of large tool results can push this turn's input past the model's wall
/// before the between-turns 80% meter ever sees it (the "input exceeds the
/// context window" rejection on codex/gpt-5.x). Estimating the full input
/// locally before each request lets the turn loop compact first — the analogue
/// of codex's run_pre_sampling_compact / opencode's isOverflow-before-each-turn.
/// Guarded on a known window (compactAt()==0 → don't compact blindly).
pub fn inputOverCompactThreshold(self: *Agent) bool {
    const threshold = self.provider.compactAt();
    if (threshold == 0) return false;
    // The server-reported meter (the same last_context_tokens the between-turns
    // gates at mainloop.zig:683/734 already trust) is refreshed mid-turn by
    // recordUsageResponses (agent_request.zig:905/924). On codex/.responses it can
    // sit far above the local byte/4 estimate — retained encrypted-reasoning items
    // are billed server-side but the local serialize under-counts them — so on a
    // long turn it held ~511k while fullInputEstimateTokens stayed under the wall
    // and the next resend was rejected for "input exceeds the context window"
    // before any compaction ran. Trip a pre-send compact on the accurate meter too.
    return self.effectiveContextTokens() >= threshold;
}

test "inputOverCompactThreshold (#193): local estimate gates a pre-send compact" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    var agent: Agent = undefined;
    agent.messages = msgs;
    agent.last_context_tokens = 0; // the gate now reads this too; `= undefined` won't apply the field default
    agent.context_local_tokens = 0;
    agent.sub = false;
    agent.strict = false;
    agent.sys_normal = "";
    agent.sys_strict = "";
    agent.tools_responses = "";
    // small window: compactAt() = 10_000/10*8 = 8_000 tokens ≈ 32_000 serialized bytes
    agent.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 10_000 };
    try std.testing.expect(!inputOverCompactThreshold(&agent)); // empty history → under
    // one fat tool output (~40KB serialized ≈ 10k est tokens) crosses 8k in a single append
    const big = "{\"type\":\"function_call_output\",\"output\":\"" ++ util.repeatBytes("x", 40000) ++ "\"}";
    try msgs.append(try std.json.parseFromSliceLeaky(Value, a, big, .{}));
    agent.messages = msgs;
    try std.testing.expect(inputOverCompactThreshold(&agent)); // burst → over → compact before send
    // the server-reported meter alone trips the gate even with an empty local history —
    // the codex mid-turn case where retained reasoning items undercount the byte/4 estimate
    agent.messages = std.json.Array.init(a);
    agent.last_context_tokens = agent.provider.compactAt();
    agent.context_local_tokens = agent.fullRequestEstimateTokens();
    try std.testing.expect(inputOverCompactThreshold(&agent));
    agent.last_context_tokens = 0;
    agent.context_local_tokens = 0;
    // Mutable system prompts are real input, not a fixed 8k prefill. A large
    // prompt must trip the gate even with no message history.
    agent.sys_normal = &util.repeatBytes("x", 40_000);
    try std.testing.expect(inputOverCompactThreshold(&agent));
    agent.sys_normal = "";
    // #192: the reported overflow was a PARALLEL tool batch, not one fat result.
    // Each function_call_output below sits far under compactAt() on its own; only
    // the six together cross it, and the continuation request carrying the whole
    // batch is the one the backend rejected. The gate has to weigh the history it
    // is about to send, not the item it just appended.
    const parallel = "{\"type\":\"function_call_output\",\"output\":\"" ++ util.repeatBytes("x", 5000) ++ "\"}";
    const one_result = try std.json.parseFromSliceLeaky(Value, a, parallel, .{});
    for (0..6) |_| {
        try std.testing.expect(!inputOverCompactThreshold(&agent)); // no prefix of the batch trips it
        try agent.messages.append(one_result);
    }
    try std.testing.expect(inputOverCompactThreshold(&agent)); // jointly over → compact before the continuation
    // unknown window (context 0) never gates, even on this over-threshold history
    agent.provider.context = 0;
    try std.testing.expect(!inputOverCompactThreshold(&agent));
}

test "inputOverCompactThreshold (#260): a fresh Base64 image is vision context, not text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const payload = try a.alloc(u8, 1_600_000);
    @memset(payload, 'A');
    const uri = try std.fmt.allocPrint(a, "data:image/png;base64,{s}", .{payload});
    var image_url: std.json.ObjectMap = .empty;
    try image_url.put(a, "url", .{ .string = uri });
    var image: std.json.ObjectMap = .empty;
    try image.put(a, "type", .{ .string = "image_url" });
    try image.put(a, "image_url", .{ .object = image_url });
    var content = std.json.Array.init(a);
    try content.append(.{ .object = image });
    var user: std.json.ObjectMap = .empty;
    try user.put(a, "role", .{ .string = "user" });
    try user.put(a, "content", .{ .array = content });
    var messages = std.json.Array.init(a);
    try messages.append(.{ .object = user });

    var agent: Agent = undefined;
    agent.messages = messages;
    agent.last_context_tokens = 0;
    agent.context_local_tokens = 0;
    agent.sub = false;
    agent.strict = false;
    agent.sys_normal = "";
    agent.sys_strict = "";
    agent.tools_openai = "";
    agent.provider = .{ .id = "codegraff", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "kimi-k2.6", .context = 262_000 };

    const raw_tokens: u64 = @intCast(context_tokens.serializedLen(Value{ .array = messages }) / 4);
    try std.testing.expect(raw_tokens > agent.provider.compactAt());
    try std.testing.expect(fullInputEstimateTokens(&agent) < 5_000);
    try std.testing.expect(!inputOverCompactThreshold(&agent));
}

pub fn recordUsageResponses(self: *Agent, response: std.json.ObjectMap, req_body_len: usize) void {
    self.last_cache_read = 0;
    self.last_usage_includes_output = false;
    // Fallback estimate from the serialized request body, with inline Base64
    // images charged as bounded vision tokens rather than text. This keeps the
    // context meter live when Codex omits usage without compacting fresh images.
    const est = requestBodyEstimateTokens(self, req_body_len);
    // A held Codex WS sends only previous_response_id + the unsent delta, so
    // body/4 can be tiny even when the preceding response reported a near-full
    // context. Missing or malformed usage is not evidence that the context got
    // smaller: preserve the authoritative meter and floor it with every local
    // estimate, just like recordUsage does for the other provider shapes.
    const usage = response.get("usage") orelse return floorContextTokens(self, est);
    if (usage != .object) return floorContextTokens(self, est);
    const u = usage.object;
    const in_tokens = usageInt(u, "input_tokens");
    const out_tokens = usageInt(u, "output_tokens");
    const raw_total_tokens = usageInt(u, "total_tokens");
    const total_tokens = @max(raw_total_tokens, in_tokens +| out_tokens);
    if (total_tokens > 0) {
        if (self.codex_prev_id != null)
            floorContextTokens(self, @intCast(total_tokens))
        else
            replaceContextTokens(self, @intCast(total_tokens));
    } else floorContextTokens(self, est);
    const usage_covers_output = total_tokens > 0 and
        (raw_total_tokens > 0 or if (u.get("output_tokens")) |v| v == .integer and v.integer >= 0 else false);
    // Chained WS totals are not comparable to the conservative full-resend
    // meter, so they cannot prove how much of the appended response growth is
    // covered. Never advance that anchor; conservative double-counting is
    // corrected by the next full re-anchor and cannot miss compaction.
    self.last_usage_includes_output = usage_covers_output and self.codex_prev_id == null;
    // #174: the server's chained number undercounts what the next full-history
    // resend will cost, and the resend is the request that gets rejected — so
    // the meter must never sit below the local full-input estimate. Same
    // correction codex CLI applies (get_non_last_reasoning_items_tokens).
    // Without it a long Extra-high session reads "95k/270k" right up until the
    // backend rejects the resend for exceeding the window, and auto-compaction
    // (gated on this meter) never rescues it.
    var cached: i64 = 0;
    if (u.get("input_tokens_details")) |d| if (d == .object) {
        cached = usageInt(d.object, "cached_tokens");
        if (cached > 0) self.last_cache_read = @intCast(cached);
    };
    self.recordCost(@max(in_tokens - cached, 0), cached, out_tokens);
}

test "recordUsageResponses: usage fallbacks never lower an authoritative meter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var agent: Agent = undefined;
    agent.io = std.testing.io;
    agent.messages = std.json.Array.init(a);
    agent.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 10_000 };
    agent.last_cache_read = 0;
    agent.last_context_tokens = 9_000; // above compactAt(), while the WS delta below is tiny
    agent.codex_prev_id = null;
    agent.sub = false;
    agent.strict = false;
    agent.sys_normal = "";
    agent.sys_strict = "";
    agent.tools_responses = "";
    agent.context_local_tokens = agent.fullRequestEstimateTokens();

    const missing: std.json.ObjectMap = .empty;
    recordUsageResponses(&agent, missing, 400);
    try std.testing.expectEqual(@as(u64, 9_000), agent.last_context_tokens);
    try std.testing.expect(!agent.last_usage_includes_output);
    try std.testing.expect(inputOverCompactThreshold(&agent));

    var malformed: std.json.ObjectMap = .empty;
    try malformed.put(a, "usage", .{ .string = "unknown" });
    recordUsageResponses(&agent, malformed, 400);
    try std.testing.expectEqual(@as(u64, 9_000), agent.last_context_tokens);

    const empty_usage: std.json.ObjectMap = .empty;
    var empty_response: std.json.ObjectMap = .empty;
    try empty_response.put(a, "usage", .{ .object = empty_usage });
    recordUsageResponses(&agent, empty_response, 400);
    try std.testing.expectEqual(@as(u64, 9_000), agent.last_context_tokens);

    var smaller_usage: std.json.ObjectMap = .empty;
    try smaller_usage.put(a, "input_tokens", .{ .integer = 90 });
    try smaller_usage.put(a, "output_tokens", .{ .integer = 10 });
    try smaller_usage.put(a, "total_tokens", .{ .integer = 100 });
    var smaller_response: std.json.ObjectMap = .empty;
    try smaller_response.put(a, "usage", .{ .object = smaller_usage });
    // A full re-anchor trusts its provider reading (with the local floor).
    recordUsageResponses(&agent, smaller_response, 400);
    try std.testing.expectEqual(@max(fullRequestEstimateTokens(&agent), @as(u64, 100)), agent.last_context_tokens);
    try std.testing.expect(agent.last_usage_includes_output);

    // The aggregate is advisory when larger input/output components are
    // present; never lower the meter below the stronger provider evidence.
    try smaller_usage.put(a, "input_tokens", .{ .integer = 8_000 });
    try smaller_usage.put(a, "output_tokens", .{ .integer = 1_000 });
    try smaller_response.put(a, "usage", .{ .object = smaller_usage });
    agent.last_context_tokens = 0;
    recordUsageResponses(&agent, smaller_response, 400);
    try std.testing.expectEqual(@max(fullRequestEstimateTokens(&agent), @as(u64, 9_000)), agent.last_context_tokens);

    // A held WS delta cannot prove the full chained context shrank.
    agent.last_context_tokens = 9_000;
    agent.codex_prev_id = "resp_previous";
    recordUsageResponses(&agent, smaller_response, 400);
    try std.testing.expectEqual(@as(u64, 9_000), agent.last_context_tokens);
    try std.testing.expect(!agent.last_usage_includes_output);

    // A fresh meter still advances from the fallback estimate.
    agent.codex_prev_id = null;
    agent.last_context_tokens = 0;
    recordUsageResponses(&agent, missing, 4_000);
    try std.testing.expectEqual(@max(fullRequestEstimateTokens(&agent), @as(u64, 1_000)), agent.last_context_tokens);
}

// #326: systemPrompt() must gate the ultra variant on the SAME condition the
// persistent-steering call sites use (session_run.zig/mainloop.zig both call
// prompts.ultracodeActive(root)), and must COMPOSE it with strict rather than
// replace it. Attempt 1 broke both: (1) gated on ultracode_mode alone, so a
// bare /effort ultra session got sys_normal — never sys_ultra — and (2)
// returned sys_ultra before the strict check, so /strict + /ultracode
// together silently dropped strict. Distinct marker strings (not real prose)
// prove the dispatch logic itself, independent of setSystemPrompts' own tests.
test "systemPrompt (#326): all four {ultracode, strict} combos, plus /effort ultra without ultracode_mode" {
    var agent: Agent = undefined;
    agent.review_mode = false;
    agent.sub = false;
    agent.sys_override = null;
    agent.sys_normal = "NORMAL";
    agent.sys_strict = "STRICT";
    agent.sys_ultra = "ULTRA";
    agent.sys_ultra_strict = "ULTRA_STRICT";
    agent.strict = false;
    agent.ultracode_mode = false;
    agent.reasoning = .medium;

    try std.testing.expectEqualStrings("NORMAL", agent.systemPrompt()); // off, off
    agent.strict = true;
    try std.testing.expectEqualStrings("STRICT", agent.systemPrompt()); // off, strict
    agent.ultracode_mode = true;
    try std.testing.expectEqualStrings("ULTRA_STRICT", agent.systemPrompt()); // on, strict — composes, not replaces
    agent.strict = false;
    try std.testing.expectEqualStrings("ULTRA", agent.systemPrompt()); // on, off

    // /effort ultra sets reasoning == .ultra, NOT ultracode_mode — attempt 1's
    // regression 1 dropped the catalog entirely on this exact path.
    agent.ultracode_mode = false;
    agent.reasoning = .ultra;
    try std.testing.expectEqualStrings("ULTRA", agent.systemPrompt());
    agent.strict = true;
    try std.testing.expectEqualStrings("ULTRA_STRICT", agent.systemPrompt());
}
