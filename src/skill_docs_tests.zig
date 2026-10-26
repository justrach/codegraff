//! skill_docs tests that did not fit under the 600-line cap. Imported from
//! skill_docs.zig's `test {}` so they stay in the suite.

const std = @import("std");
const Io = std.Io;
const skill_docs = @import("skill_docs.zig");

// A playbook larger than the catalog's 8 KB head read must still be listed
// and load in full (#730). Only the catalog read is capped; the named load
// reads the whole file.
test "#730: a SKILL.md over 8 KB stays in the catalog and loads whole" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const home = try std.fmt.allocPrint(arena, "{s}/home", .{buf[0..n]});
    const dir = try std.fmt.allocPrint(arena, "{s}/.harness/skills/graphify", .{home});
    try Io.Dir.cwd().createDirPath(io, dir);

    // 12 KB body: well past head_cap, with a marker only the full read sees.
    var body: std.Io.Writer.Allocating = .init(arena);
    try body.writer.writeAll("---\nname: graphify\ndescription: big playbook\n---\n\n");
    var i: usize = 0;
    while (i < 200) : (i += 1) try body.writer.print("line {d}: the quick brown fox jumps over the lazy dog again\n", .{i});
    try body.writer.writeAll("TAIL_MARKER_PAST_THE_HEAD_CAP\n");
    const text = body.written();
    try std.testing.expect(text.len > 8 * 1024);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/SKILL.md", .{dir}),
        .data = text,
    });

    const prev_skills = skill_docs.g_skills;
    const prev_home = skill_docs.g_home;
    defer {
        skill_docs.g_skills = prev_skills;
        skill_docs.g_home = prev_home; // load() pins `home`, which this arena owns
    }
    const list = skill_docs.load(io, arena, home);
    var found = false;
    for (list) |sk| {
        if (std.mem.eql(u8, sk.name, "graphify")) {
            found = true;
            try std.testing.expectEqualStrings("big playbook", sk.desc);
        }
    }
    try std.testing.expect(found);

    skill_docs.g_skills = list;
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "name", .{ .string = "graphify" });
    const out = try skill_docs.execSkill(std.testing.allocator, io, .{ .object = obj });
    defer std.testing.allocator.free(out.text);
    try std.testing.expect(!out.is_error);
    try std.testing.expect(std.mem.indexOf(u8, out.text, "TAIL_MARKER_PAST_THE_HEAD_CAP") != null);
}

// A workspace's .agents/skills (the cross-tool location Antigravity, Codex and
// Harbor tasks use) is project tier, and --lean still advertises it.
test "project .agents/skills loads, reaches the catalog, and keeps `skill` unfolded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root = try arena.dupe(u8, buf[0..n]);
    const dir = try std.fmt.allocPrint(arena, "{s}/.agents/skills/generate-greeting", .{root});
    try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/SKILL.md", .{dir}),
        .data = "---\nname: generate-greeting\ndescription: Write the greeting file.\n---\n\nWrite the greeting.\n",
    });

    const list = skill_docs.projectSkills(io, arena, root);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("generate-greeting", list[0].name);
    try std.testing.expect(list[0].source == .project);
    const catalog = skill_docs.promptCatalog(arena, list);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "- generate-greeting (project): Write the greeting file.") != null);

    const nlt = @import("no_local_tools.zig");
    const fold = @import("native_fold.zig");
    const saved = skill_docs.g_workspace_skills;
    defer skill_docs.g_workspace_skills = saved;
    skill_docs.g_workspace_skills = false;
    try std.testing.expect(!nlt.leanKeeps("skill"));
    try std.testing.expect(fold.isFolded("skill"));
    skill_docs.g_workspace_skills = true;
    try std.testing.expect(nlt.leanKeeps("skill"));
    try std.testing.expect(!fold.isFolded("skill"));
    try std.testing.expect(!nlt.leanKeeps("workflow") and fold.isFolded("workflow"));
}

test "promptCatalog: names + descriptions only, never bodies" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const list = [_]skill_docs.Skill{
        .{ .name = "deploy", .desc = "ship a release", .body = "SECRET-BODY-TEXT", .source = .project },
    };
    const text = skill_docs.promptCatalog(arena, &list);
    try std.testing.expect(std.mem.indexOf(u8, text, "deploy (project): ship a release") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "SECRET-BODY-TEXT") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "`skill`") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/") == null); // no file paths — they move and bust the cache prefix
    try std.testing.expect(std.mem.indexOf(u8, text, "file:") == null); // Codex prints these; we do not
    try std.testing.expectEqualStrings("", skill_docs.promptCatalog(arena, &.{}));

    const shuffled = [_]skill_docs.Skill{
        .{ .name = "zeta", .desc = "z", .body = "", .source = .personal },
        .{ .name = "alpha", .desc = "a", .body = "", .source = .plugin },
    };
    const ordered = skill_docs.promptCatalog(arena, &shuffled);
    const alpha_at = std.mem.indexOf(u8, ordered, "alpha (plugin)") orelse return error.TestUnexpectedResult;
    const zeta_at = std.mem.indexOf(u8, ordered, "zeta (personal)") orelse return error.TestUnexpectedResult;
    try std.testing.expect(alpha_at < zeta_at);
}

test "bundled skills: both parse at comptime with a trigger description" {
    try std.testing.expectEqual(@as(usize, 5), skill_docs.builtins.len);
    try std.testing.expectEqualStrings("skill-creator", skill_docs.builtins[0].name);
    try std.testing.expectEqualStrings("mcp-config", skill_docs.builtins[1].name);
    try std.testing.expectEqualStrings("mcp", skill_docs.builtins[2].name);
    try std.testing.expectEqualStrings("jspace", skill_docs.builtins[3].name);
    try std.testing.expectEqualStrings("workspace", skill_docs.builtins[4].name);
    const subjects = [_][]const u8{ skill_docs.project_dir, ".mcp.json", "graff mcp add", "action=inbox", "action=use" };
    for (skill_docs.builtins, subjects, 0..) |sk, subject, i| {
        const doc = try @import("update_archive.zig").gunzip(std.testing.allocator, sk.gzip_doc);
        defer std.testing.allocator.free(doc);
        try std.testing.expect(doc.len > 500);
        try std.testing.expect(std.mem.indexOf(u8, doc, subject) != null);
        if (i == 1) try std.testing.expect(std.mem.indexOf(u8, doc, "/mcp trust") != null);
        try std.testing.expect(sk.desc.len > 40); // a trigger, not a topic word
        try std.testing.expectEqualStrings("", sk.body);
        try std.testing.expect(sk.gzip_doc.len > 0);
        try std.testing.expect(sk.source == .builtin);
        try std.testing.expectEqualStrings("", sk.dir); // nothing on disk to point at
        try std.testing.expect(std.mem.indexOfScalar(u8, sk.name, ' ') == null);
    }
}
