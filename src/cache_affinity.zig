//! Prompt-cache affinity seed (ADR 0069).
//!
//! xAI routes `prompt_cache_key` / `x-grok-conv-id` per server. Hashing the
//! leaf cwd made every eval sandbox and worktree a unique partition, so the
//! expensive system+tools prefix never warmed. The seed is the git root when
//! one exists, otherwise the constant scratch token — never the leaf of a
//! throwaway tree (the in-house `cache-gitroot` fixture).

const std = @import("std");
const Io = std.Io;

pub const scratch_seed = "graff-scratch";

/// Salt mixed into the durable project id. Keep in one place so a rename
/// here moves `prompt_cache_key` / `x-grok-conv-id` together.
pub const cache_salt = "graff-kimi-project-cache-v1";

/// UUIDv5-shaped project cache id from an already-resolved seed. Same bytes
/// `projectRootId` sends as `prompt_cache_key` / `x-grok-conv-id`.
pub fn projectIdFromSeed(seed: []const u8, out: *[36]u8) []const u8 {
    var raw: [16]u8 = undefined;
    var digest: [32]u8 = undefined;
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(cache_salt);
    h.update(seed);
    h.final(&digest);
    @memcpy(&raw, digest[0..16]);
    raw[6] = (raw[6] & 0x0f) | 0x50; // version 5: name-derived
    raw[8] = (raw[8] & 0x3f) | 0x80; // variant 1
    const hex = std.fmt.bytesToHex(raw, .lower);
    @memcpy(out[0..8], hex[0..8]);
    out[8] = '-';
    @memcpy(out[9..13], hex[8..12]);
    out[13] = '-';
    @memcpy(out[14..18], hex[12..16]);
    out[18] = '-';
    @memcpy(out[19..23], hex[16..20]);
    out[23] = '-';
    @memcpy(out[24..36], hex[20..32]);
    return out[0..36];
}

/// Project cache id for an absolute cwd: git root when one exists, otherwise
/// the shared scratch seed. Never hashes the leaf of a throwaway tree.
pub fn projectIdForCwd(io: Io, cwd_abs: []const u8, out: *[36]u8) []const u8 {
    var seed_buf: [4096]u8 = undefined;
    return projectIdFromSeed(affinitySeed(io, cwd_abs, &seed_buf), out);
}

/// Directory that owns `.git` (file or dir), walking parents of `cwd_abs`.
/// `buf` holds the returned path. Null if the walk hits the filesystem root.
pub fn gitRootOf(io: Io, cwd_abs: []const u8, buf: []u8) ?[]const u8 {
    if (cwd_abs.len == 0 or cwd_abs.len >= buf.len) return null;
    @memcpy(buf[0..cwd_abs.len], cwd_abs);
    var cur: []const u8 = buf[0..cwd_abs.len];
    while (cur.len > 1 and (cur[cur.len - 1] == '/' or cur[cur.len - 1] == '\\'))
        cur = cur[0 .. cur.len - 1];

    var git_buf: [4096]u8 = undefined;
    while (true) {
        const git_path = std.fmt.bufPrint(&git_buf, "{s}/.git", .{cur}) catch return null;
        if (Io.Dir.cwd().access(io, git_path, .{})) |_| {
            if (cur.ptr != buf.ptr) {
                if (cur.len > buf.len) return null;
                @memcpy(buf[0..cur.len], cur);
                return buf[0..cur.len];
            }
            return cur;
        } else |_| {}
        const parent = std.fs.path.dirname(cur) orelse return null;
        if (parent.len == 0 or std.mem.eql(u8, parent, cur)) return null;
        cur = parent;
    }
}

/// Seed hashed into the durable project cache id. Repo trees share the git
/// root; a temp dir with no `.git` uses `scratch_seed`.
pub fn affinitySeed(io: Io, cwd_abs: []const u8, buf: []u8) []const u8 {
    const checkout = gitRootOf(io, cwd_abs, buf) orelse return scratch_seed;
    var primary_buf: [4096]u8 = undefined;
    const primary = linkedPrimary(io, checkout, &primary_buf) orelse return checkout;
    if (primary.len > buf.len) return checkout;
    @memcpy(buf[0..primary.len], primary);
    return buf[0..primary.len];
}

/// Resolve only a verified linked-worktree administrative directory. Ordinary
/// .git directories retain their historical key; submodules, bare repositories,
/// damaged pointers and unrelated repositories keep their checkout partition.
fn linkedPrimary(io: Io, checkout: []const u8, out: []u8) ?[]const u8 {
    var storage: [32768]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const a = fixed.allocator();
    const pointer = std.fs.path.join(a, &.{ checkout, ".git" }) catch return null;
    if ((Io.Dir.cwd().statFile(io, pointer, .{}) catch return null).kind != .file) return null;
    const text = Io.Dir.cwd().readFileAlloc(io, pointer, a, .limited(4096)) catch return null;
    const line = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, line, "gitdir:")) return null;
    const raw = std.mem.trim(u8, line[7..], " \t");
    if (raw.len == 0 or std.mem.indexOfAny(u8, raw, "\r\n\x00") != null) return null;
    const gitdir_path = std.fs.path.resolve(a, &.{ checkout, raw }) catch return null;
    const gitdir = Io.Dir.cwd().realPathFileAlloc(io, gitdir_path, a) catch return null;
    const marker = std.fs.path.join(a, &.{ gitdir, "commondir" }) catch return null;
    const data = Io.Dir.cwd().readFileAlloc(io, marker, a, .limited(4096)) catch return null;
    const common_raw = std.mem.trim(u8, data, " \t\r\n");
    if (common_raw.len == 0 or std.mem.indexOfAny(u8, common_raw, "\r\n\x00") != null) return null;
    const common_path = std.fs.path.resolve(a, &.{ gitdir, common_raw }) catch return null;
    const common = Io.Dir.cwd().realPathFileAlloc(io, common_path, a) catch return null;
    if (!std.mem.eql(u8, std.fs.path.basename(common), ".git")) return null;
    const worktrees = std.fs.path.join(a, &.{ common, "worktrees" }) catch return null;
    if (!std.mem.eql(u8, std.fs.path.dirname(gitdir) orelse return null, worktrees)) return null;
    // Git's backlink must identify this checkout, not another repository's
    // administrative entry. This also rejects partially moved/broken metadata.
    const backlink_path = std.fs.path.join(a, &.{ gitdir, "gitdir" }) catch return null;
    const backlink = Io.Dir.cwd().readFileAlloc(io, backlink_path, a, .limited(4096)) catch return null;
    const back = std.mem.trim(u8, backlink, " \t\r\n");
    const back_path = std.fs.path.resolve(a, &.{ gitdir, back }) catch return null;
    const back_real = Io.Dir.cwd().realPathFileAlloc(io, back_path, a) catch return null;
    const pointer_real = Io.Dir.cwd().realPathFileAlloc(io, pointer, a) catch return null;
    if (!std.mem.eql(u8, back_real, pointer_real)) return null;
    const primary = std.fs.path.dirname(common) orelse return null;
    if (primary.len > out.len) return null;
    @memcpy(out[0..primary.len], primary);
    return out[0..primary.len];
}

test "affinity: nested dirs under one repo share the git root" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.createDirPath(io, "a/b");

    var root_buf: [4096]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var child_buf: [4096]u8 = undefined;
    const child = try std.fmt.bufPrint(&child_buf, "{s}/a/b", .{root});

    var a_buf: [4096]u8 = undefined;
    var b_buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(root, gitRootOf(io, root, &a_buf).?);
    try std.testing.expectEqualStrings(root, gitRootOf(io, child, &b_buf).?);
    try std.testing.expectEqualStrings(
        affinitySeed(io, root, &a_buf),
        affinitySeed(io, child, &b_buf),
    );
}

test "affinity: a .git file counts as a repo root (worktree)" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".git", .data = "gitdir: /tmp/main.git\n" });
    var root_buf: [4096]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var seed_buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(root, gitRootOf(io, root, &seed_buf).?);
}

test "affinity: scratch trees without .git share one seed, not the leaf cwd" {
    if (@import("builtin").os.tag == .windows) return;
    const io = std.testing.io;
    // std.testing.tmpDir lives under the repo `.zig-cache`, so a parent walk
    // would find /workspace/.git. Use /tmp so the walk is a real scratch.
    const a_base = "/tmp/graff-aff-scratch-a";
    const b_base = "/tmp/graff-aff-scratch-b";
    Io.Dir.cwd().createDirPath(io, a_base ++ "/leaf") catch return error.SkipZigTest;
    defer Io.Dir.cwd().deleteTree(io, a_base) catch {};
    Io.Dir.cwd().createDirPath(io, b_base ++ "/other") catch return error.SkipZigTest;
    defer Io.Dir.cwd().deleteTree(io, b_base) catch {};

    var a_path: [160]u8 = undefined;
    var b_path: [160]u8 = undefined;
    const a = try std.fmt.bufPrint(&a_path, "{s}/leaf", .{a_base});
    const b = try std.fmt.bufPrint(&b_path, "{s}/other", .{b_base});

    var a_buf: [4096]u8 = undefined;
    var b_buf: [4096]u8 = undefined;
    try std.testing.expect(gitRootOf(io, a, &a_buf) == null);
    try std.testing.expect(gitRootOf(io, b, &b_buf) == null);
    try std.testing.expectEqualStrings(scratch_seed, affinitySeed(io, a, &a_buf));
    try std.testing.expectEqualStrings(scratch_seed, affinitySeed(io, b, &b_buf));
    try std.testing.expect(!std.mem.eql(u8, a, scratch_seed));
}

test "affinity: two scratch sandboxes share one project cache id" {
    // 289 list$: hashing the leaf cwd minted a unique prompt_cache_key per
    // eval sandbox, so the system+tools prefix never warmed. Offline — no
    // provider, no model. Would have failed on the cwd-hash.
    if (@import("builtin").os.tag == .windows) return;
    const io = std.testing.io;
    const a_base = "/tmp/graff-aff-id-a";
    const b_base = "/tmp/graff-aff-id-b";
    Io.Dir.cwd().createDirPath(io, a_base ++ "/leaf") catch return error.SkipZigTest;
    defer Io.Dir.cwd().deleteTree(io, a_base) catch {};
    Io.Dir.cwd().createDirPath(io, b_base ++ "/other") catch return error.SkipZigTest;
    defer Io.Dir.cwd().deleteTree(io, b_base) catch {};

    var a_path: [160]u8 = undefined;
    var b_path: [160]u8 = undefined;
    const a = try std.fmt.bufPrint(&a_path, "{s}/leaf", .{a_base});
    const b = try std.fmt.bufPrint(&b_path, "{s}/other", .{b_base});

    var id_a: [36]u8 = undefined;
    var id_b: [36]u8 = undefined;
    var id_seed: [36]u8 = undefined;
    try std.testing.expectEqualStrings(projectIdForCwd(io, a, &id_a), projectIdForCwd(io, b, &id_b));
    try std.testing.expectEqualStrings(projectIdFromSeed(scratch_seed, &id_seed), projectIdForCwd(io, a, &id_a));
}

test "affinity: hashing the leaf cwd is a forced miss" {
    // The 289 bug, spelled as ids: two sibling sandbox paths hash to
    // different UUIDs, and neither is the shared scratch id.
    const a = "/tmp/graff-evals/.sandboxes/task-a-r1";
    const b = "/tmp/graff-evals/.sandboxes/task-b-r1";
    var id_a: [36]u8 = undefined;
    var id_b: [36]u8 = undefined;
    var id_scratch: [36]u8 = undefined;
    try std.testing.expect(!std.mem.eql(u8, projectIdFromSeed(a, &id_a), projectIdFromSeed(b, &id_b)));
    try std.testing.expect(!std.mem.eql(u8, projectIdFromSeed(a, &id_a), projectIdFromSeed(scratch_seed, &id_scratch)));
}

test "affinity: nested repo dirs share one project cache id" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.createDirPath(io, "a/b");

    var root_buf: [4096]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var child_buf: [4096]u8 = undefined;
    const child = try std.fmt.bufPrint(&child_buf, "{s}/a/b", .{root});

    var id_root: [36]u8 = undefined;
    var id_child: [36]u8 = undefined;
    var id_leaf: [36]u8 = undefined;
    try std.testing.expectEqualStrings(projectIdForCwd(io, root, &id_root), projectIdForCwd(io, child, &id_child));
    // Old hash of the leaf path would have missed the root's warm prefix.
    try std.testing.expect(!std.mem.eql(u8, projectIdFromSeed(child, &id_leaf), projectIdForCwd(io, child, &id_child)));
}

test "affinity: real linked worktrees share primary checkout key without merging unrelated repos" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const primary = try std.fs.path.join(a, &.{ base, "primary" });
    defer a.free(primary);
    const sibling = try std.fs.path.join(a, &.{ base, "sibling" });
    defer a.free(sibling);
    const unrelated = try std.fs.path.join(a, &.{ base, "other" });
    defer a.free(unrelated);
    try affinityGit(&.{ "init", "-q", primary });
    try affinityGit(&.{ "-C", primary, "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "--allow-empty", "-m", "fixture" });
    try affinityGit(&.{ "-C", primary, "worktree", "add", "-q", "--detach", sibling });
    try affinityGit(&.{ "init", "-q", unrelated });
    var primary_key: [36]u8 = undefined;
    var sibling_key: [36]u8 = undefined;
    var old_primary: [36]u8 = undefined;
    var other_key: [36]u8 = undefined;
    try std.testing.expectEqualStrings(projectIdFromSeed(primary, &old_primary), projectIdForCwd(io, primary, &primary_key));
    try std.testing.expectEqualStrings(projectIdForCwd(io, primary, &primary_key), projectIdForCwd(io, sibling, &sibling_key));
    try std.testing.expect(!std.mem.eql(u8, projectIdForCwd(io, primary, &primary_key), projectIdForCwd(io, unrelated, &other_key)));
    // Finding the checkout remains a separate operation from finding affinity.
    var checkout_buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(sibling, gitRootOf(io, sibling, &checkout_buf).?);
    try expectStableRequests(&primary_key, &sibling_key);
    // Git also accepts relative .git pointers; canonicalization must agree.
    const relative_pointer = try std.fs.path.join(a, &.{ sibling, ".git" });
    defer a.free(relative_pointer);
    // Git for Windows marks a linked worktree's .git pointer read-only.
    if (@import("builtin").os.tag != .windows) {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = relative_pointer, .data = "gitdir: ../primary/.git/worktrees/sibling\n" });
        try std.testing.expectEqualStrings(projectIdForCwd(io, primary, &primary_key), projectIdForCwd(io, sibling, &sibling_key));
    }
    const nested = try std.fs.path.join(a, &.{ sibling, "nested" });
    defer a.free(nested);
    try affinityGit(&.{ "init", "-q", nested });
    try std.testing.expect(!std.mem.eql(u8, projectIdForCwd(io, primary, &primary_key), projectIdForCwd(io, nested, &other_key)));
}

fn affinityGit(args: []const []const u8) !void {
    const runner = @import("process_runner.zig");
    var argv: [24][]const u8 = undefined;
    argv[0] = "git";
    @memcpy(argv[1 .. args.len + 1], args);
    const result = try runner.runCapped(std.testing.allocator, std.testing.io, argv[0 .. args.len + 1], 4096, 4096, 15_000);
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(runner.ranOk(result));
}

test "affinity: malformed common directory and foreign backlinks preserve checkout isolation" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const primary = try std.fs.path.join(a, &.{ base, "primary" });
    const sibling = try std.fs.path.join(a, &.{ base, "sibling" });
    try tmp.dir.createDirPath(io, "primary/.git/worktrees/sibling");
    try tmp.dir.createDirPath(io, "sibling");
    try tmp.dir.writeFile(io, .{ .sub_path = "sibling/.git", .data = "gitdir: ../primary/.git/worktrees/sibling\n" });
    const backlink = try std.fmt.allocPrint(a, "{s}/.git\n", .{sibling});
    try tmp.dir.writeFile(io, .{ .sub_path = "primary/.git/worktrees/sibling/gitdir", .data = backlink });
    var key: [36]u8 = undefined;
    var expected: [36]u8 = undefined;
    for ([_][]const u8{ "", "../../missing", "../..\n../other", "../../../../other/.git" }) |bad| {
        try tmp.dir.writeFile(io, .{ .sub_path = "primary/.git/worktrees/sibling/commondir", .data = bad });
        try std.testing.expectEqualStrings(projectIdFromSeed(sibling, &expected), projectIdForCwd(io, sibling, &key));
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "primary/.git/worktrees/sibling/commondir", .data = "../..\n" });
    try std.testing.expectEqualStrings(projectIdFromSeed(primary, &expected), projectIdForCwd(io, sibling, &key));
    try tmp.dir.writeFile(io, .{ .sub_path = "primary/.git/worktrees/sibling/gitdir", .data = try std.fmt.allocPrint(a, "{s}/.git\n", .{primary}) });
    try std.testing.expectEqualStrings(projectIdFromSeed(sibling, &expected), projectIdForCwd(io, sibling, &key));
}

/// Actual request serialization must preserve both the key and stable prefix.
/// MiMo's automatic upstream cache may ignore this key; no hit-rate claim here.
fn expectStableRequests(primary: []const u8, sibling: []const u8) !void {
    const headers = @import("http_headers.zig");
    var saved: [36]u8 = undefined;
    @memcpy(&saved, headers.projectRootId(std.testing.io));
    defer headers.restoreProjectRootId(&saved);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const routes = [_]struct { provider: []const u8, model: []const u8 }{
        .{ .provider = "openai", .model = "gpt-6-astra" },
        .{ .provider = "codex", .model = "gpt-6-astra" },
        .{ .provider = "xai", .model = "grok-4.7" },
        .{ .provider = "codegraff", .model = "mimo-v2.6-flash" },
    };
    for (routes) |route| for ([_]bool{ false, true }) |child| {
        var agent = try @import("agent_request_body_responses.zig").testAgentFor(arena.allocator(), route.provider, .responses, route.model);
        agent.sub = child;
        agent.label = if (child) "implement" else "main";
        headers.restoreProjectRootId(primary);
        const first = try agent.buildBody("[]", false, true, true);
        defer std.testing.allocator.free(first);
        headers.restoreProjectRootId(sibling);
        const second = try agent.buildBody("[]", false, true, true);
        defer std.testing.allocator.free(second);
        try std.testing.expectEqualStrings(first, second);
    };
}
