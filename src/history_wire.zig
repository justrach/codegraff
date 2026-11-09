//! Repair legacy tool payloads on restore and immediately before a request.
const std = @import("std");
const messages = @import("messages.zig");
const Kind = @import("provider.zig").Provider.Kind;

pub const tool_outcome_unknown = "[TOOL_OUTCOME_UNKNOWN: session interrupted while this tool call was in flight; verify state before re-running non-idempotent commands]";
pub const tool_interrupted_readonly = "[TOOL_INTERRUPTED_READONLY: session interrupted while this read-only tool call was in flight; no state was modified, safe to re-run directly]";
pub const tool_not_started = "[TOOL_NOT_STARTED: skipped because an earlier tool call in the batch was interrupted]";

pub fn prepare(a: std.mem.Allocator, kind: Kind, history: *std.json.Array) void {
    messages.sanitizeMessagesUtf8(a, history);
    switch (kind) {
        .openai => {
            messages.normalizeOpenAIHistory(a, history);
            repairOpenAIDanglingBatch(a, history);
        },
        .responses => {
            for (history.items) |*item| {
                if (item.* != .object) continue;
                const typ = item.object.get("type") orelse continue;
                if (typ != .string or !std.mem.eql(u8, typ.string, "function_call_output")) continue;
                repair(a, &item.object, "output", false);
            }
            messages.normalizeResponsesHistory(a, history);
            repairResponsesDanglingBatch(a, history);
        },
        .anthropic => {
            for (history.items) |*item| {
                if (item.* != .object) continue;
                const content = item.object.getPtr("content") orelse continue;
                if (content.* != .array) continue;
                for (content.array.items) |*block| {
                    if (block.* != .object) continue;
                    const typ = block.object.get("type") orelse continue;
                    if (typ != .string or !std.mem.eql(u8, typ.string, "tool_result")) continue;
                    repair(a, &block.object, "content", true);
                }
            }
            repairAnthropicDanglingBatch(a, history);
        },
        .interactions => @import("interactions_steps.zig").normalizeHistory(a, history),
    }
}

fn strField(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = obj.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

fn callIdField(obj: std.json.ObjectMap) []const u8 {
    const cid = strField(obj, "call_id");
    return if (cid.len > 0) cid else strField(obj, "id");
}

pub fn isReadOnlyTool(name: []const u8) bool {
    for ([_][]const u8{
        "read_file",
        "codedb",
        "load_tool_schemas",
        "todo_read",
        "check_job",
        "list_dir",
        "read_image",
    }) |ro| {
        if (std.mem.eql(u8, name, ro)) return true;
    }
    return false;
}

pub fn missingToolTextFor(name: []const u8, missing_idx: usize) []const u8 {
    if (missing_idx > 0) return tool_not_started;
    if (isReadOnlyTool(name)) return tool_interrupted_readonly;
    return tool_outcome_unknown;
}

fn repairOpenAIDanglingBatch(a: std.mem.Allocator, history: *std.json.Array) void {
    var i: usize = 0;
    while (i < history.items.len) {
        const item = history.items[i];
        if (item != .object or !std.mem.eql(u8, strField(item.object, "role"), "assistant")) {
            i += 1;
            continue;
        }
        const tcs = item.object.get("tool_calls") orelse {
            i += 1;
            continue;
        };
        if (tcs != .array or tcs.array.items.len == 0) {
            i += 1;
            continue;
        }
        var j = i + 1;
        while (j < history.items.len) : (j += 1) {
            const next = history.items[j];
            if (next != .object or !std.mem.eql(u8, strField(next.object, "role"), "tool")) break;
        }
        var missing_idx: usize = 0;
        for (tcs.array.items) |tc| {
            if (tc != .object) continue;
            const id = strField(tc.object, "id");
            if (id.len == 0) continue;
            const func = tc.object.get("function");
            const name = if (func) |f| (if (f == .object) strField(f.object, "name") else "") else "";
            var found = false;
            for (history.items[i + 1 .. j]) |res| {
                if (res == .object and std.mem.eql(u8, strField(res.object, "tool_call_id"), id)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                var msg: std.json.ObjectMap = .empty;
                msg.put(a, "role", .{ .string = "tool" }) catch break;
                msg.put(a, "tool_call_id", .{ .string = id }) catch break;
                msg.put(a, "content", .{ .string = missingToolTextFor(name, missing_idx) }) catch break;
                history.insert(j, .{ .object = msg }) catch break;
                j += 1;
                missing_idx += 1;
            }
        }
        i = j;
    }
}

fn isAnthropicToolResultMsg(item: std.json.Value) bool {
    if (item != .object or !std.mem.eql(u8, strField(item.object, "role"), "user")) return false;
    const content = item.object.get("content") orelse return false;
    if (content != .array) return false;
    for (content.array.items) |blk| {
        if (blk == .object and std.mem.eql(u8, strField(blk.object, "type"), "tool_result")) return true;
    }
    return false;
}

fn makeAnthropicToolResultBlock(a: std.mem.Allocator, id: []const u8, text: []const u8) !std.json.Value {
    var blk: std.json.ObjectMap = .empty;
    try blk.put(a, "type", .{ .string = "tool_result" });
    try blk.put(a, "tool_use_id", .{ .string = id });
    try blk.put(a, "content", .{ .string = text });
    try blk.put(a, "is_error", .{ .bool = true });
    return .{ .object = blk };
}

fn repairAnthropicDanglingBatch(a: std.mem.Allocator, history: *std.json.Array) void {
    var i: usize = 0;
    while (i < history.items.len) {
        const item = history.items[i];
        if (item != .object or !std.mem.eql(u8, strField(item.object, "role"), "assistant")) {
            i += 1;
            continue;
        }
        const content = item.object.get("content") orelse {
            i += 1;
            continue;
        };
        if (content != .array) {
            i += 1;
            continue;
        }
        var has_tool_use = false;
        for (content.array.items) |blk| {
            if (blk == .object and std.mem.eql(u8, strField(blk.object, "type"), "tool_use") and strField(blk.object, "id").len > 0) {
                has_tool_use = true;
                break;
            }
        }
        if (!has_tool_use) {
            i += 1;
            continue;
        }
        const has_result_msg = (i + 1 < history.items.len) and isAnthropicToolResultMsg(history.items[i + 1]);
        var missing_idx: usize = 0;
        if (has_result_msg) {
            const ucontent = history.items[i + 1].object.getPtr("content").?;
            for (content.array.items) |blk| {
                if (blk != .object or !std.mem.eql(u8, strField(blk.object, "type"), "tool_use")) continue;
                const id = strField(blk.object, "id");
                if (id.len == 0) continue;
                const name = strField(blk.object, "name");
                var found = false;
                for (ucontent.array.items) |rblk| {
                    if (rblk == .object and std.mem.eql(u8, strField(rblk.object, "type"), "tool_result") and std.mem.eql(u8, strField(rblk.object, "tool_use_id"), id)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    const synth = makeAnthropicToolResultBlock(a, id, missingToolTextFor(name, missing_idx)) catch break;
                    ucontent.array.append(synth) catch break;
                    missing_idx += 1;
                }
            }
            i += 2;
        } else {
            var blocks = std.json.Array.init(a);
            for (content.array.items) |blk| {
                if (blk != .object or !std.mem.eql(u8, strField(blk.object, "type"), "tool_use")) continue;
                const id = strField(blk.object, "id");
                if (id.len == 0) continue;
                const name = strField(blk.object, "name");
                const synth = makeAnthropicToolResultBlock(a, id, missingToolTextFor(name, missing_idx)) catch break;
                blocks.append(synth) catch break;
                missing_idx += 1;
            }
            if (blocks.items.len > 0) {
                var umsg: std.json.ObjectMap = .empty;
                umsg.put(a, "role", .{ .string = "user" }) catch break;
                umsg.put(a, "content", .{ .array = blocks }) catch break;
                history.insert(i + 1, .{ .object = umsg }) catch break;
                i += 2;
            } else {
                i += 1;
            }
        }
    }
}

fn isResponsesBatchItem(item: std.json.Value) bool {
    if (item != .object) return false;
    const t = strField(item.object, "type");
    if (std.mem.eql(u8, t, "function_call") or std.mem.eql(u8, t, "function_call_output") or std.mem.eql(u8, t, "reasoning")) return true;
    if (std.mem.eql(u8, t, "message") and std.mem.eql(u8, strField(item.object, "role"), "assistant")) return true;
    return false;
}

fn repairResponsesDanglingBatch(a: std.mem.Allocator, history: *std.json.Array) void {
    var i: usize = 0;
    while (i < history.items.len) {
        const item = history.items[i];
        if (item != .object or !std.mem.eql(u8, strField(item.object, "type"), "function_call")) {
            i += 1;
            continue;
        }
        var j = i + 1;
        while (j < history.items.len and isResponsesBatchItem(history.items[j])) : (j += 1) {}
        var missing_idx: usize = 0;
        var k = i;
        const orig_end = j;
        while (k < orig_end) : (k += 1) {
            const fc = history.items[k];
            if (fc != .object or !std.mem.eql(u8, strField(fc.object, "type"), "function_call")) continue;
            const cid = callIdField(fc.object);
            if (cid.len == 0) continue;
            const name = strField(fc.object, "name");
            var found = false;
            for (history.items[i..j]) |out| {
                if (out == .object and std.mem.eql(u8, strField(out.object, "type"), "function_call_output") and std.mem.eql(u8, callIdField(out.object), cid)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                var msg: std.json.ObjectMap = .empty;
                msg.put(a, "type", .{ .string = "function_call_output" }) catch break;
                msg.put(a, "call_id", .{ .string = cid }) catch break;
                msg.put(a, "output", .{ .string = missingToolTextFor(name, missing_idx) }) catch break;
                history.insert(j, .{ .object = msg }) catch break;
                j += 1;
                missing_idx += 1;
            }
        }
        i = j;
    }
}

fn repair(a: std.mem.Allocator, obj: *std.json.ObjectMap, field: []const u8, blocks_allowed: bool) void {
    const value = obj.get(field) orelse return;
    if (value == .string) return;
    if (blocks_allowed and value == .array) {
        var blocks = true;
        for (value.array.items) |block| {
            if (block != .object) {
                blocks = false;
                break;
            }
            const typ = block.object.get("type") orelse {
                blocks = false;
                break;
            };
            if (typ != .string) {
                blocks = false;
                break;
            }
        }
        if (blocks) return;
    }
    obj.put(a, field, .{ .string = messages.sanitizeUtf8(a, messages.toolContentString(a, value)) }) catch {};
}

test "legacy tool payloads survive saved-session restore and all request wires" {
    const session = @import("session.zig");
    const writer = @import("session_writer.zig");
    const transcript = @import("session_transcript.zig");
    const Agent = @import("agent.zig").Agent;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    writer.resetForTest();
    defer writer.resetForTest();
    transcript.resetForTest();
    defer transcript.resetForTest();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var keys: @import("provider.zig").Keys = .{ .values = @splat("test-key") };
    for ([_][]const u8{ "anthropic", "openai", "xai" }) |id| {
        var root: Agent = .{
            .gpa = gpa,
            .arena = a,
            .io = io,
            .client = &client,
            .provider = try keys.providerById(id, "fixture-model"),
            .messages = std.json.Array.init(a),
            .sub = false,
            .label = "root",
            .out = null,
            .home = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}),
        };
        const kind = root.provider.kind;
        try std.testing.expect(kind == .anthropic or kind == .openai or kind == .responses);
        const raw = switch (kind) {
            .anthropic => "[{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"one\",\"content\":[61,61,61]},{\"type\":\"tool_result\",\"tool_use_id\":\"two\",\"content\":7}]}]",
            .openai => "[{\"role\":\"tool\",\"tool_call_id\":\"one\",\"content\":[61,61,61]},{\"role\":\"tool\",\"tool_call_id\":\"two\",\"content\":7}]",
            .responses => "[{\"type\":\"function_call_output\",\"call_id\":\"one\",\"output\":[61,61,61]},{\"type\":\"function_call_output\",\"call_id\":\"two\",\"output\":7}]",
            else => unreachable,
        };
        root.messages = (try std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{})).array;
        try root.messages.append(try messages.textMessage(a, "user", "Continue the synthetic session."));
        try session.saveSessionTo(&root, a, tmp.dir, id);
        session.flushSaves();
        root.messages = std.json.Array.init(a);
        try session.loadSession(&root, &keys, a, id);
        const body = try root.buildBody(null, false, false, false);
        defer gpa.free(body);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        const items = parsed.value.object.get(if (kind == .responses) "input" else "messages").?.array.items;
        var results: usize = 0;
        for (items) |item| {
            if (kind == .anthropic) {
                const content = item.object.get("content") orelse continue;
                if (content != .array) continue;
                for (content.array.items) |block| {
                    const typ = block.object.get("type") orelse continue;
                    if (!std.mem.eql(u8, typ.string, "tool_result")) continue;
                    const value = block.object.get("content").?;
                    try std.testing.expect(value == .string);
                    try std.testing.expectEqualStrings(if (results == 0) "===" else "7", value.string);
                    results += 1;
                }
            } else {
                const value = item.object.get(if (kind == .responses) "output" else "content") orelse continue;
                if (kind == .openai and !std.mem.eql(u8, item.object.get("role").?.string, "tool")) continue;
                try std.testing.expect(value == .string);
                try std.testing.expectEqualStrings(if (results == 0) "===" else "7", value.string);
                results += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 2), results);
    }
}

test "legacy repair preserves typed image blocks in tool results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "[{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"one\",\"content\":[{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"data\":\"AA==\"}}]}]}]";
    var history = (try std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{})).array;
    prepare(a, .anthropic, &history);
    try std.testing.expect(history.items[0].object.get("content").?.array.items[0].object.get("content").? == .array);
}

test "crash-tail synthesis marks first missing call TOOL_OUTCOME_UNKNOWN and subsequent missing calls TOOL_NOT_STARTED" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // OpenAI: 3 tool calls in batch; c1 has a result, c2 and c3 are missing at crash tail.
    const openai_raw =
        \\[
        \\  {"role":"assistant","content":null,"tool_calls":[
        \\    {"id":"c1","type":"function","function":{"name":"shell","arguments":"{}"}},
        \\    {"id":"c2","type":"function","function":{"name":"shell","arguments":"{}"}},
        \\    {"id":"c3","type":"function","function":{"name":"shell","arguments":"{}"}}
        \\  ]},
        \\  {"role":"tool","tool_call_id":"c1","content":"done-1"}
        \\]
    ;
    var openai_hist = (try std.json.parseFromSliceLeaky(std.json.Value, a, openai_raw, .{})).array;
    prepare(a, .openai, &openai_hist);
    try std.testing.expectEqual(@as(usize, 4), openai_hist.items.len);
    try std.testing.expectEqualStrings("done-1", openai_hist.items[1].object.get("content").?.string);
    try std.testing.expectEqualStrings("c2", openai_hist.items[2].object.get("tool_call_id").?.string);
    try std.testing.expectEqualStrings(tool_outcome_unknown, openai_hist.items[2].object.get("content").?.string);
    try std.testing.expectEqualStrings("c3", openai_hist.items[3].object.get("tool_call_id").?.string);
    try std.testing.expectEqualStrings(tool_not_started, openai_hist.items[3].object.get("content").?.string);

    // Anthropic: 2 tool_use blocks with no tool_result message at crash tail.
    const anth_raw =
        \\[
        \\  {"role":"assistant","content":[
        \\    {"type":"tool_use","id":"u1","name":"shell","input":{}},
        \\    {"type":"tool_use","id":"u2","name":"shell","input":{}}
        \\  ]}
        \\]
    ;
    var anth_hist = (try std.json.parseFromSliceLeaky(std.json.Value, a, anth_raw, .{})).array;
    prepare(a, .anthropic, &anth_hist);
    try std.testing.expectEqual(@as(usize, 2), anth_hist.items.len);
    const anth_blocks = anth_hist.items[1].object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), anth_blocks.len);
    try std.testing.expectEqualStrings("u1", anth_blocks[0].object.get("tool_use_id").?.string);
    try std.testing.expectEqualStrings(tool_outcome_unknown, anth_blocks[0].object.get("content").?.string);
    try std.testing.expectEqualStrings("u2", anth_blocks[1].object.get("tool_use_id").?.string);
    try std.testing.expectEqualStrings(tool_not_started, anth_blocks[1].object.get("content").?.string);

    // Responses: 2 function_call items at crash tail with no outputs.
    const resp_raw =
        \\[
        \\  {"type":"function_call","call_id":"r1","name":"shell","arguments":"{}"},
        \\  {"type":"function_call","call_id":"r2","name":"shell","arguments":"{}"}
        \\]
    ;
    var resp_hist = (try std.json.parseFromSliceLeaky(std.json.Value, a, resp_raw, .{})).array;
    prepare(a, .responses, &resp_hist);
    try std.testing.expectEqual(@as(usize, 4), resp_hist.items.len);
    try std.testing.expectEqualStrings("r1", resp_hist.items[2].object.get("call_id").?.string);
    try std.testing.expectEqualStrings(tool_outcome_unknown, resp_hist.items[2].object.get("output").?.string);
    try std.testing.expectEqualStrings("r2", resp_hist.items[3].object.get("call_id").?.string);
    try std.testing.expectEqualStrings(tool_not_started, resp_hist.items[3].object.get("output").?.string);
}

test "crash-tail synthesis marks interrupted read-only calls TOOL_INTERRUPTED_READONLY and later calls TOOL_NOT_STARTED" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const openai_raw =
        \\[
        \\  {"role":"assistant","content":null,"tool_calls":[
        \\    {"id":"ro1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"a.py\"}"}},
        \\    {"id":"ro2","type":"function","function":{"name":"codedb","arguments":"{\"command\":\"list_dir .\"}"}}
        \\  ]}
        \\]
    ;
    var openai_hist = (try std.json.parseFromSliceLeaky(std.json.Value, a, openai_raw, .{})).array;
    prepare(a, .openai, &openai_hist);
    try std.testing.expectEqual(@as(usize, 3), openai_hist.items.len);
    try std.testing.expectEqualStrings(tool_interrupted_readonly, openai_hist.items[1].object.get("content").?.string);
    try std.testing.expectEqualStrings(tool_not_started, openai_hist.items[2].object.get("content").?.string);

    const anth_raw =
        \\[
        \\  {"role":"assistant","content":[
        \\    {"type":"tool_use","id":"au1","name":"codedb","input":{"command":"context auth"}},
        \\    {"type":"tool_use","id":"au2","name":"shell","input":{}}
        \\  ]}
        \\]
    ;
    var anth_hist = (try std.json.parseFromSliceLeaky(std.json.Value, a, anth_raw, .{})).array;
    prepare(a, .anthropic, &anth_hist);
    const anth_blocks = anth_hist.items[1].object.get("content").?.array.items;
    try std.testing.expectEqualStrings(tool_interrupted_readonly, anth_blocks[0].object.get("content").?.string);
    try std.testing.expectEqualStrings(tool_not_started, anth_blocks[1].object.get("content").?.string);

    const resp_raw =
        \\[
        \\  {"type":"function_call","call_id":"rr1","name":"read_file","arguments":"{}"},
        \\  {"type":"function_call","call_id":"rr2","name":"shell","arguments":"{}"}
        \\]
    ;
    var resp_hist = (try std.json.parseFromSliceLeaky(std.json.Value, a, resp_raw, .{})).array;
    prepare(a, .responses, &resp_hist);
    try std.testing.expectEqualStrings(tool_interrupted_readonly, resp_hist.items[2].object.get("output").?.string);
    try std.testing.expectEqualStrings(tool_not_started, resp_hist.items[3].object.get("output").?.string);
}
