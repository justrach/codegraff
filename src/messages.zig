//! Wire-format message construction + history normalization: build
//! user/assistant/tool_result messages in each provider's shape, scrub invalid
//! UTF-8 so content never serializes as a byte-int array, and coerce resumed
//! Responses/OpenAI tool outputs back to strings (#95/#99). Split out of
//! main.zig (600-line goal). Back-imports main for Provider (.Kind) and
//! utf8Prefix (used by the Responses output cap).

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const root = @import("main.zig");
const provider_mod = @import("provider.zig");
const util = @import("util.zig");
const Provider = provider_mod.Provider;
const utf8Prefix = util.utf8Prefix;

pub fn textMessage(arena: Allocator, role: []const u8, text: []const u8) !Value {
    var msg: std.json.ObjectMap = .empty;
    try msg.put(arena, "role", .{ .string = role });
    try msg.put(arena, "content", .{ .string = try arena.dupe(u8, text) });
    return .{ .object = msg };
}

/// Build the message appended to the conversation after a tool runs, shaped
/// for each provider's request body. The tool's result text is ALWAYS written
/// as a JSON string (`.{ .string = ... }`) — never a raw `[]u8` handed to the
/// serializer, which std.json would emit as an array of integers and the API
/// would reject (`'input[N].output[0]': expected an object, got an integer`).
/// anthropic returns a `tool_result` content block (the caller wraps it in a
/// user message); openai returns a `tool` role message; responses returns a
/// `function_call_output` item. Error reporting differs per wire format:
/// anthropic carries a separate `is_error` flag, openai inlines an `[error]`
/// prefix, and responses has no error channel (text only).
pub fn toolResultMessage(arena: Allocator, kind: Provider.Kind, call_id: []const u8, raw_text: []const u8, is_error: bool) !Value {
    // Scrub raw bytes (binary tool output etc.) at the source so the result is a
    // valid JSON string, not a byte-integer array the API rejects.
    const text = sanitizeUtf8(arena, raw_text);
    var obj: std.json.ObjectMap = .empty;
    switch (kind) {
        .anthropic => {
            try obj.put(arena, "type", .{ .string = "tool_result" });
            try obj.put(arena, "tool_use_id", .{ .string = call_id });
            try obj.put(arena, "content", .{ .string = text });
            if (is_error) try obj.put(arena, "is_error", .{ .bool = true });
        },
        .openai => {
            try obj.put(arena, "role", .{ .string = "tool" });
            try obj.put(arena, "tool_call_id", .{ .string = call_id });
            const body = if (is_error)
                try std.fmt.allocPrint(arena, "[error] {s}", .{text})
            else
                text;
            try obj.put(arena, "content", .{ .string = body });
        },
        .responses => {
            try obj.put(arena, "type", .{ .string = "function_call_output" });
            try obj.put(arena, "call_id", .{ .string = call_id });
            try obj.put(arena, "output", .{ .string = text });
        },
    }
    return .{ .object = obj };
}

/// The Responses API hard-caps `function_call_output.output` at this length; an
/// oversized tool result (a big webfetch/bash/codedb/file read) is rejected
/// ("output: array too long, max 16384") and, since it's already in history,
/// wedges every later turn — the size sibling of #95's type bug.
const responses_output_cap = 16384;

/// Return a valid-UTF-8 copy of `s`, replacing each invalid byte with '?'.
/// std.json renders an invalid-UTF-8 string as a JSON array of byte-integers,
/// which every chat API rejects (`messages[N]: invalid type: integer X, expected
/// ...ContentBlock`). Tool output (bash, file reads, MCP, webfetch) is the usual
/// source of raw bytes, so any externally-sourced content must pass through this
/// before it reaches the serializer. Returns `s` unchanged when already valid.
fn sanitizeUtf8(arena: Allocator, s: []const u8) []const u8 {
    if (std.unicode.utf8ValidateSlice(s)) return s;
    const buf = arena.dupe(u8, s) catch return "";
    var i: usize = 0;
    while (i < buf.len) {
        const n = std.unicode.utf8ByteSequenceLength(buf[i]) catch {
            buf[i] = '?';
            i += 1;
            continue;
        };
        if (i + n > buf.len or !std.unicode.utf8ValidateSlice(buf[i .. i + n])) {
            buf[i] = '?';
            i += 1;
            continue;
        }
        i += n;
    }
    return buf;
}

/// Recursively scrub every string in a JSON value to valid UTF-8, in place.
fn sanitizeValueUtf8(arena: Allocator, v: *Value) void {
    switch (v.*) {
        .string => |s| {
            if (!std.unicode.utf8ValidateSlice(s)) v.* = .{ .string = sanitizeUtf8(arena, s) };
        },
        .array => |*arr| for (arr.items) |*item| sanitizeValueUtf8(arena, item),
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |e| sanitizeValueUtf8(arena, e.value_ptr);
        },
        else => {},
    }
}

/// Send-time safety net across EVERY wire format: scrub all message content to
/// valid UTF-8. A tool result carrying raw bytes (or poisoned history loaded
/// from a session) would otherwise serialize as a byte-integer array and the API
/// rejects the whole turn, replayed forever (the `messages[N]: invalid type:
/// integer` family). In place, so it self-heals stored history too.
pub fn sanitizeMessagesUtf8(arena: Allocator, messages: *std.json.Array) void {
    for (messages.items) |*m| sanitizeValueUtf8(arena, m);
}

/// #95 + size cap: coerce any malformed Responses `function_call_output.output`
/// in `messages` to a valid JSON string, AND truncate output longer than
/// `responses_output_cap`, in place. The Responses API rejects scalar/array
/// outputs ("expected an object, got an integer") and over-long ones ("array
/// too long") alike — either poisons history and bricks the gpt-5.5 session,
/// replayed every turn. toolResultMessage already emits strings; this is the
/// send-time safety net for any item that reached history malformed or
/// oversized. No-op for valid strings within the cap.
/// Chat `{role, content: string}` is accepted as the only Responses `input`
/// item. Mixed with `output_text` / `function_call` items (the nudge resend
/// after `closeCodexWs`) it 400s. Promote those strings to typed items.
fn coerceChatStringToResponses(arena: Allocator, m: *Value) void {
    if (m.* != .object) return;
    if (m.object.get("type")) |t| if (t == .string) return;
    const role_v = m.object.get("role") orelse return;
    if (role_v != .string) return;
    const role = role_v.string;
    if (!std.mem.eql(u8, role, "user") and !std.mem.eql(u8, role, "assistant")) return;
    const content = m.object.get("content") orelse return;
    if (content != .string) return;
    const block_type: []const u8 = if (std.mem.eql(u8, role, "user")) "input_text" else "output_text";
    var block: std.json.ObjectMap = .empty;
    block.put(arena, "type", .{ .string = block_type }) catch return;
    block.put(arena, "text", .{ .string = content.string }) catch return;
    var blocks: std.json.Array = .init(arena);
    blocks.append(.{ .object = block }) catch return;
    m.object.put(arena, "type", .{ .string = "message" }) catch return;
    m.object.put(arena, "content", .{ .array = blocks }) catch return;
}

pub fn isResponsesInputText(msg: Value, want: []const u8) bool {
    if (msg != .object) return false;
    const typ = msg.object.get("type") orelse return false;
    const role = msg.object.get("role") orelse return false;
    const content = msg.object.get("content") orelse return false;
    if (typ != .string or role != .string or content != .array) return false;
    if (!std.mem.eql(u8, typ.string, "message") or !std.mem.eql(u8, role.string, "user")) return false;
    if (content.array.items.len == 0 or content.array.items[0] != .object) return false;
    const block = content.array.items[0].object;
    const bt = block.get("type") orelse return false;
    const tx = block.get("text") orelse return false;
    return bt == .string and tx == .string and
        std.mem.eql(u8, bt.string, "input_text") and std.mem.eql(u8, tx.string, want);
}

pub fn normalizeResponsesHistory(arena: Allocator, messages: *std.json.Array) void {
    for (messages.items) |*m| {
        if (m.* != .object) continue;
        coerceChatStringToResponses(arena, m);
        const t = m.object.get("type") orelse continue;
        if (t != .string) continue;
        // Codex re-parses `arguments` as JSON. An object/array here (some
        // providers emit it parsed) makes the next body `Invalid body:
        // failed to parse JSON value` (#711).
        if (std.mem.eql(u8, t.string, "function_call")) {
            coerceFieldToString(arena, m, "arguments");
            continue;
        }
        if (!std.mem.eql(u8, t.string, "function_call_output")) continue;
        const out = m.object.get("output") orelse continue;
        if (out == .string and out.string.len <= responses_output_cap) continue; // valid + within cap
        const s = if (out == .string) out.string else jsonValueString(arena, out);
        const capped = if (s.len > responses_output_cap)
            (std.fmt.allocPrint(arena, "{s}\n[truncated: the Responses API caps tool output at {d} chars — read/fetch a smaller range]", .{ utf8Prefix(s, responses_output_cap - 112), responses_output_cap }) catch utf8Prefix(s, responses_output_cap))
        else
            s;
        m.object.put(arena, "output", .{ .string = capped }) catch {};
    }
}

fn coerceFieldToString(arena: Allocator, m: *Value, field: []const u8) void {
    const v = m.object.get(field) orelse return;
    if (v == .string) return;
    m.object.put(arena, field, .{ .string = jsonValueString(arena, v) }) catch {};
}

/// #99: the chat-completions sibling of normalizeResponsesHistory. A resumed
/// session can carry a `role:"tool"` message whose `content` is a byte-integer
/// array (e.g. [61,61,61] — raw tool bytes that reached history as JSON ints) or
/// a bare scalar. OpenAI-compatible providers reject it
/// (`messages[N].content[0].type: cannot be empty`) and, because it sits in
/// saved history, every later turn fails — the same wedge as #95, on the other
/// wire format. Coerce such content back to a string in place. No-op for valid
/// string content and for arrays of typed content-block objects (real blocks).
pub fn normalizeOpenAIHistory(arena: Allocator, messages: *std.json.Array) void {
    for (messages.items) |*m| {
        if (m.* != .object) continue;
        const role = m.object.get("role") orelse continue;
        if (role != .string or !std.mem.eql(u8, role.string, "tool")) continue;
        const content = m.object.get("content") orelse continue;
        if (content == .string) continue; // already valid
        if (content == .array and content.array.items.len > 0) {
            var all_objects = true;
            for (content.array.items) |it| if (it != .object) {
                all_objects = false;
                break;
            };
            if (all_objects) continue; // legitimate typed content blocks
        }
        const s = sanitizeUtf8(arena, toolContentString(arena, content));
        m.object.put(arena, "content", .{ .string = s }) catch {};
    }
}

/// Best-effort decode of a non-string tool `content` value to a string. A pure
/// byte-integer array (every item an int in 0..255) decodes back to its bytes
/// (so [61,61,61] → "==="); anything else is JSON-encoded.
fn toolContentString(arena: Allocator, v: Value) []const u8 {
    if (v == .array) {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(arena);
        for (v.array.items) |it| {
            if (it == .integer and it.integer >= 0 and it.integer <= 255) {
                bytes.append(arena, @intCast(it.integer)) catch return jsonValueString(arena, v);
            } else {
                return jsonValueString(arena, v);
            }
        }
        return arena.dupe(u8, bytes.items) catch jsonValueString(arena, v);
    }
    return jsonValueString(arena, v);
}

test "normalizeOpenAIHistory: byte-array/scalar tool content coerced to string (#99)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var msgs = std.json.Array.init(arena);
    // poison item: role:"tool" content is a byte-integer array ([61,61,61] = "===")
    var bytearr: std.json.ObjectMap = .empty;
    try bytearr.put(arena, "role", .{ .string = "tool" });
    try bytearr.put(arena, "tool_call_id", .{ .string = "c1" });
    var inner = std.json.Array.init(arena);
    try inner.append(.{ .integer = 61 });
    try inner.append(.{ .integer = 61 });
    try inner.append(.{ .integer = 61 });
    try bytearr.put(arena, "content", .{ .array = inner });
    try msgs.append(.{ .object = bytearr });
    // bare scalar content → stringified
    var scalar: std.json.ObjectMap = .empty;
    try scalar.put(arena, "role", .{ .string = "tool" });
    try scalar.put(arena, "content", .{ .integer = 42 });
    try msgs.append(.{ .object = scalar });
    // valid string tool message → untouched
    var ok_msg: std.json.ObjectMap = .empty;
    try ok_msg.put(arena, "role", .{ .string = "tool" });
    try ok_msg.put(arena, "content", .{ .string = "hello" });
    try msgs.append(.{ .object = ok_msg });
    // non-tool (user) message with array content → untouched
    var user: std.json.ObjectMap = .empty;
    try user.put(arena, "role", .{ .string = "user" });
    var ublocks = std.json.Array.init(arena);
    var blk: std.json.ObjectMap = .empty;
    try blk.put(arena, "type", .{ .string = "text" });
    try blk.put(arena, "text", .{ .string = "hi" });
    try ublocks.append(.{ .object = blk });
    try user.put(arena, "content", .{ .array = ublocks });
    try msgs.append(.{ .object = user });

    normalizeOpenAIHistory(arena, &msgs);

    try std.testing.expect(msgs.items[0].object.get("content").? == .string);
    try std.testing.expectEqualStrings("===", msgs.items[0].object.get("content").?.string);
    try std.testing.expect(msgs.items[1].object.get("content").? == .string);
    try std.testing.expectEqualStrings("42", msgs.items[1].object.get("content").?.string);
    try std.testing.expectEqualStrings("hello", msgs.items[2].object.get("content").?.string);
    try std.testing.expect(msgs.items[3].object.get("content").? == .array); // user multimodal stays an array
}
/// JSON-encode a Value to an owned string (best-effort; "" on failure).
fn jsonValueString(arena: Allocator, v: Value) []const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.write(v) catch return "";
    return aw.toOwnedSlice() catch "";
}

test "normalizeResponsesHistory: scalar/array outputs coerced to string (#95)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var msgs = std.json.Array.init(arena);
    var scalar: std.json.ObjectMap = .empty; // the poisoned item: output is a bare integer
    try scalar.put(arena, "type", .{ .string = "function_call_output" });
    try scalar.put(arena, "output", .{ .integer = 42 });
    try msgs.append(.{ .object = scalar });
    var arr: std.json.ObjectMap = .empty; // output as an array → "[42]"
    try arr.put(arena, "type", .{ .string = "function_call_output" });
    var inner = std.json.Array.init(arena);
    try inner.append(.{ .integer = 42 });
    try arr.put(arena, "output", .{ .array = inner });
    try msgs.append(.{ .object = arr });
    var ok: std.json.ObjectMap = .empty; // valid string → untouched
    try ok.put(arena, "type", .{ .string = "function_call_output" });
    try ok.put(arena, "output", .{ .string = "hello" });
    try msgs.append(.{ .object = ok });

    normalizeResponsesHistory(arena, &msgs);

    try std.testing.expect(msgs.items[0].object.get("output").? == .string);
    try std.testing.expectEqualStrings("42", msgs.items[0].object.get("output").?.string);
    try std.testing.expect(msgs.items[1].object.get("output").? == .string);
    try std.testing.expectEqualStrings("[42]", msgs.items[1].object.get("output").?.string);
    try std.testing.expectEqualStrings("hello", msgs.items[2].object.get("output").?.string);
}

test "normalizeResponsesHistory: oversized output is capped to the Responses limit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var msgs = std.json.Array.init(arena);
    var big: std.json.ObjectMap = .empty; // a 260 KB webfetch-style result
    try big.put(arena, "type", .{ .string = "function_call_output" });
    const huge = try arena.alloc(u8, 260 * 1024);
    @memset(huge, 'x');
    try big.put(arena, "output", .{ .string = huge });
    try msgs.append(.{ .object = big });

    normalizeResponsesHistory(arena, &msgs);

    const out = msgs.items[0].object.get("output").?;
    try std.testing.expect(out == .string);
    try std.testing.expect(out.string.len <= responses_output_cap);
    try std.testing.expect(std.mem.indexOf(u8, out.string, "truncated") != null);
}

test "normalizeResponsesHistory: Chat user/assistant strings become typed items" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var msgs = std.json.Array.init(arena);
    try msgs.append(try textMessage(arena, "user", "Fix stall_notice.py"));
    var typed: std.json.ObjectMap = .empty;
    try typed.put(arena, "type", .{ .string = "message" });
    try typed.put(arena, "role", .{ .string = "assistant" });
    var blocks: std.json.Array = .init(arena);
    var out_block: std.json.ObjectMap = .empty;
    try out_block.put(arena, "type", .{ .string = "output_text" });
    try out_block.put(arena, "text", .{ .string = "I'll read the spec" });
    try blocks.append(.{ .object = out_block });
    try typed.put(arena, "content", .{ .array = blocks });
    try msgs.append(.{ .object = typed });
    try msgs.append(try textMessage(arena, "assistant", "done"));

    normalizeResponsesHistory(arena, &msgs);

    try std.testing.expect(isResponsesInputText(msgs.items[0], "Fix stall_notice.py"));
    try std.testing.expectEqualStrings("message", msgs.items[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("output_text", msgs.items[1].object.get("content").?.array.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("message", msgs.items[2].object.get("type").?.string);
    try std.testing.expectEqualStrings("assistant", msgs.items[2].object.get("role").?.string);
    try std.testing.expectEqualStrings("output_text", msgs.items[2].object.get("content").?.array.items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("done", msgs.items[2].object.get("content").?.array.items[0].object.get("text").?.string);
}
test "sanitizeUtf8 scrubs invalid bytes so content never serializes as a byte-int array" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("ok?", sanitizeUtf8(arena, "ok\x80")); // lone continuation byte -> '?'
    try std.testing.expectEqualStrings("clean", sanitizeUtf8(arena, "clean")); // valid: unchanged
    try std.testing.expectEqualStrings("a\xC3\xA9b", sanitizeUtf8(arena, "a\xC3\xA9b")); // valid 'é' preserved
    try std.testing.expect(std.unicode.utf8ValidateSlice(sanitizeUtf8(arena, "x\xff\xfey")));
    // message-tree scrub: a poisoned tool content becomes valid UTF-8 in place,
    // so the serializer emits a JSON string, not [98,97,100,255].
    var msgs: std.json.Array = .init(arena);
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "role", .{ .string = "tool" });
    try obj.put(arena, "content", .{ .string = "bad\xff" });
    try msgs.append(.{ .object = obj });
    sanitizeMessagesUtf8(arena, &msgs);
    const c = msgs.items[0].object.get("content").?.string;
    try std.testing.expect(std.unicode.utf8ValidateSlice(c));
    try std.testing.expectEqualStrings("bad?", c);
}
test "toolResultMessage: result text serializes as a JSON string in every wire format" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Serialize a built message the same way buildBody does and return the bytes.
    const enc = struct {
        fn run(a: Allocator, msg: Value) ![]u8 {
            var aw: Io.Writer.Allocating = .init(a);
            var s: std.json.Stringify = .{ .writer = &aw.writer };
            try s.write(msg);
            return aw.toOwnedSlice();
        }
    }.run;

    // Responses (codex): result lives in `output`. This is the field that
    // produced "'input[N].output[0]': expected an object, got an integer"
    // when a raw []u8 reached the serializer as a byte array. Assert both the
    // Value tag and the on-the-wire shape are a string, never an array.
    {
        const msg = try toolResultMessage(arena, .responses, "call_1", "hello world", false);
        try std.testing.expect(msg.object.get("output").? == .string);
        try std.testing.expectEqualStrings("function_call_output", msg.object.get("type").?.string);
        try std.testing.expectEqualStrings("call_1", msg.object.get("call_id").?.string);
        const json = try enc(arena, msg);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"output\":\"hello world\"") != null);
        // Guard against the regression directly: output must not be a JSON array.
        try std.testing.expect(std.mem.indexOf(u8, json, "\"output\":[") == null);
    }

    // OpenAI chat-completions: result in `content` (string); errors inline an
    // [error] prefix rather than a separate flag.
    {
        const ok = try toolResultMessage(arena, .openai, "call_2", "result text", false);
        try std.testing.expect(ok.object.get("content").? == .string);
        try std.testing.expectEqualStrings("tool", ok.object.get("role").?.string);
        try std.testing.expectEqualStrings("result text", ok.object.get("content").?.string);

        const err = try toolResultMessage(arena, .openai, "call_2", "boom", true);
        try std.testing.expect(err.object.get("content").? == .string);
        try std.testing.expectEqualStrings("[error] boom", err.object.get("content").?.string);
    }

    // Anthropic: result in `content` (string) block; errors carry a separate
    // is_error flag that is absent on success.
    {
        const ok = try toolResultMessage(arena, .anthropic, "call_3", "tool said hi", false);
        try std.testing.expect(ok.object.get("content").? == .string);
        try std.testing.expectEqualStrings("tool_result", ok.object.get("type").?.string);
        try std.testing.expectEqualStrings("call_3", ok.object.get("tool_use_id").?.string);
        try std.testing.expect(ok.object.get("is_error") == null);

        const err = try toolResultMessage(arena, .anthropic, "call_3", "nope", true);
        try std.testing.expect(err.object.get("is_error").?.bool == true);
        const json = try enc(arena, err);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"content\":\"nope\"") != null);
    }
}

test "#711: parallel error bash + object-shaped output still stringify as JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const gh404 =
        \\gh: Not Found (HTTP 404)
        \\{"message":"Not Found","documentation_url":"https://docs.github.com/rest/pulls/comments#list-review-comments-on-a-pull-request"}
        \\
        \\[exit code 1]
    ;
    var msgs = std.json.Array.init(arena);
    var fc: std.json.ObjectMap = .empty;
    try fc.put(arena, "type", .{ .string = "function_call" });
    try fc.put(arena, "call_id", .{ .string = "5" });
    try fc.put(arena, "name", .{ .string = "bash" });
    var args_obj: std.json.ObjectMap = .empty;
    try args_obj.put(arena, "command", .{ .string = "gh api repos/justrach/codegraff/pulls/1/comments" });
    try fc.put(arena, "arguments", .{ .object = args_obj });
    try msgs.append(.{ .object = fc });
    try msgs.append(try toolResultMessage(arena, .responses, "5", gh404, true));
    try msgs.append(try toolResultMessage(arena, .responses, "6", gh404, true));
    var poison: std.json.ObjectMap = .empty;
    try poison.put(arena, "type", .{ .string = "function_call_output" });
    try poison.put(arena, "call_id", .{ .string = "7" });
    var parsed_err: std.json.ObjectMap = .empty;
    try parsed_err.put(arena, "message", .{ .string = "Not Found" });
    try poison.put(arena, "output", .{ .object = parsed_err });
    try msgs.append(.{ .object = poison });

    sanitizeMessagesUtf8(arena, &msgs);
    normalizeResponsesHistory(arena, &msgs);

    try std.testing.expect(msgs.items[0].object.get("arguments").? == .string);
    try std.testing.expect(std.mem.indexOf(u8, msgs.items[0].object.get("arguments").?.string, "gh api") != null);
    try std.testing.expect(msgs.items[1].object.get("output").? == .string);
    try std.testing.expect(msgs.items[2].object.get("output").? == .string);
    try std.testing.expect(msgs.items[3].object.get("output").? == .string);
    try std.testing.expect(std.mem.indexOf(u8, msgs.items[3].object.get("output").?.string, "Not Found") != null);

    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("input");
    try s.write(Value{ .array = msgs });
    try s.endObject();
    const body = aw.writer.buffered();
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
}
