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
    fold.resetContextKnob();
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
    // Name stays off the meta listing (that would rewrite the tools head).
    const still = try schema_mod.renderRootTools(arena, .openai, &with_rlm, &.{});
    try std.testing.expect(std.mem.indexOf(u8, still, "rlm") == null);
    try std.testing.expect(std.mem.indexOf(u8, still, "llm_query") == null);

    fold.markLoaded("rlm");
    const shown = try schema_mod.renderRootTools(arena, .openai, &with_rlm, &.{});
    try std.testing.expect(std.mem.indexOf(u8, shown, "rlm") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "llm_query") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, rlm.tool_schema) != null);
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

test "wide-native showcase rebuilds the cached catalog (not invalidate-only)" {
    const provider_mod = @import("provider.zig");
    const FakeAgent = struct {
        provider: struct { kind: provider_mod.Provider.Kind } = .{ .kind = .responses },
        invalidations: usize = 0,
        rebuilds: usize = 0,
        pub fn invalidateRootTools(self: *@This()) void {
            self.invalidations += 1;
        }
        pub fn ensureRootTools(self: *@This(), kind: provider_mod.Provider.Kind) !void {
            try std.testing.expectEqual(provider_mod.Provider.Kind.responses, kind);
            self.rebuilds += 1;
        }
    };

    const saved_spec = rlm_spec.available;
    defer {
        rlm_spec.available = saved_spec;
        fold.resetRlmDiscovery();
    }
    isolate();
    rlm_spec.available = true;

    var agent: FakeAgent = .{};
    try std.testing.expect(!fold.noticeWideNativeAndRefresh(&agent, &.{ "read_file", "codedb", "bash" }));
    try std.testing.expectEqual(@as(usize, 0), agent.invalidations);
    try std.testing.expectEqual(@as(usize, 0), agent.rebuilds);

    try std.testing.expect(fold.noticeWideNativeAndRefresh(&agent, &.{ "read_file", "codedb", "bash", "webfetch" }));
    try std.testing.expect(fold.listed());
    try std.testing.expect(fold.isLoaded("rlm"));
    try std.testing.expectEqual(@as(usize, 1), agent.invalidations);
    try std.testing.expectEqual(@as(usize, 1), agent.rebuilds);

    try std.testing.expect(!fold.noticeWideNativeAndRefresh(&agent, &.{ "read_file", "codedb", "bash", "webfetch" }));
    try std.testing.expectEqual(@as(usize, 1), agent.invalidations);
    try std.testing.expectEqual(@as(usize, 1), agent.rebuilds);
}

test "context below 50% of compactAt does not showcase; crossing it does" {
    const saved_spec = rlm_spec.available;
    defer {
        rlm_spec.available = saved_spec;
        fold.resetRlmDiscovery();
        fold.resetContextKnob();
    }
    isolate();
    rlm_spec.available = true;

    // Default: 50% of compactAt. compactAt=8000 → threshold 4000.
    try std.testing.expectEqual(@as(?u64, 4000), fold.contextThreshold(8000));
    try std.testing.expect(!fold.noticeContext(0, 8000));
    try std.testing.expect(!fold.noticeContext(3999, 8000));
    try std.testing.expect(!fold.listed());

    try std.testing.expect(fold.noticeContext(4000, 8000));
    try std.testing.expect(fold.listed());
    try std.testing.expect(fold.isLoaded("rlm"));
    try std.testing.expect(!fold.noticeContext(8000, 8000)); // already showcased

    fold.resetSession();
    try std.testing.expect(!fold.listed());
    try std.testing.expect(!fold.isLoaded("rlm"));

    fold.g_context_off = true;
    try std.testing.expect(!fold.noticeContext(8000, 8000));
    try std.testing.expect(!fold.listed());
}

test "lean first turn and MCP fan-out stay below the context trigger" {
    const saved_spec = rlm_spec.available;
    const saved_lean = no_local.lean;
    defer {
        rlm_spec.available = saved_spec;
        no_local.lean = saved_lean;
        fold.resetRlmDiscovery();
        fold.resetContextKnob();
    }
    isolate();
    rlm_spec.available = true;
    no_local.lean = true;

    // A small -p prompt is nowhere near 50% of a real compactAt.
    try std.testing.expect(!fold.noticeContext(800, 160_000));
    try std.testing.expect(!fold.listed());
    try std.testing.expect(!fold.noticeWideNative(&.{
        "mcp__linear__list_comments",
        "mcp__linear__list_comments",
        "mcp__linear__list_comments",
        "mcp__linear__list_comments",
    }));
    try std.testing.expect(!fold.listed());
}

test "showcasing rlm keeps the tools head bytes; schema rides the tail" {
    const saved_avail = rlm.available;
    const saved_spec = rlm_spec.available;
    const saved_stable = mcp_schema_gate.g_stable_catalog;
    defer {
        rlm.available = saved_avail;
        rlm_spec.available = saved_spec;
        rlm.sync();
        mcp_schema_gate.g_stable_catalog = saved_stable;
        fold.resetRlmDiscovery();
        fold.resetContextKnob();
    }
    isolate();
    mcp_schema_gate.g_stable_catalog = true;
    rlm.available = true;
    rlm.sync();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const specs = [_]schema_mod.ToolSpec{
        .{
            .name = mcp_schema_gate.tool_name,
            .desc = mcp_schema_gate.tool_desc,
            .schema = mcp_schema_gate.tool_schema,
        },
        .{ .name = "bash", .desc = "run a command", .schema = "{\"type\":\"object\"}" },
        .{ .name = rlm.tool_name, .desc = rlm.tool_desc, .schema = rlm.tool_schema },
    };

    const before = try schema_mod.renderRootTools(arena, .openai, &specs, &.{});
    try std.testing.expect(std.mem.indexOf(u8, before, "rlm") == null);
    try std.testing.expect(std.mem.indexOf(u8, before, rlm.tool_schema) == null);

    try std.testing.expect(fold.noticeContext(50_000, 80_000));
    const after = try schema_mod.renderRootTools(arena, .openai, &specs, &.{});
    try std.testing.expect(before.len >= 1 and before[before.len - 1] == ']');
    try std.testing.expect(std.mem.startsWith(u8, after, before[0 .. before.len - 1]));
    try std.testing.expect(after.len > before.len);
    try std.testing.expect(after[before.len - 1] == ',');
    try std.testing.expect(std.mem.indexOf(u8, after[before.len - 1 ..], rlm.tool_schema) != null);
    try std.testing.expect(std.mem.indexOf(u8, after[before.len - 1 ..], "llm_query") != null);

    fold.resetSession();
    try std.testing.expect(!fold.listed());
}
