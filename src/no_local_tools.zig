//! #330 embedder mode: the hard `--no-local-tools` gate.
//!
//! An embedder runs graff as the reasoning loop on a TRUSTED host and reaches
//! the sandbox only through tool calls, so the built-in tools that touch this
//! machine have to be gone rather than merely un-approved. A permission rule is
//! something a prompt-injected model can argue its way past; a tool that does
//! not exist is not. The coding tools come back in over MCP - the embedder
//! stands up a sandbox-proxy server and points graff at it - and this gate
//! never touches MCP-sourced tools, which is the whole point.
//!
//! Two enforcement layers, both required, because either alone is a promise
//! rather than a guarantee:
//!   1. the gated tools are never advertised - schema.zig drops them from the
//!      root catalog (effectiveRootSpecs) and from the comptime subagent
//!      catalogs, so no provider is told they exist;
//!   2. dispatch refuses - exec.zig's guard chain answers a hallucinated call
//!      with a tool error naming the flag, before anything runs.
//!
//! The switch is process-global on purpose. Subagents, workflow workers,
//! retries and judges all run in-process through the same exec path, so one
//! flag covers the whole agent tree and there is no per-agent state anyone can
//! forget to inherit.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Set once at startup by `--no-local-tools` (args.zig) or
/// `GRAFF_NO_LOCAL_TOOLS=1` (session_run.zig). Never flipped mid-session.
pub var enabled: bool = false;

/// The built-in tools that reach this host: shell execution plus its two job
/// controls, the three file tools, and codedb - which reads the host checkout
/// through its own index. `webfetch` is deliberately absent: it is plain host
/// HTTP with no sandbox to escape. So are the orchestration/meta tools, and
/// everything MCP-sourced (an `mcp__*` name never matches here).
pub const gated_tools = [_][]const u8{
    "bash",
    "bash_output",
    "bash_kill",
    "read_file",
    "edit_file",
    "write_file",
    "codedb",
};

/// A name test only, independent of whether the gate is on, so the comptime
/// catalog filter and the runtime refusal can share one list.
pub fn isLocalTool(name: []const u8) bool {
    for (gated_tools) |tool| {
        if (std.mem.eql(u8, name, tool)) return true;
    }
    return false;
}

/// Layer 2's predicate: this call must be refused before anything runs.
pub fn blocks(name: []const u8) bool {
    return enabled and isLocalTool(name);
}

/// Refusal text. Names the flag so the model stops retrying the same call, and
/// points it at what does work in this deployment.
pub const refusal_text = "--no-local-tools is set for this process: the built-in bash, bash_output, bash_kill, read_file, edit_file, write_file and codedb tools are hard-disabled and cannot be re-enabled by asking. Run commands and touch files through the sandbox tools the connected MCP server provides instead; webfetch still works.";

/// `GRAFF_NO_LOCAL_TOOLS` - affirmative-only, like GRAFF_CLOCK_SLEEP, and OR'd
/// onto the CLI flag by the caller so a stray value can never turn
/// `--no-local-tools` back off.
pub fn envEnables(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "on") or
        std.ascii.eqlIgnoreCase(value, "yes");
}

/// Layer 1, comptime half: the subagent catalogs are comptime constants, so
/// their gated twin is computed once at compile time and merely selected at
/// runtime.
pub fn remoteSpecs(comptime Spec: type, comptime specs: []const Spec) []const Spec {
    comptime {
        var out: []const Spec = &.{};
        for (specs) |spec| {
            if (isLocalTool(spec.name)) continue;
            out = out ++ [_]Spec{spec};
        }
        return out;
    }
}

/// Layer 1, runtime half: the root catalog is picked at runtime (clock_sleep,
/// learning), so the gated copy is built in the caller's arena. Returns the
/// input untouched when the gate is off - no allocation on the normal path.
pub fn filterRootSpecs(comptime Spec: type, arena: Allocator, specs: []const Spec) ![]const Spec {
    if (!enabled) return specs;
    const buf = try arena.alloc(Spec, specs.len);
    var kept: usize = 0;
    for (specs) |spec| {
        if (isLocalTool(spec.name)) continue;
        buf[kept] = spec;
        kept += 1;
    }
    return buf[0..kept];
}

test "#330: the gated set is exactly the host-touching built-ins; webfetch, meta and MCP names are not gated" {
    const saved = enabled;
    defer enabled = saved;

    for (gated_tools) |tool| try std.testing.expect(isLocalTool(tool));
    try std.testing.expectEqual(@as(usize, 7), gated_tools.len);
    for ([_][]const u8{ "webfetch", "skill", "subagent", "workflow", "todo_write", "eval", "mcp__sandbox__exec", "mcp__sandbox__bash" }) |tool|
        try std.testing.expect(!isLocalTool(tool));

    // blocks() is the gate, not the list: nothing is refused until it is on.
    enabled = false;
    for (gated_tools) |tool| try std.testing.expect(!blocks(tool));
    enabled = true;
    for (gated_tools) |tool| try std.testing.expect(blocks(tool));
    try std.testing.expect(!blocks("webfetch"));
    try std.testing.expect(!blocks("mcp__sandbox__bash"));
}

test "#330: GRAFF_NO_LOCAL_TOOLS is affirmative-only" {
    for ([_][]const u8{ "1", "true", "TRUE", "on", "Yes" }) |value| try std.testing.expect(envEnables(value));
    for ([_][]const u8{ "0", "off", "false", "no", "", "maybe" }) |value| try std.testing.expect(!envEnables(value));
}

test "#330: filterRootSpecs drops only the gated names, and does not allocate when the gate is off" {
    const Spec = struct { name: []const u8 };
    const specs = [_]Spec{
        .{ .name = "bash" },
        .{ .name = "webfetch" },
        .{ .name = "read_file" },
        .{ .name = "subagent" },
        .{ .name = "codedb" },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const saved = enabled;
    defer enabled = saved;

    enabled = false;
    try std.testing.expectEqual(specs.len, (try filterRootSpecs(Spec, arena, &specs)).len);
    try std.testing.expectEqual(@as(usize, 0), arena_state.queryCapacity());

    enabled = true;
    const gated = try filterRootSpecs(Spec, arena, &specs);
    try std.testing.expectEqual(@as(usize, 2), gated.len);
    try std.testing.expectEqualStrings("webfetch", gated[0].name);
    try std.testing.expectEqualStrings("subagent", gated[1].name);
}

test "#330: neither catalog advertises a local tool under the gate, and webfetch survives in both" {
    const schema = @import("schema.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const saved = enabled;
    defer enabled = saved;

    // Root catalog (runtime-assembled, and the one MCP tools are appended to).
    enabled = false;
    const open = try schema.effectiveRootSpecs(arena);
    var open_local: usize = 0;
    for (open) |spec| {
        if (isLocalTool(spec.name)) open_local += 1;
    }
    try std.testing.expectEqual(gated_tools.len, open_local);

    enabled = true;
    const gated = try schema.effectiveRootSpecs(arena);
    var kept_webfetch = false;
    var kept_subagent = false;
    for (gated) |spec| {
        try std.testing.expect(!isLocalTool(spec.name));
        if (std.mem.eql(u8, spec.name, "webfetch")) kept_webfetch = true;
        if (std.mem.eql(u8, spec.name, "subagent")) kept_subagent = true;
    }
    try std.testing.expectEqual(open.len - gated_tools.len, gated.len);
    try std.testing.expect(kept_webfetch); // pure host HTTP: no sandbox to escape
    try std.testing.expect(kept_subagent); // orchestration stays; the child inherits the gate

    // Subagent catalogs (comptime twins), in all three wire formats.
    for ([_][]const u8{
        schema.tools_anthropic_sub_remote,
        schema.tools_openai_sub_remote,
        schema.tools_responses_sub_remote,
    }) |catalog| {
        inline for (gated_tools) |tool|
            try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"" ++ tool ++ "\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"webfetch\"") != null);
    }
    // …and the ungated twins still carry them, so the filter is what changed.
    try std.testing.expect(std.mem.indexOf(u8, schema.tools_anthropic_sub, "\"name\":\"bash\"") != null);
}

test "#330: dispatch refuses a hallucinated bash call for the root AND for a subagent" {
    const exec = @import("exec.zig");
    const tools = @import("tools.zig");
    const gpa = std.testing.allocator;

    const saved = enabled;
    defer enabled = saved;

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"command\":\"echo gate-escaped\"}", .{});
    defer parsed.deinit();

    var client: std.http.Client = undefined;
    var ctx: tools.ToolCtx = .{
        .gpa = gpa,
        .io = std.testing.io,
        .client = &client,
        .provider = undefined,
        .registry = null,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
    };

    enabled = true;
    // from_sub=true is the child path: a subagent's tool calls run through this
    // very dispatch, so the process-global gate reaches them with no plumbing.
    for ([_]bool{ false, true }) |from_sub| {
        ctx.from_sub = from_sub;
        const out = exec.execTool(ctx, .{ .id = "call_1", .name = "bash", .input = parsed.value });
        defer gpa.free(out.text);
        try std.testing.expect(out.is_error);
        try std.testing.expect(std.mem.indexOf(u8, out.text, "--no-local-tools") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.text, "gate-escaped") == null); // never ran
    }
}
