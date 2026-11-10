//! Named prompt-prefix byte caps. Discrete knobs so a skill catalog, MCP
//! listing, or AGENTS.md cannot eat the cached prefix. `--context-limit
//! name=N` and `GRAFF_CONTEXT_LIMIT` set them; `apply` never grows.

const std = @import("std");

const util = @import("util.zig");

pub const Name = enum {
    skill_catalog_bytes,
    mcp_schema_bytes,
    agents_md_bytes,

    pub fn parse(raw: []const u8) ?Name {
        if (std.mem.eql(u8, raw, "skill_catalog_bytes")) return .skill_catalog_bytes;
        if (std.mem.eql(u8, raw, "mcp_schema_bytes")) return .mcp_schema_bytes;
        if (std.mem.eql(u8, raw, "agents_md_bytes")) return .agents_md_bytes;
        return null;
    }
};

pub const defaults = struct {
    pub const skill_catalog_bytes: usize = 4096;
    pub const mcp_schema_bytes: usize = 8192;
    pub const agents_md_bytes: usize = 8192;
};

pub var skill_catalog_bytes: usize = defaults.skill_catalog_bytes;
pub var mcp_schema_bytes: usize = defaults.mcp_schema_bytes;
pub var agents_md_bytes: usize = defaults.agents_md_bytes;

pub fn resetForTest() void {
    skill_catalog_bytes = defaults.skill_catalog_bytes;
    mcp_schema_bytes = defaults.mcp_schema_bytes;
    agents_md_bytes = defaults.agents_md_bytes;
}

fn set(name: Name, n: usize) void {
    if (n == 0) return;
    switch (name) {
        .skill_catalog_bytes => skill_catalog_bytes = n,
        .mcp_schema_bytes => mcp_schema_bytes = n,
        .agents_md_bytes => agents_md_bytes = n,
    }
}

/// `name=N`. Unknown name or 0 is an error (a knob that silently no-ops
/// would hide a typo until the prefix blew up).
pub fn applyPair(raw: []const u8) !void {
    const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return error.BadLimit;
    const name = Name.parse(std.mem.trim(u8, raw[0..eq], " \t")) orelse return error.UnknownLimit;
    const n = std.fmt.parseInt(usize, std.mem.trim(u8, raw[eq + 1 ..], " \t"), 10) catch return error.BadLimit;
    if (n == 0) return error.BadLimit;
    set(name, n);
}

/// Comma-separated pairs for `GRAFF_CONTEXT_LIMIT`.
pub fn applyEnv(raw: []const u8) void {
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (t.len == 0) continue;
        applyPair(t) catch {};
    }
}

const marker = "\n[truncated by --context-limit]";

/// Truncate `text` to `cap` on a codepoint boundary. Never grows.
pub fn apply(text: []const u8, cap: usize) []const u8 {
    if (text.len <= cap) return text;
    if (cap <= marker.len) return util.utf8Prefix(text, cap);
    const head = util.utf8Prefix(text, cap - marker.len);
    // util.utf8Prefix returns a prefix of `text`; stitch the marker only when
    // the caller copied onto a buffer they own. Here we return the bare
    // prefix — callers that need the marker use `applyAlloc`.
    return head;
}

pub fn applyAlloc(arena: std.mem.Allocator, text: []const u8, cap: usize) []const u8 {
    if (text.len <= cap) return text;
    if (cap <= marker.len) return util.utf8Prefix(text, cap);
    const head = util.utf8Prefix(text, cap - marker.len);
    return std.fmt.allocPrint(arena, "{s}{s}", .{ head, marker }) catch head;
}

/// Truncate file-backed instructions (`name`, e.g. `AGENTS.md`) to `<= cap`
/// bytes while naming the file, kept/total bytes, and exact line to read from (#1871).
pub fn applyFileAlloc(arena: std.mem.Allocator, name: []const u8, text: []const u8, cap: usize) []const u8 {
    if (text.len <= cap) return text;
    // Upper-bound marker length so `head.len + suffix.len <= cap` always holds.
    const worst = std.fmt.allocPrint(
        arena,
        "\n[{s} cut at {d} of {d} bytes (--context-limit); read {s} from line {d} for the rest]",
        .{ name, cap, text.len, name, text.len },
    ) catch return applyAlloc(arena, text, cap);
    if (cap <= worst.len) return applyAlloc(arena, text, cap);
    var head = util.utf8Prefix(text, cap - worst.len);
    if (std.mem.lastIndexOfScalar(u8, head, '\n')) |nl| {
        if (nl > head.len / 2) head = head[0..nl];
    }
    const resume_line = 1 + std.mem.count(u8, head, "\n") + @intFromBool(head.len < text.len and text[head.len] == '\n');
    return std.fmt.allocPrint(
        arena,
        "{s}\n[{s} cut at {d} of {d} bytes (--context-limit); read {s} from line {d} for the rest]",
        .{ head, name, head.len, text.len, name, resume_line },
    ) catch head;
}

/// Truncate a generated prompt section (`label`) to `<= cap` bytes with an
/// actionable recovery `hint` (#1871).
pub fn applySectionAlloc(arena: std.mem.Allocator, label: []const u8, text: []const u8, cap: usize, hint: []const u8) []const u8 {
    if (text.len <= cap) return text;
    const worst = std.fmt.allocPrint(
        arena,
        "\n[{s} cut at {d} of {d} bytes (--context-limit); {s}]",
        .{ label, cap, text.len, hint },
    ) catch return applyAlloc(arena, text, cap);
    if (cap <= worst.len) return applyAlloc(arena, text, cap);
    var head = util.utf8Prefix(text, cap - worst.len);
    if (std.mem.lastIndexOfScalar(u8, head, '\n')) |nl| {
        if (nl > head.len / 2) head = head[0..nl];
    }
    return std.fmt.allocPrint(
        arena,
        "{s}\n[{s} cut at {d} of {d} bytes (--context-limit); {s}]",
        .{ head, label, head.len, text.len, hint },
    ) catch head;
}

test "named limits parse and refuse a silent no-op" {
    resetForTest();
    defer resetForTest();
    try applyPair("skill_catalog_bytes=512");
    try std.testing.expectEqual(@as(usize, 512), skill_catalog_bytes);
    try std.testing.expectError(error.UnknownLimit, applyPair("nope=8"));
    try std.testing.expectError(error.BadLimit, applyPair("agents_md_bytes=0"));
    try std.testing.expectError(error.BadLimit, applyPair("mcp_schema_bytes"));
    applyEnv("mcp_schema_bytes=100,agents_md_bytes=200");
    try std.testing.expectEqual(@as(usize, 100), mcp_schema_bytes);
    try std.testing.expectEqual(@as(usize, 200), agents_md_bytes);
}

test "apply never grows and marks a truncate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const small = "short";
    try std.testing.expectEqualStrings(small, apply(small, 32));
    const big = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const cut = applyAlloc(a, big, 40);
    try std.testing.expect(cut.len <= 40);
    try std.testing.expect(std.mem.indexOf(u8, cut, "[truncated by --context-limit]") != null);
    try std.testing.expect(std.mem.startsWith(u8, cut, "abc"));
}

test "#1871: applyFileAlloc and applySectionAlloc stay within cap and give actionable recovery" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var doc: std.ArrayList(u8) = .empty;
    for (1..30) |line_no| try doc.print(a, "Rule line {d}: keep every check deterministic and fast.\n", .{line_no});
    const file_cut = applyFileAlloc(a, "AGENTS.md", doc.items, 320);
    try std.testing.expect(file_cut.len <= 320);
    try std.testing.expect(std.mem.indexOf(u8, file_cut, "[AGENTS.md cut at ") != null);
    try std.testing.expect(std.mem.indexOf(u8, file_cut, "read AGENTS.md from line ") != null);

    const sec_cut = applySectionAlloc(a, "skill catalog", doc.items, 260, "call `skill` with no name for the full list");
    try std.testing.expect(sec_cut.len <= 260);
    try std.testing.expect(std.mem.indexOf(u8, sec_cut, "[skill catalog cut at ") != null);
    try std.testing.expect(std.mem.indexOf(u8, sec_cut, "call `skill` with no name") != null);
}
