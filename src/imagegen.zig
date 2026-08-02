//! #352: the `imagegen` tool — text prompt in, one VERIFIED image file out.
//!
//! Why it is gated (tool_gates.zig) rather than always present: the engine is
//! not in this binary. It is `scripts/image_gen.py`, shipped with the Codex
//! `imagegen` skill at $CODEX_HOME/skills/.system/imagegen. When that skill is
//! not installed there is no image generator on this machine, and advertising
//! a tool that can only ever answer "not installed" costs schema tokens and a
//! wasted turn. So the tool appears in the catalogs — root AND subagent — only
//! after startup finds the skill, at which point graff also mirrors it into
//! ~/.harness/skills/imagegen so `skill imagegen` loads the playbook that
//! documents this CLI (imagegen_skill.zig).
//!
//! Why it does not shell out to codex: it cannot. The `image_gen` tool the
//! skill calls "preferred" runs server-side inside the Codex app and never
//! fires in `codex exec` — during #352 codex 0.141.0 was asked for a 64x64 PNG,
//! produced none, and reported success anyway by resizing a two-week-old file
//! out of ~/.codex/generated_images/. The CLI plus OPENAI_API_KEY is the only
//! path that actually renders anything, so it is the only path here.
//!
//! Which is also why every success is a receipt rather than a claim: the
//! result is emitted only after imagegen_verify.zig confirms a file exists at
//! the requested path, is newer than this call, actually changed if it already
//! existed, clears a size floor and carries the right container signature.
//!
//! Concurrency: one call makes one image, synchronously, fully verified. N
//! images means N subagents (graff's existing fan-out), each calling this once
//! — rather than a job queue in here that would put the per-image proof back
//! at arm's length from the agent that has to report it.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;
const ToolOutput = tools.ToolOutput;
const strField = tools.strField;
const missingArg = tools.missingArg;
const outsideCwd = tools.outsideCwd;
const approvals_mod = @import("approvals.zig");
const confinedPath = approvals_mod.confinedPath;
const noSymlinkEscape = approvals_mod.noSymlinkEscape;
const jobs = @import("jobs.zig");
const util = @import("util.zig");
const skill = @import("imagegen_skill.zig");
const verify = @import("imagegen_verify.zig");

pub const tool_name = "imagegen";
pub const tool_desc = "Generate an image from a text prompt and write it to one file under the working directory. Backed by the Codex imagegen skill's bundled CLI (scripts/image_gen.py, default model gpt-image-2), which graff copied into ~/.harness/skills/imagegen — load that skill with the skill tool for prompting guidance; it refers to this tool as $imagegen (a provider tool name cannot contain a dollar sign, so it is plain imagegen here). Requires OPENAI_API_KEY in graff's environment: the hosted codex image_gen tool is unavailable outside the Codex app, so there is no keyless path and without the key this generates nothing. Returns the path, byte size, format and pixel size of a VERIFIED freshly generated file — the call only succeeds once the file is proven to exist, to be newer than the call, to clear a size floor and to carry the right image signature, so never report an image this tool did not hand you a verified path for. One call makes one image; for multiple images spawn one subagent per image (each calls imagegen once and reports its verified path back) so the generations run concurrently.";
pub const tool_schema =
    \\{"type": "object", "properties": {"prompt": {"type": "string", "description": "What to draw. Be specific about subject, style, composition and background; the imagegen skill's references/prompting.md is worth loading first."}, "out": {"type": "string", "description": "Output file path, relative to the working directory (extension picks the container: .png, .jpg, .webp). Default: a fresh, collision-proof imagegen-<nonce>.png in the working directory."}, "size": {"type": "string", "description": "Pixel size, e.g. 1024x1024, 1536x1024, 1024x1536, or auto (default)."}, "model": {"type": "string", "description": "Image model. Default gpt-image-2; use gpt-image-1.5 for true model-native transparency."}, "quality": {"type": "string", "description": "low, medium (default) or high."}, "background": {"type": "string", "description": "transparent or opaque. Transparency needs a transparency-capable model and a png or webp output."}, "output_format": {"type": "string", "description": "png, jpeg or webp. Defaults to the extension of out."}}, "required": ["prompt"]}
;

/// Set once at startup by `detect`, then read by every catalog assembly and by
/// dispatch. Process-global for the same reason the #330 gate is: subagents,
/// workflow workers and judges all run in-process, so one flag covers the
/// whole agent tree with nothing per-agent to forget to inherit.
pub var available: bool = false;
/// Absolute path to the `image_gen.py` we will actually run (the mirrored copy
/// when the mirror succeeded, otherwise Codex's own).
pub var script_path: []const u8 = "";
/// Directory that script came from, for the tool's own error text.
pub var skill_dir: []const u8 = "";
/// Whether OPENAI_API_KEY was set in graff's environment at startup. Captured
/// there because that is where the environment map lives; graff never mutates
/// its own environment, so this cannot go stale mid-session.
pub var api_key_present: bool = false;

pub const default_model = "gpt-image-2";
/// One generation is a network round trip through an image model; 4 minutes is
/// generous for the slowest (high quality, large size) and still bounded, so a
/// hung request cannot pin a pool thread for the rest of the session.
pub const deadline_ms: u64 = 240 * 1000;
const stdout_cap = 64 * 1024;
const stderr_cap = 32 * 1024;
/// How much generator stderr rides along with a failure. Enough for a stack
/// trace or an API error body, not enough to flood the context.
const stderr_tail_cap = 1600;

/// Find the Codex skill, mirror it, and decide whether the tool exists this
/// session. Called once at startup, before the skill scan and before any tool
/// catalog is rendered. Takes the two environment values it needs by value
/// rather than an environ map, so a test can drive it with plain strings.
pub fn detect(io: Io, arena: Allocator, codex_home: ?[]const u8, home: ?[]const u8, api_key: ?[]const u8) void {
    available = false;
    script_path = "";
    skill_dir = "";
    api_key_present = if (api_key) |value| value.len > 0 else false;

    const src = skill.codexSkillDir(arena, codex_home, home) orelse return;
    if (!skill.present(io, arena, src)) return; // no Codex skill -> no tool

    // Prefer the mirrored copy: it is the one `skill imagegen` loads, so tool
    // and playbook stay the same version. A failed mirror (read-only HOME, a
    // half-copied tree) must not cost us the tool — fall back to Codex's own.
    if (skill.installDir(arena, home)) |dest| {
        if (skill.needsSync(io, arena, src, dest)) skill.sync(io, arena, src, dest) catch {};
        if (engineScript(io, arena, dest)) |path| {
            script_path = path;
            skill_dir = dest;
        }
    }
    if (script_path.len == 0) {
        script_path = engineScript(io, arena, src) orelse return;
        skill_dir = src;
    }
    available = true;
}

fn engineScript(io: Io, arena: Allocator, dir: []const u8) ?[]const u8 {
    const path = std.fmt.allocPrint(arena, "{s}/scripts/image_gen.py", .{dir}) catch return null;
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    if (st.kind != .file) return null;
    return path;
}

pub const Args = struct {
    prompt: []const u8,
    out: []const u8,
    model: []const u8 = default_model,
    size: ?[]const u8 = null,
    quality: ?[]const u8 = null,
    background: ?[]const u8 = null,
    output_format: ?[]const u8 = null,
};

/// `python3 <script> generate --prompt <p> --out <path> --force --model <m> …`
///
/// `--force` because the caller may have named a path that exists and the CLI
/// would otherwise refuse; whether the rewrite actually happened is not the
/// CLI's word to take, it is what verification decides afterwards.
pub fn buildArgv(arena: Allocator, script: []const u8, a: Args) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        "python3",  script,    "generate",
        "--prompt", a.prompt,  "--out",
        a.out,      "--force", "--model",
        a.model,
    });
    if (a.size) |v| try argv.appendSlice(arena, &.{ "--size", v });
    if (a.quality) |v| try argv.appendSlice(arena, &.{ "--quality", v });
    if (a.background) |v| try argv.appendSlice(arena, &.{ "--background", v });
    if (a.output_format) |v| try argv.appendSlice(arena, &.{ "--output-format", v });
    return argv.items;
}

/// Optional values land straight in an argv slot, so they must not be able to
/// impersonate a flag or smuggle a second argument. The real vocabulary here
/// is short (1024x1024, high, transparent, gpt-image-1.5), so the allowed
/// characters can be narrow.
pub fn okFlagValue(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    if (value[0] == '-') return false;
    for (value) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
        else => return false,
    };
    return true;
}

/// Distinguishes concurrent default output paths. Two subagents generating
/// into the same cwd in the same second is the normal case for the fan-out
/// pattern this tool documents, so a timestamp is not enough: 80 bits of
/// CSPRNG entropy separates processes, and the process-lifetime counter
/// separates same-process callers even if the RNG were to repeat.
var out_seq: std.atomic.Value(u32) = .init(0);
const nonce_len = 20 + 1 + 8; // hex(10 bytes) + '-' + hex(u32)

pub fn makeNonce(io: Io, buf: *[nonce_len]u8) []const u8 {
    const seq = out_seq.fetchAdd(1, .monotonic);
    var raw: [10]u8 = undefined;
    io.randomSecure(&raw) catch {
        // Never fall back to something a sibling could reproduce: the clock
        // plus the counter still differ per call.
        const ns: u128 = @bitCast(@as(i128, Io.Timestamp.now(io, .real).nanoseconds));
        std.mem.writeInt(u64, raw[0..8], @truncate(ns), .little);
        std.mem.writeInt(u16, raw[8..10], @truncate(seq), .little);
    };
    const hex = std.fmt.bytesToHex(raw, .lower);
    return std.fmt.bufPrint(buf, "{s}-{x:0>8}", .{ &hex, seq }) catch buf[0..0];
}

/// A cwd-relative path that does not exist yet. `base` is the agent's isolated
/// worktree when it has one, so the existence check looks where the file will
/// actually be written.
pub fn defaultOutPath(io: Io, arena: Allocator, base: ?[]const u8, ext: []const u8) ![]const u8 {
    var attempt: u8 = 0;
    while (attempt < 8) : (attempt += 1) {
        var buf: [nonce_len]u8 = undefined;
        const rel = try std.fmt.allocPrint(arena, "imagegen-{s}.{s}", .{ makeNonce(io, &buf), ext });
        const full: []const u8 = if (base) |b| try std.fmt.allocPrint(arena, "{s}/{s}", .{ b, rel }) else rel;
        if (Io.Dir.cwd().statFile(io, full, .{})) |_| continue else |_| return rel;
    }
    return error.PathAlreadyExists;
}

fn errText(gpa: Allocator, text: []const u8) !ToolOutput {
    return .{ .text = try gpa.dupe(u8, text), .is_error = true };
}

const unavailable_text = "imagegen is not available in this session: graff did not find the Codex imagegen skill at $CODEX_HOME/skills/.system/imagegen (CODEX_HOME defaults to ~/.codex), and its scripts/image_gen.py is the only image generator this harness can run. Install the Codex imagegen skill and restart graff. Do not substitute an existing file for a generated one.";

const no_key_text = "imagegen needs OPENAI_API_KEY exported in graff's environment, and it was not set when this session started. The tool runs the Codex imagegen skill's scripts/image_gen.py CLI, which is the only image engine available here: the hosted codex image_gen tool is server-side and never fires outside the Codex app (issue #352), so there is no keyless path. NOTHING was generated — do not report an image, and do not pass off an existing file as one. Export OPENAI_API_KEY, restart graff, then call imagegen again.";

/// Runs on a pool thread. Every failure is an is_error result; there is no
/// branch that returns success without the full verification passing.
pub fn execImagegen(ctx: ToolCtx, input: Value) !ToolOutput {
    const gpa = ctx.gpa;
    const io = ctx.io;
    // Layer 2 of the gate: refuse a name a provider hallucinated from an
    // earlier session even though it was never advertised here.
    if (!available or script_path.len == 0) return errText(gpa, unavailable_text);

    const prompt = strField(input, "prompt") orelse return missingArg(gpa, "prompt");
    if (std.mem.trim(u8, prompt, " \t\r\n").len == 0)
        return errText(gpa, "prompt must not be empty — describe the image to generate");
    if (!api_key_present) return errText(gpa, no_key_text);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args: Args = .{ .prompt = prompt, .out = "" };
    inline for (.{ "model", "size", "quality", "background", "output_format" }) |field| {
        if (strField(input, field)) |value| {
            if (!okFlagValue(value)) return .{
                .text = try std.fmt.allocPrint(gpa, "invalid {s} value '{s}' — letters, digits, dot, dash and underscore only (e.g. size 1024x1024, quality high, model gpt-image-1.5)", .{ field, value }),
                .is_error = true,
            };
            if (comptime std.mem.eql(u8, field, "model")) args.model = value else @field(args, field) = value;
        }
    }
    const explicit_format: ?verify.Format = if (args.output_format) |name|
        verify.Format.fromName(name) orelse return .{
            .text = try std.fmt.allocPrint(gpa, "unsupported output_format '{s}' — use png, jpeg or webp", .{name}),
            .is_error = true,
        }
    else
        null;

    const out_rel = if (strField(input, "out")) |p|
        p
    else
        defaultOutPath(io, arena, ctx.agent_cwd, if (explicit_format) |f| f.label() else "png") catch
            return errText(gpa, "could not pick an unused default output path — pass out explicitly");
    if (!confinedPath(out_rel) or !noSymlinkEscape(io, out_rel, ctx.agent_cwd)) return outsideCwd(gpa, out_rel);
    const format = explicit_format orelse verify.Format.fromPath(out_rel);
    // #276 P0-1: a worktree-isolated agent writes inside its own worktree.
    const resolved: []const u8 = if (ctx.agent_cwd) |base|
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, out_rel })
    else
        out_rel;
    args.out = resolved;

    const before = verify.snapshot(io, resolved);
    // Taken BEFORE the spawn: anything the generator produces must be at least
    // this new, and a file older than this is by definition not from this run.
    const started_ns = Io.Timestamp.now(io, .real).nanoseconds;

    const argv = try buildArgv(arena, script_path, args);
    const run = jobs.runCappedWithOptions(gpa, io, argv, stdout_cap, stderr_cap, deadline_ms, jobs.toolRunOptions(ctx.agent_cwd)) catch |err| switch (err) {
        error.FileNotFound => return errText(gpa, "python3 is not on PATH, so the imagegen CLI cannot run. Install Python 3, then call imagegen again. Nothing was generated."),
        else => return tools.failure(gpa, err),
    };
    defer {
        gpa.free(run.stdout);
        gpa.free(run.stderr);
    }
    const err_tail = tail(run.stderr, stderr_tail_cap);

    if (run.cancelled) return .{ .text = try gpa.dupe(u8, "imagegen was cancelled — nothing was generated"), .is_error = true, .cancelled = true };
    if (run.timed_out) return .{
        .text = try std.fmt.allocPrint(gpa, "imagegen timed out after {d}s and the generator was killed — nothing verified was produced. Retry, or try a smaller size or lower quality.\nstderr tail:\n{s}", .{ deadline_ms / 1000, err_tail }),
        .is_error = true,
    };
    const exited: ?u8 = if (run.term == .exited) run.term.exited else null;
    if (exited == null or exited.? != 0) return .{
        .text = try std.fmt.allocPrint(gpa, "imagegen failed: {s} exited {?d}. Nothing was generated — do not report an image.\nstderr tail:\n{s}", .{ std.fs.path.basename(script_path), exited, err_tail }),
        .is_error = true,
    };

    // Exit 0 is where #352's fabrication began, so it proves nothing on its own.
    var head_buf: [16]u8 = undefined;
    const after: ?verify.Snapshot = blk: {
        const shot = verify.snapshot(io, resolved);
        break :blk if (shot.existed) shot else null;
    };
    const head = headBytes(io, resolved, &head_buf);
    const verdict = verify.evaluate(before, after, started_ns, head, format);
    if (verdict != .ok) return .{
        .text = try std.fmt.allocPrint(
            gpa,
            "imagegen could NOT verify a freshly generated image and is therefore reporting failure, even though the generator exited 0.\nfailed check: {s}\nwhat that means: {s}\npath: {s}\nDo not claim an image was produced, and do not substitute another file for it.\nstderr tail:\n{s}",
            .{ verdict.failedCheck(), verdict.detail(), out_rel, err_tail },
        ),
        .is_error = true,
    };

    const size_bytes = after.?.size;
    const dims = pixelDims(arena, io, resolved);
    return .{ .text = try std.fmt.allocPrint(
        gpa,
        "generated and verified: {s} ({d} bytes, {s}{s}, model {s}). Checks passed: file exists, mtime is newer than this call, size above the {d}-byte floor, and the leading bytes match the {s} signature.",
        .{ out_rel, size_bytes, format.label(), dims orelse "", args.model, verify.min_bytes, format.label() },
    ) };
}

fn headBytes(io: Io, path: []const u8, buf: []u8) []const u8 {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return &.{};
    defer file.close(io);
    const n = file.readPositionalAll(io, buf, 0) catch return &.{};
    return buf[0..n];
}

/// The LAST bytes of the generator's stderr — a Python traceback puts the
/// useful line at the end, and an API error body is short.
fn tail(text: []const u8, cap: usize) []const u8 {
    if (text.len <= cap) return text;
    const cut = text[text.len - cap ..];
    // Start at a line boundary so the excerpt does not open mid-UTF-8.
    return if (std.mem.indexOfScalar(u8, cut, '\n')) |nl| cut[nl + 1 ..] else cut;
}

/// Pixel dimensions, macOS only and strictly best-effort: this is extra
/// reporting detail, never part of the pass/fail decision.
fn pixelDims(arena: Allocator, io: Io, path: []const u8) ?[]const u8 {
    if (builtin.os.tag != .macos) return null;
    const run = jobs.runCapped(arena, io, &.{ "sips", "-g", "pixelWidth", "-g", "pixelHeight", path }, 4096, 1024, 10_000) catch return null;
    if (run.term != .exited or run.term.exited != 0) return null;
    const w = fieldAfter(run.stdout, "pixelWidth:") orelse return null;
    const h = fieldAfter(run.stdout, "pixelHeight:") orelse return null;
    return std.fmt.allocPrint(arena, ", {s}x{s} px", .{ w, h }) catch null;
}

fn fieldAfter(text: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    const value = std.mem.trim(u8, rest[0..line_end], " \t\r");
    return if (value.len > 0 and value.len < 12) value else null;
}

const testing = std.testing;

test "#352: argv is a generate call with the required flags, optionals only when given" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const minimal = try buildArgv(arena, "/s/image_gen.py", .{ .prompt = "a red circle", .out = "out.png" });
    try testing.expectEqualStrings("python3", minimal[0]);
    try testing.expectEqualStrings("/s/image_gen.py", minimal[1]);
    try testing.expectEqualStrings("generate", minimal[2]);
    try testing.expectEqualStrings("--prompt", minimal[3]);
    try testing.expectEqualStrings("a red circle", minimal[4]);
    try testing.expectEqualStrings("--out", minimal[5]);
    try testing.expectEqualStrings("out.png", minimal[6]);
    try testing.expectEqualStrings("--force", minimal[7]);
    try testing.expectEqualStrings("--model", minimal[8]);
    try testing.expectEqualStrings(default_model, minimal[9]);
    try testing.expectEqual(@as(usize, 10), minimal.len); // no stray optional flags

    const full = try buildArgv(arena, "/s/image_gen.py", .{
        .prompt = "p",
        .out = "o.webp",
        .model = "gpt-image-1.5",
        .size = "1024x1536",
        .quality = "high",
        .background = "transparent",
        .output_format = "webp",
    });
    try testing.expectEqual(@as(usize, 18), full.len);
    for ([_][]const u8{ "--size", "1024x1536", "--quality", "high", "--background", "transparent", "--output-format", "webp" }) |want| {
        var found = false;
        for (full) |arg| {
            if (std.mem.eql(u8, arg, want)) found = true;
        }
        try testing.expect(found);
    }
    // --dry-run is never assembled: it prints a plan and writes no file, so it
    // could only ever produce an unverifiable "success".
    for (full) |arg| try testing.expect(!std.mem.eql(u8, arg, "--dry-run"));
}

test "#352: optional values cannot impersonate a flag or smuggle an argument" {
    for ([_][]const u8{ "1024x1024", "auto", "high", "transparent", "gpt-image-1.5", "PNG" }) |ok|
        try testing.expect(okFlagValue(ok));
    for ([_][]const u8{ "", "--out", "-q", "1024 1024", "a;rm -rf /", "$(id)", "a\nb", "a/b" }) |bad|
        try testing.expect(!okFlagValue(bad));
    var long: [65]u8 = @splat('a');
    try testing.expect(!okFlagValue(&long));
}

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
        try testing.expect(std.mem.endsWith(u8, path, ".png"));
        try testing.expect(confinedPath(path)); // a default path is always writable by the file tools
        try testing.expect((try seen.fetchPut(testing.allocator, path, {})) == null);
    }
    // An existing file at the drawn name is skipped rather than overwritten.
    const taken = try defaultOutPath(io, arena, base, "png");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, taken }), .data = "x" });
    try testing.expect(!std.mem.eql(u8, taken, try defaultOutPath(io, arena, base, "png")));
}

test "#352: detect gates on the Codex skill and mirrors it into the personal tier" {
    const io = testing.io;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const saved_available = available;
    const saved_script = script_path;
    const saved_dir = skill_dir;
    const saved_key = api_key_present;
    defer {
        available = saved_available;
        script_path = saved_script;
        skill_dir = saved_dir;
        api_key_present = saved_key;
    }

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = real_buf[0..try tmp.dir.realPath(io, &real_buf)];
    const codex_home = try std.fmt.allocPrint(arena, "{s}/codex", .{base});
    const home = try std.fmt.allocPrint(arena, "{s}/home", .{base});

    // A CODEX_HOME with no skill in it: the tool does not exist.
    try Io.Dir.cwd().createDirPath(io, codex_home);
    detect(io, arena, codex_home, home, null);
    try testing.expect(!available);
    try testing.expectEqualStrings("", script_path);
    try testing.expect(!api_key_present); // and the key check is honest about being unset

    // Install the skill where Codex keeps it.
    const src = try std.fmt.allocPrint(arena, "{s}/{s}", .{ codex_home, skill.codex_rel });
    try Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(arena, "{s}/scripts", .{src}));
    for ([_]struct { path: []const u8, data: []const u8 }{
        .{ .path = "SKILL.md", .data = "---\nname: imagegen\ndescription: d\n---\n\n# Image Generation Skill\nuse image_gen\n" },
        .{ .path = "LICENSE.txt", .data = "LICENSE BODY" },
        .{ .path = "scripts/image_gen.py", .data = "print('gen')" },
    }) |f| try Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ src, f.path }),
        .data = f.data,
    });

    detect(io, arena, codex_home, home, "sk-test");
    try testing.expect(available);
    try testing.expect(api_key_present);
    // The mirrored copy is what runs, so tool and playbook are the same version.
    const dest = try std.fmt.allocPrint(arena, "{s}/{s}", .{ home, skill.install_rel });
    try testing.expectEqualStrings(dest, skill_dir);
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{s}/scripts/image_gen.py", .{dest}), script_path);
    // …with its license, and with the addendum leading the body.
    const license = try Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/LICENSE.txt", .{dest}), arena, .limited(4096));
    try testing.expectEqualStrings("LICENSE BODY", license);
    const md = try Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/SKILL.md", .{dest}), arena, .limited(1 << 16));
    try testing.expect(std.mem.indexOf(u8, md, "<!-- graff addendum -->") != null);
    try testing.expect(std.mem.indexOf(u8, md, "one subagent per") != null);
    try testing.expect(std.mem.indexOf(u8, md, "use image_gen") != null); // original body kept

    // An empty key is not a key.
    detect(io, arena, codex_home, home, "");
    try testing.expect(available and !api_key_present);
}

test "#352: the honest no-key error refuses to generate and says why" {
    const gpa = testing.allocator;
    const saved_available = available;
    const saved_script = script_path;
    const saved_key = api_key_present;
    defer {
        available = saved_available;
        script_path = saved_script;
        api_key_present = saved_key;
    }

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

    // Not detected at all: refused before anything is spawned.
    available = false;
    script_path = "";
    const off = try execImagegen(ctx, parsed.value);
    defer gpa.free(off.text);
    try testing.expect(off.is_error);
    try testing.expect(std.mem.indexOf(u8, off.text, "CODEX_HOME") != null);

    // Detected, but no key: still nothing spawned, and the message says so.
    available = true;
    script_path = "/nonexistent/image_gen.py"; // never reached
    api_key_present = false;
    const no_key = try execImagegen(ctx, parsed.value);
    defer gpa.free(no_key.text);
    try testing.expect(no_key.is_error);
    try testing.expect(std.mem.indexOf(u8, no_key.text, "OPENAI_API_KEY") != null);
    try testing.expect(std.mem.indexOf(u8, no_key.text, "#352") != null);
    try testing.expect(std.mem.indexOf(u8, no_key.text, "NOTHING was generated") != null);

    // A missing prompt is caught before the key check, as a plain missing-arg.
    var empty = try std.json.parseFromSlice(Value, gpa, "{}", .{});
    defer empty.deinit();
    const no_prompt = try execImagegen(ctx, empty.value);
    defer gpa.free(no_prompt.text);
    try testing.expect(no_prompt.is_error);
    try testing.expect(std.mem.indexOf(u8, no_prompt.text, "prompt") != null);
}

test "#352: stderr tails keep the end of a traceback and start on a line boundary" {
    try testing.expectEqualStrings("short", tail("short", 100));
    const long = "line one\nline two\nline three\n";
    const cut = tail(long, 14);
    try testing.expect(std.mem.indexOf(u8, cut, "line three") != null);
    try testing.expect(std.mem.indexOf(u8, cut, "line one") == null);
    try testing.expect(std.mem.indexOfScalar(u8, cut, '\n') == null or cut[0] != '\n');
    try testing.expectEqualStrings("1024", fieldAfter("  pixelWidth: 1024\n  pixelHeight: 768\n", "pixelWidth:").?);
    try testing.expect(fieldAfter("nothing here", "pixelWidth:") == null);
}

test {
    _ = skill;
    _ = verify;
}
