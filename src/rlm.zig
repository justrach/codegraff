//! Opt-in `rlm` tool: one programmatic-tool-calling REPL per call.
//!
//! Off unless `--rlm` / `GRAFF_RLM=1`. The default catalog stays byte-stable
//! (ADR 0022). Host functions: `read_file`, `codedb` (real graff tools),
//! `sleep_ms` (overlap proof), `llm_query` (RLM tools-off sub-LM), `print`
//! (answer). Closed literal calls launch as the `code` argument streams
//! (spec-ptc) and again at exec for anything the stream missed.

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
pub const tool_desc = "Programmatic tool calling (RLM + sPTC). Run a short Python-like script whose functions ARE this session's tools. Independent read_file/codedb/bash/webfetch/sleep_ms/llm_query calls with literal arguments start in parallel as the script streams (speculated), then print() is the answer. Semicolons or newlines separate statements. llm_query(prompt) is a tools-off sub-LM call. Example: a = read_file(\"src/main.zig\"); b = codedb(\"status\"); print(a, b). No imports, no control flow — assignments and calls only. Prefer this over N separate tool calls when the work does not depend on itself.";
pub const tool_schema =
    \\{"type": "object", "properties": {"code": {"type": "string", "description": "Python-like script: name = read_file(\"path\") / codedb(\"command\") / bash(\"cmd\") / sleep_ms(ms) / llm_query(\"prompt\"); print(...) is the result. Semicolons or newlines separate statements."}}, "required": ["code"]}
;

/// Process-global: `--rlm` / GRAFF_RLM=1. Never flipped mid-session.
/// Keep in sync with rlm_spec.available (`sync`) so the SSE path can see it
/// without importing this file (exec.zig would cycle through Agent).
pub var available: bool = false;

pub fn sync() void {
    rlm_spec.available = available;
    rlm_spec.run_host = runHost;
}

pub fn resetLive(gpa: Allocator, io: Io) void {
    sync();
    rlm_spec.resetLive(gpa, io);
}

pub fn feedLive(ctx: ToolCtx, delta: []const u8) void {
    sync();
    rlm_spec.feedLive(ctx, delta);
}

/// Append `rlm` after the lean/no-local filters so `--rlm -p` still sees it.
/// The spec is folded behind `load_tool_schemas` (native_fold) until the
/// model loads or calls it — the prefix stays the lean catalog plus a name.
/// No-op when the flag is off or embedder mode stripped host tools.
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
    if (!available) return .{ .text = try ctx.gpa.dupe(u8, "rlm is off — pass --rlm (or GRAFF_RLM=1)"), .is_error = true };
    if (no_local_tools.enabled) return .{ .text = try ctx.gpa.dupe(u8, "rlm is a host tool and is disabled under --no-local-tools"), .is_error = true };
    const code = tools.strField(input, "code") orelse return tools.missingArg(ctx.gpa, "code");
    return runScript(ctx, code);
}

const Binding = struct { name: []const u8, text: []const u8 };

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
    for (binds) |b| if (std.mem.eql(u8, b.name, t)) return b.text;
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

test "maybeAppend is a no-op until --rlm, and refuses to double-append" {
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
    defer available = saved;
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
    defer available = saved;
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
    defer available = saved;
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
