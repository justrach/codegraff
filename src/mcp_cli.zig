//! The `graff mcp` CLI subcommand: list/add MCP servers in .mcp.json, plus the
//! trusted-companion-entry check + startup untrusted-server count that gate the
//! MCP consent prompt. Split out of main.zig (600-line goal). Back-imports main
//! for mcp_config_path (.mcp.json) and the companion_servers allowlist. main
//! aliases countMcpServers / persistMcpServer / mcpCommand back.
//!
//! Reads go through mcp_config.zig, so `list`, `login` and the consent count
//! all see the workspace file merged with the user-level
//! `~/.codegraff/mcp.json` (#345). Writes deliberately do not: `mcp add` and
//! the `persistMcp*` helpers target the project .mcp.json, so adding a server
//! to one repository never edits every other one, unless the person asks
//! with `graff mcp add … --everywhere`.

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

/// Where `graff mcp add` writes: the project file, or with `--everywhere` the
/// user-level file every workspace reads (Harness included, through graff).
var write_path: []const u8 = mcp_config_path;

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
    if (Io.Dir.cwd().readFileAlloc(io, write_path, arena, .limited(1 << 20))) |text| {
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

    const f = Io.Dir.cwd().createFile(io, write_path, .{}) catch return false;
    defer f.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    fw.interface.writeAll(aw.writer.buffered()) catch return false;
    fw.interface.flush() catch return false;
    return true;
}

/// Save one ready-made entry (`command`/`args`/`env` or `url`/`headers`) into
/// the project .mcp.json, keeping every other server. False on any error.
pub fn persistEntry(io: Io, arena: Allocator, name: []const u8, entry: std.json.ObjectMap) bool {
    var root_obj: std.json.ObjectMap = .empty;
    if (Io.Dir.cwd().readFileAlloc(io, write_path, arena, .limited(1 << 20))) |text| {
        if (std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always })) |v| {
            if (v == .object) root_obj = v.object;
        } else |_| {}
    } else |_| {}
    var servers: std.json.ObjectMap = .empty;
    if (root_obj.get("mcpServers")) |m| if (m == .object) {
        servers = m.object;
    };
    servers.put(arena, name, .{ .object = entry }) catch return false;
    root_obj.put(arena, "mcpServers", .{ .object = servers }) catch return false;
    var aw: Io.Writer.Allocating = .init(arena);
    var stringify: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    stringify.write(Value{ .object = root_obj }) catch return false;
    const file = Io.Dir.cwd().createFile(io, write_path, .{}) catch return false;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    writer.interface.writeAll(aw.writer.buffered()) catch return false;
    writer.interface.writeByte('\n') catch return false;
    writer.interface.flush() catch return false;
    return true;
}

/// Connect to a just-saved server and say what it offers, or what to do next.
/// A server that wants OAuth is signed in on the spot when a person is at the
/// terminal; an agent's shell gets the `graff mcp login` line instead.
fn checkSaved(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, name: []const u8, out: *Io.Writer) !void {
    const text = Io.Dir.cwd().readFileAlloc(io, write_path, arena, .limited(1 << 20)) catch return;
    const v = std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch return;
    const servers = if (v == .object) v.object.get("mcpServers") orelse return else return;
    const entry = if (servers == .object) servers.object.get(name) orelse return else return;
    if (entry != .object) return;
    const add = @import("mcp_add.zig");
    try out.print("  connecting to {s}…\n", .{name});
    try out.flush();
    var result = add.verify(io, gpa, arena, home, .{ .name = name, .cfg = entry.object });
    if (result == .needs_login) {
        const url = if (entry.object.get("url")) |u| (if (u == .string) u.string else "") else "";
        if (url.len == 0 or !(Io.File.stdin().isTty(io) catch false)) {
            try out.print("  {s} needs sign-in: run `graff mcp login {s}`\n", .{ name, name });
            return;
        }
        try out.print("  {s} needs sign-in; opening the OAuth flow\n", .{name});
        try out.flush();
        mcp_oauth.login(io, gpa, arena, home, name, url) catch return;
        result = add.verify(io, gpa, arena, home, .{ .name = name, .cfg = entry.object });
    }
    switch (result) {
        .ok => |ok| try out.print("✓ {s} works: {d} tool(s){s}{s}\n", .{ name, ok.tools, if (ok.sample.len > 0) " — " else "", ok.sample }),
        .needs_login => try out.print("  {s} still needs sign-in: run `graff mcp login {s}`\n", .{ name, name }),
        .failed => |err| try out.print("✗ saved {s}, but it did not connect ({t}): {s}\n  fix it and re-run `graff mcp add`, or remove it from {s}\n", .{ name, err, add.failureHint(err, entry.object), write_path }),
    }
}

/// Persist a native Streamable HTTP entry. Headers are optional and intended
/// for static bearer/API tokens; OAuth-capable servers can remain anonymous
/// until an authorization flow is configured.
pub fn persistMcpUrl(io: Io, arena: Allocator, name: []const u8, url: []const u8, headers: []const McpHeaderPair) bool {
    var root_obj: std.json.ObjectMap = .empty;
    if (Io.Dir.cwd().readFileAlloc(io, write_path, arena, .limited(1 << 20))) |text| {
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
    const file = Io.Dir.cwd().createFile(io, write_path, .{}) catch return false;
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
        \\  graff mcp install [--directory PATH] [--port N]   install HTTP service and client entries
        \\  graff mcp serve [--http] [--port N] [--model NAME] [--yolo]   expose run_task over stdio or HTTP
        \\  graff mcp                      list servers in .mcp.json + ~/.codegraff/mcp.json
        \\  graff mcp list --json          the same as JSON, with each server's source (no secret values)
        \\  graff mcp import               copy setup and import this project's Claude history
        \\  graff mcp import-session <id>  import only one Claude conversation into graff
        \\  graff mcp add <url | @scope/package | uvx:package | '{json}' | ->   infer, save, then connect to check it
        \\  graff mcp add <name> [--env K=V] [--header K=V]   look up a server (codegraff.com/mcp, then the MCP registry)
        \\  graff mcp add … --everywhere   save to ~/.codegraff/mcp.json (every project) instead of ./.mcp.json
        \\  graff mcp add <name> --url <https://...> [--header KEY=VALUE ...]
        \\  graff mcp login <name>        OAuth login for a remote server
        \\  graff mcp add <name> [--env KEY=VALUE ...] -- <command> [args...]
        \\  graff mcp add <name> <command> [args...]
        \\
        \\examples:
        \\  graff mcp add mobbin --url https://api.mobbin.com/mcp
        \\  graff mcp login mobbin
        \\  graff mcp add context7 -- npx -y @upstash/context7-mcp
        \\  graff mcp add playwright -- npx -y @playwright/mcp
        \\  graff mcp add sentry --env SENTRY_AUTH_TOKEN=... -- npx -y @sentry/mcp-server
        \\
    );
}

/// `add <url|package|json|->` and `add <name> <url|package>`. False when the
/// arguments are an explicit form for the caller to parse.
fn addInferred(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, environ_map: anytype, add_args: []const []const u8, name_flag: ?[]const u8, verify_after: bool, out: *Io.Writer) !bool {
    const add = @import("mcp_add.zig");
    const catalog = @import("mcp_catalog.zig");
    var entries: []const add.Named = &.{};
    const given = if (add_args.len >= 2 and catalog.isBareName(add_args[1])) try catalog.parseGiven(arena, add_args[2..]) else null;
    if (given) |g| {
        // `add linear`, `add brave-search --env BRAVE_API_KEY=…`: look the name up.
        entries = try arena.dupe(add.Named, &.{try catalog.resolve(io, gpa, arena, environ_map, add_args[1], name_flag, g, out)});
    } else if (add_args.len == 2) {
        const token = add_args[1];
        if (std.mem.eql(u8, token, "-") or std.mem.startsWith(u8, std.mem.trimStart(u8, token, " \t\r\n"), "{")) {
            const text = if (std.mem.eql(u8, token, "-")) blk: {
                var ibuf: [4096]u8 = undefined;
                var in = Io.File.stdin().reader(io, &ibuf);
                break :blk in.interface.allocRemaining(arena, .limited(1 << 20)) catch std.process.fatal("mcp add: could not read JSON from stdin", .{});
            } else token;
            entries = add.fromJson(arena, text, name_flag) catch |err| std.process.fatal("mcp add: could not read that JSON ({t}); paste a Claude/Cursor `mcpServers` block, a VS Code `servers` block, or one entry with --name", .{err});
        } else if (try add.infer(arena, token, name_flag)) |one| {
            entries = try arena.dupe(add.Named, &.{one});
        } else {
            std.process.fatal("mcp add: can't tell what '{s}' is. Give a URL, an npm package (@scope/name), uvx:<python-package>, a JSON snippet, or `graff mcp add <name> -- <command> [args...]`", .{token});
        }
    } else if (add_args.len == 3 and !std.mem.startsWith(u8, add_args[2], "-") and
        (add.isUrl(add_args[2]) or add_args[2][0] == '@' or std.mem.startsWith(u8, add_args[2], "npx:") or std.mem.startsWith(u8, add_args[2], "uvx:")))
    {
        const one = (try add.infer(arena, add_args[2], add_args[1])) orelse return false;
        entries = try arena.dupe(add.Named, &.{one});
    } else return false;
    for (entries) |e| {
        if (e.cfg.get("url")) |u| if (!mcp.validRemoteUrl(u.string)) std.process.fatal("mcp add: {s}: URL must use HTTPS (HTTP is allowed only for localhost)", .{e.name});
        if (!persistEntry(io, arena, e.name, e.cfg)) std.process.fatal("mcp add: could not write {s}", .{write_path});
        if (e.cfg.get("url")) |u| {
            try out.print("✓ added {s} ({s}) to {s}\n", .{ e.name, u.string, write_path });
        } else {
            try out.print("✓ added {s} (", .{e.name});
            try out.writeAll(e.cfg.get("command").?.string);
            if (e.cfg.get("args")) |argv| for (argv.array.items) |x| try out.print(" {s}", .{x.string});
            try out.print(") to {s}\n", .{write_path});
        }
        if (verify_after) try checkSaved(io, gpa, arena, home, e.name, out);
    }
    try out.writeAll("  a running session connects new servers before its next request.\n");
    try out.flush();
    return true;
}

pub fn mcpCommand(io: Io, gpa: Allocator, arena: Allocator, home: []const u8, environ_map: anytype, args: []const []const u8) !void {
    if (args.len > 0 and std.mem.eql(u8, args[0], "install")) {
        // The installer sets up a launchd/systemd service; spawning it on
        // Windows failed with a bare FileNotFound.
        if (@import("builtin").os.tag == .windows) {
            var ebuf: [512]u8 = undefined;
            var ew = Io.File.stderr().writer(io, &ebuf);
            try ew.interface.writeAll("graff mcp install sets up a background service on macOS and Linux only.\nOn Windows, add graff to an MCP client with the command `graff mcp serve`.\n");
            try ew.interface.flush();
            std.process.exit(1);
        }
        const exe = try std.process.executablePathAlloc(io, arena);
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ "python3", "-c", @embedFile("mcp_installer"), "--binary", exe });
        try argv.appendSlice(arena, args[1..]);
        const result = try @import("process_runner.zig").runCappedWithOptions(arena, io, argv.items, 16384, 4096, 30000, .{ .environ_map = environ_map });
        var buffer: [4096]u8 = undefined;
        var writer = Io.File.stderr().writer(io, &buffer);
        try writer.interface.writeAll(result.stdout);
        try writer.interface.writeAll(result.stderr);
        try writer.interface.flush();
        if (!@import("process_runner.zig").ranOk(result)) return error.McpInstallFailed;
        return;
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "serve")) {
        try @import("mcp_server.zig").run(io, gpa, environ_map, args[1..]);
        return;
    }
    var obuf: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(io, &obuf);
    // Reads (list/login) see project + global; writes stay project-local.
    const global_path = mcp_config.globalPath(arena, home, environ_map);

    if (args.len > 0 and (std.mem.eql(u8, args[0], "import") or std.mem.eql(u8, args[0], "import-claude") or std.mem.eql(u8, args[0], "adopt") or std.mem.eql(u8, args[0], "import-session"))) {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = Io.Dir.cwd().realPath(io, &cwd_buf) catch 0;
        const cwd = if (n > 0) cwd_buf[0..n] else ".";
        if (std.mem.eql(u8, args[0], "import-session")) {
            if (args.len != 2) return error.InvalidArguments;
            const config = environ_map.get("CLAUDE_CONFIG_DIR") orelse try std.fmt.allocPrint(arena, "{s}/.claude", .{home});
            const name = try @import("adopt_sessions.zig").importOne(io, arena, config, cwd, args[1], environ_map.get("CLAUDE_CODE_PROJECT_DIR_NAME"));
            try out.interface.print("{s}\n", .{name});
            try out.interface.flush();
            return;
        }
        try @import("adopt.zig").command(io, arena, home, cwd, &out.interface);
        return;
    }

    if (args.len == 0 or std.mem.eql(u8, args[0], "list")) {
        const merged = mcp_config.load(io, arena, Io.Dir.cwd(), mcp_config_path, global_path, home, mcp_config.isEnvOverride(environ_map));
        if (args.len > 1 and std.mem.eql(u8, args[1], "--json")) {
            try @import("mcp_list_json.zig").write(arena, merged, mcp_config_path, global_path, &out.interface);
            try out.interface.flush();
            return;
        }
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

    if (std.mem.eql(u8, args[0], "attach") or std.mem.eql(u8, args[0], "broker")) {
        // Internal: the relay and the per-machine broker of a `"shared": true` server.
        const share = @import("mcp_share.zig");
        const idle_s = std.fmt.parseInt(u32, environ_map.get("GRAFF_MCP_SHARED_IDLE_S") orelse "60", 10) catch 60;
        const run = if (args[0][0] == 'a') share.attach(io, gpa, arena, home, args[1..]) else share.broker(io, gpa, arena, home, idle_s, args[1..]);
        run catch |err| std.process.fatal("mcp {s}: {t}", .{ args[0], err });
        return;
    }

    if (std.mem.eql(u8, args[0], "login")) {
        if (args.len != 2) {
            try out.interface.writeAll("usage: graff mcp login <name>\n");
            try out.interface.flush();
            return;
        }
        const name = args[1];
        // Global servers are loginable too — the merged set is the same one
        // the session connects from.
        const merged = mcp_config.load(io, arena, Io.Dir.cwd(), mcp_config_path, global_path, home, mcp_config.isEnvOverride(environ_map));
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
        try mcp_oauth.login(io, gpa, arena, home, name, remote.string);
        return;
    }

    if (!std.mem.eql(u8, args[0], "add")) {
        try mcpCliUsage(&out.interface);
        try out.interface.flush();
        return;
    }
    // `--no-verify` and `--name N` apply to every form; stop at `--`, whose
    // tail belongs to the server's own command line.
    var verify_after = true;
    var name_flag: ?[]const u8 = null;
    var kept: std.ArrayList([]const u8) = .empty;
    try kept.append(arena, "add");
    {
        var k: usize = 1;
        while (k < args.len) : (k += 1) {
            if (std.mem.eql(u8, args[k], "--")) {
                try kept.appendSlice(arena, args[k..]);
                break;
            } else if (std.mem.eql(u8, args[k], "--no-verify")) {
                verify_after = false;
            } else if (std.mem.eql(u8, args[k], "--everywhere") or std.mem.eql(u8, args[k], "--global")) {
                write_path = mcp_config.globalPath(arena, home, environ_map) orelse
                    std.process.fatal("mcp add: --everywhere needs a home directory", .{});
                if (std.fs.path.dirname(write_path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
            } else if (std.mem.eql(u8, args[k], "--name") and k + 1 < args.len) {
                k += 1;
                name_flag = args[k];
            } else try kept.append(arena, args[k]);
        }
    }
    const add_args = kept.items;
    if (try addInferred(io, gpa, arena, home, environ_map, add_args, name_flag, verify_after, &out.interface)) return;
    if (add_args.len < 3) {
        try mcpCliUsage(&out.interface);
        try out.interface.flush();
        return;
    }

    const name = add_args[1];
    if (std.mem.eql(u8, add_args[2], "--url") or std.mem.startsWith(u8, add_args[2], "--url=")) {
        const url = if (std.mem.eql(u8, add_args[2], "--url")) blk: {
            if (add_args.len < 4) std.process.fatal("mcp add: --url needs an HTTP(S) URL", .{});
            break :blk add_args[3];
        } else add_args[2]["--url=".len..];
        if (!mcp.validRemoteUrl(url)) std.process.fatal("mcp add: URL must use HTTPS (HTTP is allowed only for localhost)", .{});
        const first_option: usize = if (std.mem.eql(u8, add_args[2], "--url")) 4 else 3;
        var headers: std.ArrayList(McpHeaderPair) = .empty;
        defer headers.deinit(arena);
        var j = first_option;
        while (j < add_args.len) : (j += 1) {
            const arg = add_args[j];
            const raw = if (std.mem.eql(u8, arg, "--header")) value: {
                j += 1;
                if (j >= add_args.len) std.process.fatal("mcp add: --header needs KEY=VALUE", .{});
                break :value add_args[j];
            } else if (std.mem.startsWith(u8, arg, "--header="))
                arg["--header=".len..]
            else
                std.process.fatal("mcp add: unexpected URL option '{s}'", .{arg});
            const eq = std.mem.indexOfScalar(u8, raw, '=') orelse std.process.fatal("mcp add: --header expects KEY=VALUE", .{});
            try headers.append(arena, .{ .key = raw[0..eq], .value = raw[eq + 1 ..] });
        }
        if (!persistMcpUrl(io, arena, name, url, headers.items)) std.process.fatal("could not write {s}", .{write_path});
        try out.interface.print("saved Streamable HTTP MCP server '{s}' to {s}\n", .{ name, write_path });
        if (verify_after) try checkSaved(io, gpa, arena, home, name, &out.interface);
        try out.interface.flush();
        return;
    }

    var env_pairs: std.ArrayList(McpEnvPair) = .empty;
    defer env_pairs.deinit(arena);
    var command_index: ?usize = null;
    var i: usize = 2;
    while (i < add_args.len) : (i += 1) {
        const arg = add_args[i];
        if (std.mem.eql(u8, arg, "--")) {
            command_index = i + 1;
            break;
        } else if (std.mem.eql(u8, arg, "--env")) {
            i += 1;
            if (i >= add_args.len) std.process.fatal("mcp add: --env needs KEY=VALUE", .{});
            const eq = std.mem.indexOfScalar(u8, add_args[i], '=') orelse std.process.fatal("mcp add: --env expects KEY=VALUE", .{});
            try env_pairs.append(arena, .{ .key = add_args[i][0..eq], .value = add_args[i][eq + 1 ..] });
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
    if (ci >= add_args.len) std.process.fatal("mcp add: missing command after --", .{});
    var command = add_args[ci];
    var command_args = add_args[ci + 1 ..];
    // `add <name> --env K=V @scope/pkg`: a lone package token, not a program.
    if (command_args.len == 0 and (command[0] == '@' or std.mem.startsWith(u8, command, "npx:") or std.mem.startsWith(u8, command, "uvx:"))) {
        if (@import("mcp_add.zig").packageSpec(command)) |spec| {
            command_args = if (spec.runner == .npx) try arena.dupe([]const u8, &.{ "-y", spec.pkg }) else try arena.dupe([]const u8, &.{spec.pkg});
            command = if (spec.runner == .npx) "npx" else "uvx";
        }
    }
    if (!persistMcpServerWithEnv(io, arena, name, command, command_args, env_pairs.items))
        std.process.fatal("mcp add: failed to write {s}", .{write_path});
    try out.interface.print("✓ added MCP server {s} to {s}\n", .{ name, write_path });
    if (verify_after) try checkSaved(io, gpa, arena, home, name, &out.interface);
    try out.interface.writeAll("  a running session connects it before its next request; otherwise `/mcp trust` if startup is waiting for consent.\n");
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
