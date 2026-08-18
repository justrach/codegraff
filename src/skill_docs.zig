//! Markdown skills: the SKILL.md playbooks the harness discovers on disk and
//! loads into context on demand.
//!
//! NOT to be confused with skills.zig, which is the *companion binary*
//! registry (`/skills add kuri` — CLI tools the harness upgrades itself with
//! when they're on PATH). This module is the document-shaped kind, same layout
//! Claude Code uses: `<dir>/<name>/SKILL.md` (or `<dir>/<name>.md`) with
//! `name:`/`description:` frontmatter and a markdown body. Discovery is tiered
//! like fleet.zig's agent personas — bundled < personal < plugins < project —
//! and disclosure is progressive: only the descriptions ride in the system prompt
//! (promptCatalog), while bodies stay on disk until the `skill` tool loads one
//! (execSkill). Bundled skills teach writing more (skill-creator), MCP
//! config (mcp-config), long-horizon control (jspace), and mid-session
//! worktree switch (workspace).

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const util = @import("util.zig");
const tools = @import("tools.zig");
const ToolOutput = tools.ToolOutput;
// Only the settings-file location, never the approval session (#422 ratchet).
const policy = @import("harness_policy.zig");
const plugins = @import("plugins.zig");

pub const Source = enum {
    builtin,
    personal,
    project,
    plugin,

    pub fn label(self: Source) []const u8 {
        return switch (self) {
            .builtin => "bundled",
            .personal => "personal",
            .project => "project",
            .plugin => "plugin",
        };
    }
};

pub const Skill = struct {
    name: []const u8,
    desc: []const u8,
    body: []const u8,
    /// Directory the SKILL.md came from; "" for a bundled skill. Helper files
    /// that ship with a skill are relative to this, so the load note can point
    /// the model at them.
    dir: []const u8 = "",
    path: []const u8 = "", // the file itself; "" when bundled
    source: Source = .builtin,
};

/// Project tier (checked in with the repo) and the personal tier under $HOME.
pub const project_dir = ".harness/skills";
/// Read as-is so skills already written for Claude Code work here untouched.
pub const compat_dir = ".claude/skills";

const file_cap = 256 * 1024; // largest SKILL.md we'll read on a named load
const head_cap = 8 * 1024; // catalog read: frontmatter + proof of a body
const body_cap = 32 * 1024; // largest body handed to the model in one load
const desc_cap = 160; // per-skill description budget in the system prompt — the trigger, not the summary; the body is one `skill` call away

/// The `skill` tool's name/description/schema. Kept here (as plain strings, not
/// a schema.ToolSpec) so schema.zig's catalog needs one entry and no import
/// cycle. The description must stay free of characters needing JSON escapes.
pub const tool_name = "skill";
pub const tool_desc = "Load a skill: the full instructions for one kind of task, kept out of your context until you need them. The system prompt lists only skill names and descriptions, so call this to read the body BEFORE doing work a skill covers, then follow it. Omit name to list every available skill. Skills come from .harness/skills/, ~/.harness/skills/, .claude/skills/, Cursor/Claude/Grok/Codex plugin trees (including Claude commands/*.md and a root SKILL.md), plus bundled skill-creator, mcp-config, jspace, and workspace.";
pub const tool_schema =
    \\{"type": "object", "properties": {"name": {"type": "string", "description": "Skill name to load; omit to list every available skill"}}}
;

const Parsed = struct { name: []const u8, desc: []const u8, body: []const u8 };

/// Split a SKILL.md into frontmatter fields + body. Same YAML-ish shape as
/// fleet.zig's persona files: a leading "---\n…\n---\n" block with `name:` and
/// `description:` lines. No frontmatter is fine — the file is all body and the
/// name comes from the filename. Comptime-callable (the bundled skills are
/// parsed at build time).
fn parseDoc(fallback_name: []const u8, data: []const u8) Parsed {
    var out: Parsed = .{ .name = fallback_name, .desc = "", .body = std.mem.trim(u8, data, " \t\r\n") };
    // A CRLF checkout (Windows CI, notepad-authored skills) opens "---\r\n";
    // the rest of the parser already tolerates \r via per-line trims.
    const fence_len: usize = if (std.mem.startsWith(u8, data, "---\r\n")) 5 else if (std.mem.startsWith(u8, data, "---\n")) 4 else return out;
    const fm_end = std.mem.indexOfPos(u8, data, fence_len, "\n---") orelse return out;
    var lines = std.mem.tokenizeScalar(u8, data[fence_len..fm_end], '\n');
    while (lines.next()) |raw| {
        const ln = std.mem.trim(u8, raw, " \t\r");
        const sep = std.mem.indexOfScalar(u8, ln, ':') orelse continue;
        const key = std.mem.trim(u8, ln[0..sep], " \t");
        const val = std.mem.trim(u8, ln[sep + 1 ..], " \t\"'");
        if (std.mem.eql(u8, key, "name") and val.len > 0) out.name = val;
        if (std.mem.eql(u8, key, "description") and val.len > 0) out.desc = val;
    }
    out.body = std.mem.trim(u8, data[@min(fm_end + "\n---".len + 1, data.len)..], " \t\r\n");
    return out;
}

const Embedded = struct { fallback: []const u8, bytes: []const u8 };
const embedded = [_]Embedded{
    .{ .fallback = "skill-creator", .bytes = @embedFile("skill_doc_creator") },
    .{ .fallback = "mcp-config", .bytes = @embedFile("skill_doc_mcp_config") },
    .{ .fallback = "jspace", .bytes = @embedFile("skill_doc_jspace") },
    .{ .fallback = "workspace", .bytes = @embedFile("skill_doc_workspace") },
};

/// Skills compiled into the binary: every install has these, no files needed.
/// Parsed at comptime, so a bundled skill missing its description or body is a
/// build error rather than a silently absent capability.
pub const builtins = blk: {
    // Frontmatter tokenizing + body trimming over a few KB of embedded markdown
    // blows the default 1000-branch comptime budget.
    @setEvalBranchQuota(200_000);
    var out: [embedded.len]Skill = undefined;
    for (embedded, 0..) |e, i| {
        const p = parseDoc(e.fallback, e.bytes);
        if (p.desc.len == 0 or p.body.len == 0)
            @compileError("bundled skill '" ++ e.fallback ++ "' needs a frontmatter description and a body");
        out[i] = .{ .name = p.name, .desc = p.desc, .body = p.body };
    }
    break :blk out;
};

/// This session's skills, in precedence order — loaded from the session arena
/// each time startup.buildSystemPrompt composes a prompt. Read by the system
/// prompt and `/skills`; the tool itself rescans instead, so a skill written
/// mid-session is loadable without a restart.
pub var g_skills: []const Skill = &builtins;
/// Resolved HOME for the personal tier, so execSkill's rescan finds the same
/// set the startup scan did.
var g_home: ?[]const u8 = null;

pub fn load(io: Io, arena: Allocator, home: ?[]const u8) []const Skill {
    g_home = home;
    return scan(io, arena, home);
}

/// Re-scan after the installed set may have changed — a `/skills remove` opt-out
/// landing in settings, or a SKILL.md written this session — so `/skills` and
/// any later prompt build stay honest without a restart.
pub fn reload(io: Io, arena: Allocator) []const Skill {
    g_skills = scan(io, arena, g_home);
    return g_skills;
}

/// Every skill on disk *including* opted-out ones, so `/skills add <name>` can
/// tell "disabled" apart from "no such skill".
pub fn scanAll(io: Io, arena: Allocator) []const Skill {
    return collect(io, arena, g_home).items;
}

fn scan(io: Io, arena: Allocator, home: ?[]const u8) []const Skill {
    var list = collect(io, arena, home);
    applyDisabled(io, arena, &list);
    return list.items;
}

/// bundled < personal dirs < user plugins < .claude/.grok/.codex/skills <
/// project plugins < .harness/skills. Each later tier shadows the previous by
/// name. Plugin trees are read in place (ADR 0007), not copied. One `discover`
/// fills both plugin tiers so startup does not walk Cursor/Claude trees four times.
fn collect(io: Io, arena: Allocator, home: ?[]const u8) std.ArrayList(Skill) {
    var list: std.ArrayList(Skill) = .empty;
    list.appendSlice(arena, &builtins) catch {};
    if (home) |h| for ([_][]const u8{ compat_dir, ".codegraff/skills", project_dir, ".grok/skills", ".codex/skills", ".agents/skills", ".cursor/skills-cursor", ".cursor/skills" }) |dir| {
        const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ h, dir }) catch continue;
        loadDir(io, arena, &list, path, .personal);
    };
    const plugs = plugins.discover(io, arena, home, Io.Dir.cwd());
    for (plugs) |p| {
        if (!p.personal) continue;
        for (p.skill_dirs) |d| loadDir(io, arena, &list, d, .plugin);
        if (p.root_skill) |rs| mergeFile(io, arena, &list, rs.dir, rs.path, rs.name, .plugin);
    }
    loadDir(io, arena, &list, compat_dir, .project);
    loadDir(io, arena, &list, ".grok/skills", .project);
    loadDir(io, arena, &list, ".codex/skills", .project);
    loadDir(io, arena, &list, ".cursor/skills", .project);
    for (plugs) |p| {
        if (p.personal) continue;
        for (p.skill_dirs) |d| loadDir(io, arena, &list, d, .plugin);
        if (p.root_skill) |rs| mergeFile(io, arena, &list, rs.dir, rs.path, rs.name, .plugin);
    }
    loadDir(io, arena, &list, project_dir, .project);
    return list;
}

/// Merge one directory's skills: `<dir>/<name>/SKILL.md` (a skill that ships
/// helper files) and `<dir>/<name>.md` (a single-file skill).
fn loadDir(io: Io, arena: Allocator, list: *std.ArrayList(Skill), dir_path: []const u8, source: Source) void {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| switch (entry.kind) {
        .file => {
            if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
            // A bare SKILL.md directly in the skills dir has no name of its own.
            if (std.ascii.eqlIgnoreCase(entry.name, "SKILL.md")) continue;
            const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            mergeFile(io, arena, list, dir_path, path, entry.name[0 .. entry.name.len - ".md".len], source);
        },
        // A symlinked skill directory is common when skills are shared between
        // checkouts; the SKILL.md read below decides whether it's really one.
        .directory, .sym_link => {
            const skill_dir = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            const path = std.fmt.allocPrint(arena, "{s}/SKILL.md", .{skill_dir}) catch continue;
            mergeFile(io, arena, list, skill_dir, path, entry.name, source);
        },
        else => {},
    };
}

fn mergeFile(io: Io, arena: Allocator, list: *std.ArrayList(Skill), dir_path: []const u8, path: []const u8, raw_name: []const u8, source: Source) void {
    // Prefix only: name + description for the prompt. The body stays on disk
    // until `skill name=` / render, same as ADR 0007 and OpenCode's catalog.
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(head_cap)) catch return;
    // raw_name points into the directory iterator's buffer, which the next
    // entry overwrites — the parsed skill has to own it.
    const fallback = arena.dupe(u8, raw_name) catch return;
    const p = parseDoc(fallback, data);
    if (p.body.len == 0) return; // an empty playbook is not a skill
    insert(arena, list, .{
        .name = p.name,
        .desc = p.desc,
        .body = "",
        .dir = dir_path,
        .path = path,
        .source = source,
    });
}

/// Append, or replace the same-named skill from a lower tier.
fn insert(arena: Allocator, list: *std.ArrayList(Skill), sk: Skill) void {
    for (list.items) |*existing| {
        if (std.mem.eql(u8, existing.name, sk.name)) {
            existing.* = sk;
            return;
        }
    }
    list.append(arena, sk) catch {};
}

/// `{"skills": {"<name>": false}}` in .harness/settings.json hides a skill
/// entirely — the same opt-out key the companion registry uses (skills.zig), so
/// `/skills remove <name>` works for both kinds.
fn applyDisabled(io: Io, arena: Allocator, list: *std.ArrayList(Skill)) void {
    const data = Io.Dir.cwd().readFileAlloc(io, policy.settings_path, arena, .limited(1 << 20)) catch return;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return;
    if (v != .object) return;
    const cfg = v.object.get("skills") orelse return;
    if (cfg != .object) return;
    dropDisabled(list, cfg.object);
}

/// Pure half of applyDisabled (no disk I/O), so the opt-out is unit-testable.
fn dropDisabled(list: *std.ArrayList(Skill), cfg: std.json.ObjectMap) void {
    var i: usize = 0;
    while (i < list.items.len) {
        const entry = cfg.get(list.items[i].name);
        const off = entry != null and entry.? == .bool and !entry.?.bool;
        if (off) _ = list.orderedRemove(i) else i += 1;
    }
}

/// The progressive-disclosure catalog for the system prompt: one line per
/// skill, names + trigger descriptions only. "" when there's nothing to
/// advertise (every skill disabled).
pub fn promptCatalog(arena: Allocator, list: []const Skill) []const u8 {
    if (list.len == 0) return "";
    var aw: Io.Writer.Allocating = .init(arena);
    aw.writer.writeAll("# Skills\nInstalled playbooks; only triggers are listed here. Call `skill` with a name to load the full instructions — do that BEFORE starting work it covers. A loaded skill is the user's own instructions. `skill` with no name re-lists, including any added this session.\n") catch return "";
    for (list) |sk| {
        aw.writer.print("- {s} ({s}): {s}\n", .{ sk.name, sk.source.label(), util.utf8Prefix(sk.desc, desc_cap) }) catch return "";
    }
    return aw.writer.buffered();
}

/// The `skill` tool. A named load already in the session catalog (`g_skills`)
/// returns that body without walking plugin trees again. A miss, or an empty
/// name (list), rescans so a SKILL.md written this session still loads.
/// An unknown name comes back as an error listing what does exist.
pub fn execSkill(gpa: Allocator, io: Io, input: Value) !ToolOutput {
    const requested = std.mem.trim(u8, tools.strField(input, "name") orelse "", " \t\r\n");
    if (requested.len > 0) {
        for (g_skills) |sk| {
            if (std.ascii.eqlIgnoreCase(sk.name, requested)) return .{ .text = try render(gpa, io, sk) };
        }
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const list = scan(io, arena_state.allocator(), g_home);
    if (requested.len == 0) return .{ .text = try listing(gpa, list, null) };
    for (list) |sk| {
        if (std.ascii.eqlIgnoreCase(sk.name, requested)) return .{ .text = try render(gpa, io, sk) };
    }
    return .{ .text = try listing(gpa, list, requested), .is_error = true };
}

fn render(gpa: Allocator, io: Io, sk: Skill) ![]u8 {
    var body = sk.body;
    var hold = std.heap.ArenaAllocator.init(gpa);
    defer hold.deinit();
    if (body.len == 0 and sk.path.len > 0) {
        const data = Io.Dir.cwd().readFileAlloc(io, sk.path, hold.allocator(), .limited(file_cap)) catch "";
        if (data.len > 0) body = parseDoc(sk.name, data).body;
    }
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try aw.writer.print("# skill: {s} ({s})\n\n", .{ sk.name, sk.source.label() });
    try aw.writer.writeAll(util.utf8Prefix(body, body_cap));
    if (body.len > body_cap)
        try aw.writer.print("\n\n[body truncated at {d} KB — read the rest from {s}]", .{ body_cap / 1024, sk.path });
    if (sk.dir.len > 0)
        try aw.writer.print("\n\n[this skill lives in {s}/ — read anything it references from there with read_file]", .{sk.dir});
    return aw.toOwnedSlice();
}

fn listing(gpa: Allocator, list: []const Skill, unknown: ?[]const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    if (unknown) |name| try aw.writer.print("no skill named '{s}'. ", .{name});
    if (list.len == 0) return blk: {
        try aw.writer.print("no skills installed — write one at {s}/<name>/SKILL.md (frontmatter: name, description; body: the instructions).", .{project_dir});
        break :blk aw.toOwnedSlice();
    };
    try aw.writer.print("{d} skill(s) available — load one by name:\n", .{list.len});
    for (list) |sk| try aw.writer.print("  {s} ({s}): {s}\n", .{ sk.name, sk.source.label(), sk.desc });
    return aw.toOwnedSlice();
}

// The `/skills` command surface — handleRemove/handleAdd/printSection — lives
// in skill_docs_render.zig (#429). It is the only part of this module that ever
// drew, and drawing is the command layer's job, not the skill subsystem's.

test "parseDoc: frontmatter wins over the filename, body starts after it" {
    const p = parseDoc("from-file", "---\nname: real-name\ndescription: what it does and when\n---\n\n# Body\nstep one\n");
    try std.testing.expectEqualStrings("real-name", p.name);
    try std.testing.expectEqualStrings("what it does and when", p.desc);
    try std.testing.expectEqualStrings("# Body\nstep one", p.body);
}

test "parseDoc: a CRLF checkout still yields frontmatter and body" {
    const p = parseDoc("f", "---\r\nname: n\r\ndescription: d\r\n---\r\nBody.\r\n");
    try std.testing.expectEqualStrings("n", p.name);
    try std.testing.expectEqualStrings("d", p.desc);
    try std.testing.expectEqualStrings("Body.", p.body);
}

test "parseDoc: no frontmatter keeps the filename and the whole file as body" {
    const p = parseDoc("deploy", "\n# Deploy\nrun it\n");
    try std.testing.expectEqualStrings("deploy", p.name);
    try std.testing.expectEqualStrings("", p.desc);
    try std.testing.expectEqualStrings("# Deploy\nrun it", p.body);
    // Unterminated frontmatter is body, not a silently swallowed header.
    const open = parseDoc("x", "---\nname: y\n");
    try std.testing.expectEqualStrings("x", open.name);
    try std.testing.expectEqualStrings("---\nname: y", open.body);
}

test "bundled skills: both parse at comptime with a trigger description" {
    try std.testing.expectEqual(@as(usize, 4), builtins.len);
    try std.testing.expectEqualStrings("skill-creator", builtins[0].name);
    try std.testing.expectEqualStrings("mcp-config", builtins[1].name);
    try std.testing.expectEqualStrings("jspace", builtins[2].name);
    try std.testing.expectEqualStrings("workspace", builtins[3].name);
    for (builtins) |sk| {
        try std.testing.expect(sk.desc.len > 40); // a trigger, not a topic word
        try std.testing.expect(sk.body.len > 500);
        try std.testing.expect(sk.source == .builtin);
        try std.testing.expectEqualStrings("", sk.dir); // nothing on disk to point at
        try std.testing.expect(std.mem.indexOfScalar(u8, sk.name, ' ') == null);
    }
    // Each bundled skill has to actually teach its subject.
    try std.testing.expect(std.mem.indexOf(u8, builtins[0].body, project_dir) != null);
    try std.testing.expect(std.mem.indexOf(u8, builtins[1].body, ".mcp.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, builtins[1].body, "/mcp trust") != null);
    try std.testing.expect(std.mem.indexOf(u8, builtins[2].body, "action=inbox") != null);
    try std.testing.expect(std.mem.indexOf(u8, builtins[3].body, "action=use") != null);
}

test "tool_desc stays JSON-escape-free (it is spliced into a raw schema string)" {
    for (tool_desc) |c| try std.testing.expect(c != '"' and c != '\\' and c >= 0x20);
    try std.testing.expect(std.mem.indexOf(u8, tool_desc, "skill-creator") != null);
    try std.testing.expect(std.mem.indexOf(u8, tool_desc, "mcp-config") != null);
    try std.testing.expect(std.mem.indexOf(u8, tool_desc, "jspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, tool_desc, "workspace") != null);
}

test "insert: a later tier shadows the same name, others append" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var list: std.ArrayList(Skill) = .empty;
    try list.appendSlice(arena, &builtins);
    insert(arena, &list, .{ .name = "mcp-config", .desc = "mine", .body = "project version", .source = .project });
    try std.testing.expectEqual(builtins.len, list.items.len); // shadowed, not appended
    for (list.items) |sk| if (std.mem.eql(u8, sk.name, "mcp-config")) {
        try std.testing.expectEqualStrings("project version", sk.body);
        try std.testing.expect(sk.source == .project);
    };
    insert(arena, &list, .{ .name = "deploy", .desc = "d", .body = "b", .source = .personal });
    try std.testing.expectEqual(builtins.len + 1, list.items.len);
}

test "dropDisabled: {\"<name>\": false} removes it; true and absent keep it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var list: std.ArrayList(Skill) = .empty;
    try list.append(arena, .{ .name = "a", .desc = "", .body = "x" });
    try list.append(arena, .{ .name = "b", .desc = "", .body = "x" });
    try list.append(arena, .{ .name = "c", .desc = "", .body = "x" });
    const v = try std.json.parseFromSliceLeaky(Value, arena, "{\"a\":false,\"b\":true}", .{ .allocate = .alloc_always });
    dropDisabled(&list, v.object);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("b", list.items[0].name);
    try std.testing.expectEqualStrings("c", list.items[1].name);
}

test "promptCatalog: names + descriptions only, never bodies" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const list = [_]Skill{
        .{ .name = "deploy", .desc = "ship a release", .body = "SECRET-BODY-TEXT", .source = .project },
    };
    const text = promptCatalog(arena, &list);
    try std.testing.expect(std.mem.indexOf(u8, text, "deploy (project): ship a release") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "SECRET-BODY-TEXT") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "`skill`") != null);
    try std.testing.expectEqualStrings("", promptCatalog(arena, &.{}));
}

test "promptCatalog: an over-long description is capped on a codepoint boundary" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Built with a comptime loop rather than `**`, which the CI compiler
    // rejects however it is spaced (see fdb12e7): 800 bytes of "é", so the
    // cap lands mid-codepoint without utf8Prefix.
    const long_arr = comptime blk: {
        var buf: [800]u8 = undefined;
        var i: usize = 0;
        while (i < buf.len) : (i += 2) {
            buf[i] = 0xC3;
            buf[i + 1] = 0xA9;
        }
        break :blk buf;
    };
    const long: []const u8 = &long_arr;
    const list = [_]Skill{.{ .name = "x", .desc = long, .body = "b" }};
    const text = promptCatalog(arena, &list);
    try std.testing.expect(std.mem.indexOf(u8, text, long) == null); // capped, not whole
    try std.testing.expect(std.mem.indexOf(u8, text, long[0 .. desc_cap - 1]) != null); // kept a prefix
    try std.testing.expect(std.unicode.utf8ValidateSlice(text)); // never mid-codepoint
}

test "render: bundled load has no file pointer; long bodies say where the rest is" {
    const gpa = std.testing.allocator;
    const bundled = try render(gpa, std.testing.io, builtins[1]);
    defer gpa.free(bundled);
    try std.testing.expect(std.mem.startsWith(u8, bundled, "# skill: mcp-config (bundled)"));
    try std.testing.expect(std.mem.indexOf(u8, bundled, ".mcp.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, bundled, "[this skill lives in") == null); // nothing on disk to point at

    const big = try gpa.alloc(u8, body_cap + 100);
    defer gpa.free(big);
    @memset(big, 'x');
    const long = try render(gpa, std.testing.io, .{ .name = "big", .desc = "", .body = big, .dir = ".harness/skills/big", .path = ".harness/skills/big/SKILL.md", .source = .project });
    defer gpa.free(long);
    try std.testing.expect(std.mem.indexOf(u8, long, "body truncated at 32 KB") != null);
    try std.testing.expect(std.mem.indexOf(u8, long, ".harness/skills/big/SKILL.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, long, "[this skill lives in .harness/skills/big/") != null);
}

test "listing: an unknown name is an error result that names what exists" {
    const gpa = std.testing.allocator;
    const text = try listing(gpa, &builtins, "nope");
    defer gpa.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "no skill named 'nope'."));
    try std.testing.expect(std.mem.indexOf(u8, text, "skill-creator (bundled)") != null);
    const empty = try listing(gpa, &.{}, null);
    defer gpa.free(empty);
    try std.testing.expect(std.mem.indexOf(u8, empty, ".harness/skills/<name>/SKILL.md") != null);
}

test "execSkill: a named load hits the session catalog without a rescan" {
    const prev = g_skills;
    defer g_skills = prev;
    const one = [_]Skill{.{
        .name = "memhit",
        .desc = "d",
        .body = "hello-from-mem",
        .source = .plugin,
    }};
    g_skills = &one;

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena_state.allocator(), "name", .{ .string = "memhit" });
    const out = try execSkill(std.testing.allocator, std.testing.io, .{ .object = obj });
    defer std.testing.allocator.free(out.text);
    try std.testing.expect(!out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "hello-from-mem") != null);
}

test "load: catalog keeps name and desc; named skill reads the body from disk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const home = std.fmt.allocPrint(arena, "{s}/home", .{buf[0..n]}) catch return error.OutOfMemory;
    const dir = std.fmt.allocPrint(arena, "{s}/.harness/skills/secret", .{home}) catch return error.OutOfMemory;
    try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = std.fmt.allocPrint(arena, "{s}/SKILL.md", .{dir}) catch return error.OutOfMemory,
        .data = "---\nname: secret\ndescription: handshake playbook\n---\n\nCATALOG_MUST_NOT_KEEP_THIS_BODY\n",
    });

    const prev_home = g_home;
    const prev_skills = g_skills;
    defer {
        g_home = prev_home;
        g_skills = prev_skills;
    }
    const list = load(io, arena, home);
    var found: ?Skill = null;
    for (list) |sk| {
        if (std.mem.eql(u8, sk.name, "secret")) found = sk;
    }
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("handshake playbook", found.?.desc);
    try std.testing.expectEqualStrings("", found.?.body);
    try std.testing.expect(std.mem.indexOf(u8, found.?.path, "SKILL.md") != null);

    g_skills = list;
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "name", .{ .string = "secret" });
    const out = try execSkill(std.testing.allocator, io, .{ .object = obj });
    defer std.testing.allocator.free(out.text);
    try std.testing.expect(!out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "CATALOG_MUST_NOT_KEEP_THIS_BODY") != null);
}
