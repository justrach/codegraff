//! Only a leading, explicitly safe read wave may execute speculatively.
const std = @import("std");
const ptc = @import("spec_ptc.zig");
const tools = @import("tools.zig");

pub fn safe(call: ptc.Call) bool {
    return std.mem.eql(u8, call.name, "read_file") or std.mem.eql(u8, call.name, "codedb") or std.mem.eql(u8, call.name, "llm_query") or std.mem.eql(u8, call.name, "sleep_ms");
}

pub fn leading(arena: std.mem.Allocator, stmt: []const u8) !?[]const ptc.Call {
    if (try ptc.extractCall(arena, stmt)) |call| {
        if (!safe(call)) return null;
        const calls = try arena.alloc(ptc.Call, 1);
        calls[0] = call;
        return calls;
    }
    const text = std.mem.trim(u8, stmt, " \t");
    if (!std.mem.startsWith(u8, text, "print(") or text[text.len - 1] != ')') return null;
    const parts = try ptc.splitTopLevel(arena, text[6 .. text.len - 1], ',');
    var calls: std.ArrayList(ptc.Call) = .empty;
    for (parts) |part| {
        const call = try ptc.extractCall(arena, part) orelse return null;
        if (!safe(call)) return null;
        try calls.append(arena, call);
    }
    return if (calls.items.len > 0) calls.items else null;
}

pub fn stopped(out: tools.ToolOutput) bool {
    return out.is_error or out.cancelled or out.pending;
}

pub fn copy(gpa: std.mem.Allocator, out: tools.ToolOutput) !tools.ToolOutput {
    var result = out;
    result.text = try gpa.dupe(u8, out.text);
    return result;
}
