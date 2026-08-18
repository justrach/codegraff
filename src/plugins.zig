//! In-place plugins and foreign-harness MCP (ADR 0007).
//!
//! Grok-build's trick is that it never copies Claude/Codex/Cursor trees into
//! its own folders: it reads `skills/`, `agents/`, and `.mcp.json` where the
//! other harness already installed them. graff's first-run `adopt` copies once
//! and then ignores anything added later. This module is the live scan.
//!
//! Skills stay on-demand (`skill` tool / `/skills`), including Claude
//! `commands/*.md` and a plugin-root `SKILL.md`. MCP still needs `/mcp
//! trust` or `--yolo`. Plugin hooks are not run. GRAFF_NO_PLUGINS=1 disables.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const layout = @import("plugin_layout.zig");

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
    commands: bool = false,
    /// Filled by the walk so later skill/agent/MCP merges do not inspect again.
    skill_dirs: []const []const u8 = &.{},
    agent_dirs: []const []const u8 = &.{},
    root_skill: ?layout.RootSkill = null,
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

fn join(arena: Allocator, a: []const u8, b: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ a, b }) catch "";
}

fn skipped(name: []const u8) bool {
    return std.mem.eql(u8, name, "marketplaces") or
        std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, "node_modules");
}

/// True when this directory entry is enough to treat the parent as a plugin,
/// so the walk does not `stat` ten marker paths per visited folder.
fn pluginMarker(name: []const u8) bool {
    return std.mem.eql(u8, name, ".cursor-plugin") or
        std.mem.eql(u8, name, ".claude-plugin") or
        std.mem.eql(u8, name, ".grok-plugin") or
        std.mem.eql(u8, name, "plugin.json") or
        std.mem.eql(u8, name, ".mcp.json") or
        std.mem.eql(u8, name, "mcp.json") or
        std.mem.eql(u8, name, "skills") or
        std.mem.eql(u8, name, "agents") or
        std.mem.eql(u8, name, "commands") or
        std.mem.eql(u8, name, "SKILL.md");
}

fn walk(io: Io, arena: Allocator, list: *std.ArrayList(Plugin), path: []const u8, origin: []const u8, personal: bool, depth: u8, visits: *usize) void {
    if (list.items.len >= plugin_cap or visits.* >= visit_cap) return;
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var children: std.ArrayList([]const u8) = .empty;
    var plugin_here = false;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (pluginMarker(entry.name)) plugin_here = true;
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        if (skipped(entry.name)) continue;
        const child = join(arena, path, entry.name);
        if (child.len == 0) continue;
        children.append(arena, child) catch {};
    }
    if (plugin_here) {
        const lay = layout.inspect(io, arena, path);
        list.append(arena, .{
            .name = if (lay.name.len > 0) lay.name else std.fs.path.basename(path),
            .path = path,
            .origin = origin,
            .personal = personal,
            .skills = lay.skill_dirs.len > 0 or lay.root_skill != null,
            .agents = lay.agent_dirs.len > 0,
            .mcp = lay.has_mcp,
            .commands = lay.has_commands,
            .skill_dirs = lay.skill_dirs,
            .agent_dirs = lay.agent_dirs,
            .root_skill = lay.root_skill,
        }) catch {};
        return; // do not treat a plugin's skills/ as a nested plugin
    }
    if (depth == 0) return;
    visits.* += 1;
    for (children.items) |child| {
        walk(io, arena, list, child, origin, personal, depth - 1, visits);
        if (list.items.len >= plugin_cap) return;
    }
}

const Spec = struct { rel: []const u8, origin: []const u8 };

const user_roots = [_]Spec{
    .{ .rel = ".cursor/plugins", .origin = "cursor" },
    .{ .rel = ".claude/plugins", .origin = "claude" },
    .{ .rel = ".grok/plugins", .origin = "grok" },
    .{ .rel = ".codex/plugins", .origin = "codex" },
    .{ .rel = ".codegraff/plugins", .origin = "graff" },
    .{ .rel = ".harness/plugins", .origin = "harness" },
};

const project_roots = [_]Spec{
    .{ .rel = ".cursor/plugins", .origin = "cursor" },
    .{ .rel = ".claude/plugins", .origin = "claude" },
    .{ .rel = ".grok/plugins", .origin = "grok" },
    .{ .rel = ".codex/plugins", .origin = "codex" },
    .{ .rel = ".harness/plugins", .origin = "harness" },
};

/// Every plugin tree under the usual Cursor/Claude/Grok/Codex/graff folders.
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
        if (p.personal != personal) continue;
        out.appendSlice(arena, p.skill_dirs) catch {};
    }
    return out.items;
}

pub fn rootSkills(io: Io, arena: Allocator, home: ?[]const u8, project: Io.Dir, personal: bool) []const layout.RootSkill {
    var out: std.ArrayList(layout.RootSkill) = .empty;
    for (discover(io, arena, home, project)) |p| {
        if (p.personal != personal) continue;
        if (p.root_skill) |rs| out.append(arena, rs) catch {};
    }
    return out.items;
}

pub fn agentDirs(io: Io, arena: Allocator, home: ?[]const u8, project: Io.Dir, personal: bool) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (discover(io, arena, home, project)) |p| {
        if (p.personal != personal) continue;
        out.appendSlice(arena, p.agent_dirs) catch {};
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
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = dir.realPath(io, &buf) catch 0;
    const cwd = if (n > 0) buf[0..n] else null;
    const plugs = discover(io, arena, if (home.len > 0) home else null, dir);
    for (plugs) |p| layout.mergeMcp(io, arena, p.path, cwd orelse "", servers, found);
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
        try out.writeAll("plugins disabled (GRAFF_NO_PLUGINS). unset it and restart to scan Cursor/Claude/Grok/Codex trees.\n");
        try out.flush();
        return true;
    }
    const rest = std.mem.trim(u8, line["/plugins".len..], " \t");
    const list = discover(io, arena, if (home.len > 0) home else null, Io.Dir.cwd());
    if (std.mem.startsWith(u8, rest, "load ")) {
        const want = std.mem.trim(u8, rest["load ".len..], " \t");
        for (list) |p| {
            if (!std.ascii.eqlIgnoreCase(p.name, want)) continue;
            try out.print("{s}  [{s}/{s}]  {s}\n", .{ p.name, p.origin, if (p.personal) "user" else "project", p.path });
            if (p.commands) try out.writeAll("  commands/*.md load as skills (Claude default)\n");
            if (p.root_skill) |rs| try out.print("  root skill: {s}\n", .{rs.name});
            if (p.skills) try out.writeAll("  skills: on-demand via the skill tool / /skills\n");
            if (p.agents) try out.writeAll("  agents: in the fleet\n");
            if (p.mcp) try out.writeAll("  mcp: in the merge (needs /mcp trust or --yolo)\n");
            try out.writeAll("hooks are not run.\n");
            try out.flush();
            return true;
        }
        try out.print("no plugin named '{s}'. /plugins lists what graff is reading.\n", .{want});
        try out.flush();
        return true;
    }
    if (list.len == 0) {
        try out.writeAll("no plugins discovered. graff reads Claude/Cursor/Grok/Codex trees in place (skills/, commands/, agents/, mcp.json, root SKILL.md). nothing to copy; GRAFF_NO_PLUGINS=1 disables.\n");
        try out.flush();
        return true;
    }
    try out.print("{d} plugin(s) (in-place, Claude layout, not copied):\n", .{list.len});
    for (list) |p| {
        try out.print("  {s}  [{s}/{s}]", .{ p.name, p.origin, if (p.personal) "user" else "project" });
        if (p.skills) try out.writeAll(" skills");
        if (p.commands) try out.writeAll(" commands");
        if (p.agents) try out.writeAll(" agents");
        if (p.mcp) try out.writeAll(" mcp");
        try out.print("  {s}\n", .{p.path});
    }
    try out.writeAll("skills and commands/*.md load on demand (skill tool / /skills). /plugins load <name> shows one. MCP still needs /mcp trust or --yolo.\n");
    try out.flush();
    return true;
}

/// `graff plugins` — same listing as `/plugins`, without starting a session.
pub fn command(io: Io, arena: Allocator, home: []const u8, args: []const []const u8) !void {
    var obuf: [4096]u8 = undefined;
    var out = Io.File.stdout().writer(io, &obuf);
    const line = if (args.len >= 2 and std.mem.eql(u8, args[0], "load"))
        std.fmt.allocPrint(arena, "/plugins load {s}", .{args[1]}) catch "/plugins"
    else
        "/plugins";
    _ = try slashCommand(io, arena, home, line, &out.interface);
}

const testing = std.testing;

fn tmpBase(io: Io, tmp: *testing.TmpDir, arena: Allocator) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    return arena.dupe(u8, buf[0..n]);
}

test "discover: Claude commands/ alone is a plugin and a skill dir" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const base = try tmpBase(io, &tmp, arena);
    const home = join(arena, base, "home");
    const plug = join(arena, home, ".claude/plugins/greet");
    try Io.Dir.cwd().createDirPath(io, join(arena, plug, ".claude-plugin"));
    try Io.Dir.cwd().createDirPath(io, join(arena, plug, "commands"));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = join(arena, plug, ".claude-plugin/plugin.json"), .data = "{\"name\":\"greet\"}" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = join(arena, plug, "commands/hello.md"), .data = "---\nname: hello\ndescription: d\n---\nHi.\n" });

    const list = discover(io, arena, home, tmp.dir);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("greet", list[0].name);
    try testing.expect(list[0].commands);
    try testing.expect(list[0].skills);
    try testing.expectEqual(@as(usize, 1), list[0].skill_dirs.len);
    try testing.expect(std.mem.endsWith(u8, list[0].skill_dirs[0], "commands"));
    const dirs = skillDirs(io, arena, home, tmp.dir, true);
    try testing.expectEqual(@as(usize, 1), dirs.len);
    try testing.expect(std.mem.endsWith(u8, dirs[0], "commands"));
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
    try testing.expectEqualStrings("pack", list[0].name);
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

test "applyEnv: GRAFF_NO_PLUGINS disables discover and /plugins" {
    const saved = disabled;
    defer disabled = saved;
    disabled = false;
    const Env = struct {
        pub fn get(_: @This(), key: []const u8) ?[]const u8 {
            return if (std.mem.eql(u8, key, "GRAFF_NO_PLUGINS")) "1" else null;
        }
    };
    applyEnv(Env{});
    try testing.expect(disabled);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const base = try tmpBase(io, &tmp, arena);
    const home = join(arena, base, "home");
    const plug = join(arena, home, ".claude/plugins/hidden");
    try Io.Dir.cwd().createDirPath(io, join(arena, plug, ".claude-plugin"));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = join(arena, plug, ".claude-plugin/plugin.json"), .data = "{\"name\":\"hidden\"}" });
    try testing.expectEqual(@as(usize, 0), discover(io, arena, home, tmp.dir).len);

    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try testing.expect(try slashCommand(io, arena, home, "/plugins", &aw.writer));
    try testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "GRAFF_NO_PLUGINS") != null);
}

test "discover: Cursor cache uses .cursor-plugin + mcp.json; name from manifest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const base = try tmpBase(io, &tmp, arena);
    const home = join(arena, base, "home");
    const hash = "2a8044425c7bddf429c3bdedf3ab61e791d34d65";
    const plug = join(arena, home, join(arena, ".cursor/plugins/cache/cursor-public/45893410", hash));
    try Io.Dir.cwd().createDirPath(io, join(arena, plug, ".cursor-plugin"));
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = join(arena, plug, ".cursor-plugin/plugin.json"),
        .data = "{\"name\":\"gmail\",\"mcpServers\":\"./mcp.json\"}",
    });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = join(arena, plug, "mcp.json"),
        .data = "{\"mcpServers\":{\"gmail\":{\"url\":\"https://gmailmcp.googleapis.com/mcp/v1\"}}}",
    });

    const list = discover(io, arena, home, tmp.dir);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("gmail", list[0].name);
    try testing.expectEqualStrings("cursor", list[0].origin);
    try testing.expect(list[0].mcp);
    try testing.expect(!list[0].skills);

    var servers: std.json.ObjectMap = .empty;
    var found = false;
    mergeMcp(io, arena, home, tmp.dir, &servers, &found);
    try testing.expect(found);
    try testing.expectEqualStrings("https://gmailmcp.googleapis.com/mcp/v1", servers.get("gmail").?.object.get("url").?.string);
}

test "discover: empty cache dirs are not plugins; layout rides on Plugin" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const base = try tmpBase(io, &tmp, arena);
    const home = join(arena, base, "home");
    try Io.Dir.cwd().createDirPath(io, join(arena, home, ".cursor/plugins/cache/org/id/not-a-plugin"));
    try Io.Dir.cwd().createDirPath(io, join(arena, home, ".claude/plugins/cache/official/empty"));
    try testing.expectEqual(@as(usize, 0), discover(io, arena, home, tmp.dir).len);

    const plug = join(arena, home, ".codegraff/plugins/solo");
    try Io.Dir.cwd().createDirPath(io, plug);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = join(arena, plug, "SKILL.md"),
        .data = "---\nname: solo\ndescription: one playbook\n---\nDo the thing.\n",
    });
    const list = discover(io, arena, home, tmp.dir);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("solo", list[0].name);
    try testing.expect(list[0].root_skill != null);
    try testing.expectEqualStrings("solo", list[0].root_skill.?.name);
    const roots = rootSkills(io, arena, home, tmp.dir, true);
    try testing.expectEqual(@as(usize, 1), roots.len);
    try testing.expectEqualStrings("solo", roots[0].name);
}
