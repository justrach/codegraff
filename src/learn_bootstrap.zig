//! Zero-configuration `graff learn init`.
//!
//! The learning engine only accepts a fully pinned configuration: absolute
//! adapter paths, SHA-256 pins, an evaluation suite, and an independent
//! holdout. Writing that by hand is why the engine shipped without ever
//! running anywhere. This module produces the whole thing from the running
//! binary: it materializes the embedded adapter kit into `.graff/learn-kit`,
//! generates a fresh primary/holdout suite pair, snapshots the parent genome
//! from this build's root prompt, and emits the pinned configuration that
//! `learn init` then bootstraps.
//!
//! Everything it writes stays inside the workspace and stays local; the
//! generated configuration turns automatic promotion on, because a loop that
//! needs a human to type `promote` is not a loop.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const assets = @import("learn_assets.zig");
const store_mod = @import("learn_store.zig");
const prompts = @import("prompts.zig");
const jobs = @import("jobs.zig");
const util = @import("util.zig");

const dir_permissions: Io.File.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
const file_permissions: Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);

pub const kit_dir_name = "learn-kit";
pub const kit_path = ".graff/" ++ kit_dir_name;
const active_ref_path = ".graff/learn/refs/active.json";
/// The agent name a learned genome must carry to become this workspace's root
/// policy. Any other name stays an ordinary learned subagent persona.
pub const root_policy_agent = "graff-root";
pub const parent_file = "parent.md";
pub const config_file = "config.json";
pub const primary_file = "primary.json";
pub const holdout_file = "holdout.json";
pub const arms_file = "arms.json";
pub const evaluator_settings_file = "evaluator.json";
pub const binary_file = "graff-pinned";

pub const Options = struct {
    provider: []const u8,
    model: []const u8,
    /// Whether this provider/model honors a reasoning-effort pin. When it does
    /// not, the adapters must not claim one: an unpinnable effort recorded in
    /// the cohort would describe a comparison that never happened.
    pin_effort: bool = false,
    candidates: usize = 2,
    repetitions: usize = 1,
};

pub const Prepared = struct {
    kit: []const u8,
    parent: []const u8,
    config: []const u8,
    provider: []const u8,
    model: []const u8,
    candidates: usize,
};

/// Anchors are matched against this build's root prompt; the first one that
/// occurs exactly once becomes the mutation target. Ordering is deliberate:
/// the last sentence is the safest place to accumulate learned clauses, and
/// the alternates only matter if a future prompt drops it.
const anchor_candidates = [_][]const u8{
    "Be direct and concise.",
    "Work directly for small sequential steps.",
    "Use todo_write to\ntrack multi-step work.",
};

/// Invariants a mutation must never disturb. The kit ships the superset; only
/// the ones actually present in the parent genome are configured, so a prompt
/// edit upstream cannot wedge every future trial.
const protected_candidates = [_][]const u8{
    "Do not claim a relaunch is required.",
    "never in the current working repository's issue tracker.",
    "do NOT override GIT_AUTHOR_*/GIT_COMMITTER_*",
    "Co-Authored-By: Codegraff <blackfloofie@codegraff.com>",
    "`reset --hard`, `clean -f`",
};

const arm_focus = [_][]const u8{
    "Tool economy: reach the same verified outcome with fewer redundant reads, repeated searches, and post-success verification calls.",
    "Exactness: preserve exact bytes and terminal-newline state on every edit, and prefer the smallest edit that satisfies the request.",
    "Parallelism: batch independent lookups into one response instead of serializing round trips that have no dependency between them.",
    "Stop conditions: treat an exact successful edit or command as complete, and re-read only after reported staleness, ambiguity, or failure.",
    "Discovery: choose the structural navigation tool for symbol/caller questions and reserve broad text scans for genuinely unknown phrasing.",
    "Reporting: state what was verified and what was not, without restating the plan or re-listing files already summarized.",
};

const arm_effort = [_][]const u8{ "high", "medium" };

fn writePrivateFile(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
    dir.deleteFile(io, name) catch {};
    const file = try dir.createFile(io, name, .{ .exclusive = true, .permissions = file_permissions });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
}

/// Write source bytes into `name`. Fallback when the filesystem cannot
/// hardlink (cross-device, or a host that does not support links).
fn copyExecutableBytes(io: Io, source: Io.File, size: u64, dir: Io.Dir, name: []const u8) !void {
    const dest = try dir.createFile(io, name, .{ .exclusive = true, .permissions = file_permissions });
    defer dest.close(io);
    var buffer: [64 << 10]u8 = undefined;
    var offset: u64 = 0;
    while (offset < size) {
        const want: usize = @intCast(@min(@as(u64, buffer.len), size - offset));
        const got = try source.readPositionalAll(io, buffer[0..want], offset);
        if (got != want) return error.UnexpectedEndOfFile;
        try dest.writeStreamingAll(io, buffer[0..got]);
        offset += got;
    }
    try dest.sync(io);
}

/// Pin the running executable into the kit. Prefer a hardlink: same inode,
/// O(1), and `graff update` replacing the live path leaves this pin (and its
/// SHA) intact. Do not chmod the dest — that would also chmod the live exe.
/// Copy only when the filesystem cannot hardlink.
fn pinExecutable(io: Io, source_path: []const u8, dir: Io.Dir, name: []const u8) !void {
    const source = try Io.Dir.openFileAbsolute(io, source_path, .{});
    defer source.close(io);
    const stat = try source.stat(io);
    if (stat.kind != .file) return error.NotRegularFile;
    if (stat.size > store_mod.max_program_bytes) return error.FileTooBig;
    dir.deleteFile(io, name) catch {};
    source.hardLink(io, dir, name, .{}) catch {
        try copyExecutableBytes(io, source, stat.size, dir, name);
    };
}

fn joinPath(arena: Allocator, root: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{c}{s}", .{ root, std.fs.path.sep, name });
}

fn pinFor(io: Io, arena: Allocator, root: []const u8, name: []const u8) !store_mod.PinnedFile {
    const path = try joinPath(arena, root, name);
    const digest = try store_mod.hashFileNoFollow(io, path);
    return .{ .path = path, .sha256 = try arena.dupe(u8, &digest) };
}

pub fn selectAnchor(parent: []const u8) ![]const u8 {
    for (anchor_candidates) |candidate| {
        if (std.mem.indexOf(u8, parent, candidate) == null) continue;
        if (std.mem.count(u8, parent, candidate) != 1) continue;
        return candidate;
    }
    return error.NoMutationAnchor;
}

pub fn selectProtected(arena: Allocator, parent: []const u8, anchor: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    // The anchor is itself an invariant: the adapter rejects a clause that
    // changes a protected substring's count, and a clause that reproduced the
    // anchor would leave the next generation with an ambiguous target.
    try list.append(arena, anchor);
    for (protected_candidates) |candidate| {
        if (std.mem.indexOf(u8, parent, candidate) == null) continue;
        try list.append(arena, candidate);
    }
    if (list.items.len < 2) return error.NoProtectedInvariants;
    return list.items;
}

const Arm = struct {
    index: usize,
    id: []const u8,
    provider: []const u8,
    model: []const u8,
    effort: ?[]const u8,
    target: []const u8,
    placement: []const u8,
    focus: []const u8,
};

const ArmsFile = struct {
    schema: []const u8 = "codegraff.learn.graff-arms.v1",
    template_egress: bool = true,
    maximum_changed_bytes: usize = 512,
    maximum_total_bytes: usize = 16384,
    protected_substrings: []const []const u8,
    targets: struct { root_workflow: []const u8 },
    arms: []const Arm,
};

const EvaluatorSettings = struct {
    schema: []const u8 = "codegraff.learn.graff-evaluator.v1",
    provider: []const u8,
    model: []const u8,
    effort: ?[]const u8,
    max_model_calls: usize = 8,
    max_tool_calls: usize = 8,
    max_attempts: usize = 2,
    task_timeout_seconds: usize = 120,
};

fn buildArms(arena: Allocator, options: Options, anchor: []const u8, protected: []const []const u8) !ArmsFile {
    const arms = try arena.alloc(Arm, options.candidates);
    for (arms, 0..) |*arm, index| {
        arm.* = .{
            .index = index,
            .id = try std.fmt.allocPrint(arena, "arm-{d}", .{index}),
            .provider = options.provider,
            .model = options.model,
            .effort = if (options.pin_effort) arm_effort[index % arm_effort.len] else null,
            .target = "root_workflow",
            // Appending after a stable anchor keeps every configured invariant
            // byte-identical; a replacement arm could delete one outright.
            .placement = "append",
            .focus = arm_focus[index % arm_focus.len],
        };
    }
    return .{
        .protected_substrings = protected,
        .targets = .{ .root_workflow = anchor },
        .arms = arms,
    };
}

/// `-B` keeps a __pycache__ directory out of the pinned kit: an unpinned file
/// appearing next to pinned ones is noise at best and confusing at worst.
fn pythonArgv(program: []const u8, primary: []const u8, holdout: []const u8) [5][]const u8 {
    return .{ program, "-B", assets.generate_name, primary, holdout };
}

/// Generate the primary suite plus a workspace-unique holdout. The generator
/// is one of the pinned kit files and runs in the kit directory so its sibling
/// case catalog imports by name.
fn generateSuites(gpa: Allocator, io: Io, kit: Io.Dir) !void {
    const interpreters = [_][]const u8{ "python3", "/usr/bin/python3", "python" };
    var last_error: ?anyerror = null;
    for (interpreters) |program| {
        const argv = pythonArgv(program, primary_file, holdout_file);
        const run = jobs.runCappedWithOptions(gpa, io, &argv, 8 << 10, 32 << 10, 120_000, .{
            .cwd = .{ .dir = kit },
            .kill_process_tree = true,
        }) catch |err| {
            last_error = err;
            continue;
        };
        defer gpa.free(run.stdout);
        defer gpa.free(run.stderr);
        if (run.timed_out) return error.SuiteGenerationTimedOut;
        if (run.term != .exited or run.term.exited != 0) return error.SuiteGenerationFailed;
        return;
    }
    return last_error orelse error.PythonUnavailable;
}

fn buildConfig(
    arena: Allocator,
    io: Io,
    root: []const u8,
    options: Options,
    arms_pin: store_mod.PinnedFile,
    settings_pin: store_mod.PinnedFile,
    binary_pin: store_mod.PinnedFile,
    pass_env: []const []const u8,
) !store_mod.Config {
    const mutator_pin = try pinFor(io, arena, root, assets.mutator_name);
    const evaluator_pin = try pinFor(io, arena, root, assets.evaluator_name);
    const behavior_pin = try pinFor(io, arena, root, assets.behavior_name);
    const scorer_pin = try pinFor(io, arena, root, assets.scorer_name);
    const case_pin = try pinFor(io, arena, root, assets.case_name);
    const primary_pin = try pinFor(io, arena, root, primary_file);
    const holdout_pin = try pinFor(io, arena, root, holdout_file);

    const mutator_inputs = try arena.dupe(store_mod.PinnedFile, &.{ arms_pin, binary_pin });
    // Input order is protocol: the evaluator reads GRAFF_LEARN_INPUT_2 for the
    // behavioral auditor and GRAFF_LEARN_INPUT_4 for the case helper.
    const evaluator_inputs = try arena.dupe(store_mod.PinnedFile, &.{ settings_pin, binary_pin, behavior_pin, scorer_pin, case_pin });
    const mutator_args = try arena.dupe([]const u8, &.{ arms_pin.path, binary_pin.path });
    const evaluator_args = try arena.dupe([]const u8, &.{ settings_pin.path, binary_pin.path });

    return .{
        .schema = store_mod.config_schema,
        .agent_name = root_policy_agent,
        .agent_description = "learned root coding policy for this workspace",
        .mutation_instruction = "Add one concise behavioral clause that measurably improves task outcomes or tool economy. Preserve every safety, authority, and attribution invariant byte-for-byte.",
        .mutator = .{
            .program = mutator_pin.path,
            .sha256 = mutator_pin.sha256,
            .args = mutator_args,
            .inputs = mutator_inputs,
            .pass_env = pass_env,
        },
        .evaluator = .{
            .program = evaluator_pin.path,
            .sha256 = evaluator_pin.sha256,
            .args = evaluator_args,
            .inputs = evaluator_inputs,
            .pass_env = pass_env,
        },
        .evaluation_suite = .{ .path = primary_pin.path, .sha256 = primary_pin.sha256 },
        .holdout_suite = .{ .path = holdout_pin.path, .sha256 = holdout_pin.sha256 },
        .limits = .{ .mutator_timeout_ms = 600_000, .evaluator_timeout_ms = 3_600_000 },
        .gate = .{
            .minimum_pairs = 40,
            .economy_gate_enabled = true,
            .promotion_mode = .economy,
            .minimum_tool_reduction_ppm = 100_000,
            .minimum_economy_pairs = 10,
            .require_all_candidates = false,
            .default_candidates = options.candidates,
            .default_repetitions = options.repetitions,
        },
        // Two-key automatic promotion: this flag plus an explicit
        // `learn run --auto`, and every statistical gate still has to pass.
        .auto = .{ .enabled = true },
        .cohort = .{
            .provider = options.provider,
            .model = options.model,
            .task_family = "coding-flow",
            .adapter_version = "graff-kit-v1",
            .verifier_version = "behavior-audited-v7",
        },
    };
}

/// Materialize the kit and return the parent/config paths `learn init` needs.
pub fn prepare(gpa: Allocator, arena: Allocator, io: Io, options: Options, pass_env: []const []const u8, out: *Io.Writer) !Prepared {
    if (options.candidates == 0 or options.candidates > 16) return error.InvalidCandidateCount;
    const base = Io.Dir.cwd();
    // Refuse before touching anything. Regenerating the kit under an existing
    // store would rewrite the exact files that store's immutable configuration
    // pins — a fresh holdout alone would fail every later verification.
    if (base.openFile(io, active_ref_path, .{ .follow_symlinks = false })) |file| {
        file.close(io);
        return error.AlreadyInitialized;
    } else |_| {}
    base.createDir(io, ".graff", dir_permissions) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var graff_dir = try base.openDir(io, ".graff", .{ .iterate = true, .follow_symlinks = false });
    defer graff_dir.close(io);
    graff_dir.createDir(io, kit_dir_name, dir_permissions) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var kit = try graff_dir.openDir(io, kit_dir_name, .{ .iterate = true, .follow_symlinks = false });
    defer kit.close(io);
    if (builtin.os.tag != .windows) try kit.setPermissions(io, dir_permissions);

    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_len = try kit.realPath(io, &real_buf);
    const root = try arena.dupe(u8, real_buf[0..real_len]);

    try out.writeAll("writing the learning kit into " ++ kit_path ++ "\n");
    for (assets.kit) |asset| try writePrivateFile(io, kit, asset.name, asset.bytes);

    const exe_path = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe_path);
    try pinExecutable(io, exe_path, kit, binary_file);

    const parent = try std.fmt.allocPrint(arena, "{s}\n", .{prompts.main_system_prompt});
    try writePrivateFile(io, kit, parent_file, parent);
    const anchor = try selectAnchor(parent);
    const protected = try selectProtected(arena, parent, anchor);

    const arms = try buildArms(arena, options, anchor, protected);
    const arms_bytes = try store_mod.jsonBytes(gpa, arms);
    defer gpa.free(arms_bytes);
    try writePrivateFile(io, kit, arms_file, arms_bytes);

    const settings: EvaluatorSettings = .{
        .provider = options.provider,
        .model = options.model,
        // Grading is a judgment call about a finished task, not the task: the
        // cheapest effort the provider offers is the right one.
        .effort = if (options.pin_effort) "low" else null,
    };
    const settings_bytes = try store_mod.jsonBytes(gpa, settings);
    defer gpa.free(settings_bytes);
    try writePrivateFile(io, kit, evaluator_settings_file, settings_bytes);

    try out.writeAll("generating a primary suite and a fresh independent holdout\n");
    try generateSuites(gpa, io, kit);

    const arms_pin = try pinFor(io, arena, root, arms_file);
    const settings_pin = try pinFor(io, arena, root, evaluator_settings_file);
    const binary_pin = try pinFor(io, arena, root, binary_file);
    const config = try buildConfig(arena, io, root, options, arms_pin, settings_pin, binary_pin, pass_env);
    try store_mod.validateConfig(config);
    const config_bytes = try store_mod.jsonBytes(gpa, config);
    defer gpa.free(config_bytes);
    try writePrivateFile(io, kit, config_file, config_bytes);

    return .{
        .kit = root,
        .parent = try joinPath(arena, root, parent_file),
        .config = try joinPath(arena, root, config_file),
        .provider = options.provider,
        .model = options.model,
        .candidates = options.candidates,
    };
}

test "the mutation anchor and protected invariants come from the live root prompt" {
    const parent = prompts.main_system_prompt;
    const anchor = try selectAnchor(parent);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, parent, anchor));

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const protected = try selectProtected(arena_state.allocator(), parent, anchor);
    try std.testing.expect(protected.len >= 4);
    try std.testing.expectEqualStrings(anchor, protected[0]);
    for (protected) |item| try std.testing.expect(std.mem.indexOf(u8, parent, item) != null);
}

test "generated arms stay inside the adapter's validation envelope" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parent = prompts.main_system_prompt;
    const arms = try buildArms(arena, .{
        .provider = "codegraff",
        .model = "deepseek-v4-pro",
        .candidates = 4,
    }, try selectAnchor(parent), try selectProtected(arena, parent, try selectAnchor(parent)));
    try std.testing.expectEqual(@as(usize, 4), arms.arms.len);
    try std.testing.expect(arms.template_egress);
    try std.testing.expect(arms.maximum_changed_bytes >= 64 and arms.maximum_changed_bytes <= 4096);
    try std.testing.expect(arms.maximum_total_bytes >= parent.len);
    for (arms.arms, 0..) |arm, index| {
        try std.testing.expectEqual(index, arm.index);
        try std.testing.expectEqualStrings("root_workflow", arm.target);
        try std.testing.expectEqualStrings("append", arm.placement);
        try std.testing.expect(arm.focus.len > 0);
        try std.testing.expect(arm.effort == null);
        for (arms.arms[0..index]) |prior| try std.testing.expect(!std.mem.eql(u8, prior.id, arm.id));
    }
}

test "a suite generation command names the pinned kit generator" {
    const argv = pythonArgv("python3", primary_file, holdout_file);
    try std.testing.expectEqualStrings("python3", argv[0]);
    try std.testing.expectEqualStrings("-B", argv[1]);
    try std.testing.expectEqualStrings(assets.generate_name, argv[2]);
    try std.testing.expectEqualStrings("primary.json", argv[3]);
    try std.testing.expectEqualStrings("holdout.json", argv[4]);
}

test "pinning the executable hardlinks on the same filesystem instead of copying" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = "graff-pin-fixture";
    {
        const file = try tmp.dir.createFile(io, "src-bin", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, payload);
    }

    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_len = try tmp.dir.realPath(io, &real_buf);
    const root = real_buf[0..real_len];
    const src_path = try std.fmt.allocPrint(std.testing.allocator, "{s}{c}src-bin", .{ root, std.fs.path.sep });
    defer std.testing.allocator.free(src_path);

    try pinExecutable(io, src_path, tmp.dir, binary_file);

    const src = try tmp.dir.openFile(io, "src-bin", .{});
    defer src.close(io);
    const dst = try tmp.dir.openFile(io, binary_file, .{});
    defer dst.close(io);
    const src_stat = try src.stat(io);
    const dst_stat = try dst.stat(io);
    try std.testing.expectEqual(src_stat.size, dst_stat.size);
    if (builtin.os.tag != .windows and src_stat.inode != 0) {
        try std.testing.expectEqual(src_stat.inode, dst_stat.inode);
        try std.testing.expect(dst_stat.nlink >= 2);
    }

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const pin = try pinFor(io, arena_state.allocator(), root, binary_file);
    try std.testing.expectEqual(@as(usize, 64), pin.sha256.len);
}
