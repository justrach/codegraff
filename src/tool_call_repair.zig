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
//!   markup it used from `content`, so the next request's history is clean.
//!   The live stream already showed it; this does not filter text deltas.
//! - `writeMimoTools` sends MiMo plain parameter types: its parser breaks on
//!   nullable unions such as `["integer","null"]`.
//! - `brokenCallLoop` ends a turn whose last three tool batches all failed on
//!   unusable arguments, instead of letting the retries multiply.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const tool_call_args = @import("tool_call_args.zig");

pub const loop_stop_text = "Stopped: the model sent tool calls with unusable arguments three times in a row, so the turn ended instead of retrying. Send a new message to continue, or switch models.";

/// The turn loop ends on this text outright: no retry, nudge, or open-work pass.
pub fn isLoopStop(text: []const u8) bool {
    return text.ptr == loop_stop_text.ptr;
}

/// runTurn's check for that stop; a child also closes its feedback inbox.
pub fn endsTurn(self: anytype, text: []const u8) bool {
    if (!isLoopStop(text)) return false;
    if (self.feedback) |inbox| _ = inbox.close(self.io);
    return true;
}

const ws = " \t\r\n";

/// One `<function=NAME>BODY</function>`; `start..end` also covers a
/// `<tool_call>` wrapper around it.
const Block = struct { name: []const u8, body: []const u8, start: usize, end: usize, state: enum { free, taken, repaired } = .free };

/// Closed `<function=NAME>BODY</function>` spans in `text`, in order. An
/// opening tag with no `</function>` before the next one (prose that quotes
/// the format, or a cut-off reply) is not a block.
fn blocks(scratch: Allocator, text: []const u8) ![]Block {
    var out: std.ArrayList(Block) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, "<function=")) |start| {
        const name_start = start + "<function=".len;
        const name_end = std.mem.indexOfScalarPos(u8, text, name_start, '>') orelse break;
        const close = std.mem.indexOfPos(u8, text, name_end, "</function>") orelse break;
        if (std.mem.indexOfPos(u8, text, name_end, "<function=")) |next| if (next < close) {
            pos = next;
            continue;
        };
        var span_start = start;
        var span_end = close + "</function>".len;
        const before = std.mem.trimEnd(u8, text[0..start], ws);
        if (std.mem.endsWith(u8, before, "<tool_call>")) span_start = before.len - "<tool_call>".len;
        const after = std.mem.trimStart(u8, text[span_end..], ws);
        if (std.mem.startsWith(u8, after, "</tool_call>")) span_end = text.len - after.len + "</tool_call>".len;
        const name = std.mem.trim(u8, text[name_start..name_end], " \t\r\n\"'");
        try out.append(scratch, .{ .name = name, .body = text[name_end + 1 .. close], .start = span_start, .end = span_end });
        pos = close + "</function>".len;
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

/// `t` is a plain JSON number: `-?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?`,
/// integer part only when `!fraction`. parseInt/parseFloat also take `+`,
/// `_`, `inf`, and `nan`, none of which is JSON.
fn jsonNumber(t: []const u8, fraction: bool) bool {
    var i: usize = 0;
    if (i < t.len and t[i] == '-') i += 1;
    const digits = struct {
        fn run(s: []const u8, from: usize) usize {
            var j = from;
            while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
            return j - from;
        }
    }.run;
    const whole = digits(t, i);
    if (whole == 0 or (whole > 1 and t[i] == '0')) return false;
    i += whole;
    if (!fraction) return i == t.len;
    if (i < t.len and t[i] == '.') {
        const n = digits(t, i + 1);
        if (n == 0) return false;
        i += 1 + n;
    }
    if (i < t.len and (t[i] == 'e' or t[i] == 'E')) {
        i += 1;
        if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
        const n = digits(t, i);
        if (n == 0) return false;
        i += n;
    }
    return i == t.len;
}

/// A `<parameter>` value as the JSON type its schema declares; text otherwise.
pub fn coerce(scratch: Allocator, raw: []const u8, prop: ?Value) Value {
    const t = std.mem.trim(u8, raw, ws);
    if (wants(prop, "integer") and jsonNumber(t, false)) if (std.fmt.parseInt(i64, t, 10)) |n| return .{ .integer = n } else |_| {};
    if (wants(prop, "number") and jsonNumber(t, true)) if (std.fmt.parseFloat(f64, t)) |n| {
        if (std.math.isFinite(n)) return .{ .number_string = t };
    } else |_| {};
    if (wants(prop, "boolean")) {
        if (std.mem.eql(u8, t, "true")) return .{ .bool = true };
        if (std.mem.eql(u8, t, "false")) return .{ .bool = false };
    }
    if (wants(prop, "array") or wants(prop, "object")) {
        if (std.json.parseFromSliceLeaky(Value, scratch, t, .{ .allocate = .alloc_always })) |v| {
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

/// Where the parameter after `from` starts: a `<parameter=` right after a
/// `</parameter>`. One inside a value (a quoted string in a command) is not.
fn nextParam(body: []const u8, from: usize) usize {
    var pos = from;
    while (std.mem.indexOfPos(u8, body, pos, "<parameter=")) |p| {
        if (std.mem.endsWith(u8, std.mem.trimEnd(u8, body[from..p], ws), "</parameter>")) return p;
        pos = p + 1;
    }
    return body.len;
}

/// Arguments object from one block's `<parameter=K>V</parameter>` pairs. A
/// value runs to the last `</parameter>` before the next parameter. Null
/// (no repair) for anything else in the body, a duplicate key, or a key the
/// tool's schema does not declare.
fn argumentsFrom(scratch: Allocator, body: []const u8, props: ?std.json.ObjectMap) !?std.json.ObjectMap {
    var obj: std.json.ObjectMap = .empty;
    var rest = std.mem.trimStart(u8, body, ws);
    while (rest.len > 0) {
        if (!std.mem.startsWith(u8, rest, "<parameter=")) return null;
        const key_end = std.mem.indexOfScalar(u8, rest, '>') orelse return null;
        const key = std.mem.trim(u8, rest["<parameter=".len..key_end], " \t\r\n\"'");
        const next = nextParam(rest, key_end + 1);
        const close = std.mem.lastIndexOf(u8, rest[key_end + 1 .. next], "</parameter>") orelse return null;
        const value_end = key_end + 1 + close;
        if (std.mem.trim(u8, rest[value_end + "</parameter>".len .. next], ws).len != 0) return null;
        const prop = if (props) |p| (p.get(key) orelse return null) else null;
        if (key.len == 0 or obj.contains(key)) return null;
        try obj.put(scratch, key, coerce(scratch, rest[key_end + 1 .. value_end], prop));
        rest = rest[next..];
    }
    return if (obj.count() == 0) null else obj;
}

/// A JSON string literal's body: up to its closing quote, or to the end of
/// a cut-off `s`. Returns the body and whether it closed.
fn stringBody(s: []const u8) struct { []const u8, bool } {
    var i: usize = 0;
    while (i < s.len) : (i += 1) switch (s[i]) {
        '\\' => i += 1,
        '"' => return .{ s[0..i], true },
        else => {},
    };
    return .{ s[0..@min(i, s.len)], false };
}

/// Whether `rebuilt` could be what the provider cut off as `broken`: each
/// `"key":"string` that `broken` spells out must name a rebuilt key whose
/// encoded value equals it (or starts with it, where cut off). Stops
/// checking at the first non-string value or unparseable byte.
fn consistent(scratch: Allocator, broken: []const u8, rebuilt: std.json.ObjectMap) !bool {
    var rest = std.mem.trimStart(u8, broken, ws);
    if (!std.mem.startsWith(u8, rest, "{")) return true;
    rest = rest[1..];
    while (true) {
        rest = std.mem.trimStart(u8, rest, ws);
        if (!std.mem.startsWith(u8, rest, "\"")) return true;
        const key, const key_closed = stringBody(rest[1..]);
        if (!key_closed) return true;
        rest = std.mem.trimStart(u8, rest[key.len + 2 ..], ws);
        if (!std.mem.startsWith(u8, rest, ":")) return true;
        rest = std.mem.trimStart(u8, rest[1..], ws);
        if (!std.mem.startsWith(u8, rest, "\"")) return true;
        const val, const val_closed = stringBody(rest[1..]);
        const want = rebuilt.get(key) orelse return false;
        const encoded = try std.json.Stringify.valueAlloc(scratch, want, .{});
        if (encoded.len < 2 or encoded[0] != '"') return false;
        const inner = encoded[1 .. encoded.len - 1];
        if (if (val_closed) !std.mem.eql(u8, inner, val) else !std.mem.startsWith(u8, inner, val)) return false;
        if (!val_closed) return true;
        rest = std.mem.trimStart(u8, rest[val.len + 2 ..], ws);
        if (!std.mem.startsWith(u8, rest, ",")) return true;
        rest = rest[1..];
    }
}

/// `text` without the spans of blocks that repaired a call, trimmed.
fn stripRepaired(arena: Allocator, text: []const u8, found: []const Block) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    for (found) |b| if (b.state == .repaired) {
        try out.appendSlice(arena, text[pos..b.start]);
        pos = b.end;
    };
    try out.appendSlice(arena, text[pos..]);
    return std.mem.trim(u8, out.items, ws);
}

const Call = struct { f: *Value, name: []const u8, args: []const u8, broken: bool };

fn countFor(name: []const u8, calls: []const Call, found: []const Block) struct { usize, usize } {
    var broken: usize = 0;
    var markup: usize = 0;
    for (calls) |c| if (c.broken and std.mem.eql(u8, c.name, name)) {
        broken += 1;
    };
    for (found) |b| if (std.mem.eql(u8, b.name, name)) {
        markup += 1;
    };
    return .{ broken, markup };
}

/// Repair a chat-completions assistant `message` in place; true when a
/// call's arguments were rebuilt. Only broken calls take markup, in order,
/// and only when a tool name has exactly as many blocks as broken calls.
/// `arena` owns `message`; everything transient goes on `scratch`.
pub fn repairCalls(arena: Allocator, scratch: Allocator, message: *Value, tools_raw: []const u8) !bool {
    if (message.* != .object) return false;
    const content = message.object.get("content") orelse return false;
    if (content != .string or std.mem.indexOf(u8, content.string, "<function=") == null) return false;
    const tool_calls = message.object.getPtr("tool_calls") orelse return false;
    if (tool_calls.* != .array or tool_calls.array.items.len == 0) return false;
    const found = try blocks(scratch, content.string);
    if (found.len == 0) return false;
    var calls: std.ArrayList(Call) = .empty;
    for (tool_calls.array.items) |*tc| {
        if (tc.* != .object) continue;
        const f = tc.object.getPtr("function") orelse continue;
        if (f.* != .object) continue;
        const name = if (f.object.get("name")) |n| (if (n == .string) n.string else continue) else continue;
        const args = if (f.object.get("arguments")) |a| (if (a == .string) a.string else "") else "";
        const parsed = tool_call_args.parse(scratch, args);
        const broken = !parsed.valid or (parsed.input == .object and parsed.input.object.count() == 0);
        try calls.append(scratch, .{ .f = f, .name = name, .args = args, .broken = broken });
    }
    const catalog = std.json.parseFromSliceLeaky(Value, scratch, tools_raw, .{ .allocate = .alloc_always }) catch null;
    var repaired = false;
    for (calls.items) |c| {
        if (!c.broken) continue;
        const broken, const markup = countFor(c.name, calls.items, found);
        if (broken != markup) continue;
        for (found) |*b| if (b.state == .free and std.mem.eql(u8, b.name, c.name)) {
            b.state = .taken;
            const obj = try argumentsFrom(scratch, b.body, properties(catalog, c.name)) orelse break;
            if (!try consistent(scratch, c.args, obj)) break;
            try c.f.object.put(arena, "arguments", .{ .string = try std.json.Stringify.valueAlloc(arena, Value{ .object = obj }, .{}) });
            b.state = .repaired;
            repaired = true;
            break;
        };
    }
    if (!repaired) return false;
    try message.object.put(arena, "content", .{ .string = try stripRepaired(arena, content.string, found) });
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

/// Chat-completions tools for MiMo: plain parameter types, no nullable
/// unions, and the root `type: object` writeOpenAITools adds.
pub fn writeMimoTools(s: *std.json.Stringify, arena: Allocator, raw: []const u8) !void {
    const value = std.json.parseFromSliceLeaky(Value, arena, raw, .{ .allocate = .alloc_always }) catch return s.print("{s}", .{raw});
    if (value != .array) return s.print("{s}", .{raw});
    for (value.array.items) |*tool| {
        if (tool.* != .object) continue;
        const f = tool.object.getPtr("function") orelse continue;
        if (f.* != .object) continue;
        if (f.object.getPtr("parameters")) |p| {
            _ = try @import("serde.zig").defaultRootObjectType(arena, p);
            try collapseNullable(arena, p);
        }
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

test {
    _ = @import("tool_call_repair_tests.zig");
}
