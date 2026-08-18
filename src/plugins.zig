//! In-place plugins and foreign-harness MCP (ADR 0007).
//!
//! Grok-build's trick is that it never copies Claude/Codex/Cursor trees into
//! its own folders: it reads `skills/`, `agents/`, and `.mcp.json` where the
//! other harness already installed them. graff's first-run `adopt` copies once
//! and then ignores anything added later. This module is the live scan.
//!
//! Skills stay on-demand (`skill` tool / `/skills`). MCP still needs `/mcp
//! trust` or `--yolo`. Plugin hooks are not run. GRAFF_NO_PLUGINS=1 disables.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const plugin_cap = 32;
const walk_depth: u8 = 4;
const visit_cap = 256;
const file_cap: std.Io.Limit = .limited(1 << 20);
const reserved = "smolify";

pub const Plugin = struct {
    name: []const u8,
    path: []const u8,
    origin: []const u8,
    personal: bool,
    skills: bool = false,
    agents: bool = false,
    mcp: bool = false,
};

fn off() bool {
    return disabled;
}

/// Set from `GRAFF_NO_PLUGINS` at session start. Default off so tests stay hermetic
/// without linking libc getenv.
pub var disabled: bool = false;

pub fn applyEnv(environ_map: anytype) void {
    disabled = environ_map.get("GRAFF_NO_PLUGINS") != null;
}

fn exists(io: Io, path: []const u8) bool {
    return (Io.Dir.cwd().statFile(io, path, .{}) catch null) != null;
}

fn join(arena: Allocator, a: []const u8, b: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ a, b }) catch "";
}

fn skipped(name: []const u8) bool {
    return std.mem.eql(u8, name, "marketplaces") or
        std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, "node_modules");
}

fn existsJoin(io: Io, a: []const u8, b: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ a, b }) catch return false;
    return exists(io, p);
}

fn isPlugin(io: Io, path: []const u8) bool {
    return existsJoin(io, path, ".claude-plugin/plugin.json") or
        existsJoin(io, path, ".grok-plugin/plugin.json") or
        existsJoin(io, path, "plugin.json") or
        existsJoin(io, path, ".mcp.json") or
        existsJoin(io, path, "skills") or
        existsJoin(io, path, "agents");
}

fn walk(io: Io, arena: Allocator, list: *std.ArrayList(Plugin), path: []const u8, origin: []const u8, personal: bool, depth: u8, visits: *usize) void {
    if (list.items.len >= plugin_cap or visits.* >= visit_cap) return;
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    if (isPlugin(io, path)) {
        const skills_p = join(arena, path, "skills");
        const agents_p = join(arena, path, "agents");
        const mcp_p = join(arena, path, ".mcp.json");
        list.append(arena, .{
            .name = arena.dupe(u8, std.fs.path.basename(path)) catch return,
            .path = path,
            .origin = origin,
            .personal = personal,
            .skills = exists(io, skills_p),
            .agents = exists(io, agents_p),
            .mcp = exists(io, mcp_p),
        }) catch {};
        return; // do not treat a plugin's skills/ as a nested plugin
    }
    if (depth == 0) return;
    visits.* += 1;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        if (skipped(entry.name)) continue;
        const child = join(arena, path, entry.name);
        if (child.len == 0) continue;
        walk(io, arena, list, child, origin, personal, depth - 1, visits);
        if (list.items.len >= plugin_cap) return;
    }
}

const Spec = struct { rel: []const u8, origin: []const u8 };

const user_roots = [_]Spec{
    .{ .rel = ".claude/plugins", .origin = "claude" },
    .{ .rel = ".grok/plugins", .origin = "grok" },
    .{ .rel = ".codex/plugins", .origin = "codex" },
    .{ .rel = ".codegraff/plugins", .origin = "graff" },
    .{ .rel = ".harness/plugins", .origin = "harness" },
};

const project_roots = [_]Spec{
    .{ .rel = ".claude/plugins", .origin = "claude" },
    .{ .rel = ".grok/plugins", .origin = "grok" },
    .{ .rel = ".codex/plugins", .origin = "codex" },
    .{ .rel = ".harness/plugins", .origin = "harness" },
};

/// Every plugin tree under the usual Claude/Grok/Codex/graff folders.
/// `project` is the workspace root (cwd in production, a tmp dir in tests).
pub fn discover(io: Io, arena: Allocator, home: ?[]const u8, project: Io.Dir) []const Plugin {
    if (off()) return &.{};
    var list: std.ArrayList(Plugin) = .empty;
    var visits: usize = 0;
    if (home) |h| if (h.len > 0) {
        for (user_roots) |spec| {
            walk(io, arena, &list, join(arena, h, spec.rel), spec.origin, true, walk_depth, &visits);
        }
    };
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = project.realPath(io, &buf) catch 0;
    if (n > 0) {
        const root = arena.dupe(u8, buf[0..n]) catch "";
        if (root.len > 0) {
            for (project_roots) |spec| {
                walk(io, arena, &list, join(arena, root, spec.rel), spec.origin, false, walk_depth, &visits);
            }
        }
    }
    return list.items;
}

pub fn skillDirs(io: Io, arena: Allocator, home: ?[]const u8, project: Io.Dir, personal: bool) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (discover(io, arena, home, project)) |p| {
        if (p.personal != personal or !p.skills) continue;
        const d = join(arena, p.path, "skills");
        if (d.len > 0) out.append(arena, d) catch {};
    }
    return out.items;
}

pub fn agentDirs(io: Io, arena: Allocator, home: ?[]const u8, project: Io.Dir, personal: bool) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (discover(io, arena, home, project)) |p| {
        if (p.personal != personal or !p.agents) continue;
        const d = join(arena, p.path, "agents");
        if (d.len > 0) out.append(arena, d) catch {};
    }
    return out.items;
}

fn pathEq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, a, "/"), std.mem.trimEnd(u8, b, "/"));
}

fn putServers(arena: Allocator, servers: *std.json.ObjectMap, found: *bool, v: ?Value) void {
    const obj = if (v) |x| (if (x == .object) x.object else return) else return;
    var it = obj.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, reserved)) continue;
        if (servers.get(e.key_ptr.*) != null) continue;
        if (e.value_ptr.* != .object) continue;
        servers.put(arena, e.key_ptr.*, e.value_ptr.*) catch continue;
        found.* = true;
    }
}

fn ingest(arena: Allocator, servers: *std.json.ObjectMap, found: *bool, text: []const u8, cwd: ?[]const u8) void {
    const parsed = std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch return;
    if (parsed != .object) return;
    putServers(arena, servers, found, parsed.object.get("mcpServers"));
    if (cwd) |c| {
        const projects = parsed.object.get("projects") orelse return;
        if (projects != .object) return;
        var it = projects.object.iterator();
        while (it.next()) |e| {
            if (!pathEq(e.key_ptr.*, c)) continue;
            if (e.value_ptr.* != .object) continue;
            putServers(arena, servers, found, e.value_ptr.object.get("mcpServers"));
        }
    }
}

fn takeAbs(io: Io, arena: Allocator, servers: *std.json.ObjectMap, found: *bool, path: []const u8, cwd: ?[]const u8) void {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, file_cap) catch return;
    ingest(arena, servers, found, text, cwd);
}

fn takeRel(io: Io, arena: Allocator, dir: Io.Dir, servers: *std.json.ObjectMap, found: *bool, rel: []const u8) void {
    const text = dir.readFileAlloc(io, rel, arena, file_cap) catch return;
    ingest(arena, servers, found, text, null);
}

/// Fill names that graff's own global/project files do not already define.
/// Later-wins stays with those files: this only inserts missing names.
pub fn mergeMcp(io: Io, arena: Allocator, home: []const u8, dir: Io.Dir, servers: *std.json.ObjectMap, found: *bool) void {
    if (off()) return;
    const plugs = discover(io, arena, if (home.len > 0) home else null, dir);
    for (plugs) |p| takeAbs(io, arena, servers, found, join(arena, p.path, ".mcp.json"), null);

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = dir.realPath(io, &buf) catch 0;
    const cwd = if (n > 0) buf[0..n] else null;
    if (home.len > 0) {
        takeAbs(io, arena, servers, found, join(arena, home, ".claude.json"), cwd);
        takeAbs(io, arena, servers, found, join(arena, home, ".claude/settings.json"), null);
        takeAbs(io, arena, servers, found, join(arena, home, ".claude/settings.local.json"), null);
        takeAbs(io, arena, servers, found, join(arena, home, ".cursor/mcp.json"), null);
        takeAbs(io, arena, servers, found, join(arena, home, ".grok/mcp.json"), null);
        if (@import("builtin").os.tag == .macos)
            takeAbs(io, arena, servers, found, join(arena, home, "Library/Application Support/Claude/claude_desktop_config.json"), null)
        else
            takeAbs(io, arena, servers, found, join(arena, home, ".config/Claude/claude_desktop_config.json"), null);
    }
    takeRel(io, arena, dir, servers, found, ".cursor/mcp.json");
    takeRel(io, arena, dir, servers, found, ".claude/settings.json");
    takeRel(io, arena, dir, servers, found, ".claude/settings.local.json");
    takeRel(io, arena, dir, servers, found, ".grok/mcp.json");
}

/// `/plugins` — list discovered plugin trees and where they came from.
pub fn slashCommand(io: Io, arena: Allocator, home: []const u8, line: []const u8, out: *Io.Writer) !bool {
    if (!(std.mem.eql(u8, line, "/plugins") or std.mem.startsWith(u8, line, "/plugins "))) return false;
    if (off()) {
        try out.writeAll("plugins disabled (GRAFF_NO_PLUGINS). unset it and restart to scan Claude/Grok/Codex trees.\n");
        try out.flush();
        return true;
    }
    const list = discover(io, arena, if (home.len > 0) home else null, Io.Dir.cwd());
    if (list.len == 0) {
        try out.writeAll("no plugins discovered. graff reads Claude/Grok/Codex plugin trees in place (skills/, agents/, .mcp.json). nothing to copy; GRAFF_NO_PLUGINS=1 disables.\n");
        try out.flush();
        return true;
    }
    try out.print("{d} plugin(s) (in-place, not copied):\n", .{list.len});
    for (list) |p| {
        try out.print("  {s}  [{s}/{s}]", .{ p.name, p.origin, if (p.personal) "user" else "project" });
        if (p.skills) try out.writeAll(" skills");
        if (p.agents) try out.writeAll(" agents");
        if (p.mcp) try out.writeAll(" mcp");
        try out.print("  {s}\n", .{p.path});
    }
    try out.writeAll("skills load on demand (skill tool / /skills). MCP still needs /mcp trust or --yolo.\n");
    try out.flush();
    return true;
}

const testing = std.testing;

fn tmpBase(io: Io, tmp: *testing.TmpDir, arena: Allocator) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    return arena.dupe(u8, buf[0..n]);
}

test "discover: a Claude plugin.json tree is a plugin; marketplaces are not" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const base = try tmpBase(io, &tmp, arena);
    const home = join(arena, base, "home");
    const plug = join(arena, home, ".claude/plugins/demo");
    try Io.Dir.cwd().createDirPath(io, join(arena, plug, ".claude-plugin"));
    try Io.Dir.cwd().createDirPath(io, join(arena, plug, "skills/demo-skill"));
    try Io.Dir.cwd().createDirPath(io, join(arena, home, ".claude/plugins/marketplaces/skip-me"));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = join(arena, plug, ".claude-plugin/plugin.json"), .data = "{\"name\":\"demo\"}" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = join(arena, plug, "skills/demo-skill/SKILL.md"), .data = "---\nname: demo-skill\ndescription: d\n---\nbody\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = join(arena, home, ".claude/plugins/marketplaces/skip-me/plugin.json"), .data = "{}" });

    const list = discover(io, arena, home, tmp.dir);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("demo", list[0].name);
    try testing.expectEqualStrings("claude", list[0].origin);
    try testing.expect(list[0].personal);
    try testing.expect(list[0].skills);
    try testing.expect(!list[0].mcp);
    const dirs = skillDirs(io, arena, home, tmp.dir, true);
    try testing.expectEqual(@as(usize, 1), dirs.len);
    try testing.expect(std.mem.endsWith(u8, dirs[0], "demo/skills"));
}

test "discover: walks Claude plugins/cache two levels down" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const base = try tmpBase(io, &tmp, arena);
    const home = join(arena, base, "home");
    const nested = join(arena, home, ".claude/plugins/cache/official/pack/1.0.0");
    try Io.Dir.cwd().createDirPath(io, join(arena, nested, "agents"));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = join(arena, nested, "plugin.json"), .data = "{\"name\":\"pack\"}" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = join(arena, nested, "agents/reviewer.md"), .data = "---\nname: pack-reviewer\n---\nbe careful\n" });

    const list = discover(io, arena, home, tmp.dir);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("1.0.0", list[0].name);
    try testing.expect(list[0].agents);
    const agents = agentDirs(io, arena, home, tmp.dir, true);
    try testing.expectEqual(@as(usize, 1), agents.len);
}

test "mergeMcp: plugin and Cursor MCP fill missing names; graff config wins" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const base = try tmpBase(io, &tmp, arena);
    const home = join(arena, base, "home");
    const plug = join(arena, home, ".grok/plugins/tools");
    try Io.Dir.cwd().createDirPath(io, plug);
    try Io.Dir.cwd().createDirPath(io, join(arena, home, ".cursor"));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = join(arena, plug, ".mcp.json"), .data = "{\"mcpServers\":{\"from-plugin\":{\"command\":\"p\"},\"shared\":{\"command\":\"plugin-loses\"}}}" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = join(arena, home, ".cursor/mcp.json"), .data = "{\"mcpServers\":{\"from-cursor\":{\"url\":\"https://cursor.example/mcp\"}}}" });

    var servers: std.json.ObjectMap = .empty;
    try servers.put(arena, "shared", .{ .object = blk: {
        var o: std.json.ObjectMap = .empty;
        try o.put(arena, "command", .{ .string = "graff-wins" });
        break :blk o;
    } });
    var found = false;
    mergeMcp(io, arena, home, tmp.dir, &servers, &found);
    try testing.expect(found);
    try testing.expect(servers.get("from-plugin") != null);
    try testing.expect(servers.get("from-cursor") != null);
    try testing.expectEqualStrings("graff-wins", servers.get("shared").?.object.get("command").?.string);
}

test "mergeMcp: ~/.claude.json project-scoped servers match this cwd" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const base = try tmpBase(io, &tmp, arena);
    const home = join(arena, base, "home");
    try Io.Dir.cwd().createDirPath(io, home);
    const head = "{\"mcpServers\":{\"root\":{\"command\":\"r\"}},\"projects\":{\"";
    const tail = "\":{\"mcpServers\":{\"here\":{\"command\":\"h\"}}},\"/other\":{\"mcpServers\":{\"nope\":{\"command\":\"x\"}}}}}";
    const payload = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ head, base, tail });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = join(arena, home, ".claude.json"), .data = payload });

    var servers: std.json.ObjectMap = .empty;
    var found = false;
    mergeMcp(io, arena, home, tmp.dir, &servers, &found);
    try testing.expect(found);
    try testing.expect(servers.get("root") != null);
    try testing.expect(servers.get("here") != null);
    try testing.expect(servers.get("nope") == null);
}

test "slashCommand: /plugins lists origin and refuses unrelated lines" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expect(!(try slashCommand(testing.io, arena_state.allocator(), "", "/skills", &aw.writer)));
    try testing.expect(try slashCommand(testing.io, arena_state.allocator(), "", "/plugins", &aw.writer));
    try testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "plugin") != null);
}
