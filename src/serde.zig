//! Session persistence + request-body serialization (std-only leaf): remember
//! the last provider+model, load/save the input-history file, and the two
//! wire-format message serializers — the Anthropic prompt-caching writer (marks
//! the final user turn with a cache_control breakpoint) and the OpenAI
//! assistant-tool-call content normalizer. Split out of main.zig (600-line
//! goal). main aliases all 6 entry points back.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const util = @import("util.zig");

const history_file = ".simple-harness-history";
const model_file = ".simple-harness-model"; // remembers the last-selected provider+model

/// Persist the active provider+model so the next launch starts on it.
pub fn saveModel(io: Io, home: []const u8, pid: []const u8, model: []const u8) void {
    if (home.len == 0) return;
    var pbuf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ home, model_file }) catch return;
    const f = Io.Dir.cwd().createFile(io, path, .{}) catch return;
    defer f.close(io);
    var wbuf: [256]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    fw.interface.print("{s}\n{s}\n", .{ pid, model }) catch return;
    fw.interface.flush() catch return;
}

/// Load the remembered provider+model (pid on line 1, model on line 2).
pub fn loadModel(io: Io, arena: Allocator, home: []const u8) ?struct { pid: []const u8, model: []const u8 } {
    if (home.len == 0) return null;
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ home, model_file }) catch return null;
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch return null;
    var it = std.mem.splitScalar(u8, data, '\n');
    const pid = std.mem.trim(u8, it.next() orelse return null, " \t\r");
    const model = std.mem.trim(u8, it.next() orelse return null, " \t\r");
    if (pid.len == 0 or model.len == 0) return null;
    return .{ .pid = pid, .model = model };
}
const history_cap = 1000; // keep the most recent N input lines

/// Load persisted ↑/↓ input history from ~/.simple-harness-history into the
/// in-memory list (gpa-owned entries; freed with the list at exit). Capped to
/// the last `history_cap` lines.
pub fn loadHistory(io: Io, gpa: Allocator, home: []const u8, history: *std.ArrayList([]const u8)) void {
    const path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ home, history_file }) catch return;
    defer gpa.free(path);
    const data = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 20)) catch return;
    defer gpa.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |ln| {
        const l = std.mem.trim(u8, ln, " \t\r");
        if (l.len == 0 or !util.rememberInput(l)) continue;
        const dup = gpa.dupe(u8, l) catch continue;
        history.append(gpa, dup) catch gpa.free(dup);
    }
    if (history.items.len > history_cap) {
        const drop = history.items.len - history_cap;
        for (history.items[0..drop]) |h| gpa.free(h);
        std.mem.copyForwards([]const u8, history.items[0..], history.items[drop..]);
        history.shrinkRetainingCapacity(history_cap);
    }
}

/// Write the (last `history_cap`) input lines back to ~/.simple-harness-history.
pub fn saveHistory(io: Io, arena: Allocator, home: []const u8, history: []const []const u8) void {
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ home, history_file }) catch return;
    const f = Io.Dir.cwd().createFile(io, path, .{}) catch return;
    defer f.close(io);
    var wbuf: [8 * 1024]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    const start = if (history.len > history_cap) history.len - history_cap else 0;
    for (history[start..]) |h| {
        if (!util.rememberInput(h)) continue;
        fw.interface.writeAll(h) catch return;
        fw.interface.writeByte('\n') catch return;
    }
    fw.interface.flush() catch return;
}

/// Serialize the Anthropic `messages` array. When `cache` is set and the final
/// message is a plain-string user turn (the common case at request time, and
/// the largest re-sent prefix), wrap it as a text block with a cache_control
/// ephemeral breakpoint — so the whole conversation prefix is cached, not just
/// the system block. Combined with the system breakpoint that's ≤2 of
/// Anthropic's 4 allowed. Other messages are written verbatim.
pub fn writeAnthropicMessages(s: *std.json.Stringify, messages: std.json.Array, cache: bool) !void {
    const items = messages.items;
    try s.beginArray();
    for (items, 0..) |m, i| {
        const cache_this = cache and i + 1 == items.len and m == .object and
            (if (m.object.get("content")) |c| c == .string else false);
        if (!cache_this) {
            try s.write(m);
            continue;
        }
        try s.beginObject();
        var it = m.object.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.key_ptr.*, "content")) continue;
            try s.objectField(kv.key_ptr.*);
            try s.write(kv.value_ptr.*);
        }
        try s.objectField("content");
        try s.beginArray();
        try s.beginObject();
        try s.objectField("type");
        try s.write("text");
        try s.objectField("text");
        try s.write(m.object.get("content").?.string);
        try s.objectField("cache_control");
        try s.print("{s}", .{"{\"type\":\"ephemeral\"}"});
        try s.endObject();
        try s.endArray();
        try s.endObject();
    }
    try s.endArray();
}

pub fn writeOpenAIMessageNormalized(s: *std.json.Stringify, m: Value) !void {
    if (m != .object) return s.write(m);
    const role = if (m.object.get("role")) |v| (if (v == .string) v.string else "") else "";
    const is_assistant_tool_call = std.mem.eql(u8, role, "assistant") and m.object.get("tool_calls") != null;
    const null_content = if (m.object.get("content")) |v| v == .null else false;
    if (!is_assistant_tool_call or !null_content) return s.write(m);

    try s.beginObject();
    var it = m.object.iterator();
    var wrote_content = false;
    while (it.next()) |kv| {
        try s.objectField(kv.key_ptr.*);
        if (std.mem.eql(u8, kv.key_ptr.*, "content")) {
            try s.write("");
            wrote_content = true;
        } else {
            try s.write(kv.value_ptr.*);
        }
    }
    if (!wrote_content) {
        try s.objectField("content");
        try s.write("");
    }
    try s.endObject();
}
