//! `/refresh` (and `/models refresh`) slash command for both REPL and ACP.
//!
//! Force-refreshes live model catalogs for every signed-in dynamic provider
//! (router providers, Codex account catalog, Kimi, and price DB) without
//! requiring a session restart. In ACP, `acp_engine` automatically emits
//! `config_option_update` after any slash command changes offered models.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const ansi = @import("ansi.zig");
const style = &ansi.style;
const catalog_failures = @import("catalog_failures.zig");
const kimi_catalog = @import("kimi_catalog.zig");
const models_cache = @import("models_cache.zig");
const pricing = @import("pricing.zig");
const pricing_db = @import("pricing_db.zig");
const provider_mod = @import("provider.zig");
const Keys = provider_mod.Keys;
const providers = @import("providers.zig");

pub fn matches(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t\r\n");
    if (std.mem.eql(u8, t, "/refresh") or std.mem.eql(u8, t, "/models refresh")) return true;
    if (std.mem.startsWith(u8, t, "/refresh ")) {
        const arg = std.mem.trim(u8, t["/refresh ".len..], " \t");
        return arg.len == 0 or std.mem.eql(u8, arg, "models");
    }
    return false;
}

pub fn tryHandle(root: *Agent, keys: *Keys, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    _ = arena;
    if (!matches(line)) return false;
    root.ensureStoredKeys(keys);

    var pinged = providers.refreshModelListing(root, keys.*);
    const codex_token = keys.get("codex") orelse "";
    if (codex_token.len > 0 and keys.codex_account.len > 0) {
        const codex_home = if (root.model_catalog) |mc| mc.codex_home else "";
        models_cache.loadCodexCatalog(root.io, root.gpa, root.arena, root.home, codex_home, codex_token, keys.codex_account, true, true);
        if (root.model_catalog) |*mc| {
            mc.loaded = true;
            mc.online_loaded = true;
        }
        pinged += 1;
    }

    try catalog_failures.report(out);
    const total = pricing.models().len;
    if (pinged > 0) {
        try out.print("{s}✓ refreshed {d} provider catalog(s){s} — {d} model entries loaded\n", .{
            style.green, pinged, style.reset, total,
        });
    } else {
        try out.print("no signed-in dynamic providers to refresh ({d} baked model entries) — use /login or /key first\n", .{total});
    }
    if (codex_token.len > 0) try out.print("  codex: {s}\n", .{models_cache.codex_catalog_source});
    if (keys.get("kimi") != null) try out.print("  kimi:  {s}\n", .{kimi_catalog.catalog_source});
    if (pricing_db.source.len != 0) try out.print("  prices: {s}\n", .{pricing_db.source});
    try out.print("{s}tip: /model <name> to switch · /models to list all{s}\n", .{ style.dim, style.reset });
    try out.flush();
    return true;
}

test "matches recognizes /refresh, /refresh models, and /models refresh" {
    try std.testing.expect(matches("/refresh"));
    try std.testing.expect(matches("  /refresh  "));
    try std.testing.expect(matches("/refresh models"));
    try std.testing.expect(matches("/models refresh"));
    try std.testing.expect(!matches("/refresh unknown"));
    try std.testing.expect(!matches("/models"));
    try std.testing.expect(!matches("/model"));
}

test "/refresh pulls live dynamic provider catalog in-session (REPL and ACP handleCommand)" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(home);

    var address = try Io.net.IpAddress.parseLiteral("127.0.0.1:0");
    var server = try Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);
    var group: Io.Group = .init;
    defer group.cancel(io);
    const Handler = struct {
        fn serve(srv_io: Io, srv: *Io.net.Server) void {
            const stream = srv.accept(srv_io) catch return;
            defer stream.close(srv_io);
            var rbuf: [2048]u8 = undefined;
            var r = Io.net.Stream.Reader.init(stream, srv_io, &rbuf);
            while (r.interface.takeDelimiter('\n') catch null) |line|
                if (std.mem.eql(u8, line, "\r") or line.len == 0) break;
            const body = "{\"models\":[{\"slug\":\"gpt-6.2-sol\",\"visibility\":\"list\",\"context_window\":500000},{\"slug\":\"gpt-6.2-astra\",\"visibility\":\"list\",\"context_window\":272000}]}";
            var wbuf: [2048]u8 = undefined;
            var w = Io.net.Stream.Writer.init(stream, srv_io, &wbuf);
            w.interface.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch return;
            w.interface.flush() catch return;
        }
    };
    try group.concurrent(io, Handler.serve, .{ io, &server });

    const saved_override = provider_mod.g_chatgpt_url_override;
    defer provider_mod.g_chatgpt_url_override = saved_override;
    const saved_table = pricing.active_model_table;
    defer pricing.active_model_table = saved_table;
    const saved_price_overlay = pricing.price_overlay;
    defer pricing.price_overlay = saved_price_overlay;
    const saved_ctx_overlay = pricing.context_overlay;
    defer pricing.context_overlay = saved_ctx_overlay;
    const saved_price_src = pricing_db.source;
    defer pricing_db.source = saved_price_src;
    const saved_attempted = @import("router_catalog.zig").attempted;
    defer @import("router_catalog.zig").attempted = saved_attempted;
    pricing_db.invalidate();
    defer pricing_db.invalidate();

    provider_mod.g_chatgpt_url_override = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1/responses", .{server.socket.address.getPort()});
    var root = try @import("agent_request_body_responses.zig").testAgentFor(a, "chatgpt-new", .responses, "gpt-6.1-sol");
    root.home = home;
    var keys: Keys = .{ .values = @splat(null) };
    _ = keys.set("chatgpt-new", "test-token", .login);

    var aw: Io.Writer.Allocating = .init(a);
    try std.testing.expect(try tryHandle(&root, &keys, a, "/refresh", &aw.writer));
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "refreshed 1 provider catalog(s)") != null);
    try std.testing.expect(pricing.providerModelInTable("chatgpt-new", "gpt-6.2-sol"));
    try std.testing.expect(pricing.providerModelInTable("chatgpt-new", "gpt-6.2-astra"));
}
