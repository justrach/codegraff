//! Codex Computer Use bridge for a standalone Graff process (#618).
//!
//! The bundled Computer Use skill is the `node-repl` content variant. Its
//! `@oai/sky` service authenticates the process chain on macOS, so starting
//! either node_repl or the plugin's direct MCP client under Graff fails with
//! "Sender process is not authenticated". Keep that boundary intact: launch
//! Codex's configured node_repl through the sibling, signed Codex sandbox
//! binary and expose its three MCP tools. This is deliberately not a generic
//! JavaScript runtime (ADR 0023); callers only invoke it for that plugin
//! variant, and the resulting MCP server still goes through normal consent.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const server_name = "node_repl";

const node_suffix = "/cua_node/bin/node_repl";
const socket_rel = "Library/Group Containers/2DC432GLL2.com.openai.sky.CUAService/IPC";

fn join(arena: Allocator, a: []const u8, b: []const u8) ?[]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, a, "/"), std.mem.trimStart(u8, b, "/") }) catch null;
}

fn stripComment(raw: []const u8) []const u8 {
    var quoted = false;
    var quote: u8 = 0;
    for (raw, 0..) |c, i| {
        if ((c == '\'' or c == '"') and (i == 0 or raw[i - 1] != '\\')) {
            if (!quoted) {
                quoted = true;
                quote = c;
            } else if (c == quote) quoted = false;
        } else if (c == '#' and !quoted) return std.mem.trim(u8, raw[0..i], " \t\r");
    }
    return std.mem.trim(u8, raw, " \t\r");
}

fn tableName(line: []const u8) ?[]const u8 {
    if (line.len < 3 or line[0] != '[' or line[line.len - 1] != ']') return null;
    return std.mem.trim(u8, line[1 .. line.len - 1], " \t");
}

fn nodeTable(name: []const u8) bool {
    return std.mem.eql(u8, name, "mcp_servers.node_repl") or
        std.mem.eql(u8, name, "mcp_servers.\"node_repl\"") or
        std.mem.eql(u8, name, "mcp_servers.'node_repl'");
}

/// Only accept a plain TOML string. Reject escapes rather than mis-resolving a
/// security-sensitive executable path with a half TOML parser.
fn stringValue(line: []const u8, key: []const u8) ?[]const u8 {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), key)) return null;
    const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (value.len < 2 or value[0] != value[value.len - 1] or (value[0] != '"' and value[0] != '\'')) return null;
    const inner = value[1 .. value.len - 1];
    if (std.mem.indexOfScalar(u8, inner, '\\') != null) return null;
    return inner;
}

fn configuredCommand(text: []const u8) ?[]const u8 {
    var in_node = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = stripComment(raw);
        if (line.len == 0) continue;
        if (tableName(line)) |name| {
            in_node = nodeTable(name);
            continue;
        }
        if (in_node) if (stringValue(line, "command")) |command| return command;
    }
    return null;
}

fn putString(arena: Allocator, object: *std.json.ObjectMap, key: []const u8, value: []const u8) bool {
    object.put(arena, key, .{ .string = arena.dupe(u8, value) catch return false }) catch return false;
    return true;
}

fn appendString(arena: Allocator, array: *std.json.Array, value: []const u8) bool {
    array.append(.{ .string = arena.dupe(u8, value) catch return false }) catch return false;
    return true;
}

fn serverFromCommand(io: Io, arena: Allocator, home: []const u8, project_dir: []const u8, node_command: []const u8) ?Value {
    if (builtin.os.tag != .macos or home.len == 0 or project_dir.len == 0) return null;
    if (!std.mem.endsWith(u8, node_command, node_suffix)) return null;
    const resources = node_command[0 .. node_command.len - node_suffix.len];
    if (resources.len == 0) return null;

    const codex = join(arena, resources, "codex") orelse return null;
    const node = join(arena, resources, "cua_node/bin/node") orelse return null;
    const modules = join(arena, resources, "cua_node/lib/node_modules") orelse return null;
    const codex_home = join(arena, home, ".codex") orelse return null;
    const computer_use_app = join(arena, codex_home, "computer-use/Codex Computer Use.app") orelse return null;
    const socket = join(arena, home, socket_rel) orelse return null;
    if ((Io.Dir.cwd().statFile(io, codex, .{}) catch null) == null or
        (Io.Dir.cwd().statFile(io, node_command, .{}) catch null) == null or
        (Io.Dir.cwd().statFile(io, node, .{}) catch null) == null) return null;

    var args = std.json.Array.init(arena);
    for ([_][]const u8{
        "sandbox",             "-P",   ":danger-full-access", "-C",         project_dir,
        "--allow-unix-socket", socket, "--",                  node_command,
    }) |arg| if (!appendString(arena, &args, arg)) return null;

    const trusted_code = std.fmt.allocPrint(arena, "{s}:{s}", .{ codex_home, modules }) catch return null;
    var env: std.json.ObjectMap = .empty;
    const pairs = [_][2][]const u8{
        .{ "HOME", home },
        .{ "PATH", "/usr/bin:/bin:/usr/sbin:/sbin" },
        .{ "TMPDIR", "/tmp" },
        .{ "CODEX_HOME", codex_home },
        .{ "CODEX_CLI_PATH", codex },
        .{ "NODE_REPL_NODE_PATH", node },
        .{ "NODE_REPL_NODE_MODULE_DIRS", modules },
        .{ "NODE_REPL_TRUSTED_CODE_PATHS", trusted_code },
        .{ "NODE_REPL_TRUSTED_SERVICES", "{\"sky\":\"@oai/sky/service\"}" },
        .{ "NODE_REPL_NATIVE_PIPE_CONNECT_TIMEOUT_MS", "1000" },
        .{ "NODE_REPL_INSTRUCTIONS_USE_CASE_COMPUTER_USE", "Control desktop apps on macOS through Computer Use." },
        .{ "SKY_CUA_SERVICE_PATH", computer_use_app },
    };
    for (pairs) |pair| if (!putString(arena, &env, pair[0], pair[1])) return null;

    var cfg: std.json.ObjectMap = .empty;
    if (!putString(arena, &cfg, "command", codex)) return null;
    cfg.put(arena, "args", .{ .array = args }) catch return null;
    cfg.put(arena, "env", .{ .object = env }) catch return null;
    if (!putString(arena, &cfg, "cwd", project_dir)) return null;
    return .{ .object = cfg };
}

/// Fill `node_repl` only when Graff/user config did not already provide it.
/// True means a usable bridge already existed or was synthesized, so callers
/// should not advertise the plugin's unauthenticated direct client instead.
pub fn merge(io: Io, arena: Allocator, home: []const u8, project_dir: []const u8, servers: *std.json.ObjectMap, found: *bool) bool {
    if (servers.get(server_name) != null) return true;
    const config_path = join(arena, home, ".codex/config.toml") orelse return false;
    const text = Io.Dir.cwd().readFileAlloc(io, config_path, arena, .limited(1 << 20)) catch return false;
    const command = configuredCommand(text) orelse return false;
    const server = serverFromCommand(io, arena, home, project_dir, command) orelse return false;
    servers.put(arena, server_name, server) catch return false;
    found.* = true;
    return true;
}

const testing = std.testing;

test "configuredCommand reads only the node_repl MCP table (#618)" {
    const text =
        \\[mcp_servers.other]
        \\command = "/wrong"
        \\[mcp_servers."node_repl"] # selected
        \\args = []
        \\command = "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl"
        \\[mcp_servers.after]
        \\command = "/also-wrong"
    ;
    try testing.expectEqualStrings(
        "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl",
        configuredCommand(text).?,
    );
    try testing.expect(configuredCommand("[mcp_servers.node_repl]\ncommand = \"bad\\npath\"\n") == null);
}

test "serverFromCommand refuses a lookalike executable tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expect(serverFromCommand(testing.io, arena_state.allocator(), "/home/a", "/repo", "/tmp/node_repl") == null);
}

test "serverFromCommand builds the signed Codex sandbox bridge (#618)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const base = try arena.dupe(u8, buf[0..n]);
    const resources = join(arena, base, "ChatGPT.app/Contents/Resources").?;
    const node_dir = join(arena, resources, "cua_node/bin").?;
    try Io.Dir.cwd().createDirPath(testing.io, node_dir);
    const command = join(arena, resources, "cua_node/bin/node_repl").?;
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = command, .data = "" });
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = join(arena, resources, "cua_node/bin/node").?, .data = "" });
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = join(arena, resources, "codex").?, .data = "" });

    const home = join(arena, base, "home").?;
    const cfg = serverFromCommand(testing.io, arena, home, base, command).?.object;
    try testing.expectEqualStrings(join(arena, resources, "codex").?, cfg.get("command").?.string);
    try testing.expectEqualStrings(base, cfg.get("cwd").?.string);
    const args = cfg.get("args").?.array.items;
    try testing.expectEqualStrings("sandbox", args[0].string);
    try testing.expectEqualStrings(":danger-full-access", args[2].string);
    try testing.expectEqualStrings("--allow-unix-socket", args[5].string);
    try testing.expectEqualStrings(command, args[8].string);
    const env = cfg.get("env").?.object;
    try testing.expectEqualStrings("{\"sky\":\"@oai/sky/service\"}", env.get("NODE_REPL_TRUSTED_SERVICES").?.string);
    try testing.expect(std.mem.endsWith(u8, env.get("SKY_CUA_SERVICE_PATH").?.string, "Codex Computer Use.app"));
}
