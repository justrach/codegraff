//! Local stdio MCP task adapter. Each call owns a bounded, fresh CLI child.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const app = @import("mcp_server_app.zig");
const runner = @import("process_runner.zig");

pub const Task = struct {
    prompt: []const u8,
    timeout_seconds: u64 = 120,
    max_model_calls: u64 = 8,
};
pub const Result = struct { text: []const u8, isError: bool = false, timed_out: bool = false, cancelled: bool = false, output_truncated: bool = false };
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
        if (std.mem.eql(u8, method, "ping")) return reply(out, id, struct {}{});
        if (std.mem.eql(u8, method, "initialize")) {
            if (self.initialized) return failure(out, id, -32600, "Already initialized");
            const requested = string(params, "protocolVersion") orelse
                return failure(out, id, -32602, "protocolVersion is required");
            const protocol = if (std.mem.eql(u8, requested, "2024-11-05") or std.mem.eql(u8, requested, "2025-03-26") or std.mem.eql(u8, requested, "2025-06-18")) requested else "2025-06-18";
            self.apps = app.supported(params);
            self.initialized = true;
            return reply(out, id, .{
                .protocolVersion = protocol,
                .capabilities = .{ .tools = struct {}{}, .resources = struct {}{} },
                .serverInfo = .{ .name = "codegraff", .title = "Codegraff", .version = @import("main.zig").harness_version },
                .instructions = "Delegate a small, self-contained task with run_task. Tasks run serially in the server launch directory with fresh context. Include scope and acceptance criteria; inspect the result and changes before integrating.",
            });
        }
        if (!self.ready) return failure(out, id, -32000, "Initialize the server first");
        if (std.mem.eql(u8, method, "tools/list")) {
            const catalog = try app.catalog(a, tool_catalog, self.apps);
            return reply(out, id, catalog);
        }
        if (std.mem.eql(u8, method, "resources/list")) return reply(out, id, .{ .resources = .{app.resource} });
        if (std.mem.eql(u8, method, "resources/templates/list")) return reply(out, id, .{ .resourceTemplates = [0]struct {}{} });
        if (std.mem.eql(u8, method, "resources/read")) {
            const uri = string(params, "uri") orelse return failure(out, id, -32602, "Resource URI is required");
            if (!std.mem.eql(u8, uri, app.uri)) return failure(out, id, -32002, "Resource not found");
            return reply(out, id, app.contents());
        }
        if (!std.mem.eql(u8, method, "tools/call")) return failure(out, id, -32601, "Method not found");
        const name = string(params, "name") orelse return failure(out, id, -32602, "Tool name is required");
        if (!std.mem.eql(u8, name, "run_task")) return failure(out, id, -32602, "Unknown tool");
        const input = params.object.get("arguments") orelse Value.null;
        const task = parseTask(input) catch return failure(out, id, -32602, "Expected prompt (1-32768 bytes), timeout_seconds (1-300), max_model_calls (1-32); no other arguments");
        const result = self.execute(self.context, a, task) catch |err| Result{
            .text = try std.fmt.allocPrint(a, "Task could not run: {s}", .{@errorName(err)}),
            .isError = true,
        };
        return reply(out, id, .{ .content = .{.{ .type = "text", .text = result.text }}, .isError = result.isError, .structuredContent = .{
            .text = result.text,
            .status = if (result.timed_out) "timed_out" else if (result.cancelled) "cancelled" else if (result.isError) "failed" else "completed",
            .output_truncated = result.output_truncated,
            .timeout_seconds = task.timeout_seconds,
            .max_model_calls = task.max_model_calls,
        } });
    }
};

fn string(value: Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const v = value.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

pub fn parseTask(input: Value) !Task {
    const prompt = string(input, "prompt") orelse return error.InvalidArguments;
    if (std.mem.trim(u8, prompt, " \r\n\t").len == 0 or prompt.len > 32768 or std.mem.indexOfScalar(u8, prompt, 0) != null) return error.InvalidArguments;
    var task: Task = .{ .prompt = prompt };
    var it = input.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "prompt")) continue;
        const v = entry.value_ptr.*;
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

const Context = struct {
    io: Io,
    exe: []const u8,
    env: *const std.process.Environ.Map,
    model: ?[]const u8 = null,
    yolo: bool = false,
};

fn execute(raw: ?*anyopaque, a: Allocator, task: Task) !Result {
    const ctx: *Context = @ptrCast(@alignCast(raw.?));
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ ctx.exe, "--no-resume", if (ctx.yolo) "--yolo" else "--safe", "--max-model-calls", try std.fmt.allocPrint(a, "{d}", .{task.max_model_calls}), "--max-tool-calls", "64" });
    if (ctx.model) |model| try argv.appendSlice(a, &.{ "--model", model });
    try argv.appendSlice(a, &.{ "-p", task.prompt });
    const run_result = try runner.runCappedWithOptions(a, ctx.io, argv.items, 64 * 1024, 16 * 1024, task.timeout_seconds * 1000, .{ .environ_map = ctx.env, .kill_process_tree = true });
    return formatResult(a, run_result);
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
    \\{"tools":[{"name":"run_task","description":"Run a small, self-contained task with Codegraff in the server launch directory. Fresh context per call; include relevant context, scope and acceptance criteria. May edit files and execute commands when server permissions allow. Returns the answer or an explicit failure with partial output. Calls run serially; no continuation or cancellation handle.","inputSchema":{"type":"object","properties":{"prompt":{"type":"string","minLength":1,"maxLength":32768},"timeout_seconds":{"type":"integer","minimum":1,"maximum":300,"default":120},"max_model_calls":{"type":"integer","minimum":1,"maximum":32,"default":8}},"required":["prompt"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}}]}
;
