//! MCP 2026-07-28 multi round-trip requests (MRTR) for `tools/call`.
//!
//! A modern server that needs client input mid-call no longer sends an
//! `elicitation/create` request; it returns `resultType: "input_required"`
//! with `inputRequests` (and optionally `requestState`). The client answers
//! each request and retries the same `tools/call` with `inputResponses` and
//! the echoed `requestState`. graff used to stop with "does not implement
//! MRTR". As with a legacy elicitation (mcp_elicitation.zig), graff shows no
//! forms, so every request is declined; `roots/list` gets no roots.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const mcp_protocol = @import("mcp_protocol.zig");

pub const max_rounds = 4;

/// The `inputResponses` object for one `input_required` result.
pub fn responses(a: Allocator, requests: std.json.ObjectMap) !Value {
    var out: std.json.ObjectMap = .empty;
    var it = requests.iterator();
    while (it.next()) |e| {
        const req = e.value_ptr.*;
        const method = if (req == .object) (if (req.object.get("method")) |m| (if (m == .string) m.string else "") else "") else "";
        var answer: std.json.ObjectMap = .empty;
        if (std.mem.eql(u8, method, "roots/list")) {
            try answer.put(a, "roots", .{ .array = std.json.Array.init(a) });
        } else {
            try answer.put(a, "action", .{ .string = "decline" });
        }
        try out.put(a, e.key_ptr.*, .{ .object = answer });
    }
    return .{ .object = out };
}

/// The retry params: the original `tools/call` params plus
/// `inputResponses` and the echoed `requestState`.
pub fn retryParams(a: Allocator, params: []const u8, result: std.json.ObjectMap) ![]const u8 {
    const original = try std.json.parseFromSliceLeaky(Value, a, params, .{ .allocate = .alloc_always });
    if (original != .object) return error.BadMcpParams;
    var next = try original.object.clone(a);
    if (result.get("inputRequests")) |reqs| if (reqs == .object) try next.put(a, "inputResponses", try responses(a, reqs.object));
    if (result.get("requestState")) |state| try next.put(a, "requestState", state);
    return std.json.Stringify.valueAlloc(a, Value{ .object = next }, .{});
}

fn inputRequired(resp: Value) ?std.json.ObjectMap {
    if (resp != .object) return null;
    const r = resp.object.get("result") orelse return null;
    if (r != .object or mcp_protocol.resultIsComplete(r.object)) return null;
    const t = r.object.get("resultType") orelse return null;
    return if (t == .string and std.mem.eql(u8, t.string, "input_required")) r.object else null;
}

/// Drive `input_required` results to completion. `send` performs one
/// `tools/call` with the given params; `first` is the reply to the original.
pub fn resolve(a: Allocator, params: []const u8, first: Value, ctx: anytype, send: fn (@TypeOf(ctx), Allocator, []const u8) anyerror!Value) !Value {
    var resp = first;
    var round: usize = 0;
    while (inputRequired(resp)) |result| : (round += 1) {
        if (round == max_rounds) return error.McpInputRequiredLoop;
        resp = try send(ctx, a, try retryParams(a, params, result));
    }
    return resp;
}

const testing = std.testing;

test "responses decline an unfillable form and answer roots/list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const reqs = try std.json.parseFromSliceLeaky(Value, a,
        \\{"login":{"method":"elicitation/create","params":{"mode":"form","message":"GitHub username?","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}}},
        \\ "roots":{"method":"roots/list","params":{}}}
    , .{});
    const out = try responses(a, reqs.object);
    try testing.expectEqualStrings("decline", out.object.get("login").?.object.get("action").?.string);
    try testing.expectEqual(@as(usize, 0), out.object.get("roots").?.object.get("roots").?.array.items.len);
}

test "retryParams keeps the call and adds inputResponses and requestState" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try std.json.parseFromSliceLeaky(Value, a,
        \\{"resultType":"input_required","inputRequests":{"q":{"method":"elicitation/create","params":{"message":"?"}}},"requestState":"s1"}
    , .{});
    const p = try retryParams(a, "{\"name\":\"get_weather\",\"arguments\":{\"location\":\"NYC\"}}", result.object);
    const v = try std.json.parseFromSliceLeaky(Value, a, p, .{});
    try testing.expectEqualStrings("get_weather", v.object.get("name").?.string);
    try testing.expectEqualStrings("s1", v.object.get("requestState").?.string);
    try testing.expect(v.object.get("inputResponses").?.object.get("q") != null);
}

const Fake = struct {
    calls: usize = 0,
    fn send(self: *Fake, a: Allocator, params: []const u8) anyerror!Value {
        self.calls += 1;
        const v = try std.json.parseFromSliceLeaky(Value, a, params, .{});
        try testing.expect(v.object.get("inputResponses") != null);
        return std.json.parseFromSliceLeaky(Value, a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}", .{});
    }
};

test "resolve retries once and returns the completed result" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try std.json.parseFromSliceLeaky(Value, a,
        \\{"jsonrpc":"2.0","id":1,"result":{"resultType":"input_required","inputRequests":{"q":{"method":"elicitation/create","params":{"message":"?"}}}}}
    , .{});
    var fake: Fake = .{};
    const done = try resolve(a, "{\"name\":\"t\",\"arguments\":{}}", first, &fake, Fake.send);
    try testing.expectEqual(@as(usize, 1), fake.calls);
    try testing.expect(mcp_protocol.resultIsComplete(done.object.get("result").?.object));
    const plain = try std.json.parseFromSliceLeaky(Value, a, "{\"result\":{\"content\":[]}}", .{});
    _ = try resolve(a, "{}", plain, &fake, Fake.send);
    try testing.expectEqual(@as(usize, 1), fake.calls); // a complete result is not retried
}
