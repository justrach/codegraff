//! MCP form elicitation for the signed Codex Computer Use bridge (#768).
//!
//! `node_repl` / `@oai/sky` call `nodeRepl.createElicitation` before desktop
//! work. Clients that advertise no form capability fail the JS call before any
//! accessibility state returns. Graff advertises form mode and answers
//! `elicitation/create` on the stdio request-scoped channel:
//!
//! - read-only `get_app_state` (especially `disableDiff: true`) is accepted
//!   with schema defaults — inspect is not a confirmation prompt;
//! - URL mode and mutating sky input are declined with an actionable fallback
//!   (desktop `computer` tool, reconnect MCP). Do not embed V8 or spoof Codex.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const mcp_protocol = @import("mcp_protocol.zig");
const mcp_stdio = @import("mcp_stdio.zig");
const util = @import("util.zig");

/// Legacy `initialize` `capabilities` object. `{form:{}}` is the 2025-11-25
/// form-only shape; an empty `elicitation` object is also form-only, but
/// node_repl checks the named form key before calling createElicitation.
pub const client_capabilities = "{\"elicitation\":{\"form\":{}}}";

pub const initialize_params =
    "{\"protocolVersion\":\"" ++ mcp_protocol.legacy_protocol ++
    "\",\"capabilities\":" ++ client_capabilities ++
    ",\"clientInfo\":{\"name\":\"simple-harness\",\"version\":\"0.1\"}}";

/// Shown when form elicitation is required and we cannot accept the request.
pub const fallback =
    \\Computer Use form elicitation is unavailable or was declined.
    \\
    \\For a read-only accessibility inspect, call sky.get_app_state({ app: "<name>", disableDiff: true }). Graff advertises MCP form elicitation and accepts that inspect without a form prompt. Reconnect MCP (`/mcp trust`) if this session started before that capability existed.
    \\
    \\If you need a snapshot without the Codex node_repl bridge, use the desktop `computer` tool (action: snapshot or apps) after Computer use is enabled in the Codegraff app menu. Do not use the plugin's raw Computer Use MCP client or synthesize OS events.
;

const mutating = [_][]const u8{
    "sky.click",
    "sky.type",
    "sky.press",
    "sky.scroll",
    "sky.hotkey",
    "sky.drag",
    "sky.setValue",
    "sky.set_value",
    "sky.keyPress",
    "sky.key_press",
    ".click(",
    ".typeText(",
    ".pressKey(",
    ".setValue(",
};

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn mutatingSky(source: []const u8) bool {
    for (mutating) |token| if (contains(source, token)) return true;
    return false;
}

/// True when the in-flight `tools/call` is a read-only Computer Use inspect.
pub fn readonlyAppState(source: []const u8) bool {
    if (!contains(source, "get_app_state")) return false;
    return !mutatingSky(source);
}

fn readonlyMessage(params: Value) bool {
    if (params != .object) return false;
    const message = params.object.get("message") orelse return false;
    if (message != .string) return false;
    const m = message.string;
    const hints = [_][]const u8{
        "get_app_state",
        "app state",
        "app-state",
        "accessibility",
        "disableDiff",
        "read-only",
        "read only",
        "readonly",
    };
    for (hints) |h| if (contains(m, h)) return true;
    return false;
}

fn urlMode(params: Value) bool {
    if (params != .object) return false;
    const mode = params.object.get("mode") orelse return false;
    return mode == .string and std.mem.eql(u8, mode.string, "url");
}

pub const Action = enum { accept, decline };

pub fn decide(source: []const u8, params: Value) Action {
    if (urlMode(params)) return .decline;
    if (readonlyAppState(source) or readonlyMessage(params)) return .accept;
    return .decline;
}

fn sensitiveName(name: []const u8) bool {
    const keys = [_][]const u8{ "password", "secret", "token", "credential", "api_key", "apikey" };
    for (keys) |k| {
        if (util.indexOfIgnoreCase(name, k) != null) return true;
    }
    return false;
}

fn writeDefault(w: *Io.Writer, schema: Value) bool {
    if (schema != .object) return false;
    if (schema.object.get("default")) |d| {
        var s: std.json.Stringify = .{ .writer = w };
        s.write(d) catch return false;
        return true;
    }
    const typ = if (schema.object.get("type")) |t| (if (t == .string) t.string else "") else "";
    if (std.mem.eql(u8, typ, "boolean")) {
        w.writeAll("true") catch return false;
        return true;
    }
    if (std.mem.eql(u8, typ, "number") or std.mem.eql(u8, typ, "integer")) {
        w.writeAll("0") catch return false;
        return true;
    }
    if (std.mem.eql(u8, typ, "array")) {
        w.writeAll("[]") catch return false;
        return true;
    }
    if (schema.object.get("enum")) |en| {
        if (en == .array and en.array.items.len > 0) {
            var s: std.json.Stringify = .{ .writer = w };
            s.write(en.array.items[0]) catch return false;
            return true;
        }
    }
    if (std.mem.eql(u8, typ, "string") or typ.len == 0) {
        w.writeAll("\"\"") catch return false;
        return true;
    }
    return false;
}

fn requiredHas(schema: Value, name: []const u8) bool {
    if (schema != .object) return false;
    const req = schema.object.get("required") orelse return false;
    if (req != .array) return false;
    for (req.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, name)) return true;
    }
    return false;
}

/// Schema defaults (or safe primitives) for an accept. Null if a required
/// secret field cannot be filled.
pub fn acceptContent(arena: Allocator, schema: ?Value) ?[]const u8 {
    const root = schema orelse return "{}";
    if (root != .object) return "{}";
    const props = root.object.get("properties") orelse return "{}";
    if (props != .object) return "{}";

    var aw: Io.Writer.Allocating = .init(arena);
    aw.writer.writeByte('{') catch return null;
    var first = true;
    var it = props.object.iterator();
    while (it.next()) |entry| {
        if (sensitiveName(entry.key_ptr.*) and requiredHas(root, entry.key_ptr.*)) return null;
        if (!first) aw.writer.writeByte(',') catch return null;
        first = false;
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        s.write(entry.key_ptr.*) catch return null;
        aw.writer.writeByte(':') catch return null;
        if (!writeDefault(&aw.writer, entry.value_ptr.*)) return null;
    }
    aw.writer.writeByte('}') catch return null;
    return aw.toOwnedSlice() catch null;
}

pub fn looksUnavailable(text: []const u8) bool {
    return contains(text, "createElicitation is unavailable") or
        contains(text, "does not support form elicitation") or
        contains(text, "Client does not support elicitation");
}

pub fn surface(alloc: Allocator, text: []const u8) ![]u8 {
    if (looksUnavailable(text)) return alloc.dupe(u8, fallback);
    return alloc.dupe(u8, text);
}

fn incomingMethod(msg: Value) ?[]const u8 {
    if (msg != .object) return null;
    if (msg.object.get("result") != null or msg.object.get("error") != null) return null;
    const method = msg.object.get("method") orelse return null;
    return if (method == .string) method.string else null;
}

fn incomingId(msg: Value) ?i64 {
    if (msg != .object) return null;
    const id = msg.object.get("id") orelse return null;
    return if (id == .integer) id.integer else null;
}

fn incomingParams(msg: Value) Value {
    if (msg != .object) return .null;
    return msg.object.get("params") orelse .null;
}

pub fn replyBody(arena: Allocator, id: i64, action: Action, content: []const u8) ![]u8 {
    return switch (action) {
        .accept => std.fmt.allocPrint(arena,
            \\{{"jsonrpc":"2.0","id":{d},"result":{{"action":"accept","content":{s}}}}}
        , .{ id, content }),
        .decline => std.fmt.allocPrint(arena,
            \\{{"jsonrpc":"2.0","id":{d},"result":{{"action":"decline"}}}}
        , .{id}),
    };
}

/// If `line` is `elicitation/create`, write a JSON-RPC result and return true.
pub fn replyStdio(w: *Io.Writer, arena: Allocator, line: []const u8, source: []const u8) !bool {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return false;
    const msg = std.json.parseFromSliceLeaky(Value, arena, trimmed, .{ .allocate = .alloc_always }) catch return false;
    const method = incomingMethod(msg) orelse return false;
    const id = incomingId(msg) orelse return false;
    if (!std.mem.eql(u8, method, "elicitation/create")) return false;

    const params = incomingParams(msg);
    var action = decide(source, params);
    var content: []const u8 = "{}";
    if (action == .accept) {
        const schema = if (params == .object) params.object.get("requestedSchema") else null;
        content = acceptContent(arena, schema) orelse {
            action = .decline;
            content = "{}";
        };
    }
    try mcp_stdio.writeRequest(w, try replyBody(arena, id, action, content));
    return true;
}

const testing = std.testing;

test "client capabilities advertise form elicitation (#768)" {
    try testing.expect(contains(client_capabilities, "\"elicitation\""));
    try testing.expect(contains(client_capabilities, "\"form\""));
    try testing.expect(contains(initialize_params, client_capabilities));
    try testing.expect(contains(initialize_params, mcp_protocol.legacy_protocol));
}

test "readonlyAppState: get_app_state + disableDiff is inspect-only (#768)" {
    const src =
        \\sky.get_app_state({ app: "Codegraff", disableDiff: true })
    ;
    try testing.expect(readonlyAppState(src));
    try testing.expect(readonlyAppState("{\"code\":\"await sky.get_app_state({app:\\\"X\\\",disableDiff:true})\"}"));
    try testing.expect(readonlyAppState("get_app_state({ app: \"Finder\" })"));
    try testing.expect(!readonlyAppState(""));
    try testing.expect(!readonlyAppState("console.log('hi')"));
}

test "readonlyAppState: mutating sky calls are not inspect-only (#768)" {
    try testing.expect(!readonlyAppState("sky.get_app_state({app:'X'}); sky.click({x:1})"));
    try testing.expect(!readonlyAppState("sky.click({ x: 10, y: 10 })"));
    try testing.expect(!readonlyAppState("sky.get_app_state({ disableDiff: false }); sky.setValue({id:1})"));
}

test "decide accepts read-only inspect and declines URL / input (#768)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const inspect = try std.json.parseFromSliceLeaky(Value, a,
        \\{"message":"Inspect Codegraff app state","requestedSchema":{"type":"object","properties":{}}}
    , .{});
    try testing.expectEqual(Action.accept, decide("sky.get_app_state({disableDiff:true})", inspect));
    try testing.expectEqual(Action.accept, decide("", inspect));

    const url = try std.json.parseFromSliceLeaky(Value, a,
        \\{"mode":"url","message":"Sign in","url":"https://example.invalid"}
    , .{});
    try testing.expectEqual(Action.decline, decide("sky.get_app_state({disableDiff:true})", url));

    const click = try std.json.parseFromSliceLeaky(Value, a,
        \\{"message":"Allow click"}
    , .{});
    try testing.expectEqual(Action.decline, decide("sky.click({x:1,y:2})", click));
}

test "acceptContent fills defaults and refuses required secrets (#768)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqualStrings("{}", acceptContent(a, null).?);

    const empty = try std.json.parseFromSliceLeaky(Value, a,
        \\{"type":"object","properties":{}}
    , .{});
    try testing.expectEqualStrings("{}", acceptContent(a, empty).?);

    const flagged = try std.json.parseFromSliceLeaky(Value, a,
        \\{"type":"object","properties":{"approved":{"type":"boolean","default":true}}}
    , .{});
    try testing.expectEqualStrings("{\"approved\":true}", acceptContent(a, flagged).?);

    const secret = try std.json.parseFromSliceLeaky(Value, a,
        \\{"type":"object","properties":{"password":{"type":"string"}},"required":["password"]}
    , .{});
    try testing.expect(acceptContent(a, secret) == null);
}

test "replyBody: accept carries content, decline names no form fields (#768)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ok = try replyBody(a, 99, .accept, "{}");
    try testing.expect(contains(ok, "\"action\":\"accept\""));
    try testing.expect(contains(ok, "\"content\":{}"));
    const no = try replyBody(a, 7, .decline, "{}");
    try testing.expect(contains(no, "\"action\":\"decline\""));
    try testing.expect(!contains(no, "\"content\""));
}

test "looksUnavailable / surface rewrite the node_repl form-elicitation crash (#768)" {
    const raw = "nodeRepl.createElicitation is unavailable because the MCP client does not support form elicitation";
    try testing.expect(looksUnavailable(raw));
    try testing.expect(!looksUnavailable("app state ok"));

    const rewritten = try surface(testing.allocator, raw);
    defer testing.allocator.free(rewritten);
    try testing.expect(contains(rewritten, "disableDiff: true"));
    try testing.expect(contains(rewritten, "computer"));
    try testing.expect(contains(rewritten, "snapshot"));
    try testing.expect(!contains(rewritten, "createElicitation is unavailable"));

    const passthrough = try surface(testing.allocator, "other MCP error");
    defer testing.allocator.free(passthrough);
    try testing.expectEqualStrings("other MCP error", passthrough);
}

test "replyStdio accepts get_app_state elicitation and writes a JSON-RPC result (#768)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const line =
        \\{"jsonrpc":"2.0","id":42,"method":"elicitation/create","params":{"message":"Inspect","requestedSchema":{"type":"object","properties":{}}}}
    ;
    try testing.expect(try replyStdio(&w, a, line, "sky.get_app_state({ app: \"Codegraff\", disableDiff: true })"));
    const out = w.buffered();
    try testing.expect(contains(out, "\"action\":\"accept\""));
    try testing.expect(std.mem.endsWith(u8, out, "\n"));
}

test "replyStdio declines mutating sky input (#768)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const line =
        \\{"jsonrpc":"2.0","id":3,"method":"elicitation/create","params":{"message":"Click"}}
    ;
    try testing.expect(try replyStdio(&w, a, line, "sky.click({x:1,y:2})"));
    try testing.expect(contains(w.buffered(), "\"action\":\"decline\""));
}

test "replyStdio ignores notifications and ordinary results (#768)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try testing.expect(!try replyStdio(&w, a, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}", ""));
    try testing.expect(!try replyStdio(&w, a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}", ""));
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
}
