//! Late-showcase tests for folded `rlm` (ADR 0030). Split out of
//! native_fold.zig so that file stays under the 600-line ceiling.

const std = @import("std");
const fold = @import("native_fold.zig");
const schema_mod = @import("schema.zig");
const rlm = @import("rlm.zig");
const rlm_spec = @import("rlm_spec.zig");
const mcp_schema_gate = @import("mcp_schema_gate.zig");
const no_local = @import("no_local_tools.zig");

fn isolate() void {
    fold.enabled = true;
    fold.resetRlmDiscovery();
}

test "rlm joins the fold only while available (off under --old)" {
    const saved_avail = rlm_spec.available;
    const saved_enabled = fold.enabled;
    defer {
        rlm_spec.available = saved_avail;
        fold.enabled = saved_enabled;
        fold.resetRlmDiscovery();
    }
    isolate();
    rlm_spec.available = false;
    try std.testing.expect(!fold.isFolded("rlm"));
    try std.testing.expect(!fold.blocked("rlm"));

    rlm_spec.available = true;
    try std.testing.expect(fold.isFolded("rlm"));
    try std.testing.expect(fold.blocked("rlm"));
    fold.markLoaded("rlm");
    try std.testing.expect(fold.isLoaded("rlm"));
    try std.testing.expect(!fold.blocked("rlm"));
}

test "folded rlm stays off the listing until showcase; off stays off" {
    const saved_avail = rlm.available;
    const saved_spec = rlm_spec.available;
    const saved_enabled = fold.enabled;
    defer {
        rlm.available = saved_avail;
        rlm_spec.available = saved_spec;
        rlm.sync();
        fold.enabled = saved_enabled;
        fold.resetRlmDiscovery();
    }
    isolate();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const meta = [_]schema_mod.ToolSpec{.{
        .name = mcp_schema_gate.tool_name,
        .desc = mcp_schema_gate.tool_desc,
        .schema = mcp_schema_gate.tool_schema,
    }};
    const with_rlm = [_]schema_mod.ToolSpec{
        meta[0],
        .{ .name = rlm.tool_name, .desc = rlm.tool_desc, .schema = rlm.tool_schema },
    };

    rlm.available = false;
    rlm.sync();
    const off = try schema_mod.renderRootTools(arena, .openai, &meta, &.{});
    try std.testing.expect(std.mem.indexOf(u8, off, "rlm") == null);

    rlm.available = true;
    rlm.sync();
    try std.testing.expect(fold.isFolded("rlm"));
    try std.testing.expect(!fold.listed());
    const hidden = try schema_mod.renderRootTools(arena, .openai, &with_rlm, &.{});
    try std.testing.expect(std.mem.indexOf(u8, hidden, "rlm") == null);
    try std.testing.expect(std.mem.indexOf(u8, hidden, "llm_query") == null);

    fold.showcaseRlm();
    try std.testing.expect(fold.listed());
    const shown = try schema_mod.renderRootTools(arena, .openai, &with_rlm, &.{});
    try std.testing.expect(std.mem.indexOf(u8, shown, "rlm") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "llm_query") == null);
    try std.testing.expect(std.mem.indexOf(u8, shown, rlm.tool_schema) == null);
}

test "lean keeps rlm folded until showcase; --rlm puts the schema on" {
    const saved_avail = rlm.available;
    const saved_spec = rlm_spec.available;
    const saved_enabled = fold.enabled;
    const saved_lean = no_local.lean;
    defer {
        rlm.available = saved_avail;
        rlm_spec.available = saved_spec;
        rlm.sync();
        fold.enabled = saved_enabled;
        no_local.lean = saved_lean;
        fold.resetRlmDiscovery();
    }
    isolate();
    no_local.lean = true;
    rlm.available = true;
    rlm.sync();
    try std.testing.expect(fold.isFolded("rlm"));
    try std.testing.expect(fold.catalogSkips("rlm"));
    try std.testing.expect(!fold.listed());

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const specs = [_]schema_mod.ToolSpec{
        .{ .name = rlm.tool_name, .desc = rlm.tool_desc, .schema = rlm.tool_schema },
    };
    const hidden = try schema_mod.renderRootTools(arena, .openai, &specs, &.{});
    try std.testing.expect(std.mem.indexOf(u8, hidden, "llm_query") == null);
    try std.testing.expect(std.mem.indexOf(u8, hidden, rlm.tool_schema) == null);

    fold.showcaseFromCli();
    try std.testing.expect(fold.listed());
    try std.testing.expect(fold.isLoaded("rlm"));
    // Stable catalog still skips the mid-array slot; the schema rides the tail.
    const shown = try schema_mod.renderRootTools(arena, .openai, &specs, &.{});
    try std.testing.expect(std.mem.indexOf(u8, shown, "llm_query") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, rlm.tool_schema) != null);
}

test "wide native batch showcases rlm; MCP fan-out does not" {
    const saved_spec = rlm_spec.available;
    defer {
        rlm_spec.available = saved_spec;
        fold.resetRlmDiscovery();
    }
    isolate();
    rlm_spec.available = true;

    try std.testing.expect(!fold.noticeWideNative(&.{ "read_file", "codedb", "bash" }));
    try std.testing.expect(!fold.listed());
    try std.testing.expect(!fold.noticeWideNative(&.{
        "mcp__linear__list_comments",
        "mcp__linear__list_comments",
        "mcp__linear__list_comments",
        "mcp__linear__list_comments",
    }));
    try std.testing.expect(!fold.listed());

    try std.testing.expect(fold.noticeWideNative(&.{ "read_file", "codedb", "bash", "webfetch" }));
    try std.testing.expect(fold.listed());
    try std.testing.expect(fold.isLoaded("rlm"));

    fold.resetSession();
    try std.testing.expect(!fold.listed());
    try std.testing.expect(!fold.isLoaded("rlm"));

    fold.showcaseFromCli();
    fold.resetSession();
    try std.testing.expect(fold.listed());
}
