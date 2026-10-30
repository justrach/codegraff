//! Is a proposed harness tree one graff can run? Every problem comes back as
//! one line of actionable prose, because the list is fed verbatim to the
//! proposer as retry feedback: say what is wrong and what to do instead.
//!
//! Beyond shape (paths, sizes, frontmatter, hook JSON), two rules keep a
//! refine loop honest. References to helper scripts must resolve inside the
//! tree, so a probe never fails on a file the proposal forgot. And text the
//! proposal adds may not talk about grading: the loop improves the work from
//! how runs behaved, and a harness that cites a rubric or a grader is tuning
//! to a measurement it should never see.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const tree_mod = @import("harness_tree.zig");
const Tree = tree_mod.Tree;

pub const grader_words = [_][]const u8{ "rubric", "grader", "grading criteria", "hidden test", "judge's", "the judge" };
const hook_events = [_][]const u8{ "pre_tool", "post_tool", "turn_end" };

/// Every problem with `tree`, one line each; empty means it can run. `base`
/// is the tree the proposal started from: grading language already in it is
/// the user's and is not held against the proposal.
pub fn problems(arena: Allocator, tree: Tree, base: ?Tree) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (tree.files.len > tree_mod.max_files)
        try say(arena, &out, "the harness has {d} files; keep it to {d} or fewer by merging or dropping the least useful ones", .{ tree.files.len, tree_mod.max_files });
    var n_instructions: usize = 0;
    for (tree.files, 0..) |f, i| {
        if (i > 0 and !std.mem.lessThan(u8, tree.files[i - 1].path, f.path))
            try say(arena, &out, "{s} appears twice or out of order; list each path once", .{f.path});
        const part = tree_mod.classify(f.path) orelse {
            try say(arena, &out, "{s} is not part of the harness; use the instruction file, {s}/<name>/SKILL.md, {s}/<name>.md, {s}/<file>, or the hooks in {s} (names are lowercase letters, digits, `_` or `-`)", .{ f.path, tree_mod.skills_dir, tree_mod.agents_dir, tree_mod.scripts_dir, tree_mod.hooks_path });
            continue;
        };
        if (f.data.len > tree_mod.max_file_bytes)
            try say(arena, &out, "{s} is {d} bytes; keep each file under {d}", .{ f.path, f.data.len, tree_mod.max_file_bytes });
        switch (part) {
            .instructions => {
                n_instructions += 1;
                const cap = @import("context_limits.zig").agents_md_bytes;
                if (f.data.len > cap)
                    try say(arena, &out, "{s} is {d} bytes but graff reads only the first {d}; move detail into a skill and keep the instruction file short", .{ f.path, f.data.len, cap });
            },
            .skill => try checkSkill(arena, &out, f),
            .skill_file => {
                const name = tree_mod.skillName(f.path).?;
                const doc = try std.fmt.allocPrint(arena, "{s}/{s}/SKILL.md", .{ tree_mod.skills_dir, name });
                if (tree.get(doc) == null)
                    try say(arena, &out, "{s} belongs to skill `{s}`, which has no {s}; add one or drop the file", .{ f.path, name, doc });
            },
            .subagent => {
                const base_name = std.fs.path.basename(f.path);
                if (@import("agent_file.zig").parse(arena, base_name, f.data) == null)
                    try say(arena, &out, "{s} has no prompt body; a subagent file needs instructions after its frontmatter", .{f.path});
            },
            .script => {},
            .hooks => try checkHooks(arena, &out, f.data),
        }
        try checkScriptRefs(arena, &out, tree, f);
        try checkGraderWords(arena, &out, f, if (base) |b| b.get(f.path) else null);
    }
    if (n_instructions > 1)
        try say(arena, &out, "the harness has {d} instruction files but graff reads only the first non-empty one; keep a single instruction file", .{n_instructions});
    return out.items;
}

/// The problems as one message, or null when there are none.
pub fn report(arena: Allocator, tree: Tree, base: ?Tree) !?[]const u8 {
    const list = try problems(arena, tree, base);
    if (list.len == 0) return null;
    var buf: std.Io.Writer.Allocating = .init(arena);
    for (list) |p| try buf.writer.print("- {s}\n", .{p});
    return buf.writer.buffered();
}

fn say(arena: Allocator, out: *std.ArrayList([]const u8), comptime fmt: []const u8, args: anytype) !void {
    try out.append(arena, try std.fmt.allocPrint(arena, fmt, args));
}

fn checkSkill(arena: Allocator, out: *std.ArrayList([]const u8), f: tree_mod.File) !void {
    const dir_name = tree_mod.skillName(f.path).?;
    const doc = @import("skill_docs.zig").parseDoc(dir_name, f.data);
    if (!std.mem.startsWith(u8, f.data, "---"))
        return say(arena, out, "{s} needs frontmatter: start it with ---, then `name: {s}` and a one-line `description:`, then ---", .{ f.path, dir_name });
    if (doc.desc.len == 0)
        try say(arena, out, "{s} has no `description:`; graff shows only the description until the skill is loaded, so say when to use it", .{f.path});
    if (!std.mem.eql(u8, doc.name, dir_name))
        try say(arena, out, "{s} is named `{s}` in its frontmatter; use `name: {s}` to match its directory", .{ f.path, doc.name, dir_name });
    if (doc.body.len == 0) try say(arena, out, "{s} has no body after its frontmatter", .{f.path});
}

fn checkHooks(arena: Allocator, out: *std.ArrayList([]const u8), data: []const u8) !void {
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{}) catch
        return say(arena, out, "the hooks are not valid JSON; write an object like {{\"pre_tool\": [{{\"match\": \"shell\", \"command\": \"python3 .harness/scripts/guard.py\"}}]}}", .{});
    if (v != .object) return say(arena, out, "the hooks must be a JSON object keyed by pre_tool, post_tool or turn_end", .{});
    var it = v.object.iterator();
    while (it.next()) |kv| {
        const event = kv.key_ptr.*;
        if (!known(event)) {
            try say(arena, out, "hook event `{s}` does not exist; use pre_tool, post_tool or turn_end", .{event});
            continue;
        }
        if (kv.value_ptr.* != .array) {
            try say(arena, out, "hooks.{s} must be a list of {{\"command\": ...}} objects", .{event});
            continue;
        }
        for (kv.value_ptr.array.items, 0..) |h, i| {
            const cmd = if (h == .object) h.object.get("command") else null;
            if (cmd == null or cmd.? != .string or std.mem.trim(u8, cmd.?.string, " \t").len == 0)
                try say(arena, out, "hooks.{s}[{d}] needs a non-empty string `command`", .{ event, i });
        }
    }
}

fn known(event: []const u8) bool {
    for (hook_events) |e| if (std.mem.eql(u8, e, event)) return true;
    return false;
}

/// Every `.harness/scripts/<file>` a harness file mentions must be in the tree.
fn checkScriptRefs(arena: Allocator, out: *std.ArrayList([]const u8), tree: Tree, f: tree_mod.File) !void {
    const prefix = tree_mod.scripts_dir ++ "/";
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, f.data, at, prefix)) |start| {
        var end = start + prefix.len;
        while (end < f.data.len and isPathByte(f.data[end])) end += 1;
        while (end > start + prefix.len and f.data[end - 1] == '.') end -= 1; // sentence period
        at = end;
        if (end == start + prefix.len) continue;
        const ref = f.data[start..end];
        if (tree.get(ref) == null)
            try say(arena, out, "{s} mentions {s}, which is not in the harness; add the script or drop the mention", .{ f.path, ref });
    }
}

fn isPathByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == '/';
}

fn checkGraderWords(arena: Allocator, out: *std.ArrayList([]const u8), f: tree_mod.File, before: ?[]const u8) !void {
    for (grader_words) |word| {
        if (countFold(f.data, word) > if (before) |b| countFold(b, word) else 0)
            try say(arena, out, "{s} adds text about `{s}`; describe the work itself, not how it is graded", .{ f.path, word });
    }
}

fn countFold(hay: []const u8, needle: []const u8) usize {
    if (needle.len == 0 or hay.len < needle.len) return 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) n += 1;
    }
    return n;
}
