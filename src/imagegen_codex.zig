//! #352: the preferred imagegen engine — the hosted `image_gen` tool, driven
//! headlessly through `codex exec`.
//!
//! This is the engine the #352 investigation concluded did NOT work, and the
//! conclusion was version-bound rather than wrong. codex 0.141.0 could not run
//! the only local model carrying the image_generation + namespace_tools
//! capabilities, so `image_gen` never entered its Responses tools array and the
//! model — asked for an image it had no way to make — invented one from a
//! two-week-old file. codex 0.146.0 with gpt-5.6-sol does fire the tool
//! headlessly and drops a real PNG under $CODEX_HOME/generated_images. Whether
//! this engine works is therefore a property of the installed CLI version AND
//! the configured model, which is precisely why nothing here trusts it.
//!
//! What graff refuses to trust, concretely:
//!   * the transcript — codex's own words about what it produced are exactly
//!     what fabricated #352, so they are diagnostics and nothing more;
//!   * the exit code — 0 with a chatty success narrative is the fabrication
//!     signature, so a clean exit with no fresh artifact is a hard error;
//!   * the model's file handling — the controlled prompt tells it not to copy,
//!     move or convert anything. graff scans save_root itself, picks the newest
//!     file whose mtime is at or after the spawn, verifies its magic bytes, and
//!     does the copy and any resize with its own hands.
//!
//! The child also runs in a private empty scratch directory rather than the
//! user's checkout: `--sandbox workspace-write` makes the cwd writable, and
//! there is no reason for an image generation to be able to write into the
//! repo it was called from.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const run_mod = @import("imagegen_run.zig");

/// A hosted image generation is a slow round trip plus codex's own startup;
/// 6 minutes is generous and still bounded.
pub const deadline_ms: u64 = 360 * 1000;

/// Where codex saves what `image_gen` returns, relative to CODEX_HOME.
pub const save_root_rel = "generated_images";

const max_scan_depth: u8 = 4; // real layout is <save_root>/<session>/<call>.png

/// codex exec, non-interactive, with the feature flag forced on so the tool is
/// offered even when the user's config.toml never enabled it, and pointed at a
/// PRIVATE CODEX_HOME for this one run (see `prepareHome`). The model comes
/// from the user's own codex config — graff does not pick one, because which
/// models carry the image capabilities is codex's business, not ours.
///
/// `env` rather than a shell: CODEX_HOME has to reach the child, and `sh -c`
/// would put a model-supplied prompt through a quoting layer for no reason.
///
/// `--skip-git-repo-check` is required BECAUSE of the isolation above, not in
/// spite of it. codex refuses to run in a directory it does not consider
/// trusted ("Not inside a trusted directory and --skip-git-repo-check was not
/// specified", exit 1), and the cwd we hand it is deliberately an empty
/// non-git scratch directory graff just created. That check exists to stop
/// codex writing into a user's real project by accident; here there is no user
/// project to protect — the whole point of the private cwd is that the child
/// has nothing of theirs within reach, and `--sandbox workspace-write` confines
/// its writes to that empty directory. Skipping the check is what lets the
/// stronger isolation stand; without it the engine simply never runs.
pub fn buildArgv(arena: Allocator, private_home: []const u8, prompt: []const u8) ![]const []const u8 {
    return arena.dupe([]const u8, &.{
        "env",
        try std.fmt.allocPrint(arena, "CODEX_HOME={s}", .{private_home}),
        "codex",
        "exec",
        "--sandbox",
        "workspace-write",
        "--skip-git-repo-check",
        "-c",
        "features.image_generation=true",
        prompt,
    });
}

/// Credentials that make a private CODEX_HOME usable. Symlinked rather than
/// copied so a token never lands as a second plaintext file in a temp dir.
pub const linked_files = [_][]const u8{ "auth.json", "config.toml" };

/// Build a private CODEX_HOME for ONE run.
///
/// Why this exists: `generated_images` is shared state. Scanning the user's
/// real save_root for "the newest fresh file" is safe with one caller and
/// unsafe with the N-parallel-subagents pattern this tool documents — a run
/// that fabricated (wrote nothing, exited 0) would happily adopt a SIBLING's
/// artifact, pass every freshness and magic check, and hand back an image it
/// did not generate. That is #352 again, and the checks cannot catch it,
/// because the file really is fresh and really is an image; it just belongs
/// to someone else. Two callers could equally be handed the same bytes, and a
/// human using the Codex app during the run could have their image captured
/// into a tool result.
///
/// So each invocation gets its own CODEX_HOME holding only the credential
/// files, and therefore its own empty `generated_images`. Our scan cannot see
/// anyone else's artifacts, and nobody else can see ours.
///
/// Accepted caveat: if codex refreshes its token during the run and writes it
/// by atomic replace, the replacement lands on the private copy and is
/// discarded with it. The next real run refreshes again — a refresh is
/// idempotent, and losing one is far cheaper than cross-attributing an image.
pub fn prepareHome(io: Io, arena: Allocator, private_home: []const u8, real_home: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, private_home);
    for (linked_files) |name| {
        const target = try std.fmt.allocPrint(arena, "{s}/{s}", .{ real_home, name });
        _ = Io.Dir.cwd().statFile(io, target, .{}) catch continue; // config.toml is optional
        const link = try std.fmt.allocPrint(arena, "{s}/{s}", .{ private_home, name });
        Io.Dir.cwd().symLink(io, target, link, .{}) catch {};
    }
}

/// Remove the credential symlinks BEFORE the tree is deleted, so a delete can
/// never walk into the user's real CODEX_HOME through one of them.
pub fn unlinkHome(io: Io, arena: Allocator, private_home: []const u8) void {
    for (linked_files) |name| {
        const link = std.fmt.allocPrint(arena, "{s}/{s}", .{ private_home, name }) catch continue;
        Io.Dir.cwd().deleteFile(io, link) catch {};
    }
}

/// This run's private save_root.
pub fn saveRoot(arena: Allocator, private_home: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ private_home, save_root_rel });
}

/// The instruction codex actually receives. It pins the tool, forbids the file
/// handling graff is about to do itself, and asks for a short reply so a long
/// narrative cannot crowd out the stderr tail we keep for diagnostics.
pub fn buildPrompt(arena: Allocator, user_prompt: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\Call the built-in image_gen tool exactly once to generate this image:
        \\
        \\{s}
        \\
        \\Rules: use the image_gen tool and nothing else. Do NOT copy, move, rename or
        \\convert any file, do NOT resize the image, and do NOT run shell commands to
        \\save or inspect it - the program that called you collects the generated file
        \\itself. If the image_gen tool is not available to you, say exactly
        \\IMAGE_GEN_UNAVAILABLE and stop. Otherwise reply with one short line once the
        \\tool call has returned.
    , .{user_prompt});
}

pub const Artifact = struct {
    path: []const u8,
    size: u64,
    mtime_ns: i128,
};

/// The newest regular file under `root` whose mtime is at or after `since_ns`.
///
/// This is the anti-fabrication check for this engine: codex writes each
/// generation to a fresh path under save_root, so a run that produced nothing
/// leaves nothing new behind no matter how confidently it says otherwise.
/// `since_ns` should be floored to the second by the caller — some filesystems
/// truncate mtime, and a genuine artifact must not read as stale because of it.
///
/// Dotfiles are skipped: the real save_root on this machine contains a
/// .DS_Store, and Finder rewriting it must never be mistaken for an image.
pub fn newestFresh(io: Io, arena: Allocator, root: []const u8, since_ns: i128) ?Artifact {
    var best: ?Artifact = null;
    scan(io, arena, root, since_ns, 0, &best);
    return best;
}

fn scan(io: Io, arena: Allocator, dir_path: []const u8, since_ns: i128, depth: u8, best: *?Artifact) void {
    if (depth > max_scan_depth) return;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        switch (entry.kind) {
            .directory => scan(io, arena, path, since_ns, depth + 1, best),
            // Some filesystems (and some network mounts) report `.unknown` from
            // readdir rather than a type; stat decides instead of skipping.
            .file, .unknown => {
                const st = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
                if (st.kind == .directory) {
                    scan(io, arena, path, since_ns, depth + 1, best);
                    continue;
                }
                if (st.kind != .file) continue;
                if (st.mtime.nanoseconds < since_ns) continue; // predates this run
                if (best.*) |cur| {
                    if (st.mtime.nanoseconds <= cur.mtime_ns) continue;
                }
                best.* = .{ .path = path, .size = st.size, .mtime_ns = st.mtime.nanoseconds };
            },
            else => {},
        }
    }
}

/// Floor to the whole second, so a coarse-granularity filesystem truncating a
/// genuine artifact's mtime cannot make it read as older than the spawn.
pub fn freshnessFloor(started_ns: i128) i128 {
    const s = std.time.ns_per_s;
    return started_ns - @mod(started_ns, s);
}

/// codex answers a model it cannot serve with a 400 naming the CLI version.
/// That is a fixable local problem, so it gets a fixable local answer instead
/// of a raw transcript dump.
pub fn tooOld(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "requires a newer version of Codex") != null or
        std.mem.indexOf(u8, text, "requires a newer version of codex") != null;
}

pub const too_old_text = "the installed codex CLI is too old for the model your codex config selects, so the hosted image_gen tool was never offered. Upgrade it (bun install -g @openai/codex) and call imagegen again, or pass engine \"openai_api\" to use the OPENAI_API_KEY path instead. Nothing was generated.";

/// The model told us outright that it had no image_gen tool. Worth its own
/// message: it is the honest version of what #352 fabricated.
pub fn saidUnavailable(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "IMAGE_GEN_UNAVAILABLE") != null;
}

pub const unavailable_text = "codex ran, but reported that the hosted image_gen tool was not available to it — the model your codex config selects does not carry the image-generation capability. Check `codex features list` shows image_generation stable/true and that your configured model supports it, or pass engine \"openai_api\" to use the OPENAI_API_KEY path. Nothing was generated.";

/// No fresh artifact after a clean exit. This is #352's exact signature, so
/// the message says so rather than leaving it as a puzzling empty result.
pub const no_artifact_text = "codex exited successfully but left NO new file under its generated_images directory, so no image was generated no matter what its transcript says. This is the #352 failure mode: the hosted image_gen tool is only offered when the CLI version and the configured model both support it, and a model without it will happily narrate a success it did not perform. Nothing was generated — do not report an image.";

const testing = std.testing;

test "#352: argv forces the feature flag on and runs codex non-interactively" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try buildArgv(arena, "/tmp/priv", "PROMPT");
    const want = [_][]const u8{
        "env",                            "CODEX_HOME=/tmp/priv", "codex",                 "exec",
        "--sandbox",                      "workspace-write",
        // Without this codex exits 1 in our own empty scratch cwd: "Not inside
        // a trusted directory and --skip-git-repo-check was not specified".
             "--skip-git-repo-check", "-c",
        "features.image_generation=true", "PROMPT",
    };
    try testing.expectEqual(want.len, argv.len);
    for (want, argv) |w, got| try testing.expectEqualStrings(w, got);

    // Named explicitly too, so a reordering refactor cannot quietly drop it.
    var has_skip = false;
    for (argv) |a| {
        if (std.mem.eql(u8, a, "--skip-git-repo-check")) has_skip = true;
    }
    try testing.expect(has_skip);
    // ...and the escape hatch that would ACTUALLY be unsafe is never assembled:
    // the sandbox is what keeps the child confined to the scratch directory.
    for (argv) |a| try testing.expect(!std.mem.eql(u8, a, "--dangerously-bypass-approvals-and-sandbox"));
    // No model is pinned: which models carry the capability is codex's call.
    for (argv) |a| try testing.expect(!std.mem.eql(u8, a, "--model") and !std.mem.eql(u8, a, "-m"));
    // The prompt is a single argv slot; no shell is involved, so no quoting
    // layer can reinterpret it.
    try testing.expectEqualStrings("env", argv[0]);
    try testing.expectEqualStrings("PROMPT", argv[argv.len - 1]);
}

test "#352: a private CODEX_HOME links only credentials, so its save_root starts empty and isolated" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = real_buf[0..try tmp.dir.realPath(io, &real_buf)];

    // A "real" CODEX_HOME with credentials AND somebody else's artifacts.
    const real_home = try std.fmt.allocPrint(arena, "{s}/codex", .{base});
    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(arena, "{s}/generated_images/other", .{real_home}));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/auth.json", .{real_home}), .data = "{\"tok\":1}" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/generated_images/other/exec-theirs.png", .{real_home}), .data = "\x89PNG\r\n\x1a\n" ++ "theirs" });

    const private_home = try std.fmt.allocPrint(arena, "{s}/run-a/home", .{base});
    try prepareHome(io, arena, private_home, real_home);

    // Credentials reachable through the link...
    const auth = try Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/auth.json", .{private_home}), arena, .limited(64));
    try testing.expectEqualStrings("{\"tok\":1}", auth);
    // ...and no config.toml link, because the source had none.
    try testing.expect(Io.Dir.cwd().statFile(io, try std.fmt.allocPrint(arena, "{s}/config.toml", .{private_home}), .{}) == error.FileNotFound);

    // The private save_root is empty: a sibling's fresh artifact is invisible.
    const mine = try saveRoot(arena, private_home);
    try testing.expect(newestFresh(io, arena, mine, 0) == null);
    // ...while the real one obviously still has it — proving the isolation is
    // what hides it, not an empty fixture.
    try testing.expect(newestFresh(io, arena, try std.fmt.allocPrint(arena, "{s}/generated_images", .{real_home}), 0) != null);

    // Cleanup unlinks credentials first, so deleting the tree cannot reach
    // through a symlink into the user's real CODEX_HOME.
    unlinkHome(io, arena, private_home);
    try Io.Dir.cwd().deleteTree(io, try std.fmt.allocPrint(arena, "{s}/run-a", .{base}));
    const survived = try Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/auth.json", .{real_home}), arena, .limited(64));
    try testing.expectEqualStrings("{\"tok\":1}", survived);
}

test "#352: two concurrent runs cannot see each other's artifacts" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = real_buf[0..try tmp.dir.realPath(io, &real_buf)];

    const a_root = try std.fmt.allocPrint(arena, "{s}/a/generated_images/s1", .{base});
    const b_root = try std.fmt.allocPrint(arena, "{s}/b/generated_images/s1", .{base});
    try Io.Dir.cwd().createDirPath(io, a_root);
    try Io.Dir.cwd().createDirPath(io, b_root);
    // Only run A produced something. Run B fabricated: exit 0, no file.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/exec-a.png", .{a_root}), .data = "\x89PNG\r\n\x1a\n" ++ "aaaa" });

    const a_save = try std.fmt.allocPrint(arena, "{s}/a/generated_images", .{base});
    const b_save = try std.fmt.allocPrint(arena, "{s}/b/generated_images", .{base});
    try testing.expect(newestFresh(io, arena, a_save, 0) != null);
    // The whole point: B finds nothing even though a fresh, valid, sibling
    // image exists on the same machine at the same moment.
    try testing.expect(newestFresh(io, arena, b_save, 0) == null);
}

test "#352: the controlled prompt carries the user's text and forbids the file handling graff does itself" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = try buildPrompt(arena, "a red circle on white");
    try testing.expect(std.mem.indexOf(u8, p, "a red circle on white") != null);
    try testing.expect(std.mem.indexOf(u8, p, "image_gen tool exactly once") != null);
    for ([_][]const u8{ "Do NOT copy, move, rename or", "do NOT resize", "IMAGE_GEN_UNAVAILABLE" }) |needle|
        try testing.expect(std.mem.indexOf(u8, p, needle) != null);
}

test "#352: discovery picks the newest FRESH file, ignores stale ones and dotfiles, and finds nothing when nothing was written" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = real_buf[0..try tmp.dir.realPath(io, &real_buf)];

    const day_ns: i128 = 24 * 60 * 60 * std.time.ns_per_s;
    const now = Io.Timestamp.now(io, .real).nanoseconds;
    const marker = now - 60 * std.time.ns_per_s; // "this run started a minute ago"

    // Mirror the real layout: <root>/<session>/<call>.png, plus a .DS_Store.
    const session = try std.fmt.allocPrint(arena, "{s}/019f-session", .{root});
    try Io.Dir.cwd().createDirPath(io, session);
    const stale = try std.fmt.allocPrint(arena, "{s}/exec-old.png", .{session});
    const fresh = try std.fmt.allocPrint(arena, "{s}/exec-new.png", .{session});
    const fresher = try std.fmt.allocPrint(arena, "{s}/exec-newest.png", .{session});
    const junk = try std.fmt.allocPrint(arena, "{s}/.DS_Store", .{root});
    for ([_][]const u8{ stale, fresh, fresher, junk }) |p|
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = "\x89PNG\r\n\x1a\n" ++ "payload" });

    // Stale = written two weeks ago; the .DS_Store is fresh but must be skipped.
    try Io.Dir.cwd().setTimestamps(io, stale, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = @intCast(now - 14 * day_ns) } } });
    try Io.Dir.cwd().setTimestamps(io, fresh, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = @intCast(now - 30 * std.time.ns_per_s) } } });
    try Io.Dir.cwd().setTimestamps(io, fresher, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = @intCast(now - 5 * std.time.ns_per_s) } } });

    const picked = newestFresh(io, arena, root, marker).?;
    try testing.expect(std.mem.endsWith(u8, picked.path, "exec-newest.png"));

    // A marker AFTER everything on disk finds nothing — the fabrication case,
    // and the state a run that generated nothing leaves behind.
    try testing.expect(newestFresh(io, arena, root, now + std.time.ns_per_s) == null);
    // An absent save_root is "no artifact", not a crash.
    try testing.expect(newestFresh(io, arena, "/nonexistent/generated_images", 0) == null);
    // Only the stale file is old enough to be excluded by a two-week marker.
    try testing.expect(newestFresh(io, arena, root, now - 13 * day_ns) != null);
}

test "#352: freshnessFloor only ever loosens by less than a second" {
    const s: i128 = std.time.ns_per_s;
    try testing.expectEqual(@as(i128, 5 * s), freshnessFloor(5 * s));
    try testing.expectEqual(@as(i128, 5 * s), freshnessFloor(5 * s + 999_999_999));
    try testing.expect(freshnessFloor(7 * s + 1) > 6 * s);
}

test "#352: a too-old CLI and a self-reported missing tool each get their own actionable message" {
    try testing.expect(tooOld("stream error: unexpected status 400: this model requires a newer version of Codex."));
    try testing.expect(!tooOld("some other 400"));
    try testing.expect(std.mem.indexOf(u8, too_old_text, "bun install -g @openai/codex") != null);

    try testing.expect(saidUnavailable("IMAGE_GEN_UNAVAILABLE"));
    try testing.expect(!saidUnavailable("image generated fine"));
    try testing.expect(std.mem.indexOf(u8, unavailable_text, "codex features list") != null);
    // The empty-handed success case names #352 so the failure is recognisable.
    try testing.expect(std.mem.indexOf(u8, no_artifact_text, "#352") != null);
}
