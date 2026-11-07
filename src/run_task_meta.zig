//! The `codegraff/runTask` facts that travel with a delegated MCP task: from
//! the MCP result's `_meta` mirror, through the engine's `tool_result` event,
//! into ACP `_meta` on the completed `tool_call_update`.
//!
//! Only these five facts move. The task's text and the caller's context never
//! do, and no charge is estimated here — `usage_reported` says whether a
//! settlement exists, it does not invent one (ADR 0253).

const std = @import("std");
const Value = std.json.Value;
const RunTaskMeta = @import("engine_events.zig").RunTaskMeta;

/// The namespaced key on both the MCP result and the ACP update. Same key on
/// purpose: a client can follow one name across the boundary.
pub const key = "codegraff/runTask";

fn intField(o: std.json.ObjectMap, k: []const u8) ?u64 {
    const v = o.get(k) orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

fn boolField(o: std.json.ObjectMap, k: []const u8) bool {
    const v = o.get(k) orelse return false;
    return v == .bool and v.bool;
}

fn strField(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

/// Borrow the five fields out of a `codegraff/runTask` object. The strings
/// stay owned by the JSON that produced them; use `readDup` when that JSON is
/// about to die. `context_chars` is the anchor: without it this is not a
/// runTask object, and a partial one is ignored rather than half-reported.
pub fn read(o: std.json.ObjectMap) ?RunTaskMeta {
    return .{
        .context_chars = intField(o, "context_chars") orelse return null,
        .context_used_chars = intField(o, "context_used_chars") orelse 0,
        .context_summarized = boolField(o, "context_summarized"),
        .usage_reported = boolField(o, "usage_reported"),
        .usage_unavailable_reason = strField(o, "usage_unavailable_reason") orelse "",
    };
}

/// `read`, with the one borrowed string copied into `a`.
pub fn readDup(a: std.mem.Allocator, o: std.json.ObjectMap) ?RunTaskMeta {
    var m = read(o) orelse return null;
    m.usage_unavailable_reason = a.dupe(u8, m.usage_unavailable_reason) catch "";
    return m;
}

/// The mirror inside an MCP `tools/call` result object.
pub fn fromMcpResult(a: std.mem.Allocator, result: std.json.ObjectMap) ?RunTaskMeta {
    const meta = result.get("_meta") orelse return null;
    if (meta != .object) return null;
    const rt = meta.object.get(key) orelse return null;
    if (rt != .object) return null;
    return readDup(a, rt.object);
}

/// The same object as it rides a `--json` tool_result line.
pub fn fromEvent(ev: Value) ?RunTaskMeta {
    if (ev != .object) return null;
    const rt = ev.object.get("run_task") orelse return null;
    if (rt != .object) return null;
    return read(rt.object);
}

const testing = std.testing;

/// These tests parse JSON into an arena: `parseFromSliceLeaky` is leaky by
/// design, and the testing allocator counts every leaked byte.
fn parse(a: std.mem.Allocator, raw: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, raw, .{});
}

test "read: the five fields round-trip, and a missing anchor is not a runTask object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parse(a,
        \\{"context_chars":40,"context_used_chars":7,"context_summarized":true,"usage_reported":false,"usage_unavailable_reason":"no settlement"}
    );
    const m = read(v.object).?;
    try testing.expectEqual(@as(u64, 40), m.context_chars);
    try testing.expectEqual(@as(u64, 7), m.context_used_chars);
    try testing.expect(m.context_summarized);
    try testing.expect(!m.usage_reported);
    try testing.expectEqualStrings("no settlement", m.usage_unavailable_reason);
    // Without the anchor this is some other object that happens to share a key.
    const other = try parse(a, "{\"usage_reported\":false}");
    try testing.expect(read(other.object) == null);
}

test "fromMcpResult: reads the namespaced mirror, ignores anything else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try parse(a,
        \\{"text":"answer","_meta":{"codegraff/runTask":{"context_chars":9,"usage_unavailable_reason":"r"}}}
    );
    const m = fromMcpResult(a, ok.object).?;
    try testing.expectEqual(@as(u64, 9), m.context_chars);
    try testing.expectEqualStrings("r", m.usage_unavailable_reason);
    for ([_][]const u8{
        \\{"text":"answer"}
        ,
        \\{"text":"answer","_meta":{"graff/view":{"kind":"html"}}}
        ,
        \\{"text":"answer","_meta":{"codegraff/runTask":"nope"}}
        ,
    }) |raw| {
        const v = try parse(a, raw);
        try testing.expect(fromMcpResult(a, v.object) == null);
    }
}

test "readDup copies the reason; fromEvent reads the wire line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try parse(a,
        \\{"run_task":{"context_chars":3,"context_summarized":true,"usage_reported":false,"usage_unavailable_reason":"why"}}
    );
    const m = fromEvent(v).?;
    try testing.expectEqual(@as(u64, 3), m.context_chars);
    try testing.expect(m.context_summarized);
    try testing.expectEqualStrings("why", m.usage_unavailable_reason);
    try testing.expect(fromEvent(.null) == null);
    try testing.expect(fromEvent(try parse(a, "{\"type\":\"tool_result\"}")) == null);
    // A dup survives the JSON that produced it.
    var src = std.heap.ArenaAllocator.init(testing.allocator);
    const v2 = try parse(src.allocator(),
        \\{"codegraff/runTask":{"context_chars":1,"usage_unavailable_reason":"kept"}}
    );
    const dup = readDup(a, v2.object.get("codegraff/runTask").?.object).?;
    src.deinit();
    try testing.expectEqualStrings("kept", dup.usage_unavailable_reason);
}
