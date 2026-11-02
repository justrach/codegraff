//! Explicit error events inside a streamed body (#748).
//!
//! A provider that refuses a streamed request often answers with an SSE body
//! that holds nothing but an error event: `event: error` plus
//! `data: {"type":"error","error":{…}}` on Anthropic Messages, a
//! `{"error":{…}}` chunk on chat-completions, Google's
//! `{"error":{"code":400,"status":"INVALID_ARGUMENT",…}}` on Interactions, or a
//! bare `{"message":…}` frame after `event: error` from a proxy. Each stream
//! assembler asks `envelope` about every payload it parses and hands a match
//! back as the `{"type":"error","error":{…}}` root that request() already
//! reports, so the provider's type and message reach the api-error path and
//! its retry policy instead of the body failing reassembly and looking like a
//! truncated response.

const std = @import("std");
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

const util = @import("util.zig");

/// Track the SSE `event:` name for the data lines that follow it. Call with
/// every line the assembler's `ssePayload` rejected; returns the new flag.
/// `event: error` sets it, any other event name clears it, other lines keep it.
pub fn namesError(raw_line: []const u8, prev: bool) bool {
    const line = std.mem.trim(u8, raw_line, " \t\r");
    if (!std.mem.startsWith(u8, line, "event:")) return prev;
    return std.mem.eql(u8, std.mem.trim(u8, line["event:".len..], " \t"), "error");
}

fn isError(v: ?Value) bool {
    const t = v orelse return false;
    return t == .string and std.mem.eql(u8, t.string, "error");
}

/// The `error` member when it carries anything (`"error": null` is a normal
/// chat-completions chunk on some providers).
fn errorField(obj: ObjectMap) ?Value {
    const e = obj.get("error") orelse return null;
    return switch (e) {
        .object, .string => e,
        else => null,
    };
}

/// True when this parsed payload is an explicit error event: it is typed
/// `error` (`type` or Interactions' `event_type`), carries a non-null `error`
/// member, or arrived under an `event: error` name.
pub fn isErrorEvent(obj: ObjectMap, named_error: bool) bool {
    return named_error or isError(obj.get("type")) or isError(obj.get("event_type")) or errorField(obj) != null;
}

/// The `{"type":"error","error":{type,message,code,…}}` envelope for an error
/// event, deep-copied onto `arena`, or null when `obj` is an ordinary event.
/// Nested `error` fields win; top-level `message`/`code` (Responses-style and
/// bare proxy frames) fill gaps; Google's `status` stands in for a missing
/// `type` so deterministic classes like INVALID_ARGUMENT stay recognizable.
pub fn envelope(arena: std.mem.Allocator, obj: ObjectMap, named_error: bool) !?ObjectMap {
    if (!isErrorEvent(obj, named_error)) return null;
    var inner: ObjectMap = .empty;
    if (errorField(obj)) |e| switch (e) {
        .object => inner = (try util.dupeJsonValue(arena, e)).object,
        .string => |s| try inner.put(arena, "message", .{ .string = try arena.dupe(u8, s) }),
        else => {},
    };
    for ([_][]const u8{ "message", "code" }) |k| if (inner.get(k) == null) if (obj.get(k)) |v| switch (v) {
        .string, .integer => try inner.put(arena, k, try util.dupeJsonValue(arena, v)),
        else => {},
    };
    if (inner.get("type") == null) if (inner.get("status")) |s| if (s == .string) try inner.put(arena, "type", s);
    var env: ObjectMap = .empty;
    try env.put(arena, "type", .{ .string = "error" });
    try env.put(arena, "error", .{ .object = inner });
    if (obj.get("request_id")) |r| if (r == .string) try env.put(arena, "request_id", .{ .string = try arena.dupe(u8, r.string) });
    return env;
}

/// `error.type` from an envelope, or "" — the class name request() and the
/// retry classifiers read.
pub fn errorType(env: ObjectMap) []const u8 {
    const e = env.get("error") orelse return "";
    if (e != .object) return "";
    const t = e.object.get("type") orelse return "";
    return if (t == .string) t.string else "";
}

fn parse(arena: std.mem.Allocator, payload: []const u8) !ObjectMap {
    return (try std.json.parseFromSliceLeaky(Value, arena, payload, .{})).object;
}

test "#748: envelope recognizes each error event shape and preserves type and message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const anth = (try envelope(a, try parse(a, "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"bad tool schema\"},\"request_id\":\"req_1\"}"), false)).?;
    try std.testing.expectEqualStrings("invalid_request_error", errorType(anth));
    try std.testing.expectEqualStrings("bad tool schema", anth.get("error").?.object.get("message").?.string);
    try std.testing.expectEqualStrings("req_1", anth.get("request_id").?.string);

    const google = (try envelope(a, try parse(a, "{\"error\":{\"code\":400,\"message\":\"Request contains an invalid argument.\",\"status\":\"INVALID_ARGUMENT\"}}"), false)).?;
    try std.testing.expectEqualStrings("INVALID_ARGUMENT", errorType(google));

    const string_err = (try envelope(a, try parse(a, "{\"error\":\"model not allowed\"}"), false)).?;
    try std.testing.expectEqualStrings("model not allowed", string_err.get("error").?.object.get("message").?.string);

    // A bare frame is an error only because the SSE event named it one.
    const bare = "{\"message\":\"Overloaded\",\"code\":\"overloaded\"}";
    try std.testing.expect((try envelope(a, try parse(a, bare), false)) == null);
    const named = (try envelope(a, try parse(a, bare), true)).?;
    try std.testing.expectEqualStrings("Overloaded", named.get("error").?.object.get("message").?.string);
    try std.testing.expectEqualStrings("overloaded", named.get("error").?.object.get("code").?.string);

    // Ordinary events stay ordinary.
    try std.testing.expect((try envelope(a, try parse(a, "{\"choices\":[],\"error\":null}"), false)) == null);
    try std.testing.expect((try envelope(a, try parse(a, "{\"type\":\"message_start\",\"message\":{}}"), false)) == null);
}

test "#748: namesError follows the SSE event name" {
    try std.testing.expect(namesError("event: error\r", false));
    try std.testing.expect(namesError("event:error", false));
    try std.testing.expect(!namesError("event: message_start", true));
    try std.testing.expect(namesError(": keep-alive", true));
    try std.testing.expect(!namesError("id: 7", false));
}

const Agent = @import("agent.zig").Agent;

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

test "#748: error-only Anthropic SSE becomes an error root on every frame shape" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var agent = testAgent(arena_state.allocator());
    const assemble = @import("anthropic_assemble.zig").assembleAnthropic;
    const typed = (try assemble(&agent, "event: error\n" ++
        "data: {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"tools.0: name too long\"}}\n\n")).?;
    try std.testing.expectEqualStrings("invalid_request_error", errorType(typed));
    try std.testing.expectEqualStrings("tools.0: name too long", typed.get("error").?.object.get("message").?.string);

    // A compatible proxy that drops `type` used to reassemble to null and fall
    // through to the unparseable/truncated-body path.
    const untyped = (try assemble(&agent, "event: error\n" ++
        "data: {\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n")).?;
    try std.testing.expectEqualStrings("error", untyped.get("type").?.string);
    try std.testing.expectEqualStrings("overloaded_error", errorType(untyped));

    const bare = (try assemble(&agent, "event: error\ndata: {\"message\":\"upstream rejected the request\"}\n\n")).?;
    try std.testing.expectEqualStrings("upstream rejected the request", bare.get("error").?.object.get("message").?.string);
}

test "#748: error-only Interactions SSE is an error root, not an empty interaction" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var agent = testAgent(arena_state.allocator());
    const assemble = @import("interactions_stream.zig").assemble;
    const root = (try assemble(&agent, "event: error\n" ++
        "data: {\"event_type\":\"error\",\"error\":{\"code\":400,\"message\":\"Request contains an invalid argument.\",\"status\":\"INVALID_ARGUMENT\"}}\n\n" ++
        "data: [DONE]\n")).?;
    try std.testing.expectEqualStrings("error", root.get("type").?.string);
    try std.testing.expectEqualStrings("INVALID_ARGUMENT", errorType(root));
    try std.testing.expectEqualStrings("Request contains an invalid argument.", root.get("error").?.object.get("message").?.string);
    try std.testing.expect(root.get("steps") == null);

    // A failed interaction carries its error inside the interaction object.
    const failed = (try assemble(&agent, "event: interaction.completed\n" ++
        "data: {\"event_type\":\"interaction.completed\",\"interaction\":{\"id\":\"v1_x\",\"status\":\"failed\",\"error\":{\"code\":503,\"message\":\"The model is overloaded.\",\"status\":\"UNAVAILABLE\"}}}\n\n")).?;
    try std.testing.expectEqualStrings("UNAVAILABLE", errorType(failed));
    try std.testing.expectEqualStrings("The model is overloaded.", failed.get("error").?.object.get("message").?.string);
}

test "#748: error-only chat-completions SSE keeps a string error and a bare named frame" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var agent = testAgent(arena_state.allocator());
    const str_err = (try agent.assembleOpenAI("data: {\"error\":\"tool_choice must be auto\"}\n\ndata: [DONE]\n")).?;
    try std.testing.expectEqualStrings("tool_choice must be auto", str_err.get("error").?.object.get("message").?.string);
    const named = (try agent.assembleOpenAI("event: error\ndata: {\"message\":\"Provider returned error\",\"code\":502}\n\n")).?;
    try std.testing.expectEqualStrings("Provider returned error", named.get("error").?.object.get("message").?.string);
}
