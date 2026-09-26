//! ask_user over ACP. A client that advertised `elicitation.form` gets the
//! standard `elicitation/create` form request; a client that opted in with
//! `_meta["graff/askUser"]` gets graff's `gui_ask_user`. Any other client
//! cannot show the question, so ask_user must return at once: waiting for an
//! answer that can never arrive froze the turn until the user cancelled it.
const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const util = @import("util.zig");
const acp_ask = @import("acp_ask.zig");

pub const Mode = enum { none, elicitation, legacy };

/// Latched at `initialize` (one ACP connection per process).
pub var mode: Mode = .none;
var seq = std.atomic.Value(u64).init(0);
/// The one outstanding request; 0 when none. A late or repeated response to
/// an earlier request must never answer a later question.
var pending = std.atomic.Value(u64).init(0);

pub const request_prefix = "graff-elicit-";

pub const unsupported_text =
    "This ACP client cannot show questions mid-turn, so nobody will see this one. " ++
    "Do not ask again: make a reasonable, reversible assumption and continue, " ++
    "or finish the turn and put the question in your reply.";

pub fn configure(params: ?Value) void {
    mode = detect(params);
    pending.store(0, .release);
}

/// v1 sends `clientCapabilities`, v2 `capabilities`; the markers are the same.
fn detect(params: ?Value) Mode {
    const p = params orelse return .none;
    if (p != .object) return .none;
    const caps = p.object.get("clientCapabilities") orelse p.object.get("capabilities") orelse return .none;
    if (caps != .object) return .none;
    if (caps.object.get("elicitation")) |e| if (e == .object) if (e.object.get("form")) |form| if (form == .object) return .elicitation;
    if (caps.object.get("_meta")) |meta| if (meta == .object) if (meta.object.get("graff/askUser")) |v| if (v == .bool and v.bool) return .legacy;
    return .none;
}

fn optionLabel(opt: Value) ?[]const u8 {
    if (opt == .string) return opt.string;
    if (opt != .object) return null;
    return util.strFieldObj(opt.object, "label") orelse util.strFieldObj(opt.object, "text") orelse util.strFieldObj(opt.object, "value");
}

/// Choices become an `enum` only when every option has a label; otherwise the
/// answer stays free text so a valid reply is never unrepresentable.
fn choices(input: Value) ?[]const Value {
    if (input != .object) return null;
    const opts = input.object.get("options") orelse return null;
    if (opts != .array or opts.array.items.len < 2) return null;
    for (opts.array.items) |opt| if (optionLabel(opt) == null) return null;
    return opts.array.items;
}

/// `elicitation/create` in form mode with one required `answer` field.
pub fn writeRequest(w: *Io.Writer, sid: []const u8, question: []const u8, input: Value) !void {
    const n = seq.fetchAdd(1, .monotonic) + 1;
    pending.store(n, .release);
    var id_buf: [48]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, request_prefix ++ "{d}", .{n});
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(id);
    try s.objectField("method");
    try s.write("elicitation/create");
    try s.objectField("params");
    try s.beginObject();
    try s.objectField("sessionId");
    try s.write(sid);
    try s.objectField("mode");
    try s.write("form");
    try s.objectField("message");
    try s.write(question);
    try s.objectField("requestedSchema");
    try s.beginObject();
    try s.objectField("type");
    try s.write("object");
    try s.objectField("properties");
    try s.beginObject();
    try s.objectField("answer");
    try s.beginObject();
    try s.objectField("type");
    try s.write("string");
    try s.objectField("title");
    try s.write("Answer");
    if (choices(input)) |opts| {
        try s.objectField("enum");
        try s.beginArray();
        for (opts) |opt| try s.write(optionLabel(opt).?);
        try s.endArray();
    }
    try s.endObject();
    try s.endObject();
    try s.objectField("required");
    try s.write(&[_][]const u8{"answer"});
    try s.endObject();
    try s.endObject();
    try s.endObject();
    try w.writeByte('\n');
}

/// A client response to our request (from the stdin pump). Returns true when
/// the line was ours, answered or stale.
pub fn accept(value: Value) bool {
    if (value != .object or value.object.contains("method")) return false;
    const id = util.strFieldObj(value.object, "id") orelse return false;
    if (!std.mem.startsWith(u8, id, request_prefix)) return false;
    const n = std.fmt.parseInt(u64, id[request_prefix.len..], 10) catch return true;
    if (n == 0 or pending.cmpxchgStrong(n, 0, .acq_rel, .acquire) != null) return true;
    const result = value.object.get("result") orelse {
        _ = acp_ask.reply("", true);
        return true;
    };
    if (result == .object and std.mem.eql(u8, util.strFieldObj(result.object, "action") orelse "", "accept")) {
        if (result.object.get("content")) |content| if (content == .object) if (util.strFieldObj(content.object, "answer")) |answer|
            if (acp_ask.reply(answer, false)) return true;
    }
    // decline, cancel, an empty answer, or a malformed result.
    _ = acp_ask.reply("", true);
    return true;
}

/// The waiter is done (answered or cancelled); later responses are stale.
pub fn finish() void {
    pending.store(0, .release);
}

const testing = std.testing;

fn parse(a: std.mem.Allocator, json: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, a, json, .{});
}

test "ask mode follows the client's capabilities" {
    defer configure(null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    configure(try parse(a, "{\"protocolVersion\":1,\"clientCapabilities\":{\"fs\":{}}}"));
    try testing.expectEqual(Mode.none, mode);
    configure(try parse(a, "{\"clientCapabilities\":{\"elicitation\":{\"url\":{}}}}"));
    try testing.expectEqual(Mode.none, mode);
    configure(try parse(a, "{\"clientCapabilities\":{\"elicitation\":{\"form\":null}}}"));
    try testing.expectEqual(Mode.none, mode);
    configure(try parse(a, "{\"clientCapabilities\":{\"elicitation\":{\"form\":{}}}}"));
    try testing.expectEqual(Mode.elicitation, mode);
    configure(try parse(a, "{\"capabilities\":{\"elicitation\":{\"form\":{}}}}"));
    try testing.expectEqual(Mode.elicitation, mode);
    configure(try parse(a, "{\"clientCapabilities\":{\"_meta\":{\"graff/askUser\":true}}}"));
    try testing.expectEqual(Mode.legacy, mode);
    configure(try parse(a, "{\"clientCapabilities\":{\"_meta\":{\"graff/askUser\":true},\"elicitation\":{\"form\":{}}}}"));
    try testing.expectEqual(Mode.elicitation, mode);
}

test "elicitation request is a form with an answer field and option enum" {
    defer finish();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Io.Writer.Allocating = .init(a);
    try writeRequest(&out.writer, "s1", "Which target?", try parse(a, "{\"options\":[\"npm\",{\"label\":\"GitHub\"}]}"));
    const msg = try parse(a, out.writer.buffered());
    try testing.expectEqualStrings("elicitation/create", msg.object.get("method").?.string);
    const params = msg.object.get("params").?.object;
    try testing.expectEqualStrings("form", params.get("mode").?.string);
    try testing.expectEqualStrings("Which target?", params.get("message").?.string);
    const answer = params.get("requestedSchema").?.object.get("properties").?.object.get("answer").?.object;
    try testing.expectEqual(@as(usize, 2), answer.get("enum").?.array.items.len);
    out.clearRetainingCapacity();
    try writeRequest(&out.writer, "s1", "Free?", try parse(a, "{\"options\":[\"one\",5]}"));
    try testing.expect(std.mem.indexOf(u8, out.writer.buffered(), "\"enum\"") == null);
}

test "responses answer only the outstanding request" {
    acp_ask.attach(testing.io, testing.allocator);
    defer acp_ask.detach();
    defer finish();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sink: Io.Writer.Allocating = .init(a);
    try writeRequest(&sink.writer, "s", "q", .null);
    const id = pending.load(.acquire);
    const stale = try std.fmt.allocPrint(a, "{{\"id\":\"graff-elicit-{d}\",\"result\":{{\"action\":\"accept\",\"content\":{{\"answer\":\"old\"}}}}}}", .{id + 7});
    try testing.expect(accept(try parse(a, stale)));
    const good = try std.fmt.allocPrint(a, "{{\"id\":\"graff-elicit-{d}\",\"result\":{{\"action\":\"accept\",\"content\":{{\"answer\":\"npm\"}}}}}}", .{id});
    try testing.expect(accept(try parse(a, good)));
    try testing.expect(accept(try parse(a, good))); // repeated: consumed, ignored
    const got = try acp_ask.wait(a);
    try testing.expectEqualStrings("npm", got.text);
    try testing.expect(!got.cancelled);
    try testing.expect(!accept(try parse(a, "{\"id\":\"graff-permission-1\",\"result\":{}}")));
}

test "decline and cancel end the question as cancelled" {
    acp_ask.attach(testing.io, testing.allocator);
    defer acp_ask.detach();
    defer finish();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sink: Io.Writer.Allocating = .init(a);
    try writeRequest(&sink.writer, "s", "q", .null);
    const decline = try std.fmt.allocPrint(a, "{{\"id\":\"graff-elicit-{d}\",\"result\":{{\"action\":\"decline\"}}}}", .{pending.load(.acquire)});
    try testing.expect(accept(try parse(a, decline)));
    try testing.expect((try acp_ask.wait(a)).cancelled);
}
