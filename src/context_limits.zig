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
