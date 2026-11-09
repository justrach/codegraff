//! ACP `mcpServers` on session/new and session/load. The client that spawned
//! graff names the MCP servers its session should have; they join the live
//! registry the way `/mcp add` adds one, alongside whatever .mcp.json and the
//! global config already connected. Before this they were ignored, and a
//! client's tools never reached the model.
//!
//! ACP shapes (the client decides which it sends; graff advertises
//! `mcpCapabilities.http` at initialize, not sse):
//!   stdio: {"name","command","args":[…],"env":[{"name","value"}]}
//!   http:  {"type":"http","name","url","headers":[{"name","value"}]}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const mcp = @import("mcp.zig");
const Server = @import("mcp_rpc.zig").Server;
const util = @import("util.zig");

/// One server as the registry's config reads it: a name and the same object a
/// `.mcp.json` entry would hold (`command`/`args`/`env` or `url`/`headers`).
pub const Spec = struct {
    name: []const u8,
    cfg: std.json.ObjectMap,
};

/// The servers in a request's params. Entries graff cannot run — sse, no
/// name, neither a command nor a url, malformed pairs — are left out rather
/// than failing the session.
pub fn parse(arena: Allocator, params: ?Value) ![]Spec {
    const p = params orelse return &.{};
    if (p != .object) return &.{};
    const list = p.object.get("mcpServers") orelse return &.{};
    if (list != .array) return &.{};
    var out: std.ArrayList(Spec) = .empty;
    for (list.array.items) |entry| {
        if (entry != .object) continue;
        const name = util.strFieldObj(entry.object, "name") orelse continue;
        if (name.len == 0) continue;
        const kind = util.strFieldObj(entry.object, "type") orelse "stdio";
        var cfg: std.json.ObjectMap = .empty;
        if (std.mem.eql(u8, kind, "http")) {
            const url = util.strFieldObj(entry.object, "url") orelse continue;
            try cfg.put(arena, "url", .{ .string = url });
            if (try pairs(arena, entry.object.get("headers"))) |headers| try cfg.put(arena, "headers", .{ .object = headers });
        } else if (std.mem.eql(u8, kind, "stdio")) {
            const command = util.strFieldObj(entry.object, "command") orelse continue;
            if (command.len == 0) continue;
            try cfg.put(arena, "command", .{ .string = command });
            var argv = std.json.Array.init(arena);
            if (entry.object.get("args")) |args| if (args == .array) for (args.array.items) |arg| {
                if (arg == .string) try argv.append(arg);
            };
            try cfg.put(arena, "args", .{ .array = argv });
            if (try pairs(arena, entry.object.get("env"))) |env| try cfg.put(arena, "env", .{ .object = env });
        } else continue; // sse: not advertised, not run
        try out.append(arena, .{ .name = name, .cfg = cfg });
    }
    return out.items;
}

/// ACP's `[{"name","value"}]` as the `{name: value}` object .mcp.json uses.
/// Null when there are none.
fn pairs(arena: Allocator, value: ?Value) !?std.json.ObjectMap {
    const v = value orelse return null;
    if (v != .array or v.array.items.len == 0) return null;
    var map: std.json.ObjectMap = .empty;
    for (v.array.items) |item| {
        if (item != .object) continue;
        const name = util.strFieldObj(item.object, "name") orelse continue;
        const val = util.strFieldObj(item.object, "value") orelse continue;
        try map.put(arena, name, .{ .string = val });
    }
    return if (map.count() == 0) null else map;
}

/// How long session/new and session/load wait on the client's servers
/// (#1291, ADR 0230). Long enough for a server restored from the tool cache,
/// so the first request's catalog already has it; never long enough to hold
/// the session for a real handshake, which keeps connecting in the background
/// and joins on a later model request.
pub const attach_budget_ms: u32 = if (@import("builtin").os.tag == .windows) 1500 else 250;

/// The live ACP session's hook (engine.Dispatch.mcp_servers): start what the
/// client named, merge whatever connects within `attach_budget_ms`, then
/// re-render the root's tool catalog so the model sees the new tools on its
/// next request, as `/mcp add` does.
pub fn attach(ctx: *anyopaque, _: Allocator, params: ?Value) anyerror!void {
    const live: *@import("acp_live_turn.zig").LiveTurn = @ptrCast(@alignCast(ctx));
    const root = live.root;
    const reg = root.registry orelse return;
    const durable_params = if (params) |p| try util.dupeJsonValue(root.arena, p) else null;
    const specs = try parse(root.arena, durable_params);
    if (specs.len == 0) return;
    if (!joinWithin(reg, root.arena, specs, attach_budget_ms)) return;
    root.invalidateRootTools();
    @import("prompt_cache_hud.zig").noteBust(.mcp);
    try root.ensureRootTools(root.provider.kind);
    root.rebaseContextMeter();
}

/// Queue every server's handshake, wait at most `budget_ms` for them, and
/// merge the ones that finished. A server the thread pool cannot take is
/// connected inline instead of dropped. True when anything joined.
pub fn joinWithin(reg: *mcp.Registry, arena: Allocator, specs: []const Spec, budget_ms: u32) bool {
    const mcp_boot = @import("mcp_boot.zig");
    var queued: std.ArrayList([]const u8) = .empty;
    var direct: std.ArrayList(Spec) = .empty;
    for (specs) |spec| {
        const list_ok = if (mcp_boot.queueConfig(reg, spec.name, spec.cfg)) queued.append(arena, spec.name) else direct.append(arena, spec);
        list_ok catch return false;
    }
    const before = reg.servers.len;
    _ = connect(reg, direct.items, null);
    // Also consumes failed handshakes, which add nothing.
    if (queued.items.len > 0) _ = mcp_boot.joinNamedWithin(reg, queued.items, budget_ms);
    return reg.servers.len > before;
}

/// Connect each server the registry does not already have by name, in order.
/// Returns how many joined; one that fails to start is reported on `notice`
/// and skipped, so a bad entry never costs the session. Run between turns.
pub fn connect(reg: *mcp.Registry, specs: []const Spec, notice: ?*std.Io.Writer) usize {
    var added: usize = 0;
    for (specs) |spec| {
        var present = false;
        for (reg.servers) |server| if (std.mem.eql(u8, server.name, spec.name)) {
            present = true;
            break;
        };
        if (present) continue;
        const a = reg.arena();
        var servers: std.ArrayList(*Server) = .empty;
        var tools: std.ArrayList(mcp.Tool) = .empty;
        servers.appendSlice(a, reg.servers) catch continue;
        tools.appendSlice(a, reg.tools) catch continue;
        const name = a.dupe(u8, spec.name) catch continue;
        reg.startServer(a, &servers, &tools, name, spec.cfg) catch |err| {
            if (notice) |w| w.print("[mcp:{s}] failed to start: {t}\n", .{ spec.name, err }) catch {};
            continue;
        };
        reg.servers = a.dupe(*Server, servers.items) catch continue;
        reg.tools = a.dupe(mcp.Tool, tools.items) catch continue;
        added += 1;
    }
    return added;
}

test "parse: stdio with args and env, http with headers, sse and malformed left out" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const params = try std.json.parseFromSliceLeaky(Value, a,
        \\{"sessionId":"s","cwd":"/tmp","mcpServers":[
        \\  {"name":"files","command":"/usr/bin/files-mcp","args":["--root","/tmp",7],"env":[{"name":"TOKEN","value":"t"}]},
        \\  {"type":"http","name":"browser","url":"http://127.0.0.1:9/mcp","headers":[{"name":"Authorization","value":"Bearer x"}]},
        \\  {"type":"sse","name":"old","url":"http://127.0.0.1:9/sse","headers":[]},
        \\  {"name":"","command":"x"},
        \\  {"name":"nocmd"},
        \\  {"type":"http","name":"nourl"},
        \\  "junk"
        \\]}
    , .{});
    const specs = try parse(a, params);
    try std.testing.expectEqual(@as(usize, 2), specs.len);

    try std.testing.expectEqualStrings("files", specs[0].name);
    try std.testing.expectEqualStrings("/usr/bin/files-mcp", specs[0].cfg.get("command").?.string);
    const argv = specs[0].cfg.get("args").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), argv.len); // the number is not an argument
    try std.testing.expectEqualStrings("--root", argv[0].string);
    try std.testing.expectEqualStrings("t", specs[0].cfg.get("env").?.object.get("TOKEN").?.string);
    try std.testing.expect(specs[0].cfg.get("url") == null);

    try std.testing.expectEqualStrings("browser", specs[1].name);
    try std.testing.expectEqualStrings("http://127.0.0.1:9/mcp", specs[1].cfg.get("url").?.string);
    try std.testing.expectEqualStrings("Bearer x", specs[1].cfg.get("headers").?.object.get("Authorization").?.string);
    try std.testing.expect(specs[1].cfg.get("command") == null);
}

test "parse: no params, no list, or an empty list is nothing to connect" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    try std.testing.expectEqual(@as(usize, 0), (try parse(a, null)).len);
    const none = try std.json.parseFromSliceLeaky(Value, a, "{\"cwd\":\"/tmp\"}", .{});
    try std.testing.expectEqual(@as(usize, 0), (try parse(a, none)).len);
    const empty = try std.json.parseFromSliceLeaky(Value, a, "{\"mcpServers\":[]}", .{});
    try std.testing.expectEqual(@as(usize, 0), (try parse(a, empty)).len);
}

test "connect: a server the registry already has by name is kept, not respawned" {
    var reg = mcp.Registry.empty(std.testing.allocator, std.testing.io);
    defer reg.deinit();
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var existing: Server = undefined;
    existing.name = "files";
    var list = [_]*Server{&existing};
    reg.servers = &list;
    var cfg: std.json.ObjectMap = .empty;
    try cfg.put(a, "command", .{ .string = "/nonexistent/should-not-spawn" });
    const specs = [_]Spec{.{ .name = "files", .cfg = cfg }};
    try std.testing.expectEqual(@as(usize, 0), connect(&reg, &specs, null));
    try std.testing.expectEqual(@as(usize, 1), reg.servers.len);
    reg.servers = &.{}; // not the registry's to free
}

fn stdioSpec(a: Allocator, name: []const u8, command: []const u8, args: []const []const u8) !Spec {
    var cfg: std.json.ObjectMap = .empty;
    try cfg.put(a, "command", .{ .string = command });
    var argv = std.json.Array.init(a);
    for (args) |arg| try argv.append(.{ .string = arg });
    try cfg.put(a, "args", .{ .array = argv });
    return .{ .name = name, .cfg = cfg };
}

test "joinWithin (#1291): a server that fails fast ends the wait early" {
    const io = std.testing.io;
    var reg = mcp.Registry.empty(std.testing.allocator, io);
    defer reg.deinit();
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const specs = [_]Spec{try stdioSpec(a, "gone", "/nonexistent/graff-mcp-1291", &.{})};
    const t0 = std.Io.Timestamp.now(io, .awake);
    try std.testing.expect(!joinWithin(&reg, a, &specs, 10_000));
    try std.testing.expect(t0.untilNow(io, .awake).toMilliseconds() < 5_000);
    try std.testing.expectEqual(@as(usize, 0), reg.servers.len);
}

test "joinWithin (#1291): a stalled handshake returns at the budget and stays queued" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // needs /bin/sh
    const io = std.testing.io;
    var reg = mcp.Registry.empty(std.testing.allocator, io);
    defer reg.deinit(); // joins the handshake once `sleep` exits
    reg.stdio_probe = false;
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    // Starts fine and never answers the initialize request.
    const specs = [_]Spec{try stdioSpec(a, "stalled", "/bin/sh", &.{ "-c", "sleep 2" })};
    const t0 = std.Io.Timestamp.now(io, .awake);
    try std.testing.expect(!joinWithin(&reg, a, &specs, 100));
    try std.testing.expect(t0.untilNow(io, .awake).toMilliseconds() < 1_500);
    try std.testing.expect(@import("mcp_boot.zig").alreadyStarting(&reg, "stalled"));
}

test "handleLine: initialize advertises http MCP, session/new hands the hook its mcpServers first" {
    const engine = @import("acp_engine.zig");
    const Fixture = struct {
        seen: usize = 0,
        names: [4][]const u8 = undefined,
        fn turn(_: *anyopaque, a: Allocator, text: []const u8) anyerror![]const u8 {
            return a.dupe(u8, text);
        }
        fn servers(ctx: *anyopaque, a: Allocator, params: ?Value) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            for (try parse(a, params)) |spec| {
                self.names[self.seen] = spec.name;
                self.seen += 1;
            }
        }
    };
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var fixture: Fixture = .{};
    var d: engine.Dispatch = .{ .turn = Fixture.turn, .ctx = &fixture, .seed = 7, .mcp_servers = Fixture.servers };
    var buf: [16384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try engine.handleLine(&d, a, &w, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":1}}");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"mcpCapabilities\":{\"http\":true,\"sse\":false}") != null);

    w = .fixed(&buf);
    try engine.handleLine(&d, a, &w,
        \\{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[{"name":"files","command":"/bin/files"},{"type":"http","name":"browser","url":"http://127.0.0.1:9/mcp","headers":[]}]}}
    );
    try std.testing.expectEqual(@as(usize, 2), fixture.seen);
    try std.testing.expectEqualStrings("files", fixture.names[0]);
    try std.testing.expectEqualStrings("browser", fixture.names[1]);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"sessionId\"") != null);
}
