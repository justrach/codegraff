//! Complete, current MCP tool catalogs.
//!
//! - `tools/list` is paginated: a server may return `nextCursor` and expect
//!   the client to ask again. graff read only the first page, so a large
//!   server's later tools never reached the model. `complete` follows the
//!   cursor (bounded) and merges every page.
//! - A server can change its tools mid-session and say so with
//!   `notifications/tools/list_changed` (mcp_notify marks it stale). A
//!   2026-07-28 stdio server only sends that after `subscriptions/listen`,
//!   which `listen` requests at connect. `refreshStale` re-lists each stale
//!   server before the next model request so the catalog is not frozen at
//!   connect time.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const mcp = @import("mcp.zig");
const mcp_rpc = @import("mcp_rpc.zig");
const mcp_protocol = @import("mcp_protocol.zig");
const mcp_stdio = @import("mcp_stdio.zig");
const Server = mcp_rpc.Server;
const Tool = mcp.Tool;

pub const max_pages = 32;

pub const Listed = struct { result: Value, tools: Value };

fn nextCursor(o: std.json.ObjectMap) ?[]const u8 {
    const c = o.get("nextCursor") orelse return null;
    return if (c == .string and c.string.len > 0) c.string else null;
}

/// `first` is the first `tools/list` result. Follows `nextCursor` and
/// returns one result whose `tools` holds every page. A failed later page
/// ends the listing with what was already read.
pub fn complete(server: *Server, a: Allocator, io: ?Io, first: Value) !Listed {
    if (first != .object) return error.BadMcpResponse;
    const tv = first.object.get("tools") orelse return error.BadMcpResponse;
    if (tv != .array) return error.BadMcpResponse;
    var cursor = nextCursor(first.object) orelse return .{ .result = first, .tools = tv };
    var all = std.json.Array.init(a);
    try all.appendSlice(tv.array.items);
    var pages: usize = 1;
    while (pages < max_pages) : (pages += 1) {
        const params = try std.json.Stringify.valueAlloc(a, .{ .cursor = cursor }, .{});
        const resp = mcp_rpc.handshakeRequest(server, a, io, params, "tools/list") catch break;
        if (resp != .object) break;
        const r = resp.object.get("result") orelse break;
        if (r != .object) break;
        const page = r.object.get("tools") orelse break;
        if (page != .array) break;
        try all.appendSlice(page.array.items);
        const next = nextCursor(r.object) orelse break;
        if (std.mem.eql(u8, next, cursor)) break; // a server repeating itself
        cursor = next;
    }
    var merged = try first.object.clone(a);
    _ = merged.orderedRemove("nextCursor");
    try merged.put(a, "tools", .{ .array = all });
    return .{ .result = .{ .object = merged }, .tools = .{ .array = all } };
}

/// The registry's tool records for one server's `tools` array.
pub fn appendTools(a: Allocator, tools: *std.ArrayList(Tool), server_index: usize, server: *const Server, tools_v: Value) !void {
    for (tools_v.array.items) |t| {
        if (t != .object) continue;
        if (!@import("mcp_apps.zig").modelVisible(t)) continue;
        const name_v = t.object.get("name") orelse continue;
        if (name_v != .string) continue;
        const orig = try a.dupe(u8, name_v.string);
        const qualified = try @import("mcp_names.zig").qualify(a, server.name, orig);
        // Prefer description; fall back to the 2025-06-18+ human-readable
        // title so a metadata-only tool isn't blank to the model.
        const desc = if (t.object.get("description")) |d| (if (d == .string) d.string else "") else if (t.object.get("title")) |ti| (if (ti == .string) ti.string else "") else "";
        // Deep-clone: the Value copy from get() shares entries storage with
        // tools_v, which mcp_cache.store serializes after this loop; mutating
        // through the copy's shared ArrayHashMap storage corrupts that tree.
        var schema = if (t.object.get("inputSchema")) |sv|
            try mcp_protocol.deepClone(a, sv)
        else
            Value{ .object = .empty };
        try mcp_protocol.rewriteOneOf(a, &schema);
        // ...then lower any TOP-LEVEL combinator: Anthropic rejects the
        // whole request over one, so a single server advertising it would
        // break every turn (codedbpro's `replace`, "path or paths").
        try mcp_protocol.flattenTopLevel(a, &schema);
        try tools.append(a, .{
            .server_index = server_index,
            .server_name = server.name,
            .original_name = orig,
            .qualified_name = qualified,
            .description = try a.dupe(u8, desc),
            .input_schema = schema,
            .ui_resource_uri = if (@import("mcp_apps.zig").resourceUri(t)) |uri| try a.dupe(u8, uri) else null,
            .read_only = declaresReadOnly(t),
        });
    }
}

test "appendTools normalizes schemas without changing the serializable source catalog (#1892)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const source = try std.json.parseFromSliceLeaky(Value, a,
        \\{"tools":[
        \\  {"name":"union","inputSchema":{"type":"object","properties":{"keep":{"oneOf":[{"type":"string"},{"type":"null"}]}},"oneOf":[{"properties":{"path":{"type":"string"}},"required":["path"]},{"properties":{"paths":{"type":"array","items":{"type":"string"}}},"required":["paths"]}]}},
        \\  {"name":"intersection","inputSchema":{"properties":{"keep":{"type":"boolean"}},"required":["keep"],"allOf":[{"properties":{"extra":{"type":"integer"}},"required":["extra"]}]}},
        \\  {"name":"alternative","inputSchema":{"anyOf":[{"properties":{"a":{"type":"string"}},"required":["a"]},{"properties":{"b":{"type":"string"}},"required":["b"]}]}}
        \\],"nextCursor":"more"}
    , .{ .allocate = .alloc_always });
    const before = try std.json.Stringify.valueAlloc(a, source, .{});
    const server: Server = .{ .name = "fixture", .transport = .{ .dormant = .{ .cfg = .empty } } };
    var tools: std.ArrayList(Tool) = .empty;
    try appendTools(a, &tools, 0, &server, source.object.get("tools").?);

    // mcp_cache.store serializes this original tools/list tree after discovery.
    // Compare every byte, not just surviving keys: nested maps and arrays must
    // also be unchanged, including their iteration order and original oneOf.
    const after = try std.json.Stringify.valueAlloc(a, source, .{});
    try std.testing.expectEqualStrings(before, after);
    try std.testing.expectEqual(@as(usize, 3), tools.items.len);
    for (tools.items) |tool| {
        try std.testing.expect(mcp_protocol.topLevelCombinator(tool.input_schema) == null);
        try std.testing.expectEqualStrings("object", tool.input_schema.object.get("type").?.string);
    }
    const union_schema = tools.items[0].input_schema.object;
    const properties = union_schema.get("properties").?.object;
    const nested = properties.get("keep").?.object;
    try std.testing.expect(nested.get("oneOf") == null);
    try std.testing.expectEqual(@as(usize, 2), nested.get("anyOf").?.array.items.len);
    try std.testing.expect(properties.get("path") != null);
    try std.testing.expect(properties.get("paths") != null);
    try std.testing.expect(union_schema.get("required") == null);
    try std.testing.expectEqualStrings("Requires one of: path or paths.", union_schema.get("description").?.string);
    const intersection = tools.items[1].input_schema.object;
    try std.testing.expect(intersection.get("properties").?.object.get("extra") != null);
    try std.testing.expectEqual(@as(usize, 2), intersection.get("required").?.array.items.len);
    try std.testing.expectEqualStrings("Requires one of: a or b.", tools.items[2].input_schema.object.get("description").?.string);
}

/// MCP tool annotations: `readOnlyHint: true` says the tool does not modify
/// its environment. Absent or false means it may (the spec's default).
pub fn declaresReadOnly(t: Value) bool {
    if (t != .object) return false;
    const annotations = t.object.get("annotations") orelse return false;
    if (annotations != .object) return false;
    const hint = annotations.object.get("readOnlyHint") orelse return false;
    return hint == .bool and hint.bool;
}

test "a tool is read-only only when its annotations say readOnlyHint: true (ADR 0228)" {
    const a = std.testing.allocator;
    for ([_]struct { json: []const u8, want: bool }{
        .{ .json = "{\"name\":\"list\",\"annotations\":{\"readOnlyHint\":true}}", .want = true },
        .{ .json = "{\"name\":\"save\",\"annotations\":{\"readOnlyHint\":false}}", .want = false },
        .{ .json = "{\"name\":\"save\",\"annotations\":{\"destructiveHint\":false}}", .want = false },
        .{ .json = "{\"name\":\"plain\"}", .want = false },
        .{ .json = "{\"name\":\"odd\",\"annotations\":{\"readOnlyHint\":\"true\"}}", .want = false },
    }) |case| {
        const parsed = try std.json.parseFromSlice(Value, a, case.json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(case.want, declaresReadOnly(parsed.value));
    }
}

/// Ask a 2026-07-28 stdio server for `notifications/tools/list_changed`.
/// Fire and forget: the acknowledgement and later notifications are read
/// (and observed) by the next request's wait, and the id never matches a
/// real request. A server without subscriptions answers with an error that
/// is skipped the same way.
pub fn listen(server: *Server, a: Allocator) void {
    if (server.era != .modern or server.transport != .stdio) return;
    const id = server.next_id;
    server.next_id += 1;
    const line = mcp_protocol.buildRequest(a, id, "subscriptions/listen", "{\"notifications\":{\"toolsListChanged\":true}}", true) catch return;
    mcp_stdio.writeRequest(&server.transport.stdio.stdin_writer.interface, line) catch {};
}

/// Before each model request: merge finished deferred handshakes, then
/// re-list servers whose tools changed. True when the catalog must rebuild.
pub fn beforeRequest(reg: *mcp.Registry) bool {
    const added = @import("mcp_watch.zig").poll(reg); // servers added mid-session
    if (!reg.first_request_join_skipped) settle(reg, first_request_budget_ms);
    const joined = @import("mcp_boot.zig").joinBeforeRequest(reg) or added;
    const refreshed = refreshStale(reg);
    return joined or refreshed;
}

/// How long the first request gives queued starts. A dormant server restored
/// from cache (mcp_lazy.zig) starts in milliseconds, and merging it on a later
/// request would change the catalog mid-session and throw away the prompt
/// cache (ADR 0221). A real handshake takes longer and still joins on a later
/// request, as ADR 0035 has it.
const first_request_budget_ms: u32 = 100;

fn settle(reg: *mcp.Registry, budget_ms: u32) void {
    var waited: u32 = 0;
    while (waited < budget_ms) : (waited += 5) {
        reg.mutex.lockUncancelable(reg.io);
        const busy = for (reg.pending_starts) |t| {
            if (t.ready) |flag| if (!flag.load(.acquire)) break true;
        } else false;
        reg.mutex.unlock(reg.io);
        if (!busy) return;
        reg.io.sleep(.fromMilliseconds(5), .awake) catch return;
    }
}

/// Re-list every server that announced a tool change. True when the
/// registry's tools changed, so the caller rebuilds the model's catalog.
pub fn refreshStale(reg: *mcp.Registry) bool {
    reg.mutex.lockUncancelable(reg.io);
    defer reg.mutex.unlock(reg.io);
    var changed = false;
    for (reg.servers, 0..) |server, i| {
        if (!server.notes.tools_stale.swap(false, .acq_rel)) continue;
        const a = reg.arena();
        const resp = mcp_rpc.handshakeRequest(server, a, reg.io, "{}", "tools/list") catch continue;
        if (resp != .object) continue;
        const first = resp.object.get("result") orelse continue;
        const listed = complete(server, a, reg.io, first) catch continue;
        var tools: std.ArrayList(Tool) = .empty;
        for (reg.tools) |t| if (t.server_index != i) tools.append(a, t) catch return changed;
        appendTools(a, &tools, i, server, listed.tools) catch continue;
        reg.tools = tools.items;
        changed = true;
    }
    return changed;
}

test "the first request merges a start that finishes within its budget (ADR 0221)" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const boot = @import("mcp_boot.zig");
    var reg = mcp.Registry.empty(a, io);
    defer reg.deinit();
    const Task = struct {
        fn run(task_io: Io, done: *std.atomic.Value(bool)) boot.StartOutcome {
            defer done.store(true, .release);
            task_io.sleep(.fromMilliseconds(20), .awake) catch {};
            return .{};
        }
    };
    const flag = try a.create(std.atomic.Value(bool));
    flag.* = .init(false);
    reg.pending_starts = try a.alloc(boot.PendingStart, 1);
    reg.pending_starts[0] = .{ .future = try io.concurrent(Task.run, .{ io, flag }), .ready = flag };
    reg.pending_names = try reg.arena().dupe([]const u8, &.{"dormant"});
    settle(&reg, first_request_budget_ms);
    try std.testing.expect(boot.joinBeforeRequest(&reg));
    try std.testing.expectEqual(@as(usize, 0), reg.pending_starts.len);
}
