//! Reassembly of OpenAI Responses SSE events into a response object.

const std = @import("std");
const Value = std.json.Value;

const Agent = @import("agent.zig").Agent;
const policy = @import("agent_request_policy.zig");
const errorCode = policy.errorCode;
const util = @import("util.zig");

pub const ResponsesFailure = struct {
    message: []const u8,
    code: ?[]const u8 = null,
};

pub const ResponsesResult = union(enum) { ok: std.json.ObjectMap, err: ResponsesFailure };

pub fn parseResponses(self: *Agent, body: []const u8) !ResponsesResult {
    // The final output items arrive as individual `response.output_item.done`
    // events; `response.completed` carries usage but an empty output array.
    // Collect the done-items and synthesize a {output, usage} object.
    //
    // #124 slice 2b: every SSE event of the stream parses on the per-request
    // scratch arena — the text deltas are the bulk of the body and their parse
    // trees used to pile up on the session arena forever (~30-45 KB/turn
    // measured). Only what escapes this request is detached onto the session
    // arena: the output items (stepResponses appends them to history verbatim)
    // via dupeJsonValue, and the usage/id/error scalars.
    const scratch = self.scratchAlloc();
    const result_arena = self.messageMutationAlloc();
    var items = std.json.Array.init(result_arena);
    var usage: ?Value = null;
    var resp_id: ?[]const u8 = null; // response.id, for previous_response_id delta continuation (#codex-ws)
    var saw_completed = false;
    var saw_incomplete = false;
    var err_msg: ?[]const u8 = null;
    var err_code: ?[]const u8 = null;
    var it = std.mem.tokenizeScalar(u8, body, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const payload = std.mem.trim(u8, line["data:".len..], " ");
        if (payload.len == 0 or std.mem.eql(u8, payload, "[DONE]")) continue;
        const v = std.json.parseFromSliceLeaky(Value, scratch, payload, .{ .allocate = .alloc_always }) catch continue;
        if (v != .object) continue;
        const t = v.object.get("type") orelse continue;
        if (t != .string) continue;
        if (std.mem.eql(u8, t.string, "response.output_item.done")) {
            if (v.object.get("item")) |item| try items.append(try util.dupeJsonValue(result_arena, item));
        } else if (std.mem.eql(u8, t.string, "response.completed") or std.mem.eql(u8, t.string, "response.incomplete")) {
            saw_completed = std.mem.eql(u8, t.string, "response.completed");
            saw_incomplete = std.mem.eql(u8, t.string, "response.incomplete");
            if (v.object.get("response")) |r| if (r == .object) {
                if (r.object.get("usage")) |u| usage = try util.dupeJsonValue(result_arena, u);
                if (r.object.get("id")) |idv| if (idv == .string) {
                    resp_id = try result_arena.dupe(u8, idv.string);
                };
            };
        } else if (std.mem.eql(u8, t.string, "response.failed") or std.mem.eql(u8, t.string, "error")) {
            err_msg = if (errorMessage(v.object)) |m|
                result_arena.dupe(u8, m) catch "codex stream reported a failure"
            else
                "codex stream reported a failure";
            if (errorCode(v.object)) |code| err_code = result_arena.dupe(u8, code) catch null;
        }
    }
    // A terminal failure wins even if the stream produced partial completed
    // items first. Committing those items as a successful compaction summary
    // would replace live history with a response the provider explicitly
    // rejected.
    if (err_msg) |m| return .{ .err = .{ .message = m, .code = err_code } };
    if (saw_completed or saw_incomplete or items.items.len > 0) {
        var resp: std.json.ObjectMap = .empty;
        try resp.put(result_arena, "output", .{ .array = items });
        if (usage) |u| try resp.put(result_arena, "usage", u);
        if (resp_id) |rid| try resp.put(result_arena, "id", .{ .string = rid });
        // Item-only streams are tolerated for ordinary turns, but are not a
        // safe sole source for a compaction handoff: no terminal completed event
        // means the transport may have ended mid-summary.
        if (!saw_completed) try resp.put(result_arena, "incomplete", .{ .bool = true });
        return .{ .ok = resp };
    }
    // Not an SSE stream — maybe a JSON error body (401, rate limit, …). The
    // message is duped off the scratch parse: sayApiError re-formats it onto
    // the session arena, but the retry loop may also inspect it after another
    // rebuild iteration reset the scratch arena.
    const v = std.json.parseFromSliceLeaky(Value, scratch, body, .{ .allocate = .alloc_always }) catch return error.Unparseable;
    if (v == .object) {
        const message = errorMessage(v.object);
        const raw_code = errorCode(v.object);
        if (message != null or raw_code != null) {
            const code = if (raw_code) |c| result_arena.dupe(u8, c) catch null else null;
            const m = message orelse "codex provider reported an error";
            return .{ .err = .{
                .message = result_arena.dupe(u8, m) catch "unparseable provider error",
                .code = code,
            } };
        }
    }
    return error.Unparseable;
}

test "parseResponses: terminal failure beats partial items; incomplete stays marked" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = undefined;
    agent.arena = a;
    agent.scratch_arena = null;
    agent.message_mutation_arena = null;

    const item_event =
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"partial\"}]}}\n";
    const failed_body = item_event ++
        "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"summary rejected\",\"code\":\"context_length_exceeded\"}}}\n";
    switch (try parseResponses(&agent, failed_body)) {
        .err => |failure| {
            try std.testing.expectEqualStrings("summary rejected", failure.message);
            try std.testing.expectEqualStrings("context_length_exceeded", failure.code.?);
        },
        .ok => return error.TestUnexpectedResult,
    }

    const incomplete_body = item_event ++
        "data: {\"type\":\"response.incomplete\",\"response\":{\"usage\":{\"total_tokens\":42}}}\n";
    switch (try parseResponses(&agent, incomplete_body)) {
        .ok => |root| {
            try std.testing.expectEqual(@as(usize, 1), root.get("output").?.array.items.len);
            try std.testing.expect(root.get("incomplete").?.bool);
        },
        .err => return error.TestUnexpectedResult,
    }

    switch (try parseResponses(&agent, item_event)) {
        .ok => |root| try std.testing.expect(root.get("incomplete").?.bool),
        .err => return error.TestUnexpectedResult,
    }

    switch (try parseResponses(&agent, "{\"error\":{\"code\":\"context_length_exceeded\"}}")) {
        .err => |failure| {
            try std.testing.expectEqualStrings("context_length_exceeded", failure.code.?);
            try std.testing.expect(failure.message.len > 0);
        },
        .ok => return error.TestUnexpectedResult,
    }
}

pub fn errorMessage(obj: std.json.ObjectMap) ?[]const u8 {
    if (obj.get("error")) |e| {
        if (e == .object) {
            if (e.object.get("message")) |m| if (m == .string) return m.string;
        } else if (e == .string) return e.string;
    }
    if (obj.get("response")) |r| if (r == .object) {
        if (r.object.get("error")) |e| if (e == .object) {
            if (e.object.get("message")) |m| if (m == .string) return m.string;
        };
    };
    if (obj.get("detail")) |d| if (d == .string) return d.string;
    if (obj.get("message")) |m| if (m == .string) return m.string;
    return null;
}
