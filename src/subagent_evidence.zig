//! Bounded partial evidence for a failed sub-agent (#793).
//!
//! The parent still sees `is_error`. Findings and tool names that already
//! landed are kept, labelled incomplete, so a workflow excerpt can summarize
//! unfinished work instead of only the transport cause.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const evidence_cap: usize = 800;
pub const marker = "[partial evidence, incomplete]";

pub fn append(gpa: Allocator, failure: []u8, tools: []const u8, findings: []const u8) []u8 {
    const t = std.mem.trim(u8, tools, " \t\r\n");
    const f = std.mem.trim(u8, findings, " \t\r\n");
    if (t.len == 0 and f.len == 0) return failure;
    return std.fmt.allocPrint(gpa, "{s}\n{s}{s}{s}{s}{s}", .{
        failure,
        marker,
        if (t.len > 0) " tools=" else "",
        t,
        if (f.len > 0) "\n" else "",
        f,
    }) catch failure;
}

/// Head of the failure cause plus a bounded tail of the evidence section so
/// a workflow `{{prev}}` excerpt is not cause-only.
pub fn excerpt(arena: Allocator, text: []const u8, cause_cap: usize, ev_cap: usize) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return "";
    const ev_at = std.mem.indexOf(u8, trimmed, marker);
    const cause = if (ev_at) |i| trimmed[0..i] else trimmed;
    const ev = if (ev_at) |i| trimmed[i..] else "";
    const cause_head = utf8Prefix(cause, cause_cap);
    const ev_head = utf8Prefix(ev, ev_cap);
    var aw: std.Io.Writer.Allocating = .init(arena);
    aw.writer.writeAll(cause_head) catch return cause_head;
    if (ev_head.len > 0) {
        if (cause_head.len > 0 and cause_head[cause_head.len - 1] != ' ')
            aw.writer.writeByte(' ') catch {};
        aw.writer.writeAll(ev_head) catch {};
    }
    const out = aw.writer.buffered();
    for (out) |*c| if (c.* == '\n' or c.* == '\r' or c.* == '\t') {
        c.* = ' ';
    };
    if (cause_head.len + ev_head.len < trimmed.len) {
        return std.fmt.allocPrint(arena, "{s}…", .{out}) catch out;
    }
    return out;
}

fn utf8Prefix(s: []const u8, cap: usize) []const u8 {
    return @import("util.zig").utf8Prefix(s, cap);
}

test "#793: append keeps the failure and labels incomplete evidence" {
    const gpa = std.testing.allocator;
    const base = try gpa.dupe(u8, "subagent sa-001 failed before producing a report: timeout [transport failure, 1 try].");
    const out = append(gpa, base, "read_file,grep", "found 3 call sites in auth.zig");
    defer gpa.free(out);
    if (out.ptr != base.ptr) gpa.free(base);
    try std.testing.expect(std.mem.indexOf(u8, out, "timeout") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "read_file,grep") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "auth.zig") != null);
}

test "#793: excerpt includes the evidence section, not only the cause" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text = "subagent sa-001 failed before producing a report: boom [api failure, 1 try]. retry ok.\n" ++
        marker ++ " tools=read_file\nfound the leak in src/a.zig";
    const got = excerpt(a, text, 80, 120);
    try std.testing.expect(std.mem.indexOf(u8, got, "boom") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "partial evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "src/a.zig") != null);
}
