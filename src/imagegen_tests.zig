//! #352 imagegen behaviour tests. Split out of imagegen.zig (600-line
//! ceiling); referenced from its test block so they actually run.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const imagegen = @import("imagegen.zig");
const codex = @import("imagegen_codex.zig");
const skill = @import("imagegen_skill.zig");
const run_mod = @import("imagegen_run.zig");
const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;
const confinedPath = @import("approvals.zig").confinedPath;
const detect = imagegen.detect;
const execImagegen = imagegen.execImagegen;
const defaultOutPath = imagegen.defaultOutPath;

const testing = std.testing;

test "#352: default out paths stay unique across many rapid calls (the subagent fan-out case)" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = real_buf[0..try tmp.dir.realPath(io, &real_buf)];

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(testing.allocator);
    for (0..256) |_| {
        const path = try defaultOutPath(io, arena, base, "png");
        try testing.expect(std.mem.startsWith(u8, path, "imagegen-"));
        try testing.expect(confinedPath(path)); // a default path is always writable by the file tools
        try testing.expect((try seen.fetchPut(testing.allocator, path, {})) == null);
    }
    const taken = try defaultOutPath(io, arena, base, "png");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, taken }), .data = "x" });
    try testing.expect(!std.mem.eql(u8, taken, try defaultOutPath(io, arena, base, "png")));
}

test "#352: detect gates on the Codex skill, mirrors it, and decides which engines this machine has" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const saved = .{ imagegen.available, imagegen.script_path, imagegen.skill_dir, imagegen.api_key_present, imagegen.codex_ready, imagegen.codex_home };
    defer {
        imagegen.available = saved[0];
        imagegen.script_path = saved[1];
        imagegen.skill_dir = saved[2];
        imagegen.api_key_present = saved[3];
        imagegen.codex_ready = saved[4];
        imagegen.codex_home = saved[5];
    }

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = real_buf[0..try tmp.dir.realPath(io, &real_buf)];
    const fake_codex_home = try std.fmt.allocPrint(arena, "{s}/codex", .{base});
    const home = try std.fmt.allocPrint(arena, "{s}/home", .{base});

    // A CODEX_HOME with no skill in it: the tool does not exist.
    try Io.Dir.cwd().createDirPath(io, fake_codex_home);
    detect(io, arena, .{ .codex_home = fake_codex_home, .home = home });
    try testing.expect(!imagegen.available);
    try testing.expectEqualStrings("", imagegen.script_path);
    try testing.expect(!imagegen.api_key_present and !imagegen.codex_ready);

    // Install the skill where Codex keeps it.
    const src = try std.fmt.allocPrint(arena, "{s}/{s}", .{ fake_codex_home, skill.codex_rel });
    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(arena, "{s}/scripts", .{src}));
    for ([_]struct { path: []const u8, data: []const u8 }{
        .{ .path = "SKILL.md", .data = "---\nname: imagegen\ndescription: d\n---\n\n# Image Generation Skill\nuse image_gen\n" },
        .{ .path = "LICENSE.txt", .data = "LICENSE BODY" },
        .{ .path = "scripts/image_gen.py", .data = "print('gen')" },
    }) |f| try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ src, f.path }),
        .data = f.data,
    });

    detect(io, arena, .{ .codex_home = fake_codex_home, .home = home, .openai_api_key = "sk-test" });
    try testing.expect(imagegen.available and imagegen.api_key_present);
    // No auth.json in this fake CODEX_HOME, so the codex engine is not offered
    // however the real CLI happens to be installed on the test machine.
    try testing.expect(!imagegen.codex_ready);

    const dest = try std.fmt.allocPrint(arena, "{s}/{s}", .{ home, skill.install_rel });
    try testing.expectEqualStrings(dest, imagegen.skill_dir);
    const license = try Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/LICENSE.txt", .{dest}), arena, .limited(4096));
    try testing.expectEqualStrings("LICENSE BODY", license);
    const md = try Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/SKILL.md", .{dest}), arena, .limited(1 << 16));
    try testing.expect(std.mem.indexOf(u8, md, "<!-- graff addendum -->") != null);
    try testing.expect(std.mem.indexOf(u8, md, "one subagent per") != null);
    try testing.expect(std.mem.indexOf(u8, md, "use image_gen") != null); // original body kept

    // An empty key is not a key.
    detect(io, arena, .{ .codex_home = fake_codex_home, .home = home, .openai_api_key = "" });
    try testing.expect(imagegen.available and !imagegen.api_key_present);
}

test "#352: with no usable engine the tool refuses up front and spawns nothing" {
    const gpa = testing.allocator;
    const saved = .{ imagegen.available, imagegen.script_path, imagegen.api_key_present, imagegen.codex_ready };
    defer {
        imagegen.available = saved[0];
        imagegen.script_path = saved[1];
        imagegen.api_key_present = saved[2];
        imagegen.codex_ready = saved[3];
    }
    // Any spawn at all is a test failure: nothing below should reach one.
    const S = struct {
        fn boom(_: Allocator, _: Io, _: []const []const u8, _: u64, _: ?[]const u8) anyerror!run_mod.Outcome {
            return error.TestUnexpectedSpawn;
        }
    };
    const saved_hook = run_mod.hook;
    defer run_mod.hook = saved_hook;
    run_mod.hook = S.boom;

    var parsed = try std.json.parseFromSlice(Value, gpa, "{\"prompt\":\"a red circle\"}", .{});
    defer parsed.deinit();
    var client: std.http.Client = undefined;
    const ctx: ToolCtx = .{
        .gpa = gpa,
        .io = testing.io,
        .client = &client,
        .provider = undefined,
        .registry = null,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
    };

    imagegen.available = false;
    const off = try execImagegen(ctx, parsed.value);
    defer gpa.free(off.text);
    try testing.expect(off.is_error and std.mem.indexOf(u8, off.text, "CODEX_HOME") != null);

    // Detected, but neither engine usable: the refusal names both requirements.
    imagegen.available = true;
    imagegen.codex_ready = false;
    imagegen.api_key_present = false;
    imagegen.script_path = "/nonexistent/image_gen.py";
    const none = try execImagegen(ctx, parsed.value);
    defer gpa.free(none.text);
    try testing.expect(none.is_error);
    for ([_][]const u8{ "codex login", "OPENAI_API_KEY", "#352", "NOTHING was generated" }) |needle|
        try testing.expect(std.mem.indexOf(u8, none.text, needle) != null);

    var empty = try std.json.parseFromSlice(Value, gpa, "{}", .{});
    defer empty.deinit();
    const no_prompt = try execImagegen(ctx, empty.value);
    defer gpa.free(no_prompt.text);
    try testing.expect(no_prompt.is_error and std.mem.indexOf(u8, no_prompt.text, "prompt") != null);
}

/// A fake `codex exec` for the replay tests below. It reads the private
/// CODEX_HOME out of the argv graff built, plants whatever artifact the
/// scenario calls for, and always exits 0 with a confident success narrative —
/// because that is exactly what #352 did.
const FakeCodex = struct {
    /// What to leave in the private save_root before "succeeding".
    var plant: enum { nothing, stale_png, fresh_png, fresh_junk } = .nothing;
    var transcript: []const u8 = "Generated your 64x64 PNG. Verified it is a 64x64 PNG.";

    fn privateHome(argv: []const []const u8) ?[]const u8 {
        for (argv) |a| {
            if (std.mem.startsWith(u8, a, "CODEX_HOME=")) return a["CODEX_HOME=".len..];
        }
        return null;
    }

    fn run(a: Allocator, io: Io, argv: []const []const u8, _: u64, _: ?[]const u8) anyerror!run_mod.Outcome {
        // sips (dimension reporting) also goes through the seam.
        if (std.mem.eql(u8, argv[0], "sips"))
            return .{ .exit_code = 0, .stdout = "f\n  pixelWidth: 64\n  pixelHeight: 64\n" };

        const home = privateHome(argv) orelse return error.TestMissingCodexHome;
        if (plant != .nothing) {
            const dir = try std.fmt.allocPrint(a, "{s}/generated_images/019f-session", .{home});
            try Io.Dir.cwd().createDirPath(io, dir);
            const path = try std.fmt.allocPrint(a, "{s}/exec-call.png", .{dir});
            const png = "\x89PNG\r\n\x1a\n" ++ ("p" ** 4096);
            try Io.Dir.cwd().writeFile(io, .{
                .sub_path = path,
                .data = if (plant == .fresh_junk) "{\"error\": \"no\"}" ++ ("x" ** 4096) else png,
            });
            if (plant == .stale_png) {
                const two_weeks: i128 = 14 * 24 * 60 * 60 * std.time.ns_per_s;
                const then = Io.Timestamp.now(io, .real).nanoseconds - two_weeks;
                try Io.Dir.cwd().setTimestamps(io, path, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = @intCast(then) } } });
            }
        }
        // Exit 0, every time. The transcript is confident, every time.
        return .{ .exit_code = 0, .stdout = transcript };
    }
};

// The whole point of the tool, end to end: a codex run that says it succeeded
// but produced nothing this run must come back as an ERROR.
test "#352 replay: codex exits 0 with a confident success transcript and NO fresh artifact — reported as failure" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = real_buf[0..try tmp.dir.realPath(io, &real_buf)];

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A real-looking CODEX_HOME (credentials only) plus a work dir for output.
    const home = try std.fmt.allocPrint(arena, "{s}/codex", .{base});
    try Io.Dir.cwd().createDirPath(io, home);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/auth.json", .{home}), .data = "{}" });
    const work = try std.fmt.allocPrint(arena, "{s}/work", .{base});
    try Io.Dir.cwd().createDirPath(io, work);

    const saved = .{ imagegen.available, imagegen.codex_ready, imagegen.codex_home, imagegen.scratch_root, imagegen.api_key_present, run_mod.hook };
    defer {
        imagegen.available = saved[0];
        imagegen.codex_ready = saved[1];
        imagegen.codex_home = saved[2];
        imagegen.scratch_root = saved[3];
        imagegen.api_key_present = saved[4];
        run_mod.hook = saved[5];
    }
    imagegen.available = true;
    imagegen.codex_ready = true;
    imagegen.codex_home = home;
    imagegen.scratch_root = base;
    imagegen.api_key_present = false; // codex engine only
    run_mod.hook = FakeCodex.run;

    var client: std.http.Client = undefined;
    const ctx: ToolCtx = .{
        .gpa = gpa,
        .io = io,
        .client = &client,
        .provider = undefined,
        .registry = null,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
        .agent_cwd = work, // output lands in the temp work dir, not the repo
    };
    var input = try std.json.parseFromSlice(Value, gpa, "{\"prompt\":\"a 64x64 red circle\",\"out\":\"shot.png\"}", .{});
    defer input.deinit();
    const out_path = try std.fmt.allocPrint(arena, "{s}/shot.png", .{work});

    // 1. THE #352 CASE: exit 0, confident transcript, nothing written.
    FakeCodex.plant = .nothing;
    {
        const r = try execImagegen(ctx, input.value);
        defer gpa.free(r.text);
        try std.testing.expect(r.is_error);
        try std.testing.expect(std.mem.indexOf(u8, r.text, "#352") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.text, "no image was generated") != null);
        // and no file was invented at the output path
        try std.testing.expect(Io.Dir.cwd().statFile(io, out_path, .{}) == error.FileNotFound);
    }

    // 2. A STALE artifact in our own save_root is still not this run's work.
    FakeCodex.plant = .stale_png;
    {
        const r = try execImagegen(ctx, input.value);
        defer gpa.free(r.text);
        try std.testing.expect(r.is_error);
        try std.testing.expect(Io.Dir.cwd().statFile(io, out_path, .{}) == error.FileNotFound);
    }

    // 3. A fresh file that is not an image fails on its signature.
    FakeCodex.plant = .fresh_junk;
    {
        const r = try execImagegen(ctx, input.value);
        defer gpa.free(r.text);
        try std.testing.expect(r.is_error);
        try std.testing.expect(std.mem.indexOf(u8, r.text, "not a PNG, JPEG or WebP") != null);
    }

    // 4. The happy path, to prove the failures above are the checks working
    // rather than the tool being broken: a fresh valid PNG is copied out and
    // reported with a receipt naming the checks that passed.
    FakeCodex.plant = .fresh_png;
    {
        const r = try execImagegen(ctx, input.value);
        defer gpa.free(r.text);
        try std.testing.expect(!r.is_error);
        try std.testing.expect(std.mem.indexOf(u8, r.text, "generated and verified: shot.png") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.text, "engine codex") != null);
        const copied = try Io.Dir.cwd().readFileAlloc(io, out_path, arena, .limited(1 << 16));
        try std.testing.expect(std.mem.startsWith(u8, copied, "\x89PNG\r\n\x1a\n"));
    }

    // The private CODEX_HOME is cleaned up, and the real one still has its
    // credentials (the symlinks were unlinked, not followed).
    const auth = try Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/auth.json", .{home}), arena, .limited(16));
    try std.testing.expectEqualStrings("{}", auth);
    try std.testing.expect(Io.Dir.cwd().statFile(io, try std.fmt.allocPrint(arena, "{s}/generated_images", .{home}), .{}) == error.FileNotFound);
}

test "#352 + plan mode: imagegen is refused like write_file, and nothing is spawned" {
    const gpa = std.testing.allocator;
    const main_mod = @import("main.zig");
    const exec = @import("exec.zig");

    const saved_plan = main_mod.plan_mode;
    const saved_available = imagegen.available;
    const saved_hook = run_mod.hook;
    defer {
        main_mod.plan_mode = saved_plan;
        imagegen.available = saved_available;
        run_mod.hook = saved_hook;
    }
    const S = struct {
        fn boom(_: Allocator, _: Io, _: []const []const u8, _: u64, _: ?[]const u8) anyerror!run_mod.Outcome {
            return error.TestUnexpectedSpawn;
        }
    };
    run_mod.hook = S.boom;
    imagegen.available = true;
    main_mod.plan_mode = true;

    var input = try std.json.parseFromSlice(Value, gpa, "{\"prompt\":\"a red circle\"}", .{});
    defer input.deinit();
    var client: std.http.Client = undefined;
    const ctx: ToolCtx = .{
        .gpa = gpa,
        .io = std.testing.io,
        .client = &client,
        .provider = undefined,
        .registry = null,
        .from_sub = true, // the subagent path, which skips the root gate
        .approvals = null,
        .tracer = null,
    };
    const denied = exec.execTool(ctx, .{ .id = "c1", .name = "imagegen", .input = input.value });
    defer gpa.free(denied.text);
    try std.testing.expect(denied.is_error);
    try std.testing.expect(std.mem.indexOf(u8, denied.text, "plan mode") != null);
}
