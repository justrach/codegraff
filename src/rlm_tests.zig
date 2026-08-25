//! Tests split out of rlm.zig so the REPL stays under the 600-line cap.

const std = @import("std");
const Io = std.Io;

const rlm = @import("rlm.zig");
const rlm_spec = @import("rlm_spec.zig");
const no_local_tools = @import("no_local_tools.zig");
const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;

fn testCtx(gpa: std.mem.Allocator, io: Io, client: *std.http.Client) ToolCtx {
    return .{
        .gpa = gpa,
        .io = io,
        .client = client,
        .provider = undefined,
        .registry = null,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
    };
}

test "maybeAppend is a no-op when --old, and refuses to double-append" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Spec = struct { name: []const u8, desc: []const u8 = "", schema: []const u8 = "{}" };
    const base = [_]Spec{.{ .name = "read_file" }};
    const saved = rlm.available;
    const saved_local = no_local_tools.enabled;
    defer {
        rlm.available = saved;
        no_local_tools.enabled = saved_local;
    }
    rlm.available = false;
    no_local_tools.enabled = false;
    try std.testing.expectEqual(@as(usize, 1), (try rlm.maybeAppend(Spec, arena, &base)).len);
    rlm.available = true;
    const one = try rlm.maybeAppend(Spec, arena, &base);
    try std.testing.expectEqual(@as(usize, 2), one.len);
    try std.testing.expectEqualStrings(rlm.tool_name, one[1].name);
    const two = try rlm.maybeAppend(Spec, arena, one);
    try std.testing.expectEqual(@as(usize, 2), two.len);
    rlm.available = true;
    no_local_tools.enabled = true;
    try std.testing.expectEqual(@as(usize, 1), (try rlm.maybeAppend(Spec, arena, &base)).len);
}

test "runScript speculates three sleeps so wall time is ~one sleep, not three" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dummy_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer dummy_client.deinit();
    const saved = rlm.available;
    defer {
        rlm.available = saved;
        rlm.resetLive(gpa, io);
    }
    rlm.available = true;
    const ctx = testCtx(gpa, io, &dummy_client);
    const t0: Io.Timestamp = .now(io, .awake);
    const out = try rlm.runScript(ctx, "a = sleep_ms(40)\nb = sleep_ms(41)\nc = sleep_ms(42)\nprint(a)");
    defer gpa.free(out.text);
    const dt = t0.untilNow(io, .awake).toMilliseconds();
    try std.testing.expect(!out.is_error);
    try std.testing.expectEqualStrings("slept 40ms", out.text);
    try std.testing.expect(dt < 100);
}

test "runScript reads a fixture via speculated read_file and prints it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "hello-rlm\n" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buf);
    const dir = path_buf[0..n];
    var dummy_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer dummy_client.deinit();
    const saved = rlm.available;
    defer {
        rlm.available = saved;
        rlm.resetLive(gpa, io);
    }
    rlm.available = true;
    var ctx = testCtx(gpa, io, &dummy_client);
    ctx.agent_cwd = dir;
    const out = try rlm.runScript(ctx, "x = read_file(\"note.txt\")\nprint(x)");
    defer gpa.free(out.text);
    try std.testing.expect(!out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "hello-rlm") != null);
    const nested = try rlm.runScript(ctx, "print(read_file(\"note.txt\"))");
    defer gpa.free(nested.text);
    try std.testing.expect(!nested.is_error);
    try std.testing.expect(std.mem.indexOf(u8, nested.text, "hello-rlm") != null);
}

test "runScript splits a semicolon one-liner and prints both binds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dummy_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer dummy_client.deinit();
    const saved = rlm.available;
    defer {
        rlm.available = saved;
        rlm.resetLive(gpa, io);
    }
    rlm.available = true;
    const ctx = testCtx(gpa, io, &dummy_client);
    const t0: Io.Timestamp = .now(io, .awake);
    const out = try rlm.runScript(ctx, "a = sleep_ms(40); b = sleep_ms(41); print(a, b)");
    defer gpa.free(out.text);
    const dt = t0.untilNow(io, .awake).toMilliseconds();
    try std.testing.expect(!out.is_error);
    try std.testing.expectEqualStrings("slept 40ms\nslept 41ms", out.text);
    try std.testing.expect(dt < 90);
}

test "feedLive launches sleeps before runScript, so claim is a hit not a re-run" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dummy_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer dummy_client.deinit();
    const saved = rlm.available;
    defer {
        rlm.available = saved;
        rlm.resetLive(gpa, io);
    }
    rlm.available = true;
    const ctx = testCtx(gpa, io, &dummy_client);
    const t0: Io.Timestamp = .now(io, .awake);
    rlm.feedLive(ctx, "a = sleep_ms(40)\n");
    rlm.feedLive(ctx, "b = sleep_ms(41)\n");
    rlm.feedLive(ctx, "c = sleep_ms(42)\n");
    const out = try rlm.runScript(ctx, "a = sleep_ms(40)\nb = sleep_ms(41)\nc = sleep_ms(42)\nprint(a)");
    defer gpa.free(out.text);
    const dt = t0.untilNow(io, .awake).toMilliseconds();
    try std.testing.expect(!out.is_error);
    try std.testing.expectEqualStrings("slept 40ms", out.text);
    try std.testing.expect(dt < 100);
}

test "feedLive splits a semicolon line before runScript claims" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dummy_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer dummy_client.deinit();
    const saved = rlm.available;
    defer {
        rlm.available = saved;
        rlm.resetLive(gpa, io);
    }
    rlm.available = true;
    const ctx = testCtx(gpa, io, &dummy_client);
    const t0: Io.Timestamp = .now(io, .awake);
    rlm.feedLive(ctx, "a = sleep_ms(40); b = sleep_ms(41)\n");
    const out = try rlm.runScript(ctx, "a = sleep_ms(40); b = sleep_ms(41); print(a, b)");
    defer gpa.free(out.text);
    const dt = t0.untilNow(io, .awake).toMilliseconds();
    try std.testing.expect(!out.is_error);
    try std.testing.expectEqualStrings("slept 40ms\nslept 41ms", out.text);
    try std.testing.expect(dt < 90);
}

test "runScript reuses last-script binds; resetLive drops them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dummy_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer dummy_client.deinit();
    const saved = rlm.available;
    defer {
        rlm.available = saved;
        rlm.resetLive(gpa, io);
    }
    rlm.available = true;
    const ctx = testCtx(gpa, io, &dummy_client);
    const first = try rlm.runScript(ctx, "prev = sleep_ms(1)");
    defer gpa.free(first.text);
    try std.testing.expect(!first.is_error);
    const reuse = try rlm.runScript(ctx, "print(prev)");
    defer gpa.free(reuse.text);
    try std.testing.expect(!reuse.is_error);
    try std.testing.expectEqualStrings("slept 1ms", reuse.text);
    const overwrite = try rlm.runScript(ctx, "prev = sleep_ms(2); print(prev)");
    defer gpa.free(overwrite.text);
    try std.testing.expectEqualStrings("slept 2ms", overwrite.text);
    const kept = try rlm.runScript(ctx, "print(prev)");
    defer gpa.free(kept.text);
    try std.testing.expectEqualStrings("slept 2ms", kept.text);
    rlm.resetLive(gpa, io);
    const gone = try rlm.runScript(ctx, "print(prev)");
    defer gpa.free(gone.text);
    try std.testing.expectEqualStrings("prev", gone.text);
}

test "runScript last assignment wins when a name is rebound in one script" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dummy_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer dummy_client.deinit();
    const saved = rlm.available;
    defer {
        rlm.available = saved;
        rlm.resetLive(gpa, io);
    }
    rlm.available = true;
    const ctx = testCtx(gpa, io, &dummy_client);
    const out = try rlm.runScript(ctx, "a = sleep_ms(1); a = sleep_ms(2); print(a)");
    defer gpa.free(out.text);
    try std.testing.expect(!out.is_error);
    try std.testing.expectEqualStrings("slept 2ms", out.text);
}

fn catalogHas(specs: anytype, name: []const u8) bool {
    for (specs) |s| if (std.mem.eql(u8, s.name, name)) return true;
    return false;
}

test "maybeAppend keeps subagent and workflow; rlm is never the only catalog tool" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Spec = struct { name: []const u8, desc: []const u8 = "", schema: []const u8 = "{}" };
    const base = [_]Spec{
        .{ .name = "read_file" },
        .{ .name = "subagent" },
        .{ .name = "workflow" },
    };
    const saved = rlm.available;
    const saved_local = no_local_tools.enabled;
    defer {
        rlm.available = saved;
        no_local_tools.enabled = saved_local;
        rlm.sync();
    }
    rlm.available = true;
    no_local_tools.enabled = false;
    const on = try rlm.maybeAppend(Spec, arena, &base);
    try std.testing.expectEqual(@as(usize, 4), on.len);
    try std.testing.expect(catalogHas(on, "subagent"));
    try std.testing.expect(catalogHas(on, "workflow"));
    try std.testing.expect(catalogHas(on, rlm.tool_name));
    try std.testing.expect(on.len > 1);

    rlm.available = false;
    const off = try rlm.maybeAppend(Spec, arena, &base);
    try std.testing.expectEqual(@as(usize, 3), off.len);
    try std.testing.expect(catalogHas(off, "subagent"));
    try std.testing.expect(!catalogHas(off, rlm.tool_name));
}

test "effectiveRootSpecs: default rlm keeps subagent; --old and --lean do not drop it" {
    const schema = @import("schema.zig");
    const root = @import("main.zig");
    const learn_store = @import("learn_store.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const saved = rlm.available;
    const saved_lean = no_local_tools.lean;
    const saved_local = no_local_tools.enabled;
    const saved_clock = root.g_clock_sleep;
    const saved_learn = learn_store.active_agent_loaded;
    defer {
        rlm.available = saved;
        no_local_tools.lean = saved_lean;
        no_local_tools.enabled = saved_local;
        root.g_clock_sleep = saved_clock;
        learn_store.active_agent_loaded = saved_learn;
        rlm.sync();
    }
    no_local_tools.enabled = false;
    root.g_clock_sleep = false;
    learn_store.active_agent_loaded = true;

    rlm.available = true;
    no_local_tools.lean = false;
    rlm.sync();
    const def = try schema.effectiveRootSpecs(arena);
    try std.testing.expect(catalogHas(def, "subagent"));
    try std.testing.expect(catalogHas(def, "workflow"));
    try std.testing.expect(catalogHas(def, rlm.tool_name));
    try std.testing.expect(def.len > 2);

    rlm.available = false;
    rlm.sync();
    const old = try schema.effectiveRootSpecs(arena);
    try std.testing.expect(catalogHas(old, "subagent"));
    try std.testing.expect(catalogHas(old, "workflow"));
    try std.testing.expect(!catalogHas(old, rlm.tool_name));

    rlm.available = true;
    no_local_tools.lean = true;
    rlm.sync();
    const lean_on = try schema.effectiveRootSpecs(arena);
    try std.testing.expect(catalogHas(lean_on, "subagent"));
    try std.testing.expect(catalogHas(lean_on, rlm.tool_name));
    try std.testing.expect(!catalogHas(lean_on, "workflow"));
    try std.testing.expect(catalogHas(lean_on, "bash"));
    try std.testing.expect(no_local_tools.leanKeeps("subagent"));
    try std.testing.expect(!no_local_tools.leanKeeps(rlm.tool_name));
}

test "runScript empty subagent() reaches execSubagent; persist binds do not break that" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dummy_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer dummy_client.deinit();
    const saved = rlm.available;
    defer {
        rlm.available = saved;
        rlm.resetLive(gpa, io);
    }
    rlm.available = true;
    const ctx = testCtx(gpa, io, &dummy_client);
    const first = try rlm.runScript(ctx, "prev = sleep_ms(1)");
    defer gpa.free(first.text);
    try std.testing.expect(!first.is_error);
    const miss = try rlm.runScript(ctx, "h = subagent()");
    defer gpa.free(miss.text);
    try std.testing.expect(miss.is_error);
    try std.testing.expect(std.mem.indexOf(u8, miss.text, "missing required") != null);
    try std.testing.expect(std.mem.indexOf(u8, miss.text, "prompt") != null);
    const reuse = try rlm.runScript(ctx, "print(prev)");
    defer gpa.free(reuse.text);
    try std.testing.expect(!reuse.is_error);
    try std.testing.expectEqualStrings("slept 1ms", reuse.text);
}

test "feedLive launches two independent subagent() calls before runScript claims" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dummy_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer dummy_client.deinit();
    const saved = rlm.available;
    defer {
        rlm.available = saved;
        rlm.resetLive(gpa, io);
    }
    rlm.available = true;
    const ctx = testCtx(gpa, io, &dummy_client);
    rlm.feedLive(ctx, "a = subagent()\n");
    rlm.feedLive(ctx, "b = subagent(\"\")\n");
    var claimed = std.StringHashMap(ToolOutput).init(gpa);
    defer {
        var it = claimed.iterator();
        while (it.next()) |e| gpa.free(e.value_ptr.text);
        claimed.deinit();
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    rlm_spec.takeLive(ctx, &claimed, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 2), claimed.count());
    var it = claimed.iterator();
    while (it.next()) |e| {
        try std.testing.expect(e.value_ptr.is_error);
        try std.testing.expect(std.mem.indexOf(u8, e.value_ptr.text, "prompt") != null);
    }
}

test "rlm prompt: subagent() is advertised as sidecar-only, not a critical-path handoff" {
    try std.testing.expect(std.mem.indexOf(u8, rlm.tool_desc, "sidecar-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, rlm.tool_desc, "critical-path") != null);
    try std.testing.expect(std.mem.indexOf(u8, rlm_spec.system_note, "sidecar-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, rlm_spec.system_note, "critical-path") != null);
    try std.testing.expect(rlm.tool_desc.len < 600);
    try std.testing.expect(std.mem.indexOf(u8, rlm.lean_tool_desc, "load_tool_schemas") != null);
    try std.testing.expect(std.mem.indexOf(u8, rlm.lean_tool_desc, "MCP") != null);
}

test "runScript refuses an unloaded MCP name and does not treat it as a host tool" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dummy_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer dummy_client.deinit();
    const saved = rlm.available;
    const saved_mcp = @import("rlm_mcp.zig").host_enabled;
    defer {
        rlm.available = saved;
        @import("rlm_mcp.zig").host_enabled = saved_mcp;
        rlm.resetLive(gpa, io);
    }
    rlm.available = true;
    @import("rlm_mcp.zig").host_enabled = true;
    const ctx = testCtx(gpa, io, &dummy_client);
    const out = try rlm.runScript(ctx, "x = mcp__linear__list_issues()\nprint(x)");
    defer gpa.free(out.text);
    try std.testing.expect(out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "MCP not available") != null or std.mem.indexOf(u8, out.text, "load_tool_schemas") != null);
}
