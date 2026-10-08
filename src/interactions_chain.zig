//! Server-side state on Google's Interactions wire (ADR 0271).
//!
//! A stored Interaction keeps every step it was sent and every step it
//! produced. A follow-up that names it in `previous_interaction_id` sends only
//! the steps added since, and the endpoint reports — and bills — only those as
//! input: a 38k-token history continued with a short question comes back as
//! ~130 `total_input_tokens`, with the whole prompt in `raw_prompt_token`.
//! Before this, graff sent `store:false` and replayed every step every request.
//!
//! The chain is used only while graff's history is a clean extension of what
//! the server holds, and the guard is content rather than bookkeeping:
//! `history_fp` hashes the wire form of messages[0..upto] when the chain is
//! recorded, and a request chains only when that prefix still hashes the same
//! under the same model. A /clear, a rewind, a compaction, a trim, an in-place
//! edit of an earlier step, or a model switch therefore sends a full replay,
//! which anchors a new chain. A chained request the endpoint rejects (an
//! expired or unknown id) is resent once as a full replay (agent_request.zig).
//!
//! GRAFF_INTERACTIONS_STORE=0 restores the stateless shape: `store:false` and a
//! full replay every request, so Google keeps nothing.

const std = @import("std");
const Value = std.json.Value;
const Wyhash = std.hash.Wyhash;

const Agent = @import("agent.zig").Agent;

/// Off only by GRAFF_INTERACTIONS_STORE=0 (session_settings.applyEnvKnobs).
pub var g_store = true;

const max_id = 256;

pub const Chain = struct {
    id_buf: [max_id]u8 = undefined,
    id_len: usize = 0, // 0 = no chain: the next request is a full replay
    upto: usize = 0, // messages the server holds behind the id
    history_fp: u64 = 0, // hash of messages[0..upto] as written on the wire
    model_fp: u64 = 0,
    /// The request in flight: how many messages it carried and the hash state
    /// after them, so recording its answer only hashes the answer's steps.
    sent_len: usize = 0,
    sent_state: ?Wyhash = null,
    sent_model_fp: u64 = 0,

    pub fn id(self: *const Chain) ?[]const u8 {
        return if (self.id_len == 0) null else self.id_buf[0..self.id_len];
    }

    pub fn clear(self: *Chain) void {
        self.id_len = 0;
        self.upto = 0;
    }
};

pub const Plan = struct {
    prev_id: ?[]const u8 = null,
    /// First message to send; 0 = full replay.
    from: usize = 0,
};

fn modelFp(model: []const u8) u64 {
    return Wyhash.hash(0, model);
}

/// Feed each message's wire form (session_wake.writeWire) into `h`.
fn hashMessages(h: *Wyhash, items: []const Value) !void {
    var buf: [1024]u8 = undefined;
    var hw: std.Io.Writer.Hashing(Wyhash) = .initHasher(h.*, &buf);
    for (items) |m| {
        var s: std.json.Stringify = .{ .writer = &hw.writer };
        try @import("session_wake.zig").writeWire(&s, m);
    }
    try hw.writer.flush();
    h.* = hw.hasher;
}

fn digest(h: Wyhash) u64 {
    var copy = h;
    return copy.final();
}

/// Decide what the next request sends, and remember what it carried so the
/// answer can extend the chain. Called once per body build.
pub fn plan(self: *Agent) !Plan {
    const c = &self.ix_chain;
    c.sent_state = null;
    if (!g_store) {
        c.clear();
        return .{};
    }
    const items = self.messages.items;
    const model = modelFp(self.provider.model);
    var h = Wyhash.init(0);
    var out: Plan = .{};
    var hashed: usize = 0;
    // `upto < len`: an empty delta is not a request the endpoint accepts.
    if (c.id_len > 0 and c.model_fp == model and c.upto < items.len) {
        try hashMessages(&h, items[0..c.upto]);
        hashed = c.upto;
        if (digest(h) == c.history_fp) out = .{ .prev_id = c.id(), .from = c.upto };
    }
    if (out.prev_id == null) c.clear();
    try hashMessages(&h, items[hashed..]);
    c.sent_len = items.len;
    c.sent_state = h;
    c.sent_model_fp = model;
    return out;
}

/// Anchor the chain on the Interaction that just answered: the server now
/// holds what the request carried plus `steps`. Call before the steps are
/// appended to history. Anything else appended in between (or a response
/// without an id) leaves no chain, so the next request replays in full.
pub fn record(self: *Agent, root: std.json.ObjectMap, steps: []const Value) !void {
    const c = &self.ix_chain;
    const state = c.sent_state orelse return;
    c.sent_state = null;
    c.clear();
    if (self.messages.items.len != c.sent_len) return;
    const id_v = root.get("id") orelse return;
    if (id_v != .string or id_v.string.len == 0 or id_v.string.len > max_id) return;
    var h = state;
    try hashMessages(&h, steps);
    @memcpy(c.id_buf[0..id_v.string.len], id_v.string);
    c.id_len = id_v.string.len;
    c.upto = c.sent_len + steps.len;
    c.history_fp = digest(h);
    c.model_fp = c.sent_model_fp;
}

/// A rejected request that named a stored Interaction: drop the chain so the
/// rebuilt request replays in full. Bounded by construction — the rebuilt body
/// carries no previous_interaction_id, so its own failure returns false.
pub fn dropRejected(self: *Agent, body: []const u8) bool {
    if (self.provider.kind != .interactions) return false;
    if (std.mem.indexOf(u8, body, "\"previous_interaction_id\"") == null) return false;
    self.ix_chain.clear();
    if (self.tracer) |tr| tr.note("interactions", "chained request rejected — resending the full history");
    return true;
}

fn testAgent(arena: std.mem.Allocator) Agent {
    return .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{ .id = "google", .kind = .interactions, .auth = .goog_api_key, .url = "", .api_key = "", .model = "gemini-3.8-flash", .context = 1_000_000 },
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "",
        .out = null,
    };
}

fn parse(arena: std.mem.Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, text, .{});
}

fn answer(arena: std.mem.Allocator, id: []const u8) !std.json.ObjectMap {
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "id", .{ .string = id });
    return root;
}

/// One model turn: plan the request, then record and append the answer.
fn turn(agent: *Agent, arena: std.mem.Allocator, id: []const u8, step_json: []const u8) !Plan {
    var p = try plan(agent);
    // prev_id points into the chain, which record() is about to overwrite.
    if (p.prev_id) |held| p.prev_id = try arena.dupe(u8, held);
    const st = try parse(arena, step_json);
    try record(agent, try answer(arena, id), &.{st});
    try agent.messages.append(st);
    return p;
}

test "a turn that extends history chains and sends only the new steps" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a);
    const steps = @import("interactions_steps.zig");

    try agent.messages.append(try steps.userInput(a, "first"));
    const p1 = try turn(&agent, a, "v1_one", "{\"type\":\"model_output\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}");
    try std.testing.expect(p1.prev_id == null); // nothing stored yet: full replay
    try std.testing.expectEqual(@as(usize, 0), p1.from);

    try agent.messages.append(try steps.userInput(a, "second"));
    const p2 = try turn(&agent, a, "v1_two", "{\"type\":\"function_call\",\"id\":\"c1\",\"name\":\"bash\",\"arguments\":{}}");
    try std.testing.expectEqualStrings("v1_one", p2.prev_id.?);
    try std.testing.expectEqual(@as(usize, 2), p2.from); // just "second"

    // A tool result rides on the newest Interaction.
    try agent.messages.append(try steps.functionResult(a, "c1", "bash", "out"));
    const p3 = try plan(&agent);
    try std.testing.expectEqualStrings("v1_two", p3.prev_id.?);
    try std.testing.expectEqual(@as(usize, 4), p3.from);
}

test "any change to what the server holds falls back to a full replay" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const steps = @import("interactions_steps.zig");
    const reply = "{\"type\":\"model_output\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}";

    // An in-place edit of a sent step (compaction, a trim, a capped output).
    var edited = testAgent(a);
    try edited.messages.append(try steps.userInput(a, "first"));
    _ = try turn(&edited, a, "v1_one", reply);
    edited.messages.items[0] = try steps.userInput(a, "summary of earlier work");
    try edited.messages.append(try steps.userInput(a, "next"));
    try std.testing.expect((try plan(&edited)).prev_id == null);

    // /clear then a history that grows back past the watermark.
    var cleared = testAgent(a);
    try cleared.messages.append(try steps.userInput(a, "first"));
    _ = try turn(&cleared, a, "v1_one", reply);
    cleared.messages.clearRetainingCapacity();
    for ([_][]const u8{ "a", "b", "c" }) |t| try cleared.messages.append(try steps.userInput(a, t));
    try std.testing.expect((try plan(&cleared)).prev_id == null);

    // A model switch.
    var switched = testAgent(a);
    try switched.messages.append(try steps.userInput(a, "first"));
    _ = try turn(&switched, a, "v1_one", reply);
    switched.provider.model = "gemini-3.8-pro";
    try switched.messages.append(try steps.userInput(a, "next"));
    try std.testing.expect((try plan(&switched)).prev_id == null);

    // Nothing new to send: an empty delta is never chained.
    var idle = testAgent(a);
    try idle.messages.append(try steps.userInput(a, "first"));
    _ = try turn(&idle, a, "v1_one", reply);
    try std.testing.expect((try plan(&idle)).prev_id == null);
}

test "a message appended while the request was in flight leaves no chain" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const steps = @import("interactions_steps.zig");
    var agent = testAgent(a);
    try agent.messages.append(try steps.userInput(a, "first"));
    _ = try plan(&agent);
    try agent.messages.append(try steps.userInput(a, "steer")); // the server never saw this
    try record(&agent, try answer(a, "v1_one"), &.{});
    try std.testing.expect(agent.ix_chain.id() == null);
}

test "the opt-out keeps every request stateless" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const steps = @import("interactions_steps.zig");
    const saved = g_store;
    defer g_store = saved;
    g_store = false;
    var agent = testAgent(a);
    try agent.messages.append(try steps.userInput(a, "first"));
    _ = try turn(&agent, a, "v1_one", "{\"type\":\"model_output\",\"content\":[]}");
    try agent.messages.append(try steps.userInput(a, "next"));
    try std.testing.expect((try plan(&agent)).prev_id == null);
    try std.testing.expect(agent.ix_chain.id() == null);
}

test "a rejected chained request drops the chain once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = testAgent(a);
    agent.ix_chain.id_len = 3;
    try std.testing.expect(dropRejected(&agent, "{\"previous_interaction_id\":\"v1_x\",\"input\":[]}"));
    try std.testing.expect(agent.ix_chain.id() == null);
    try std.testing.expect(!dropRejected(&agent, "{\"input\":[]}")); // the full replay failed on its own merits
}
