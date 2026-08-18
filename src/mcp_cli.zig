//! The `graff mcp` CLI subcommand: list/add MCP servers in .mcp.json, plus the
//! trusted-companion-entry check + startup untrusted-server count that gate the
//! MCP consent prompt. Split out of main.zig (600-line goal). Back-imports main
//! for mcp_config_path (.mcp.json) and the companion_servers allowlist. main
//! aliases countMcpServers / persistMcpServer / mcpCommand back.
//!
//! Reads go through mcp_config.zig, so `list`, `login` and the consent count
//! all see the workspace file merged with the user-level
//! `~/.codegraff/mcp.json` (#345). Writes deliberately do not: `mcp add` and
//! the `persistMcp*` helpers still target the project .mcp.json only, so
//! adding a server to one repository never edits every other one.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const root = @import("main.zig");
const skills = @import("skills.zig");
const mcp = @import("mcp.zig");
const mcp_config = @import("mcp_config.zig");
const mcp_oauth = @import("mcp_oauth.zig");
const mcp_config_path = root.mcp_config_path;
const companion_servers = skills.companion_servers;

fn trustedMcpEntry(name: []const u8, cfg: Value) bool {
    if (cfg != .object) return false;
    const expected_bin = for (companion_servers) |c| {
        if (std.mem.eql(u8, name, c.server)) break c.bin;
    } else return false;
    const cmd = cfg.object.get("command") orelse return false;
    if (cmd != .string or !std.mem.eql(u8, cmd.string, expected_bin)) return false;
    const args = cfg.object.get("args") orelse return true;
    if (args != .array) return false;
    if (args.array.items.len == 0) return true;
    if (args.array.items.len != 1) return false;
    const a0 = args.array.items[0];
    return a0 == .string and std.mem.eql(u8, a0.string, "--mcp");
}

/// Count the servers in an already-merged config that actually need consent at
/// startup (0 if none; trusted companion entries are exempt — see
/// trustedMcpEntry). Takes the `Merged` rather than loading it so the caller
/// keeps the invalid-file flags it needs to report, instead of the load
/// happening twice with the diagnosis thrown away once. A global entry is no
/// more trusted than a workspace one: it can run local commands or ship data
/// off-box just the same, so it is counted and gated identically.
pub fn countMcpServers(merged: mcp_config.Merged) usize {
    var n: usize = 0;
    var it = merged.servers.iterator();
    while (it.next()) |entry| {
        // `smolify` is a reserved core server; configured entries cannot shadow
        // its pinned endpoint and therefore need no consent.
        if (std.mem.eql(u8, entry.key_ptr.*, "smolify")) continue;
        if (!trustedMcpEntry(entry.key_ptr.*, entry.value_ptr.*)) n += 1;
    }
    return n;
}

/// Best-effort write of a server entry into .mcp.json (so `/mcp add` survives
/// a restart). Merges into any existing config. Returns false on any error.
const McpEnvPair = struct { key: []const u8, value: []const u8 };
pub const McpHeaderPair = struct { key: []const u8, value: []const u8 };

pub fn persistMcpServer(io: Io, arena: Allocator, name: []const u8, command: []const u8, args: []const []const u8) bool {
    return persistMcpServerWithEnv(io, arena, name, command, args, &.{});
}

fn persistMcpServerWithEnv(io: Io, arena: Allocator, name: []const u8, command: []const u8, args: []const []const u8, env: []const McpEnvPair) bool {
    var root_obj: std.json.ObjectMap = .empty;
    if (Io.Dir.cwd().readFileAlloc(io, mcp_config_path, arena, .limited(1 << 20))) |text| {
        if (std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always })) |v| {
            if (v == .object) root_obj = v.object;
        } else |_| {}
    } else |_| {}

    var servers: std.json.ObjectMap = .empty;
    if (root_obj.get("mcpServers")) |m| if (m == .object) {
        servers = m.object;
    };
    var entry: std.json.ObjectMap = .empty;
    entry.put(arena, "command", .{ .string = command }) catch return false;
    var argv = std.json.Array.init(arena);
    for (args) |a| argv.append(.{ .string = a }) catch return false;
    entry.put(arena, "args", .{ .array = argv }) catch return false;
    if (env.len > 0) {
        var env_obj: std.json.ObjectMap = .empty;
        for (env) |pair| env_obj.put(arena, pair.key, .{ .string = pair.value }) catch return false;
        entry.put(arena, "env", .{ .object = env_obj }) catch return false;
    }
    servers.put(arena, name, .{ .object = entry }) catch return false;
    root_obj.put(arena, "mcpServers", .{ .object = servers }) catch return false;

    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    s.write(Value{ .object = root_obj }) catch return false;

    const f = Io.Dir.cwd().createFile(io, mcp_config_path, .{}) catch return false;
    defer f.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    fw.interface.writeAll(aw.writer.buffered()) catch return false;
    fw.interface.flush() catch return false;
    return true;
}

/// Persist a native Streamable HTTP entry. Headers are optional and intended
/// for static bearer/API tokens; OAuth-capable servers can remain anonymous
/// until an authorization flow is configured.
pub fn persistMcpUrl(io: Io, arena: Allocator, name: []const u8, url: []const u8, headers: []const McpHeaderPair) bool {
    var root_obj: std.json.ObjectMap = .empty;
    if (Io.Dir.cwd().readFileAlloc(io, mcp_config_path, arena, .limited(1 << 20))) |text| {
        if (std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always })) |v| {
            if (v == .object) root_obj = v.object;
        } else |_| {}
    } else |_| {}

    var servers: std.json.ObjectMap = .empty;
    if (root_obj.get("mcpServers")) |m| if (m == .object) {
        servers = m.object;
    };
    var entry: std.json.ObjectMap = .empty;
    entry.put(arena, "url", .{ .string = url }) catch return false;
    if (headers.len > 0) {
        var header_obj: std.json.ObjectMap = .empty;
        for (headers) |header| header_obj.put(arena, header.key, .{ .string = header.value }) catch return false;
        entry.put(arena, "headers", .{ .object = header_obj }) catch return false;
    }
    servers.put(arena, name, .{ .object = entry }) catch return false;
    root_obj.put(arena, "mcpServers", .{ .object = servers }) catch return false;

    var aw: Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &aw.writer };
    stringify.write(Value{ .object = root_obj }) catch return false;
    const file = Io.Dir.cwd().createFile(io, mcp_config_path, .{}) catch return false;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    writer.interface.writeAll(aw.writer.buffered()) catch return false;
    writer.interface.flush() catch return false;
    return true;
}

fn mcpCliUsage(w: *Io.Writer) !void {
    try w.writeAll(
        \\usage:
        \\  graff mcp                      list servers in .mcp.json + ~/.codegraff/mcp.json
        \\  graff mcp import               copy Claude/Cursor MCP + skills into graff folders
        \\  graff mcp add <name> --url <https://...> [--header KEY=VALUE ...]
        \\  graff mcp login <name>        OAuth login for a remote server
        \\  graff mcp add <name> [--env KEY=VALUE ...] -- <command> [args...]
        \\  graff mcp add <name> <command> [args...]
        \\
        \\examples:
        \\  graff mcp add mobbin --url https://api.mobbin.com/mcp
        \\  graff mcp login mobbin
        \\  graff mcp login smolify
        \\  graff mcp add context7 -- npx -y @upstash/context7-mcp
        \\  graff mcp add playwright -- npx -y @playwright/mcp
        \\  graff mcp add sentry --env SENTRY_AUTH_TOKEN=... -- npx -y @sentry/mcp-server
        \\
    );
}

pub fn mcpCommand(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, environ_map: anytype, args: []const []const u8) !void {
    var obuf: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(io, &obuf);
    // Reads (list/login) see project + global; writes stay project-local.
    const global_path = mcp_config.globalPath(arena, home, environ_map);

    if (args.len > 0 and (std.mem.eql(u8, args[0], "import") or std.mem.eql(u8, args[0], "import-claude") or std.mem.eql(u8, args[0], "adopt"))) {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = Io.Dir.cwd().realPath(io, &cwd_buf) catch 0;
        const cwd = if (n > 0) cwd_buf[0..n] else ".";
        try @import("adopt.zig").command(io, arena, home, cwd, &out.interface);
        return;
    }

    if (args.len == 0 or std.mem.eql(u8, args[0], "list")) {
        const merged = mcp_config.load(io, arena, Io.Dir.cwd(), mcp_config_path, global_path, home);
        try mcp_config.reportInvalid(merged, &out.interface, mcp_config_path, global_path, "", "");
        if (merged.servers.count() == 0) {
            try out.interface.writeAll("no MCP servers configured. Add one with `graff mcp add <name> -- <command> [args...]`,\nor list servers for every project in ~/" ++ mcp_config.global_rel_path ++ ".\n");
        } else {
            try out.interface.print("{d} MCP server(s):\n", .{merged.servers.count()});
            var it = merged.servers.iterator();
            while (it.next()) |entry| {
                const cfg = entry.value_ptr.*;
                if (cfg != .object) continue;
                if (cfg.object.get("url")) |url| {
                    try out.interface.print("  {s}: {s}", .{ entry.key_ptr.*, if (url == .string) url.string else "?" });
                } else {
                    const command = if (cfg.object.get("command")) |c| if (c == .string) c.string else "?" else "?";
                    try out.interface.print("  {s}: {s}", .{ entry.key_ptr.*, command });
                    if (cfg.object.get("args")) |argv| if (argv == .array) for (argv.array.items) |arg| {
                        if (arg == .string) try out.interface.print(" {s}", .{arg.string});
                    };
                }
                // Only what the project does not define is tagged: an entry the
                // workspace overrides is the workspace's, not the user's.
                if (merged.isGlobalOnly(entry.key_ptr.*)) try out.interface.writeAll("  (global)");
                try out.interface.writeByte('\n');
            }
        }
        try out.interface.flush();
        return;
    }

    if (std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        try mcpCliUsage(&out.interface);
        try out.interface.flush();
        return;
    }

    if (std.mem.eql(u8, args[0], "login")) {
        if (args.len != 2) {
            try out.interface.writeAll("usage: graff mcp login <name>\n");
            try out.interface.flush();
            return;
        }
        const name = args[1];
        const url = if (std.mem.eql(u8, name, "smolify"))
            mcp.smolify_url
        else url: {
            // Global servers are loginable too — the merged set is the same one
            // the session connects from.
            const merged = mcp_config.load(io, arena, Io.Dir.cwd(), mcp_config_path, global_path, home);
            // Say which file is broken before claiming the server is missing:
            // "not configured" for a server that IS configured, in a file that
            // does not parse, sends the user looking in the wrong place.
            try mcp_config.reportInvalid(merged, &out.interface, mcp_config_path, global_path, "", "");
            try out.interface.flush();
            if (!merged.found) std.process.fatal("mcp login: no MCP config; add the remote server first", .{});
            const entry = merged.servers.get(name) orelse std.process.fatal("mcp login: server '{s}' is not configured", .{name});
            if (entry != .object) std.process.fatal("mcp login: server '{s}' has invalid config", .{name});
            const remote = entry.object.get("url") orelse std.process.fatal("mcp login: server '{s}' is not a remote URL server", .{name});
            if (remote != .string or !mcp.validRemoteUrl(remote.string)) std.process.fatal("mcp login: server '{s}' has an invalid URL", .{name});
            break :url remote.string;
        };
        try mcp_oauth.login(io, gpa, arena, home, name, url);
        return;
    }

    if (!std.mem.eql(u8, args[0], "add")) {
        try mcpCliUsage(&out.interface);
        try out.interface.flush();
        return;
    }
    if (args.len < 3) {
        try mcpCliUsage(&out.interface);
        try out.interface.flush();
        return;
    }

    const name = args[1];
    if (std.mem.eql(u8, name, "smolify")) std.process.fatal("mcp add: 'smolify' is a reserved core server", .{});
    if (std.mem.eql(u8, args[2], "--url") or std.mem.startsWith(u8, args[2], "--url=")) {
        const url = if (std.mem.eql(u8, args[2], "--url")) blk: {
            if (args.len < 4) std.process.fatal("mcp add: --url needs an HTTP(S) URL", .{});
            break :blk args[3];
        } else args[2]["--url=".len..];
        if (!mcp.validRemoteUrl(url)) std.process.fatal("mcp add: URL must use HTTPS (HTTP is allowed only for localhost)", .{});
        const first_option: usize = if (std.mem.eql(u8, args[2], "--url")) 4 else 3;
        var headers: std.ArrayList(McpHeaderPair) = .empty;
        defer headers.deinit(arena);
        var j = first_option;
        while (j < args.len) : (j += 1) {
            const arg = args[j];
            const raw = if (std.mem.eql(u8, arg, "--header")) value: {
                j += 1;
                if (j >= args.len) std.process.fatal("mcp add: --header needs KEY=VALUE", .{});
                break :value args[j];
            } else if (std.mem.startsWith(u8, arg, "--header="))
                arg["--header=".len..]
            else
                std.process.fatal("mcp add: unexpected URL option '{s}'", .{arg});
            const eq = std.mem.indexOfScalar(u8, raw, '=') orelse std.process.fatal("mcp add: --header expects KEY=VALUE", .{});
            try headers.append(arena, .{ .key = raw[0..eq], .value = raw[eq + 1 ..] });
        }
        if (!persistMcpUrl(io, arena, name, url, headers.items)) std.process.fatal("could not write .mcp.json", .{});
        try out.interface.print("saved Streamable HTTP MCP server '{s}' to .mcp.json\n", .{name});
        try out.interface.flush();
        return;
    }

    var env_pairs: std.ArrayList(McpEnvPair) = .empty;
    defer env_pairs.deinit(arena);
    var command_index: ?usize = null;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            command_index = i + 1;
            break;
        } else if (std.mem.eql(u8, arg, "--env")) {
            i += 1;
            if (i >= args.len) std.process.fatal("mcp add: --env needs KEY=VALUE", .{});
            const eq = std.mem.indexOfScalar(u8, args[i], '=') orelse std.process.fatal("mcp add: --env expects KEY=VALUE", .{});
            try env_pairs.append(arena, .{ .key = args[i][0..eq], .value = args[i][eq + 1 ..] });
        } else if (std.mem.startsWith(u8, arg, "--env=")) {
            const kv = arg["--env=".len..];
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse std.process.fatal("mcp add: --env expects KEY=VALUE", .{});
            try env_pairs.append(arena, .{ .key = kv[0..eq], .value = kv[eq + 1 ..] });
        } else {
            command_index = i;
            break;
        }
    }
    const ci = command_index orelse std.process.fatal("mcp add: missing command after server name", .{});
    if (ci >= args.len) std.process.fatal("mcp add: missing command after --", .{});
    const command = args[ci];
    const command_args = args[ci + 1 ..];
    if (!persistMcpServerWithEnv(io, arena, name, command, command_args, env_pairs.items))
        std.process.fatal("mcp add: failed to write .mcp.json", .{});
    try out.interface.print("✓ added MCP server {s} to .mcp.json\n  run `graff` and use `/mcp trust` if workspace MCP startup is waiting for consent.\n", .{name});
    try out.interface.flush();
}
test "trustedMcpEntry: only the exact companion shape skips the consent gate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const parse = struct {
        fn p(al: Allocator, s: []const u8) Value {
            return std.json.parseFromSliceLeaky(Value, al, s, .{}) catch unreachable;
        }
    }.p;
    // codedb-pro: the current companion name.
    try std.testing.expect(trustedMcpEntry("codedbpro", parse(a, "{\"command\":\"codedb-pro\",\"args\":[\"--mcp\"]}")));
    try std.testing.expect(trustedMcpEntry("codedbpro", parse(a, "{\"command\":\"codedb-pro\"}")));
    try std.testing.expect(!trustedMcpEntry("codedbpro", parse(a, "{\"command\":\"muonry\"}"))); // wrong binary
    // muonry: the legacy alias, still trusted.
    try std.testing.expect(trustedMcpEntry("muonry", parse(a, "{\"command\":\"muonry\",\"args\":[\"--mcp\"]}")));
    try std.testing.expect(trustedMcpEntry("muonry", parse(a, "{\"command\":\"muonry\"}")));
    try std.testing.expect(trustedMcpEntry("muonry", parse(a, "{\"command\":\"muonry\",\"args\":[]}")));
    try std.testing.expect(!trustedMcpEntry("muonry", parse(a, "{\"command\":\"evil\"}")));
    try std.testing.expect(!trustedMcpEntry("muonry", parse(a, "{\"command\":\"muonry\",\"args\":[\"--mcp\",\"--evil\"]}")));
    try std.testing.expect(!trustedMcpEntry("muonry", parse(a, "{\"command\":\"./muonry\",\"args\":[\"--mcp\"]}")));
    try std.testing.expect(!trustedMcpEntry("other", parse(a, "{\"command\":\"muonry\"}")));
    // Workspace remote servers cross a network/data boundary and need consent
    // just like local commands.
    try std.testing.expect(!trustedMcpEntry("remote", parse(a, "{\"url\":\"https://example.com/mcp\"}")));
    try std.testing.expect(!trustedMcpEntry("local-http", parse(a, "{\"url\":\"http://127.0.0.1:3000/mcp\"}")));
    try std.testing.expect(!trustedMcpEntry("remote", parse(a, "{\"url\":\"file:///tmp/mcp\"}")));
    try std.testing.expect(!trustedMcpEntry("remote", parse(a, "{\"url\":\"https://example.com/mcp\",\"command\":\"evil\"}")));
}
