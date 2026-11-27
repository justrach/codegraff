//! #1686: a resumed session keeps the provider's count of its compaction state.

const std = @import("std");
const Value = std.json.Value;
const Agent = @import("agent.zig").Agent;
const context_tokens = @import("context_tokens.zig");
const persist = @import("opaque_state_persist.zig");
const session = @import("session.zig");

const window: u64 = 270_000;
const state_len: usize = 8_000_000;

fn history(a: std.mem.Allocator, fill: u8) !std.json.Array {
    const head = "{\"type\":\"compaction\",\"encrypted_content\":\"";
    const json = try a.alloc(u8, head.len + state_len + 2);
    @memcpy(json[0..head.len], head);
    @memset(json[head.len .. head.len + state_len], fill);
    @memcpy(json[head.len + state_len ..], "\"}");
    var msgs = std.json.Array.init(a);
    try msgs.append(try std.json.parseFromSliceLeaky(Value, a, json, .{}));
    try msgs.append(try std.json.parseFromSliceLeaky(Value, a, "{\"role\":\"user\",\"content\":\"hi\"}", .{}));
    return msgs;
}

fn agent(msgs: std.json.Array) Agent {
    var root: Agent = undefined;
    root.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = window };
    root.messages = msgs;
    root.sub = false;
    root.strict = false;
    root.sys_normal = "";
    root.sys_strict = "";
    root.tools_responses = "";
    root.last_cache_read = 0;
    return root;
}

/// What a warm process saves after the provider counted the state at 80k:
/// the meter pair and the persisted count, as one session object.
const Saved = struct { context: u64, local: u64, obj: std.json.ObjectMap };

fn countAndSave(a: std.mem.Allocator, root: *Agent) !Saved {
    context_tokens.learnState(state_len, 80_000, root.fullRequestEstimateTokens());
    const local = root.fullRequestEstimateTokens();
    var aw: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try persist.write(&s, root.provider, .{ .array = root.messages });
    try s.endObject();
    const parsed = try std.json.parseFromSliceLeaky(Value, a, aw.writer.buffered(), .{});
    return .{ .context = 80_001, .local = local, .obj = parsed.object };
}

/// A new process: empty calibration, then loadSession's restore order.
fn reload(root: *Agent, saved: Saved) void {
    context_tokens.resetStateCountsForTest();
    persist.restore(root.provider, .{ .array = root.messages }, saved.obj);
    session.restoreContextMeter(root, saved.context, saved.local);
}

test "a reloaded session keeps the provider's count of its compaction state (#1686)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    context_tokens.resetStateCountsForTest();
    defer context_tokens.resetStateCountsForTest();

    var root = agent(try history(a, 'A'));
    const saved = try countAndSave(a, &root);
    try std.testing.expect(saved.obj.get(persist.field) != null);

    // Without the record a new process reads the state at bytes/16 (the bug).
    var cold = saved;
    cold.obj = (try std.json.parseFromSliceLeaky(Value, a, "{}", .{})).object;
    reload(&root, cold);
    try std.testing.expect(root.effectiveContextTokens() > window);
    try std.testing.expect(root.inputOverCompactThreshold());

    // With it, the reload keeps the counted occupancy and needs no compaction.
    reload(&root, saved);
    try std.testing.expect(root.effectiveContextTokens() < 100_000);
    try std.testing.expect(!root.inputOverCompactThreshold());
}

test "a saved state count applies only to the same state, provider, and model (#1686)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    context_tokens.resetStateCountsForTest();
    defer context_tokens.resetStateCountsForTest();

    var counted = agent(try history(a, 'A'));
    const saved = try countAndSave(a, &counted);

    // Same length, different blob: the digest refuses it.
    var other = agent(try history(a, 'B'));
    reload(&other, saved);
    try std.testing.expect(context_tokens.calibratedState(state_len) == null);
    try std.testing.expect(other.inputOverCompactThreshold());

    var moved = agent(counted.messages);
    moved.provider.model = "gpt-6";
    reload(&moved, saved);
    try std.testing.expect(context_tokens.calibratedState(state_len) == null);
    moved.provider.model = "gpt-5";
    moved.provider.id = "openai";
    reload(&moved, saved);
    try std.testing.expect(context_tokens.calibratedState(state_len) == null);

    const malformed = [_][]const u8{
        "{\"opaque_state_count\":{\"provider\":\"codex\",\"model\":\"gpt-5\",\"state_bytes\":8000000,\"state_digest\":\"zz\",\"tokens\":72000}}",
        "{\"opaque_state_count\":{\"provider\":\"codex\",\"model\":\"gpt-5\",\"state_bytes\":8000000,\"state_digest\":\"0\",\"tokens\":-1}}",
        "{\"opaque_state_count\":\"codex\"}",
        "{}",
    };
    for (malformed) |text| {
        const parsed = try std.json.parseFromSliceLeaky(Value, a, text, .{});
        reload(&counted, .{ .context = saved.context, .local = saved.local, .obj = parsed.object });
        try std.testing.expect(context_tokens.calibratedState(state_len) == null);
    }
}

test "an uncounted compaction state writes no record (#1686)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    context_tokens.resetStateCountsForTest();
    defer context_tokens.resetStateCountsForTest();

    const root = agent(try history(a, 'A'));
    var aw: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try persist.write(&s, root.provider, .{ .array = root.messages });
    try s.endObject();
    try std.testing.expectEqualStrings("{}", aw.writer.buffered());
}

test "session save and load both carry the compaction-state count (#1686)" {
    const src = @embedFile("session.zig");
    const ser_src = @embedFile("session_serialize.zig");
    try std.testing.expect(std.mem.indexOf(u8, ser_src, "opaque_state_persist.zig\").write(&s, root.provider, Value{ .array = saved_msgs })") != null);
    // Restore runs before the meter is rebased, or the rebase reads bytes/16.
    const restore_at = std.mem.indexOf(u8, src, "opaque_state_persist.zig\").restore(root.provider") orelse return error.TestUnexpectedResult;
    const rebase_at = std.mem.indexOf(u8, src, "    restoreContextMeter(root, saved_context_tokens, saved_local_tokens);") orelse return error.TestUnexpectedResult;
    try std.testing.expect(restore_at < rebase_at);
}

test "a session saved after a counted request loads without a forced compaction (#1686)" {
    const writer = @import("session_writer.zig");
    const transcript = @import("session_transcript.zig");
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    writer.resetForTest();
    defer writer.resetForTest();
    transcript.resetForTest();
    defer transcript.resetForTest();
    context_tokens.resetStateCountsForTest();
    defer context_tokens.resetStateCountsForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var keys: @import("provider.zig").Keys = .{ .values = @splat("test-key") };
    var provider = try keys.providerById("openai", "gpt-6-sol");
    provider.context = window;
    var root: Agent = .{
        .gpa = gpa,
        .arena = a,
        .io = io,
        .client = &client,
        .provider = provider,
        .messages = try history(a, 'A'),
        .sub = false,
        .label = "root",
        .out = null,
        .home = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}),
    };
    try root.ensureRootTools(root.provider.kind);

    // Warm process: the provider counted a full request carrying the state at 80k.
    context_tokens.learnState(state_len, 80_000, root.fullRequestEstimateTokens());
    root.last_context_tokens = 80_001;
    root.context_local_tokens = root.fullRequestEstimateTokens();
    try std.testing.expect(!root.inputOverCompactThreshold());
    try session.saveSessionTo(&root, a, tmp.dir, "reload-1686");
    session.flushSaves();

    // New process: no calibration in memory, then the real load path.
    context_tokens.resetStateCountsForTest();
    root.last_context_tokens = 0;
    root.context_local_tokens = 0;
    try session.loadSession(&root, &keys, a, "reload-1686");
    root.provider.context = window;
    try std.testing.expect(root.effectiveContextTokens() < 100_000);
    try std.testing.expect(!root.inputOverCompactThreshold());
}

/// An opaque reasoning item (not a compaction item, so no state record is
/// saved) whose bytes the local estimate over-counts relative to the
/// provider's own usage: 331k counted, about 608k estimated, 500k window.
const reasoning_window: u64 = 500_000;
const reasoning_count: u64 = 331_000;

fn reasoningHistory(a: std.mem.Allocator) !std.json.Array {
    const head = "{\"type\":\"reasoning\",\"encrypted_content\":\"";
    const reasoning_len: usize = 2_400_000;
    const json = try a.alloc(u8, head.len + reasoning_len + 2);
    @memcpy(json[0..head.len], head);
    @memset(json[head.len .. head.len + reasoning_len], 'R');
    @memcpy(json[head.len + reasoning_len ..], "\"}");
    var msgs = std.json.Array.init(a);
    try msgs.append(try std.json.parseFromSliceLeaky(Value, a, "{\"role\":\"user\",\"content\":\"start\"}", .{}));
    try msgs.append(try std.json.parseFromSliceLeaky(Value, a, json, .{}));
    return msgs;
}

/// The pair session_serialize writes: the live meter and its local estimate.
fn savedPair(root: *Agent, obj: std.json.ObjectMap) Saved {
    const estimate = root.contextEstimate();
    return .{ .context = estimate.effective, .local = estimate.local, .obj = obj };
}

test "a reload keeps a provider count below the local estimate (#1686)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    context_tokens.resetStateCountsForTest();
    defer context_tokens.resetStateCountsForTest();

    var root = agent(try reasoningHistory(a));
    root.provider.context = reasoning_window;
    const local = root.fullRequestEstimateTokens();
    try std.testing.expect(local > root.provider.compactAt()); // the local estimate alone crosses the gate

    // Warm process: the live meter trusts the lower provider count.
    root.last_context_tokens = reasoning_count;
    root.context_local_tokens = local;
    try std.testing.expectEqual(reasoning_count, root.effectiveContextTokens());
    try std.testing.expect(!root.inputOverCompactThreshold());

    // New process: loadSession's restore with the saved pair, unchanged history.
    reload(&root, .{ .context = reasoning_count, .local = local, .obj = (try std.json.parseFromSliceLeaky(Value, a, "{}", .{})).object });
    try std.testing.expectEqual(reasoning_count, root.effectiveContextTokens());
    try std.testing.expect(!root.inputOverCompactThreshold());
}

test "a reload restores the live meter above, at, or below the local estimate (#1686)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    context_tokens.resetStateCountsForTest();
    defer context_tokens.resetStateCountsForTest();
    const empty = (try std.json.parseFromSliceLeaky(Value, a, "{}", .{})).object;

    var root = agent(try reasoningHistory(a));
    root.provider.context = reasoning_window;
    const local = root.fullRequestEstimateTokens();
    for ([_]u64{ local + 5_000, local, reasoning_count }) |count| {
        root.last_context_tokens = count;
        root.context_local_tokens = local;
        const live = root.effectiveContextTokens();
        const live_over = root.inputOverCompactThreshold();
        reload(&root, savedPair(&root, empty));
        try std.testing.expectEqual(live, root.effectiveContextTokens());
        try std.testing.expectEqual(live_over, root.inputOverCompactThreshold());
        // History added after the reload still counts on top of the restored meter.
        try root.messages.append(try std.json.parseFromSliceLeaky(Value, a, "{\"role\":\"user\",\"content\":\"next\"}", .{}));
        const grown = root.fullRequestEstimateTokens() - local;
        try std.testing.expect(grown > 0);
        try std.testing.expectEqual(live + grown, root.effectiveContextTokens());
        _ = root.messages.pop();
    }
    // A file from before the paired field re-estimates, as it always did.
    session.restoreContextMeter(&root, reasoning_count, null);
    try std.testing.expectEqual(local, root.effectiveContextTokens());
}

test "a saved provider count below the estimate survives save, load, and a second save (#1686)" {
    const writer = @import("session_writer.zig");
    const transcript = @import("session_transcript.zig");
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    writer.resetForTest();
    defer writer.resetForTest();
    transcript.resetForTest();
    defer transcript.resetForTest();
    context_tokens.resetStateCountsForTest();
    defer context_tokens.resetStateCountsForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var keys: @import("provider.zig").Keys = .{ .values = @splat("test-key") };
    var provider = try keys.providerById("openai", "gpt-6-sol");
    provider.context = reasoning_window;
    var root: Agent = .{
        .gpa = gpa,
        .arena = a,
        .io = io,
        .client = &client,
        .provider = provider,
        .messages = try reasoningHistory(a),
        .sub = false,
        .label = "root",
        .out = null,
        .home = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}),
    };
    try root.ensureRootTools(root.provider.kind);

    // Warm process: the provider counted the full request below the estimate.
    root.last_context_tokens = reasoning_count;
    const warm_local = root.fullRequestEstimateTokens();
    root.context_local_tokens = warm_local;
    try std.testing.expect(warm_local > root.provider.compactAt());
    try std.testing.expect(!root.inputOverCompactThreshold());
    try session.saveSessionTo(&root, a, tmp.dir, "reload-below-1686");
    session.flushSaves();

    // New process, real load path (ACP session/load, --resume and /fork all
    // run loadSession); then save the restored session again, as a fork does,
    // and load that copy too.
    for ([_][]const u8{ "reload-below-1686", "reload-below-1686-fork" }, 0..) |name, hop| {
        root.last_context_tokens = 0;
        root.context_local_tokens = 0;
        try session.loadSession(&root, &keys, a, name);
        root.provider.context = reasoning_window;
        // The count, plus whatever the reloaded request estimate grew by (the
        // rebuilt prompt and tools), as the live meter would add it; never the
        // re-estimated history.
        const growth = root.fullRequestEstimateTokens() -| warm_local;
        try std.testing.expect(growth < 1_000);
        try std.testing.expectEqual(reasoning_count + growth, root.effectiveContextTokens());
        // REPL resume and the pre-send gate both decide on this check.
        try std.testing.expect(!root.inputOverCompactThreshold());
        if (hop == 0) {
            try session.saveSessionTo(&root, a, tmp.dir, "reload-below-1686-fork");
            session.flushSaves();
        }
    }
}

test "a chained response teaches the compaction-state count (#1686)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    context_tokens.resetStateCountsForTest();
    defer context_tokens.resetStateCountsForTest();

    // previous_response_id still bills the whole chain as input (OpenAI), so a
    // WebSocket delta's usage counts the state like a full request's does.
    var root = agent(try history(a, 'A'));
    root.codex_prev_id = "resp_1";
    const response = try std.json.parseFromSliceLeaky(Value, a, "{\"usage\":{\"input_tokens\":80000}}", .{});
    @import("opaque_state_usage.zig").learn(&root, response.object);
    try std.testing.expect(context_tokens.calibratedState(state_len) != null);
    try std.testing.expect(!root.inputOverCompactThreshold());
}
