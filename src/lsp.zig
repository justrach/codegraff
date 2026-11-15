//! Opt-in, read-only LSP queries through a bounded stdio helper. The same
//! executor is used by line REPL, ACP, workers and RLM host calls.
const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const tools = @import("tools.zig");
const config = @import("lsp_config.zig");
const runner = @import("process_runner.zig");
pub const spec: @import("schema.zig").ToolSpec = .{
    .name = "lsp",
    .desc = "Query an explicitly configured local language server: diagnostics, hover, definition, references or document_symbols. Read-only protocol operations, no server installation or workspace edits. Paths stay in this agent workspace. Positions are 1-based lines and 0-based UTF-16 character offsets. Diagnostics timeouts are not clean results. status lists configured servers without launching them.",
    .schema =
    \\{"type":"object","properties":{"operation":{"type":"string","enum":["status","diagnostics","hover","definition","references","document_symbols"]},"path":{"type":"string"},"line":{"type":"integer","minimum":1},"character":{"type":"integer","minimum":0},"server":{"type":"string"}},"required":["operation"]}
    ,
};
fn fail(a: Allocator, message: []const u8) !tools.ToolOutput {
    return .{ .text = try a.dupe(u8, message), .is_error = true };
}
fn field(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}
pub fn positional(operation: []const u8) bool {
    for ([_][]const u8{ "hover", "definition", "references" }) |name| if (std.mem.eql(u8, operation, name)) return true;
    return false;
}
fn valid(operation: []const u8) bool {
    return positional(operation) or std.mem.eql(u8, operation, "status") or std.mem.eql(u8, operation, "diagnostics") or std.mem.eql(u8, operation, "document_symbols");
}
pub fn execute(ctx: tools.ToolCtx, input: Value) !tools.ToolOutput {
    if (@import("no_local_tools.zig").enabled) return fail(ctx.gpa, "LSP is disabled by --no-local-tools");
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    if (@import("hard_policy_context.zig").check(ctx.io, a, ctx.agent_cwd, ctx.hard_policy, "tool.use", "lsp")) |denied| return fail(ctx.gpa, denied);
    if (input != .object) return fail(ctx.gpa, "lsp requires an object");
    const operation = field(input.object, "operation") orelse return fail(ctx.gpa, "lsp requires operation");
    if (!valid(operation)) return fail(ctx.gpa, "unsupported LSP operation");
    const registry = ctx.lsp_registry;
    if (registry.problem) |problem| return fail(ctx.gpa, problem);
    if (std.mem.eql(u8, operation, "status")) {
        var servers = std.json.Array.init(a);
        for (registry.servers) |server| {
            var obj: std.json.ObjectMap = .empty;
            try obj.put(a, "id", .{ .string = server.id });
            try obj.put(a, "language_id", .{ .string = server.language_id });
            try servers.append(.{ .object = obj });
        }
        return .{ .text = try std.json.Stringify.valueAlloc(ctx.gpa, .{ .version = 1, .enabled = registry.enabled(), .servers = Value{ .array = servers } }, .{}) };
    }
    const path = field(input.object, "path") orelse return fail(ctx.gpa, "lsp requires path");
    if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return fail(ctx.gpa, "invalid LSP path");
    const id = if (input.object.get("server")) |v| (if (v == .string) v.string else return fail(ctx.gpa, "server must be a string")) else null;
    const server = registry.select(path, id) orelse return fail(ctx.gpa, "no configured LSP server matches this file; configure lsp.servers in protected .harness/settings.json");
    var line: i64 = 0;
    var character: i64 = 0;
    if (positional(operation)) {
        const l = input.object.get("line") orelse return fail(ctx.gpa, "this LSP operation requires line");
        const c = input.object.get("character") orelse return fail(ctx.gpa, "this LSP operation requires character");
        if (l != .integer or c != .integer or l.integer < 1 or l.integer > 1_000_000 or c.integer < 0 or c.integer > 1_000_000) return fail(ctx.gpa, "invalid LSP position (line is 1-based, character is 0-based UTF-16)");
        line = l.integer - 1;
        character = c.integer;
    }
    const paths = @import("codedbpro_paths.zig");
    const root = try paths.sessionAbs(a, ctx.io, ctx.agent_cwd, ".");
    const absolute = try paths.sessionAbs(a, ctx.io, ctx.agent_cwd, path);
    const request = try std.json.Stringify.valueAlloc(a, .{ .command = server.command, .root = root, .path = absolute, .language_id = server.language_id, .operation = operation, .line = line, .character = character, .timeout_ms = server.timeout_ms, .server_id = server.id, .warm_ttl_ms = server.warm_ttl_ms }, .{});
    if (request.len > 32 * 1024) return fail(ctx.gpa, "LSP request exceeds 32 KiB");
    var empty = std.process.Environ.Map.init(a);
    defer empty.deinit();
    const use_warm = server.warm_ttl_ms > 0 and @import("builtin").os.tag != .windows;
    const argv: []const []const u8 = if (use_warm)
        &.{ "python3", "-c", @embedFile("lsp_warm.py"), @embedFile("lsp_warm.py"), @embedFile("lsp_client.py"), request }
    else
        &.{ "python3", "-c", @embedFile("lsp_client.py"), request };
    const result = runner.runCappedWithOptions(ctx.gpa, ctx.io, argv, 64 * 1024, 4096, server.timeout_ms + (if (use_warm) @as(u64, 3000) else 2000), .{
        .cwd = .{ .path = root },
        .environ_map = @import("tool_env.zig").get() orelse &empty,
        .kill_process_tree = true,
    }) catch return fail(ctx.gpa, "LSP helper unavailable; Python 3 and the configured server must already be installed");
    defer ctx.gpa.free(result.stdout);
    defer ctx.gpa.free(result.stderr);
    if (result.cancelled) return .{ .text = try ctx.gpa.dupe(u8, "LSP query cancelled"), .is_error = true, .cancelled = true };
    if (result.timed_out) return fail(ctx.gpa, "LSP query timed out; diagnostics are incomplete, not clean");
    if (result.stdout_truncated) return fail(ctx.gpa, "LSP result exceeds 64 KiB; result is incomplete");
    const reply = std.json.parseFromSliceLeaky(Value, a, result.stdout, .{}) catch return fail(ctx.gpa, "invalid response from LSP helper");
    if (reply != .object) return fail(ctx.gpa, "invalid response from LSP helper");
    const version = reply.object.get("version") orelse return fail(ctx.gpa, "unversioned LSP helper response");
    if (version != .integer or version.integer != 1) return fail(ctx.gpa, "unsupported LSP helper version");
    const complete = if (reply.object.get("complete")) |v| v == .bool and v.bool else false;
    const failed = !runner.ranOk(result) or reply.object.contains("error") or !complete;
    if (ctx.tracer) |tr| tr.write(.{ .t = tr.elapsedMs(), .ev = "lsp_query", .operation = operation, .complete = complete, .is_error = failed });
    return .{ .text = try ctx.gpa.dupe(u8, result.stdout), .is_error = failed };
}
