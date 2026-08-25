//! Zig speculator for programmatic tool calling (sPTC).
//!
//! [spec-ptc](https://github.com/alexzhang13/spec-ptc) overlaps tool work
//! with generation: as a code REPL streams, closed statements whose arguments
//! are literals launch as futures; the real exec claims them. Graff's native
//! loop already fans a finished batch across the pool — this is earlier: the
//! call is visible in partial source before the `rlm` tool argument closes.
//!
//! This module is the language-agnostic half. It does not run tools. A host
//! (rlm.zig) feeds source, launches `Call`s, and claims by canonical key.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A closed call with literal args, ready to speculate or claim.
pub const Call = struct {
    name: []const u8,
    /// Canonical JSON object, e.g. `{"path":"a.txt"}`. Arena/gpa-owned.
    args_json: []const u8,

    pub fn key(self: Call, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}\n{s}", .{ self.name, self.args_json });
    }
};

/// Incremental source → complete top-level statements (newline-terminated).
pub const Segmenter = struct {
    pending: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Segmenter, gpa: Allocator) void {
        self.pending.deinit(gpa);
    }

    /// Append `delta`. Returns newly closed statements (each without the
    /// trailing newline). Caller frees the slice; strings alias `pending`
    /// until the next feed, so copy what you keep.
    pub fn feed(self: *Segmenter, gpa: Allocator, delta: []const u8) ![][]const u8 {
        try self.pending.appendSlice(gpa, delta);
        return self.takeClosed(gpa);
    }

    pub fn finish(self: *Segmenter, gpa: Allocator) ![][]const u8 {
        if (self.pending.items.len == 0) return &.{};
        const tail = std.mem.trim(u8, self.pending.items, " \t\r\n");
        if (tail.len == 0) {
            self.pending.clearRetainingCapacity();
            return &.{};
        }
        const one = try gpa.alloc([]const u8, 1);
        one[0] = try gpa.dupe(u8, tail);
        self.pending.clearRetainingCapacity();
        return one;
    }

    fn takeClosed(self: *Segmenter, gpa: Allocator) ![][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer out.deinit(gpa);
        var rest = self.pending.items;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            const line = std.mem.trim(u8, rest[0..nl], " \t\r");
            if (line.len > 0) try out.append(gpa, try gpa.dupe(u8, line));
            rest = rest[nl + 1 ..];
        }
        if (rest.ptr != self.pending.items.ptr) {
            const n = rest.len;
            std.mem.copyForwards(u8, self.pending.items[0..n], rest);
            self.pending.shrinkRetainingCapacity(n);
        }
        return out.toOwnedSlice(gpa);
    }
};

/// Pull a speculatable `name(...)` / `var = name(...)` from one statement.
/// Only literal args (string / int / bool). Returns null for print, comments,
/// or anything that still depends on a runtime value.
pub fn extractCall(arena: Allocator, stmt: []const u8) !?Call {
    const line = stripComment(stmt);
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return null;
    const call_src = afterOptionalAssign(trimmed) orelse return null;
    const open = std.mem.indexOfScalar(u8, call_src, '(') orelse return null;
    const name = std.mem.trim(u8, call_src[0..open], " \t");
    if (!isIdent(name)) return null;
    if (std.mem.eql(u8, name, "print")) return null;
    const close = lastParen(call_src) orelse return null;
    const inner = call_src[open + 1 .. close];
    const args_json = parseArgs(arena, name, inner) catch |err| switch (err) {
        error.NeedKeywords => return null,
        else => return err,
    } orelse return null;
    return .{ .name = try arena.dupe(u8, name), .args_json = args_json };
}

pub fn extractCalls(arena: Allocator, statements: []const []const u8) ![]Call {
    var out: std.ArrayList(Call) = .empty;
    for (statements) |stmt| {
        if (try extractCall(arena, stmt)) |c| try out.append(arena, c);
    }
    return out.toOwnedSlice(arena);
}

fn stripComment(stmt: []const u8) []const u8 {
    var i: usize = 0;
    var in_str: ?u8 = null;
    var esc = false;
    while (i < stmt.len) : (i += 1) {
        const c = stmt[i];
        if (in_str) |q| {
            if (esc) {
                esc = false;
                continue;
            }
            if (c == '\\') {
                esc = true;
                continue;
            }
            if (c == q) in_str = null;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_str = c;
            continue;
        }
        if (c == '#') return stmt[0..i];
    }
    return stmt;
}

fn afterOptionalAssign(stmt: []const u8) ?[]const u8 {
    const paren = std.mem.indexOfScalar(u8, stmt, '(') orelse stmt.len;
    if (std.mem.indexOfScalar(u8, stmt[0..paren], '=')) |eq| {
        // `==` or a comparison is not an assignment we care about.
        if (eq + 1 < stmt.len and stmt[eq + 1] == '=') return stmt;
        const lhs = std.mem.trim(u8, stmt[0..eq], " \t");
        if (!isIdent(lhs)) return null;
        return trimStart(stmt[eq + 1 ..], " \t");
    }
    return stmt;
}

fn isIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!identStart(s[0])) return false;
    for (s[1..]) |c| if (!identCont(c)) return false;
    return true;
}

fn identStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

fn identCont(c: u8) bool {
    return identStart(c) or (c >= '0' and c <= '9');
}

fn lastParen(s: []const u8) ?usize {
    if (s.len == 0 or s[s.len - 1] != ')') return null;
    return s.len - 1;
}

const Arg = struct { key: ?[]const u8, value: Value };

const Value = union(enum) {
    string: []const u8,
    int: i64,
    bool: bool,
};

fn parseArgs(arena: Allocator, tool: []const u8, inner: []const u8) !?[]const u8 {
    var args: std.ArrayList(Arg) = .empty;
    var i: usize = 0;
    const src = inner;
    skipWs(src, &i);
    if (i >= src.len) return try canonicalize(arena, tool, &.{});
    while (i < src.len) {
        skipWs(src, &i);
        if (i >= src.len) break;
        var key: ?[]const u8 = null;
        const start = i;
        if (identStart(src[i])) {
            i += 1;
            while (i < src.len and identCont(src[i])) i += 1;
            const ident = src[start..i];
            skipWs(src, &i);
            if (i < src.len and src[i] == '=') {
                i += 1;
                key = ident;
                skipWs(src, &i);
            } else {
                i = start;
            }
        }
        const val = (try parseValue(arena, src, &i)) orelse return null;
        try args.append(arena, .{ .key = key, .value = val });
        skipWs(src, &i);
        if (i >= src.len) break;
        if (src[i] != ',') return null;
        i += 1;
    }
    return try canonicalize(arena, tool, args.items);
}

fn parseValue(arena: Allocator, src: []const u8, i: *usize) !?Value {
    if (i.* >= src.len) return null;
    const c = src[i.*];
    if (c == '"' or c == '\'') return .{ .string = (try parseString(arena, src, i)) orelse return null };
    if (c == '-' or (c >= '0' and c <= '9')) return parseInt(src, i);
    if (takeWord(src, i, "true")) return .{ .bool = true };
    if (takeWord(src, i, "false")) return .{ .bool = false };
    return null;
}

fn parseString(arena: Allocator, src: []const u8, i: *usize) !?[]const u8 {
    const q = src[i.*];
    i.* += 1;
    var out: std.ArrayList(u8) = .empty;
    var esc = false;
    while (i.* < src.len) : (i.* += 1) {
        const c = src[i.*];
        if (esc) {
            try out.append(arena, switch (c) {
                'n' => '\n',
                't' => '\t',
                else => c,
            });
            esc = false;
            continue;
        }
        if (c == '\\') {
            esc = true;
            continue;
        }
        if (c == q) {
            i.* += 1;
            return @as(?[]const u8, try out.toOwnedSlice(arena));
        }
        try out.append(arena, c);
    }
    return null;
}

fn parseInt(src: []const u8, i: *usize) ?Value {
    const start = i.*;
    if (src[i.*] == '-') i.* += 1;
    if (i.* >= src.len or src[i.*] < '0' or src[i.*] > '9') {
        i.* = start;
        return null;
    }
    while (i.* < src.len and src[i.*] >= '0' and src[i.*] <= '9') i.* += 1;
    const n = std.fmt.parseInt(i64, src[start..i.*], 10) catch return null;
    return .{ .int = n };
}

fn takeWord(src: []const u8, i: *usize, word: []const u8) bool {
    if (i.* + word.len > src.len) return false;
    if (!std.mem.eql(u8, src[i.*..][0..word.len], word)) return false;
    const after = i.* + word.len;
    if (after < src.len and identCont(src[after])) return false;
    i.* = after;
    return true;
}

fn trimStart(s: []const u8, cutset: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and std.mem.indexOfScalar(u8, cutset, s[i]) != null) i += 1;
    return s[i..];
}

fn skipWs(src: []const u8, i: *usize) void {
    while (i.* < src.len and (src[i.*] == ' ' or src[i.*] == '\t')) i.* += 1;
}

fn canonicalize(arena: Allocator, tool: []const u8, args: []const Arg) ![]const u8 {
    var obj: std.json.ObjectMap = .empty;
    const field = hostField(tool);
    if (args.len == 1 and args[0].key == null) {
        try putValue(arena, &obj, field, args[0].value);
    } else {
        for (args) |a| {
            const k = a.key orelse return error.NeedKeywords;
            try putValue(arena, &obj, k, a.value);
        }
    }
    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(std.json.Value{ .object = obj });
    return aw.toOwnedSlice();
}

fn hostField(tool: []const u8) []const u8 {
    if (std.mem.eql(u8, tool, "read_file")) return "path";
    if (std.mem.eql(u8, tool, "codedb")) return "command";
    if (std.mem.eql(u8, tool, "sleep_ms")) return "ms";
    if (std.mem.eql(u8, tool, "llm_query")) return "prompt";
    return "arg";
}

fn putValue(arena: Allocator, obj: *std.json.ObjectMap, key: []const u8, v: Value) !void {
    const jv: std.json.Value = switch (v) {
        .string => |s| .{ .string = s },
        .int => |n| .{ .integer = n },
        .bool => |b| .{ .bool = b },
    };
    try obj.put(arena, key, jv);
}

test "Segmenter yields a line only after the newline, then flushes the tail" {
    const gpa = std.testing.allocator;
    var seg: Segmenter = .{};
    defer seg.deinit(gpa);
    const none = try seg.feed(gpa, "a = read_file(\"x\")");
    defer gpa.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    const one = try seg.feed(gpa, "\nb = read_file(\"y\")\n");
    defer {
        for (one) |s| gpa.free(s);
        gpa.free(one);
    }
    try std.testing.expectEqual(@as(usize, 2), one.len);
    try std.testing.expectEqualStrings("a = read_file(\"x\")", one[0]);
    try std.testing.expectEqualStrings("b = read_file(\"y\")", one[1]);
}

test "extractCall reads positional and keyword literals; print and names are skipped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = (try extractCall(a, "x = read_file(\"docs/a.txt\")")).?;
    try std.testing.expectEqualStrings("read_file", r.name);
    try std.testing.expectEqualStrings("{\"path\":\"docs/a.txt\"}", r.args_json);
    const k = (try extractCall(a, "codedb(command=\"status\")")).?;
    try std.testing.expectEqualStrings("{\"command\":\"status\"}", k.args_json);
    const s = (try extractCall(a, "sleep_ms(40)")).?;
    try std.testing.expectEqualStrings("{\"ms\":40}", s.args_json);
    const q = (try extractCall(a, "n = llm_query(\"summarize this chunk\")")).?;
    try std.testing.expectEqualStrings("llm_query", q.name);
    try std.testing.expectEqualStrings("{\"prompt\":\"summarize this chunk\"}", q.args_json);
    try std.testing.expect(try extractCall(a, "print(x)") == null);
    try std.testing.expect(try extractCall(a, "read_file(path)") == null);
    try std.testing.expect(try extractCall(a, "# just a comment") == null);
}

test "extractCalls finds independent sleeps in a three-call script" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src = [_][]const u8{
        "a = sleep_ms(40)",
        "b = sleep_ms(40)",
        "c = sleep_ms(40)",
        "print(a)",
    };
    const calls = try extractCalls(a, &src);
    try std.testing.expectEqual(@as(usize, 3), calls.len);
    try std.testing.expectEqualStrings("sleep_ms", calls[0].name);
}
