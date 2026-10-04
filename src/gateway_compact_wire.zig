//! The wire half of hosted compaction (ADR 0252): graff's provider-shaped
//! history to the gateway's neutral transcript, and the reply back onto it.
//! Pure — no Agent, no network — so every wire format's mapping is pinned by
//! fixtures (gateway_compact_tests.zig).
//!
//! Out: consecutive items of one side fold into one neutral message — user
//! prompts, harness notes and tool results on one side; assistant text, calls
//! and reasoning on the other — and each message remembers the native range
//! it came from. In: the endpoint's per-call decisions are applied to the
//! NATIVE items by call id. Nothing is rebuilt from the neutral copy, so
//! reasoning, images and provider metadata stay as they were; a hybrid summary
//! replaces only the native range it summarized.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

const sanitizeUtf8 = @import("messages.zig").sanitizeUtf8;

/// The endpoint's own cap on one transcript.
pub const max_messages = 2000;
/// Newest messages the hybrid summary keeps verbatim: the endpoint's default,
/// which its summary step applies whatever the request says.
pub const recent_kept = 6;

pub const Role = enum { user, assistant };
pub const Use = struct { id: []const u8, name: []const u8, input: Value = .null };
pub const Result = struct { id: []const u8, text: []const u8 = "", is_error: bool = false };

pub const Msg = struct {
    role: Role,
    /// The native items [lo, hi) this message folds.
    lo: usize,
    hi: usize,
    text: []const u8 = "",
    uses: []const Use = &.{},
    results: []const Result = &.{},
};

const Builder = struct {
    a: Allocator,
    /// Call/result ids only: no text, no argument parsing (pair checks).
    ids_only: bool = false,
    out: std.ArrayList(Msg) = .empty,
    open: ?Msg = null,
    text: std.ArrayList(u8) = .empty,
    uses: std.ArrayList(Use) = .empty,
    results: std.ArrayList(Result) = .empty,

    fn close(b: *Builder) !void {
        var m = b.open orelse return;
        m.text = try b.text.toOwnedSlice(b.a);
        m.uses = try b.uses.toOwnedSlice(b.a);
        m.results = try b.results.toOwnedSlice(b.a);
        try b.out.append(b.a, m);
        b.open = null;
    }

    fn addText(b: *Builder, s: []const u8) !void {
        if (b.ids_only or s.len == 0) return;
        if (b.text.items.len > 0) try b.text.append(b.a, '\n');
        try b.text.appendSlice(b.a, sanitizeUtf8(b.a, s));
    }

    fn use(b: *Builder, id: ?[]const u8, name: ?[]const u8, input: ?Value, wrap_as: []const u8) !void {
        const call_id = id orelse return;
        const args: Value = if (b.ids_only) .null else try argsObject(b.a, input, wrap_as);
        try b.uses.append(b.a, .{ .id = call_id, .name = name orelse "tool", .input = args });
    }

    fn result(b: *Builder, id: ?[]const u8, payload: ?Value, is_error: bool) !void {
        const call_id = id orelse return;
        const text = if (b.ids_only) "" else sanitizeUtf8(b.a, try textOf(b.a, payload orelse .null));
        try b.results.append(b.a, .{ .id = call_id, .text = text, .is_error = is_error });
    }
};

fn str(o: ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn errorFlag(o: ObjectMap) bool {
    const v = o.get("is_error") orelse o.get("isError") orelse return false;
    return v == .bool and v.bool;
}

/// Which side an item speaks for. Typed items (Responses, Interactions) are
/// the model's unless they carry a result or a prompt; role messages follow
/// their role, with tool results and harness notes on the user side.
fn itemRole(item: Value) ?Role {
    if (item != .object) return null;
    const o = item.object;
    if (str(o, "type")) |t| {
        if (eql(t, "function_call_output") or eql(t, "custom_tool_call_output") or
            eql(t, "function_result") or eql(t, "user_input")) return .user;
        if (!eql(t, "message")) return .assistant; // calls, reasoning, thought, model_output, opaque state
    }
    const role = str(o, "role") orelse return null;
    return if (eql(role, "assistant")) .assistant else .user;
}

/// Joined text of a string, a text-bearing object, or an array of parts.
/// Images and other non-text parts contribute nothing.
pub fn textOf(a: Allocator, v: Value) ![]const u8 {
    switch (v) {
        .string => |s| return s,
        .object => |o| return str(o, "text") orelse "",
        .array => |arr| {
            var out: std.ArrayList(u8) = .empty;
            for (arr.items) |part| {
                const t = switch (part) {
                    .string => |s| s,
                    .object => |o| str(o, "text") orelse "",
                    else => "",
                };
                if (t.len == 0) continue;
                if (out.items.len > 0) try out.append(a, '\n');
                try out.appendSlice(a, t);
            }
            return out.items;
        },
        else => return "",
    }
}

/// The endpoint takes a call's input as a JSON object: Chat/Responses carry a
/// string of JSON, a freeform tool a raw string, and either may not parse.
fn argsObject(a: Allocator, v: ?Value, wrap_as: []const u8) !Value {
    const raw = v orelse return .{ .object = .empty };
    switch (raw) {
        .object => return raw,
        .null => return .{ .object = .empty },
        .string => |s| {
            if (std.json.parseFromSliceLeaky(Value, a, s, .{ .allocate = .alloc_always })) |parsed| {
                if (parsed == .object) return parsed;
            } else |_| {}
        },
        else => {},
    }
    var o: ObjectMap = .empty;
    try o.put(a, wrap_as, raw);
    return .{ .object = o };
}

fn absorbBlock(b: *Builder, block: Value) !void {
    if (block == .string) return b.addText(block.string);
    if (block != .object) return;
    const o = block.object;
    const t = str(o, "type") orelse return;
    if (eql(t, "text") or eql(t, "input_text") or eql(t, "output_text")) return b.addText(str(o, "text") orelse "");
    if (eql(t, "tool_use")) return b.use(str(o, "id"), str(o, "name"), o.get("input"), "input");
    if (eql(t, "tool_result")) return b.result(str(o, "tool_use_id"), o.get("content"), errorFlag(o));
}

fn absorb(b: *Builder, item: Value) !void {
    if (item != .object) return;
    const o = item.object;
    if (str(o, "type")) |t| {
        if (eql(t, "function_call")) return b.use(str(o, "call_id") orelse str(o, "id"), str(o, "name"), o.get("arguments"), "arguments");
        if (eql(t, "custom_tool_call")) return b.use(str(o, "call_id"), str(o, "name"), o.get("input"), "input");
        if (eql(t, "function_call_output") or eql(t, "custom_tool_call_output")) return b.result(str(o, "call_id"), o.get("output"), false);
        if (eql(t, "function_result")) return b.result(str(o, "call_id"), o.get("result"), errorFlag(o));
        if (eql(t, "user_input") or eql(t, "model_output") or eql(t, "message")) {
            if (b.ids_only) return;
            return b.addText(try textOf(b.a, o.get("content") orelse .null));
        }
        return; // reasoning, thought, opaque provider state: nothing readable
    }
    const role = str(o, "role") orelse return;
    if (eql(role, "tool")) {
        // OpenAI Chat has no error bit; graff writes failures with this prefix.
        const content = o.get("content") orelse Value.null;
        const failed = content == .string and std.mem.startsWith(u8, content.string, "[error] ");
        return b.result(str(o, "tool_call_id"), content, failed);
    }
    if (o.get("content")) |content| switch (content) {
        .string => |s| try b.addText(s),
        .array => |arr| for (arr.items) |block| try absorbBlock(b, block),
        else => {},
    };
    if (o.get("tool_calls")) |calls| if (calls == .array) for (calls.array.items) |call| {
        if (call != .object) continue;
        const f = call.object.get("function") orelse continue;
        if (f != .object) continue;
        try b.use(str(call.object, "id"), str(f.object, "name"), f.object.get("arguments"), "arguments");
    };
}

fn fold(a: Allocator, items: []const Value, ids_only: bool) ![]const Msg {
    var b: Builder = .{ .a = a, .ids_only = ids_only };
    for (items, 0..) |item, i| {
        const role = itemRole(item) orelse if (b.open) |m| m.role else Role.user;
        if (b.open == null or b.open.?.role != role) {
            try b.close();
            b.open = .{ .role = role, .lo = i, .hi = i };
        }
        b.open.?.hi = i + 1;
        try absorb(&b, item);
    }
    try b.close();
    return b.out.items;
}

/// Native history → neutral messages. The ranges are contiguous and cover
/// every item, so each native item belongs to exactly one message.
pub fn transcript(a: Allocator, items: []const Value) ![]const Msg {
    return fold(a, items, false);
}

/// The POST /v1/compact body.
pub fn request(a: Allocator, msgs: []const Msg, model: []const u8, goal: ?[]const u8) ![]const u8 {
    const WireUse = struct { tool_use_id: []const u8, tool: []const u8, input: Value };
    const WireResult = struct { tool_use_id: []const u8, text: []const u8, isError: ?bool };
    const WireMsg = struct { role: []const u8, text: []const u8, toolUses: []const WireUse, toolResults: []const WireResult };
    const out = try a.alloc(WireMsg, msgs.len);
    for (msgs, out) |m, *w| {
        const uses = try a.alloc(WireUse, m.uses.len);
        for (m.uses, uses) |u, *x| x.* = .{ .tool_use_id = u.id, .tool = u.name, .input = u.input };
        const results = try a.alloc(WireResult, m.results.len);
        for (m.results, results) |r, *x| x.* = .{ .tool_use_id = r.id, .text = r.text, .isError = if (r.is_error) true else null };
        w.* = .{ .role = @tagName(m.role), .text = m.text, .toolUses = uses, .toolResults = results };
    }
    var aw: std.Io.Writer.Allocating = .init(a);
    const body = .{ .model = model, .mode = "hybrid", .goal = goal, .messages = out };
    try std.json.Stringify.value(body, .{ .emit_null_optional_fields = false }, &aw.writer);
    return aw.writer.buffered();
}

pub const Action = enum { keep, drop_result, drop_call };
pub const Decisions = std.StringHashMapUnmanaged(Action);

pub const Reply = struct {
    decisions: Decisions = .empty,
    /// The endpoint's transcript after compaction, for validation only.
    messages: []const Value = &.{},
    summarized: bool = false,
    /// The spliced summary without the endpoint's header line.
    summary: []const u8 = "",
};

pub fn parseReply(a: Allocator, root: Value) !Reply {
    if (root != .object) return error.UnexpectedReply;
    const msgs = root.object.get("messages") orelse return error.UnexpectedReply;
    const decisions = root.object.get("decisions") orelse return error.UnexpectedReply;
    if (msgs != .array or decisions != .array) return error.UnexpectedReply;
    var reply: Reply = .{ .messages = msgs.array.items };
    for (decisions.array.items) |d| {
        if (d != .object) return error.UnexpectedReply;
        const id = str(d.object, "tool_use_id") orelse return error.UnexpectedReply;
        const action = std.meta.stringToEnum(Action, str(d.object, "action") orelse "") orelse return error.UnexpectedReply;
        try reply.decisions.put(a, id, action);
    }
    if (root.object.get("stats")) |stats| {
        if (stats == .object) if (stats.object.get("summarized")) |v| {
            reply.summarized = v == .bool and v.bool;
        };
    }
    if (reply.summarized) {
        if (reply.messages.len < 2 or reply.messages[1] != .object) return error.UnexpectedReply;
        const text = str(reply.messages[1].object, "text") orelse return error.UnexpectedReply;
        const body = if (std.mem.indexOfScalar(u8, text, '\n')) |nl| text[nl + 1 ..] else text;
        reply.summary = std.mem.trim(u8, body, " \t\r\n");
        if (reply.summary.len == 0) return error.UnexpectedReply;
    }
    return reply;
}

fn act(d: *const Decisions, id: ?[]const u8) Action {
    return d.get(id orelse return .keep) orelse .keep;
}

/// The endpoint's rule: a message survives unless compaction touched it and
/// left no text, call, or result behind.
fn survives(m: Msg, d: *const Decisions) bool {
    var touched = false;
    var left = m.text.len > 0;
    for (m.uses) |u| {
        if (act(d, u.id) == .drop_call) touched = true else left = true;
    }
    for (m.results) |r| switch (act(d, r.id)) {
        .drop_call => touched = true,
        .drop_result => {
            touched = true;
            left = true;
        },
        .keep => left = true,
    };
    return !touched or left;
}

fn sameIds(listed: ?Value, comptime T: type, mine: []const T, d: *const Decisions) bool {
    const arr = if (listed) |v| (if (v == .array) v.array.items else return false) else &[_]Value{};
    var k: usize = 0;
    for (mine) |x| {
        if (act(d, x.id) == .drop_call) continue;
        if (k >= arr.len or arr[k] != .object) return false;
        const id = str(arr[k].object, "tool_use_id") orelse return false;
        if (!eql(id, x.id)) return false;
        k += 1;
    }
    return k == arr.len;
}

/// Is `r` (from the reply) message `m` after the decisions? Text is compared
/// byte for byte: the endpoint never rewrites it.
fn matches(r: Value, m: Msg, d: *const Decisions) bool {
    if (r != .object) return false;
    const role = str(r.object, "role") orelse return false;
    if (!eql(role, @tagName(m.role))) return false;
    if (!eql(str(r.object, "text") orelse "", m.text)) return false;
    return sameIds(r.object.get("toolUses"), Use, m.uses, d) and
        sameIds(r.object.get("toolResults"), Result, m.results, d);
}

fn useAt(msgs: []const Msg, id: []const u8) ?usize {
    for (msgs, 0..) |m, j| for (m.uses) |u| if (eql(u.id, id)) return j;
    return null;
}

pub fn msgAt(msgs: []const Msg, native: usize) ?usize {
    for (msgs, 0..) |m, j| if (native >= m.lo and native < m.hi) return j;
    return null;
}

pub const Plan = struct {
    /// Per neutral message: kept (with its per-call decisions applied).
    keep: []bool,
    /// The neutral message the summary note goes before; null = no summary.
    note_before: ?usize = null,
};

/// Check the reply against what the decisions imply, then decide which
/// neutral messages stay. A summarized reply is [first, summary, newest k]:
/// k is at least recent_kept, more when the endpoint moved its cut back over
/// a call/result pair. The cut also moves back here over any call a kept
/// result answers (a result without its call is rejected by every wire), and
/// `opening` — an unresolved turn's opening prompt (#581) — stays verbatim.
pub fn plan(a: Allocator, msgs: []const Msg, reply: *const Reply, opening: ?usize) !Plan {
    const d = &reply.decisions;
    var left: std.ArrayList(usize) = .empty;
    for (msgs, 0..) |m, j| if (survives(m, d)) try left.append(a, j);
    const keep = try a.alloc(bool, msgs.len);
    @memset(keep, true);
    if (!reply.summarized) {
        if (reply.messages.len != left.items.len) return error.UnexpectedReply;
        for (left.items, reply.messages) |j, r| if (!matches(r, msgs[j], d)) return error.UnexpectedReply;
        return .{ .keep = keep };
    }
    // At least two messages summarized between the first and the kept tail.
    if (reply.messages.len < 3 or left.items.len < reply.messages.len + 1) return error.UnexpectedReply;
    const head = left.items[0];
    const tail = left.items[left.items.len - (reply.messages.len - 2) ..];
    if (!matches(reply.messages[0], msgs[head], d)) return error.UnexpectedReply;
    for (tail, reply.messages[2..]) |j, r| if (!matches(r, msgs[j], d)) return error.UnexpectedReply;
    var cut = tail[0];
    var moved = true;
    while (moved) {
        moved = false;
        for (msgs[cut..]) |m| for (m.results) |r| {
            const j = useAt(msgs, r.id) orelse continue;
            if (j > head and j < cut) {
                cut = j;
                moved = true;
            }
        };
    }
    @memset(keep, false);
    keep[head] = true;
    @memset(keep[cut..], true);
    if (opening) |t| {
        if (msgAt(msgs, t)) |j| keep[j] = keep[j] or j > head;
    }
    var note_before: ?usize = null;
    for (keep[head + 1 ..], head + 1..) |k, j| if (k) {
        note_before = j;
        break;
    };
    return .{ .keep = keep, .note_before = note_before orelse return error.UnexpectedReply };
}

fn cloneObject(a: Allocator, o: ObjectMap) !ObjectMap {
    var c: ObjectMap = .empty;
    try c.ensureTotalCapacity(a, o.count());
    var it = o.iterator();
    while (it.next()) |e| c.putAssumeCapacity(e.key_ptr.*, e.value_ptr.*);
    return c;
}

fn withField(a: Allocator, o: ObjectMap, key: []const u8, v: Value) !Value {
    var c = try cloneObject(a, o);
    try c.put(a, key, v);
    return .{ .object = c };
}

const Shape = enum { string, parts };

/// A result payload per its decision: gone with its call, shrunk to a stub,
/// or untouched. Null removes the item.
fn shrink(a: Allocator, o: ObjectMap, field: []const u8, action: Action, removable: bool, shape: Shape, stubber: anytype) !?Value {
    if (action == .keep) return .{ .object = o };
    if (action == .drop_call and removable) return null;
    const full = try textOf(a, o.get(field) orelse .null);
    const stub = stubber.stub(a, full);
    if (stub.len >= full.len) return .{ .object = o };
    const payload: Value = switch (shape) {
        .string => .{ .string = stub },
        .parts => blk: {
            var part: ObjectMap = .empty;
            try part.put(a, "type", .{ .string = "text" });
            try part.put(a, "text", .{ .string = stub });
            var parts = std.json.Array.init(a);
            try parts.append(.{ .object = part });
            break :blk .{ .array = parts };
        },
    };
    return try withField(a, o, field, payload);
}

fn shrinkBlocks(a: Allocator, o: ObjectMap, d: *const Decisions, removable: bool, stubber: anytype) !?Value {
    const content = o.get("content") orelse return .{ .object = o };
    if (content != .array) return .{ .object = o };
    var blocks = std.json.Array.init(a);
    var changed = false;
    for (content.array.items) |block| {
        const is_result = block == .object and eql(str(block.object, "type") orelse "", "tool_result");
        const action = if (is_result) act(d, str(block.object, "tool_use_id")) else .keep;
        if (action == .keep) {
            try blocks.append(block);
            continue;
        }
        changed = true;
        if (try shrink(a, block.object, "content", action, removable, .string, stubber)) |v| try blocks.append(v);
    }
    if (!changed) return .{ .object = o };
    if (blocks.items.len == 0) return null;
    return try withField(a, o, "content", .{ .array = blocks });
}

/// Something a later request can use: text or a call. Reasoning, thinking or
/// an empty shell left behind by dropped calls is not.
fn substantive(content: ?Value, calls: ?Value) bool {
    if (calls) |c| if (c == .array and c.array.items.len > 0) return true;
    const v = content orelse return false;
    if (v == .string) return v.string.len > 0;
    if (v != .array) return false;
    for (v.array.items) |block| {
        if (block != .object) continue;
        const t = str(block.object, "type") orelse continue;
        if (eql(t, "tool_use")) return true;
        if (!eql(t, "text")) continue;
        const text: []const u8 = str(block.object, "text") orelse "";
        if (text.len > 0) return true;
    }
    return false;
}

fn dropCalls(a: Allocator, o: ObjectMap, d: *const Decisions) !?Value {
    var calls = o.get("tool_calls");
    var calls_changed = false;
    if (calls) |c| if (c == .array) {
        var kept = std.json.Array.init(a);
        for (c.array.items) |call| {
            const id = if (call == .object) str(call.object, "id") else null;
            if (act(d, id) == .drop_call) calls_changed = true else try kept.append(call);
        }
        if (calls_changed) calls = .{ .array = kept };
    };
    var content = o.get("content");
    var content_changed = false;
    if (content) |c| if (c == .array) {
        var kept = std.json.Array.init(a);
        for (c.array.items) |block| {
            const dropped = block == .object and eql(str(block.object, "type") orelse "", "tool_use") and
                act(d, str(block.object, "id")) == .drop_call;
            if (dropped) content_changed = true else try kept.append(block);
        }
        if (content_changed) content = .{ .array = kept };
    };
    if (!calls_changed and !content_changed) return .{ .object = o };
    if (!substantive(content, calls)) return null;
    var c = try cloneObject(a, o);
    if (calls_changed) {
        // An empty tool_calls array is rejected outright; the key goes.
        if (calls.?.array.items.len == 0) _ = c.orderedRemove("tool_calls") else try c.put(a, "tool_calls", calls.?);
    }
    if (content_changed) try c.put(a, "content", content.?);
    return .{ .object = c };
}

/// One native item after the decisions. `removable`: the item is from an
/// earlier turn, so a dropped call goes with its result and stale reasoning
/// goes too (#174). In the live turn a dropped call only loses its result's
/// bulk: that turn's reasoning, thinking and signatures stay paired with every
/// call they reference.
pub fn applyItem(a: Allocator, item: Value, d: *const Decisions, removable: bool, stubber: anytype) !?Value {
    if (item != .object) return item;
    const o = item.object;
    if (str(o, "type")) |t| {
        if (eql(t, "function_call") or eql(t, "custom_tool_call"))
            return if (removable and act(d, str(o, "call_id") orelse str(o, "id")) == .drop_call) null else item;
        if (eql(t, "function_call_output") or eql(t, "custom_tool_call_output"))
            return shrink(a, o, "output", act(d, str(o, "call_id")), removable, .string, stubber);
        if (eql(t, "function_result"))
            return shrink(a, o, "result", act(d, str(o, "call_id")), removable, .parts, stubber);
        if (eql(t, "reasoning") and removable) return null;
        return item;
    }
    const role = str(o, "role") orelse return item;
    if (eql(role, "tool")) return shrink(a, o, "content", act(d, str(o, "tool_call_id")), removable, .string, stubber);
    if (eql(role, "assistant")) return if (removable) dropCalls(a, o, d) else item;
    if (eql(role, "user")) return shrinkBlocks(a, o, d, removable, stubber);
    return item;
}

/// The history to install. `removable_before`: items before this index belong
/// to earlier turns (see applyItem).
pub fn apply(a: Allocator, items: []const Value, msgs: []const Msg, p: Plan, d: *const Decisions, removable_before: usize, note: ?Value, stubber: anytype) !std.json.Array {
    var fresh = std.json.Array.init(a);
    try fresh.ensureTotalCapacity(items.len + 1);
    for (msgs, 0..) |m, j| {
        if (p.note_before == j) if (note) |n| try fresh.append(n);
        if (!p.keep[j]) continue;
        for (items[m.lo..m.hi], m.lo..) |item, i| {
            if (try applyItem(a, item, d, i < removable_before, stubber)) |v| try fresh.append(v);
        }
    }
    return fresh;
}

/// The items a summary replaced (#409 reads their artifact paths).
pub fn replaced(a: Allocator, items: []const Value, msgs: []const Msg, p: Plan) ![]const Value {
    var out: std.ArrayList(Value) = .empty;
    for (msgs, p.keep) |m, k| if (!k) try out.appendSlice(a, items[m.lo..m.hi]);
    return out.items;
}

const IdSet = std.StringHashMapUnmanaged(void);

/// Results without an earlier call, and calls without a later result.
fn unpaired(a: Allocator, items: []const Value) !IdSet {
    const msgs = try fold(a, items, true);
    var calls: IdSet = .empty;
    var answered: IdSet = .empty;
    var bad: IdSet = .empty;
    for (msgs) |m| {
        for (m.uses) |u| try calls.put(a, u.id, {});
        for (m.results) |r| {
            if (!calls.contains(r.id)) try bad.put(a, r.id, {});
            try answered.put(a, r.id, {});
        }
    }
    var it = calls.keyIterator();
    while (it.next()) |id| if (!answered.contains(id.*)) try bad.put(a, id.*, {});
    return bad;
}

/// Refuse a history that pairs worse than the one it replaces: a provider
/// rejects an orphaned result or an unanswered call on every request.
pub fn checkPairs(a: Allocator, before: []const Value, after: []const Value) !void {
    const was = try unpaired(a, before);
    const now = try unpaired(a, after);
    var it = now.keyIterator();
    while (it.next()) |id| if (!was.contains(id.*)) return error.UnpairedToolCall;
}
