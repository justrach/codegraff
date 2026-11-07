//! Reassemble a streamed Anthropic Messages body into the non-streaming
//! response shape stepAnthropic reads. Split out of agent_steps.zig (600-line
//! cap) when #1218 added per-block stop tracking.

const std = @import("std");
const Value = std.json.Value;

const Agent = @import("agent.zig").Agent;
const util = @import("util.zig");
const tool_call_args = @import("tool_call_args.zig");
const sse_error = @import("sse_error_event.zig");

const ssePayload = Agent.ssePayload;
const sseIndex = Agent.sseIndex;

/// One in-flight content block while reassembling an Anthropic stream.
const BlockAcc = struct {
    obj: std.json.ObjectMap = .empty,
    text: std.ArrayList(u8) = .empty,
    json: std.ArrayList(u8) = .empty,
    thinking: std.ArrayList(u8) = .empty,
    signature: std.ArrayList(u8) = .empty,
    /// content_block_stop arrived: the block finished streaming.
    stopped: bool = false,

    fn isToolUse(self: BlockAcc) bool {
        const t = self.obj.get("type") orelse return false;
        return t == .string and std.mem.eql(u8, t.string, "tool_use");
    }
};

/// message_start carries the message skeleton (role, model, input-token
/// usage); content blocks open with content_block_start and accumulate
/// via content_block_delta (text / partial_json / thinking / signature);
/// message_delta carries stop_reason and output-token usage.
pub fn assembleAnthropic(self: *Agent, body: []const u8) !?std.json.ObjectMap {
    // #124 slice 2b: the whole assembly — per-event parse trees, delta
    // accumulators, the stitched message — lives on the per-request scratch
    // arena; the finished message is deep-copied onto the session arena once
    // at return (it becomes the assistant history message, so it must survive
    // the next request's scratch reset). Previously every event's parse tree
    // landed on the session arena for the life of the process.
    const scratch = self.scratchAlloc();
    const result_arena = self.messageMutationAlloc();
    var root: ?std.json.ObjectMap = null;
    var blocks: std.ArrayList(BlockAcc) = .empty;
    var stop_reason: ?Value = null;
    var stop_details: ?Value = null; // a refusal's category (ADR 0219)
    var usage_delta: ?Value = null;
    var saw_block_stop = false;
    var named_error = false; // the data lines follow an `event: error` name
    var it = std.mem.tokenizeScalar(u8, body, '\n');
    while (it.next()) |raw_line| {
        const payload = ssePayload(raw_line) orelse {
            named_error = sse_error.namesError(raw_line, named_error);
            continue;
        };
        const v = std.json.parseFromSliceLeaky(Value, scratch, payload, .{ .allocate = .alloc_always }) catch continue;
        if (v != .object) continue;
        // An error event (typed, untyped from a proxy, or a bare frame under
        // `event: error`) becomes the root: request()'s type=="error" check
        // reports it with the provider's type and message (#748). Detached
        // from scratch: the rebuild loop can reset the scratch arena before
        // the message is done being read.
        if (try sse_error.envelope(result_arena, v.object, named_error)) |env| return env;
        named_error = false;
        const t = v.object.get("type") orelse continue;
        if (t != .string) continue;
        if (std.mem.eql(u8, t.string, "message_start")) {
            if (v.object.get("message")) |m| if (m == .object) {
                root = m.object;
            };
        } else if (std.mem.eql(u8, t.string, "content_block_start")) {
            const idx = sseIndex(v.object) orelse continue;
            while (blocks.items.len <= idx) try blocks.append(scratch, .{});
            if (v.object.get("content_block")) |cb| if (cb == .object) {
                blocks.items[idx].obj = cb.object;
            };
        } else if (std.mem.eql(u8, t.string, "content_block_delta")) {
            const idx = sseIndex(v.object) orelse continue;
            if (idx >= blocks.items.len) continue;
            const d = v.object.get("delta") orelse continue;
            if (d != .object) continue;
            const b = &blocks.items[idx];
            if (d.object.get("text")) |x| if (x == .string) try b.text.appendSlice(scratch, x.string);
            if (d.object.get("partial_json")) |x| if (x == .string) try b.json.appendSlice(scratch, x.string);
            if (d.object.get("thinking")) |x| if (x == .string) try b.thinking.appendSlice(scratch, x.string);
            if (d.object.get("signature")) |x| if (x == .string) try b.signature.appendSlice(scratch, x.string);
        } else if (std.mem.eql(u8, t.string, "content_block_stop")) {
            saw_block_stop = true;
            const idx = sseIndex(v.object) orelse continue;
            if (idx < blocks.items.len) blocks.items[idx].stopped = true;
        } else if (std.mem.eql(u8, t.string, "message_delta")) {
            if (v.object.get("delta")) |d| if (d == .object) {
                if (d.object.get("stop_reason")) |sr| if (sr == .string) {
                    stop_reason = sr;
                };
                if (d.object.get("stop_details")) |sd| if (sd == .object) {
                    stop_details = sd;
                };
            };
            if (v.object.get("usage")) |u| if (u == .object) {
                usage_delta = u;
            };
        }
    }
    var r = root orelse return null;
    // #1218: a response that stopped mid-output (max_tokens, or a stream that
    // ended before message_delta) can leave tool_use blocks half-written. A
    // block without its content_block_stop is the one that was cut; a provider
    // that never sends block stops leaves only the last tool_use in doubt.
    const cut = tool_call_args.responseCut(if (stop_reason) |s| s.string else null);
    var last_tool: ?usize = null;
    for (blocks.items, 0..) |b, i| if (b.isToolUse()) {
        last_tool = i;
    };
    var content = std.json.Array.init(scratch);
    for (blocks.items, 0..) |*b, i| {
        if (b.obj.get("type") == null) continue; // never started
        if (b.text.items.len > 0) try b.obj.put(scratch, "text", .{ .string = b.text.items });
        if (b.thinking.items.len > 0) try b.obj.put(scratch, "thinking", .{ .string = b.thinking.items });
        if (b.signature.items.len > 0) try b.obj.put(scratch, "signature", .{ .string = b.signature.items });
        const cut_block = cut and b.isToolUse() and (if (saw_block_stop) !b.stopped else i == last_tool);
        if (b.json.items.len > 0 or cut_block) try tool_call_args.putStreamedInput(scratch, &b.obj, b.json.items, cut_block);
        try content.append(.{ .object = b.obj });
    }
    try r.put(scratch, "content", .{ .array = content });
    try r.put(scratch, "stop_reason", stop_reason orelse Value{ .string = "end_turn" });
    if (stop_details) |sd| try r.put(scratch, "stop_details", sd);
    if (stop_reason == null) try r.put(scratch, "incomplete", .{ .bool = true });
    if (usage_delta) |ud| {
        var usage: std.json.ObjectMap = .empty;
        if (r.get("usage")) |base| if (base == .object) {
            var e = base.object.iterator();
            while (e.next()) |kv| try usage.put(scratch, kv.key_ptr.*, kv.value_ptr.*);
        };
        var e = ud.object.iterator();
        while (e.next()) |kv| try usage.put(scratch, kv.key_ptr.*, kv.value_ptr.*);
        try r.put(scratch, "usage", .{ .object = usage });
    }
    return (try util.dupeJsonValue(result_arena, .{ .object = r })).object;
}

fn testAgent(arena: std.mem.Allocator) Agent {
    return .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = undefined,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = null,
    };
}

fn refusals(arena: std.mem.Allocator, body: []const u8) ![]tool_call_args.Refusal {
    var agent = testAgent(arena);
    const root = (try assembleAnthropic(&agent, body)).?;
    const blocks = root.get("content").?.array.items;
    const out = try arena.alloc(tool_call_args.Refusal, blocks.len);
    for (blocks, out) |*b, *o| o.* = tool_call_args.takeInvalidMark(&b.object);
    return out;
}

const start_read = "data: {\"type\":\"message_start\",\"message\":{\"role\":\"assistant\",\"content\":[]}}\n";

fn toolStart(comptime ix: []const u8) []const u8 {
    return "data: {\"type\":\"content_block_start\",\"index\":" ++ ix ++ ",\"content_block\":{\"type\":\"tool_use\",\"id\":\"t" ++ ix ++ "\",\"name\":\"read_file\",\"input\":{}}}\n";
}

fn toolJson(comptime ix: []const u8, comptime json: []const u8) []const u8 {
    return "data: {\"type\":\"content_block_delta\",\"index\":" ++ ix ++ ",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"" ++ json ++ "\"}}\n";
}

fn toolStop(comptime ix: []const u8) []const u8 {
    return "data: {\"type\":\"content_block_stop\",\"index\":" ++ ix ++ "}\n";
}

test "#1218: a max_tokens stop refuses only the calls it cut, including a call with no input yet" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try refusals(arena, comptime start_read ++
        toolStart("0") ++ toolJson("0", "{\\\"path\\\":\\\"a.zig\\\"}") ++ toolStop("0") ++
        toolStart("1") ++ toolJson("1", "{\\\"path\\\":\\\"b.z") ++
        toolStart("2") ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}\n");
    try std.testing.expectEqualSlices(tool_call_args.Refusal, &.{ .none, .cut, .cut }, got);
}

test "#1218: a stream that ends before message_delta is cut; a finished response is not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // No block stops at all (some compatible providers): only the last call is in doubt.
    const dropped = try refusals(arena, comptime start_read ++
        toolStart("0") ++ toolJson("0", "{\\\"path\\\":\\\"a.zig\\\"}") ++
        toolStart("1"));
    try std.testing.expectEqualSlices(tool_call_args.Refusal, &.{ .none, .cut }, dropped);
    // A finished response keeps a no-input call runnable and a malformed one malformed.
    const done = try refusals(arena, comptime start_read ++
        toolStart("0") ++ toolStop("0") ++
        toolStart("1") ++ toolJson("1", "{\\\"path\\\":") ++ toolStop("1") ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n");
    try std.testing.expectEqualSlices(tool_call_args.Refusal, &.{ .none, .malformed }, done);
}

test "a refusal keeps its stop_details category (ADR 0219)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var agent = testAgent(arena_state.allocator());
    const root = (try assembleAnthropic(&agent, start_read ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\",\"stop_details\":{\"type\":\"refusal\",\"category\":\"cyber\"}}}\n")).?;
    try std.testing.expectEqualStrings("refusal", root.get("stop_reason").?.string);
    try std.testing.expectEqualStrings("cyber", @import("claude_refusal.zig").category(root).?);
}
