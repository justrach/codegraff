//! The harness tree: what is on the surface, load/write round trips, the
//! digest, and the checker's feedback.

const std = @import("std");
const tree_mod = @import("harness_tree.zig");
const check_mod = @import("harness_tree_check.zig");
const cli = @import("harness_tree_cli.zig");
const Tree = tree_mod.Tree;
const File = tree_mod.File;

const skill_doc = "---\nname: totals\ndescription: Use when a report sums columns.\n---\nRun python3 .harness/scripts/sum.py before answering.\n";
const agent_doc = "---\nname: reviewer\ndescription: Reviews a draft.\n---\nRead the draft and list concrete defects.\n";

fn put(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    const io = std.testing.io;
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

fn sample(dir: std.Io.Dir) !void {
    try put(dir, "AGENTS.md", "Be terse.\n");
    try put(dir, "CLAUDE.md", "shadowed by AGENTS.md\n");
    try put(dir, ".agents/skills/totals/SKILL.md", skill_doc);
    try put(dir, ".agents/skills/totals/scripts/check.py", "print('ok')\n");
    try put(dir, ".agents/skills/Bad Name/SKILL.md", skill_doc);
    try put(dir, ".harness/agents/reviewer.md", agent_doc);
    try put(dir, ".harness/scripts/sum.py", "print(1)\n");
    try put(dir, ".harness/settings.json", "{\"model\":\"keep-me\",\"hooks\":{\"turn_end\":[{\"command\":\"true\"}]}}");
    try put(dir, "src/main.py", "not harness\n");
}

test "the harness surface is the files graff loads to decide how it works" {
    const cases = .{
        .{ "AGENTS.md", tree_mod.Part.instructions },
        .{ "CLAUDE.md", tree_mod.Part.instructions },
        .{ ".agents/skills/totals/SKILL.md", tree_mod.Part.skill },
        .{ ".agents/skills/totals.md", tree_mod.Part.skill },
        .{ ".agents/skills/totals/scripts/check.py", tree_mod.Part.skill_file },
        .{ ".harness/agents/reviewer.md", tree_mod.Part.subagent },
        .{ ".harness/agents/reviewer.toml", tree_mod.Part.subagent },
        .{ ".harness/scripts/sum.py", tree_mod.Part.script },
        .{ ".harness/settings.json", tree_mod.Part.hooks },
    };
    inline for (cases) |c| try std.testing.expectEqual(@as(?tree_mod.Part, c[1]), tree_mod.classify(c[0]));
    for ([_][]const u8{
        "README.md",                  "src/main.zig",                ".agents/skills/Bad Name/SKILL.md",
        ".agents/skills/x/../../etc", ".agents/skills/x/a/b/c/d.py", ".harness/agents/notes.txt",
        ".harness/scripts/sub/x.py",  ".harness/scripts/.hidden",    ".agents/skills",
        "docs/AGENTS.md",
    }) |path| try std.testing.expectEqual(@as(?tree_mod.Part, null), tree_mod.classify(path));
}

test "load reads the active instruction file, skills, subagents, scripts and hooks" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try sample(tmp.dir);

    const loaded = try tree_mod.load(io, a, tmp.dir);
    const paths = [_][]const u8{
        ".agents/skills/totals/SKILL.md", ".agents/skills/totals/scripts/check.py", ".harness/agents/reviewer.md",
        ".harness/scripts/sum.py",        ".harness/settings.json",                 "AGENTS.md",
    };
    try std.testing.expectEqual(paths.len, loaded.tree.files.len);
    for (paths, loaded.tree.files) |want, got| try std.testing.expectEqualStrings(want, got.path);
    try std.testing.expectEqual(@as(usize, 1), loaded.skipped.len);
    try std.testing.expectEqualStrings(".agents/skills/Bad Name/SKILL.md", loaded.skipped[0]);
    // The hooks file carries only the hooks object, not the other settings.
    const hooks = loaded.tree.get(".harness/settings.json").?;
    try std.testing.expect(std.mem.indexOf(u8, hooks, "turn_end") != null);
    try std.testing.expect(std.mem.indexOf(u8, hooks, "keep-me") == null);
    try std.testing.expectEqual(@as(usize, 0), (try check_mod.problems(a, loaded.tree, null)).len);
}

test "write makes a checkout's harness exactly the tree and leaves the rest alone" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var src = std.testing.tmpDir(.{ .iterate = true });
    defer src.cleanup();
    var dst = std.testing.tmpDir(.{ .iterate = true });
    defer dst.cleanup();
    try sample(src.dir);
    const tree = (try tree_mod.load(io, a, src.dir)).tree;

    // The destination has a stale skill, other settings, and project files.
    try put(dst.dir, ".agents/skills/stale/SKILL.md", skill_doc);
    try put(dst.dir, ".agents/skills/stale/scripts/old.py", "x\n");
    try put(dst.dir, ".harness/settings.json", "{\"theme\":\"dark\"}");
    try put(dst.dir, "src/app.py", "project code\n");
    try tree_mod.write(io, a, tree, dst.dir);

    const again = (try tree_mod.load(io, a, dst.dir)).tree;
    try std.testing.expectEqualSlices(u8, &tree_mod.digest(tree), &tree_mod.digest(again));
    try std.testing.expectError(error.FileNotFound, dst.dir.access(io, ".agents/skills/stale", .{}));
    const settings = try dst.dir.readFileAlloc(io, ".harness/settings.json", a, .limited(1 << 16));
    try std.testing.expect(std.mem.indexOf(u8, settings, "\"theme\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, settings, "turn_end") != null);
    try dst.dir.access(io, "src/app.py", .{});

    // Dropping the hooks removes only that key.
    var no_hooks: std.ArrayList(File) = .empty;
    for (tree.files) |f| if (tree_mod.classify(f.path) != .hooks) try no_hooks.append(a, f);
    try tree_mod.write(io, a, .{ .files = no_hooks.items }, dst.dir);
    const after = try dst.dir.readFileAlloc(io, ".harness/settings.json", a, .limited(1 << 16));
    try std.testing.expect(std.mem.indexOf(u8, after, "\"theme\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "hooks") == null);
}

test "a tree whose instruction file is CLAUDE.md removes an AGENTS.md that would shadow it" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var dst = std.testing.tmpDir(.{ .iterate = true });
    defer dst.cleanup();
    try put(dst.dir, "AGENTS.md", "old rules\n");
    const files = [_]File{.{ .path = "CLAUDE.md", .data = "new rules\n" }};
    try tree_mod.write(io, a, .{ .files = &files }, dst.dir);
    try std.testing.expectError(error.FileNotFound, dst.dir.access(io, "AGENTS.md", .{}));
    const loaded = try tree_mod.load(io, a, dst.dir);
    try std.testing.expectEqualStrings("CLAUDE.md", loaded.tree.instructions().?.path);
}

test "the digest names the content and diff names the changed paths" {
    const a_files = [_]File{ .{ .path = "AGENTS.md", .data = "one" }, .{ .path = ".harness/scripts/x.py", .data = "x" } };
    const b_files = [_]File{ .{ .path = "AGENTS.md", .data = "two" }, .{ .path = ".harness/agents/r.md", .data = "r" } };
    const t1: Tree = .{ .files = &a_files };
    const t2: Tree = .{ .files = &b_files };
    try std.testing.expectEqualSlices(u8, &tree_mod.digest(t1), &tree_mod.digest(.{ .files = &a_files }));
    try std.testing.expect(!std.mem.eql(u8, &tree_mod.digest(t1), &tree_mod.digest(t2)));
    // Moving bytes between path and data must not collide.
    const c1 = [_]File{.{ .path = "AGENTS.md", .data = "ab" }};
    const c2 = [_]File{.{ .path = "AGENTS.mda", .data = "b" }};
    try std.testing.expect(!std.mem.eql(u8, &tree_mod.digest(.{ .files = &c1 }), &tree_mod.digest(.{ .files = &c2 })));

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const d = try tree_mod.diff(arena_state.allocator(), t1, t2);
    try std.testing.expectEqualStrings(".harness/agents/r.md", d.added[0]);
    try std.testing.expectEqualStrings(".harness/scripts/x.py", d.removed[0]);
    try std.testing.expectEqualStrings("AGENTS.md", d.modified[0]);
    try std.testing.expect((try tree_mod.diff(arena_state.allocator(), t1, t1)).empty());
}

fn expectProblem(list: []const []const u8, needle: []const u8) !void {
    for (list) |p| if (std.mem.indexOf(u8, p, needle) != null) return;
    std.debug.print("no problem mentions {s}; got:\n", .{needle});
    for (list) |p| std.debug.print("  {s}\n", .{p});
    return error.TestExpectedProblem;
}

test "check says what is wrong with a proposal and how to fix it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const long = try a.alloc(u8, @import("context_limits.zig").agents_md_bytes + 1);
    @memset(long, 'x');
    const files = [_]File{
        .{ .path = ".agents/skills/loose/scripts/a.py", .data = "x" },
        .{ .path = ".agents/skills/nofront/SKILL.md", .data = "just a body\n" },
        .{ .path = ".agents/skills/totals/SKILL.md", .data = "---\nname: total\ndescription: d\n---\nUse .harness/scripts/missing.py.\n" },
        .{ .path = ".harness/agents/empty.md", .data = "---\nname: empty\n---\n" },
        .{ .path = ".harness/settings.json", .data = "{\"on_start\":[],\"pre_tool\":[{\"match\":\"shell\"}]}" },
        .{ .path = "AGENTS.md", .data = long },
        .{ .path = "notes/idea.md", .data = "x" },
    };
    const list = try check_mod.problems(a, .{ .files = &files }, null);
    try expectProblem(list, "skill `loose`, which has no");
    try expectProblem(list, "nofront/SKILL.md needs frontmatter");
    try expectProblem(list, "use `name: totals`");
    try expectProblem(list, "missing.py, which is not in the harness");
    try expectProblem(list, "empty.md has no prompt body");
    try expectProblem(list, "hook event `on_start` does not exist");
    try expectProblem(list, "hooks.pre_tool[0] needs a non-empty string `command`");
    try expectProblem(list, "graff reads only the first");
    try expectProblem(list, "notes/idea.md is not part of the harness");
}

test "check rejects grading language a proposal adds but not what the base already had" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = [_]File{.{ .path = "AGENTS.md", .data = "Our rubric for reviews lives in docs/.\n" }};
    const same = [_]File{.{ .path = "AGENTS.md", .data = "Our rubric for reviews lives in docs/.\nBe terse.\n" }};
    const gamed = [_]File{.{ .path = "AGENTS.md", .data = "Our rubric for reviews lives in docs/.\nThe grader wants a table; match the Rubric.\n" }};
    try std.testing.expectEqual(@as(usize, 0), (try check_mod.problems(a, .{ .files = &same }, .{ .files = &base })).len);
    const list = try check_mod.problems(a, .{ .files = &gamed }, .{ .files = &base });
    try expectProblem(list, "`rubric`");
    try expectProblem(list, "`grader`");
}

test "harness-tree apply exports a harness that check accepts and digests the same" {
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try sample(tmp.dir);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const exported = try std.fmt.allocPrint(a, "{s}/exported", .{root});

    var sink: std.Io.Writer.Allocating = .init(a);
    try std.testing.expectEqual(@as(u8, 0), try cli.run(io, a, &sink.writer, &.{ "apply", root, exported }));
    sink.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try cli.run(io, a, &sink.writer, &.{ "check", exported, "--base", root }));
    try std.testing.expect(std.mem.startsWith(u8, sink.writer.buffered(), "ok "));

    // A file the proposer put outside the surface is reported, not ignored.
    try put(tmp.dir, "exported/skills/new/SKILL.md", skill_doc);
    sink.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 1), try cli.run(io, a, &sink.writer, &.{ "check", exported }));
    try std.testing.expect(std.mem.indexOf(u8, sink.writer.buffered(), "skills/new/SKILL.md is not part of the harness") != null);
}
