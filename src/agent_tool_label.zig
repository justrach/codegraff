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

fn displayPath(path: []const u8) []const u8 {
    if (path.len == 0) return path;
    if (std.fs.path.isAbsolute(path)) {
        const base = std.fs.path.basename(path);
        return if (base.len > 0) base else path;
    }
    return path;
}

fn namedDetailField(name: []const u8, input: std.json.Value) ?[]const u8 {
    // bash's command is not conversational — the ✓ line interprets the result.
    if (std.mem.eql(u8, name, "codedb")) return "command";
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
        if (shown.len == 0) continue;
        if (std.mem.eql(u8, field, "path") or std.mem.eql(u8, field, "file") or std.mem.eql(u8, field, "uri"))
            return displayPath(shown);
        return shown;
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
    if (std.mem.eql(u8, t.name, "bash")) return "";
    if (std.mem.eql(u8, t.name, "edit_file")) {
        const path = stringField(t.input, "path") orelse return "";
        return editDelta(t.input, displayPath(firstLine(path)), buf);
    }
    if (namedDetailField(t.name, t.input)) |field| {
        const raw = stringField(t.input, field) orelse return "";
        const shown = firstLine(raw);
        if (std.mem.eql(u8, field, "path") or std.mem.eql(u8, field, "file")) return displayPath(shown);
        return shown;
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
    if (std.mem.startsWith(u8, name, "mcp")) {
        const leaf = blk: {
            if (std.mem.lastIndexOf(u8, name, "__")) |u| {
                if (u + 2 < name.len) break :blk name[u + 2 ..];
            }
            if (std.mem.startsWith(u8, name, "mcp_")) break :blk name["mcp_".len..];
            break :blk name;
        };
        if (std.mem.endsWith(u8, leaf, "search")) return "search";
        const n = copy(buf, if (leaf.len > 12) leaf[0..12] else leaf);
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

pub fn lastNonEmptyLine(text: []const u8) []const u8 {
    const rest = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.lastIndexOfScalar(u8, rest, '\n')) |nl|
        return std.mem.trim(u8, rest[nl + 1 ..], " \t\r");
    return rest;
}

fn hexPrefix(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and i < 40) : (i += 1) {
        const c = s[i];
        const hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!hex) break;
    }
    return i;
}

fn gitCommitCount(text: []const u8) ?usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const s = std.mem.trim(u8, raw, " \t\r");
        const h = hexPrefix(s);
        if (h >= 7 and (h == s.len or s[h] == ' ')) n += 1;
    }
    return if (n >= 3) n else null;
}

fn looksLikeRefs(text: []const u8) bool {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const s = std.mem.trim(u8, raw, " \t\r*");
        if (std.mem.startsWith(u8, s, "refs/") or
            std.mem.startsWith(u8, s, "remotes/") or
            std.mem.startsWith(u8, s, "origin/") or
            std.mem.startsWith(u8, s, "release/") or
            std.mem.eql(u8, s, "main")) n += 1;
    }
    return n >= 3;
}

fn isSummaryLine(s: []const u8) bool {
    if (s.len == 0 or s.len > 80) return false;
    if (std.mem.indexOf(u8, s, "passed") != null) return true;
    if (std.mem.indexOf(u8, s, "failed") != null) return true;
    if (std.mem.startsWith(u8, s, "ok") or std.mem.startsWith(u8, s, "OK")) return true;
    if (std.mem.startsWith(u8, s, "error") or std.mem.startsWith(u8, s, "Error")) return true;
    if (std.mem.startsWith(u8, s, "All ")) return true;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// Scan a JSON object for `"key":` then a string, bool, or integer. Not a parser.
fn jsonQuoted(s: []const u8, key: []const u8) ?[]const u8 {
    var pat: [48]u8 = undefined;
    const p = std.fmt.bufPrint(&pat, "\"{s}\":", .{key}) catch return null;
    const at = std.mem.indexOf(u8, s, p) orelse return null;
    var j = at + p.len;
    while (j < s.len and (s[j] == ' ' or s[j] == '\t')) j += 1;
    if (j >= s.len) return null;
    if (s[j] == '"') {
        j += 1;
        const start = j;
        while (j < s.len) : (j += 1) {
            if (s[j] == '\\') {
                j += 1;
                continue;
            }
            if (s[j] == '"') return s[start..j];
        }
        return null;
    }
    if (std.mem.startsWith(u8, s[j..], "true")) return "true";
    if (std.mem.startsWith(u8, s[j..], "false")) return "false";
    const start = j;
    while (j < s.len and s[j] >= '0' and s[j] <= '9') j += 1;
    if (j > start) return s[start..j];
    return null;
}

fn escapedNewlineCount(json_string: []const u8) usize {
    var n: usize = 1;
    var i: usize = 0;
    while (i + 1 < json_string.len) : (i += 1) {
        if (json_string[i] == '\\' and json_string[i + 1] == 'n') n += 1;
    }
    return n;
}

/// JSON tool results (CodeDB Pro, MCP) become a decision, never the envelope.
fn interpretJson(s: []const u8, buf: []u8) []const u8 {
    if (jsonQuoted(s, "ok")) |ok| {
        if (std.mem.eql(u8, ok, "false")) {
            if (jsonQuoted(s, "error")) |err| {
                return if (err.len > result_preview_bytes) err[0..result_preview_bytes] else err;
            }
            return "failed";
        }
    }
    if (jsonQuoted(s, "matches")) |m|
        return std.fmt.bufPrint(buf, "{s} matches", .{m}) catch m;
    if (jsonQuoted(s, "mode")) |mode| {
        const lines = if (jsonQuoted(s, "content")) |c| escapedNewlineCount(c) else 0;
        if (lines > 1)
            return std.fmt.bufPrint(buf, "{s} · {d} lines", .{ mode, lines }) catch mode;
        return mode;
    }
    return "";
}

/// One-line decision the transcript shows. Raw output stays off this line.
pub fn interpret(name: []const u8, all: []const u8, buf: []u8) []const u8 {
    if (all.len == 0) return "";
    const trimmed = std.mem.trimStart(u8, all, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] == '{') return interpretJson(trimmed, buf);
    const lines = newlineCount(all);
    if (std.mem.eql(u8, name, "read_file") and lines > 1) {
        return std.fmt.bufPrint(buf, "{d} lines", .{lines}) catch all;
    }
    const bashy = std.mem.eql(u8, name, "bash") or std.mem.eql(u8, name, "codedb");
    if (bashy and lines > 1) {
        if (gitCommitCount(all)) |n|
            return std.fmt.bufPrint(buf, "{d} commits", .{n}) catch lastNonEmptyLine(all);
        if (looksLikeRefs(all) and lines >= 4)
            return std.fmt.bufPrint(buf, "{d} branches", .{lines}) catch lastNonEmptyLine(all);
        const last = lastNonEmptyLine(all);
        const compacted = compactBash(last, buf);
        if (!std.mem.eql(u8, compacted, last)) return compacted;
        if (isSummaryLine(last)) {
            return if (last.len > result_preview_bytes) last[0..result_preview_bytes] else last;
        }
        if (lines >= 4)
            return std.fmt.bufPrint(buf, "{d} lines", .{lines}) catch last;
        return if (last.len > result_preview_bytes) last[0..result_preview_bytes] else last;
    }
    if (bashy) return compactBash(firstLine(all), buf);
    const raw = firstLine(all);
    return if (raw.len > result_preview_bytes) raw[0..result_preview_bytes] else raw;
}

/// Transport death, not a tool bug. The transcript names the family once.
pub fn infraFamily(name: []const u8, text: []const u8) ?[]const u8 {
    const closed = std.mem.indexOf(u8, text, "McpClosed") != null or
        std.mem.indexOf(u8, text, "McpHandshakeTimeout") != null;
    if (!closed) return null;
    if (std.mem.indexOf(u8, name, "codedb") != null) return "codedb";
    return "mcp";
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
    if (shown.len > 0 and shown[0] == '{') return "";
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

test "interpret turns git log and branch dumps into counts" {
    var buf: [32]u8 = undefined;
    const log =
        \\d022479 feat(ui): cache
        \\8f75b5b fix(tui): chips
        \\4ba84b3 feat(models): seats
        \\
    ;
    try std.testing.expectEqualStrings("3 commits", interpret("bash", log, &buf));
    const refs =
        \\* release/v0.0.269
        \\  main
        \\  remotes/origin/main
        \\  remotes/origin/release/v0.0.269
        \\
    ;
    try std.testing.expectEqualStrings("4 branches", interpret("bash", refs, &buf));
    try std.testing.expectEqualStrings("29", interpret("bash", "29\n", &buf));
}

test "bash detail is empty so the command never becomes the transcript" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [16]u8 = undefined;
    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), "{\"command\":\"git log --oneline v0.0.267..HEAD | wc -l\"}", .{});
    try std.testing.expectEqualStrings("", detail(.{ .name = "bash", .input = input }, &buf));
    try std.testing.expectEqualStrings("git", verb("bash", input, &buf));
}

test "mcp verb is the leaf, not _codedbpro_" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("read", verb("mcp__codedbpro__read", .null, &buf));
    try std.testing.expectEqualStrings("search", verb("mcp__codedbpro__faster_search", .null, &buf));
    try std.testing.expectEqualStrings("search", verb("mcp_search", .null, &buf));
}

test "infraFamily collapses McpClosed to a family name" {
    try std.testing.expectEqualStrings("codedb", infraFamily("mcp__codedbpro__read", "McpClosed") orelse "");
    try std.testing.expectEqualStrings("mcp", infraFamily("mcp__github__get", "McpHandshakeTimeout") orelse "");
    try std.testing.expect(infraFamily("bash", "boom") == null);
}

test "interpretJson never leaks a CodeDB envelope" {
    var buf: [48]u8 = undefined;
    const section =
        \\{"ok":true,"file":"/Users/rachpradhan/codedb/docs/architecture.md","mode":"section","content":"a\nb\nc"}
    ;
    try std.testing.expectEqualStrings("section · 3 lines", interpret("mcp__codedbpro__read", section, &buf));
    try std.testing.expectEqualStrings("5 matches", interpret("mcp__codedbpro__faster_search", "{\"ok\":true,\"matches\":5}", &buf));
    try std.testing.expectEqualStrings("outline", interpret("mcp__codedbpro__read", "{\"ok\":true,\"mode\":\"outline\"}", &buf));
    try std.testing.expectEqualStrings("", interpret("mcp__codedbpro__read", "{\"ok\":true,\"file\":\"x.md\"}", &buf));
}

test "mcp file detail is the basename, not the absolute path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var buf: [16]u8 = undefined;
    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), "{\"file\":\"/Users/rachpradhan/codedb/docs/architecture.md\",\"mode\":\"section\"}", .{});
    try std.testing.expectEqualStrings("architecture.md", detail(.{ .name = "mcp__codedbpro__read", .input = input }, &buf));
}
