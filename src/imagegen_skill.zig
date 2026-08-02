//! #352: locating the Codex `imagegen` skill and mirroring it into graff's own
//! personal skill tier.
//!
//! The skill is the tool's reason to exist. Codex ships it at
//! `$CODEX_HOME/skills/.system/imagegen/` (CODEX_HOME defaults to ~/.codex),
//! and its `scripts/image_gen.py` is the only image engine that actually
//! renders anything for us: the `image_gen` tool the SKILL.md calls "preferred"
//! is hosted server-side inside the Codex app and never fires here (#352).
//!
//! Two things happen when it is found:
//!   1. the `imagegen` tool becomes available (tool_gates.zig);
//!   2. the whole skill directory is copied into `~/.harness/skills/imagegen/`
//!      so `skill imagegen` resolves through graff's existing personal-tier
//!      scan (skill_docs.zig) with its references/, scripts/ and LICENSE.txt
//!      intact — a skill separated from its license is not a skill we should
//!      be shipping around.
//!
//! The copy is not verbatim: a graff addendum is spliced in directly after the
//! frontmatter, because following the document as written would send the model
//! straight at a tool that does not exist here. The addendum is first in the
//! body on purpose — a correction that arrives after 24 KB of instructions for
//! the wrong tool has already lost.
//!
//! Refresh policy: copy when the destination is missing, or when the source
//! SKILL.md is newer than the copy. Otherwise leave it alone — a user who
//! edited their copy keeps their edits until Codex itself ships a new version.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Where Codex keeps it, relative to CODEX_HOME.
pub const codex_rel = "skills/.system/imagegen";
/// Where we mirror it, relative to $HOME (graff's personal skill tier).
pub const install_rel = ".harness/skills/imagegen";

const max_depth: u8 = 6; // the real tree is 2 deep; this is a runaway-symlink stop
const skill_md_cap = 512 * 1024;

/// `$CODEX_HOME/skills/.system/imagegen`, or `$HOME/.codex/...` when
/// CODEX_HOME is unset. Null when neither is known.
pub fn codexSkillDir(arena: Allocator, codex_home: ?[]const u8, home: ?[]const u8) ?[]const u8 {
    const base: []const u8 = blk: {
        if (codex_home) |value| {
            if (value.len > 0) break :blk value;
        }
        const h = home orelse return null;
        if (h.len == 0) return null;
        break :blk std.fmt.allocPrint(arena, "{s}/.codex", .{h}) catch return null;
    };
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ base, codex_rel }) catch null;
}

/// `$HOME/.harness/skills/imagegen`.
pub fn installDir(arena: Allocator, home: ?[]const u8) ?[]const u8 {
    const h = home orelse return null;
    if (h.len == 0) return null;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ h, install_rel }) catch null;
}

/// mtime of `<dir>/SKILL.md`, or null when there is no readable SKILL.md —
/// which is also the "is this really the skill?" test.
pub fn skillMtime(io: Io, arena: Allocator, dir: []const u8) ?i128 {
    const path = std.fmt.allocPrint(arena, "{s}/SKILL.md", .{dir}) catch return null;
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    if (st.kind != .file) return null;
    return st.mtime.nanoseconds;
}

pub fn present(io: Io, arena: Allocator, dir: []const u8) bool {
    return skillMtime(io, arena, dir) != null;
}

/// Copy when the destination has no SKILL.md, or the source's is newer.
pub fn needsSync(io: Io, arena: Allocator, src: []const u8, dest: []const u8) bool {
    const src_mtime = skillMtime(io, arena, src) orelse return false; // nothing to copy
    const dest_mtime = skillMtime(io, arena, dest) orelse return true; // nothing copied yet
    return src_mtime > dest_mtime;
}

/// Mirror the skill, then overwrite the copied SKILL.md with the addended
/// version. Best-effort per entry: one unreadable asset must not cost us the
/// scripts and the license.
pub fn sync(io: Io, arena: Allocator, src: []const u8, dest: []const u8) !void {
    try copyTree(io, arena, src, dest, 0);
    const src_md = try std.fmt.allocPrint(arena, "{s}/SKILL.md", .{src});
    const dest_md = try std.fmt.allocPrint(arena, "{s}/SKILL.md", .{dest});
    const original = try Io.Dir.cwd().readFileAlloc(io, src_md, arena, .limited(skill_md_cap));
    const patched = try withAddendum(arena, original);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dest_md, .data = patched });
}

fn copyTree(io: Io, arena: Allocator, src: []const u8, dest: []const u8, depth: u8) !void {
    if (depth > max_depth) return;
    try Io.Dir.cwd().createDirPath(io, dest);
    var dir = try Io.Dir.cwd().openDir(io, src, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const from = std.fmt.allocPrint(arena, "{s}/{s}", .{ src, entry.name }) catch continue;
        const to = std.fmt.allocPrint(arena, "{s}/{s}", .{ dest, entry.name }) catch continue;
        switch (entry.kind) {
            // sym_link included: copyFile follows it, so a symlinked script
            // lands as a real file in the copy rather than a dangling link.
            .file, .sym_link => Io.Dir.cwd().copyFile(from, Io.Dir.cwd(), to, io, .{}) catch continue,
            .directory => copyTree(io, arena, from, to, depth + 1) catch continue,
            else => {},
        }
    }
}

/// The correction spliced into the copied SKILL.md. Everything in it is a
/// statement about THIS harness that the upstream document gets wrong.
pub const addendum =
    \\<!-- graff addendum -->
    \\> **graff note — read this before following anything below.**
    \\>
    \\> This is a copy of the Codex `imagegen` skill, installed by graff. Parts of it
    \\> do not apply here:
    \\>
    \\> - **There is no built-in `image_gen` tool in graff.** It is hosted server-side
    \\>   inside the Codex app and never fires here. Every instruction below that
    \\>   says to prefer the built-in tool, or that describes "default built-in tool
    \\>   mode", does not apply. Do not claim an image was generated by it.
    \\> - **Use graff's `imagegen` tool instead** (this document calls it `$imagegen`;
    \\>   the tool name is plain `imagegen` because provider tool names cannot
    \\>   contain `$`). It runs this skill's bundled `scripts/image_gen.py` CLI —
    \\>   the fallback path described below — so the CLI reference, prompting guide
    \\>   and sample prompts here ARE accurate and worth reading.
    \\> - **`OPENAI_API_KEY` is required.** The CLI is the only engine available, so
    \\>   the keyless path this document describes does not exist here. Without the
    \\>   key the tool returns an error and generates nothing.
    \\> - **The tool verifies its own output.** It only reports success after the
    \\>   file exists, is newer than the run, is large enough, and carries the right
    \\>   container signature. Never report a generated image that the tool did not
    \\>   return a verified path for, and never substitute an existing file for one
    \\>   you failed to generate.
    \\> - **For several images, fan out with subagents.** Spawn one subagent per
    \\>   image (`subagent`, or one `workflow` task each); each child calls
    \\>   `imagegen` exactly once for its own image and reports the verified path
    \\>   back. That is how generations run concurrently — a single agent calling
    \\>   `imagegen` N times in a row is serial and much slower.
    \\
    \\<!-- end graff addendum -->
;

/// Splice the addendum in directly after the YAML frontmatter (or at the very
/// top when there is none), leaving the frontmatter itself untouched so
/// skill_docs.zig still parses `name:`/`description:` out of it.
pub fn withAddendum(arena: Allocator, original: []const u8) ![]u8 {
    const split = bodyStart(original);
    return std.fmt.allocPrint(arena, "{s}{s}\n\n{s}", .{ original[0..split], addendum, original[split..] });
}

/// Byte offset where the body begins: past a leading `---\n … \n---\n` block.
fn bodyStart(data: []const u8) usize {
    const fence_len: usize = if (std.mem.startsWith(u8, data, "---\r\n"))
        5
    else if (std.mem.startsWith(u8, data, "---\n"))
        4
    else
        return 0;
    const close = std.mem.indexOfPos(u8, data, fence_len, "\n---") orelse return 0;
    var i = close + "\n---".len;
    while (i < data.len and (data[i] == '\r' or data[i] == '-')) i += 1;
    if (i < data.len and data[i] == '\n') i += 1;
    return i;
}

const testing = std.testing;

test "#352: CODEX_HOME wins over HOME, and both produce the .system skill path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings(
        "/tmp/cx/skills/.system/imagegen",
        codexSkillDir(arena, "/tmp/cx", "/home/u").?,
    );
    try testing.expectEqualStrings(
        "/home/u/.codex/skills/.system/imagegen",
        codexSkillDir(arena, null, "/home/u").?,
    );
    // An empty CODEX_HOME is not a location; fall back to HOME.
    try testing.expectEqualStrings(
        "/home/u/.codex/skills/.system/imagegen",
        codexSkillDir(arena, "", "/home/u").?,
    );
    try testing.expect(codexSkillDir(arena, null, null) == null);
    try testing.expect(installDir(arena, null) == null);
    try testing.expectEqualStrings("/home/u/.harness/skills/imagegen", installDir(arena, "/home/u").?);
}

test "#352: the addendum goes after the frontmatter, before the body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = "---\nname: \"imagegen\"\ndescription: \"d\"\n---\n\n# Image Generation Skill\nbody text\n";
    const out = try withAddendum(arena, doc);
    try testing.expect(std.mem.startsWith(u8, out, "---\nname: \"imagegen\"")); // frontmatter untouched
    const marker = std.mem.indexOf(u8, out, "<!-- graff addendum -->").?;
    const fm_end = std.mem.indexOf(u8, out, "\n---\n").? + "\n---\n".len;
    const body = std.mem.indexOf(u8, out, "# Image Generation Skill").?;
    try testing.expect(marker >= fm_end and marker < body);
    try testing.expect(std.mem.indexOf(u8, out, "no built-in `image_gen` tool in graff") != null);
    try testing.expect(std.mem.indexOf(u8, out, "OPENAI_API_KEY` is required") != null);
    try testing.expect(std.mem.indexOf(u8, out, "one subagent per") != null);

    // No frontmatter: the addendum still leads.
    const bare = try withAddendum(arena, "# Just a body\n");
    try testing.expect(std.mem.startsWith(u8, bare, "<!-- graff addendum -->"));
    // CRLF frontmatter is still recognised as frontmatter.
    const crlf = try withAddendum(arena, "---\r\nname: x\r\n---\r\nbody\n");
    try testing.expect(std.mem.startsWith(u8, crlf, "---\r\nname: x"));
}

test "#352: sync mirrors the tree with LICENSE + scripts, and only re-copies when the source is newer" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = real_buf[0..try tmp.dir.realPath(io, &real_buf)];
    const src = try std.fmt.allocPrint(arena, "{s}/codex/skills/.system/imagegen", .{base});
    const dest = try std.fmt.allocPrint(arena, "{s}/home/.harness/skills/imagegen", .{base});

    // Nothing on disk yet: not present, nothing to sync.
    try testing.expect(!present(io, arena, src));
    try testing.expect(!needsSync(io, arena, src, dest));

    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(arena, "{s}/scripts", .{src}));
    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(arena, "{s}/references", .{src}));
    for ([_]struct { path: []const u8, data: []const u8 }{
        .{ .path = "SKILL.md", .data = "---\nname: imagegen\ndescription: d\n---\n\n# Body\noriginal\n" },
        .{ .path = "LICENSE.txt", .data = "LICENSE BODY" },
        .{ .path = "scripts/image_gen.py", .data = "print('gen')" },
        .{ .path = "references/cli.md", .data = "# cli" },
    }) |f| try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ src, f.path }),
        .data = f.data,
    });

    try testing.expect(present(io, arena, src));
    try testing.expect(needsSync(io, arena, src, dest));
    try sync(io, arena, src, dest);

    // Everything that matters made the trip, at the same relative paths.
    for ([_][]const u8{ "LICENSE.txt", "scripts/image_gen.py", "references/cli.md" }) |rel| {
        const copied = try Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/{s}", .{ dest, rel }), arena, .limited(4096));
        try testing.expect(copied.len > 0);
    }
    const md = try Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/SKILL.md", .{dest}), arena, .limited(1 << 16));
    try testing.expect(std.mem.indexOf(u8, md, "<!-- graff addendum -->") != null);
    try testing.expect(std.mem.indexOf(u8, md, "original") != null); // body preserved
    try testing.expect(std.mem.startsWith(u8, md, "---\nname: imagegen"));

    // Freshly synced: no re-copy, and a local edit survives.
    try testing.expect(!needsSync(io, arena, src, dest));
    const edited = try std.fmt.allocPrint(arena, "{s}/SKILL.md", .{dest});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = edited, .data = "---\nname: imagegen\ndescription: d\n---\nmine\n" });
    try testing.expect(!needsSync(io, arena, src, dest)); // the copy is now NEWER than the source

    // A newer upstream SKILL.md is the one thing that re-copies.
    const src_md = try std.fmt.allocPrint(arena, "{s}/SKILL.md", .{src});
    const dest_mtime = skillMtime(io, arena, dest).?;
    try Io.Dir.cwd().setTimestamps(io, src_md, .{
        .modify_timestamp = .{ .new = .{ .nanoseconds = @intCast(dest_mtime + std.time.ns_per_s) } },
    });
    try testing.expect(needsSync(io, arena, src, dest));
}
