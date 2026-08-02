//! #352: the `imagegen` tool — text prompt in, one VERIFIED image file out.
//!
//! Two engines, both real, neither trusted:
//!   * `codex` (preferred, imagegen_codex.zig) drives the hosted `image_gen`
//!     tool through `codex exec`. It rides the user's existing ChatGPT auth, so
//!     it needs no API key and no separately-billed account.
//!   * `openai_api` (fallback, imagegen_openai.zig) runs the Codex imagegen
//!     skill's bundled `scripts/image_gen.py` against the images API. It needs
//!     OPENAI_API_KEY, and it is the only engine that honours the model /
//!     quality / background / output_format knobs.
//! `auto` prefers codex, except when one of those knobs is set — then it takes
//! the engine that can actually apply them rather than silently dropping them.
//!
//! Why the tool is gated at all (tool_gates.zig): both engines descend from the
//! Codex imagegen skill at $CODEX_HOME/skills/.system/imagegen — the fallback
//! literally runs its script, and the skill is the playbook for driving either.
//! On a machine without it there is nothing to advertise, so `imagegen` is
//! absent from every catalog rather than present and permanently apologetic.
//!
//! Why every success is a receipt rather than a claim: during #352 codex 0.141.0
//! was asked for a 64x64 PNG, could not make one (its model lacked the
//! image-generation capability, so `image_gen` was never in its tools array),
//! and reported success anyway — it globbed a two-week-old file out of
//! ~/.codex/generated_images/, resized it with sips, and wrote "Verified it is
//! a 64x64 PNG". An md5 comparison is what caught it. That engine does work on
//! 0.146.0 with an image-capable model, which makes availability a property of
//! the installed CLI version and the configured model — and makes verification
//! permanent rather than a phase: imagegen_verify.zig has to confirm a file
//! exists at the requested path, is newer than this call, changed if it already
//! existed, clears a size floor, and carries a real container signature. No
//! branch returns success with a check skipped.
//!
//! Concurrency: one call makes one image, synchronously, fully verified. N
//! images means N subagents (graff's existing fan-out), each calling this once
//! — rather than a job queue in here that would put the per-image proof back at
//! arm's length from the agent that has to report it.

const std = @import("std");
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
const skills = @import("skills.zig");
const skill = @import("imagegen_skill.zig");
const verify = @import("imagegen_verify.zig");
const run_mod = @import("imagegen_run.zig");
const codex = @import("imagegen_codex.zig");
const openai = @import("imagegen_openai.zig");
const sips = @import("imagegen_sips.zig");
const select = @import("imagegen_select.zig");
pub const Engine = select.Engine;

pub const tool_name = "imagegen";
pub const tool_desc = "Generate an image from a text prompt and write it to one file under the working directory. Two engines: by default (engine auto) it drives the hosted image_gen tool through your logged-in codex CLI, which needs NO API key; the fallback engine openai_api runs the Codex imagegen skill's bundled scripts/image_gen.py (model gpt-image-2) and does need OPENAI_API_KEY, but it is the only engine that applies the model, quality, background and output_format options. graff copied that skill into ~/.harness/skills/imagegen - load it with the skill tool for prompting guidance; it refers to this tool as $imagegen (a provider tool name cannot contain a dollar sign, so it is plain imagegen here). Every result is freshness-verified by graff itself and never by the generator: the call only succeeds once the file is proven to exist, to be newer than the call, to clear a size floor and to carry a real image signature, so never report an image this tool did not hand you a verified path for. One call makes one image; for multiple images spawn one subagent per image (each calls imagegen once and reports its verified path back) so the generations run concurrently.";
pub const tool_schema =
    \\{"type": "object", "properties": {"prompt": {"type": "string", "description": "What to draw. Be specific about subject, style, composition and background; the imagegen skill's references/prompting.md is worth loading first."}, "out": {"type": "string", "description": "Output file path, relative to the working directory. Default: a fresh, collision-proof imagegen-<nonce>.png in the working directory."}, "engine": {"type": "string", "enum": ["auto", "codex", "openai_api"], "description": "Which generator to use. auto (default) prefers codex - the hosted image_gen tool via your logged-in codex CLI, no API key needed - and falls back to the OPENAI_API_KEY CLI. The options below marked openai_api-only select that engine."}, "size": {"type": "string", "description": "Pixel size, e.g. 1024x1024 or 1024x1536. Both engines support it (the codex engine generates at native size and graff resizes the result itself)."}, "model": {"type": "string", "description": "openai_api-only. Image model; default gpt-image-2, or gpt-image-1.5 for true model-native transparency."}, "quality": {"type": "string", "description": "openai_api-only. low, medium (default) or high."}, "background": {"type": "string", "description": "openai_api-only. transparent or opaque."}, "output_format": {"type": "string", "description": "openai_api-only. png, jpeg or webp. The codex engine always produces png."}}, "required": ["prompt"]}
;

/// Set once at startup by `detect`, then read by every catalog assembly and by
/// dispatch. Process-global for the same reason the #330 gate is: subagents,
/// workflow workers and judges all run in-process, so one flag covers the whole
/// agent tree with nothing per-agent to forget to inherit.
pub var available: bool = false;
/// Directory the mirrored (or, if the mirror failed, the original) skill lives
/// in — reported at startup, and where the fallback engine's script comes from.
pub var skill_dir: []const u8 = "";
/// `image_gen.py` for the openai_api engine.
pub var script_path: []const u8 = "";
/// OPENAI_API_KEY was set in graff's environment at startup. Captured there
/// because that is where the environment map lives; graff never mutates its own
/// environment, so this cannot go stale mid-session.
pub var api_key_present: bool = false;
/// A `codex` binary is on PATH and $CODEX_HOME/auth.json exists.
pub var codex_ready: bool = false;
/// $CODEX_HOME/generated_images — where graff goes looking for the artifact.
pub var save_root: []const u8 = "";
/// Parent for the private empty cwd each codex run gets.
pub var scratch_root: []const u8 = "/tmp";

/// Everything `detect` needs from the environment, by value rather than as a
/// map, so a test can drive it with plain strings.
pub const Env = struct {
    codex_home: ?[]const u8 = null,
    home: ?[]const u8 = null,
    openai_api_key: ?[]const u8 = null,
    tmp_dir: ?[]const u8 = null,
};

/// Find the Codex skill, mirror it, work out which engines this machine can
/// actually run, and decide whether the tool exists this session. Called once
/// at startup, before the skill scan and before any tool catalog is rendered.
pub fn detect(io: Io, arena: Allocator, env: Env) void {
    available = false;
    script_path = "";
    skill_dir = "";
    save_root = "";
    codex_ready = false;
    api_key_present = if (env.openai_api_key) |value| value.len > 0 else false;
    if (env.tmp_dir) |t| if (t.len > 0) {
        scratch_root = std.mem.trimEnd(u8, t, "/");
    };

    const src = skill.codexSkillDir(arena, env.codex_home, env.home) orelse return;
    if (!skill.present(io, arena, src)) return; // no Codex skill -> no tool

    // Prefer the mirrored copy: it is the one `skill imagegen` loads, so tool
    // and playbook stay the same version. A failed mirror (read-only HOME, a
    // half-copied tree) must not cost us the tool — fall back to Codex's own.
    if (skill.installDir(arena, env.home)) |dest| {
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
    detectCodex(io, arena, env);
    available = true;
}

/// The codex engine needs the CLI itself AND a login: `codex exec` without an
/// auth.json only ever produces an interactive login prompt, which in a tool
/// call is an unkillable hang rather than an error.
fn detectCodex(io: Io, arena: Allocator, env: Env) void {
    const codex_home = skill.codexHomeDir(arena, env.codex_home, env.home) orelse return;
    const auth = std.fmt.allocPrint(arena, "{s}/auth.json", .{codex_home}) catch return;
    _ = Io.Dir.cwd().statFile(io, auth, .{}) catch return;
    if (!skills.binOnPath(io, "codex")) return;
    save_root = std.fmt.allocPrint(arena, "{s}/{s}", .{ codex_home, codex.save_root_rel }) catch return;
    codex_ready = true;
}

/// Which engines this session can actually run, for the startup line. A
/// detected tool with no usable engine says so up front rather than waiting
/// for the model to discover it mid-turn.
pub fn engineSummary() []const u8 {
    if (codex_ready and api_key_present) return "codex + openai_api";
    if (codex_ready) return "codex engine";
    if (api_key_present) return "openai_api engine";
    return "NO usable engine: needs `codex login` or OPENAI_API_KEY";
}

fn engineScript(io: Io, arena: Allocator, dir: []const u8) ?[]const u8 {
    const path = std.fmt.allocPrint(arena, "{s}/scripts/image_gen.py", .{dir}) catch return null;
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    if (st.kind != .file) return null;
    return path;
}

fn errText(gpa: Allocator, text: []const u8) !ToolOutput {
    return .{ .text = try gpa.dupe(u8, text), .is_error = true };
}

/// Runs on a pool thread. Every failure is an is_error result; there is no
/// branch that returns success without the full verification passing.
pub fn execImagegen(ctx: ToolCtx, input: Value) !ToolOutput {
    const gpa = ctx.gpa;
    const io = ctx.io;
    // Layer 2 of the gate: refuse a name a provider hallucinated from an
    // earlier session even though it was never advertised here.
    if (!available) return errText(gpa, select.no_skill_text);

    const prompt = strField(input, "prompt") orelse return missingArg(gpa, "prompt");
    if (std.mem.trim(u8, prompt, " \t\r\n").len == 0)
        return errText(gpa, "prompt must not be empty — describe the image to generate");

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args: openai.Args = .{ .prompt = prompt, .out = "" };
    inline for (.{ "model", "size", "quality", "background", "output_format" }) |field| {
        if (strField(input, field)) |value| {
            if (!openai.okFlagValue(value)) return .{
                .text = try std.fmt.allocPrint(gpa, "invalid {s} value '{s}' — letters, digits, dot, dash and underscore only (e.g. size 1024x1024, quality high, model gpt-image-1.5)", .{ field, value }),
                .is_error = true,
            };
            if (comptime std.mem.eql(u8, field, "model")) args.model = value else @field(args, field) = value;
        }
    }
    // parseEngine maps both "auto" and garbage to null, so the name is checked
    // first — an unrecognised engine must be an error, not a silent auto.
    const requested: ?Engine = if (strField(input, "engine")) |name| blk: {
        if (!select.knownEngineName(name)) return .{
            .text = try std.fmt.allocPrint(gpa, "unknown engine '{s}' — use auto, codex or openai_api", .{name}),
            .is_error = true,
        };
        break :blk select.parseEngine(name);
    } else null;
    const tuned = select.firstTunedParam(input);
    const engine = switch (select.choose(requested, codex_ready, api_key_present and script_path.len > 0, tuned != null)) {
        .use => |e| e,
        .refuse => |reason| return .{ .text = try select.refusalText(gpa, reason, tuned), .is_error = true },
    };

    const explicit_format: ?verify.Format = if (args.output_format) |name|
        verify.Format.fromName(name) orelse return .{
            .text = try std.fmt.allocPrint(gpa, "unsupported output_format '{s}' — use png, jpeg or webp", .{name}),
            .is_error = true,
        }
    else
        null;
    // The hosted image_gen tool has no size parameter, so for that engine graff
    // resizes afterwards — which means the value has to be one sips accepts.
    const resize_to: ?sips.Size = if (engine == .codex) blk: {
        const text = args.size orelse break :blk null;
        break :blk sips.parseSize(text) orelse return .{
            .text = try std.fmt.allocPrint(gpa, "the codex engine generates at native size and graff resizes with sips, which needs a concrete <width>x<height> — '{s}' is not one. Use e.g. 1024x1024, or pass engine \"openai_api\" (which accepts auto).", .{text}),
            .is_error = true,
        };
    } else null;

    const out_rel = if (strField(input, "out")) |p|
        p
    else
        defaultOutPath(io, arena, ctx.agent_cwd, if (explicit_format) |f| f.label() else "png") catch
            return errText(gpa, "could not pick an unused default output path — pass out explicitly");
    if (!confinedPath(out_rel) or !noSymlinkEscape(io, out_rel, ctx.agent_cwd)) return outsideCwd(gpa, out_rel);
    // #276 P0-1: a worktree-isolated agent writes inside its own worktree.
    const resolved: []const u8 = if (ctx.agent_cwd) |base|
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, out_rel })
    else
        out_rel;
    args.out = resolved;

    const before = verify.snapshot(io, resolved);
    // Taken BEFORE the spawn: anything a generator produces must be at least
    // this new, and a file older than this is by definition not from this run.
    const started_ns = Io.Timestamp.now(io, .real).nanoseconds;

    const produced: verify.Format = switch (engine) {
        .codex => switch (try runCodex(gpa, arena, io, prompt, resolved, started_ns)) {
            .ok => |f| f,
            .fail => |out| return out,
        },
        .openai_api => switch (try runOpenai(gpa, arena, io, ctx.agent_cwd, args)) {
            .ok => explicit_format orelse verify.Format.fromPath(out_rel),
            .fail => |out| return out,
        },
    };

    // Same verification for both engines, on the file the caller will open.
    var head_buf: [16]u8 = undefined;
    const after: ?verify.Snapshot = blk: {
        const shot = verify.snapshot(io, resolved);
        break :blk if (shot.existed) shot else null;
    };
    const verdict = verify.evaluate(before, after, started_ns, headBytes(io, resolved, &head_buf), produced);
    if (verdict != .ok) return .{
        .text = try std.fmt.allocPrint(
            gpa,
            "imagegen could NOT verify a freshly generated image and is therefore reporting failure, even though the {s} engine reported success.\nfailed check: {s}\nwhat that means: {s}\npath: {s}\nDo not claim an image was produced, and do not substitute another file for it.",
            .{ @tagName(engine), verdict.failedCheck(), verdict.detail(), out_rel },
        ),
        .is_error = true,
    };

    // Resize last, on the already-verified copy, with graff's own hands (#352:
    // leaving the resize to the model is how a stale file became "64x64").
    var note: []const u8 = "";
    if (resize_to) |size| if (!sips.resize(arena, io, resolved, size)) {
        note = if (sips.available)
            " — WARNING: the requested resize failed, so this is the native-size image"
        else
            " — note: native size (the codex engine cannot request a size, and sips resizing is macOS-only)";
    };
    const measured = sips.dims(arena, io, resolved);
    const final = verify.snapshot(io, resolved);
    return .{ .text = try std.fmt.allocPrint(
        gpa,
        "generated and verified: {s} ({d} bytes, {s}{s}, engine {s}){s}. Checks passed: the file exists, its mtime is newer than this call, its size is above the {d}-byte floor, and its leading bytes match the {s} signature.",
        .{
            out_rel,
            final.size,
            produced.label(),
            if (measured) |m| try std.fmt.allocPrint(arena, ", {d}x{d} px", .{ m.w, m.h }) else "",
            @tagName(engine),
            note,
            verify.min_bytes,
            produced.label(),
        },
    ) };
}

const EngineResult = union(enum) { ok: verify.Format, fail: ToolOutput };

/// The codex engine: spawn, then do every piece of artifact handling ourselves.
fn runCodex(gpa: Allocator, arena: Allocator, io: Io, prompt: []const u8, resolved: []const u8, started_ns: i128) !EngineResult {
    if (save_root.len == 0) return .{ .fail = try errText(gpa, select.no_skill_text) };
    // A private empty cwd: --sandbox workspace-write makes the working
    // directory writable, and an image generation has no business being able
    // to write into the repo it was called from.
    const scratch = makeScratch(io, arena) orelse
        return .{ .fail = try errText(gpa, "could not create a private scratch directory for the codex engine — set TMPDIR to a writable location, or pass engine \"openai_api\". Nothing was generated.") };
    defer Io.Dir.cwd().deleteTree(io, scratch) catch {};

    const argv = try codex.buildArgv(arena, try codex.buildPrompt(arena, prompt));
    const out = run_mod.run(arena, io, argv, codex.deadline_ms, scratch) catch |err| switch (err) {
        error.FileNotFound => return .{ .fail = try errText(gpa, "the codex CLI is no longer on PATH, so the preferred imagegen engine cannot run. Reinstall it (bun install -g @openai/codex) or pass engine \"openai_api\". Nothing was generated.") },
        else => return .{ .fail = tools.failure(gpa, err) },
    };
    const tails = try std.fmt.allocPrint(arena, "{s}\n{s}", .{ run_mod.tail(out.stdout, 900), run_mod.tail(out.stderr, 900) });

    if (out.cancelled) return .{ .fail = .{ .text = try gpa.dupe(u8, "imagegen was cancelled — nothing was generated"), .is_error = true, .cancelled = true } };
    if (out.timed_out) return .{ .fail = .{
        .text = try std.fmt.allocPrint(gpa, "the codex engine timed out after {d}s and was killed — nothing verified was produced.\ntranscript tail:\n{s}", .{ codex.deadline_ms / 1000, tails }),
        .is_error = true,
    } };
    if (codex.tooOld(out.stdout) or codex.tooOld(out.stderr)) return .{ .fail = try errText(gpa, codex.too_old_text) };
    if (codex.saidUnavailable(out.stdout)) return .{ .fail = try errText(gpa, codex.unavailable_text) };
    if (!out.ranClean()) return .{ .fail = .{
        .text = try std.fmt.allocPrint(gpa, "codex exec failed (exit {?d}) — nothing was generated.\ntranscript tail:\n{s}", .{ out.exit_code, tails }),
        .is_error = true,
    } };

    // Exit 0 proves nothing — #352 WAS exit 0, with a confident transcript.
    // The artifact on disk is the only evidence that counts.
    const floor = codex.freshnessFloor(started_ns);
    const art = codex.newestFresh(io, arena, save_root, floor) orelse return .{ .fail = .{
        .text = try std.fmt.allocPrint(gpa, "{s}\ntranscript tail:\n{s}", .{ codex.no_artifact_text, tails }),
        .is_error = true,
    } };

    var head_buf: [16]u8 = undefined;
    const head = headBytes(io, art.path, &head_buf);
    const produced = verify.Format.detect(head) orelse return .{ .fail = .{
        .text = try std.fmt.allocPrint(gpa, "codex left a fresh file at {s} but its leading bytes are not a PNG, JPEG or WebP, so it is not an image. Nothing usable was generated.", .{art.path}),
        .is_error = true,
    } };
    const verdict = verify.evaluate(.{}, .{ .existed = true, .size = art.size, .mtime_ns = art.mtime_ns }, floor, head, produced);
    if (verdict != .ok) return .{ .fail = .{
        .text = try std.fmt.allocPrint(gpa, "the file codex produced failed verification.\nfailed check: {s}\nwhat that means: {s}\nartifact: {s}", .{ verdict.failedCheck(), verdict.detail(), art.path }),
        .is_error = true,
    } };

    Io.Dir.cwd().copyFile(art.path, Io.Dir.cwd(), resolved, io, .{ .make_path = true }) catch |err| return .{ .fail = .{
        .text = try std.fmt.allocPrint(gpa, "codex generated a verified image at {s} but graff could not copy it to {s}: {t}", .{ art.path, resolved, err }),
        .is_error = true,
    } };
    return .{ .ok = produced };
}

/// The fallback engine: the CLI writes the output path itself.
fn runOpenai(gpa: Allocator, arena: Allocator, io: Io, agent_cwd: ?[]const u8, args: openai.Args) !EngineResult {
    const argv = try openai.buildArgv(arena, script_path, args);
    const out = run_mod.run(arena, io, argv, openai.deadline_ms, agent_cwd) catch |err| switch (err) {
        error.FileNotFound => return .{ .fail = try errText(gpa, openai.no_python_text) },
        else => return .{ .fail = tools.failure(gpa, err) },
    };
    const err_tail = run_mod.tail(out.stderr, 1600);
    if (out.cancelled) return .{ .fail = .{ .text = try gpa.dupe(u8, "imagegen was cancelled — nothing was generated"), .is_error = true, .cancelled = true } };
    if (out.timed_out) return .{ .fail = .{
        .text = try std.fmt.allocPrint(gpa, "imagegen timed out after {d}s and the generator was killed — nothing verified was produced. Retry, or try a smaller size or lower quality.\nstderr tail:\n{s}", .{ openai.deadline_ms / 1000, err_tail }),
        .is_error = true,
    } };
    if (!out.ranClean()) return .{ .fail = .{
        .text = try std.fmt.allocPrint(gpa, "imagegen failed: image_gen.py exited {?d}. Nothing was generated — do not report an image.\nstderr tail:\n{s}", .{ out.exit_code, err_tail }),
        .is_error = true,
    } };
    return .{ .ok = .png }; // the caller substitutes the requested container
}

fn makeScratch(io: Io, arena: Allocator) ?[]const u8 {
    var buf: [nonce_len]u8 = undefined;
    const path = std.fmt.allocPrint(arena, "{s}/graff-imagegen-{s}", .{ scratch_root, makeNonce(io, &buf) }) catch return null;
    Io.Dir.cwd().createDirPath(io, path) catch return null;
    return path;
}

fn headBytes(io: Io, path: []const u8, buf: []u8) []const u8 {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return &.{};
    defer file.close(io);
    const n = file.readPositionalAll(io, buf, 0) catch return &.{};
    return buf[0..n];
}

/// Distinguishes concurrent default output paths and scratch directories. Two
/// subagents generating into the same cwd in the same second is the normal case
/// for the fan-out pattern this tool documents, so a timestamp is not enough:
/// 80 bits of CSPRNG entropy separates processes, and the process-lifetime
/// counter separates same-process callers even if the RNG were to repeat.
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

    const saved = .{ available, script_path, skill_dir, api_key_present, codex_ready, save_root };
    defer {
        available = saved[0];
        script_path = saved[1];
        skill_dir = saved[2];
        api_key_present = saved[3];
        codex_ready = saved[4];
        save_root = saved[5];
    }

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = real_buf[0..try tmp.dir.realPath(io, &real_buf)];
    const codex_home = try std.fmt.allocPrint(arena, "{s}/codex", .{base});
    const home = try std.fmt.allocPrint(arena, "{s}/home", .{base});

    // A CODEX_HOME with no skill in it: the tool does not exist.
    try Io.Dir.cwd().createDirPath(io, codex_home);
    detect(io, arena, .{ .codex_home = codex_home, .home = home });
    try testing.expect(!available);
    try testing.expectEqualStrings("", script_path);
    try testing.expect(!api_key_present and !codex_ready);

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

    detect(io, arena, .{ .codex_home = codex_home, .home = home, .openai_api_key = "sk-test" });
    try testing.expect(available and api_key_present);
    // No auth.json in this fake CODEX_HOME, so the codex engine is not offered
    // however the real CLI happens to be installed on the test machine.
    try testing.expect(!codex_ready);

    const dest = try std.fmt.allocPrint(arena, "{s}/{s}", .{ home, skill.install_rel });
    try testing.expectEqualStrings(dest, skill_dir);
    const license = try Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/LICENSE.txt", .{dest}), arena, .limited(4096));
    try testing.expectEqualStrings("LICENSE BODY", license);
    const md = try Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/SKILL.md", .{dest}), arena, .limited(1 << 16));
    try testing.expect(std.mem.indexOf(u8, md, "<!-- graff addendum -->") != null);
    try testing.expect(std.mem.indexOf(u8, md, "one subagent per") != null);
    try testing.expect(std.mem.indexOf(u8, md, "use image_gen") != null); // original body kept

    // An empty key is not a key.
    detect(io, arena, .{ .codex_home = codex_home, .home = home, .openai_api_key = "" });
    try testing.expect(available and !api_key_present);
}

test "#352: with no usable engine the tool refuses up front and spawns nothing" {
    const gpa = testing.allocator;
    const saved = .{ available, script_path, api_key_present, codex_ready };
    defer {
        available = saved[0];
        script_path = saved[1];
        api_key_present = saved[2];
        codex_ready = saved[3];
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

    available = false;
    const off = try execImagegen(ctx, parsed.value);
    defer gpa.free(off.text);
    try testing.expect(off.is_error and std.mem.indexOf(u8, off.text, "CODEX_HOME") != null);

    // Detected, but neither engine usable: the refusal names both requirements.
    available = true;
    codex_ready = false;
    api_key_present = false;
    script_path = "/nonexistent/image_gen.py";
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

test {
    _ = skill;
    _ = verify;
    _ = select;
    _ = codex;
    _ = openai;
    _ = sips;
    _ = run_mod;
}
