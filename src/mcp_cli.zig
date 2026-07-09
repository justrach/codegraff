//! The `graff mcp` CLI subcommand: list/add MCP servers in .mcp.json, plus the
//! trusted-companion-entry check + startup untrusted-server count that gate the
//! MCP consent prompt. Split out of main.zig (600-line goal). Back-imports main
//! for mcp_config_path (.mcp.json) and the companion_servers allowlist. main
//! aliases countMcpServers / persistMcpServer / mcpCommand back.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const root = @import("main.zig");
const mcp_config_path = root.mcp_config_path;
const companion_servers = root.companion_servers;

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

/// Count the workspace .mcp.json servers that actually need consent at
/// startup (0 if none/missing; trusted companion entries are exempt — see
/// trustedMcpEntry). Used to gate auto-spawning untrusted workspace servers.
pub fn countMcpServers(io: Io, arena: Allocator) usize {
    const data = Io.Dir.cwd().readFileAlloc(io, mcp_config_path, arena, .limited(1 << 20)) catch return 0;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return 0;
    if (v != .object) return 0;
    const servers = v.object.get("mcpServers") orelse return 0;
    if (servers != .object) return 0;
    var n: usize = 0;
    var it = servers.object.iterator();
    while (it.next()) |entry| {
        if (!trustedMcpEntry(entry.key_ptr.*, entry.value_ptr.*)) n += 1;
    }
    return n;
}

/// Best-effort write of a server entry into .mcp.json (so `/mcp add` survives
/// a restart). Merges into any existing config. Returns false on any error.
const McpEnvPair = struct { key: []const u8, value: []const u8 };

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

fn mcpCliUsage(w: *Io.Writer) !void {
    try w.writeAll(
        \\usage:
        \\  graff mcp                      list servers in .mcp.json
        \\  graff mcp add <name> [--env KEY=VALUE ...] -- <command> [args...]
        \\  graff mcp add <name> <command> [args...]
        \\
        \\examples:
        \\  graff mcp add context7 -- npx -y @upstash/context7-mcp
        \\  graff mcp add playwright -- npx -y @playwright/mcp
        \\  graff mcp add sentry --env SENTRY_AUTH_TOKEN=... -- npx -y @sentry/mcp-server
        \\
    );
}

pub fn mcpCommand(io: Io, arena: Allocator, args: []const []const u8) !void {
    var obuf: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(io, &obuf);

    if (args.len == 0 or std.mem.eql(u8, args[0], "list")) {
        const data = Io.Dir.cwd().readFileAlloc(io, mcp_config_path, arena, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => {
                try out.interface.writeAll("no .mcp.json yet. Add one with `graff mcp add <name> -- <command> [args...]`.\n");
                try out.interface.flush();
                return;
            },
            else => return err,
        };
        const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch {
            try out.interface.writeAll(".mcp.json is not valid JSON.\n");
            try out.interface.flush();
            return;
        };
        const servers = if (v == .object) v.object.get("mcpServers") else null;
        if (servers == null or servers.? != .object or servers.?.object.count() == 0) {
            try out.interface.writeAll("no MCP servers configured. Add one with `graff mcp add <name> -- <command> [args...]`.\n");
        } else {
            try out.interface.print("{d} MCP server(s) in .mcp.json:\n", .{servers.?.object.count()});
            var it = servers.?.object.iterator();
            while (it.next()) |entry| {
                const cfg = entry.value_ptr.*;
                if (cfg != .object) continue;
                const command = if (cfg.object.get("command")) |c| if (c == .string) c.string else "?" else "?";
                try out.interface.print("  {s}: {s}", .{ entry.key_ptr.*, command });
                if (cfg.object.get("args")) |argv| if (argv == .array) for (argv.array.items) |a| {
                    if (a == .string) try out.interface.print(" {s}", .{a.string});
                };
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
}
