//! Copy MCP servers and skills from Claude Code / Cursor into graff's own
//! folders (`~/.codegraff/mcp.json`, `.mcp.json`, `~/.codegraff/skills`,
//! `.harness/skills`). Same idea as Grok's `/import-claude`: scan their files,
//! write ours, never overwrite a name that is already configured.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const mcp_config = @import("mcp_config.zig");
const skill_docs = @import("skill_docs.zig");

const file_cap: std.Io.Limit = .limited(2 << 20);
const max_copy_depth: u8 = 6;
/// Written after the first adopt so startup does not rescan Claude every launch.
pub const marker_rel = ".codegraff/adopted";

pub const Report = struct {
    added_user: usize = 0,
    added_project: usize = 0,
    skipped: usize = 0,
    skills: usize = 0,
    hooks: usize = 0,
    rules: usize = 0,
    sources: usize = 0,
};

/// `graff mcp import` / `graff import-claude`. Always allowed after first-run.
pub fn command(io: Io, arena: Allocator, home: []const u8, cwd: []const u8, out: *Io.Writer) !void {
    const r = try run(io, arena, home, cwd);
    markAdopted(io, arena, home);
    if (r.added_user + r.added_project + r.skills == 0 and r.skipped == 0) {
        try out.writeAll("nothing to adopt: no Claude/Cursor MCP servers or skills found.\n");
        try out.flush();
        return;
    }
    try out.print("adopted {d} user MCP → ~/" ++ mcp_config.global_rel_path ++ "\n", .{r.added_user});
    try out.print("adopted {d} project MCP → .mcp.json\n", .{r.added_project});
    if (r.skipped > 0) try out.print("skipped {d} already configured\n", .{r.skipped});
    try out.print("copied {d} skill(s) → ~/.codegraff/skills and .harness/skills\n", .{r.skills});
    if (r.hooks > 0) try out.print("copied {d} hook(s) → ~/.codegraff/hooks (PreToolUse Read/Edit skipped)\n", .{r.hooks});
    if (r.rules > 0) try out.print("copied {d} rule file(s) → .harness/\n", .{r.rules});
    try out.writeAll("new MCP servers still need /mcp trust or --yolo to connect.\n");
    try out.flush();
}

pub fn trySlash(io: Io, arena: Allocator, home: []const u8, line: []const u8, out: *Io.Writer) !bool {
    const cmd = std.mem.trim(u8, line, " \t");
    if (!(std.mem.eql(u8, cmd, "/import-claude") or std.mem.eql(u8, cmd, "/mcp import") or std.mem.eql(u8, cmd, "/adopt")))
        return false;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = Io.Dir.cwd().realPath(io, &cwd_buf) catch 0;
    const cwd = if (n > 0) cwd_buf[0..n] else ".";
    try command(io, arena, home, cwd, out);
    return true;
}

/// One-shot at session start: copy Claude/Cursor MCP + skills into graff folders
/// if we have never done so. Later re-runs go through `command`.
pub fn maybeFirstRun(io: Io, arena: Allocator, home: []const u8, cwd: []const u8) !?Report {
    if (home.len == 0) return null;
    if (alreadyAdopted(io, arena, home)) return null;
    const r = try run(io, arena, home, cwd);
    markAdopted(io, arena, home);
    return r;
}

pub fn alreadyAdopted(io: Io, arena: Allocator, home: []const u8) bool {
    const path = markerPath(arena, home) orelse return false;
    return (Io.Dir.cwd().statFile(io, path, .{}) catch null) != null;
}

fn markAdopted(io: Io, arena: Allocator, home: []const u8) void {
    const path = markerPath(arena, home) orelse return;
    if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "1\n" }) catch {};
}

fn markerPath(arena: Allocator, home: []const u8) ?[]const u8 {
    if (home.len == 0) return null;
    return std.fmt.allocPrint(arena, "{s}/" ++ marker_rel, .{home}) catch null;
}

pub fn run(io: Io, arena: Allocator, home: []const u8, cwd: []const u8) !Report {
    var r: Report = .{};
    var user_add: std.json.ObjectMap = .empty;
    var proj_add: std.json.ObjectMap = .empty;

    if (home.len > 0) {
        takeFile(io, arena, &user_add, &r, try std.fmt.allocPrint(arena, "{s}/.claude.json", .{home}), .user_root, cwd);
        takeFile(io, arena, &user_add, &r, try std.fmt.allocPrint(arena, "{s}/.claude/settings.json", .{home}), .plain, cwd);
        takeFile(io, arena, &user_add, &r, try std.fmt.allocPrint(arena, "{s}/.claude/settings.local.json", .{home}), .plain, cwd);
        takeFile(io, arena, &user_add, &r, try std.fmt.allocPrint(arena, "{s}/.cursor/mcp.json", .{home}), .plain, cwd);
        if (builtin_desktop(arena, home)) |p| takeFile(io, arena, &user_add, &r, p, .plain, cwd);
    }
    takeFile(io, arena, &proj_add, &r, join(arena, cwd, ".claude/settings.json"), .plain, cwd);
    takeFile(io, arena, &proj_add, &r, join(arena, cwd, ".claude/settings.local.json"), .plain, cwd);
    takeFile(io, arena, &proj_add, &r, join(arena, cwd, ".cursor/mcp.json"), .plain, cwd);
    if (home.len > 0) {
        takeFile(io, arena, &proj_add, &r, try std.fmt.allocPrint(arena, "{s}/.claude.json", .{home}), .user_project, cwd);
    }

    const user_path = if (home.len > 0)
        try std.fmt.allocPrint(arena, "{s}/" ++ mcp_config.global_rel_path, .{home})
    else
        null;
    if (user_path) |p| r.added_user = try mergeWrite(io, arena, p, user_add, &r.skipped);
    r.added_project = try mergeWrite(io, arena, join(arena, cwd, ".mcp.json"), proj_add, &r.skipped);

    if (home.len > 0) {
        r.skills += copySkillDir(
            io,
            arena,
            try std.fmt.allocPrint(arena, "{s}/.claude/skills", .{home}),
            try std.fmt.allocPrint(arena, "{s}/.codegraff/skills", .{home}),
        );
    }
    r.skills += copySkillDir(io, arena, join(arena, cwd, skill_docs.compat_dir), join(arena, cwd, skill_docs.project_dir));
    r.hooks += adoptHooks(io, arena, home, cwd);
    r.rules += adoptRules(io, arena, cwd);
    return r;
}

const Kind = enum { plain, user_root, user_project };

fn takeFile(io: Io, arena: Allocator, dest: *std.json.ObjectMap, r: *Report, path: []const u8, kind: Kind, cwd: []const u8) void {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, file_cap) catch return;
    const parsed = std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch return;
    if (parsed != .object) return;
    r.sources += 1;
    switch (kind) {
        .plain => harvest(arena, dest, parsed.object.get("mcpServers")),
        .user_root => harvest(arena, dest, parsed.object.get("mcpServers")),
        .user_project => harvestProject(arena, dest, parsed.object.get("projects"), cwd),
    }
}

fn harvestProject(arena: Allocator, dest: *std.json.ObjectMap, projects: ?Value, cwd: []const u8) void {
    const obj = if (projects) |v| (if (v == .object) v.object else return) else return;
    var it = obj.iterator();
    while (it.next()) |e| {
        if (!pathEq(e.key_ptr.*, cwd)) continue;
        if (e.value_ptr.* != .object) continue;
        harvest(arena, dest, e.value_ptr.object.get("mcpServers"));
    }
}

fn harvest(arena: Allocator, dest: *std.json.ObjectMap, servers: ?Value) void {
    const obj = if (servers) |v| (if (v == .object) v.object else return) else return;
    var it = obj.iterator();
    while (it.next()) |e| {
        if (dest.get(e.key_ptr.*) != null) continue;
        const n = normalize(arena, e.value_ptr.*) orelse continue;
        dest.put(arena, e.key_ptr.*, n) catch {};
    }
}

fn normalize(arena: Allocator, v: Value) ?Value {
    if (v != .object) return null;
    var out: std.json.ObjectMap = .empty;
    if (v.object.get("url")) |u| if (u == .string and u.string.len > 0) {
        out.put(arena, "url", u) catch return null;
        if (v.object.get("headers")) |h| if (h == .object) out.put(arena, "headers", h) catch {};
        return .{ .object = out };
    };
    const cmd = v.object.get("command") orelse return null;
    if (cmd != .string or cmd.string.len == 0) return null;
    out.put(arena, "command", cmd) catch return null;
    if (v.object.get("args")) |a| if (a == .array) out.put(arena, "args", a) catch {};
    if (v.object.get("env")) |e| if (e == .object) out.put(arena, "env", e) catch {};
    return .{ .object = out };
}

fn mergeWrite(io: Io, arena: Allocator, path: []const u8, incoming: std.json.ObjectMap, skipped: *usize) !usize {
    if (incoming.count() == 0) return 0;
    var root: std.json.ObjectMap = .empty;
    if (Io.Dir.cwd().readFileAlloc(io, path, arena, file_cap)) |text| {
        if (std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always })) |v| {
            if (v == .object) root = v.object;
        } else |_| {}
    } else |_| {}
    var servers: std.json.ObjectMap = .empty;
    if (root.get("mcpServers")) |m| {
        if (m == .object) servers = m.object;
    }
    var added: usize = 0;
    var it = incoming.iterator();
    while (it.next()) |e| {
        if (servers.get(e.key_ptr.*) != null) {
            skipped.* += 1;
            continue;
        }
        servers.put(arena, e.key_ptr.*, e.value_ptr.*) catch continue;
        added += 1;
    }
    if (added == 0) return 0;
    root.put(arena, "mcpServers", .{ .object = servers }) catch return added;
    if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    s.write(Value{ .object = root }) catch return added;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.writer.buffered() }) catch return 0;
    return added;
}

fn copySkillDir(io: Io, arena: Allocator, src: []const u8, dest_root: []const u8) usize {
    var dir = Io.Dir.cwd().openDir(io, src, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var n: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        const from = std.fmt.allocPrint(arena, "{s}/{s}", .{ src, e.name }) catch continue;
        const to = std.fmt.allocPrint(arena, "{s}/{s}", .{ dest_root, e.name }) catch continue;
        switch (e.kind) {
            .directory => {
                const md = std.fmt.allocPrint(arena, "{s}/SKILL.md", .{to}) catch continue;
                if (Io.Dir.cwd().statFile(io, md, .{}) catch null) |_| continue;
                copyTree(io, arena, from, to, 0) catch continue;
                n += 1;
            },
            .file => {
                if (!std.mem.endsWith(u8, e.name, ".md")) continue;
                if (Io.Dir.cwd().statFile(io, to, .{}) catch null) |_| continue;
                Io.Dir.cwd().createDirPath(io, dest_root) catch continue;
                Io.Dir.cwd().copyFile(from, Io.Dir.cwd(), to, io, .{}) catch continue;
                n += 1;
            },
            else => {},
        }
    }
    return n;
}

fn copyTree(io: Io, arena: Allocator, src: []const u8, dest: []const u8, depth: u8) !void {
    if (depth > max_copy_depth) return;
    try Io.Dir.cwd().createDirPath(io, dest);
    var dir = try Io.Dir.cwd().openDir(io, src, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        const from = std.fmt.allocPrint(arena, "{s}/{s}", .{ src, e.name }) catch continue;
        const to = std.fmt.allocPrint(arena, "{s}/{s}", .{ dest, e.name }) catch continue;
        switch (e.kind) {
            .file, .sym_link => Io.Dir.cwd().copyFile(from, Io.Dir.cwd(), to, io, .{}) catch continue,
            .directory => copyTree(io, arena, from, to, depth + 1) catch continue,
            else => {},
        }
    }
}

fn join(arena: Allocator, cwd: []const u8, rel: []const u8) []const u8 {
    if (cwd.len == 0 or std.mem.eql(u8, cwd, ".")) return rel;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ cwd, rel }) catch rel;
}

fn pathEq(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const aa = if (a.len > 0 and a[a.len - 1] == '/') a[0 .. a.len - 1] else a;
    const bb = if (b.len > 0 and b[b.len - 1] == '/') b[0 .. b.len - 1] else b;
    if (std.mem.eql(u8, aa, bb)) return true;
    // Worktrees and moved checkouts: match if either path ends with the other.
    if (aa.len > bb.len) return std.mem.endsWith(u8, aa, bb) and aa[aa.len - bb.len - 1] == '/';
    if (bb.len > aa.len) return std.mem.endsWith(u8, bb, aa) and bb[bb.len - aa.len - 1] == '/';
    return false;
}

/// Claude PreToolUse that matches Read/Edit/Write would brick graff's native tools.
fn skipMatcher(m: []const u8) bool {
    return std.mem.indexOf(u8, m, "Read") != null or std.mem.indexOf(u8, m, "Edit") != null or std.mem.indexOf(u8, m, "Write") != null;
}

fn mapMatcher(arena: Allocator, m: []const u8) []const u8 {
    if (m.len == 0) return "*";
    var out = std.array_list.Managed(u8).init(arena);
    var it = std.mem.splitScalar(u8, m, '|');
    var first = true;
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " ");
        const mapped: []const u8 = if (std.mem.eql(u8, p, "Bash")) "bash" else if (std.mem.eql(u8, p, "Read")) "read_file" else if (std.mem.eql(u8, p, "Edit")) "edit_file" else if (std.mem.eql(u8, p, "Write")) "write_file" else p;
        if (!first) out.append('|') catch {};
        first = false;
        out.appendSlice(mapped) catch {};
    }
    return if (out.items.len == 0) "*" else out.items;
}

fn adoptHooks(io: Io, arena: Allocator, home: []const u8, cwd: []const u8) usize {
    _ = cwd;
    if (home.len == 0) return 0;
    const paths = [_][]const u8{
        std.fmt.allocPrint(arena, "{s}/.claude/settings.json", .{home}) catch return 0,
        std.fmt.allocPrint(arena, "{s}/.claude/settings.local.json", .{home}) catch return 0,
    };
    var n: usize = 0;
    var graff: std.json.ObjectMap = .empty;
    for (paths) |p| {
        const text = Io.Dir.cwd().readFileAlloc(io, p, arena, file_cap) catch continue;
        const parsed = std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch continue;
        if (parsed != .object) continue;
        const hooks = parsed.object.get("hooks") orelse continue;
        if (hooks != .object) continue;
        n += harvestClaudeHooks(arena, &graff, hooks.object);
    }
    if (n == 0) return 0;
    var root: std.json.ObjectMap = .empty;
    root.put(arena, "hooks", .{ .object = graff }) catch return n;
    const dest = std.fmt.allocPrint(arena, "{s}/.codegraff/hooks/imported-from-claude.json", .{home}) catch return n;
    if (std.fs.path.dirname(dest)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    s.write(Value{ .object = root }) catch return n;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = aw.writer.buffered() }) catch {};
    return n;
}

fn harvestClaudeHooks(arena: Allocator, dest: *std.json.ObjectMap, hooks: std.json.ObjectMap) usize {
    var n: usize = 0;
    n += takeClaudeEvent(arena, dest, hooks, "PreToolUse", "pre_tool");
    n += takeClaudeEvent(arena, dest, hooks, "PostToolUse", "post_tool");
    n += takeClaudeEvent(arena, dest, hooks, "Stop", "turn_end");
    return n;
}

fn takeClaudeEvent(arena: Allocator, dest: *std.json.ObjectMap, hooks: std.json.ObjectMap, claude_name: []const u8, graff_name: []const u8) usize {
    const ev = hooks.get(claude_name) orelse return 0;
    if (ev != .array) return 0;
    var list = if (dest.get(graff_name)) |v| (if (v == .array) v.array else std.json.Array.init(arena)) else std.json.Array.init(arena);
    var added: usize = 0;
    for (ev.array.items) |item| {
        if (item != .object) continue;
        const matcher = if (item.object.get("matcher")) |m| (if (m == .string) m.string else "") else "";
        if (std.mem.eql(u8, claude_name, "PreToolUse") and skipMatcher(matcher)) continue;
        const inner = item.object.get("hooks") orelse continue;
        if (inner != .array) continue;
        for (inner.array.items) |h| {
            if (h != .object) continue;
            const cmd = h.object.get("command") orelse continue;
            if (cmd != .string or cmd.string.len == 0) continue;
            var entry: std.json.ObjectMap = .empty;
            entry.put(arena, "match", .{ .string = mapMatcher(arena, matcher) }) catch continue;
            entry.put(arena, "command", cmd) catch continue;
            list.append(.{ .object = entry }) catch continue;
            added += 1;
        }
    }
    if (added > 0) dest.put(arena, graff_name, .{ .array = list }) catch {};
    return added;
}

fn adoptRules(io: Io, arena: Allocator, cwd: []const u8) usize {
    var n: usize = 0;
    const dest_dir = join(arena, cwd, ".harness");
    const pairs = [_][2][]const u8{
        .{ join(arena, cwd, "CLAUDE.md"), join(arena, dest_dir, "CLAUDE.md") },
        .{ join(arena, cwd, ".claude/CLAUDE.md"), join(arena, dest_dir, "CLAUDE.md") },
    };
    for (pairs) |pair| {
        if (Io.Dir.cwd().statFile(io, pair[1], .{}) catch null) |_| continue;
        Io.Dir.cwd().copyFile(pair[0], Io.Dir.cwd(), pair[1], io, .{}) catch continue;
        n += 1;
        break;
    }
    return n;
}

fn builtin_desktop(arena: Allocator, home: []const u8) ?[]const u8 {
    if (builtin.os.tag == .macos) {
        return std.fmt.allocPrint(arena, "{s}/Library/Application Support/Claude/claude_desktop_config.json", .{home}) catch null;
    }
    return std.fmt.allocPrint(arena, "{s}/.config/Claude/claude_desktop_config.json", .{home}) catch null;
}

const builtin = @import("builtin");
const testing = std.testing;

test "adopt writes missing Claude MCP into graff folders and skips existing names" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = real_buf[0..try tmp.dir.realPath(io, &real_buf)];
    const home = try std.fmt.allocPrint(arena, "{s}/home", .{base});
    const cwd = try std.fmt.allocPrint(arena, "{s}/proj", .{base});

    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(arena, "{s}/.claude/skills/demo", .{home}));
    try Io.Dir.cwd().createDirPath(io, cwd);
    const payload = try std.fmt.allocPrint(
        arena,
        "{{\"mcpServers\":{{\"codedb\":{{\"command\":\"/bin/codedb\",\"args\":[]}},\"smolify\":{{\"command\":\"x\"}},\"deepwiki\":{{\"url\":\"https://mcp.deepwiki.com/mcp\"}}}},\"projects\":{{{s}:{{\"mcpServers\":{{\"relay\":{{\"command\":\"relay\",\"args\":[\"-s\"]}}}}}}}}}}",
        .{@import("plugin_index.zig").quote(arena, cwd)},
    );
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/.claude.json", .{home}), .data = payload });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/.claude/skills/demo/SKILL.md", .{home}), .data = "---\nname: demo\ndescription: d\n---\nbody\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/.mcp.json", .{cwd}), .data = "{\"mcpServers\":{\"deepwiki\":{\"url\":\"https://keep.example/mcp\"}}}" });

    const r = try run(io, arena, home, cwd);
    try testing.expectEqual(@as(usize, 3), r.added_user);
    try testing.expectEqual(@as(usize, 1), r.added_project);
    try testing.expectEqual(@as(usize, 0), r.skipped);
    try testing.expectEqual(@as(usize, 1), r.skills);

    const global = try Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/.codegraff/mcp.json", .{home}), arena, file_cap);
    try testing.expect(std.mem.indexOf(u8, global, "codedb") != null);
    try testing.expect(std.mem.indexOf(u8, global, "smolify") != null);
    const project = try Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/.mcp.json", .{cwd}), arena, file_cap);
    try testing.expect(std.mem.indexOf(u8, project, "relay") != null);
    try testing.expect(std.mem.indexOf(u8, project, "keep.example") != null);

    const again = try run(io, arena, home, cwd);
    try testing.expectEqual(@as(usize, 0), again.added_user);
    try testing.expectEqual(@as(usize, 0), again.added_project);
    try testing.expect(again.skipped >= 2);
}

test "first-run adopt writes a marker and does not run again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = real_buf[0..try tmp.dir.realPath(io, &real_buf)];
    const home = try std.fmt.allocPrint(arena, "{s}/home", .{base});
    try Io.Dir.cwd().createDirPath(io, home);

    try testing.expect(!alreadyAdopted(io, arena, home));
    const first = try maybeFirstRun(io, arena, home, try std.fmt.allocPrint(arena, "{s}/proj", .{base}));
    try testing.expect(first != null);
    try testing.expect(alreadyAdopted(io, arena, home));
    try testing.expect(try maybeFirstRun(io, arena, home, ".") == null);
}
