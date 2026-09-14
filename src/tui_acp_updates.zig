//! ACP transcript decoding, independent of live session and Agent lifecycle.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const tui = @import("tui");
const repl = @import("repl.zig");
const util = @import("util.zig");
const label = @import("agent_tool_label.zig");
const citations = @import("cite_markup.zig");

/// Maps one ACP `session/update` line onto the TUI stream / event queue.
pub const Apply = struct {
    queue: *tui.EventQueue,
    stream: *repl.StreamBuf,
    show_thinking: bool = false,
    reasoning_open: bool = false,
    reasoning_citations: citations.Stream = .{},
    answer_citations: citations.Stream = .{},
    last_title: [160]u8 = undefined,
    last_title_len: usize = 0,

    pub fn reset(self: *Apply) void {
        self.reasoning_citations = .{};
        self.answer_citations = .{};
        self.reasoning_open = false;
    }
};

pub fn applyBuffered(a: *Apply, gpa: Allocator, bytes: []const u8) void {
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |line| applyLine(a, gpa, line);
}

pub fn applyLine(a: *Apply, gpa: Allocator, line: []const u8) void {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return;
    var parsed = std.json.parseFromSlice(Value, gpa, trimmed, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const method = util.strFieldObj(parsed.value.object, "method") orelse return;
    if (!std.mem.eql(u8, method, "session/update")) return;
    const params = parsed.value.object.get("params") orelse return;
    if (params != .object) return;
    const update = params.object.get("update") orelse return;
    if (update != .object) return;
    const kind = util.strFieldObj(update.object, "sessionUpdate") orelse return;
    if (std.mem.eql(u8, kind, "agent_thought_chunk") or std.mem.eql(u8, kind, "agent_message_chunk")) {
        applyChunk(a, std.mem.eql(u8, kind, "agent_thought_chunk"), contentText(update.object) orelse return);
        return;
    }
    if (std.mem.eql(u8, kind, "tool_call")) {
        const title = util.strFieldObj(update.object, "title") orelse "tool";
        const name = util.strFieldObj(update.object, "name") orelse title;
        rememberTitle(a, name);
        if (label.skipTranscript(name)) return;
        a.queue.push(.{ .tool_started = .{ .name = name, .detail = cap(title, 160) } });
        return;
    }
    if (std.mem.eql(u8, kind, "tool_call_update")) {
        if (tui.rawStream()) |raw| raw.len.store(0, .release);
        const title = a.last_title[0..a.last_title_len];
        if (title.len == 0 or label.skipTranscript(title)) return;
        const status = util.strFieldObj(update.object, "status") orelse "completed";
        const failed = std.mem.eql(u8, status, "failed");
        const text = updateText(update.object);
        a.queue.push(.{ .tool_finished = .{
            .name = title,
            .detail = cap(text, 80),
            .is_error = failed,
        } });
    }
}

fn contentText(update: std.json.ObjectMap) ?[]const u8 {
    const content = update.get("content") orelse return null;
    if (content != .object) return null;
    return util.strFieldObj(content.object, "text");
}

fn updateText(update: std.json.ObjectMap) []const u8 {
    const content = update.get("content") orelse return "";
    if (content != .array or content.array.items.len == 0) return "";
    const first = content.array.items[0];
    if (first != .object) return "";
    const inner = first.object.get("content") orelse return "";
    if (inner != .object) return "";
    return util.strFieldObj(inner.object, "text") orelse "";
}

fn rememberTitle(a: *Apply, title: []const u8) void {
    const n = @min(title.len, a.last_title.len);
    @memcpy(a.last_title[0..n], title[0..n]);
    a.last_title_len = n;
}

fn cap(s: []const u8, n: usize) []const u8 {
    const line = if (std.mem.indexOfScalar(u8, s, '\n')) |i| s[0..i] else s;
    return line[0..@min(line.len, n)];
}

/// The in-process transport can pass text directly; wire clients decode into this same path.
pub fn applyChunk(a: *Apply, thinking: bool, text: []const u8) void {
    if (text.len == 0 or (thinking and !a.show_thinking)) return;
    const filter = if (thinking) &a.reasoning_citations else &a.answer_citations;
    // Batch visible bytes: the live tail publishes atomically on each append.
    var visible: [1024]u8 = undefined;
    var len: usize = 0;
    for (text) |c| {
        var scratch: [3]u8 = undefined;
        const clean = filter.byte(c, &scratch);
        if (clean.len == 0) continue;
        if (thinking) {
            a.reasoning_open = true;
        } else if (a.reasoning_open) {
            a.reasoning_open = false;
            a.stream.appendBytes("\n");
        }
        if (len + clean.len > visible.len) {
            a.stream.appendBytes(visible[0..len]);
            len = 0;
        }
        @memcpy(visible[len..][0..clean.len], clean);
        len += clean.len;
    }
    if (len != 0) a.stream.appendBytes(visible[0..len]);
}

test "applyLine: thought then text land on the live tail" {
    var q: tui.EventQueue = .{};
    q.attach(std.testing.allocator);
    defer q.deinit();
    var buf: [128]u8 = undefined;
    var stream: repl.StreamBuf = .{ .buf = &buf };
    var a: Apply = .{ .queue = &q, .stream = &stream, .show_thinking = true };
    applyLine(&a, std.testing.allocator, "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":\"why\"}}}}");
    applyLine(&a, std.testing.allocator, "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"hi\"}}}}");
    const snap = stream.snapshot(std.testing.allocator) orelse return error.NoStream;
    defer std.testing.allocator.free(snap);
    try std.testing.expectEqualStrings("why\nhi", snap);
}

test "applyLine: tool_call then tool_call_update become typed rows" {
    var q: tui.EventQueue = .{};
    q.attach(std.testing.allocator);
    defer q.deinit();
    var buf: [32]u8 = undefined;
    var stream: repl.StreamBuf = .{ .buf = &buf };
    var a: Apply = .{ .queue = &q, .stream = &stream };
    applyLine(&a, std.testing.allocator, "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"tool_call\",\"name\":\"read_file\",\"title\":\"note.txt\",\"kind\":\"read\",\"status\":\"in_progress\"}}}");
    applyLine(&a, std.testing.allocator, "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"tool_call_update\",\"status\":\"completed\",\"content\":[{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":\"ok\\nmore\"}}]}}}");
    const evs = q.drain();
    defer q.free(evs);
    try std.testing.expectEqual(@as(usize, 2), evs.len);
    try std.testing.expectEqualStrings("read_file", evs[0].tool_started.name);
    try std.testing.expectEqualStrings("note.txt", evs[0].tool_started.detail);
    try std.testing.expectEqualStrings("ok", evs[1].tool_finished.detail);
    try std.testing.expect(!evs[1].tool_finished.is_error);
}

test "direct chunks match ACP wire decoding without allocations" {
    var q: tui.EventQueue = .{};
    var direct_buf: [128]u8 = undefined;
    var wire_buf: [128]u8 = undefined;
    var direct: repl.StreamBuf = .{ .buf = &direct_buf };
    var wire: repl.StreamBuf = .{ .buf = &wire_buf };
    var a: Apply = .{ .queue = &q, .stream = &direct, .show_thinking = true };
    var b: Apply = .{ .queue = &q, .stream = &wire, .show_thinking = true };
    applyChunk(&a, true, "why日");
    applyChunk(&a, false, "hello🚀");
    applyLine(&b, std.testing.allocator, "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"text\":\"why日\"}}}}");
    applyLine(&b, std.testing.allocator, "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"text\":\"hello🚀\"}}}}");
    try std.testing.expectEqualStrings(wire.buf[0..wire.len.load(.acquire)], direct.buf[0..direct.len.load(.acquire)]);
    try std.testing.expectEqual(b.reasoning_open, a.reasoning_open);
}

test "hidden reasoning and empty chunks do not alter transcript" {
    var q: tui.EventQueue = .{};
    var buf: [64]u8 = undefined;
    var stream: repl.StreamBuf = .{ .buf = &buf };
    var a: Apply = .{ .queue = &q, .stream = &stream };
    applyChunk(&a, true, "hidden");
    applyChunk(&a, false, "");
    applyChunk(&a, false, "visible");
    try std.testing.expectEqualStrings("visible", stream.buf[0..stream.len.load(.acquire)]);
    try std.testing.expect(!a.reasoning_open);
}

test "ACP citation display filters every byte split and independent channels (#874)" {
    const raw = "before日\u{E200}cite\u{E202}turn0view0\u{E201}after\u{E202}🚀\u{E201}";
    for (0..raw.len + 1) |split| {
        var q: tui.EventQueue = .{};
        var buf: [256]u8 = undefined;
        var stream: repl.StreamBuf = .{ .buf = &buf };
        var a: Apply = .{ .queue = &q, .stream = &stream, .show_thinking = true };
        applyChunk(&a, true, "why\u{E200}cite");
        applyChunk(&a, false, raw[0..split]);
        applyChunk(&a, false, raw[split..]);
        applyChunk(&a, true, "hidden\u{E201}done");
        try std.testing.expectEqualStrings("why\nbefore日after🚀done", buf[0..stream.len.load(.acquire)]);
    }
}

test "ACP citation-only chunks do not add reasoning separators and reset drops partial spans (#874)" {
    var q: tui.EventQueue = .{};
    var buf: [128]u8 = undefined;
    var stream: repl.StreamBuf = .{ .buf = &buf };
    var a: Apply = .{ .queue = &q, .stream = &stream, .show_thinking = true };
    applyLine(&a, std.testing.allocator, "{\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"text\":\"\\ue200cite\\ue202turn0view0\\ue201\"}}}}");
    applyChunk(&a, false, "ok");
    applyChunk(&a, true, "\xee\x88");
    applyChunk(&a, false, "\u{E200}unterminated");
    a.reset();
    applyChunk(&a, true, "fresh");
    applyChunk(&a, false, "answer");
    try std.testing.expectEqualStrings("okfresh\nanswer", buf[0..stream.len.load(.acquire)]);
}
