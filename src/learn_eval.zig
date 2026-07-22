//! Mutation/evaluation protocols and the trusted paired promotion gate.
//!
//! External tools are pinned and invoked with direct argv, bounded output,
//! bounded response files, a private scratch cwd, and an explicit environment.
//! They still execute with the invoking user's OS privileges: this is hygiene,
//! not a security sandbox.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const jobs = @import("jobs.zig");
const store_mod = @import("learn_store.zig");
const protocol = @import("learn_eval_types.zig");

pub const mutation_request_schema = protocol.mutation_request_schema;
pub const mutation_response_schema = protocol.mutation_response_schema;
pub const evaluation_request_schema = protocol.evaluation_request_schema;
pub const evaluation_response_schema = protocol.evaluation_response_schema;
pub const primary_baseline_request_schema = protocol.primary_baseline_request_schema;
pub const primary_baseline_response_schema = protocol.primary_baseline_response_schema;
pub const primary_evaluation_request_schema = protocol.primary_evaluation_request_schema;
pub const primary_evaluation_response_schema = protocol.primary_evaluation_response_schema;
pub const legacy_run_schema = protocol.legacy_run_schema;
pub const run_schema = protocol.run_schema;
pub const GenomeRef = protocol.GenomeRef;
pub const MutationRequest = protocol.MutationRequest;
pub const MutationResponse = protocol.MutationResponse;
pub const PairRequest = protocol.PairRequest;
pub const EvaluationRequest = protocol.EvaluationRequest;
pub const PairResult = protocol.PairResult;
pub const EvaluationResponse = protocol.EvaluationResponse;
pub const BaselinePairResult = protocol.BaselinePairResult;
pub const PrimaryBaselineRequest = protocol.PrimaryBaselineRequest;
pub const PrimaryBaselineResponse = protocol.PrimaryBaselineResponse;
pub const PrimaryBaselineRecord = protocol.PrimaryBaselineRecord;
pub const PrimaryBaselineRef = protocol.PrimaryBaselineRef;
pub const PrimaryEvaluationRequest = protocol.PrimaryEvaluationRequest;
pub const PrimaryEvaluationResponse = protocol.PrimaryEvaluationResponse;
pub const MutationRecord = protocol.MutationRecord;
pub const ComparisonRecord = protocol.ComparisonRecord;
pub const CandidateRecord = protocol.CandidateRecord;
pub const RunRecord = protocol.RunRecord;
pub const MutationOutcome = protocol.MutationOutcome;

const file_permissions: Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
pub const executable_permissions: Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o700);
pub const dir_permissions: Io.File.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);

pub fn candidateSeed(trial_id: []const u8, candidate_index: usize) [64]u8 {
    var buffer: [96]u8 = undefined;
    const framed = std.fmt.bufPrint(&buffer, "{s}:{d}", .{ trial_id, candidate_index }) catch unreachable;
    return store_mod.domainId("codegraff-learn/candidate-seed/v1", framed);
}

pub fn cohortId(config_id: []const u8, suite_sha256: []const u8, harness_version: []const u8) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("codegraff-learn/cohort/v1");
    hash.update(&.{0});
    for ([_][]const u8{ config_id, suite_sha256, harness_version }) |field| {
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, len[0..], @intCast(field.len), .big);
        hash.update(&len);
        hash.update(field);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn pairSeed(trial_id: []const u8, suite_sha256: []const u8, case_id: []const u8, repetition: usize) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("codegraff-learn/pair-seed/v1");
    hash.update(&.{0});
    for ([_][]const u8{ trial_id, suite_sha256, case_id }) |field| {
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, len[0..], @intCast(field.len), .big);
        hash.update(&len);
        hash.update(field);
    }
    var repetition_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &repetition_bytes, @intCast(repetition), .big);
    hash.update(&repetition_bytes);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn createScratch(io: Io, store: *store_mod.Store) !struct { name: [32]u8, dir: Io.Dir } {
    var attempts: usize = 0;
    while (attempts < 16) : (attempts += 1) {
        var raw: [16]u8 = undefined;
        try io.randomSecure(&raw);
        const name = std.fmt.bytesToHex(raw, .lower);
        store.tmp.createDir(io, &name, dir_permissions) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        // The directory exists from here on: clean it up if the open or the
        // permission tightening fails, instead of leaking it into store.tmp.
        errdefer store.tmp.deleteTree(io, &name) catch {};
        const dir = try store.tmp.openDir(io, &name, .{ .iterate = true, .follow_symlinks = false });
        errdefer dir.close(io);
        if (builtin.os.tag != .windows) try dir.setPermissions(io, dir_permissions);
        return .{ .name = name, .dir = dir };
    }
    return error.ScratchNameCollision;
}

pub fn writePrivateWithPermissions(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8, permissions: Io.File.Permissions) !void {
    const file = try dir.createFile(io, name, .{ .exclusive = true, .permissions = permissions });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
}

pub fn writePrivate(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
    return writePrivateWithPermissions(io, dir, name, bytes, file_permissions);
}

fn buildEnvironment(gpa: Allocator, parent: *const std.process.Environ.Map, program: store_mod.Program, input_paths: []const []const u8, scratch: Io.Dir, io: Io) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(gpa);
    errdefer env.deinit();
    try env.put("PATH", if (builtin.os.tag == .windows) "C:\\Windows\\System32" else "/usr/bin:/bin");
    try env.put("LANG", "C");
    try env.put("LC_ALL", "C");
    try env.put("GRAFF_LEARN_PROTOCOL", "1");

    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_len = try scratch.realPath(io, &real_buf);
    const root = real_buf[0..real_len];
    const home = try std.fmt.allocPrint(gpa, "{s}{c}home", .{ root, std.fs.path.sep });
    defer gpa.free(home);
    const temp = try std.fmt.allocPrint(gpa, "{s}{c}tmp", .{ root, std.fs.path.sep });
    defer gpa.free(temp);
    try env.put("HOME", home);
    try env.put("USERPROFILE", home);
    try env.put("TMPDIR", temp);
    try env.put("TMP", temp);
    try env.put("TEMP", temp);

    var count_buf: [32]u8 = undefined;
    try env.put("GRAFF_LEARN_INPUT_COUNT", try std.fmt.bufPrint(&count_buf, "{d}", .{input_paths.len}));
    for (input_paths, 0..) |path, index| {
        var key_buf: [64]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "GRAFF_LEARN_INPUT_{d}", .{index});
        try env.put(key, path);
    }

    if (builtin.os.tag == .windows) {
        if (parent.get("SystemRoot")) |value| try env.put("SystemRoot", value);
        if (parent.get("ComSpec")) |value| try env.put("ComSpec", value);
    }
    for (program.pass_env) |name| if (parent.get(name)) |value| try env.put(name, value);
    return env;
}

fn snapshotExtension(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    if (extension.len > 16) return "";
    for (extension) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return "";
    return extension;
}

pub fn invoke(
    gpa: Allocator,
    io: Io,
    parent_env: *const std.process.Environ.Map,
    scratch: Io.Dir,
    program: store_mod.Program,
    operation: []const u8,
    stdout_cap: usize,
    stderr_cap: usize,
    timeout_ms: u64,
) !void {
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try scratch.realPath(io, &root_buf);
    const root = root_buf[0..root_len];

    var program_name_buf: [64]u8 = undefined;
    const program_name = try std.fmt.bufPrint(&program_name_buf, "program{s}", .{snapshotExtension(program.program)});
    const program_bytes = try store_mod.readPinnedFileAlloc(io, gpa, .{ .path = program.program, .sha256 = program.sha256 }, store_mod.max_program_bytes);
    defer gpa.free(program_bytes);
    try writePrivateWithPermissions(io, scratch, program_name, program_bytes, executable_permissions);
    const program_path = try std.fmt.allocPrint(gpa, "{s}{c}{s}", .{ root, std.fs.path.sep, program_name });
    defer gpa.free(program_path);

    const input_paths = try gpa.alloc([]const u8, program.inputs.len);
    var initialized_inputs: usize = 0;
    defer {
        for (input_paths[0..initialized_inputs]) |path| gpa.free(path);
        gpa.free(input_paths);
    }
    for (program.inputs, 0..) |input, index| {
        var name_buf: [96]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "input-{d}{s}", .{ index, snapshotExtension(input.path) });
        const bytes = try store_mod.readPinnedFileAlloc(io, gpa, input, store_mod.max_program_bytes);
        defer gpa.free(bytes);
        try writePrivate(io, scratch, name, bytes);
        input_paths[index] = try std.fmt.allocPrint(gpa, "{s}{c}{s}", .{ root, std.fs.path.sep, name });
        initialized_inputs += 1;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, program_path);
    for (program.args) |arg| {
        var effective = arg;
        for (program.inputs, input_paths) |input, snapshot_path| {
            if (std.mem.eql(u8, arg, input.path)) {
                effective = snapshot_path;
                break;
            }
        }
        try argv.append(gpa, effective);
    }
    try argv.appendSlice(gpa, &.{ operation, "request.json", "response.json" });

    var env = try buildEnvironment(gpa, parent_env, program, input_paths, scratch, io);
    defer env.deinit();
    const run = try jobs.runCappedWithOptions(gpa, io, argv.items, stdout_cap, stderr_cap, timeout_ms, .{
        .cwd = .{ .dir = scratch },
        .environ_map = &env,
    });
    defer {
        gpa.free(run.stdout);
        gpa.free(run.stderr);
    }
    if (run.timed_out) {
        std.debug.print("learn: {s} timed out after {d} ms\n", .{ program.program, timeout_ms });
        return error.ProcessTimedOut;
    }
    if (run.term != .exited or run.term.exited != 0) {
        // The bare error alone cost real debugging time: surface which tool
        // failed and a bounded stderr excerpt before the scratch dir (and the
        // request/response evidence in it) is deleted by the caller.
        const excerpt = run.stderr[0..@min(run.stderr.len, 4096)];
        std.debug.print("learn: {s} failed ({any}); stderr (first {d} of {d} bytes):\n{s}\n", .{ program.program, run.term, excerpt.len, run.stderr.len, excerpt });
        return error.ProcessFailed;
    }
}

/// Retry one failed evaluator process in the same private scratch directory.
/// Cooperative adapters can resume from their request-bound case checkpoint,
/// avoiding a second baseline or replay of already completed cases.
pub fn invokeEvaluator(
    gpa: Allocator,
    io: Io,
    parent_env: *const std.process.Environ.Map,
    scratch: Io.Dir,
    program: store_mod.Program,
    operation: []const u8,
    stdout_cap: usize,
    stderr_cap: usize,
    timeout_ms: u64,
) !void {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        invoke(gpa, io, parent_env, scratch, program, operation, stdout_cap, stderr_cap, timeout_ms) catch |err| switch (err) {
            error.ProcessFailed, error.ProcessTimedOut => if (attempt == 0) {
                var program_name_buf: [64]u8 = undefined;
                const program_name = try std.fmt.bufPrint(&program_name_buf, "program{s}", .{snapshotExtension(program.program)});
                try scratch.deleteFile(io, program_name);
                for (program.inputs, 0..) |input, index| {
                    var name_buf: [96]u8 = undefined;
                    const name = try std.fmt.bufPrint(&name_buf, "input-{d}{s}", .{ index, snapshotExtension(input.path) });
                    try scratch.deleteFile(io, name);
                }
                continue;
            } else return err,
            else => return err,
        };
        return;
    }
}

fn validDescription(value: []const u8) bool {
    return value.len <= 512 and std.unicode.utf8ValidateSlice(value) and std.mem.indexOfScalar(u8, value, 0) == null;
}

pub fn mutate(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    parent_env: *const std.process.Environ.Map,
    store: *store_mod.Store,
    config: store_mod.Config,
    trial_id: []const u8,
    candidate_index: usize,
    parent_id: []const u8,
    parent_prompt: []const u8,
) !MutationOutcome {
    if (!store_mod.validId(trial_id) or !store_mod.validId(parent_id)) return error.InvalidId;
    var scratch_created = try createScratch(io, store);
    defer store.tmp.deleteTree(io, &scratch_created.name) catch {};
    defer scratch_created.dir.close(io);
    try scratch_created.dir.createDir(io, "home", dir_permissions);
    try scratch_created.dir.createDir(io, "tmp", dir_permissions);
    try writePrivate(io, scratch_created.dir, "parent.genome", parent_prompt);

    const seed = candidateSeed(trial_id, candidate_index);
    const request: MutationRequest = .{
        .schema = mutation_request_schema,
        .trial_id = trial_id,
        .candidate_index = candidate_index,
        .seed = &seed,
        .parent = .{ .id = parent_id, .path = "parent.genome" },
        .child_path = "child.genome",
        .maximum_bytes = config.limits.genome_bytes,
        .instruction = config.mutation_instruction,
    };
    const request_bytes = try store_mod.jsonBytes(gpa, request);
    defer gpa.free(request_bytes);
    if (request_bytes.len > config.limits.request_bytes) return error.RequestTooLarge;
    const request_id = try store.writeEvidence(gpa, request_bytes);
    try writePrivate(io, scratch_created.dir, "request.json", request_bytes);

    try invoke(gpa, io, parent_env, scratch_created.dir, config.mutator, "mutate", config.limits.stdout_bytes, config.limits.stderr_bytes, config.limits.mutator_timeout_ms);
    const response_bytes = try store_mod.readFileNoFollow(io, scratch_created.dir, "response.json", gpa, config.limits.response_bytes);
    defer gpa.free(response_bytes);
    const response = try std.json.parseFromSliceLeaky(MutationResponse, arena, response_bytes, .{});
    if (!std.mem.eql(u8, response.schema, mutation_response_schema) or
        !std.mem.eql(u8, response.trial_id, trial_id) or
        response.candidate_index != candidate_index or
        !std.mem.eql(u8, response.parent_id, parent_id) or
        !std.mem.eql(u8, response.child_path, "child.genome") or
        !store_mod.validId(response.child_sha256) or
        !validDescription(response.description)) return error.InvalidMutationResponse;

    const prompt = try store_mod.readFileNoFollow(io, scratch_created.dir, "child.genome", gpa, config.limits.genome_bytes);
    errdefer gpa.free(prompt);
    if (std.mem.trim(u8, prompt, " \t\r\n").len == 0 or !std.unicode.utf8ValidateSlice(prompt)) return error.InvalidGenome;
    const child_sha256 = store_mod.rawSha256(prompt);
    if (!std.mem.eql(u8, response.child_sha256, &child_sha256)) return error.MutationOutputMismatch;
    const response_id = try store.writeEvidence(gpa, response_bytes);
    const genome_id = try store.writeGenome(gpa, prompt);
    return .{
        .genome_id = genome_id,
        .prompt = prompt,
        .record = .{
            .seed = try arena.dupe(u8, &seed),
            .request_evidence_id = try arena.dupe(u8, &request_id),
            .response_evidence_id = try arena.dupe(u8, &response_id),
            .description = try arena.dupe(u8, response.description),
            .genome_bytes = prompt.len,
        },
    };
}

pub fn buildPairs(gpa: Allocator, trial_id: []const u8, suite: store_mod.Suite, manifest: store_mod.SuiteManifest, _: usize, repetitions: usize) ![]PairRequest {
    const count = std.math.mul(usize, manifest.cases.len, repetitions) catch return error.TooManyPairs;
    if (count == 0 or count > store_mod.max_pairs) return error.TooManyPairs;
    const pairs = try gpa.alloc(PairRequest, count);
    var initialized: usize = 0;
    errdefer {
        for (pairs[0..initialized]) |pair| gpa.free(pair.seed);
        gpa.free(pairs);
    }
    for (0..repetitions) |repetition| {
        for (manifest.cases) |case| {
            // Common random numbers: every arm receives identical primary
            // seeds for the same case/repetition, so generator identity is the
            // only intended source of between-arm variation.
            const seed = pairSeed(trial_id, suite.sha256, case.id, repetition);
            const seed_copy = try gpa.dupe(u8, &seed);
            pairs[initialized] = .{
                .case_id = case.id,
                .seed = seed_copy,
                .critical = case.critical,
            };
            initialized += 1;
        }
    }
    return pairs;
}

pub fn freePairs(gpa: Allocator, pairs: []PairRequest) void {
    for (pairs) |pair| gpa.free(pair.seed);
    gpa.free(pairs);
}

// Statistics and comparison aggregation live in focused sibling modules.
const learn_stats = @import("learn_stats.zig");
pub const js_exact_max = learn_stats.js_exact_max;
pub const pairedTail = learn_stats.pairedTail;
const comparison_mod = @import("learn_comparison.zig");
pub const computeComparison = comparison_mod.computeComparison;

fn validateEvaluationEnvelope(request: EvaluationRequest, response: EvaluationResponse, trial_id: []const u8, candidate_index: usize, cohort_id: []const u8, suite: store_mod.Suite, parent_id: []const u8, child_id: []const u8, repetitions: usize) !void {
    if (!std.mem.eql(u8, request.schema, evaluation_request_schema) or
        !std.mem.eql(u8, request.trial_id, trial_id) or
        request.candidate_index != candidate_index or
        !std.mem.eql(u8, request.cohort_id, cohort_id) or
        !std.mem.eql(u8, request.suite_sha256, suite.sha256) or
        !std.mem.eql(u8, request.suite_path, "suite.json") or
        !std.mem.eql(u8, request.parent.id, parent_id) or
        !std.mem.eql(u8, request.parent.path, "parent.genome") or
        !std.mem.eql(u8, request.child.id, child_id) or
        !std.mem.eql(u8, request.child.path, "child.genome") or
        request.repetitions != repetitions) return error.InvalidEvaluationRequest;
    if (!std.mem.eql(u8, response.schema, evaluation_response_schema) or
        !std.mem.eql(u8, response.trial_id, trial_id) or
        response.candidate_index != candidate_index or
        !std.mem.eql(u8, response.cohort_id, cohort_id) or
        !std.mem.eql(u8, response.suite_sha256, suite.sha256) or
        !std.mem.eql(u8, response.parent_id, parent_id) or
        !std.mem.eql(u8, response.child_id, child_id)) return error.InvalidEvaluationResponse;
}

pub fn evaluate(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    parent_env: *const std.process.Environ.Map,
    store: *store_mod.Store,
    config: store_mod.Config,
    config_id: []const u8,
    harness_version: []const u8,
    trial_id: []const u8,
    candidate_index: usize,
    parent_id: []const u8,
    parent_prompt: []const u8,
    child_id: []const u8,
    child_prompt: []const u8,
    suite: store_mod.Suite,
    repetitions: usize,
    planned_candidates: usize,
) !ComparisonRecord {
    const loaded_suite = try store_mod.loadSuite(io, arena, suite);
    const pairs = try buildPairs(gpa, trial_id, suite, loaded_suite.manifest, candidate_index, repetitions);
    defer freePairs(gpa, pairs);
    const cohort = cohortId(config_id, suite.sha256, harness_version);

    var scratch_created = try createScratch(io, store);
    defer store.tmp.deleteTree(io, &scratch_created.name) catch {};
    defer scratch_created.dir.close(io);
    try scratch_created.dir.createDir(io, "home", dir_permissions);
    try scratch_created.dir.createDir(io, "tmp", dir_permissions);
    try writePrivate(io, scratch_created.dir, "parent.genome", parent_prompt);
    try writePrivate(io, scratch_created.dir, "child.genome", child_prompt);
    try writePrivate(io, scratch_created.dir, "suite.json", loaded_suite.bytes);

    const request: EvaluationRequest = .{
        .schema = evaluation_request_schema,
        .trial_id = trial_id,
        .candidate_index = candidate_index,
        .cohort_id = &cohort,
        .suite_sha256 = suite.sha256,
        .suite_path = "suite.json",
        .parent = .{ .id = parent_id, .path = "parent.genome" },
        .child = .{ .id = child_id, .path = "child.genome" },
        .repetitions = repetitions,
        .pairs = pairs,
    };
    const request_bytes = try store_mod.jsonBytes(gpa, request);
    defer gpa.free(request_bytes);
    if (request_bytes.len > config.limits.request_bytes) return error.RequestTooLarge;
    const request_id = try store.writeEvidence(gpa, request_bytes);
    try writePrivate(io, scratch_created.dir, "request.json", request_bytes);

    try invokeEvaluator(gpa, io, parent_env, scratch_created.dir, config.evaluator, "evaluate", config.limits.stdout_bytes, config.limits.stderr_bytes, config.limits.evaluator_timeout_ms);
    const response_bytes = try store_mod.readFileNoFollow(io, scratch_created.dir, "response.json", gpa, config.limits.response_bytes);
    defer gpa.free(response_bytes);
    const response = try std.json.parseFromSliceLeaky(EvaluationResponse, arena, response_bytes, .{});
    try validateEvaluationEnvelope(request, response, trial_id, candidate_index, &cohort, suite, parent_id, child_id, repetitions);
    const response_id = try store.writeEvidence(gpa, response_bytes);
    var comparison = try computeComparison(config, suite.sha256, &request_id, &response_id, pairs, response, planned_candidates);
    comparison.request_evidence_id = try arena.dupe(u8, &request_id);
    comparison.response_evidence_id = try arena.dupe(u8, &response_id);
    return comparison;
}

pub fn comparisonEqual(a: ComparisonRecord, b: ComparisonRecord) bool {
    return std.mem.eql(u8, a.suite_sha256, b.suite_sha256) and
        std.mem.eql(u8, a.request_evidence_id, b.request_evidence_id) and
        std.mem.eql(u8, a.response_evidence_id, b.response_evidence_id) and
        a.pairs == b.pairs and a.statistical_units == b.statistical_units and
        a.parent_passes == b.parent_passes and a.child_passes == b.child_passes and
        a.wins == b.wins and a.losses == b.losses and a.ties == b.ties and
        a.child_critical_failures == b.child_critical_failures and a.critical_regressions == b.critical_regressions and
        a.delta_ppm == b.delta_ppm and a.mean_score_delta_ppm == b.mean_score_delta_ppm and a.p_value_ppb == b.p_value_ppb and
        a.parent_cost_micros == b.parent_cost_micros and a.child_cost_micros == b.child_cost_micros and
        a.tool_calls_measured == b.tool_calls_measured and
        a.parent_tool_calls == b.parent_tool_calls and a.child_tool_calls == b.child_tool_calls and
        a.tool_wins == b.tool_wins and a.tool_losses == b.tool_losses and a.tool_ties == b.tool_ties and
        a.tool_delta_ppm == b.tool_delta_ppm and a.tool_p_value_ppb == b.tool_p_value_ppb and
        a.latency_measured == b.latency_measured and a.parent_latency_ms == b.parent_latency_ms and a.child_latency_ms == b.child_latency_ms and
        a.economy_eligible == b.economy_eligible and
        a.eligible == b.eligible and std.mem.eql(u8, a.reason, b.reason);
}

pub fn verifyComparison(
    arena: Allocator,
    io: Io,
    store: *store_mod.Store,
    config: store_mod.Config,
    config_id: []const u8,
    harness_version: []const u8,
    trial_id: []const u8,
    candidate_index: usize,
    parent_id: []const u8,
    child_id: []const u8,
    suite: store_mod.Suite,
    repetitions: usize,
    planned_candidates: usize,
    recorded: ComparisonRecord,
) !ComparisonRecord {
    if (!std.mem.eql(u8, recorded.suite_sha256, suite.sha256)) return error.ComparisonMismatch;
    const loaded_suite = try store_mod.loadSuite(io, arena, suite);
    const expected_pairs = try buildPairs(arena, trial_id, suite, loaded_suite.manifest, candidate_index, repetitions);
    const request_bytes = try store.readEvidence(arena, recorded.request_evidence_id, config.limits.request_bytes);
    const response_bytes = try store.readEvidence(arena, recorded.response_evidence_id, config.limits.response_bytes);
    const request = try std.json.parseFromSliceLeaky(EvaluationRequest, arena, request_bytes, .{});
    const response = try std.json.parseFromSliceLeaky(EvaluationResponse, arena, response_bytes, .{});
    const cohort = cohortId(config_id, suite.sha256, harness_version);
    try validateEvaluationEnvelope(request, response, trial_id, candidate_index, &cohort, suite, parent_id, child_id, repetitions);
    if (request.pairs.len != expected_pairs.len) return error.PairMismatch;
    for (request.pairs, expected_pairs) |actual, expected| {
        if (!std.mem.eql(u8, actual.case_id, expected.case_id) or !std.mem.eql(u8, actual.seed, expected.seed) or actual.critical != expected.critical) return error.PairMismatch;
    }
    const recomputed = try computeComparison(config, suite.sha256, recorded.request_evidence_id, recorded.response_evidence_id, request.pairs, response, planned_candidates);
    if (!comparisonEqual(recomputed, recorded)) return error.ComparisonMismatch;
    return recomputed;
}

pub fn validateRun(run: RunRecord) !void {
    const current = std.mem.eql(u8, run.schema, run_schema);
    const legacy = std.mem.eql(u8, run.schema, legacy_run_schema);
    if ((!current and !legacy) or !store_mod.validId(run.trial_id) or !store_mod.validId(run.nonce) or !store_mod.validId(run.config_id) or !store_mod.validId(run.parent_genome_id) or !store_mod.validId(run.parent_transaction_id)) return error.InvalidRun;
    if (run.planned_candidates == 0 or run.planned_candidates > 16 or run.candidates.len != run.planned_candidates) return error.InvalidRun;
    if (run.repetitions == 0 or run.repetitions > 100 or run.harness_version.len == 0 or run.harness_version.len > 128) return error.InvalidRun;
    if (run.primary_winner_genome_id) |id| if (!store_mod.validId(id)) return error.InvalidRun;
    if (run.selected_genome_id) |id| if (!store_mod.validId(id)) return error.InvalidRun;
    if (current) {
        if (run.primary_baseline) |baseline| {
            if (!store_mod.validId(baseline.suite_sha256) or !store_mod.validId(baseline.request_evidence_id) or !store_mod.validId(baseline.response_evidence_id)) return error.InvalidRun;
        }
    } else if (run.primary_baseline != null) return error.InvalidRun;
    for (run.candidates) |candidate| {
        if (!store_mod.validId(candidate.genome_id) or !store_mod.validId(candidate.mutation.seed) or !store_mod.validId(candidate.mutation.request_evidence_id) or !store_mod.validId(candidate.mutation.response_evidence_id)) return error.InvalidRun;
        if (candidate.eligible and candidate.primary == null) return error.InvalidRun;
    }
}

test {
    _ = @import("learn_eval_tests.zig");
}
