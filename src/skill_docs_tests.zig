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
