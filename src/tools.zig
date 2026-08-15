//! Tool execution context, lifecycle-hook dispatch, and the small tool
//! helpers. Split out of main.zig (600-line goal): `ToolOutput`/`ToolCtx`,
//! pre/post-tool hook dispatch (`hookPayload`/`hookGate`/
//! `runPostToolHooks`), the codedb-guard (issue #626: `codedbGuard`/
//! `extractSourceFilePath`/`referencesSourceFile`) and the metered-companion
//! router (`companionRoute`/`companionNativeFallback`), plus the small
//! request/response helpers (`failure`/`apiErrorMessage`/
//! `mentionsReasoningEffort`/`strField`/`intField`/`missingArg`/
//! `outsideCwd`/`blankText`/`rawFetch`) that `exec.zig`'s `execTool`/
//! `execToolInner` build on. Back-imports main (as `main_mod`, not `root` —
//! `apiErrorMessage`'s own param is named `root`) for `ToolCall`, `Provider`,
//! `harness_version`, and the codedb-guard globals/cache; the file-index
//! cache itself (`codedbFileIndexed`) stays in main.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const provider_mod = @import("provider.zig");
/// A normalized tool invocation — same shape for both providers.
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    input: Value,
};

/// A tool's outcome, arena-owned, ready to wire into either format.
pub const ExecResult = struct {
    text: []const u8,
    is_error: bool,
    cancelled: bool = false, // ended by user Esc, not by failing (#266)
    ms: i64 = 0, // wall-clock of the tool exec (external tools only; --timing)
};

pub const AnswerRequest = struct {
    text: []const u8,
    cancelled: bool,
    call_id: []const u8,
};

pub fn answerParseError(err: anyerror) []const u8 {
    return switch (err) {
        error.AnswerNotObject => "answer must be a JSON object",
        error.AnswerWrongType => "expected answer request for ask_user",
        error.AnswerCallIdMismatch => "answer call_id did not match active ask_user prompt",
        else => "invalid answer JSON for ask_user",
    };
}

pub fn parseAnswerRequest(parsed: Value, expected_call_id: []const u8) !AnswerRequest {
    if (parsed != .object) return error.AnswerNotObject;
    const rtype = if (parsed.object.get("type")) |v| (if (v == .string) v.string else "") else "";
    if (!std.mem.eql(u8, rtype, "answer")) return error.AnswerWrongType;
    const call_id = if (parsed.object.get("call_id")) |v| (if (v == .string) v.string else "") else "";
    if (call_id.len > 0 and expected_call_id.len > 0 and !std.mem.eql(u8, call_id, expected_call_id))
        return error.AnswerCallIdMismatch;
    const cancelled = if (parsed.object.get("cancelled")) |v| v == .bool and v.bool else false;
    const text = if (parsed.object.get("text")) |v| (if (v == .string) v.string else "") else "";
    return .{ .text = text, .cancelled = cancelled, .call_id = call_id };
}
const Provider = provider_mod.Provider;
const harness_version = main_mod.harness_version;

const mcp = @import("mcp.zig");
const hooks = @import("hooks.zig");
const trace = @import("trace.zig");
const Tracer = trace.Tracer;
const ToolSink = trace.ToolSink;
const approvals_mod = @import("approvals.zig");
const Approvals = approvals_mod.Approvals;
const skills = @import("skills.zig");
const run_budget_mod = @import("run_budget.zig");
pub const json_args = @import("json_args.zig");

pub const ToolOutput = struct {
    text: []u8 = &.{}, // gpa-owned
    is_error: bool = false,
    cancelled: bool = false, // ended by user Esc, not by failing (#266)
    ms: i64 = 0, // set by execTool
};

// `/rewind`'s pre-write file history lives in snapshots.zig (this file is at
// the 600-line cap); re-exported so `tools.Snapshots` keeps resolving for
// main.zig/agent.zig/exec.zig — and so `Rewound`, which `restore()` now
// returns, reaches its callers by that one route rather than a second import.
const snapshots_mod = @import("snapshots.zig");
pub const beforeFromRead = snapshots_mod.beforeFromRead;
pub const Snapshots = snapshots_mod.Snapshots;
pub const Rewound = snapshots_mod.Rewound;

/// Everything a tool executor may touch from a pool thread. All fields are
/// thread-safe (gpa, io, shared http client, mutex-guarded registry and
/// approvals) or read-only.
pub const ToolCtx = struct {
    gpa: Allocator,
    io: Io,
    client: *std.http.Client,
    provider: Provider,
    subagent_provider: ?Provider = null,
    subagent_cross_provider: bool = false,
    registry: ?*mcp.Registry,
    from_sub: bool,
    out: ?*Io.Writer = null, // live pane / stdout; foreground bash streams here (#472)
    has_eval: bool = false, // the root's --eval loop: escalation's strongest verifier
    approvals: ?*Approvals,
    tracer: ?*Tracer,
    run_budget: ?*run_budget_mod.RunBudget = null,
    depth: u8 = 0,
    snapshots: ?*Snapshots = null,
    tools_used: ?*ToolSink = null, // the calling agent's tool log (trajectory/process mining)
    loop_deadline_ms: ?i64 = null, // the running /loop's wall-clock deadline, copied from the spawning Agent: a child inherits the parent's ABSOLUTE deadline (minus an integration margin), never a slice of it
    agent_cwd: ?[]const u8 = null, // #276 P0-1: per-agent isolated worktree (absolute path); null = shared cwd. Set from Agent.agent_cwd, never a process-wide chdir — safe across parallel sibling subagents on the same pool.
};

/// Event JSON for a tool lifecycle hook: {"event","tool","input"[,
/// "is_error","output"]} — written to the hook's stdin. gpa-owned.
fn hookPayload(gpa: Allocator, event: []const u8, call: ToolCall, output: ?*const ToolOutput) ?[]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    const built = blk: {
        var s: std.json.Stringify = .{ .writer = &aw.writer };
        s.beginObject() catch break :blk false;
        s.objectField("event") catch break :blk false;
        s.write(event) catch break :blk false;
        s.objectField("tool") catch break :blk false;
        s.write(call.name) catch break :blk false;
        s.objectField("input") catch break :blk false;
        s.write(call.input) catch break :blk false;
        if (output) |o| {
            // Cap the echoed output and keep the cut on a UTF-8 boundary so
            // the JSON stays valid.
            var t = o.text[0..@min(o.text.len, 4096)];
            var strips: usize = 0;
            while (strips < 3 and t.len > 0 and !std.unicode.utf8ValidateSlice(t)) : (strips += 1) t = t[0 .. t.len - 1];
            if (!std.unicode.utf8ValidateSlice(t)) t = "";
            s.objectField("is_error") catch break :blk false;
            s.write(o.is_error) catch break :blk false;
            s.objectField("output") catch break :blk false;
            s.write(t) catch break :blk false;
        }
        s.endObject() catch break :blk false;
        break :blk true;
    };
    if (!built) {
        aw.deinit();
        return null;
    }
    return aw.toOwnedSlice() catch {
        aw.deinit();
        return null;
    };
}

/// pre_tool hooks: first matching hook that exits 2 blocks the call; its
/// stderr becomes the tool result the model sees. Timeouts and other exit
/// codes allow — a broken hook must never brick the loop.
pub fn hookGate(ctx: ToolCtx, call: ToolCall) ?ToolOutput {
    if (main_mod.g_hooks.pre_tool.len == 0) return null;
    const payload = hookPayload(ctx.gpa, "pre_tool", call, null) orelse return null;
    defer ctx.gpa.free(payload);
    for (main_mod.g_hooks.pre_tool) |h| {
        if (!h.matches(call.name)) continue;
        const res = hooks.runHookCmd(ctx.gpa, ctx.io, h.command, payload, h.timeout_ms);
        defer if (res.stderr.len > 0) ctx.gpa.free(res.stderr);
        if (res.code) |c| if (c == 2) {
            const text = hooks.denialText(ctx.gpa, h, res.stderr) orelse
                return .{ .text = &.{}, .is_error = true };
            return .{ .text = text, .is_error = true };
        };
    }
    return null;
}

/// post_tool hooks: best-effort, sequential (a formatter should finish
/// before the next tool runs), exit codes ignored.
pub fn runPostToolHooks(ctx: ToolCtx, call: ToolCall, out: ToolOutput) void {
    if (main_mod.g_hooks.post_tool.len == 0) return;
    const payload = hookPayload(ctx.gpa, "post_tool", call, &out) orelse return;
    defer ctx.gpa.free(payload);
    for (main_mod.g_hooks.post_tool) |h| {
        if (!h.matches(call.name)) continue;
        const res = hooks.runHookCmd(ctx.gpa, ctx.io, h.command, payload, h.timeout_ms);
        if (res.stderr.len > 0) ctx.gpa.free(res.stderr);
    }
}

/// Built-in pre_tool guard for issue #626. Blocks a bash command that scans or
/// reads a *concrete source file* (`grep`/`sed`/`cat`/… on a path ending in a
/// known code extension) and redirects the model to the codedb tool, whose
/// structural queries (symbol/callers/deps/outline/context) otherwise go
/// unused. Narrow on purpose: only known scan/read utilities, only a concrete
/// source path (globs like `*.zig` are left alone), only when `codedb` is on
/// PATH (else the model would be stuck between a blocked grep and no tool), and
/// never when GRAFF_NO_CODEDB_GUARD is set. A block returns is_error so the
/// model adapts — same contract as a pre_tool hook's exit 2.
pub fn codedbGuard(ctx: ToolCtx, call: ToolCall) ?ToolOutput {
    if (!main_mod.g_codedb_guard) return null;
    if (!std.mem.eql(u8, call.name, "bash")) return null;
    const cmd = strField(call.input, "command") orelse return null;

    // First word must be a code scan/read utility (basename, so /usr/bin/grep
    // counts; sudo/env prefixes are intentionally not unwrapped).
    const trimmed = std.mem.trim(u8, cmd, " \t");
    const word_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    const tool = std.fs.path.basename(trimmed[0..word_end]);
    const scanners = [_][]const u8{
        "grep", "egrep",  "fgrep", "rg",   "ripgrep", "ag", "ack",
        "sed",  "awk",    "cat",   "head", "tail",    "wc", "nl",
        "bat",  "batcat",
    };
    var is_scanner = false;
    for (scanners) |s| if (std.mem.eql(u8, s, tool)) {
        is_scanner = true;
    };
    if (!is_scanner) return null;

    // …aimed at a concrete source file (not a glob — codedb glob/tree cover that).
    const src_path = extractSourceFilePath(cmd) orelse return null;

    // Only redirect when codedb is actually installed (cache the PATH lookup).
    if (main_mod.g_codedb_present == null) main_mod.g_codedb_present = skills.binOnPath(ctx.io, "codedb");
    if (main_mod.g_codedb_present != true) return null;

    // Only redirect when codedb actually indexed this file. Large files
    // (e.g. a 13K-line main.zig) are silently skipped by codedb; blocking
    // bash grep on them traps the agent between a blocked grep and an empty
    // codedb result. Let bash through for un-indexed files (issue #54).
    if (!hooks.codedbFileIndexed(ctx.io, ctx.gpa, src_path)) return null;

    const msg = std.fmt.allocPrint(ctx.gpa, "blocked: this repo is codedb-indexed — don't shell out to `{s}` to read or search source. Use the codedb tool (indexed + structural): search <query> · symbol <name> [--body] · callers <name> · deps <path> · outline <path> · read <path> · context <task>. If you genuinely need raw bash here, set GRAFF_NO_CODEDB_GUARD=1.", .{tool}) catch return .{ .text = &.{}, .is_error = true };
    return .{ .text = msg, .is_error = true };
}

/// Extract the first concrete source file path from a bash command (after
/// the command word). Returns null for globs or non-source tokens. Used by
/// the codedb guard to check whether the target file is actually indexed
/// before redirecting bash to codedb — a file codedb skipped (too large)
/// must be allowed through bash, or the agent is trapped.
fn extractSourceFilePath(cmd: []const u8) ?[]const u8 {
    const exts = [_][]const u8{
        ".zig",  ".rs",  ".ts",  ".tsx", ".js",    ".jsx",   ".mjs",    ".cjs",
        ".py",   ".go",  ".c",   ".h",   ".cc",    ".cpp",   ".hpp",    ".cxx",
        ".java", ".kt",  ".rb",  ".php", ".swift", ".scala", ".cs",     ".lua",
        ".ex",   ".exs", ".erl", ".clj", ".dart",  ".vue",   ".svelte",
    };
    var it = std.mem.tokenizeAny(u8, cmd, " \t\n");
    var first = true;
    while (it.next()) |raw| {
        if (first) {
            first = false;
            continue; // skip the command word itself
        }
        const tok = std.mem.trim(u8, raw, "'\"`()");
        if (std.mem.indexOfAny(u8, tok, "*?") != null) continue; // glob, not a path
        for (exts) |e| if (std.mem.endsWith(u8, tok, e)) return tok;
    }
    return null;
}

/// True when `cmd` names a concrete source file (delegates to
/// extractSourceFilePath). Kept for the /hooks display and tests.
fn referencesSourceFile(cmd: []const u8) bool {
    return extractSourceFilePath(cmd) != null;
}

/// Built-in pre_tool router for the metered companion — the tool-layer twin of
/// providerFor()'s model routing (prefer the configured target, fall back to a
/// default). codedb-pro's tools (mcp__codedbpro__*) are only advertised while it
/// is connected; if the model calls one when the companion is gone (disconnected
/// mid-session, or a stale tool name carried over from a prior turn), don't hand
/// back a bare "unknown tool" — redirect to the native equivalent, which is
/// always registered. Returns null (let the call run) when the companion IS
/// connected, or when this isn't a companion tool at all.
pub fn companionRoute(ctx: ToolCtx, call: ToolCall) ?ToolOutput {
    const bare = skills.companionToolName(call.name) orelse return null;
    if (ctx.registry) |reg| {
        for (skills.companion_servers) |c| if (skills.mcpServerConnected(reg.tools, c.server)) return null;
    }
    const native = companionNativeFallback(bare);
    const msg = std.fmt.allocPrint(ctx.gpa, "the codedb-pro companion isn't connected this session, so {s} can't run — it was only an accelerator. Use the native {s} instead (always available).", .{ call.name, native }) catch return .{ .text = &.{}, .is_error = true };
    return .{ .text = msg, .is_error = true };
}

/// Map a companion tool (bare name, sans the mcp__<server>__ prefix) to the
/// native tool that does the same job — the fallback companionRoute steers to.
fn companionNativeFallback(bare: []const u8) []const u8 {
    if (std.mem.eql(u8, bare, "read")) return "read_file tool";
    if (std.mem.eql(u8, bare, "search") or std.mem.eql(u8, bare, "faster_search") or std.mem.eql(u8, bare, "meta_search"))
        return "codedb tool (search/symbol/callers/outline), or bash grep";
    if (std.mem.eql(u8, bare, "edit") or std.mem.eql(u8, bare, "patch") or std.mem.eql(u8, bare, "replace"))
        return "edit_file tool";
    if (std.mem.eql(u8, bare, "create")) return "write_file tool";
    if (std.mem.eql(u8, bare, "diff")) return "bash `git diff`";
    if (std.mem.eql(u8, bare, "lint")) return "bash to run the linter directly";
    return "native read_file/edit_file/codedb/bash tools";
}

pub fn failure(gpa: Allocator, err: anyerror) ToolOutput {
    // #122/#253: a bare error name is useless advice for an fd-limit hit — say
    // what it means and what helps. ulimit cannot fix SYSTEM-wide exhaustion.
    const text = (switch (err) {
        error.ProcessFdQuotaExceeded => gpa.dupe(u8, "error: ProcessFdQuotaExceeded — graff hit its open-file limit, usually from many parallel tools/subagents/MCP servers in one turn. Retry the failed calls sequentially (less parallel fan-out); if it recurs, raise the limit (`ulimit -n 4096`) before starting graff."),
        error.SystemFdQuotaExceeded => gpa.dupe(u8, "error: SystemFdQuotaExceeded — the SYSTEM-wide open-file table is full, so `ulimit` will not help. Wait for other processes to release files (or close some applications), then retry sequentially."),
        else => std.fmt.allocPrint(gpa, "error: {t}", .{err}),
    }) catch return .{ .is_error = true };
    return .{ .text = text, .is_error = true };
}

/// Pull a human-readable message from an OpenAI-style error envelope, handling
/// both `{"error":{"message":...}}` (OpenAI/Anthropic) and `{"error":"...","code":...}`
/// where `error` is a bare string (the codegraff gateway's shape, e.g. grok-build
/// rejecting an unsupported parameter). Returns null when there is no error field
/// (or it is explicitly null), so a normal response is never mistaken for an error.
pub fn apiErrorMessage(root: std.json.ObjectMap) ?[]const u8 {
    const e = root.get("error") orelse return null;
    return switch (e) {
        .null => null,
        .string => e.string,
        .object => if (e.object.get("message")) |m| (if (m == .string) m.string else "unknown error") else "unknown error",
        else => "unknown error",
    };
}

/// Does an API error message complain about the reasoning-effort hint? Gateways
/// word it differently: OpenAI says "reasoning_effort", the codegraff gateway
/// (e.g. for grok-build) says "reasoningEffort". Either means: drop it and retry.
pub fn mentionsReasoningEffort(msg: []const u8) bool {
    return std.mem.indexOf(u8, msg, "reasoning_effort") != null or
        std.mem.indexOf(u8, msg, "reasoningEffort") != null;
}

/// A required string argument, or null if absent / wrong type. Guards
/// against malformed model output panicking the process (DoS).
pub fn strField(input: Value, name: []const u8) ?[]const u8 {
    if (input != .object) return null;
    const v = input.object.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

/// An integer argument, or null if absent / wrong type (same DoS guard).
pub fn intField(input: Value, name: []const u8) ?i64 {
    if (input != .object) return null;
    const v = input.object.get(name) orelse return null;
    return if (v == .integer) v.integer else null;
}

pub fn missingArg(gpa: Allocator, name: []const u8) !ToolOutput {
    return .{ .text = try std.fmt.allocPrint(gpa, "missing or non-string argument: {s}", .{name}), .is_error = true };
}

pub fn outsideCwd(gpa: Allocator, path: []const u8) !ToolOutput {
    return .{
        .text = try std.fmt.allocPrint(gpa, "path '{s}' is outside the working directory — native file tools are confined to the cwd subtree (no absolute paths, no '..'). If the user explicitly requested that external target, the root agent may continue with permission-gated bash using quoted paths after checking git status; those edits are not covered by /rewind. A relaunch is not required. Subagents remain confined.", .{path}),
        .is_error = true,
    };
}

/// How much of a command's output graff will hold at all. #440 demoted this
/// from a CONTEXT cap to a capture ceiling: the model no longer receives a
/// tool result in full (tool_handle.zig turns anything past its threshold into
/// a preview + a durable handle), so the only thing this number still bounds is
/// harness memory and how much of a chatty command the handle can preserve. At
/// the old 128 KiB the handle silently lied for exactly the case #440 measured
/// — a 168 KB log, of which a quarter was already destroyed before anything
/// could be written down.
pub const bash_stdout_cap = 1024 * 1024;
pub const bash_stderr_cap = 32 * 1024;
pub const webfetch_cap = 256 * 1024;
/// Capture ceiling for the `codedb read --compact` fallback (#66). This used to
/// double as a context cap that truncated any codedb result past 64 KiB; #440
/// removed that half — the handle preserves those bytes instead of discarding
/// them, and bounds the context on its own.
pub const codedb_result_cap = 64 * 1024;

/// True when the text carries no real content (empty, or whitespace only) —
/// kuri-fetch "succeeds" on JS-rendered SPAs but emits pages of blank lines.
pub fn blankText(text: []const u8) bool {
    var meaningful: usize = 0;
    for (text) |c| switch (c) {
        ' ', '\t', '\r', '\n' => {},
        else => meaningful += 1,
    };
    return meaningful < 16;
}

/// Fallback webfetch path: a plain GET via the harness's shared HTTP client,
/// raw body (HTML/text), capped at webfetch_cap. Load-bearing even when kuri
/// is installed — it covers the servers kuri's TLS stack rejects and the
/// SPAs it renders blank.
pub fn rawFetch(gpa: Allocator, client: *std.http.Client, url: []const u8) ToolOutput {
    const buf = gpa.alloc(u8, webfetch_cap) catch return .{ .is_error = true };
    defer gpa.free(buf);
    var w: Io.Writer = .fixed(buf);
    var truncated = false;
    var status: ?std.http.Status = null;
    if (client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &w,
        .headers = .{ .user_agent = .{ .override = "simple-harness/" ++ harness_version } },
    })) |res| {
        status = res.status;
    } else |err| switch (err) {
        error.WriteFailed => truncated = true, // body hit the cap: keep what we have
        else => return failure(gpa, err),
    }
    const body = w.buffered();
    if (status) |st| {
        const code = @intFromEnum(st);
        if (code < 200 or code >= 300) return .{
            .text = std.fmt.allocPrint(gpa, "HTTP {d} {s}", .{ code, st.phrase() orelse "" }) catch return .{ .is_error = true },
            .is_error = true,
        };
    }
    if (std.mem.indexOfScalar(u8, body[0..@min(body.len, 4096)], 0) != null) return .{
        .text = std.fmt.allocPrint(gpa, "{s} returned binary content ({d} bytes) — webfetch only handles text; use bash (e.g. curl -o) to download it", .{ url, body.len }) catch return .{ .is_error = true },
        .is_error = true,
    };
    if (blankText(body)) return .{ .text = gpa.dupe(u8, "(empty response body)") catch return .{ .is_error = true } };
    var aw: Io.Writer.Allocating = .init(gpa);
    aw.writer.writeAll(body) catch {
        aw.deinit();
        return .{ .is_error = true };
    };
    if (truncated) aw.writer.print("\n[truncated at {d} KB]", .{webfetch_cap / 1024}) catch {};
    return .{ .text = aw.toOwnedSlice() catch return .{ .is_error = true } };
}

test "codedbGuard.referencesSourceFile: concrete code paths, not globs/logs/configs" {
    // The exact #626 screenshot commands — every one reads a source file.
    try std.testing.expect(referencesSourceFile("grep -n \"description\" src/mcp.zig"));
    try std.testing.expect(referencesSourceFile("wc -l src/mcp.zig"));
    try std.testing.expect(referencesSourceFile("sed -n '600,700p' src/mcp.zig"));
    try std.testing.expect(referencesSourceFile("cat gui/src/hooks/types/copy.ts"));
    // Globs are discovery, not a read — codedb glob/tree cover those separately.
    try std.testing.expect(!referencesSourceFile("find . -name '*.zig'"));
    try std.testing.expect(!referencesSourceFile("grep -r foo --include=*.rs ."));
    // No concrete source path → leave it alone (logs, docs, bare commands).
    try std.testing.expect(!referencesSourceFile("grep error /var/log/app.log"));
    try std.testing.expect(!referencesSourceFile("cat README.md"));
    try std.testing.expect(!referencesSourceFile("ls -la"));
    // The command word itself ending in a code ext must not self-trigger.
    try std.testing.expect(!referencesSourceFile("./build.zig"));
}

test "blankText: webfetch empty-output heuristic" {
    try std.testing.expect(blankText(""));
    try std.testing.expect(blankText("   \n\n\t\r\n  \n")); // SPA: pages of blank lines
    try std.testing.expect(blankText("ok\n")); // a couple of stray chars is still no content
    try std.testing.expect(!blankText("# Example Domain\n\nThis domain is for use..."));
}

test "companionNativeFallback: every companion tool maps to a native equivalent" {
    try std.testing.expectEqualStrings("read_file tool", companionNativeFallback("read"));
    try std.testing.expectEqualStrings("edit_file tool", companionNativeFallback("patch"));
    try std.testing.expectEqualStrings("edit_file tool", companionNativeFallback("edit"));
    try std.testing.expectEqualStrings("write_file tool", companionNativeFallback("create"));
    try std.testing.expect(std.mem.indexOf(u8, companionNativeFallback("faster_search"), "codedb") != null);
    // an unknown/new companion tool still gets a sane native pointer
    try std.testing.expect(std.mem.indexOf(u8, companionNativeFallback("memo"), "native") != null);
}

test "strField/intField: typed JSON field extraction, null on wrong type or non-object" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = std.json.parseFromSliceLeaky(Value, a, "{\"s\":\"hi\",\"n\":42,\"b\":true}", .{}) catch unreachable;
    try std.testing.expectEqualStrings("hi", strField(v, "s").?);
    try std.testing.expect(strField(v, "n") == null); // present but not a string
    try std.testing.expect(strField(v, "missing") == null);
    try std.testing.expect(strField(Value{ .null = {} }, "s") == null); // non-object input
    try std.testing.expectEqual(@as(i64, 42), intField(v, "n").?);
    try std.testing.expect(intField(v, "s") == null); // present but not an integer
    try std.testing.expect(intField(v, "missing") == null);
}

test "missingArg: builds an is_error result naming the argument" {
    const o = try missingArg(std.testing.allocator, "path");
    defer std.testing.allocator.free(o.text);
    try std.testing.expect(o.is_error);
    try std.testing.expect(std.mem.indexOf(u8, o.text, "path") != null);
}

test "outsideCwd: points an explicitly authorized root agent at the safe fallback" {
    const o = try outsideCwd(std.testing.allocator, "../zigrepper");
    defer std.testing.allocator.free(o.text);
    try std.testing.expect(o.is_error);
    try std.testing.expect(std.mem.indexOf(u8, o.text, "permission-gated bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, o.text, "quoted paths") != null);
    try std.testing.expect(std.mem.indexOf(u8, o.text, "not covered by /rewind") != null);
    try std.testing.expect(std.mem.indexOf(u8, o.text, "relaunch is not required") != null);
    try std.testing.expect(std.mem.indexOf(u8, o.text, "Subagents remain confined") != null);
}

test "apiErrorMessage: object-message, bare-string, and absent envelopes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const mk = struct {
        fn p(al: Allocator, s: []const u8) Value {
            return std.json.parseFromSliceLeaky(Value, al, s, .{}) catch unreachable;
        }
    }.p;
    try std.testing.expectEqualStrings("bad thing", apiErrorMessage(mk(a, "{\"error\":{\"message\":\"bad thing\"}}").object).?);
    // codegraff gateway shape: error is a bare string (the grok-build case)
    try std.testing.expectEqualStrings(
        "Model grok-build-0.1 does not support parameter reasoningEffort.",
        apiErrorMessage(mk(a, "{\"code\":\"invalid-argument\",\"error\":\"Model grok-build-0.1 does not support parameter reasoningEffort.\"}").object).?,
    );
    try std.testing.expect(apiErrorMessage(mk(a, "{\"choices\":[]}").object) == null);
    try std.testing.expect(apiErrorMessage(mk(a, "{\"error\":null}").object) == null);
}

test "mentionsReasoningEffort: matches snake_case and camelCase wording" {
    try std.testing.expect(mentionsReasoningEffort("Unknown parameter: reasoning_effort"));
    try std.testing.expect(mentionsReasoningEffort("Model X does not support parameter reasoningEffort."));
    try std.testing.expect(!mentionsReasoningEffort("some other error"));
}

test "parseAnswerRequest: preserves multiline text and optional call id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try std.json.parseFromSliceLeaky(Value, a,
        \\{"type":"answer","text":"line 1\nline 2","cancelled":false,"call_id":"call-1"}
    , .{});
    const answer = try parseAnswerRequest(v, "call-1");
    try std.testing.expectEqualStrings("line 1\nline 2", answer.text);
    try std.testing.expectEqualStrings("call-1", answer.call_id);
    try std.testing.expect(!answer.cancelled);
}

test "parseAnswerRequest: explicit cancel and mismatched call id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cancelled = try std.json.parseFromSliceLeaky(Value, a,
        \\{"type":"answer","cancelled":true,"call_id":"call-1"}
    , .{});
    const answer = try parseAnswerRequest(cancelled, "call-1");
    try std.testing.expect(answer.cancelled);
    try std.testing.expectEqualStrings("", answer.text);

    const mismatch = try std.json.parseFromSliceLeaky(Value, a,
        \\{"type":"answer","text":"nope","call_id":"call-2"}
    , .{});
    try std.testing.expectError(error.AnswerCallIdMismatch, parseAnswerRequest(mismatch, "call-1"));
}
