//! Claude-compatible plugin layout (ADR 0007).
//!
//! Claude Code auto-discovers `skills/`, `commands/` (flat markdown playbooks),
//! `agents/`, `.mcp.json`, and a root `SKILL.md` when there is no `skills/`
//! tree. The optional `.claude-plugin/plugin.json` (or Cursor/Grok sibling)
//! may add extra paths or inline `mcpServers`. `${CLAUDE_PLUGIN_ROOT}` and
//! `${CLAUDE_PROJECT_DIR}` expand in MCP command/args/env/url strings.
//!
//! Hooks, LSP, monitors, and `bin/` PATH injection are not applied.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const file_cap: std.Io.Limit = .limited(1 << 20);

/// Codex's order: `.codex-plugin` first, then Claude, then Cursor.
const manifest_files = [_][]const u8{
    ".codex-plugin/plugin.json",
    ".claude-plugin/plugin.json",
    ".cursor-plugin/plugin.json",
    ".grok-plugin/plugin.json",
    "plugin.json",
};

pub const RootSkill = struct {
    path: []const u8,
    name: []const u8,
    dir: []const u8,
};

pub const Layout = struct {
    name: []const u8 = "",
    skill_dirs: []const []const u8 = &.{},
    agent_dirs: []const []const u8 = &.{},
    root_skill: ?RootSkill = null,
    has_commands: bool = false,
    has_mcp: bool = false,
};

fn exists(io: Io, path: []const u8) bool {
    return (Io.Dir.cwd().statFile(io, path, .{}) catch null) != null;
}

fn join(arena: Allocator, a: []const u8, b: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ a, b }) catch "";
}

/// Refuse `..` so a manifest cannot walk out of the plugin tree.
fn resolveRel(arena: Allocator, plugin_path: []const u8, rel: []const u8) ?[]const u8 {
    var r = std.mem.trim(u8, rel, " \t");
    if (std.mem.startsWith(u8, r, "./")) r = r[2..];
    if (r.len == 0 or std.mem.eql(u8, r, ".")) return plugin_path;
    if (std.mem.indexOf(u8, r, "..") != null) return null;
    const out = join(arena, plugin_path, r);
    return if (out.len > 0) out else null;
}

fn appendDir(arena: Allocator, list: *std.ArrayList([]const u8), io: Io, path: []const u8) void {
    if (path.len == 0 or !exists(io, path)) return;
    for (list.items) |have| if (std.mem.eql(u8, have, path)) return;
    list.append(arena, path) catch {};
}

fn collectPaths(arena: Allocator, list: *std.ArrayList([]const u8), io: Io, plugin_path: []const u8, field: ?Value) void {
    const v = field orelse return;
    switch (v) {
        .string => if (resolveRel(arena, plugin_path, v.string)) |p| appendDir(arena, list, io, p),
        .array => for (v.array.items) |item| {
            if (item == .string) if (resolveRel(arena, plugin_path, item.string)) |p| appendDir(arena, list, io, p);
        },
        else => {},
    }
}

fn readManifest(io: Io, arena: Allocator, plugin_path: []const u8) ?Value {
    for (manifest_files) |rel| {
        const text = Io.Dir.cwd().readFileAlloc(io, join(arena, plugin_path, rel), arena, .limited(64 * 1024)) catch continue;
        const v = std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch continue;
        if (v == .object) return v;
    }
    return null;
}

/// Codex bundled plugins can select a host-provided content surface instead
/// of their raw MCP declaration. Computer Use uses this to require the signed
/// node_repl bridge (#618).
pub fn usesNodeRepl(io: Io, arena: Allocator, plugin_path: []const u8) bool {
    const manifest = readManifest(io, arena, plugin_path) orelse return false;
    const variant = manifest.object.get("bundledContentVariant") orelse return false;
    return variant == .string and std.mem.eql(u8, variant.string, "node-repl");
}

pub fn expandPlaceholders(arena: Allocator, text: []const u8, plugin_root: []const u8, project_dir: []const u8) []const u8 {
    if (std.mem.indexOf(u8, text, "${CLAUDE_") == null) return text;
    const step = std.mem.replaceOwned(u8, arena, text, "${CLAUDE_PLUGIN_ROOT}", plugin_root) catch text;
    if (project_dir.len == 0) return step;
    return std.mem.replaceOwned(u8, arena, step, "${CLAUDE_PROJECT_DIR}", project_dir) catch step;
}

fn expandValue(arena: Allocator, v: Value, plugin_root: []const u8, project_dir: []const u8) Value {
    return switch (v) {
        .string => .{ .string = expandPlaceholders(arena, v.string, plugin_root, project_dir) },
        .object => blk: {
            var out: std.json.ObjectMap = .empty;
            var it = v.object.iterator();
            while (it.next()) |e| {
                out.put(arena, e.key_ptr.*, expandValue(arena, e.value_ptr.*, plugin_root, project_dir)) catch {};
            }
            break :blk .{ .object = out };
        },
        .array => blk: {
            var out = std.json.Array.init(arena);
            for (v.array.items) |item| out.append(expandValue(arena, item, plugin_root, project_dir)) catch {};
            break :blk .{ .array = out };
        },
        else => v,
    };
}

fn prepareServer(arena: Allocator, plugin_root: []const u8, cfg: std.json.ObjectMap) ?Value {
    var out: std.json.ObjectMap = .empty;
    var it = cfg.iterator();
    while (it.next()) |e| out.put(arena, e.key_ptr.*, e.value_ptr.*) catch return null;

    // Plugin MCP commands are resolved from the plugin, not from whichever
    // repository launched graff. Codex's Computer Use package is the concrete
    // #618 witness: command `./bin/computer-use-client-launcher`, cwd `.`.
    if (out.get("cwd")) |cwd| {
        if (cwd != .string) return null;
        if (!std.fs.path.isAbsolute(cwd.string)) {
            const resolved = resolveRel(arena, plugin_root, cwd.string) orelse return null;
            out.put(arena, "cwd", .{ .string = resolved }) catch return null;
        }
    } else if (out.get("command")) |command| {
        if (command == .string and std.mem.startsWith(u8, command.string, "./"))
            out.put(arena, "cwd", .{ .string = plugin_root }) catch return null;
    }
    return .{ .object = out };
}

fn putServers(arena: Allocator, servers: *std.json.ObjectMap, found: *bool, v: ?Value, plugin_root: []const u8) void {
    const obj = if (v) |x| (if (x == .object) x.object else return) else return;
    var it = obj.iterator();
    while (it.next()) |e| {
        if (servers.get(e.key_ptr.*) != null) continue;
        if (e.value_ptr.* != .object) continue;
        const prepared = prepareServer(arena, plugin_root, e.value_ptr.*.object) orelse continue;
        servers.put(arena, e.key_ptr.*, prepared) catch continue;
        found.* = true;
    }
}

fn ingestText(arena: Allocator, servers: *std.json.ObjectMap, found: *bool, text: []const u8, plugin_root: []const u8, project_dir: []const u8) void {
    const parsed = std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch return;
    if (parsed != .object) return;
    const expanded = expandValue(arena, parsed, plugin_root, project_dir);
    if (expanded != .object) return;
    if (expanded.object.get("mcpServers")) |inner| {
        putServers(arena, servers, found, inner, plugin_root);
        return;
    }
    // Inline `{ "name": { "command": ... } }` — Claude plugin.json shape.
    putServers(arena, servers, found, expanded, plugin_root);
}

fn ingestFile(io: Io, arena: Allocator, servers: *std.json.ObjectMap, found: *bool, path: []const u8, plugin_root: []const u8, project_dir: []const u8) void {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, file_cap) catch return;
    ingestText(arena, servers, found, text, plugin_root, project_dir);
}

fn ingestMcpField(io: Io, arena: Allocator, servers: *std.json.ObjectMap, found: *bool, plugin_path: []const u8, project_dir: []const u8, field: Value) void {
    switch (field) {
        .string => if (resolveRel(arena, plugin_path, field.string)) |p| ingestFile(io, arena, servers, found, p, plugin_path, project_dir),
        .array => for (field.array.items) |item| {
            if (item == .string) if (resolveRel(arena, plugin_path, item.string)) |p|
                ingestFile(io, arena, servers, found, p, plugin_path, project_dir);
        },
        .object => {
            const expanded = expandValue(arena, field, plugin_path, project_dir);
            if (expanded.object.get("mcpServers")) |inner| {
                putServers(arena, servers, found, inner, plugin_path);
            } else {
                putServers(arena, servers, found, expanded, plugin_path);
            }
        },
        else => {},
    }
}

fn readOneManifest(io: Io, arena: Allocator, plugin_path: []const u8, rel: []const u8) ?Value {
    const text = Io.Dir.cwd().readFileAlloc(io, join(arena, plugin_path, rel), arena, .limited(64 * 1024)) catch return null;
    const v = std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch return null;
    return if (v == .object) v else null;
}

/// Claude defaults plus any extra dirs the manifest names. One readdir of the
/// plugin root, then at most one manifest file — not a stat per marker.
pub fn inspect(io: Io, arena: Allocator, plugin_path: []const u8) Layout {
    var skills: std.ArrayList([]const u8) = .empty;
    var agents: std.ArrayList([]const u8) = .empty;
    var has_commands = false;
    var has_mcp = false;
    var saw_root_skill = false;
    var saw_codex = false;
    var saw_claude = false;
    var saw_cursor = false;
    var saw_grok = false;
    var saw_plugin_json = false;
    var dir = Io.Dir.cwd().openDir(io, plugin_path, .{ .iterate = true }) catch return .{
        .name = std.fs.path.basename(plugin_path),
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (std.mem.eql(u8, entry.name, "skills")) {
            skills.append(arena, join(arena, plugin_path, "skills")) catch {};
        } else if (std.mem.eql(u8, entry.name, "commands")) {
            has_commands = true;
            skills.append(arena, join(arena, plugin_path, "commands")) catch {};
        } else if (std.mem.eql(u8, entry.name, "agents")) {
            agents.append(arena, join(arena, plugin_path, "agents")) catch {};
        } else if (std.mem.eql(u8, entry.name, "SKILL.md")) {
            saw_root_skill = true;
        } else if (std.mem.eql(u8, entry.name, "mcp.json") or std.mem.eql(u8, entry.name, ".mcp.json")) {
            has_mcp = true;
        } else if (std.mem.eql(u8, entry.name, ".codex-plugin")) {
            saw_codex = true;
        } else if (std.mem.eql(u8, entry.name, ".claude-plugin")) {
            saw_claude = true;
        } else if (std.mem.eql(u8, entry.name, ".cursor-plugin")) {
            saw_cursor = true;
        } else if (std.mem.eql(u8, entry.name, ".grok-plugin")) {
            saw_grok = true;
        } else if (std.mem.eql(u8, entry.name, "plugin.json")) {
            saw_plugin_json = true;
        }
    }

    const manifest_rel: ?[]const u8 = if (saw_codex) ".codex-plugin/plugin.json" else if (saw_claude) ".claude-plugin/plugin.json" else if (saw_cursor) ".cursor-plugin/plugin.json" else if (saw_grok) ".grok-plugin/plugin.json" else if (saw_plugin_json) "plugin.json" else null;
    const manifest = if (manifest_rel) |rel| readOneManifest(io, arena, plugin_path, rel) else null;
    if (manifest) |v| {
        collectPaths(arena, &skills, io, plugin_path, v.object.get("skills"));
        collectPaths(arena, &skills, io, plugin_path, v.object.get("commands"));
        collectPaths(arena, &agents, io, plugin_path, v.object.get("agents"));
        if (v.object.get("mcpServers") != null) has_mcp = true;
    }

    const name = if (manifest) |v| blk: {
        if (v.object.get("name")) |n| if (n == .string and n.string.len > 0) break :blk n.string;
        break :blk std.fs.path.basename(plugin_path);
    } else std.fs.path.basename(plugin_path);

    var root_skill: ?RootSkill = null;
    if (skills.items.len == 0 and saw_root_skill) {
        root_skill = .{
            .path = join(arena, plugin_path, "SKILL.md"),
            .name = name,
            .dir = plugin_path,
        };
    }

    return .{
        .name = name,
        .skill_dirs = skills.items,
        .agent_dirs = agents.items,
        .root_skill = root_skill,
        .has_commands = has_commands,
        .has_mcp = has_mcp,
    };
}

/// Fill missing MCP names from Claude/Cursor default files and the manifest.
pub fn mergeMcp(io: Io, arena: Allocator, plugin_path: []const u8, project_dir: []const u8, servers: *std.json.ObjectMap, found: *bool) void {
    ingestFile(io, arena, servers, found, join(arena, plugin_path, ".mcp.json"), plugin_path, project_dir);
    ingestFile(io, arena, servers, found, join(arena, plugin_path, "mcp.json"), plugin_path, project_dir);
    if (readManifest(io, arena, plugin_path)) |v| {
        if (v.object.get("mcpServers")) |field|
            ingestMcpField(io, arena, servers, found, plugin_path, project_dir, field);
    }
}

const testing = std.testing;

fn tmpBase(io: Io, tmp: *testing.TmpDir, arena: Allocator) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    return arena.dupe(u8, buf[0..n]);
}

test "inspect: commands/ and root SKILL.md follow Claude defaults" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const base = try tmpBase(io, &tmp, arena);
    const plug = join(arena, base, "greet");
    try Io.Dir.cwd().createDirPath(io, join(arena, plug, ".claude-plugin"));
    try Io.Dir.cwd().createDirPath(io, join(arena, plug, "commands"));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = join(arena, plug, ".claude-plugin/plugin.json"), .data = "{\"name\":\"greet\"}" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = join(arena, plug, "commands/hello.md"), .data = "---\nname: hello\ndescription: say hi\n---\nHi.\n" });

    const lay = inspect(io, arena, plug);
    try testing.expectEqualStrings("greet", lay.name);
    try testing.expect(lay.has_commands);
    try testing.expectEqual(@as(usize, 1), lay.skill_dirs.len);
    try testing.expect(std.mem.endsWith(u8, lay.skill_dirs[0], "commands"));
    try testing.expect(lay.root_skill == null);

    const lone = join(arena, base, "solo");
    try Io.Dir.cwd().createDirPath(io, join(arena, lone, ".claude-plugin"));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = join(arena, lone, ".claude-plugin/plugin.json"), .data = "{\"name\":\"solo\"}" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = join(arena, lone, "SKILL.md"), .data = "---\nname: solo\ndescription: one playbook\n---\nDo the thing.\n" });
    const lone_lay = inspect(io, arena, lone);
    try testing.expectEqualStrings("solo", lone_lay.name);
    try testing.expect(lone_lay.root_skill != null);
    try testing.expectEqualStrings("solo", lone_lay.root_skill.?.name);
    try testing.expectEqual(@as(usize, 0), lone_lay.skill_dirs.len);

    const cx = join(arena, base, "host");
    try Io.Dir.cwd().createDirPath(io, join(arena, cx, ".codex-plugin"));
    try Io.Dir.cwd().createDirPath(io, join(arena, cx, "skills"));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = join(arena, cx, ".codex-plugin/plugin.json"), .data = "{\"name\":\"host\"}" });
    const cx_lay = inspect(io, arena, cx);
    try testing.expectEqualStrings("host", cx_lay.name);
    try testing.expectEqual(@as(usize, 1), cx_lay.skill_dirs.len);
}

test "mergeMcp: inline servers expand CLAUDE_PLUGIN_ROOT; extra file paths work" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const base = try tmpBase(io, &tmp, arena);
    const plug = join(arena, base, "pack");
    try Io.Dir.cwd().createDirPath(io, join(arena, plug, ".claude-plugin"));
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = join(arena, plug, ".claude-plugin/plugin.json"),
        .data = "{\"name\":\"pack\",\"mcpServers\":{\"inline\":{\"command\":\"${CLAUDE_PLUGIN_ROOT}/bin/tool\"}}}",
    });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = join(arena, plug, "extra-mcp.json"),
        .data = "{\"mcpServers\":{\"from-extra\":{\"command\":\"/bin/false\"}}}",
    });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = join(arena, plug, ".claude-plugin/plugin.json"),
        .data = "{\"name\":\"pack\",\"mcpServers\":[\"./extra-mcp.json\"]}",
    });

    var servers: std.json.ObjectMap = .empty;
    var found = false;
    mergeMcp(io, arena, plug, base, &servers, &found);
    try testing.expect(found);
    try testing.expect(servers.get("from-extra") != null);

    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = join(arena, plug, ".claude-plugin/plugin.json"),
        .data = "{\"name\":\"pack\",\"mcpServers\":{\"inline\":{\"command\":\"${CLAUDE_PLUGIN_ROOT}/bin/tool\"}}}",
    });
    servers = .empty;
    found = false;
    mergeMcp(io, arena, plug, base, &servers, &found);
    const cmd = servers.get("inline").?.object.get("command").?.string;
    try testing.expect(std.mem.endsWith(u8, cmd, "pack/bin/tool"));
    try testing.expect(std.mem.indexOf(u8, cmd, "${CLAUDE_") == null);
}

test "mergeMcp: plugin-relative command and cwd resolve from the plugin (#618)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const base = try tmpBase(io, &tmp, arena);
    const plug = join(arena, base, "computer-use");
    try Io.Dir.cwd().createDirPath(io, plug);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = join(arena, plug, ".mcp.json"), .data = "{\"mcpServers\":{\"computer-use\":{\"command\":\"client\"}}}" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = join(arena, plug, "mcp.json"), .data = "{\"mcpServers\":{\"relative\":{\"command\":\"./bin/server\",\"cwd\":\".\"}}}" });

    var servers: std.json.ObjectMap = .empty;
    var found = false;
    mergeMcp(io, arena, plug, base, &servers, &found);
    try testing.expect(found);
    try testing.expectEqual(@as(usize, 2), servers.count());
    const relative = servers.get("relative").?.object;
    try testing.expectEqualStrings("./bin/server", relative.get("command").?.string);
    try testing.expectEqualStrings(plug, relative.get("cwd").?.string);
}

test "usesNodeRepl reads the Codex bundled content variant (#618)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try tmpBase(testing.io, &tmp, arena);
    const plug = join(arena, base, "computer-use");
    try Io.Dir.cwd().createDirPath(testing.io, join(arena, plug, ".codex-plugin"));
    try Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = join(arena, plug, ".codex-plugin/plugin.json"),
        .data = "{\"name\":\"computer-use\",\"bundledContentVariant\":\"node-repl\"}",
    });
    try testing.expect(usesNodeRepl(testing.io, arena, plug));
}

test "resolveRel refuses parent-directory escapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expect(resolveRel(arena_state.allocator(), "/plugins/demo", "../secret") == null);
    try testing.expectEqualStrings("/plugins/demo/commands", resolveRel(arena_state.allocator(), "/plugins/demo", "./commands").?);
}
