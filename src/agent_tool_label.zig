//! Verb + detail + remembered args for line-REPL tool lines (variations 4+5).
//! `bash` is never the label — the command (or a short verb) is.

const std = @import("std");

const engine_events = @import("engine_events.zig");
const ToolInvocation = engine_events.ToolInvocation;

pub const detail_preview_bytes: usize = 96;
pub const result_preview_bytes: usize = 100;

pub fn stringField(input: std.json.Value, field: []const u8) ?[]const u8 {
    if (input != .object) return null;
    const value = input.object.get(field) orelse return null;
    return if (value == .string) value.string else null;
}

pub fn firstLine(s: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, s, '\n') orelse s.len;
    return std.mem.trim(u8, s[0..end], " \t\r");
}

pub fn firstToken(s: []const u8) []const u8 {
    const line = firstLine(s);
    const end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    return line[0..end];
}

pub fn newlineCount(s: []const u8) usize {
    if (s.len == 0) return 0;
    var n: usize = 1;
    for (s) |c| {
        if (c == '\n') n += 1;
    }
    if (s[s.len - 1] == '\n') n -= 1;
    return n;
}

fn namedDetailField(name: []const u8, input: std.json.Value) ?[]const u8 {
    if (std.mem.eql(u8, name, "bash") or std.mem.eql(u8, name, "codedb")) return "command";
    if (std.mem.eql(u8, name, "read_file") or
        std.mem.eql(u8, name, "write_file") or
        std.mem.eql(u8, name, "edit_file")) return "path";
    if (std.mem.eql(u8, name, "webfetch")) return "url";
    if (std.mem.eql(u8, name, "subagent")) return "description";
    if (std.mem.eql(u8, name, "imagegen")) return "prompt";
    if (std.mem.eql(u8, name, "peer_message")) {
        if (stringField(input, "action")) |act| {
            if (act.len > 0 and !std.mem.eql(u8, act, "send")) return "action";
        }
        return "text";
    }
    if (std.mem.eql(u8, name, "workspace")) {
        if (stringField(input, "path")) |p| if (p.len > 0) return "path";
        return "action";
    }
    return null;
}

const fallback_fields = [_][]const u8{ "command", "path", "query", "url", "pattern", "file", "prompt", "uri", "text" };

fn fallbackDetail(input: std.json.Value) []const u8 {
    for (fallback_fields) |field| {
        const raw = stringField(input, field) orelse continue;
        const shown = firstLine(raw);
        if (shown.len > 0) return shown;
    }
    return "";
}

fn addSpanDelta(old: []const u8, new: []const u8, plus: *usize, minus: *usize, spans: *usize) void {
    plus.* += newlineCount(new);
    minus.* += newlineCount(old);
    spans.* += 1;
}

pub fn editDelta(input: std.json.Value, path: []const u8, buf: []u8) []const u8 {
    var plus: usize = 0;
    var minus: usize = 0;
    var spans: usize = 0;
    if (stringField(input, "old_string")) |old| {
        if (stringField(input, "new_string")) |new| addSpanDelta(old, new, &plus, &minus, &spans);
    }
    if (input == .object) if (input.object.get("edits")) |v| if (v == .array) {
        for (v.array.items) |item| {
            const old = stringField(item, "old_string") orelse continue;
            const new = stringField(item, "new_string") orelse continue;
            addSpanDelta(old, new, &plus, &minus, &spans);
        }
    };
    if (spans == 0) return path;
    if (spans == 1)
        return std.fmt.bufPrint(buf, "{s} · +{d}/-{d}", .{ path, plus, minus }) catch path;
    return std.fmt.bufPrint(buf, "{s} · {d} spans · +{d}/-{d}", .{ path, spans, plus, minus }) catch path;
}

pub fn detail(t: ToolInvocation, buf: []u8) []const u8 {
    if (std.mem.eql(u8, t.name, "edit_file")) {
        const path = stringField(t.input, "path") orelse return "";
        return editDelta(t.input, firstLine(path), buf);
    }
    if (namedDetailField(t.name, t.input)) |field| {
        const raw = stringField(t.input, field) orelse return "";
        return firstLine(raw);
    }
    return fallbackDetail(t.input);
}

fn copy(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

/// Short verb the human reads. Never "bash".
pub fn verb(name: []const u8, input: std.json.Value, buf: []u8) []const u8 {
    if (std.mem.eql(u8, name, "bash")) {
        const cmd = stringField(input, "command") orelse return "run";
        const tok = firstToken(cmd);
        if (std.mem.indexOf(u8, cmd, "test") != null) return "test";
        if (tok.len > 0 and tok.len <= 12) {
            const n = copy(buf, tok);
            return buf[0..n];
        }
        return "run";
    }
    if (std.mem.eql(u8, name, "edit_file")) return "edit";
    if (std.mem.eql(u8, name, "write_file")) return "write";
    if (std.mem.eql(u8, name, "read_file")) return "read";
    if (std.mem.eql(u8, name, "webfetch")) return "fetch";
    if (std.mem.eql(u8, name, "codedb")) {
        const cmd = stringField(input, "command") orelse return "search";
        const tok = firstToken(cmd);
        if (tok.len > 0) {
            const n = copy(buf, tok);
            return buf[0..n];
        }
        return "search";
    }
    if (std.mem.eql(u8, name, "subagent")) return "agent";
    if (std.mem.eql(u8, name, "imagegen")) return "image";
    if (std.mem.startsWith(u8, name, "mcp_")) {
        const rest = name["mcp_".len..];
        const n = copy(buf, if (rest.len > 12) rest[0..12] else rest);
        return buf[0..n];
    }
    const n = copy(buf, if (name.len > 12) name[0..12] else name);
    return buf[0..n];
}

const Pending = struct {
    name: [64]u8 = undefined,
    name_len: usize = 0,
    verb: [16]u8 = undefined,
    verb_len: usize = 0,
    detail: [96]u8 = undefined,
    detail_len: usize = 0,
    used: bool = false,
};

fn emptyPending() [8]Pending {
    var out: [8]Pending = undefined;
    for (&out) |*p| p.* = .{};
    return out;
}

var pending: [8]Pending = emptyPending();

pub fn remember(name: []const u8, v: []const u8, d: []const u8) void {
    var slot: ?*Pending = null;
    for (&pending) |*p| {
        if (!p.used) {
            slot = p;
            break;
        }
    }
    if (slot == null) slot = &pending[0];
    const p = slot.?;
    p.used = true;
    p.name_len = copy(&p.name, name);
    p.verb_len = copy(&p.verb, v);
    p.detail_len = copy(&p.detail, d);
}

pub const Remembered = struct { verb: []const u8, detail: []const u8 };

pub fn take(name: []const u8) ?Remembered {
    for (&pending) |*p| {
        if (!p.used) continue;
        if (!std.mem.eql(u8, p.name[0..p.name_len], name)) continue;
        p.used = false;
        return .{ .verb = p.verb[0..p.verb_len], .detail = p.detail[0..p.detail_len] };
    }
    return null;
}

pub fn resetPending() void {
    for (&pending) |*p| p.used = false;
}

pub fn compactBash(line: []const u8, buf: []u8) []const u8 {
    if (std.mem.startsWith(u8, line, "All ") and std.mem.endsWith(u8, line, " tests passed")) {
        const n = line["All ".len .. line.len - " tests passed".len];
        return std.fmt.bufPrint(buf, "{s} passed", .{n}) catch line;
    }
    return line;
}

/// Drop a result preview that only restates the verb/detail (the edit
/// harness saying "applied N edit span(s)…" when `+12/-4` is already there).
pub fn usefulPreview(name: []const u8, known: []const u8, shown: []const u8) []const u8 {
    if (shown.len == 0) return shown;
    if (std.mem.eql(u8, name, "edit_file")) {
        if (std.mem.indexOf(u8, shown, "edit span") != null) return "";
        if (std.mem.indexOf(u8, known, " · +") != null) return "";
    }
    if (known.len > 0 and std.mem.eql(u8, shown, known)) return "";
    return shown;
}

test "verb never says bash" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [16]u8 = undefined;
    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), "{\"command\":\"zig build test\"}", .{});
    try std.testing.expectEqualStrings("test", verb("bash", input, &buf));
    try std.testing.expectEqualStrings("edit", verb("edit_file", .null, &buf));
    try std.testing.expectEqualStrings("read", verb("read_file", .null, &buf));
}

test "compactBash keeps the count and drops the boilerplate" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("1475 passed", compactBash("All 1475 tests passed", &buf));
    try std.testing.expectEqualStrings("ok", compactBash("ok", &buf));
}

test "usefulPreview drops edit-span boilerplate once +N/-N is known" {
    try std.testing.expectEqualStrings("", usefulPreview("edit_file", "src/a.zig · +3/-2", "applied 1 edit span(s) to src/a.zig (each verified)"));
    try std.testing.expectEqualStrings("4 matches", usefulPreview("mcp_search", "standing line", "4 matches"));
    try std.testing.expectEqualStrings("", usefulPreview("webfetch", "https://ex", "https://ex"));
}
