//! Codex PluginStore (ADR 0007).
//!
//! Codex never writes `installed_plugins.json` and never lists `plugins/cache/`.
//! Enabled ids in `config.toml` (`[plugins."name@marketplace"]`) resolve to
//! `plugins/cache/<marketplace>/<name>/<version>`. Prefer version `local`,
//! else the last sorted version dir. Disabled and invalid keys are skipped.
//!
//! Skill bodies stay off the system-prompt prefix (prompt-cache max): this
//! module only yields install roots; `skill_docs.promptCatalog` prints names.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const plugin_index = @import("plugin_index.zig");

pub const Entry = plugin_index.Entry;

const file_cap: std.Io.Limit = .limited(1 << 20);
const cap = 32;

const Key = struct {
    name: []const u8,
    marketplace: []const u8,
    enabled: bool,
};

/// `codex_home` is `~/.codex` or `<cwd>/.codex`. Empty on missing config.
pub fn load(io: Io, arena: Allocator, codex_home: []const u8) []const Entry {
    if (codex_home.len == 0) return &.{};
    const toml_path = std.fmt.allocPrint(arena, "{s}/config.toml", .{codex_home}) catch return &.{};
    const text = Io.Dir.cwd().readFileAlloc(io, toml_path, arena, file_cap) catch return &.{};
    var out: std.ArrayList(Entry) = .empty;
    for (keys(arena, text)) |k| {
        if (!k.enabled or out.items.len >= cap) continue;
        const path = activeRoot(io, arena, codex_home, k.name, k.marketplace) orelse continue;
        out.append(arena, .{ .name = k.name, .path = path }) catch {};
    }
    return out.items;
}

fn keys(arena: Allocator, text: []const u8) []const Key {
    var out: std.ArrayList(Key) = .empty;
    var current: ?usize = null;
    var inline_plugins = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = stripComment(raw);
        if (line.len == 0) continue;
        if (line[0] == '[') {
            current = null;
            inline_plugins = false;
            const inner = tableName(line) orelse continue;
            if (std.mem.eql(u8, inner, "plugins")) {
                inline_plugins = true;
                continue;
            }
            const key = pluginTableKey(inner) orelse continue;
            const id = parseId(key) orelse continue;
            if (out.items.len >= cap) continue;
            out.append(arena, .{ .name = id.name, .marketplace = id.marketplace, .enabled = true }) catch continue;
            current = out.items.len - 1;
            continue;
        }
        if (inline_plugins) {
            const ik = inlineKey(line) orelse continue;
            const id = parseId(ik.key) orelse continue;
            if (out.items.len >= cap) continue;
            out.append(arena, .{ .name = id.name, .marketplace = id.marketplace, .enabled = ik.enabled }) catch {};
            continue;
        }
        if (current) |i| {
            if (enabledLine(line)) |en| out.items[i].enabled = en;
        }
    }
    return out.items;
}

fn stripComment(line: []const u8) []const u8 {
    const hash = std.mem.indexOfScalar(u8, line, '#') orelse return std.mem.trim(u8, line, " \t\r");
    if (std.mem.indexOfScalar(u8, line[0..hash], '"') != null) return std.mem.trim(u8, line, " \t\r");
    return std.mem.trim(u8, line[0..hash], " \t\r");
}

fn tableName(line: []const u8) ?[]const u8 {
    if (line.len < 3 or line[0] != '[' or line[line.len - 1] != ']') return null;
    return std.mem.trim(u8, line[1 .. line.len - 1], " \t");
}

fn pluginTableKey(inner: []const u8) ?[]const u8 {
    const prefix = "plugins.";
    if (!std.mem.startsWith(u8, inner, prefix)) return null;
    return unquote(inner[prefix.len..]);
}

fn unquote(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t");
    if (t.len >= 2 and ((t[0] == '"' and t[t.len - 1] == '"') or (t[0] == '\'' and t[t.len - 1] == '\'')))
        return t[1 .. t.len - 1];
    return t;
}

fn parseId(key: []const u8) ?struct { name: []const u8, marketplace: []const u8 } {
    const at = std.mem.lastIndexOfScalar(u8, key, '@') orelse return null;
    const name = key[0..at];
    const marketplace = key[at + 1 ..];
    if (!validName(name) or !validMarketplace(marketplace)) return null;
    return .{ .name = name, .marketplace = marketplace };
}

fn validName(s: []const u8) bool {
    if (s.len == 0 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return false;
    if (s[0] == '.' or s[s.len - 1] == '.' or std.mem.indexOf(u8, s, "..") != null) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    }
    return true;
}

fn validMarketplace(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

fn validVersion(s: []const u8) bool {
    if (s.len == 0 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.' and c != '+') return false;
    }
    return true;
}

fn enabledLine(line: []const u8) ?bool {
    if (!std.mem.startsWith(u8, line, "enabled")) return null;
    const rest = std.mem.trim(u8, line["enabled".len..], " \t");
    if (rest.len == 0 or rest[0] != '=') return null;
    const val = std.mem.trim(u8, rest[1..], " \t");
    if (std.mem.startsWith(u8, val, "false")) return false;
    if (std.mem.startsWith(u8, val, "true")) return true;
    return null;
}

fn inlineKey(line: []const u8) ?struct { key: []const u8, enabled: bool } {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const key = unquote(line[0..eq]);
    if (std.mem.indexOfScalar(u8, key, '@') == null) return null;
    const rhs = line[eq + 1 ..];
    const enabled = if (std.mem.indexOf(u8, rhs, "enabled")) |i|
        std.mem.indexOf(u8, rhs[i..], "false") == null
    else
        true;
    return .{ .key = key, .enabled = enabled };
}

fn activeRoot(io: Io, arena: Allocator, home: []const u8, name: []const u8, marketplace: []const u8) ?[]const u8 {
    const base = std.fmt.allocPrint(arena, "{s}/plugins/cache/{s}/{s}", .{ home, marketplace, name }) catch return null;
    var dir = Io.Dir.cwd().openDir(io, base, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory and e.kind != .sym_link) continue;
        if (!validVersion(e.name)) continue;
        names.append(arena, arena.dupe(u8, e.name) catch continue) catch continue;
    }
    var best: ?[]const u8 = null;
    for (names.items) |n| {
        if (std.mem.eql(u8, n, "local")) return std.fmt.allocPrint(arena, "{s}/local", .{base}) catch null;
        if (best == null or std.mem.order(u8, n, best.?) == .gt) best = n;
    }
    const ver = best orelse return null;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ base, ver }) catch null;
}

const testing = std.testing;

fn tmpBase(io: Io, tmp: *testing.TmpDir, arena: Allocator) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    return arena.dupe(u8, buf[0..n]);
}

fn join(arena: Allocator, a: []const u8, b: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ a, b }) catch "";
}

test "load: config.toml enabled id resolves cache version; disabled and decoys stay invisible" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const home = try tmpBase(io, &tmp, arena);
    const pack = join(arena, home, "plugins/cache/official/pack/local");
    const decoy = join(arena, home, "plugins/cache/official/decoy/local");
    const old = join(arena, home, "plugins/cache/official/pack/1.0.0");
    try Io.Dir.cwd().createDirPath(io, join(arena, pack, ".codex-plugin"));
    try Io.Dir.cwd().createDirPath(io, join(arena, decoy, "skills"));
    try Io.Dir.cwd().createDirPath(io, old);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = join(arena, home, "config.toml"),
        .data =
        \\[plugins."pack@official"]
        \\enabled = true
        \\
        \\[plugins."decoy@official"]
        \\enabled = false
        \\
        \\[plugins.invalid]
        \\enabled = true
        \\
        \\[plugins."missing@official"]
        \\enabled = true
        ,
    });

    try testing.expectEqual(@as(usize, 0), load(io, arena, join(arena, home, "nope")).len);

    const got = load(io, arena, home);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("pack", got[0].name);
    try testing.expect(std.mem.endsWith(u8, got[0].path, "official/pack/local"));
}

test "load: inline [plugins] table and newest version when local is absent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const home = try tmpBase(io, &tmp, arena);
    try Io.Dir.cwd().createDirPath(io, join(arena, home, "plugins/cache/test/demo/1.2.0"));
    try Io.Dir.cwd().createDirPath(io, join(arena, home, "plugins/cache/test/demo/0.9.0"));
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = join(arena, home, "config.toml"),
        .data =
        \\[plugins]
        \\"demo@test" = { enabled = true }
        ,
    });
    const got = load(io, arena, home);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expect(std.mem.endsWith(u8, got[0].path, "test/demo/1.2.0"));
}

test "discover: Codex store is visible; cache/ is still not walked" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const base = try tmpBase(io, &tmp, arena);
    const user = join(arena, base, "home");
    const pack = join(arena, user, ".codex/plugins/cache/official/pack/local");
    const decoy = join(arena, user, ".codex/plugins/cache/official/decoy/local");
    try Io.Dir.cwd().createDirPath(io, join(arena, pack, ".codex-plugin"));
    try Io.Dir.cwd().createDirPath(io, join(arena, pack, "skills/hi"));
    try Io.Dir.cwd().createDirPath(io, join(arena, decoy, "skills/nope"));
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = join(arena, pack, ".codex-plugin/plugin.json"),
        .data = "{\"name\":\"pack\"}",
    });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = join(arena, pack, "skills/hi/SKILL.md"),
        .data = "---\nname: pack-hi\ndescription: d\n---\nbody\n",
    });
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = join(arena, decoy, "skills/nope/SKILL.md"),
        .data = "---\nname: nope\ndescription: d\n---\nbody\n",
    });
    const plugins = @import("plugins.zig");
    try testing.expectEqual(@as(usize, 0), plugins.discover(io, arena, user, tmp.dir).len);

    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = join(arena, user, ".codex/config.toml"),
        .data =
        \\[plugins."pack@official"]
        \\enabled = true
        ,
    });
    const list = plugins.discover(io, arena, user, tmp.dir);
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expectEqualStrings("pack", list[0].name);
    try testing.expectEqualStrings("codex", list[0].origin);
    try testing.expect(list[0].skills);
}
