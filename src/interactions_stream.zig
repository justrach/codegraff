//! Reassemble Google's Interactions SSE into the non-streaming Interaction
//! shape the step functions read, mirroring what assembleOpenAI/assembleAnthropic
//! do for their wires.
//!
//! The event vocabulary (named SSE events, `data:` payload also carries
//! `event_type`):
//!
//!   interaction.created       {"interaction":{"id","status","model"}}
//!   step.start                {"index":0,"step":{"type":"thought"}}
//!   step.delta                {"index":0,"delta":{"type":"thought_signature","signature":"…"}}
//!                             {"index":1,"delta":{"type":"text","text":"…"}}
//!                             {"index":1,"delta":{"type":"arguments_delta","arguments":"{\"a\":1}"}}
//!   step.stop                 {"index":1}
//!   interaction.completed     {"interaction":{"status":"completed"|"requires_action","usage":{…}}}
//!   done                      [DONE]
//!
//! `arguments` arrives as chunks of a JSON *string* but must be echoed back as
//! a JSON *object*, so it is accumulated and parsed once at the end.

const std = @import("std");
const Value = std.json.Value;

const Agent = @import("agent.zig").Agent;

/// One in-flight step. `text` and `args` accumulate across deltas.
const StepAcc = struct {
    kind: []const u8 = "",
    id: []const u8 = "",
    name: []const u8 = "",
    signature: []const u8 = "",
    text: std.ArrayList(u8) = .empty,
    args: std.ArrayList(u8) = .empty,
};

fn ssePayload(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "data:")) return null;
    return std.mem.trim(u8, line["data:".len..], " \t\r");
}

fn str(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

pub fn assemble(self: *Agent, body: []const u8) !?std.json.ObjectMap {
    const arena = self.messageMutationAlloc();
    var steps: std.ArrayList(StepAcc) = .empty;
    var usage: ?Value = null;
    var status: []const u8 = "";
    var interaction_id: []const u8 = "";
    var saw_event = false;

    var it = std.mem.tokenizeScalar(u8, body, '\n');
    while (it.next()) |raw_line| {
        const payload = ssePayload(raw_line) orelse continue;
        if (std.mem.eql(u8, payload, "[DONE]")) {
            saw_event = true;
            continue;
        }
        // #124: the per-event parse tree is transient — every string kept below
        // is duped into `arena` before the scratch allocator is reset.
        const v = std.json.parseFromSliceLeaky(Value, self.scratchAlloc(), payload, .{ .allocate = .alloc_always }) catch continue;
        if (v != .object) continue;
        saw_event = true;

        if (v.object.get("interaction")) |ix| if (ix == .object) {
            if (str(ix.object, "id").len > 0) interaction_id = try arena.dupe(u8, str(ix.object, "id"));
            if (str(ix.object, "status").len > 0) status = try arena.dupe(u8, str(ix.object, "status"));
            if (ix.object.get("usage")) |u| usage = try @import("util.zig").dupeJsonValue(arena, u);
        };

        const idx: usize = blk: {
            const i = v.object.get("index") orelse break :blk std.math.maxInt(usize);
            break :blk if (i == .integer and i.integer >= 0) @intCast(i.integer) else std.math.maxInt(usize);
        };
        if (idx == std.math.maxInt(usize)) continue;
        while (steps.items.len <= idx) try steps.append(arena, .{});
        const acc = &steps.items[idx];

        if (v.object.get("step")) |st| if (st == .object) {
            if (str(st.object, "type").len > 0) acc.kind = try arena.dupe(u8, str(st.object, "type"));
            if (str(st.object, "id").len > 0) acc.id = try arena.dupe(u8, str(st.object, "id"));
            if (str(st.object, "name").len > 0) acc.name = try arena.dupe(u8, str(st.object, "name"));
        };
        if (v.object.get("delta")) |d| if (d == .object) {
            if (str(d.object, "text").len > 0) try acc.text.appendSlice(arena, str(d.object, "text"));
            if (str(d.object, "signature").len > 0) acc.signature = try arena.dupe(u8, str(d.object, "signature"));
            if (str(d.object, "arguments").len > 0) try acc.args.appendSlice(arena, str(d.object, "arguments"));
        };
    }
    if (!saw_event) return null;

    var out_steps = std.json.Array.init(arena);
    for (steps.items) |st| {
        if (st.kind.len == 0) continue;
        var obj: std.json.ObjectMap = .empty;
        try obj.put(arena, "type", .{ .string = st.kind });
        if (std.mem.eql(u8, st.kind, "thought")) {
            if (st.signature.len > 0) try obj.put(arena, "signature", .{ .string = st.signature });
        } else if (std.mem.eql(u8, st.kind, "model_output")) {
            var part: std.json.ObjectMap = .empty;
            try part.put(arena, "type", .{ .string = "text" });
            try part.put(arena, "text", .{ .string = st.text.items });
            var content = std.json.Array.init(arena);
            try content.append(.{ .object = part });
            try obj.put(arena, "content", .{ .array = content });
        } else if (std.mem.eql(u8, st.kind, "function_call")) {
            if (st.id.len > 0) try obj.put(arena, "id", .{ .string = st.id });
            if (st.name.len > 0) try obj.put(arena, "name", .{ .string = st.name });
            // Chunks spell a JSON string; the wire wants the object back.
            const parsed: Value = if (st.args.items.len == 0)
                .{ .object = .empty }
            else
                std.json.parseFromSliceLeaky(Value, arena, st.args.items, .{ .allocate = .alloc_always }) catch .{ .object = .empty };
            try obj.put(arena, "arguments", if (parsed == .object) parsed else .{ .object = .empty });
        }
        try out_steps.append(.{ .object = obj });
    }

    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "steps", .{ .array = out_steps });
    if (status.len > 0) try root.put(arena, "status", .{ .string = status });
    if (interaction_id.len > 0) try root.put(arena, "id", .{ .string = interaction_id });
    if (usage) |u| try root.put(arena, "usage", u);
    return root;
}
