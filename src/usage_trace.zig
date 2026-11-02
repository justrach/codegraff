//! One `usage` trace event per model response: the server's own token counts.
//!
//! The `api` event carries `context_tokens`, the context meter, which is the
//! larger of the server total and graff's local estimate of a full resend
//! (agent_context.zig). On a chained Codex request the server drops earlier
//! turns' reasoning while the local estimate still counts every retained
//! encrypted reasoning item, so `cache_read_tokens / context_tokens` is not a
//! cache hit rate. This event records what the server billed, split the same
//! way recordCost receives it, so trajectory analysis can compute
//! `cache_read_tokens / input_tokens` per request.
//!
//! recordCost only stashes the numbers (tests build partial agents whose
//! tracer is undefined); Tracer.api writes them right after its `api` line.
//! A request and its trace line run on the same thread, so the slot is
//! thread-local.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const cache_ttl = @import("cache_ttl.zig");
const hud = @import("prompt_cache_hud.zig");

const Usage = struct {
    provider: []const u8,
    input: i64,
    cache_read: i64,
    cache_write: i64,
    output: i64,
    chained: bool,
    /// #1320: why a read may have dropped. Time since this agent's previous
    /// request began, the TTL asked for (null: the provider default), whether
    /// the system+tools prefix changed and the named reason, and on a
    /// zero-read request with real input the likely cause.
    gap_ms: ?i64 = null,
    cache_ttl: ?[]const u8 = null,
    prefix_changed: bool = false,
    prefix_bust: ?[]const u8 = null,
    cache_miss: ?[]const u8 = null,
    /// Of `output`, the reasoning the server reports (Responses
    /// output_tokens_details); null when the wire has no split.
    reasoning: ?i64 = null,
    cache_write_12h: ?i64 = null,
    cache_write_30m: ?i64 = null,
};

threadlocal var pending: ?Usage = null;

/// After recordUsageResponses: the reasoning share of this response's output,
/// so the trace separates thinking from what the model wrote.
pub fn noteReasoning(response: std.json.ObjectMap) void {
    if (pending == null) return;
    const usage = response.get("usage") orelse return;
    if (usage != .object) return;
    const details = usage.object.get("output_tokens_details") orelse return;
    if (details != .object) return;
    const n = details.object.get("reasoning_tokens") orelse return;
    if (n == .integer and n.integer >= 0) pending.?.reasoning = n.integer;
}

/// From recordCost: remember this response's usage for the next `api` line.
pub fn note(self: *const Agent, ordinary: i64, cache_read: i64, cache_write: i64, out: i64) void {
    const gap = cache_ttl.gap();
    // The prefix tracker follows the root session only.
    const snap = if (self.sub) hud.Snap{} else hud.snapshot();
    const input = ordinary + cache_read + cache_write;
    pending = .{
        .provider = self.provider.id,
        .input = input,
        .cache_read = cache_read,
        .cache_write = cache_write,
        .output = out,
        // Sent as previous_response_id + the new items on a held socket.
        .chained = self.codex_prev_id != null,
        .gap_ms = gap,
        .cache_ttl = blk: {
            if (cache_ttl.control(self)) |c| if (std.mem.eql(u8, c, cache_ttl.ephemeral_1h)) break :blk "1h";
            const oai = @import("openai_prompt_cache.zig");
            if (oai.active(self)) break :blk oai.current().label();
            break :blk null;
        },
        .prefix_changed = !snap.same,
        .prefix_bust = if (snap.same) null else hud.bustLabel(snap.last_bust),
        .cache_miss = cache_ttl.missReason(cache_read, input, !snap.same, gap),
    };
}

/// From Tracer.api on a successful call: write the pending usage, if any.
pub fn emit(tr: anytype, label: []const u8, from_sub: bool, model: []const u8) void {
    const u = pending orelse return;
    pending = null;
    tr.write(.{
        .t = tr.elapsedMs(),
        .ev = "usage",
        .agent = label,
        .from_sub = from_sub,
        .provider = u.provider,
        .model = model,
        .input_tokens = u.input,
        .cache_read_tokens = u.cache_read,
        .cache_write_tokens = u.cache_write,
        .output_tokens = u.output,
        .chained = u.chained,
        .gap_ms = u.gap_ms,
        .cache_ttl = u.cache_ttl,
        .prefix_changed = u.prefix_changed,
        .prefix_bust = u.prefix_bust,
        .cache_miss = u.cache_miss,
        .reasoning_tokens = u.reasoning,
        .cache_write_12h_tokens = u.cache_write_12h,
        .cache_write_30m_tokens = u.cache_write_30m,
    });
}

/// After recordCost: named OpenAI write lifetimes from input_tokens_details.
pub fn noteWriteSplit(write_12h: i64, write_30m: i64) void {
    if (pending == null) return;
    if (write_12h > 0) pending.?.cache_write_12h = write_12h;
    if (write_30m > 0) pending.?.cache_write_30m = write_30m;
}

/// From Tracer.api on a failed call: nothing was billed for it.
pub fn drop() void {
    pending = null;
}

test "usage waits for its api line and is written once" {
    const Sink = struct {
        lines: u32 = 0,
        last_input: i64 = 0,
        last_miss: ?[]const u8 = null,
        last_reasoning: ?i64 = null,
        fn write(self: *@This(), event: anytype) void {
            self.lines += 1;
            self.last_input = event.input_tokens;
            self.last_miss = event.cache_miss;
            self.last_reasoning = event.reasoning_tokens;
        }
        fn elapsedMs(_: *@This()) i64 {
            return 0;
        }
    };
    var agent: Agent = undefined; // only provider, sub, codex_prev_id and compaction_request are read
    agent.provider.id = "codex";
    agent.provider.model = "gpt-6-sol";
    agent.compaction_request = false;
    agent.codex_prev_id = null;
    agent.sub = true;
    agent.request_started = null;
    cache_ttl.begin(&agent); // this thread's slot: no previous request
    var sink: Sink = .{};
    note(&agent, 100, 900, 0, 7);
    emit(&sink, "main", false, "gpt-6-sol");
    emit(&sink, "main", false, "gpt-6-sol"); // taken: no second line
    try std.testing.expectEqual(@as(u32, 1), sink.lines);
    try std.testing.expectEqual(@as(i64, 1000), sink.last_input);
    try std.testing.expect(sink.last_miss == null);
    note(&agent, 1, 2, 3, 4);
    drop(); // the call failed
    emit(&sink, "main", false, "gpt-6-sol");
    try std.testing.expectEqual(@as(u32, 1), sink.lines);
    // #1320: a zero-read request says why.
    note(&agent, 50_000, 0, 0, 9);
    emit(&sink, "main", false, "gpt-6-sol");
    try std.testing.expectEqualStrings("first_request", sink.last_miss.?);
    try std.testing.expect(sink.last_reasoning == null); // no split on the wire

    // A Responses usage block splits reasoning out of the output.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(),
        \\{"usage":{"input_tokens":10,"output_tokens":40,"output_tokens_details":{"reasoning_tokens":32}}}
    , .{});
    note(&agent, 10, 0, 0, 40);
    noteReasoning(parsed.object);
    emit(&sink, "main", false, "gpt-6-sol");
    try std.testing.expectEqual(@as(?i64, 32), sink.last_reasoning);
}

test {
    _ = cache_ttl;
}
