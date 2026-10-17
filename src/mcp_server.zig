//! Local stdio MCP task adapter. Each call owns a bounded, fresh CLI child.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const app = @import("mcp_server_app.zig");
const modern = @import("mcp_server_modern.zig");
const runner = @import("process_runner.zig");

pub const Task = struct {
    prompt: []const u8,
    /// Caller-supplied background for the task, appended to the child's system
    /// prompt. Over `inline_context_max` it is summarized first (ADR 0253).
    context: ?[]const u8 = null,
    timeout_seconds: u64 = 120,
    max_model_calls: u64 = 8,
};
pub const Result = struct {
    text: []const u8,
    isError: bool = false,
    timed_out: bool = false,
    cancelled: bool = false,
    output_truncated: bool = false,
    context_chars: u64 = 0,
    context_summarized: bool = false,
    context_used_chars: u64 = 0,
    /// Set only when the server summarized a handover before the task ran.
    preprocess: ?Preprocess = null,
};
pub const Execute = *const fn (?*anyopaque, Allocator, Task) anyerror!Result;

pub const Server = struct {
    initialized: bool = false,
    ready: bool = false,
    apps: bool = false,
    execute: Execute,
    context: ?*anyopaque = null,

    pub fn handle(self: *Server, a: Allocator, out: *Io.Writer, line: []const u8) !void {
        const request = std.json.parseFromSliceLeaky(Value, a, line, .{}) catch
            return failure(out, .null, -32700, "Parse error");
        if (request != .object) return failure(out, .null, -32600, "Invalid Request");
        const id = request.object.get("id") orelse Value.null;
        if (id != .null and id != .string and id != .integer)
            return failure(out, .null, -32600, "Invalid request id");
        const version = string(request, "jsonrpc") orelse "";
        const method = string(request, "method") orelse "";
        if (!std.mem.eql(u8, version, "2.0") or method.len == 0)
            return failure(out, id, -32600, "Invalid Request");
        if (!request.object.contains("id")) {
            if (self.initialized and std.mem.eql(u8, method, "notifications/initialized")) self.ready = true;
            return;
        }
        const params = request.object.get("params") orelse Value.null;
        // 2026-07-28: the version rides each request's _meta; no handshake.
        const era: ?[]const u8 = modern.requestedVersion(params);
        if (era) |requested| if (!modern.isSupported(requested)) return modern.unsupported(out, id, requested);
        const apps = if (era != null) app.supported(try modern.capabilityParams(a, params)) else self.apps;
        const answer: Answer = .{ .a = a, .out = out, .id = id, .modern = era != null };
        if (std.mem.eql(u8, method, "ping")) return answer.send(struct {}{}, false);
        if (std.mem.eql(u8, method, "server/discover")) {
            if (era == null) return failure(out, id, -32601, "Method not found");
            return answer.send(.{
                .supportedVersions = modern.supported_versions,
                .capabilities = capabilities,
                .serverInfo = server_info,
                .instructions = instructions,
            }, true);
        }
        if (era == null and std.mem.eql(u8, method, "initialize")) {
            if (self.initialized) return failure(out, id, -32600, "Already initialized");
            const requested = string(params, "protocolVersion") orelse
                return failure(out, id, -32602, "protocolVersion is required");
            const protocol = for (modern.supported_versions[1..]) |v| {
                if (std.mem.eql(u8, requested, v)) break v;
            } else modern.supported_versions[1];
            self.apps = app.supported(params);
            self.initialized = true;
            return reply(out, id, .{
                .protocolVersion = protocol,
                .capabilities = capabilities,
                .serverInfo = server_info,
                .instructions = instructions,
            });
        }
        if (era == null and !self.ready) return failure(out, id, -32000, "Initialize the server first");
        if (std.mem.eql(u8, method, "tools/list")) {
            const catalog = try app.catalog(a, tool_catalog, apps);
            return answer.send(catalog, true);
        }
        if (std.mem.eql(u8, method, "resources/list")) return answer.send(.{ .resources = .{app.resource} }, true);
        if (std.mem.eql(u8, method, "resources/templates/list")) return answer.send(.{ .resourceTemplates = [0]struct {}{} }, true);
        if (std.mem.eql(u8, method, "resources/read")) {
            const uri = string(params, "uri") orelse return failure(out, id, -32602, "Resource URI is required");
            if (!std.mem.eql(u8, uri, app.uri)) return failure(out, id, -32002, "Resource not found");
            return answer.send(app.contents(), true);
        }
        if (!std.mem.eql(u8, method, "tools/call")) return failure(out, id, -32601, "Method not found");
        const name = string(params, "name") orelse return failure(out, id, -32602, "Tool name is required");
        if (!std.mem.eql(u8, name, "run_task")) return failure(out, id, -32602, "Unknown tool");
        const input = params.object.get("arguments") orelse Value.null;
        const task = parseTask(input) catch return failure(out, id, -32602, "Expected prompt (1-32768 bytes), context (1-32768 bytes), timeout_seconds (1-300), max_model_calls (1-32); no other arguments");
        const result = self.execute(self.context, a, task) catch |err| Result{
            .text = try std.fmt.allocPrint(a, "Task could not run: {s}", .{@errorName(err)}),
            .isError = true,
        };
        const data = .{
            .text = result.text,
            .status = if (result.timed_out) "timed_out" else if (result.cancelled) "cancelled" else if (result.isError) "failed" else "completed",
            .output_truncated = result.output_truncated,
            .timeout_seconds = task.timeout_seconds,
            .max_model_calls = task.max_model_calls,
            .context_chars = result.context_chars,
            .context_summarized = result.context_summarized,
            .context_used_chars = result.context_used_chars,
            .usage_reported = usage_reported,
            .usage_unavailable_reason = usage_unavailable_reason,
            // Preprocessing is reported separately from child execution: it is
            // a settled charge the engine ingested, counted once here and not
            // folded into the (unavailable) child total.
            .preprocess = blk: {
                const p = result.preprocess orelse Preprocess{};
                const reason = if (result.preprocess == null)
                    "no summarization was needed"
                else if (p.usage_complete) "" else preprocess_unavailable;
                break :blk .{
                    .cost_usd = p.cost_usd,
                    .usage_complete = p.usage_complete,
                    .input_tokens = p.input_tokens,
                    .output_tokens = p.output_tokens,
                    .unavailable_reason = reason,
                };
            },
        };
        // The same metadata in the namespaced slot, so a client that renders the
        // raw result never has to parse prose to learn what the child was given
        // (the `graff/…` / `codegraff/…` convention used elsewhere).
        return answer.send(.{ .content = .{.{ .type = "text", .text = result.text }}, .isError = result.isError, .structuredContent = data, ._meta = .{ .@"codegraff/runTask" = data } }, false);
    }
};

/// What a caller may rely on about per-task cost, stated rather than omitted.
/// The task child runs in print mode, which exposes no settled gateway charge,
/// and a charge is never derived from a list rate (`pricing_settled.zig`).
/// Reporting `false` here is the honest contract: account-wide gateway usage
/// stays authoritative when no per-task settlement exists (ADR 0253).
const usage_reported = false;
const usage_unavailable_reason = "per-task usage and charge are not reported: the task child runs in print mode, which exposes no settled gateway charge, and a charge is never derived from list rates. Account-wide gateway usage remains authoritative.";

const capabilities = .{ .tools = struct {}{}, .resources = struct {}{} };
const server_info = .{ .name = "codegraff", .title = "Codegraff", .version = @import("main.zig").harness_version };
const instructions = "Delegate a small, self-contained task with run_task. Tasks run serially in the server launch directory with fresh context; hand background over in context, which is summarized when it is long. Include scope and acceptance criteria; inspect the result and changes before integrating.";

/// One reply, in the requesting era's shape.
const Answer = struct {
    a: Allocator,
    out: *Io.Writer,
    id: Value,
    modern: bool,

    fn send(self: Answer, result: anytype, cacheable: bool) !void {
        if (!self.modern) return reply(self.out, self.id, result);
        return reply(self.out, self.id, try modern.envelope(self.a, result, cacheable));
    }
};

fn string(value: Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const v = value.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

pub fn parseTask(input: Value) !Task {
    const prompt = string(input, "prompt") orelse return error.InvalidArguments;
    if (std.mem.trim(u8, prompt, " \r\n\t").len == 0 or prompt.len > context_max_bytes or std.mem.indexOfScalar(u8, prompt, 0) != null) return error.InvalidArguments;
    var task: Task = .{ .prompt = prompt };
    var it = input.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "prompt")) continue;
        const v = entry.value_ptr.*;
        // `context` is the one string argument: background the caller wants the
        // child to have. It cannot carry configuration — only text the child
        // reads (ADR 0253).
        if (std.mem.eql(u8, key, "context")) {
            if (v != .string) return error.InvalidArguments;
            if (std.mem.trim(u8, v.string, " \r\n\t").len == 0 or v.string.len > context_max_bytes or std.mem.indexOfScalar(u8, v.string, 0) != null) return error.InvalidArguments;
            task.context = v.string;
            continue;
        }
        if (v != .integer or v.integer < 1) return error.InvalidArguments;
        if (std.mem.eql(u8, key, "timeout_seconds") and v.integer <= 300) {
            task.timeout_seconds = @intCast(v.integer);
        } else if (std.mem.eql(u8, key, "max_model_calls") and v.integer <= 32) {
            task.max_model_calls = @intCast(v.integer);
        } else return error.InvalidArguments;
    }
    return task;
}

fn reply(out: *Io.Writer, id: Value, result: anytype) !void {
    var json: std.json.Stringify = .{ .writer = out };
    try json.write(.{ .jsonrpc = "2.0", .id = id, .result = result });
    try out.writeByte('\n');
}
fn failure(out: *Io.Writer, id: Value, code: i32, message: []const u8) !void {
    var json: std.json.Stringify = .{ .writer = out };
    try json.write(.{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } });
    try out.writeByte('\n');
}

pub fn serve(gpa: Allocator, in: *Io.Reader, out: *Io.Writer, server: *Server) !void {
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    while (true) {
        const line = in.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                _ = in.discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) {
                    error.EndOfStream => return,
                    else => return discard_err,
                };
                try failure(out, .null, -32600, "Request exceeds 64 KiB");
                try out.flush();
                continue;
            },
            else => return err,
        } orelse return;
        try server.handle(scratch.allocator(), out, line);
        try out.flush();
        _ = scratch.reset(.retain_capacity);
    }
}

pub const Context = struct {
    io: Io,
    exe: []const u8,
    env: *const std.process.Environ.Map,
    model: ?[]const u8 = null,
    yolo: bool = false,
};

/// Caller-supplied background at or below this size rides the child's appended
/// system prompt verbatim; above it the server summarizes first, so a large
/// handover cannot crowd out the child's own task (ADR 0253).
const inline_context_max: usize = 8192;
const context_max_bytes: usize = 32768;
const summary_stdout_cap: usize = 16 * 1024;
const summarize_deadline_ms: u64 = 60_000;

/// Leave the bounded task time to stop its child and return partial output.
/// Other tools, discovery, and invalid task inputs keep the normal HTTP bound.
/// This is request-local: it never changes another server's client settings.
pub fn transportTimeoutSeconds(a: Allocator, method: []const u8, name: ?[]const u8, body: []const u8) i64 {
    if (!std.mem.eql(u8, method, "tools/call") or !std.mem.eql(u8, name orelse "", "run_task")) return 15;
    const parsed = std.json.parseFromSlice(Value, a, body, .{}) catch return 15;
    defer parsed.deinit();
    const request = parsed.value;
    if (request != .object) return 15;
    const params = request.object.get("params") orelse return 15;
    if (params != .object) return 15;
    const task = parseTask(params.object.get("arguments") orelse return 15) catch return 15;
    const preprocessing: u64 = if (task.context) |context| if (context.len > inline_context_max) summarize_deadline_ms / 1000 else 0 else 0;
    return @intCast(task.timeout_seconds + preprocessing + 15);
}

const raw_context_lead = "\n\nBackground context supplied by the caller for this task:\n\n";
const summary_context_lead = "\n\nBackground context supplied by the caller for this task (summarized to fit):\n\n";
const summarize_instruction =
    \\Summarize the context below so another agent can use it as background for a
    \\task. Keep decisions, constraints, file paths, open questions, and anything
    \\needed to continue the work; drop pleasantries, repetition and formatting
    \\nnoise. Answer with the summary alone, and do not use tools.
    \\
    \\<context>
    \\
;

fn execute(raw: ?*anyopaque, a: Allocator, task: Task) !Result {
    const ctx: *Context = @ptrCast(@alignCast(raw.?));
    var appended: ?[]const u8 = null;
    var summarized = false;
    var used_chars: u64 = 0;
    var preprocess: ?Preprocess = null;
    if (task.context) |context| {
        if (context.len <= inline_context_max) {
            appended = try std.fmt.allocPrint(a, "{s}{s}", .{ raw_context_lead, context });
            used_chars = context.len;
        } else {
            const summary = summarizeContext(a, ctx, context) catch |err| return Result{
                .text = try std.fmt.allocPrint(a, "Task not run: context summarization failed ({s}). Retry with a shorter context, or omit context.", .{@errorName(err)}),
                .isError = true,
                .context_chars = context.len,
            };
            appended = try std.fmt.allocPrint(a, "{s}{s}", .{ summary_context_lead, summary.text });
            summarized = true;
            used_chars = summary.text.len;
            preprocess = summary.usage;
        }
    }
    const argv = try taskArgv(a, ctx, task, appended);
    const run_result = try runner.runCappedWithOptions(a, ctx.io, argv, 64 * 1024, 16 * 1024, task.timeout_seconds * 1000, .{ .environ_map = ctx.env, .kill_process_tree = true });
    var result = try formatResult(a, run_result);
    result.context_chars = if (task.context) |c| c.len else 0;
    result.context_summarized = summarized;
    result.context_used_chars = used_chars;
    result.preprocess = preprocess;
    return result;
}

/// Arguments for one bounded task child. `appended` is the context text to add
/// to the child's system prompt, or null when the caller supplied none.
/// Permissions and model still come from the server launch, never the call
/// (ADR 0129): `context` adds text, not configuration.
pub fn taskArgv(a: Allocator, ctx: *Context, task: Task, appended: ?[]const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ ctx.exe, "--no-resume", if (ctx.yolo) "--yolo" else "--safe", "--max-model-calls", try std.fmt.allocPrint(a, "{d}", .{task.max_model_calls}), "--max-tool-calls", "64" });
    if (ctx.model) |model| try argv.appendSlice(a, &.{ "--model", model });
    if (appended) |text| try argv.appendSlice(a, &.{ "--append-system-prompt", text });
    try argv.appendSlice(a, &.{ "-p", task.prompt });
    return argv.items;
}

/// What the preprocessing step cost, as the summarizer child reported it.
/// `cost_usd` is null whenever no settled charge was available — an incomplete
/// or unpriced report is surfaced as unavailable, never as a list-rate guess.
pub const Preprocess = struct {
    cost_usd: ?f64 = null,
    usage_complete: bool = false,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
};

const Summary = struct { text: []const u8, usage: Preprocess };

/// Re-exported for tests: the summarizer's shape without spawning anything.
pub const ParsedSummary = Summary;

const preprocess_unavailable = "the summarizer reported an incomplete charge (missing or unpriced usage); no settled amount is claimed and no list-rate estimate is substituted";

var g_summary_seq: std.atomic.Value(u64) = .init(0);

fn tempPath(a: Allocator, ctx: *Context) ![]const u8 {
    const dir = if (ctx.env.get("TMPDIR")) |t| if (t.len > 0) std.mem.trimEnd(u8, t, "/") else "/tmp" else "/tmp";
    const n = g_summary_seq.fetchAdd(1, .monotonic);
    const stamp: u64 = @intCast(Io.Timestamp.now(ctx.io, .awake).nanoseconds);
    return std.fmt.allocPrint(a, "{s}/graff-mcp-summary-{d}-{d}.json", .{ dir, stamp, n });
}

/// The `turn` event of a `--json` one-shot: its text is the answer, and its
/// usage fields are the settled charge the engine already ingested. Any other
/// line is ignored, and an incomplete report yields a null cost.
pub fn parseTurn(a: Allocator, stdout: []const u8) !Summary {
    var lines = std.mem.tokenizeScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const ev = std.json.parseFromSliceLeaky(Value, a, line, .{}) catch continue;
        if (ev != .object) continue;
        const typ = ev.object.get("type") orelse continue;
        if (typ != .string or !std.mem.eql(u8, typ.string, "turn")) continue;
        const raw = ev.object.get("text") orelse continue;
        if (raw != .string) continue;
        const text = std.mem.trim(u8, raw.string, " \r\n\t");
        if (text.len == 0) return error.ContextSummarizationFailed;
        const num = struct {
            fn get(o: std.json.ObjectMap, k: []const u8) u64 {
                const v = o.get(k) orelse return 0;
                return switch (v) {
                    .integer => |i| if (i >= 0) @intCast(i) else 0,
                    .float => |f| if (f >= 0) @intFromFloat(f) else 0,
                    else => 0,
                };
            }
        };
        const complete = if (ev.object.get("usage_complete")) |v| (v == .bool and v.bool) else false;
        const settled = complete and num.get(ev.object, "unpriced_calls") == 0 and num.get(ev.object, "missing_usage_calls") == 0;
        const cost: ?f64 = if (settled) switch (ev.object.get("cost_usd") orelse .null) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => null,
        } else null;
        return .{ .text = text, .usage = .{
            .cost_usd = cost,
            .usage_complete = settled and cost != null,
            .input_tokens = num.get(ev.object, "input_tokens"),
            .output_tokens = num.get(ev.object, "output_tokens"),
        } };
    }
    return error.ContextSummarizationFailed;
}

/// Shrink an over-long handover into readable text before it reaches the child.
///
/// A fresh one-shot can only consume text. The gateway's `/responses/compact`
/// endpoint returns opaque server state that is meaningful only by continuing
/// the conversation it compacted, so it cannot seed a child that starts with
/// `--no-resume` (ADR 0002, ADR 0253); the readable summarizer is the arm that
/// fits. The summarizer runs `--safe` with no tool budget — summarizing is not
/// a reason to touch the workspace — and under the caller's own credentials,
/// so its spend lands on the same bill rather than a new one.
fn summarizeContext(a: Allocator, ctx: *Context, context: []const u8) !Summary {
    const brief = try std.fmt.allocPrint(a, "{s}{s}\n</context>\n", .{ summarize_instruction, context });
    // `--json`, not `-p`: print mode reports no settled charge, and the engine
    // already ingests an exact one on this path. Its single request line
    // arrives on a FILE-backed stdin, so nothing has to feed a pipe
    // concurrently and a large handover cannot deadlock the parent.
    var request: Io.Writer.Allocating = .init(a);
    var js: std.json.Stringify = .{ .writer = &request.writer };
    try js.write(.{ .type = "user", .text = brief });
    try request.writer.writeByte('\n');

    const path = try tempPath(a, ctx);
    defer Io.Dir.deleteFileAbsolute(ctx.io, path) catch {};
    {
        const out = Io.Dir.createFileAbsolute(ctx.io, path, .{ .truncate = true }) catch return error.ContextSummarizationFailed;
        defer out.close(ctx.io);
        var wbuf: [4096]u8 = undefined;
        var fw = out.writer(ctx.io, &wbuf);
        fw.interface.writeAll(request.written()) catch return error.ContextSummarizationFailed;
        fw.interface.flush() catch return error.ContextSummarizationFailed;
    }
    const stdin_file = Io.Dir.openFileAbsolute(ctx.io, path, .{ .mode = .read_only }) catch return error.ContextSummarizationFailed;
    defer stdin_file.close(ctx.io);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ ctx.exe, "--no-resume", "--safe", "--json", "--max-model-calls", "1", "--max-tool-calls", "0" });
    if (ctx.model) |model| try argv.appendSlice(a, &.{ "--model", model });
    const summary_run = try runner.runCappedWithOptions(a, ctx.io, argv.items, summary_stdout_cap, 8 * 1024, summarize_deadline_ms, .{ .environ_map = ctx.env, .kill_process_tree = true, .stdin_file = stdin_file });
    if (!runner.ranOk(summary_run) or summary_run.timed_out or summary_run.cancelled) return error.ContextSummarizationFailed;
    return try parseTurn(a, summary_run.stdout);
}

pub fn formatResult(a: Allocator, result: runner.CappedRun) !Result {
    const ok = runner.ranOk(result) and !result.cancelled and !result.timed_out;
    const suffix = if (result.timed_out) "\n[Task timed out; partial work may remain.]" else if (result.cancelled) "\n[Task cancelled; partial work may remain.]" else if (!ok) "\n[Task failed; partial work may remain.]" else "";
    return .{
        .text = try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{
            result.stdout,
            if (result.stdout_truncated) "\n[Task output truncated at 64 KiB.]" else "",
            suffix,
            if (!ok) result.stderr else "",
            if (!ok and result.stderr_truncated) "\n[Diagnostics truncated at 16 KiB.]" else "",
        }),
        .isError = !ok,
        .timed_out = result.timed_out,
        .cancelled = result.cancelled,
        .output_truncated = result.stdout_truncated or (!ok and result.stderr_truncated),
    };
}

pub fn run(io: Io, gpa: Allocator, parent: *const std.process.Environ.Map, args: []const []const u8) !void {
    if (parent.get("GRAFF_MCP_TASK") != null) return error.NestedMcpTaskServer;
    const exe = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe);
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    for (parent.keys(), parent.values()) |key, value| try env.put(key, value);
    try env.put("GRAFF_MCP_TASK", "1");
    var ctx: Context = .{ .io = io, .exe = exe, .env = &env };
    var port: ?u16 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--http")) {
            port = 7720;
        } else if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            i += 1;
            port = try std.fmt.parseInt(u16, args[i], 10);
            if (port.? == 0) return error.InvalidMcpPort;
        } else if (std.mem.eql(u8, args[i], "--yolo")) {
            ctx.yolo = true;
        } else if (std.mem.eql(u8, args[i], "--model") and i + 1 < args.len) {
            i += 1;
            ctx.model = args[i];
        } else return error.InvalidMcpServeOption;
    }
    if (port) |http_port| return @import("mcp_server_http.zig").run(io, gpa, http_port, parent.get("GRAFF_MCP_TOKEN") orelse return error.McpHttpTokenRequired, .{ .execute = execute, .context = &ctx });
    var read_buf: [64 * 1024]u8 = undefined;
    var in = Io.File.stdin().reader(io, &read_buf);
    var write_buf: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(io, &write_buf);
    var server: Server = .{ .execute = execute, .context = &ctx };
    try serve(gpa, &in.interface, &out.interface, &server);
}

const tool_catalog =
    \\{"tools":[{"name":"run_task","description":"Run a small, self-contained task with Codegraff in the server launch directory. Fresh context per call; pass background the child needs in context (summarized when long) and include scope and acceptance criteria. May edit files and execute commands when server permissions allow. Returns the answer or an explicit failure with partial output. Calls run serially; no continuation or cancellation handle.","inputSchema":{"type":"object","properties":{"prompt":{"type":"string","minLength":1,"maxLength":32768},"context":{"type":"string","minLength":1,"maxLength":32768,"description":"Background for the task: relevant history, decisions, file paths or constraints the child cannot re-derive. Appended to the child's system prompt; over 8192 bytes it is summarized first, and the result reports whether that happened."},"timeout_seconds":{"type":"integer","minimum":1,"maximum":300,"default":120},"max_model_calls":{"type":"integer","minimum":1,"maximum":32,"default":8}},"required":["prompt"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}}]}
;
