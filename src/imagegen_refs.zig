//! #1775: workspace-confined reference image resolution and scratch staging for
//! `imagegen`.
//!
//! `codex exec` runs inside an empty private scratch cwd so `--sandbox
//! workspace-write` can never touch the caller's checkout. Two upstream Codex
//! behaviors broke relative reference image paths there:
//!   1. `view_image` resolves relative paths against that empty scratch cwd;
//!   2. `image_gen`'s `referenced_image_paths` deserializes `AbsolutePathBuf`
//!      without a base-path guard (`codex-rs/utils/absolute-path/src/lib.rs`),
//!      failing closed with `"AbsolutePathBuf deserialized without a base path"`
//!      on any relative path.
//!
//! This module resolves caller-supplied reference images (explicit `images`
//! entries and existing workspace-relative image paths named in `prompt`)
//! against the active session workspace (`agent_cwd` or POSIX cwd after
//! `workspace use`), enforces `confinedPath` + `noSymlinkEscape`, verifies
//! image magic bytes, stages read-only copies under `<scratch>/refs/` outside
//! both `child_cwd` and `save_root`, and rewrites prompt spans to canonical
//! absolute paths.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const tools = @import("tools.zig");
const ToolOutput = tools.ToolOutput;
const outsideCwd = tools.outsideCwd;
const policy = @import("harness_policy.zig");
const confinedPath = policy.confinedPath;
const noSymlinkEscape = policy.noSymlinkEscape;
const codedbpro_paths = @import("codedbpro_paths.zig");
const verify = @import("imagegen_verify.zig");

/// Matches Codex's `MAX_EDIT_IMAGES` (`ext/image-generation/src/tool.rs`).
pub const max_images: usize = 5;
/// Matches Codex's `MAX_EDIT_IMAGE_BYTES` (50 MiB).
pub const max_image_bytes: u64 = 50 * 1024 * 1024;

pub const Span = struct {
    start: usize,
    end: usize,
    ref_idx: usize,
};

pub const Resolved = struct {
    paths: []const []const u8,
    spans: []const Span,
    missing_prompt_ref: ?[]const u8 = null,

    /// Replace any workspace-relative image path spans in `prompt` with the
    /// engine-specific absolute paths (`paths` for `openai_api`, staged scratch
    /// paths for `codex`).
    pub fn rewritePrompt(self: Resolved, arena: Allocator, prompt: []const u8, target_paths: []const []const u8) ![]const u8 {
        if (self.spans.len == 0) return prompt;
        var out: std.ArrayList(u8) = .empty;
        var cursor: usize = 0;
        for (self.spans) |sp| {
            if (sp.start < cursor or sp.end > prompt.len or sp.ref_idx >= target_paths.len) continue;
            try out.appendSlice(arena, prompt[cursor..sp.start]);
            try out.appendSlice(arena, target_paths[sp.ref_idx]);
            cursor = sp.end;
        }
        try out.appendSlice(arena, prompt[cursor..]);
        return out.items;
    }
};

pub const Outcome = union(enum) {
    ok: Resolved,
    fail: ToolOutput,
};

/// Active workspace root for this tool call: a subagent's isolated `agent_cwd`
/// when set, else the live POSIX cwd (`/workspace use` moves this, whereas
/// Threaded Io's `Dir.cwd()` can stay stale — #721 / #747).
pub fn activeBase(arena: Allocator, io: Io, agent_cwd: ?[]const u8) ![]const u8 {
    return codedbpro_paths.sessionAbs(arena, io, agent_cwd, ".");
}

/// Resolve an already-confined workspace-relative path to an absolute path,
/// canonicalizing when it already exists on disk.
pub fn resolveAbs(arena: Allocator, io: Io, base_cwd: []const u8, rel: []const u8) ![]const u8 {
    const joined = try codedbpro_paths.sessionAbs(arena, io, base_cwd, rel);
    return canonicalOrSelf(arena, io, joined);
}

fn canonicalOrSelf(arena: Allocator, io: Io, path: []const u8) []const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = Io.Dir.cwd().realPathFile(io, path, &buf) catch return path;
    return arena.dupe(u8, buf[0..n]) catch path;
}

fn beneathDir(path: []const u8, root: []const u8) ?[]const u8 {
    const clean_root = std.mem.trimEnd(u8, root, "/\\");
    if (clean_root.len == 0 or !std.mem.startsWith(u8, path, clean_root)) return null;
    if (path.len == clean_root.len) return null;
    if (!std.fs.path.isSep(path[clean_root.len])) return null;
    const rel = std.mem.trimStart(u8, path[clean_root.len..], "/\\");
    return if (rel.len > 0) rel else null;
}

/// Convert an in-workspace path to a confined path checked against `base_cwd`.
/// Absolute paths are allowed ONLY when they sit under `base_cwd` (or its
/// canonical target, e.g. `/tmp` vs `/private/tmp`) or an explicit `--add-dir`
/// root (`workspace_roots`), and still pass `confinedPath` + `noSymlinkEscape`.
fn confineInputPath(arena: Allocator, io: Io, base_cwd: []const u8, raw: []const u8) ?[]const u8 {
    if (raw.len == 0) return null;
    if (std.fs.path.isAbsolute(raw)) {
        if (confinedPath(raw) and noSymlinkEscape(io, raw, base_cwd)) return raw;
        const canon_base = canonicalOrSelf(arena, io, base_cwd);
        const rel = beneathDir(raw, base_cwd) orelse beneathDir(raw, canon_base) orelse return null;
        if (confinedPath(rel) and noSymlinkEscape(io, rel, base_cwd)) return rel;
        return null;
    }
    if (confinedPath(raw) and noSymlinkEscape(io, raw, base_cwd)) return raw;
    return null;
}

fn errFmt(gpa: Allocator, comptime fmt: []const u8, args: anytype) !Outcome {
    return .{ .fail = .{ .text = try std.fmt.allocPrint(gpa, fmt, args), .is_error = true } };
}

fn explicitImagesValue(input: Value) ?struct { name: []const u8, val: Value } {
    if (input != .object) return null;
    inline for (.{ "images", "references", "referenced_image_paths" }) |key| {
        if (input.object.get(key)) |v| {
            if (v != .null) return .{ .name = key, .val = v };
        }
    }
    return null;
}

fn checkImageFile(io: Io, path: []const u8) enum { ok, missing, not_file, empty, too_large, bad_magic } {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => .missing,
        else => .not_file,
    };
    if (st.kind != .file) return .not_file;
    if (st.size == 0) return .empty;
    if (st.size > max_image_bytes) return .too_large;
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return .not_file;
    defer file.close(io);
    var head: [16]u8 = undefined;
    const n = file.readPositionalAll(io, &head, 0) catch return .not_file;
    if (verify.Format.detect(head[0..n]) == null) return .bad_magic;
    return .ok;
}

fn appendUnique(arena: Allocator, list: *std.ArrayList([]const u8), canon: []const u8) !?usize {
    for (list.items, 0..) |existing, idx| {
        if (std.mem.eql(u8, existing, canon)) return idx;
    }
    if (list.items.len >= max_images) return null;
    const idx = list.items.len;
    try list.append(arena, canon);
    return idx;
}

pub fn resolve(gpa: Allocator, arena: Allocator, io: Io, base_cwd: []const u8, input: Value, prompt: []const u8) !Outcome {
    var paths: std.ArrayList([]const u8) = .empty;
    var spans: std.ArrayList(Span) = .empty;

    if (explicitImagesValue(input)) |field| {
        if (field.val != .array) {
            return errFmt(gpa, "{s} must be an array of workspace-relative image paths (PNG, JPEG or WebP). Nothing was generated.", .{field.name});
        }
        if (field.val.array.items.len > max_images) {
            return errFmt(gpa, "imagegen accepts at most {d} reference images (got {d}). Nothing was generated.", .{ max_images, field.val.array.items.len });
        }
        for (field.val.array.items) |item| {
            if (item != .string) {
                return errFmt(gpa, "every entry in {s} must be a non-empty string path. Nothing was generated.", .{field.name});
            }
            const raw = std.mem.trim(u8, item.string, " \t\r\n");
            if (raw.len == 0) {
                return errFmt(gpa, "{s} contains an empty path — pass workspace-relative PNG, JPEG or WebP paths. Nothing was generated.", .{field.name});
            }
            const confined = confineInputPath(arena, io, base_cwd, raw) orelse
                return .{ .fail = try outsideCwd(gpa, raw) };
            const abs = try resolveAbs(arena, io, base_cwd, confined);
            switch (checkImageFile(io, abs)) {
                .ok => {},
                .missing => return errFmt(gpa, "reference image '{s}' does not exist in the active workspace ({s}). Check the path or active worktree before calling imagegen. Nothing was generated.", .{ raw, base_cwd }),
                .not_file => return errFmt(gpa, "reference image '{s}' is not a readable regular file. Pass a PNG, JPEG or WebP file inside the workspace. Nothing was generated.", .{raw}),
                .empty => return errFmt(gpa, "reference image '{s}' is empty (0 bytes). Nothing was generated.", .{raw}),
                .too_large => return errFmt(gpa, "reference image '{s}' exceeds the 50 MiB limit. Resize or compress it first. Nothing was generated.", .{raw}),
                .bad_magic => return errFmt(gpa, "reference image '{s}' is not a valid PNG, JPEG or WebP image (unrecognized file signature). Nothing was generated.", .{raw}),
            }
            _ = try appendUnique(arena, &paths, abs);
        }
    }

    const missing_hint = try scanPromptRefs(arena, io, base_cwd, prompt, &paths, &spans);
    return .{ .ok = .{
        .paths = paths.items,
        .spans = spans.items,
        .missing_prompt_ref = missing_hint,
    } };
}

fn isDelim(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n', '"', '\'', '`', '(', ')', '[', ']', '{', '}', '<', '>', ',', ';' => true,
        else => false,
    };
}

fn hasImageExt(path: []const u8) bool {
    inline for (.{ ".png", ".jpg", ".jpeg", ".webp" }) |ext| {
        if (path.len > ext.len and std.ascii.endsWithIgnoreCase(path, ext)) return true;
    }
    return false;
}

/// Scan `prompt` for workspace-relative image tokens (`assets/ref.png`,
/// `./style.webp`, etc.). Existing valid workspace images are attached and
/// their spans recorded for rewriting; nonexistent slash-qualified relative
/// image tokens are remembered only as a diagnostic hint if generation fails.
fn scanPromptRefs(
    arena: Allocator,
    io: Io,
    base_cwd: []const u8,
    prompt: []const u8,
    paths: *std.ArrayList([]const u8),
    spans: *std.ArrayList(Span),
) !?[]const u8 {
    var missing_hint: ?[]const u8 = null;
    var i: usize = 0;
    while (i < prompt.len) {
        while (i < prompt.len and isDelim(prompt[i])) : (i += 1) {}
        if (i >= prompt.len) break;
        const tok_start = i;
        while (i < prompt.len and !isDelim(prompt[i])) : (i += 1) {}
        var tok_end = i;
        while (tok_end > tok_start and switch (prompt[tok_end - 1]) {
            '.', ':', '!', '?' => true,
            else => false,
        }) : (tok_end -= 1) {}
        if (tok_end <= tok_start) continue;

        const candidate = prompt[tok_start..tok_end];
        if (!hasImageExt(candidate)) continue;
        if (std.mem.indexOf(u8, candidate, "://") != null) continue;
        if (std.ascii.startsWithIgnoreCase(candidate, "data:")) continue;

        // Also allow an in-workspace absolute path in prompt to be staged safely,
        // while rejecting anything outside `base_cwd`.
        const confined = confineInputPath(arena, io, base_cwd, candidate) orelse continue;
        const abs = try resolveAbs(arena, io, base_cwd, confined);
        if (checkImageFile(io, abs) == .ok) {
            if (try appendUnique(arena, paths, abs)) |ref_idx| {
                try spans.append(arena, .{ .start = tok_start, .end = tok_end, .ref_idx = ref_idx });
            }
        } else if (missing_hint == null and !std.fs.path.isAbsolute(candidate) and std.mem.indexOfAny(u8, candidate, "/\\") != null) {
            missing_hint = candidate;
        }
    }
    return missing_hint;
}

/// Stage verified reference images into `<scratch>/refs/<n>-<safe_name>` and
/// return their canonical absolute paths. Staging outside `<scratch>/cwd` and
/// `<scratch>/home/generated_images` keeps the caller's repo untouched, avoids
/// `clap`'s comma delimiter splitting filenames, and prevents `newestFresh`
/// from mistaking a reference image for a generated output.
pub fn stageForCodex(io: Io, arena: Allocator, scratch: []const u8, refs: []const []const u8) ![]const []const u8 {
    if (refs.len == 0) return &.{};
    const refs_dir = try std.fmt.allocPrint(arena, "{s}/refs", .{scratch});
    try Io.Dir.cwd().createDirPath(io, refs_dir);

    var staged: std.ArrayList([]const u8) = .empty;
    try staged.ensureTotalCapacity(arena, refs.len);
    for (refs, 0..) |src, idx| {
        const base = std.fs.path.basename(src);
        var clean = try arena.alloc(u8, base.len);
        for (base, 0..) |c, ci| {
            clean[ci] = switch (c) {
                'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => c,
                else => '_',
            };
        }
        const dst = try std.fmt.allocPrint(arena, "{s}/{d}-{s}", .{ refs_dir, idx + 1, if (clean.len > 0) clean else "ref.png" });
        try Io.Dir.cwd().copyFile(src, Io.Dir.cwd(), dst, io, .{});
        try staged.append(arena, canonicalOrSelf(arena, io, dst));
    }
    return staged.items;
}

const testing = std.testing;

test "#1775: resolve confines references to active workspace, verifies magic bytes, and rewrites prompt spans" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = real_buf[0..try tmp.dir.realPath(io, &real_buf)];

    const work = try std.fmt.allocPrint(arena, "{s}/work", .{base});
    const outside = try std.fmt.allocPrint(arena, "{s}/outside", .{base});
    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(arena, "{s}/assets", .{work}));
    try Io.Dir.cwd().createDirPath(io, outside);

    const png_bytes = "\x89PNG\r\n\x1a\n" ++ @as([128]u8, @splat('p'));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/assets/style.png", .{work}), .data = png_bytes });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/assets/not_image.png", .{work}), .data = "plain text" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/secret.png", .{outside}), .data = png_bytes });

    // 1. Prompt-only relative reference auto-resolves and rewrites to staged abs path.
    var empty_obj = try std.json.parseFromSlice(Value, gpa, "{}", .{});
    defer empty_obj.deinit();
    const prompt = "Match the palette in assets/style.png, keeping crisp edges.";
    const got = switch (try resolve(gpa, arena, io, work, empty_obj.value, prompt)) {
        .ok => |r| r,
        .fail => |f| {
            gpa.free(f.text);
            return error.TestUnexpectedError;
        },
    };
    try testing.expectEqual(@as(usize, 1), got.paths.len);
    try testing.expect(std.fs.path.isAbsolute(got.paths[0]));

    const scratch = try std.fmt.allocPrint(arena, "{s}/scratch", .{base});
    const staged = try stageForCodex(io, arena, scratch, got.paths);
    try testing.expectEqual(@as(usize, 1), staged.len);
    try testing.expect(std.fs.path.isAbsolute(staged[0]));
    const rewritten = try got.rewritePrompt(arena, prompt, staged);
    try testing.expect(std.mem.indexOf(u8, rewritten, "assets/style.png") == null);
    try testing.expect(std.mem.indexOf(u8, rewritten, staged[0]) != null);

    // 2. Traversal in explicit `images` is rejected as outsideCwd.
    var escape_in = try std.json.parseFromSlice(Value, gpa, "{\"images\":[\"../outside/secret.png\"]}", .{});
    defer escape_in.deinit();
    switch (try resolve(gpa, arena, io, work, escape_in.value, "draw")) {
        .ok => return error.TestExpectedError,
        .fail => |f| {
            defer gpa.free(f.text);
            try testing.expect(f.is_error);
            try testing.expect(std.mem.indexOf(u8, f.text, "outside the working directory") != null);
        },
    }

    // 3. Symlink escape inside workspace is rejected.
    const esc_link = try std.fmt.allocPrint(arena, "{s}/assets/link.png", .{work});
    const esc_target = try std.fmt.allocPrint(arena, "{s}/secret.png", .{outside});
    if (Io.Dir.cwd().symLink(io, esc_target, esc_link, .{})) |_| {
        var link_in = try std.json.parseFromSlice(Value, gpa, "{\"images\":[\"assets/link.png\"]}", .{});
        defer link_in.deinit();
        switch (try resolve(gpa, arena, io, work, link_in.value, "draw")) {
            .ok => return error.TestExpectedError,
            .fail => |f| {
                defer gpa.free(f.text);
                try testing.expect(f.is_error);
                try testing.expect(std.mem.indexOf(u8, f.text, "outside the working directory") != null);
            },
        }
    } else |_| {}

    // 4. Non-image file disguised with .png extension fails magic check.
    var bad_magic = try std.json.parseFromSlice(Value, gpa, "{\"images\":[\"assets/not_image.png\"]}", .{});
    defer bad_magic.deinit();
    switch (try resolve(gpa, arena, io, work, bad_magic.value, "draw")) {
        .ok => return error.TestExpectedError,
        .fail => |f| {
            defer gpa.free(f.text);
            try testing.expect(f.is_error);
            try testing.expect(std.mem.indexOf(u8, f.text, "unrecognized file signature") != null);
        },
    }

    // 5. Missing explicit reference gives a specific missing-file error, not #352.
    var missing_in = try std.json.parseFromSlice(Value, gpa, "{\"images\":[\"assets/nope.png\"]}", .{});
    defer missing_in.deinit();
    switch (try resolve(gpa, arena, io, work, missing_in.value, "draw")) {
        .ok => return error.TestExpectedError,
        .fail => |f| {
            defer gpa.free(f.text);
            try testing.expect(f.is_error);
            try testing.expect(std.mem.indexOf(u8, f.text, "does not exist in the active workspace") != null);
            try testing.expect(std.mem.indexOf(u8, f.text, "#352") == null);
        },
    }
}
