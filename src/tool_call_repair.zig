//! Tool calls whose arguments the provider's parser lost.
//!
//! MiMo V2.6 (and other Qwen-coder-style servers) sometimes return a
//! structured tool call whose `arguments` are empty, `{}`, or cut off at a
//! non-string parameter, while the model's real call sits in `content` as
//! `<tool_call><function=NAME><parameter=KEY>VALUE</parameter>…</function>`.
//! Executing `{}` fails, the broken call goes back into history, and the
//! model copies the pattern on every later turn.
//!
//! - `repairCalls` rebuilds a broken call's arguments from the matching
//!   markup (values coerced to the tool schema's types) and removes the
//!   markup from `content`, so neither the UI nor the next request sees it.
//! - `writeMimoTools` sends MiMo plain parameter types: its parser breaks on
//!   nullable unions such as `["integer","null"]`.
//! - `brokenCallLoop` ends a turn whose last three tool batches all failed on
//!   unusable arguments, instead of letting the retries multiply.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const tool_call_args = @import("tool_call_args.zig");

pub const loop_stop_text = "Stopped: the model sent tool calls with unusable arguments three times in a row, so the turn ended instead of retrying. Send a new message to continue, or switch models.";

const Block = struct { name: []const u8, body: []const u8, used: bool = false };

/// `<function=NAME>BODY</function>` spans in `text`, in order. A block cut
/// off before its closing tag runs to the end of the text.
fn blocks(arena: Allocator, text: []const u8) ![]Block {
    var out: std.ArrayList(Block) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, "<function=")) |start| {
        const name_start = start + "<function=".len;
        const name_end = std.mem.indexOfScalarPos(u8, text, name_start, '>') orelse break;
        const body_end = std.mem.indexOfPos(u8, text, name_end, "</function>") orelse text.len;
        const name = std.mem.trim(u8, text[name_start..name_end], " \t\r\n\"'");
        try out.append(arena, .{ .name = name, .body = text[name_end + 1 .. body_end] });
        pos = @min(text.len, body_end + "</function>".len);
    }
    return out.items;
}

/// The declared JSON types of one property schema (`type` string/array, or
/// the `type` of each `anyOf`/`oneOf` branch).
fn wants(prop: ?Value, kind: []const u8) bool {
    const p = prop orelse return false;
    if (p != .object) return false;
    if (p.object.get("type")) |t| switch (t) {
        .string => |s| if (std.mem.eql(u8, s, kind)) return true,
        .array => |a| for (a.items) |item| {
            if (item == .string and std.mem.eql(u8, item.string, kind)) return true;
        },
        else => {},
    };
    for ([_][]const u8{ "anyOf", "oneOf" }) |key| if (p.object.get(key)) |branches| if (branches == .array) {
        for (branches.array.items) |branch| if (wants(branch, kind)) return true;
    };
    return false;
}

/// A `<parameter>` value as the JSON type its schema declares; text otherwise.
fn coerce(arena: Allocator, raw: []const u8, prop: ?Value) Value {
    const t = std.mem.trim(u8, raw, " \t\r\n");
    if (wants(prop, "integer")) if (std.fmt.parseInt(i64, t, 10)) |n| return .{ .integer = n } else |_| {};
    if (wants(prop, "number")) if (std.fmt.parseFloat(f64, t)) |n| return .{ .float = n } else |_| {};
    if (wants(prop, "boolean")) {
        if (std.mem.eql(u8, t, "true")) return .{ .bool = true };
        if (std.mem.eql(u8, t, "false")) return .{ .bool = false };
    }
    if (wants(prop, "array") or wants(prop, "object")) {
        if (std.json.parseFromSliceLeaky(Value, arena, t, .{ .allocate = .alloc_always })) |v| {
            if (v == .array or v == .object) return v;
        } else |_| {}
    }
    // Qwen-coder markup wraps each value in one newline on each side.
    var v = raw;
    if (std.mem.startsWith(u8, v, "\n")) v = v[1..];
    if (std.mem.endsWith(u8, v, "\n")) v = v[0 .. v.len - 1];
    return .{ .string = v };
}

/// `properties` of the named tool in a chat-completions tools catalog.
fn properties(catalog: ?Value, name: []const u8) ?std.json.ObjectMap {
    const tools = catalog orelse return null;
    if (tools != .array) return null;
    for (tools.array.items) |tool| {
        if (tool != .object) continue;
        const f = tool.object.get("function") orelse tool;
        if (f != .object) continue;
        const n = f.object.get("name") orelse continue;
        if (n != .string or !std.mem.eql(u8, n.string, name)) continue;
        const params = f.object.get("parameters") orelse return null;
        if (params != .object) return null;
        const props = params.object.get("properties") orelse return null;
        return if (props == .object) props.object else null;
    }
    return null;
}

/// JSON-object arguments from one block's `<parameter=K>V</parameter>` pairs.
fn argumentsFrom(arena: Allocator, body: []const u8, props: ?std.json.ObjectMap) !?[]const u8 {
    var obj: std.json.ObjectMap = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, "<parameter=")) |start| {
        const key_start = start + "<parameter=".len;
        const key_end = std.mem.indexOfScalarPos(u8, body, key_start, '>') orelse break;
        const next = std.mem.indexOfPos(u8, body, key_end, "<parameter=") orelse body.len;
        const close = std.mem.indexOfPos(u8, body, key_end, "</parameter>");
        const value_end = if (close) |c| @min(c, next) else next;
        const key = std.mem.trim(u8, body[key_start..key_end], " \t\r\n\"'");
        const prop = if (props) |p| p.get(key) else null;
        try obj.put(arena, key, coerce(arena, body[key_end + 1 .. value_end], prop));
        pos = if (close) |c| (if (c < next) c + "</parameter>".len else next) else next;
    }
    if (obj.count() == 0) return null;
    return try std.json.Stringify.valueAlloc(arena, Value{ .object = obj }, .{});
}

/// `text` without its tool-call markup (`<tool_call>…</tool_call>` and any
/// bare `<function=…>…</function>`), trimmed.
fn stripMarkup(arena: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (pos < text.len) {
        const wrapped = std.mem.indexOfPos(u8, text, pos, "<tool_call>");
        const bare = std.mem.indexOfPos(u8, text, pos, "<function=");
        const start = if (wrapped != null and (bare == null or wrapped.? <= bare.?)) wrapped.? else bare orelse break;
        const close_tag: []const u8 = if (wrapped != null and start == wrapped.?) "</tool_call>" else "</function>";
        try out.appendSlice(arena, text[pos..start]);
        const end = std.mem.indexOfPos(u8, text, start, close_tag) orelse text.len;
        pos = @min(text.len, end + close_tag.len);
    }
    if (pos < text.len) try out.appendSlice(arena, text[pos..]);
    return std.mem.trim(u8, out.items, " \t\r\n");
}

/// Repair a chat-completions assistant `message` in place. Returns true when
/// it changed (a call's arguments rebuilt, or markup removed from content).
pub fn repairCalls(arena: Allocator, message: *Value, tools_raw: []const u8) !bool {
    if (message.* != .object) return false;
    const content = message.object.get("content") orelse return false;
    if (content != .string or std.mem.indexOf(u8, content.string, "<function=") == null) return false;
    const calls = message.object.getPtr("tool_calls") orelse return false;
    if (calls.* != .array or calls.array.items.len == 0) return false;
    const found = try blocks(arena, content.string);
    if (found.len == 0) return false;
    const catalog = std.json.parseFromSliceLeaky(Value, arena, tools_raw, .{ .allocate = .alloc_always }) catch null;
    for (calls.array.items) |*tc| {
        if (tc.* != .object) continue;
        const f = tc.object.getPtr("function") orelse continue;
        if (f.* != .object) continue;
        const name = if (f.object.get("name")) |n| (if (n == .string) n.string else continue) else continue;
        const args = if (f.object.get("arguments")) |a| (if (a == .string) a.string else "") else "";
        const parsed = tool_call_args.parse(arena, args);
        const broken = !parsed.valid or (parsed.input == .object and parsed.input.object.count() == 0);
        for (found) |*b| {
            if (b.used or !std.mem.eql(u8, b.name, name)) continue;
            b.used = true;
            if (broken) if (try argumentsFrom(arena, b.body, properties(catalog, name))) |fixed| {
                try f.object.put(arena, "arguments", .{ .string = fixed });
            };
            break;
        }
    }
    try message.object.put(arena, "content", .{ .string = try stripMarkup(arena, content.string) });
    return true;
}

/// `schema` with nullable unions collapsed to the plain type, recursively.
fn collapseNullable(arena: Allocator, schema: *Value) !void {
    if (schema.* != .object) return;
    const obj = &schema.object;
    if (obj.getPtr("type")) |t| if (t.* == .array) {
        var other: ?Value = null;
        var others: usize = 0;
        var nullable = false;
        for (t.array.items) |item| {
            if (item == .string and std.mem.eql(u8, item.string, "null")) nullable = true else {
                others += 1;
                other = item;
            }
        }
        if (nullable and others == 1) t.* = other.?;
    };
    if (obj.get("anyOf")) |any| if (any == .array) {
        var keep: ?Value = null;
        var others: usize = 0;
        for (any.array.items) |branch| {
            const null_branch = branch == .object and branch.object.count() == 1 and
                if (branch.object.get("type")) |bt| bt == .string and std.mem.eql(u8, bt.string, "null") else false;
            if (!null_branch) {
                others += 1;
                keep = branch;
            }
        }
        if (others == 1 and others < any.array.items.len and keep.? == .object) {
            _ = obj.orderedRemove("anyOf");
            var it = keep.?.object.iterator();
            while (it.next()) |e| if (obj.get(e.key_ptr.*) == null) try obj.put(arena, e.key_ptr.*, e.value_ptr.*);
        }
    };
    if (obj.getPtr("properties")) |props| if (props.* == .object) {
        var it = props.object.iterator();
        while (it.next()) |e| try collapseNullable(arena, e.value_ptr);
    };
    if (obj.getPtr("items")) |items| try collapseNullable(arena, items);
}

/// Chat-completions tools for MiMo: plain parameter types, no nullable unions.
pub fn writeMimoTools(s: *std.json.Stringify, arena: Allocator, raw: []const u8) !void {
    const value = std.json.parseFromSliceLeaky(Value, arena, raw, .{ .allocate = .alloc_always }) catch return s.print("{s}", .{raw});
    if (value != .array) return s.print("{s}", .{raw});
    for (value.array.items) |*tool| {
        if (tool.* != .object) continue;
        const f = tool.object.getPtr("function") orelse continue;
        if (f.* != .object) continue;
        if (f.object.getPtr("parameters")) |p| try collapseNullable(arena, p);
    }
    try s.write(value);
}

/// Chat-completions tools for this seat: Kimi's stricter validator, MiMo's
/// plain types, or the root-schema repair every other endpoint gets.
pub fn writeChatTools(s: *std.json.Stringify, arena: Allocator, raw: []const u8, provider_id: []const u8, model: []const u8) !void {
    const serde = @import("serde.zig");
    if (std.mem.eql(u8, provider_id, "kimi")) return serde.writeKimiTools(s, arena, raw);
    if (@import("effort_route.zig").mimoRoute(provider_id, model)) return writeMimoTools(s, arena, raw);
    return serde.writeOpenAITools(s, arena, raw);
}

fn unusableResult(content: Value) bool {
    if (content != .string) return false;
    const t = std.mem.trimStart(u8, content.string, " ");
    const body = if (std.mem.startsWith(u8, t, "[error] ")) t["[error] ".len..] else t;
    return std.mem.startsWith(u8, body, tool_call_args.invalid_exec_message) or
        std.mem.startsWith(u8, body, "missing or non-string argument");
}

/// True when the last three tool batches in chat-completions history each
/// failed entirely on unusable arguments.
pub fn brokenCallLoop(messages: []const Value) bool {
    var i = messages.len;
    var batches: usize = 0;
    while (batches < 3) {
        var results: usize = 0;
        while (i > 0) {
            const m = messages[i - 1];
            const role = if (m == .object) (if (m.object.get("role")) |r| (if (r == .string) r.string else "") else "") else "";
            if (!std.mem.eql(u8, role, "tool")) break;
            if (!unusableResult(m.object.get("content") orelse .null)) return false;
            results += 1;
            i -= 1;
        }
        if (results == 0 or i == 0) return false;
        const call_msg = messages[i - 1];
        if (call_msg != .object or call_msg.object.get("tool_calls") == null) return false;
        i -= 1;
        batches += 1;
    }
    return true;
}

test "repairCalls rebuilds lost arguments from markup, typed by the schema, and strips it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tools =
        \\[{"type":"function","function":{"name":"read_file","parameters":{"type":"object","properties":{"path":{"type":"string"},"start_line":{"type":["integer","null"]},"end_line":{"type":["integer","null"]}}}}}]
    ;
    var message = try std.json.parseFromSliceLeaky(Value, a,
        \\{"role":"assistant","content":"Let me look.\n<tool_call><function=read_file><parameter=path>src/vision.zig</parameter><parameter=start_line>40</parameter><parameter=end_line>160</parameter></function></tool_call>",
        \\ "tool_calls":[{"id":"c1","type":"function","function":{"name":"read_file","arguments":"{\"path\": \"src/vision.zig\", \", \"start_line\": "}}]}
    , .{ .allocate = .alloc_always });
    try std.testing.expect(try repairCalls(a, &message, tools));
    const args = message.object.get("tool_calls").?.array.items[0].object.get("function").?.object.get("arguments").?.string;
    const parsed = try std.json.parseFromSliceLeaky(Value, a, args, .{});
    try std.testing.expectEqualStrings("src/vision.zig", parsed.object.get("path").?.string);
    try std.testing.expectEqual(@as(i64, 40), parsed.object.get("start_line").?.integer);
    try std.testing.expectEqual(@as(i64, 160), parsed.object.get("end_line").?.integer);
    try std.testing.expectEqualStrings("Let me look.", message.object.get("content").?.string);
}

test "repairCalls keeps good arguments, only strips the echoed markup; plain text is untouched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var echoed = try std.json.parseFromSliceLeaky(Value, a,
        \\{"role":"assistant","content":"<function=shell><parameter=command>\nls\n</parameter></function>",
        \\ "tool_calls":[{"id":"c1","type":"function","function":{"name":"shell","arguments":"{\"command\":\"ls -la\"}"}}]}
    , .{ .allocate = .alloc_always });
    try std.testing.expect(try repairCalls(a, &echoed, "[]"));
    try std.testing.expectEqualStrings("{\"command\":\"ls -la\"}", echoed.object.get("tool_calls").?.array.items[0].object.get("function").?.object.get("arguments").?.string);
    try std.testing.expectEqualStrings("", echoed.object.get("content").?.string);

    var plain = try std.json.parseFromSliceLeaky(Value, a,
        \\{"role":"assistant","content":"No markup here.","tool_calls":[{"id":"c1","type":"function","function":{"name":"shell","arguments":"{}"}}]}
    , .{ .allocate = .alloc_always });
    try std.testing.expect(!try repairCalls(a, &plain, "[]"));
}

test "repairCalls: multiline string values lose only the wrapping newlines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var message = try std.json.parseFromSliceLeaky(Value, a,
        \\{"role":"assistant","content":"<tool_call>\n<function=write_file>\n<parameter=path>\na.txt\n</parameter>\n<parameter=content>\n  one\n  two\n</parameter>\n</function>\n</tool_call>",
        \\ "tool_calls":[{"id":"c1","type":"function","function":{"name":"write_file","arguments":""}}]}
    , .{ .allocate = .alloc_always });
    try std.testing.expect(try repairCalls(a, &message, "[]"));
    const args = message.object.get("tool_calls").?.array.items[0].object.get("function").?.object.get("arguments").?.string;
    const parsed = try std.json.parseFromSliceLeaky(Value, a, args, .{});
    try std.testing.expectEqualStrings("a.txt", parsed.object.get("path").?.string);
    try std.testing.expectEqualStrings("  one\n  two", parsed.object.get("content").?.string);
}

test "writeMimoTools collapses nullable unions to the plain type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try writeMimoTools(&s, a,
        \\[{"type":"function","function":{"name":"read_file","parameters":{"type":"object","properties":{"start_line":{"type":["integer","null"]},"contains":{"anyOf":[{"type":"string"},{"type":"null"}],"description":"d"},"tags":{"type":"array","items":{"type":["string","null"]}}}}}}]
    );
    const out = try std.json.parseFromSliceLeaky(Value, a, aw.written(), .{});
    const props = out.array.items[0].object.get("function").?.object.get("parameters").?.object.get("properties").?.object;
    try std.testing.expectEqualStrings("integer", props.get("start_line").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("string", props.get("contains").?.object.get("type").?.string);
    try std.testing.expect(props.get("contains").?.object.get("anyOf") == null);
    try std.testing.expectEqualStrings("d", props.get("contains").?.object.get("description").?.string);
    try std.testing.expectEqualStrings("string", props.get("tags").?.object.get("items").?.object.get("type").?.string);
}

test "brokenCallLoop: three all-unusable batches in a row, not two or a mixed one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const call =
        \\{"role":"assistant","content":"","tool_calls":[{"id":"x","type":"function","function":{"name":"read_file","arguments":"{}"}}]}
    ;
    const bad = "{\"role\":\"tool\",\"tool_call_id\":\"x\",\"content\":\"[error] " ++ tool_call_args.invalid_exec_message ++ "\"}";
    const missing = "{\"role\":\"tool\",\"tool_call_id\":\"x\",\"content\":\"[error] missing or non-string argument: path\"}";
    const good = "{\"role\":\"tool\",\"tool_call_id\":\"x\",\"content\":\"const x = 1;\"}";
    const three = try std.json.parseFromSliceLeaky(Value, a, "[{\"role\":\"user\",\"content\":\"go\"}," ++ call ++ "," ++ bad ++ "," ++ call ++ "," ++ bad ++ "," ++ missing ++ "," ++ call ++ "," ++ bad ++ "]", .{});
    try std.testing.expect(brokenCallLoop(three.array.items));
    const two = try std.json.parseFromSliceLeaky(Value, a, "[{\"role\":\"user\",\"content\":\"go\"}," ++ call ++ "," ++ bad ++ "," ++ call ++ "," ++ bad ++ "]", .{});
    try std.testing.expect(!brokenCallLoop(two.array.items));
    const mixed = try std.json.parseFromSliceLeaky(Value, a, "[" ++ call ++ "," ++ bad ++ "," ++ call ++ "," ++ good ++ "," ++ bad ++ "," ++ call ++ "," ++ bad ++ "]", .{});
    try std.testing.expect(!brokenCallLoop(mixed.array.items));
}
