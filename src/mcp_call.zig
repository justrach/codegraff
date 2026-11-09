//! MCP invocation and recovery, separated from registry lifecycle.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Registry = @import("mcp.zig").Registry;
const mcp_rpc = @import("mcp_rpc.zig");
const mcp_protocol = @import("mcp_protocol.zig");
const initializeServer = mcp_rpc.initializeServer;
const request = mcp_rpc.request;
const renderResult = @import("mcp_content.zig").renderResult;
const Server = mcp_rpc.Server;

/// One server/tool for MRTR retries (mcp_mrtr.resolve).
const McpCall = struct {
    server: *Server,
    name: []const u8,
    fn send(self: McpCall, a: Allocator, params: []const u8) anyerror!Value {
        return request(self.server, a, params, "tools/call", self.name);
    }
};

pub const CallResult = struct {
    text: []u8,
    is_error: bool,
    /// Borrowed slice of `text`, not a second allocation. RLM consumes this
    /// JSON value rather than parsing a server's human-readable summary.
    structured_text: ?[]const u8 = null,
    /// The delegated task's `codegraff/runTask` mirror, when the server sent
    /// one. Copied out of the response arena before it dies.
    run_task: ?@import("engine_events.zig").RunTaskMeta = null,

    pub fn takeHostText(self: CallResult, a: Allocator) ![]u8 {
        if (self.structured_text) |structured| {
            defer a.free(self.text);
            return try a.dupe(u8, structured);
        }
        return self.text;
    }
};

/// A tool whose server connection closed or failed this session (#1523).
/// Remembered so a later call or schema load names the closed service
/// instead of reporting a tool that was never registered.
pub const Withdrawn = struct { qualified_name: []const u8, server: []const u8, reason: []const u8 };

const restart_hint = "Inspect /mcp; `/mcp reconnect <server>` starts it again without a new session, then reload its tool schemas.";

/// The registry lock is held throughout. Never replay a possibly executed call.
pub fn call(reg: *Registry, out_alloc: Allocator, qualified: []const u8, input: Value) !CallResult {
    return invoke(reg, out_alloc, qualified, input) catch |err| switch (err) {
        error.McpClosed, error.ReadFailed, error.WriteFailed, error.BrokenPipe, error.ConnectionResetByPeer => blk: {
            if (try @import("mcp_restart.zig").closeForRestart(reg, out_alloc, qualified, @errorName(err))) |text| break :blk .{ .text = text, .is_error = true };
            try withdrawServer(reg, qualified, @errorName(err));
            break :blk .{
                .text = try std.fmt.allocPrint(out_alloc, "MCP service connection closed or failed ({s}). Its tools have been withdrawn from the catalog. The tool may not have completed; it was not retried automatically. " ++ restart_hint, .{@errorName(err)}),
                .is_error = true,
            };
        },
        else => return err,
    };
}

fn withdrawServer(reg: *Registry, qualified: []const u8, reason: []const u8) !void {
    const server_index = for (reg.tools) |tool| {
        if (std.mem.eql(u8, tool.qualified_name, qualified)) break tool.server_index;
    } else return;
    var available: std.ArrayList(@import("mcp.zig").Tool) = .empty;
    var withdrawn: std.ArrayList(Withdrawn) = .empty;
    try withdrawn.appendSlice(reg.arena(), reg.withdrawn);
    for (reg.tools) |tool| {
        if (tool.server_index != server_index) {
            try available.append(reg.arena(), tool);
        } else try withdrawn.append(reg.arena(), .{ .qualified_name = tool.qualified_name, .server = tool.serverName(), .reason = reason });
    }
    // Replace the slice instead of mutating snapshots held by in-flight callers.
    reg.tools = try available.toOwnedSlice(reg.arena());
    reg.withdrawn = try withdrawn.toOwnedSlice(reg.arena());
    reg.catalog_dirty.store(true, .release);
}

fn withdrawnTool(reg: *const Registry, qualified: []const u8) ?Withdrawn {
    for (reg.withdrawn) |w| if (std.mem.eql(u8, w.qualified_name, qualified)) return w;
    return null;
}

fn isLive(reg: *const Registry, qualified: []const u8) bool {
    for (reg.tools) |t| if (std.mem.eql(u8, t.qualified_name, qualified)) return true;
    return false;
}

fn hasLiveServer(reg: *const Registry, server: []const u8) bool {
    for (reg.tools) |t| if (std.mem.eql(u8, t.serverName(), server)) return true;
    return false;
}

fn hasLiveQueryMatch(all: []const @import("mcp.zig").Tool, input: Value) bool {
    const query = @import("tools.zig").strField(input, "query") orelse return false;
    const gate = @import("mcp_schema_gate.zig");
    for (all) |t| {
        if (!gate.isDeferred(all, t)) continue;
        var tok = std.mem.tokenizeAny(u8, query, " \t,;:/_-");
        while (tok.next()) |w| {
            if (w.len < 2) continue;
            if (gate.containsIgnoreCase(t.qualified_name, w) or gate.containsIgnoreCase(t.description, w)) return true;
        }
    }
    return false;
}

fn findWithdrawn(reg: *const Registry, input: Value) ?Withdrawn {
    if (@import("tools.zig").strField(input, "server")) |want| {
        if (!hasLiveServer(reg, want)) {
            for (reg.withdrawn) |w| if (std.mem.eql(u8, w.server, want)) return w;
        }
    }
    if (input == .object) if (input.object.get("tools")) |list| if (list == .array) {
        for (list.array.items) |item| {
            if (item != .string or isLive(reg, item.string)) continue;
            if (withdrawnTool(reg, item.string)) |w| return w;
        }
    };
    return null;
}

pub fn unavailableLoadForPlatform(reg: *Registry, a: Allocator, input: Value, is_macos: bool) ?[]const u8 {
    var check_nanocua = false;
    {
        reg.mutex.lockUncancelable(reg.io);
        defer reg.mutex.unlock(reg.io);
        if (findWithdrawn(reg, input)) |hit| {
            return std.fmt.allocPrint(a, "MCP service {s} is unavailable: its connection closed or failed earlier in this session ({s}) and its tools were withdrawn, so nothing was loaded and {s} cannot be called. " ++ restart_hint, .{ hit.server, hit.reason, hit.qualified_name }) catch null;
        }
        if (!hasLiveServer(reg, @import("nanocua_default.zig").server_name)) {
            check_nanocua = @import("nanocua_default.zig").requestsNanocua(input, hasLiveQueryMatch(reg.tools, input));
        }
    }
    if (check_nanocua) {
        if (@import("nanocua_default.zig").resolveUnavailable(reg, a, is_macos)) |msg| {
            return a.dupe(u8, msg) catch msg;
        }
    }
    return null;
}

/// #1523 / #1819: `load_tool_schemas` (and `mcp_search_tools`) for a service
/// whose connection closed or macOS `nanocua` before `nanocua.app` is installed
/// answers with the real reason instead of claiming the tool does not exist.
pub fn unavailableLoad(reg: *Registry, a: Allocator, input: Value) ?[]const u8 {
    return unavailableLoadForPlatform(reg, a, input, @import("builtin").os.tag == .macos);
}

fn invoke(reg: *Registry, out_alloc: Allocator, qualified: []const u8, input: Value) !CallResult {
    const tool = for (reg.tools) |t| {
        if (std.mem.eql(u8, t.qualified_name, qualified)) break t;
    } else {
        // #1523: a sibling call in the same batch can close the connection
        // first; this call then reports the same closed service.
        if (withdrawnTool(reg, qualified)) |w| return .{ .text = try std.fmt.allocPrint(out_alloc, "MCP service connection closed or failed earlier in this session ({s}). Its tools have been withdrawn from the catalog; this call was not sent. " ++ restart_hint, .{w.reason}), .is_error = true };
        if (@import("nanocua_default.zig").isComputerToolName(qualified)) {
            if (@import("nanocua_default.zig").unavailableMessage(reg.io, reg.arena(), reg.home, reg.global_config_path, reg.global_is_override, @import("builtin").os.tag == .macos)) |msg| {
                return .{ .text = try out_alloc.dupe(u8, msg), .is_error = true };
            }
        }
        reg.catalog_dirty.store(true, .release);
        return .{ .text = try out_alloc.dupe(u8, "MCP tool is not registered in the current connection. Its loaded schema may be stale. The next catalog will reflect the current registration. Inspect /mcp; `/mcp reconnect <server>` starts the configured service again, then reload its schema before retrying."), .is_error = true };
    };

    const server = reg.servers[tool.server_index];
    const params = try std.json.Stringify.valueAlloc(reg.gpa, .{ .name = tool.original_name, .arguments = input }, .{});
    defer reg.gpa.free(params);

    // Tool responses can be large and numerous; keep them out of the
    // session arena. Only the returned text is copied to `out_alloc`.
    var response_arena_state = std.heap.ArenaAllocator.init(reg.gpa);
    defer response_arena_state.deinit();
    const response_alloc = response_arena_state.allocator();
    if (server.transport == .dormant) @import("mcp_lazy.zig").wake(reg, server) catch |err|
        return .{ .text = try std.fmt.allocPrint(out_alloc, "MCP server {s} failed to start: {t}", .{ server.name, err }), .is_error = true };
    if (!server.initialized) try initializeServer(server, response_alloc, reg.arena(), null);
    const first_resp = request(server, response_alloc, params, "tools/call", tool.original_name) catch |err| switch (err) {
        // Streamable HTTP servers use 404 to expire a session. Re-run the
        // MCP handshake once, then retry the call without the stale ID.
        // A modern-era server never carries a session id in the first
        // place (mcp_http never sends/stores one for a modern request),
        // so this cannot structurally fire for one — the explicit guard
        // is defense-in-depth against a future refactor resurrecting a
        // re-handshake loop against a server that has no `initialize`.
        error.McpSessionExpired => retry: {
            if (server.era != .legacy) return err;
            try initializeServer(server, response_alloc, reg.arena(), null);
            break :retry try request(server, response_alloc, params, "tools/call", tool.original_name);
        },
        else => return err,
    };

    // Resolve bounded MRTR input requests before interpreting the tool result.
    const call_ctx: McpCall = .{ .server = server, .name = tool.original_name };
    const resp = try @import("mcp_mrtr.zig").resolve(response_alloc, params, first_resp, call_ctx, McpCall.send);
    if (resp != .object) return error.BadMcpResponse;

    if (resp.object.get("error")) |e| {
        // Protocol-level failure (unknown tool, invalid args, server
        // crash) — distinct from a tool that ran and *returned* an error
        // (isError below). Keep the JSON-RPC code: models retry better
        // when they can tell -32602 bad-params from a tool-side failure.
        const msg = if (e == .object) blk: {
            const m = e.object.get("message") orelse break :blk "MCP error";
            break :blk if (m == .string) m.string else "MCP error";
        } else "MCP error";
        const code: i64 = if (e == .object) blk: {
            const c = e.object.get("code") orelse break :blk 0;
            break :blk if (c == .integer) c.integer else 0;
        } else 0;
        const text = if (code != 0)
            try std.fmt.allocPrint(out_alloc, "MCP error {d}: {s}", .{ code, msg })
        else
            try out_alloc.dupe(u8, msg);
        return .{ .text = text, .is_error = true };
    }
    // A well-formed JSON-RPC reply has `result` xor `error`; `error` was
    // handled above. Guard a malformed server that sends neither (or a
    // non-object result) instead of force-unwrapping into a panic.
    const result_val = resp.object.get("result") orelse
        return .{ .text = try out_alloc.dupe(u8, "MCP response had neither result nor error"), .is_error = true };
    if (result_val != .object)
        return .{ .text = try out_alloc.dupe(u8, "MCP response result was not an object"), .is_error = true };
    const result = result_val.object;
    // resultType absent MUST read as "complete". input_required was
    // resolved above; any other type is surfaced, never returned as "".
    if (!mcp_protocol.resultIsComplete(result))
        return .{ .text = try out_alloc.dupe(u8, "MCP server returned an unsupported resultType"), .is_error = true };
    const is_error = if (result.get("isError")) |v| (v == .bool and v.bool) else false;
    const run_task = @import("run_task_meta.zig").fromMcpResult(out_alloc, result);

    var ow: Io.Writer.Allocating = .init(out_alloc);
    errdefer ow.deinit();
    if (tool.ui_resource_uri) |uri| {
        const path = @import("mcp_apps.zig").snapshot(reg.io, response_alloc, reg.home, server, uri, input, result_val) catch null;
        if (path) |p| {
            reg.last_app_path = try reg.arena().dupe(u8, p);
            try ow.writer.print("[MCP app]({s}) — saved interactive result; /mcp apps opens it in a browser.\n", .{p});
        } else try ow.writer.writeAll("[MCP app view unavailable; ordinary tool output follows.]\n");
    }
    const structured_range = try renderResult(&ow.writer, result, .{
        .arena = reg.arena(),
        .slot = &reg.pending_image,
        .label = qualified,
        .supports_vision = reg.vision_capable,
    }, response_alloc);
    const text = try ow.toOwnedSlice();
    return .{ .text = text, .is_error = is_error, .run_task = run_task, .structured_text = if (structured_range) |range| text[range.start..range.end] else null };
}
