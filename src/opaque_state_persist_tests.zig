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
    try std.testing.expect(std.mem.indexOf(u8, src, "opaque_state_persist.zig\").write(&s, root.provider, Value{ .array = saved_msgs })") != null);
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
