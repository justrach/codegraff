//! Reassembly of OpenAI Responses SSE events into a response object.

const std = @import("std");
const Value = std.json.Value;

const Agent = @import("agent.zig").Agent;
const policy = @import("agent_request_policy.zig");
const errorCode = policy.errorCode;
const util = @import("util.zig");
const sse_error = @import("sse_error_event.zig");

pub const ResponsesFailure = struct {
    message: []const u8,
    code: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    /// The provider's error class (`error.type`, e.g. invalid_request_error),
    /// so the retry classifiers can tell a deterministic rejection from a
    /// transient one (#748). Empty when the provider sent none.
    etype: []const u8 = "",

    /// The text to test for an auth failure. The ChatGPT plan route's
    /// subscription_sharing_invalid_user 401 names it only in the code.
    pub fn authText(f: ResponsesFailure) []const u8 {
        const c = f.code orelse return f.message;
        return if (policy.isAuthError(c)) c else f.message;
    }
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
    // A steered WS stream (agent_ws_steer) ends a response per steer before the
    // last; their usage is billed there, while the meter keeps the last one.
    var steered_usage = std.json.Array.init(result_arena);
    var resp_id: ?[]const u8 = null; // response.id, for previous_response_id delta continuation (#codex-ws)
    var saw_completed = false;
    var saw_incomplete = false;
    var terminal: @import("agent_length.zig").ResponsesTerminal = .{};
    var err_msg: ?[]const u8 = null;
    var err_code: ?[]const u8 = null;
    var err_rid: ?[]const u8 = null;
    var err_type: []const u8 = "";
    var named_error = false; // the data lines follow an `event: error` name
    var it = std.mem.tokenizeScalar(u8, body, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (!std.mem.startsWith(u8, line, "data:")) {
            named_error = sse_error.namesError(line, named_error);
            continue;
        }
        const payload = std.mem.trim(u8, line["data:".len..], " ");
        if (payload.len == 0 or std.mem.eql(u8, payload, "[DONE]")) continue;
        const v = std.json.parseFromSliceLeaky(Value, scratch, payload, .{ .allocate = .alloc_always }) catch continue;
        if (v != .object) continue;
        const named = named_error;
        named_error = false;
        const tname: []const u8 = if (v.object.get("type")) |tv| (if (tv == .string) tv.string else "") else "";
        // #748: `response.failed`, a typed `error` event, an untyped
        // `{"error":…}` frame, or a bare frame under `event: error` all end
        // the stream as a failure carrying the provider's type and message.
        // Before, the last two parsed as nothing and the body as Unparseable.
        if (std.mem.eql(u8, tname, "response.failed") or std.mem.eql(u8, tname, "error") or named or
            (tname.len == 0 and sse_error.isErrorEvent(v.object, false)))
        {
            err_msg = if (errorMessage(v.object)) |m|
                result_arena.dupe(u8, m) catch "codex stream reported a failure"
            else
                "codex stream reported a failure";
            if (errorCode(v.object)) |code| err_code = result_arena.dupe(u8, code) catch null;
            if (errorRequestId(v.object)) |id| err_rid = result_arena.dupe(u8, id) catch null;
            err_type = result_arena.dupe(u8, errorType(v.object)) catch "";
            continue;
        }
        if (std.mem.eql(u8, tname, "response.output_item.done")) {
            if (v.object.get("item")) |item| try items.append(try util.dupeJsonValue(result_arena, item));
        } else if (std.mem.eql(u8, tname, "response.completed") or std.mem.eql(u8, tname, "response.incomplete")) {
            saw_completed = std.mem.eql(u8, tname, "response.completed");
            saw_incomplete = std.mem.eql(u8, tname, "response.incomplete");
            if (v.object.get("response")) |r| if (r == .object) {
                try terminal.record(result_arena, r.object);
                if (r.object.get("usage")) |u| {
                    if (usage) |earlier| try steered_usage.append(earlier);
                    usage = try util.dupeJsonValue(result_arena, u);
                }
                if (r.object.get("id")) |idv| if (idv == .string) {
                    resp_id = try result_arena.dupe(u8, idv.string);
                };
            };
        } else if (std.mem.eql(u8, tname, @import("agent_ws_steer.zig").applied_type)) {
            // A steer the server applied here: the user's words where the model read them.
            if (v.object.get("text")) |txt| if (txt == .string)
                try items.append(try @import("session_wake.zig").message(result_arena, txt.string));
        }
    }
    // A terminal failure wins even if the stream produced partial completed
    // items first. Committing those items as a successful compaction summary
    // would replace live history with a response the provider explicitly
    // rejected.
    if (err_msg) |m| return .{ .err = .{ .message = m, .code = err_code, .request_id = err_rid, .etype = err_type } };
    if (saw_completed or saw_incomplete or items.items.len > 0) {
        var resp: std.json.ObjectMap = .empty;
        try resp.put(result_arena, "output", .{ .array = items });
        try terminal.apply(result_arena, &resp);
        if (usage) |u| try resp.put(result_arena, "usage", u);
        if (steered_usage.items.len > 0) try resp.put(result_arena, "steered_usage", .{ .array = steered_usage });
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
            const rid = if (errorRequestId(v.object)) |id| result_arena.dupe(u8, id) catch null else null;
            const m = message orelse "codex provider reported an error";
            return .{ .err = .{
                .message = result_arena.dupe(u8, m) catch "unparseable provider error",
                .code = code,
                .request_id = rid,
                .etype = result_arena.dupe(u8, errorType(v.object)) catch "",
            } };
        }
    }
    return error.Unparseable;
}

/// Safe diagnostic for a parsed Responses failure. This is the redaction
/// boundary for WS error frames: only the provider, structured code and message
/// survive — never the raw envelope, echoed request, headers or auth fields.
/// Each field is single-lined and bounded before it reaches last_api_error or
/// the default-on trace.
pub fn failureDiagnostic(allocator: std.mem.Allocator, provider: []const u8, failure: ResponsesFailure) ![]u8 {
    var buf: [768]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeDiagnosticField(&w, provider, 40);
    try w.writeAll(" api error");
    if (failure.code) |code| {
        try w.writeAll(" [");
        try writeDiagnosticField(&w, code, 96);
        try w.writeByte(']');
    }
    try w.writeAll(": ");
    try writeDiagnosticField(&w, failure.message, 384);
    if (failure.request_id) |rid| {
        try w.writeAll(" [");
        try writeDiagnosticField(&w, rid, 96);
        try w.writeByte(']');
    }
    // A spent ChatGPT plan allowance, often mid-stream (ADR 0221).
    if (policy.isPlanUsageLimit(failure.code)) try w.writeAll(" \xe2\x80\x94 " ++ @import("oauth_chatgpt.zig").usage_hint);
    // Reached only after the one refresh-and-retry could not help.
    if (std.mem.eql(u8, provider, "chatgpt-new") and policy.isAuthError(failure.authText())) try w.writeAll(" \xe2\x80\x94 sign in again with `graff login chatgpt`");
    return allocator.dupe(u8, w.buffered());
}

test "failureDiagnostic points a spent ChatGPT plan at its usage page, a rejected user at sign-in" {
    const a = std.testing.allocator;
    const d = try failureDiagnostic(a, "chatgpt-new", .{ .message = "Usage limit reached.", .code = "subscription_sharing_usage_limit_exceeded" });
    defer a.free(d);
    try std.testing.expect(std.mem.startsWith(u8, d, "chatgpt-new api error [subscription_sharing_usage_limit_exceeded]: Usage limit reached."));
    try std.testing.expect(std.mem.endsWith(u8, d, "https://chatgpt.com/settings/usage"));

    // The route's other 401 names the failure only in its code.
    const user: ResponsesFailure = .{ .message = "User cannot be verified.", .code = "subscription_sharing_invalid_user" };
    try std.testing.expectEqualStrings("subscription_sharing_invalid_user", user.authText());
    const signed_out = try failureDiagnostic(a, "chatgpt-new", user);
    defer a.free(signed_out);
    try std.testing.expect(std.mem.endsWith(u8, signed_out, "sign in again with `graff login chatgpt`"));
    // A message that already reads as auth keeps it; a plan limit is no sign-in.
    try std.testing.expectEqualStrings("Unauthorized", (ResponsesFailure{ .message = "Unauthorized", .code = "server_error" }).authText());
    try std.testing.expectEqualStrings("Usage limit reached.", (ResponsesFailure{ .message = "Usage limit reached.", .code = "subscription_sharing_usage_limit_exceeded" }).authText());
}

fn writeDiagnosticField(w: *std.Io.Writer, raw: []const u8, max: usize) !void {
    const prefix = util.utf8Prefix(raw, max);
    for (prefix) |b| try w.writeByte(if (b < 0x20 or b == 0x7f) ' ' else b);
    if (prefix.len < raw.len) try w.writeAll("…");
}

test "failureDiagnostic retains only bounded single-line code and message" {
    const a = std.testing.allocator;
    var long: [513]u8 = @splat('x');
    @memcpy(long[0..13], "bad request\r\n");
    const diagnostic = try failureDiagnostic(a, "codex", .{
        .code = "invalid_request_error\nignored-envelope",
        .message = &long,
    });
    defer a.free(diagnostic);
    try std.testing.expect(std.mem.startsWith(u8, diagnostic, "codex api error [invalid_request_error ignored-envelope]: bad request  "));
    try std.testing.expect(std.mem.endsWith(u8, diagnostic, "…"));
    try std.testing.expect(diagnostic.len < 560);
    try std.testing.expect(std.mem.indexOfScalar(u8, diagnostic, '\n') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, diagnostic, '\r') == null);
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

test "parseResponses preserves output-limit reasons without continuing filtered responses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var agent: Agent = undefined;
    agent.arena = arena_state.allocator();
    agent.scratch_arena = null;
    agent.message_mutation_arena = null;
    for ([_][]const u8{ "max_output_tokens", "content_filter" }) |reason| {
        const body = try std.fmt.allocPrint(agent.arena, "data: {{\"type\":\"response.incomplete\",\"response\":{{\"incomplete_details\":{{\"reason\":\"{s}\"}},\"usage\":{{\"total_tokens\":42}}}}}}\n", .{reason});
        switch (try parseResponses(&agent, body)) {
            .ok => |root| {
                try std.testing.expect(root.get("incomplete").?.bool);
                try std.testing.expectEqual(std.mem.eql(u8, reason, "max_output_tokens"), @import("agent_length.zig").limited(.responses, root));
            },
            .err => return error.TestUnexpectedResult,
        }
    }
}

test "#1019: type:error token-parse frame yields failure.message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = undefined;
    agent.arena = a;
    agent.scratch_arena = null;
    agent.message_mutation_arena = null;
    const body =
        "data: {\"type\":\"error\",\"error\":{\"message\":\"Internal error during token parsing\"}}\n";
    switch (try parseResponses(&agent, body)) {
        .err => |failure| {
            try std.testing.expectEqualStrings("Internal error during token parsing", failure.message);
            try std.testing.expect(failure.code == null);
        },
        .ok => return error.TestUnexpectedResult,
    }
}

// GPT-5.6 Programmatic Tool Calling adds output item types graff does not
// implement: `program`, program-issued `function_call`s carrying `caller`, and
// `program_output`. Unknown items must ride through the parser and
// stepResponses as opaque history (they are valid next-turn input, so the
// server keeps its `call_id`/`caller` pairing) without erroring or hiding the
// final message.
test "GPT-5.6 PTC: unknown `program` / `program_output` items are kept opaque, never an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent = try @import("agent_request_body_responses.zig").testAgentFor(a, "openai", .responses, "gpt-5.6");
    agent.sub = true; // no unstreamed-text surface in a test
    const before = agent.messages.items.len;
    const body =
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"program\",\"id\":\"prog_1\",\"code\":\"print(1)\",\"status\":\"completed\"}}\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"program_output\",\"id\":\"po_1\",\"program_id\":\"prog_1\",\"output\":\"1\"}}\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}}\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"reasoning\":{\"effort\":\"medium\",\"context\":\"all_turns\"},\"usage\":{\"total_tokens\":7}}}\n";
    const parsed = switch (try parseResponses(&agent, body)) {
        .ok => |root| root,
        .err => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 3), parsed.get("output").?.array.items.len);
    try std.testing.expect(parsed.get("incomplete") == null);
    const final = try agent.stepResponses(parsed);
    try std.testing.expectEqualStrings("done", final.?);
    // All three items are history now, verbatim (phase and program fields intact).
    try std.testing.expectEqual(before + 3, agent.messages.items.len);
    try std.testing.expectEqualStrings("program", agent.messages.items[before].object.get("type").?.string);
    try std.testing.expectEqualStrings("program_output", agent.messages.items[before + 1].object.get("type").?.string);
    try std.testing.expectEqualStrings("final_answer", agent.messages.items[before + 2].object.get("phase").?.string);
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
    if (obj.get("detail")) |d| switch (d) {
        .string => |s| return s,
        // The ChatGPT plan route's 401: {"detail":{"error_code":"invalid_token"}}.
        .object => |o| {
            if (o.get("message")) |m| if (m == .string) return m.string;
            if (o.get("error_code")) |c| if (c == .string) return c.string;
        },
        else => {},
    };
    if (obj.get("message")) |m| if (m == .string) return m.string;
    return null;
}

/// The error class from `error.type` or `response.error.type`; the frame's
/// own top-level `type` is the event name, never the class.
fn errorType(obj: std.json.ObjectMap) []const u8 {
    const holder = if (obj.get("response")) |r| (if (r == .object and obj.get("error") == null) r.object else obj) else obj;
    const e = holder.get("error") orelse return "";
    if (e != .object) return "";
    const t = e.object.get("type") orelse return "";
    return if (t == .string) t.string else "";
}

test "#748: error-only Responses SSE is a typed failure, never Unparseable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var agent: Agent = undefined;
    agent.arena = arena_state.allocator();
    agent.scratch_arena = null;
    agent.message_mutation_arena = null;
    const bodies = [_][]const u8{
        // Typed error event (already handled): the class now survives.
        "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"code\":\"invalid_value\",\"message\":\"Invalid tool schema\"}}\n\n",
        // response.failed carries the class under response.error.
        "event: response.failed\ndata: {\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"type\":\"invalid_request_error\",\"code\":\"invalid_value\",\"message\":\"Invalid tool schema\"}}}\n\n",
        // An untyped frame from a proxy used to be skipped, leaving the body Unparseable.
        "event: error\ndata: {\"error\":{\"type\":\"invalid_request_error\",\"code\":\"invalid_value\",\"message\":\"Invalid tool schema\"}}\n\n",
    };
    for (bodies) |body| switch (try parseResponses(&agent, body)) {
        .err => |failure| {
            try std.testing.expectEqualStrings("Invalid tool schema", failure.message);
            try std.testing.expectEqualStrings("invalid_value", failure.code.?);
            try std.testing.expectEqualStrings("invalid_request_error", failure.etype);
        },
        .ok => return error.TestUnexpectedResult,
    };
    // A bare frame is a failure only because the SSE event named it one.
    switch (try parseResponses(&agent, "event: error\ndata: {\"message\":\"Upstream rejected the request\",\"code\":\"bad_request\"}\n\n")) {
        .err => |failure| {
            try std.testing.expectEqualStrings("Upstream rejected the request", failure.message);
            try std.testing.expectEqualStrings("bad_request", failure.code.?);
        },
        .ok => return error.TestUnexpectedResult,
    }
    // The class decides the retry: an invalid request is deterministic, an
    // overload stays on the transient ladder.
    const gw = @import("agent_gateway_retry.zig");
    try std.testing.expect(!gw.isTransientServerError("invalid_request_error", "invalid_value", "Invalid tool schema"));
    try std.testing.expect(!gw.isShortGatewayFlake("invalid_request_error", null, "An error occurred while processing your request."));
    try std.testing.expect(gw.isShortGatewayFlake("", null, "An error occurred while processing your request."));
    try std.testing.expect(gw.isTransientServerError("server_error", null, "The server is overloaded"));
}

test "parseResponses reads the ChatGPT plan route's expired-token envelope" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var agent: Agent = undefined;
    agent.arena = arena_state.allocator();
    agent.scratch_arena = null;
    agent.message_mutation_arena = null;
    switch (try parseResponses(&agent, "{\"detail\":{\"error_code\":\"invalid_token\"}}\n")) {
        .err => |failure| {
            try std.testing.expectEqualStrings("invalid_token", failure.message);
            try std.testing.expectEqualStrings("invalid_token", failure.code.?);
            try std.testing.expect(policy.isAuthError(failure.message));
        },
        .ok => return error.TestUnexpectedResult,
    }
}

/// Public error envelopes may carry a join id (`error.request_id`, top-level
/// `request_id`, or the Responses `response.error` copy). Empty strings are
/// treated as absent so a missing field never prints as `[]`.
pub fn errorRequestId(obj: std.json.ObjectMap) ?[]const u8 {
    if (obj.get("error")) |e| {
        if (e == .object) {
            if (e.object.get("request_id")) |m| if (m == .string and m.string.len > 0) return m.string;
        }
    }
    if (obj.get("response")) |r| if (r == .object) {
        if (r.object.get("error")) |e| if (e == .object) {
            if (e.object.get("request_id")) |m| if (m == .string and m.string.len > 0) return m.string;
        };
        if (r.object.get("request_id")) |m| if (m == .string and m.string.len > 0) return m.string;
    };
    if (obj.get("request_id")) |m| if (m == .string and m.string.len > 0) return m.string;
    return null;
}

test "failureDiagnostic includes request_id when present and omits when absent" {
    const a = std.testing.allocator;
    const with_id = try failureDiagnostic(a, "openai", .{
        .message = "temporarily unavailable",
        .code = "service_unavailable",
        .request_id = "cg_req_abc",
    });
    defer a.free(with_id);
    try std.testing.expectEqualStrings("openai api error [service_unavailable]: temporarily unavailable [cg_req_abc]", with_id);

    const without = try failureDiagnostic(a, "openai", .{
        .message = "temporarily unavailable",
        .code = "service_unavailable",
    });
    defer a.free(without);
    try std.testing.expectEqualStrings("openai api error [service_unavailable]: temporarily unavailable", without);
    try std.testing.expect(std.mem.indexOf(u8, without, "cg_req_") == null);
}

test "parseResponses copies request_id from JSON envelope and SSE failed event" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = undefined;
    agent.arena = a;
    agent.scratch_arena = null;
    agent.message_mutation_arena = null;

    const json_body =
        "{\"type\":\"error\",\"error\":{\"message\":\"temporarily unavailable\",\"type\":\"service_unavailable\",\"code\":\"service_unavailable\",\"request_id\":\"cg_req_json\"}}";
    switch (try parseResponses(&agent, json_body)) {
        .err => |failure| {
            try std.testing.expectEqualStrings("temporarily unavailable", failure.message);
            try std.testing.expectEqualStrings("service_unavailable", failure.code.?);
            try std.testing.expectEqualStrings("cg_req_json", failure.request_id.?);
        },
        .ok => return error.TestUnexpectedResult,
    }

    const no_id_body =
        "{\"type\":\"error\",\"error\":{\"message\":\"temporarily unavailable\",\"code\":\"service_unavailable\"}}";
    switch (try parseResponses(&agent, no_id_body)) {
        .err => |failure| try std.testing.expect(failure.request_id == null),
        .ok => return error.TestUnexpectedResult,
    }

    const failed_body =
        "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"summary rejected\",\"code\":\"context_length_exceeded\",\"request_id\":\"cg_req_sse\"}}}\n";
    switch (try parseResponses(&agent, failed_body)) {
        .err => |failure| try std.testing.expectEqualStrings("cg_req_sse", failure.request_id.?),
        .ok => return error.TestUnexpectedResult,
    }
}

test "errorRequestId reads nested, Responses, and top-level fields; ignores empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nested: std.json.ObjectMap = .empty;
    try nested.put(a, "request_id", .{ .string = "cg_req_nested" });
    var root1: std.json.ObjectMap = .empty;
    try root1.put(a, "error", .{ .object = nested });
    try std.testing.expectEqualStrings("cg_req_nested", errorRequestId(root1).?);

    var resp_err: std.json.ObjectMap = .empty;
    try resp_err.put(a, "request_id", .{ .string = "cg_req_resp" });
    var resp: std.json.ObjectMap = .empty;
    try resp.put(a, "error", .{ .object = resp_err });
    var root2: std.json.ObjectMap = .empty;
    try root2.put(a, "response", .{ .object = resp });
    try std.testing.expectEqualStrings("cg_req_resp", errorRequestId(root2).?);

    var root3: std.json.ObjectMap = .empty;
    try root3.put(a, "request_id", .{ .string = "cg_req_top" });
    try std.testing.expectEqualStrings("cg_req_top", errorRequestId(root3).?);

    var empty_id: std.json.ObjectMap = .empty;
    try empty_id.put(a, "request_id", .{ .string = "" });
    var root4: std.json.ObjectMap = .empty;
    try root4.put(a, "error", .{ .object = empty_id });
    try std.testing.expect(errorRequestId(root4) == null);

    var root5: std.json.ObjectMap = .empty;
    try root5.put(a, "message", .{ .string = "hi" });
    try std.testing.expect(errorRequestId(root5) == null);
}
