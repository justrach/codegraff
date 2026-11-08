//! History translation across a /model switch that changes wire format.
//! Split out of providers.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Provider = @import("provider.zig").Provider;
const extractText = @import("providers.zig").extractText;
const textMessage = @import("messages.zig").textMessage;
const hot_context = @import("hot_context.zig");

/// Rebuild the history as text-only user/assistant turns in `to_kind`'s format
/// — used to carry the conversation across a wire-format switch. Tool-call
/// structure and tool-accompanying status preambles are dropped so intermediate
/// "I'll run X" heads-ups do not survive as standalone tool-less assistant
/// replies (#1833); `attempt_completion` answers are preserved as assistant text.
/// Hot-context updates may be developer/system-role, so they are retyped for
/// the new wire rather than dropped; otherwise the model would fall back to
/// the stale instructions in the system prompt.
pub fn translateHistory(arena: Allocator, msgs: *std.json.Array, to_kind: Provider.Kind) void {
    var out = std.json.Array.init(arena);
    for (msgs.items, 0..) |m, i| {
        if (m != .object) continue;
        // The new route announces loaded tools its own way, or not at all (ADR 0221).
        if (@import("additional_tools.zig").isItem(m)) continue;
        if (hot_context.isHotContext(m)) {
            out.append(hot_context.retyped(arena, to_kind, extractText(arena, m)) catch continue) catch {};
            continue;
        }
        if (std.mem.eql(u8, strField(m.object, "type"), "function_call")) {
            if (std.mem.eql(u8, strField(m.object, "name"), "attempt_completion")) {
                const res = std.mem.trim(u8, resultFromArgsJson(arena, strField(m.object, "arguments")), " \t\r\n");
                if (res.len > 0) appendTurn(arena, &out, m, "assistant", res);
            }
            continue;
        }
        const role = strField(m.object, "role");
        if (!std.mem.eql(u8, role, "user") and !std.mem.eql(u8, role, "assistant")) continue;
        if (std.mem.eql(u8, role, "assistant")) {
            if (completionResultFromAssistant(arena, m.object)) |res| {
                const trimmed = std.mem.trim(u8, res, " \t\r\n");
                if (trimmed.len > 0) appendTurn(arena, &out, m, "assistant", trimmed);
                continue;
            }
            if (isToolPreamble(msgs.items, i)) continue;
        }
        const text = std.mem.trim(u8, extractText(arena, m), " \t\r\n");
        if (text.len == 0) continue;
        appendTurn(arena, &out, m, role, text);
    }
    msgs.* = out;
}

fn strField(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

fn resultFromArgsJson(arena: Allocator, raw: []const u8) []const u8 {
    if (raw.len == 0) return "";
    const parsed = std.json.parseFromSliceLeaky(Value, arena, raw, .{}) catch return "";
    return if (parsed == .object) strField(parsed.object, "result") else "";
}

fn completionResultFromAssistant(arena: Allocator, obj: std.json.ObjectMap) ?[]const u8 {
    if (obj.get("tool_calls")) |tc| if (tc == .array) {
        for (tc.array.items) |call| {
            if (call != .object) continue;
            const f = call.object.get("function") orelse continue;
            if (f != .object) continue;
            if (std.mem.eql(u8, strField(f.object, "name"), "attempt_completion"))
                return resultFromArgsJson(arena, strField(f.object, "arguments"));
        }
    };
    if (obj.get("content")) |c| if (c == .array) {
        for (c.array.items) |blk| {
            if (blk != .object) continue;
            if (!std.mem.eql(u8, strField(blk.object, "type"), "tool_use")) continue;
            if (!std.mem.eql(u8, strField(blk.object, "name"), "attempt_completion")) continue;
            if (blk.object.get("input")) |inp| if (inp == .object) return strField(inp.object, "result");
        }
    };
    return null;
}

fn isToolPreamble(items: []const Value, idx: usize) bool {
    const obj = items[idx].object;
    if (obj.get("tool_calls")) |tc| if (tc == .array and tc.array.items.len > 0) return true;
    if (obj.get("content")) |c| if (c == .array) {
        for (c.array.items) |blk| {
            if (blk == .object and std.mem.eql(u8, strField(blk.object, "type"), "tool_use")) return true;
        }
    };
    var j = idx + 1;
    while (j < items.len) : (j += 1) {
        if (items[j] != .object) continue;
        const t = strField(items[j].object, "type");
        if (std.mem.eql(u8, t, "reasoning") or std.mem.eql(u8, t, "thought")) continue;
        return std.mem.eql(u8, t, "function_call");
    }
    return false;
}

fn appendTurn(arena: Allocator, out: *std.json.Array, src: Value, role: []const u8, text: []const u8) void {
    if (std.mem.eql(u8, role, "assistant") and out.items.len > 0) {
        const last = &out.items[out.items.len - 1];
        if (last.* == .object and !hot_context.isHotContext(last.*) and
            std.mem.eql(u8, strField(last.object, "role"), "assistant"))
        {
            const prev = strField(last.object, "content");
            const joined = std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ prev, text }) catch return;
            last.object.put(arena, "content", .{ .string = joined }) catch {};
            return;
        }
    }
    const msg = @import("session_wake.zig").copyOrigin(arena, src, textMessage(arena, role, text) catch return) catch return;
    out.append(msg) catch {};
}

fn parse(a: Allocator, s: []const u8) Value {
    return std.json.parseFromSliceLeaky(Value, a, s, .{}) catch unreachable;
}

test "translateHistory: flattens to {role,content:string}, keeps user/assistant, drops the rest" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    try msgs.append(parse(a, "{\"role\":\"system\",\"content\":\"sys\"}")); // dropped
    try msgs.append(parse(a, "{\"role\":\"user\",\"content\":\"hello\"}")); // kept
    try msgs.append(parse(a, "{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}")); // flattened
    try msgs.append(parse(a, "{\"role\":\"tool\",\"content\":\"result\"}")); // dropped
    try msgs.append(parse(a, "{\"role\":\"user\",\"content\":\"   \"}")); // whitespace-only -> dropped
    translateHistory(a, &msgs, .anthropic);
    try std.testing.expectEqual(@as(usize, 2), msgs.items.len);
    try std.testing.expectEqualStrings("user", msgs.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("hello", msgs.items[0].object.get("content").?.string);
    try std.testing.expectEqualStrings("assistant", msgs.items[1].object.get("role").?.string);
    try std.testing.expectEqualStrings("hi", msgs.items[1].object.get("content").?.string);
}

test "translateHistory retypes a hot-context update for the new wire" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    try msgs.append(parse(a, "{\"role\":\"user\",\"content\":\"hi\"}"));
    try msgs.append(try hot_context.retyped(a, .responses, "<context key=\"core/date\">x</context>"));
    try std.testing.expectEqualStrings("developer", msgs.items[1].object.get("role").?.string);
    translateHistory(a, &msgs, .anthropic);
    try std.testing.expectEqual(@as(usize, 2), msgs.items.len);
    try std.testing.expect(hot_context.isHotContext(msgs.items[1]));
    try std.testing.expectEqualStrings("user", msgs.items[1].object.get("role").?.string);
    try std.testing.expectEqualStrings("<context key=\"core/date\">x</context>", msgs.items[1].object.get("content").?.string);
}

test "#1833 translateHistory drops tool-accompanying preambles and keeps final or attempt_completion answers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    try msgs.append(parse(a, "{\"role\":\"user\",\"content\":\"fix the bug\"}"));
    // Responses tool-call preamble + reasoning + function_call + output
    try msgs.append(parse(a, "{\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"I'll inspect the file.\"}]}"));
    try msgs.append(parse(a, "{\"type\":\"reasoning\",\"encrypted_content\":\"abc\"}"));
    try msgs.append(parse(a, "{\"type\":\"function_call\",\"call_id\":\"c1\",\"name\":\"read_file\",\"arguments\":\"{}\"}"));
    try msgs.append(parse(a, "{\"type\":\"function_call_output\",\"call_id\":\"c1\",\"output\":\"ok\"}"));
    // OpenAI tool-call preamble
    try msgs.append(parse(a, "{\"role\":\"assistant\",\"content\":\"Running tests now.\",\"tool_calls\":[{\"id\":\"c2\",\"type\":\"function\",\"function\":{\"name\":\"shell\",\"arguments\":\"{}\"}}]}"));
    try msgs.append(parse(a, "{\"role\":\"tool\",\"tool_call_id\":\"c2\",\"content\":\"PASS\"}"));
    // Anthropic tool-call preamble
    try msgs.append(parse(a, "{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Applying patch.\"},{\"type\":\"tool_use\",\"id\":\"c3\",\"name\":\"edit_file\",\"input\":{}}]}"));
    // Final completion via attempt_completion function_call
    try msgs.append(parse(a, "{\"type\":\"function_call\",\"call_id\":\"c4\",\"name\":\"attempt_completion\",\"arguments\":\"{\\\"result\\\":\\\"Fixed and verified.\\\"}\"}"));
    translateHistory(a, &msgs, .openai);
    try std.testing.expectEqual(@as(usize, 2), msgs.items.len);
    try std.testing.expectEqualStrings("user", msgs.items[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("fix the bug", msgs.items[0].object.get("content").?.string);
    try std.testing.expectEqualStrings("assistant", msgs.items[1].object.get("role").?.string);
    try std.testing.expectEqualStrings("Fixed and verified.", msgs.items[1].object.get("content").?.string);
}

