//! Slim rlm reducers: `len(x)` and `project(x, field)`.
//!
//! ADR 0029: `each()` without a way to print a small summary made grok-4.6
//! dump fat MCP binds or invent `for`/`len`. These two stay data helpers,
//! not a general language.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const spec_ptc = @import("spec_ptc.zig");
const rlm_spec = @import("rlm_spec.zig");
const rlm_mcp = @import("rlm_mcp.zig");

pub const StmtHit = rlm_mcp.StmtHit;

pub fn evalStmt(
    arena: Allocator,
    gpa: Allocator,
    stmt: []const u8,
    binds: []const rlm_spec.Binding,
    bind_out: *std.ArrayList(rlm_spec.Binding),
) !StmtHit {
    const trimmed = std.mem.trim(u8, stmt, " \t");
    var rest = trimmed;
    var assign: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq| {
        const lhs = std.mem.trim(u8, trimmed[0..eq], " \t");
        const rhs = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
        if (lhs.len > 0 and (std.mem.startsWith(u8, rhs, "len(") or std.mem.startsWith(u8, rhs, "project("))) {
            assign = lhs;
            rest = rhs;
        }
    }
    const text = evalExpr(arena, rest, binds) catch |err| switch (err) {
        error.Miss => return .miss,
        else => return .{ .fail = try std.fmt.allocPrint(gpa, "rlm: {s} failed", .{rest}) },
    };
    if (assign) |nm| try bind_out.append(arena, .{
        .name = try arena.dupe(u8, nm),
        .text = try arena.dupe(u8, text),
    });
    return .ok;
}

/// Resolve `len(x)` / `project(x, "field")` for `print(...)`.
pub fn evalExpr(arena: Allocator, expr: []const u8, binds: []const rlm_spec.Binding) ![]const u8 {
    const t = std.mem.trim(u8, expr, " \t");
    if (std.mem.startsWith(u8, t, "len(") and t[t.len - 1] == ')') {
        const inner = std.mem.trim(u8, t["len(".len .. t.len - 1], " \t");
        const raw = bindText(binds, inner) orelse inner;
        const items = try jsonArray(arena, raw);
        return try std.fmt.allocPrint(arena, "{d}", .{items.len});
    }
    if (std.mem.startsWith(u8, t, "project(") and t[t.len - 1] == ')') {
        const inner = t["project(".len .. t.len - 1];
        const parts = try spec_ptc.splitTopLevel(arena, inner, ',');
        if (parts.len != 2) return error.Miss;
        const raw = bindText(binds, parts[0]) orelse std.mem.trim(u8, parts[0], " \t");
        const field = stripQuotes(parts[1]);
        const items = try jsonArray(arena, raw);
        var out: std.ArrayList(u8) = .empty;
        try out.append(arena, '[');
        for (items, 0..) |item, i| {
            if (i > 0) try out.append(arena, ',');
            try out.appendSlice(arena, try fieldValue(arena, item, field));
        }
        try out.append(arena, ']');
        return out.toOwnedSlice(arena);
    }
    return error.Miss;
}

fn bindText(binds: []const rlm_spec.Binding, name: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, name, " \t");
    var i = binds.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, binds[i].name, t)) return binds[i].text;
    }
    return null;
}

fn stripQuotes(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0]) return t[1 .. t.len - 1];
    return t;
}

fn jsonArray(arena: Allocator, text: []const u8) ![]const Value {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const parsed = std.json.parseFromSlice(Value, arena, trimmed, .{}) catch return error.Miss;
    if (parsed.value == .array) return parsed.value.array.items;
    if (parsed.value == .object) {
        var it = parsed.value.object.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* == .array) return e.value_ptr.array.items;
        }
    }
    return error.Miss;
}

fn fieldValue(arena: Allocator, item: Value, field: []const u8) ![]const u8 {
    if (item != .object) return error.Miss;
    const v = item.object.get(field) orelse return error.Miss;
    var aw: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.write(v);
    return aw.toOwnedSlice();
}

test "len() counts a JSON array bind" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const binds = [_]rlm_spec.Binding{.{ .name = "issues", .text = "[{\"id\":1},{\"id\":2},{\"id\":3}]" }};
    var bind_out: std.ArrayList(rlm_spec.Binding) = .empty;
    const hit = try evalStmt(arena, gpa, "n = len(issues)", &binds, &bind_out);
    try std.testing.expect(hit == .ok);
    try std.testing.expectEqualStrings("3", bind_out.items[0].text);
}

test "project() extracts one field; print(len()) resolves" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const binds = [_]rlm_spec.Binding{.{ .name = "issues", .text = "[{\"id\":\"ISS-1\",\"title\":\"a\"},{\"id\":\"ISS-2\",\"title\":\"b\"}]" }};
    const ids = try evalExpr(arena, "project(issues, \"id\")", &binds);
    try std.testing.expectEqualStrings("[\"ISS-1\",\"ISS-2\"]", ids);
    const n = try evalExpr(arena, "len(issues)", &binds);
    try std.testing.expectEqualStrings("2", n);
}
