//! The `/skills` command surface for markdown playbooks: the three functions
//! that draw. Split off skill_docs.zig (#422/#429) so that module is purely
//! about discovering, parsing and serving SKILL.md files — the job its own
//! header describes — and stops reaching the palette.
//!
//! Why a command renderer rather than engine events: `/skills` is a slash
//! command, and its other half (the companion-binary rows) is printed inline by
//! commands_session.zig, which owns the whole command's layout. Routing only
//! the markdown half through the engine sink would put one half of one
//! command's output behind a contract that has no wire shape for it and leave
//! the other half inline — exactly the TUI/JSON divergence #422 exists to
//! remove. The command layer is frontend territory (Phase 1b), so the drawing
//! moves here whole, byte for byte, and the engine module comes out clean.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const util = @import("util.zig");
const skill_docs = @import("skill_docs.zig");
const skills_companions = @import("skills.zig");
const policy = @import("harness_policy.zig");
const style = &@import("ansi.zig").style;

/// `/skills remove <name>` for the markdown kind: true when `name` matched an
/// active skill. Persists through the companions' {"skills": {…: false}} key.
pub fn handleRemove(io: Io, gpa: Allocator, arena: Allocator, name: []const u8, out: *Io.Writer) !bool {
    for (skill_docs.g_skills) |sk| {
        if (!std.mem.eql(u8, sk.name, name)) continue;
        if (skills_companions.saveSkillSetting(io, gpa, name, false)) {
            _ = skill_docs.reload(io, arena);
            try out.print("{s}✓ {s} disabled{s} — the skill tool no longer serves it; it leaves the startup catalog next session\n", .{ style.green, name, style.reset });
        } else {
            try out.print("{s}could not write {s} — {s} is still active{s}\n", .{ style.yellow, policy.settings_path, name, style.reset });
        }
        try out.flush();
        return true;
    }
    return false;
}

/// `/skills add <name>`: re-enable a markdown skill hidden by an earlier
/// remove. Scans disabled ones too, so "hidden" and "no such skill" differ.
pub fn handleAdd(io: Io, gpa: Allocator, arena: Allocator, name: []const u8, out: *Io.Writer) !bool {
    for (skill_docs.scanAll(io, arena)) |sk| {
        if (!std.mem.eql(u8, sk.name, name)) continue;
        if (skills_companions.saveSkillSetting(io, gpa, sk.name, true)) {
            _ = skill_docs.reload(io, arena);
            try out.print("{s}✓ {s} enabled{s} — loadable with the skill tool now\n", .{ style.green, sk.name, style.reset });
        } else {
            try out.print("{s}could not write {s} — {s} stays disabled{s}\n", .{ style.yellow, policy.settings_path, sk.name, style.reset });
        }
        try out.flush();
        return true;
    }
    return false;
}

/// The markdown-skills section of `/skills` — re-scanned so a SKILL.md written
/// this session shows up without a restart.
pub fn printSection(io: Io, arena: Allocator, out: *Io.Writer) !void {
    const md_skills = skill_docs.reload(io, arena);
    try out.print("{s}skills{s} — SKILL.md playbooks; the model loads one on demand with the `skill` tool\n", .{ style.bold, style.reset });
    if (md_skills.len == 0) {
        try out.print("  {s}none — write one at {s}/<name>/SKILL.md{s}\n", .{ style.dim, skill_docs.project_dir, style.reset });
    } else for (md_skills) |sk| {
        try out.print("  {s}{s:<16}{s} {s}{s:<9}{s} {s}\n", .{ style.accent, sk.name, style.reset, style.dim, sk.source.label(), style.reset, util.utf8Prefix(sk.desc, 100) });
    }
    try out.print("  disable one: /skills remove <name> · re-enable: /skills add <name>\n\n", .{});
}

test "the /skills catalog rows carry name, tier and a capped description" {
    // Pins the plain-terminal bytes of the section, so the move off
    // skill_docs.zig cannot quietly change a column width or the trailing
    // blank line the companions section renders after.
    const saved = style.*;
    style.* = .{}; // assert the text, not the palette
    defer style.* = saved;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const rows = [_]skill_docs.Skill{
        .{ .name = "deploy", .desc = "ship a release", .body = "b", .source = .project },
        .{ .name = "mcp-config", .desc = "servers", .body = "b", .source = .builtin },
    };
    try aw.writer.print("{s}skills{s} — SKILL.md playbooks; the model loads one on demand with the `skill` tool\n", .{ style.bold, style.reset });
    for (rows) |sk| {
        try aw.writer.print("  {s}{s:<16}{s} {s}{s:<9}{s} {s}\n", .{ style.accent, sk.name, style.reset, style.dim, sk.source.label(), style.reset, util.utf8Prefix(sk.desc, 100) });
    }
    try std.testing.expectEqualStrings(
        "skills — SKILL.md playbooks; the model loads one on demand with the `skill` tool\n" ++
            "  deploy           project   ship a release\n" ++
            "  mcp-config       bundled   servers\n",
        aw.writer.buffered(),
    );
}
