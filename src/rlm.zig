//! Default `rlm` tool: one programmatic-tool-calling REPL per call (ADR 0022).
//!
//! On unless `--old` / `--no-rlm` / `GRAFF_OLD=1` / `GRAFF_RLM=0`. `--rlm`
//! and `GRAFF_RLM=1` force it back on. Host functions: `read_file`, `codedb`
//! (real graff tools), `sleep_ms` (overlap proof), `llm_query` (RLM tools-off
//! sub-LM), `print` (answer). Closed literal calls launch as the `code`
//! argument streams (spec-ptc) and again at exec for anything the stream missed.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const spec_ptc = @import("spec_ptc.zig");
const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;
const no_local_tools = @import("no_local_tools.zig");
const exec_mod = @import("exec.zig");
const rlm_query = @import("rlm_query.zig");
const rlm_spec = @import("rlm_spec.zig");

pub const tool_name = "rlm";
pub const tool_desc = "Programmatic tool calling (RLM + sPTC). Run a short Python-like script whose functions ARE this session's tools. Independent read_file/codedb/bash/webfetch/sleep_ms/llm_query/subagent calls with literal arguments start in parallel as the script streams (speculated), then print() is the answer. Assignments persist across rlm calls in this session. subagent(\"task\") is Prime-style recursion (graff's subagent tool; sync in v1; run_in_background=true returns an id). Semicolons or newlines separate statements. llm_query(prompt) is a tools-off sub-LM call. Example: a = read_file(\"src/main.zig\"); b = codedb(\"status\"); print(a, b). No imports, no control flow — assignments and calls only. Prefer this over N separate tool calls when the work does not depend on itself.";
pub const tool_schema =
    \\{"type": "object", "properties": {"code": {"type": "string", "description": "Python-like script: name = read_file(\"path\") / codedb(\"command\") / bash(\"cmd\") / sleep_ms(ms) / llm_query(\"prompt\") / subagent(\"task\"); print(...) is the result. Assignments persist across rlm calls. Semicolons or newlines separate statements."}}, "required": ["code"]}
;

/// Process-global: on by default. `--old` / `--no-rlm` turn it off; `--rlm`
/// turns it on. Never flipped mid-session. Keep in sync with
/// rlm_spec.available (`sync`) so the SSE path can see it without importing
/// this file (exec.zig would cycle through Agent).
pub var available: bool = true;
/// True after `--rlm` / `--old` / `--no-rlm` so env knobs cannot clobber CLI.
pub var cli_set: bool = false;

pub fn sync() void {
    rlm_spec.available = available;
    rlm_spec.run_host = runHost;
}

/// Last CLI flag wins. Marks `cli_set` so GRAFF_RLM / GRAFF_OLD stay off this path.
pub fn setFromCli(on: bool) void {
    available = on;
    cli_set = true;
    sync();
}

pub fn resetLive(gpa: Allocator, io: Io) void {
    sync();
    rlm_spec.resetLive(gpa, io);
    rlm_spec.resetBinds(gpa, io);
}

pub fn feedLive(ctx: ToolCtx, delta: []const u8) void {
    sync();
    rlm_spec.feedLive(ctx, delta);
}

/// Append `rlm` after the lean/no-local filters so the default `-p` still
/// sees it. The spec is folded behind `load_tool_schemas` (native_fold)
/// until the model loads or calls it — the prefix stays the lean catalog
/// plus a name. No-op when `--old` or embedder mode stripped host tools.
pub fn maybeAppend(comptime Spec: type, arena: Allocator, specs: []const Spec) ![]const Spec {
    sync();
    if (!available or no_local_tools.enabled) return specs;
    for (specs) |s| if (std.mem.eql(u8, s.name, tool_name)) return specs;
    const buf = try arena.alloc(Spec, specs.len + 1);
    @memcpy(buf[0..specs.len], specs);
    buf[specs.len] = .{ .name = tool_name, .desc = tool_desc, .schema = tool_schema };
    return buf;
}

pub fn exec(ctx: ToolCtx, input: Value) !ToolOutput {
    sync();
    if (!available) return .{ .text = try ctx.gpa.dupe(u8, "rlm is off — pass --rlm or drop --old"), .is_error = true };
    if (no_local_tools.enabled) return .{ .text = try ctx.gpa.dupe(u8, "rlm is a host tool and is disabled under --no-local-tools"), .is_error = true };
    const code = tools.strField(input, "code") orelse return tools.missingArg(ctx.gpa, "code");
    return runScript(ctx, code);
}

const Binding = rlm_spec.Binding;

pub fn runScript(ctx: ToolCtx, code: []const u8) !ToolOutput {
    sync();
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var claimed = std.StringHashMap(ToolOutput).init(ctx.gpa);
    defer {
        var cit = claimed.iterator();
        while (cit.next()) |e| ctx.gpa.free(e.value_ptr.text);
        claimed.deinit();
    }
    rlm_spec.takeLive(ctx, &claimed, arena);

    const stmts = try spec_ptc.splitStatements(arena, code);

    const calls = try spec_ptc.extractCalls(arena, stmts);
    try speculate(ctx, arena, calls, &claimed);

    var binds: std.ArrayList(Binding) = .empty;
    try rlm_spec.seedBinds(ctx.gpa, ctx.io, arena, &binds);
    defer rlm_spec.commitBinds(ctx.gpa, ctx.io, binds.items) catch {};
    var printed: std.ArrayList(u8) = .empty;
    defer printed.deinit(ctx.gpa);

    for (stmts) |stmt| {
        if (try evalStmt(ctx, arena, stmt, binds.items, &claimed, &printed, &binds)) |err| {
            return .{ .text = err, .is_error = true };
        }
    }
    if (printed.items.len == 0) return .{ .text = try ctx.gpa.dupe(u8, "(rlm: script produced no print())") };
    return .{ .text = try printed.toOwnedSlice(ctx.gpa) };
}

fn speculate(ctx: ToolCtx, arena: Allocator, calls: []const spec_ptc.Call, claimed: *std.StringHashMap(ToolOutput)) !void {
    if (calls.len == 0) return;
    var uniq: std.ArrayList(spec_ptc.Call) = .empty;
    var seen = std.StringHashMap(void).init(arena);
    for (calls) |c| {
        const key = try c.key(arena);
        if (claimed.contains(key)) continue;
        if (try seen.fetchPut(key, {})) |_| continue;
        try uniq.append(arena, c);
    }
    if (uniq.items.len == 0) return;
    const futs = try arena.alloc(Io.Future(ToolOutput), uniq.items.len);
    const keys = try arena.alloc([]const u8, uniq.items.len);
    for (uniq.items, futs, keys) |c, *fut, *key| {
        key.* = try c.key(arena);
        fut.* = ctx.io.async(runHost, .{ ctx, c });
    }
    for (futs, keys) |*fut, key| {
        const out = fut.await(ctx.io);
        try claimed.put(key, out);
    }
}

fn runHost(ctx: ToolCtx, call: spec_ptc.Call) ToolOutput {
    if (std.mem.eql(u8, call.name, "sleep_ms")) return runSleep(ctx, call.args_json);
    if (std.mem.eql(u8, call.name, "llm_query")) return rlm_query.run(ctx, call.args_json);
    var parsed = std.json.parseFromSlice(Value, ctx.gpa, call.args_json, .{}) catch {
        return .{ .text = ctx.gpa.dupe(u8, "rlm: bad args") catch &.{}, .is_error = true };
    };
    defer parsed.deinit();
    return exec_mod.execTool(ctx, .{ .id = "rlm", .name = call.name, .input = parsed.value });
}

fn runSleep(ctx: ToolCtx, args_json: []const u8) ToolOutput {
    var parsed = std.json.parseFromSlice(Value, ctx.gpa, args_json, .{}) catch {
        return .{ .text = ctx.gpa.dupe(u8, "rlm: sleep_ms needs ms") catch &.{}, .is_error = true };
    };
    defer parsed.deinit();
    const ms = tools.intField(parsed.value, "ms") orelse 0;
    const capped: i64 = @min(@max(ms, 0), 5_000);
    ctx.io.sleep(.fromMilliseconds(capped), .awake) catch {};
    return .{ .text = std.fmt.allocPrint(ctx.gpa, "slept {d}ms", .{capped}) catch ctx.gpa.dupe(u8, "slept") catch &.{} };
}

fn evalStmt(
    ctx: ToolCtx,
    arena: Allocator,
    stmt: []const u8,
    binds: []const Binding,
    claimed: *std.StringHashMap(ToolOutput),
    printed: *std.ArrayList(u8),
    bind_out: *std.ArrayList(Binding),
) !?[]u8 {
    const call = try spec_ptc.extractCall(arena, stmt);
    if (call) |c| {
        const key = try c.key(arena);
        const out = claimed.get(key) orelse runHost(ctx, c);
        if (out.is_error) return try ctx.gpa.dupe(u8, out.text);
        if (assignName(stmt)) |nm| try bind_out.append(arena, .{ .name = try arena.dupe(u8, nm), .text = try arena.dupe(u8, out.text) });
        return null;
    }
    if (printArgs(stmt)) |inner| {
        const text = try renderPrint(arena, inner, binds);
        if (printed.items.len > 0) try printed.append(ctx.gpa, '\n');
        try printed.appendSlice(ctx.gpa, text);
        return null;
    }
    return try std.fmt.allocPrint(ctx.gpa, "rlm: unsupported statement: {s}", .{stmt});
}

fn assignName(stmt: []const u8) ?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, stmt, '=') orelse return null;
    const lhs = std.mem.trim(u8, stmt[0..eq], " \t");
    if (lhs.len == 0) return null;
    return lhs;
}

fn printArgs(stmt: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, stmt, " \t");
    if (!std.mem.startsWith(u8, t, "print(") or t[t.len - 1] != ')') return null;
    return t["print(".len .. t.len - 1];
}

fn renderPrint(arena: Allocator, inner: []const u8, binds: []const Binding) ![]const u8 {
    const parts = try spec_ptc.splitTopLevel(arena, inner, ',');
    if (parts.len == 0) return "";
    var out: std.ArrayList(u8) = .empty;
    for (parts, 0..) |part, i| {
        if (i > 0) try out.append(arena, '\n');
        try out.appendSlice(arena, try renderPrintPart(arena, part, binds));
    }
    return out.toOwnedSlice(arena);
}

fn renderPrintPart(arena: Allocator, inner: []const u8, binds: []const Binding) ![]const u8 {
    const t = std.mem.trim(u8, inner, " \t");
    if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0]) return t[1 .. t.len - 1];
    var i = binds.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, binds[i].name, t)) return binds[i].text;
    }
    return try arena.dupe(u8, t);
}

fn testCtx(gpa: Allocator, io: Io, client: *std.http.Client) ToolCtx {
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
    const saved = available;
    const saved_local = no_local_tools.enabled;
    defer {
        available = saved;
        no_local_tools.enabled = saved_local;
    }
    available = false;
    no_local_tools.enabled = false;
    try std.testing.expectEqual(@as(usize, 1), (try maybeAppend(Spec, arena, &base)).len);
    available = true;
    const one = try maybeAppend(Spec, arena, &base);
    try std.testing.expectEqual(@as(usize, 2), one.len);
    try std.testing.expectEqualStrings(tool_name, one[1].name);
    const two = try maybeAppend(Spec, arena, one);
    try std.testing.expectEqual(@as(usize, 2), two.len);
    available = true;
    no_local_tools.enabled = true;
    try std.testing.expectEqual(@as(usize, 1), (try maybeAppend(Spec, arena, &base)).len);
}

test "runScript speculates three sleeps so wall time is ~one sleep, not three" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dummy_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer dummy_client.deinit();
    const saved = available;
    defer {
        available = saved;
        resetLive(gpa, io);
    }
    available = true;
    const ctx = testCtx(gpa, io, &dummy_client);
    const t0: Io.Timestamp = .now(io, .awake);
    const out = try runScript(ctx, "a = sleep_ms(40)\nb = sleep_ms(41)\nc = sleep_ms(42)\nprint(a)");
    defer gpa.free(out.text);
    const dt = t0.untilNow(io, .awake).toMilliseconds();
    try std.testing.expect(!out.is_error);
    try std.testing.expectEqualStrings("slept 40ms", out.text);
    // Sequential would be ~120ms. Parallel speculation should land well under 100.
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
    const saved = available;
    defer {
        available = saved;
        resetLive(gpa, io);
    }
    available = true;
    var ctx = testCtx(gpa, io, &dummy_client);
    ctx.agent_cwd = dir;
    const out = try runScript(ctx, "x = read_file(\"note.txt\")\nprint(x)");
    defer gpa.free(out.text);
    try std.testing.expect(!out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "hello-rlm") != null);
}

test "runScript splits a semicolon one-liner and prints both binds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dummy_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer dummy_client.deinit();
    const saved = available;
    defer {
        available = saved;
        resetLive(gpa, io);
    }
    available = true;
    const ctx = testCtx(gpa, io, &dummy_client);
    const t0: Io.Timestamp = .now(io, .awake);
    const out = try runScript(ctx, "a = sleep_ms(40); b = sleep_ms(41); print(a, b)");
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
    const saved = available;
    defer {
        available = saved;
        resetLive(gpa, io);
    }
    available = true;
    const ctx = testCtx(gpa, io, &dummy_client);
    const t0: Io.Timestamp = .now(io, .awake);
    feedLive(ctx, "a = sleep_ms(40)\n");
    feedLive(ctx, "b = sleep_ms(41)\n");
    feedLive(ctx, "c = sleep_ms(42)\n");
    const out = try runScript(ctx, "a = sleep_ms(40)\nb = sleep_ms(41)\nc = sleep_ms(42)\nprint(a)");
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
    const saved = available;
    defer {
        available = saved;
        resetLive(gpa, io);
    }
    available = true;
    const ctx = testCtx(gpa, io, &dummy_client);
    const t0: Io.Timestamp = .now(io, .awake);
    feedLive(ctx, "a = sleep_ms(40); b = sleep_ms(41)\n");
    const out = try runScript(ctx, "a = sleep_ms(40); b = sleep_ms(41); print(a, b)");
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
    const saved = available;
    defer {
        available = saved;
        resetLive(gpa, io);
    }
    available = true;
    const ctx = testCtx(gpa, io, &dummy_client);
    const first = try runScript(ctx, "prev = sleep_ms(1)");
    defer gpa.free(first.text);
    try std.testing.expect(!first.is_error);
    const reuse = try runScript(ctx, "print(prev)");
    defer gpa.free(reuse.text);
    try std.testing.expect(!reuse.is_error);
    try std.testing.expectEqualStrings("slept 1ms", reuse.text);
    const overwrite = try runScript(ctx, "prev = sleep_ms(2); print(prev)");
    defer gpa.free(overwrite.text);
    try std.testing.expectEqualStrings("slept 2ms", overwrite.text);
    const kept = try runScript(ctx, "print(prev)");
    defer gpa.free(kept.text);
    try std.testing.expectEqualStrings("slept 2ms", kept.text);
    resetLive(gpa, io);
    const gone = try runScript(ctx, "print(prev)");
    defer gpa.free(gone.text);
    try std.testing.expectEqualStrings("prev", gone.text);
}

test "runScript last assignment wins when a name is rebound in one script" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dummy_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer dummy_client.deinit();
    const saved = available;
    defer {
        available = saved;
        resetLive(gpa, io);
    }
    available = true;
    const ctx = testCtx(gpa, io, &dummy_client);
    const out = try runScript(ctx, "a = sleep_ms(1); a = sleep_ms(2); print(a)");
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
    const saved = available;
    const saved_local = no_local_tools.enabled;
    defer {
        available = saved;
        no_local_tools.enabled = saved_local;
        sync();
    }
    available = true;
    no_local_tools.enabled = false;
    const on = try maybeAppend(Spec, arena, &base);
    try std.testing.expectEqual(@as(usize, 4), on.len);
    try std.testing.expect(catalogHas(on, "subagent"));
    try std.testing.expect(catalogHas(on, "workflow"));
    try std.testing.expect(catalogHas(on, tool_name));
    try std.testing.expect(on.len > 1);

    available = false;
    const off = try maybeAppend(Spec, arena, &base);
    try std.testing.expectEqual(@as(usize, 3), off.len);
    try std.testing.expect(catalogHas(off, "subagent"));
    try std.testing.expect(!catalogHas(off, tool_name));
}

test "effectiveRootSpecs: default rlm keeps subagent; --old and --lean do not drop it" {
    const schema = @import("schema.zig");
    const root = @import("main.zig");
    const learn_store = @import("learn_store.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const saved = available;
    const saved_lean = no_local_tools.lean;
    const saved_local = no_local_tools.enabled;
    const saved_clock = root.g_clock_sleep;
    const saved_learn = learn_store.active_agent_loaded;
    defer {
        available = saved;
        no_local_tools.lean = saved_lean;
        no_local_tools.enabled = saved_local;
        root.g_clock_sleep = saved_clock;
        learn_store.active_agent_loaded = saved_learn;
        sync();
    }
    no_local_tools.enabled = false;
    root.g_clock_sleep = false;
    learn_store.active_agent_loaded = true;

    available = true;
    no_local_tools.lean = false;
    sync();
    const def = try schema.effectiveRootSpecs(arena);
    try std.testing.expect(catalogHas(def, "subagent"));
    try std.testing.expect(catalogHas(def, "workflow"));
    try std.testing.expect(catalogHas(def, tool_name));
    try std.testing.expect(def.len > 2);

    available = false;
    sync();
    const old = try schema.effectiveRootSpecs(arena);
    try std.testing.expect(catalogHas(old, "subagent"));
    try std.testing.expect(catalogHas(old, "workflow"));
    try std.testing.expect(!catalogHas(old, tool_name));

    available = true;
    no_local_tools.lean = true;
    sync();
    const lean_on = try schema.effectiveRootSpecs(arena);
    try std.testing.expect(catalogHas(lean_on, "subagent"));
    try std.testing.expect(catalogHas(lean_on, tool_name));
    try std.testing.expect(!catalogHas(lean_on, "workflow"));
    try std.testing.expect(no_local_tools.leanKeeps("subagent"));
    try std.testing.expect(!no_local_tools.leanKeeps(tool_name));
}

test "runScript empty subagent() reaches execSubagent; persist binds do not break that" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dummy_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer dummy_client.deinit();
    const saved = available;
    defer {
        available = saved;
        resetLive(gpa, io);
    }
    available = true;
    const ctx = testCtx(gpa, io, &dummy_client);
    const first = try runScript(ctx, "prev = sleep_ms(1)");
    defer gpa.free(first.text);
    try std.testing.expect(!first.is_error);
    const miss = try runScript(ctx, "h = subagent()");
    defer gpa.free(miss.text);
    try std.testing.expect(miss.is_error);
    try std.testing.expect(std.mem.indexOf(u8, miss.text, "missing required") != null);
    try std.testing.expect(std.mem.indexOf(u8, miss.text, "prompt") != null);
    const reuse = try runScript(ctx, "print(prev)");
    defer gpa.free(reuse.text);
    try std.testing.expect(!reuse.is_error);
    try std.testing.expectEqualStrings("slept 1ms", reuse.text);
}

test "feedLive launches two independent subagent() calls before runScript claims" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dummy_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer dummy_client.deinit();
    const saved = available;
    defer {
        available = saved;
        resetLive(gpa, io);
    }
    available = true;
    const ctx = testCtx(gpa, io, &dummy_client);
    feedLive(ctx, "a = subagent()\n");
    feedLive(ctx, "b = subagent(\"\")\n");
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
