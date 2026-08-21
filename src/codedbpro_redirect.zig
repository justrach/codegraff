//! Licensed-pro native→companion redirects. Split out of codedbpro_report.zig
//! (600-line cap). Native `codedb` is a different job from the paid suite and
//! is never redirected. Only read_file and leading shell searches map.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tools = @import("tools.zig");

pub const Redirect = struct { name: []const u8, input: std.json.Value };

fn kv(gpa: Allocator, name: []const u8, key: []const u8, value: []const u8) ?Redirect {
    var obj: std.json.ObjectMap = .empty;
    obj.put(gpa, key, .{ .string = value }) catch return null;
    return .{ .name = name, .input = .{ .object = obj } };
}

pub fn readRedirect(gpa: Allocator, file: []const u8, mode: []const u8) ?Redirect {
    var obj: std.json.ObjectMap = .empty;
    obj.put(gpa, "file", .{ .string = file }) catch return null;
    obj.put(gpa, "mode", .{ .string = mode }) catch return null;
    return .{ .name = "mcp__codedbpro__read", .input = .{ .object = obj } };
}

pub fn searchRedirect(gpa: Allocator, pattern: []const u8) ?Redirect {
    if (pattern.len == 0) return null;
    return kv(gpa, "mcp__codedbpro__faster_search", "pattern", pattern);
}

fn leadingSearchCommand(cmd: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, cmd, " \t");
    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    const first = trimmed[0..end];
    return std.mem.eql(u8, first, "grep") or std.mem.eql(u8, first, "rg") or std.mem.eql(u8, first, "find");
}

/// Translate a blocked native read/shell-search into the zigrepper twin.
/// Native `codedb` always returns null — it stays the free index. Edits
/// never redirect — native edit tools own /rewind.
pub fn redirect(gpa: Allocator, call: tools.ToolCall) ?Redirect {
    if (std.mem.eql(u8, call.name, "codedb")) return null;
    if (std.mem.eql(u8, call.name, "read_file")) {
        const path = tools.strField(call.input, "path") orelse return null;
        if (tools.intField(call.input, "start_line")) |s| {
            const e = tools.intField(call.input, "end_line") orelse s + 400;
            var obj: std.json.ObjectMap = .empty;
            obj.put(gpa, "file", .{ .string = path }) catch return null;
            obj.put(gpa, "mode", .{ .string = "lines" }) catch return null;
            obj.put(gpa, "range", .{ .string = std.fmt.allocPrint(gpa, "{d}-{d}", .{ s, e }) catch return null }) catch return null;
            return .{ .name = "mcp__codedbpro__read", .input = .{ .object = obj } };
        }
        return readRedirect(gpa, path, "full");
    }
    if (std.mem.eql(u8, call.name, "bash")) {
        const cmd = tools.strField(call.input, "command") orelse return null;
        if (!leadingSearchCommand(cmd)) return null;
        var it = std.mem.tokenizeAny(u8, cmd, " \t");
        _ = it.next();
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, cmd, " \t"), "find")) return null;
        while (it.next()) |tok| {
            if (tok[0] == '-') continue;
            return searchRedirect(gpa, std.mem.trim(u8, tok, "\"'"));
        }
        return null;
    }
    return null;
}

fn jsonCall(a: Allocator, name: []const u8, body: []const u8) tools.ToolCall {
    return .{ .id = "t", .name = name, .input = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch unreachable };
}

test "redirect: native codedb is never mapped; read_file and leading grep still are" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const r1 = redirect(a, jsonCall(a, "read_file", "{\"path\":\"src/main.zig\"}")).?;
    try std.testing.expectEqualStrings("mcp__codedbpro__read", r1.name);
    try std.testing.expectEqualStrings("full", r1.input.object.get("mode").?.string);

    try std.testing.expect(redirect(a, jsonCall(a, "codedb", "{\"command\":\"around flushPassiveEffects\"}")) == null);
    try std.testing.expect(redirect(a, jsonCall(a, "codedb", "{\"command\":\"context how does auth work\"}")) == null);
    try std.testing.expect(redirect(a, jsonCall(a, "codedb", "{\"command\":\"callpath exec codedbGuard\"}")) == null);
    try std.testing.expect(redirect(a, jsonCall(a, "codedb", "{\"command\":\"list_dir src\"}")) == null);
    try std.testing.expect(redirect(a, jsonCall(a, "codedb", "{\"command\":\"status\"}")) == null);
    try std.testing.expect(redirect(a, jsonCall(a, "codedb", "{\"command\":\"search parseHeader\"}")) == null);
    try std.testing.expect(redirect(a, jsonCall(a, "edit_file", "{}")) == null);
}
