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

pub const mutation_request_schema = "codegraff.learn.mutation.request.v1";
pub const mutation_response_schema = "codegraff.learn.mutation.response.v1";
pub const evaluation_request_schema = "codegraff.learn.evaluation.request.v1";
pub const evaluation_response_schema = "codegraff.learn.evaluation.response.v1";
pub const run_schema = "codegraff.learn.run.v1";

const file_permissions: Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
const executable_permissions: Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o700);
const dir_permissions: Io.File.Permissions = if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
const js_exact_max: u64 = 9_007_199_254_740_991;

pub const GenomeRef = struct {
    id: []const u8,
    path: []const u8,
};

pub const MutationRequest = struct {
    schema: []const u8,
    trial_id: []const u8,
    candidate_index: usize,
    seed: []const u8,
    parent: GenomeRef,
    child_path: []const u8,
    maximum_bytes: usize,
    instruction: []const u8,
};

pub const MutationResponse = struct {
    schema: []const u8,
    trial_id: []const u8,
    candidate_index: usize,
    parent_id: []const u8,
    child_path: []const u8,
    child_sha256: []const u8,
    description: []const u8 = "",
};

pub const PairRequest = struct {
    case_id: []const u8,
    seed: []const u8,
    critical: bool,
};

pub const EvaluationRequest = struct {
    schema: []const u8,
    trial_id: []const u8,
    candidate_index: usize,
    cohort_id: []const u8,
    suite_sha256: []const u8,
    suite_path: []const u8,
    parent: GenomeRef,
    child: GenomeRef,
    repetitions: usize,
    pairs: []const PairRequest,
};

pub const PairResult = struct {
    case_id: []const u8,
    seed: []const u8,
    parent_pass: bool,
    child_pass: bool,
    parent_score_ppm: u32,
    child_score_ppm: u32,
    parent_cost_micros: u64 = 0,
    child_cost_micros: u64 = 0,
    parent_latency_ms: u64 = 0,
    child_latency_ms: u64 = 0,
};

pub const EvaluationResponse = struct {
    schema: []const u8,
    trial_id: []const u8,
    candidate_index: usize,
    cohort_id: []const u8,
    suite_sha256: []const u8,
    parent_id: []const u8,
    child_id: []const u8,
    pairs: []const PairResult,
};

pub const MutationRecord = struct {
    seed: []const u8,
    request_evidence_id: []const u8,
    response_evidence_id: []const u8,
};

pub const ComparisonRecord = struct {
    suite_sha256: []const u8,
    request_evidence_id: []const u8,
    response_evidence_id: []const u8,
    pairs: usize,
    statistical_units: usize,
    parent_passes: usize,
    child_passes: usize,
    wins: usize,
    losses: usize,
    ties: usize,
    critical_regressions: usize,
    delta_ppm: i64,
    mean_score_delta_ppm: i64,
    p_value_ppb: u64,
    parent_cost_micros: u64,
    child_cost_micros: u64,
    eligible: bool,
    reason: []const u8,
};

pub const CandidateRecord = struct {
    genome_id: []const u8,
    mutation: MutationRecord,
    primary: ?ComparisonRecord,
    holdout: ?ComparisonRecord,
    eligible: bool,
    reason: []const u8,
};

pub const RunRecord = struct {
    schema: []const u8,
    trial_id: []const u8,
    nonce: []const u8,
    created_unix_ms: i64,
    harness_version: []const u8,
    config_id: []const u8,
    parent_genome_id: []const u8,
    parent_generation: u64,
    parent_transaction_id: []const u8,
    planned_candidates: usize,
    repetitions: usize,
    auto_requested: bool,
    candidates: []const CandidateRecord,
    selected_genome_id: ?[]const u8,
};

pub const MutationOutcome = struct {
    genome_id: [64]u8,
    prompt: []u8,
    record: MutationRecord,
};

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

pub fn pairSeed(trial_id: []const u8, suite_sha256: []const u8, candidate_index: usize, case_id: []const u8, repetition: usize) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("codegraff-learn/pair-seed/v1");
    hash.update(&.{0});
    for ([_][]const u8{ trial_id, suite_sha256, case_id }) |field| {
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, len[0..], @intCast(field.len), .big);
        hash.update(&len);
        hash.update(field);
    }
    var ints: [16]u8 = undefined;
    std.mem.writeInt(u64, ints[0..8], @intCast(candidate_index), .big);
    std.mem.writeInt(u64, ints[8..16], @intCast(repetition), .big);
    hash.update(&ints);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn createScratch(io: Io, store: *store_mod.Store) !struct { name: [32]u8, dir: Io.Dir } {
    var attempts: usize = 0;
    while (attempts < 16) : (attempts += 1) {
        var raw: [16]u8 = undefined;
        io.randomSecure(&raw) catch io.random(&raw);
        const name = std.fmt.bytesToHex(raw, .lower);
        store.tmp.createDir(io, &name, dir_permissions) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        const dir = try store.tmp.openDir(io, &name, .{ .iterate = true, .follow_symlinks = false });
        if (builtin.os.tag != .windows) try dir.setPermissions(io, dir_permissions);
        return .{ .name = name, .dir = dir };
    }
    return error.ScratchNameCollision;
}

fn writePrivateWithPermissions(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8, permissions: Io.File.Permissions) !void {
    const file = try dir.createFile(io, name, .{ .exclusive = true, .permissions = permissions });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
}

fn writePrivate(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
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

fn invoke(
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
    if (run.timed_out) return error.ProcessTimedOut;
    if (run.term != .exited or run.term.exited != 0) return error.ProcessFailed;
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
        },
    };
}

fn buildPairs(gpa: Allocator, trial_id: []const u8, suite: store_mod.Suite, manifest: store_mod.SuiteManifest, candidate_index: usize, repetitions: usize) ![]PairRequest {
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
            const seed = pairSeed(trial_id, suite.sha256, candidate_index, case.id, repetition);
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

fn freePairs(gpa: Allocator, pairs: []PairRequest) void {
    for (pairs) |pair| gpa.free(pair.seed);
    gpa.free(pairs);
}

/// Exact one-sided paired-binomial tail, evaluated stably from the first tail
/// term. A value at or below `alpha / planned_candidates` is significant.
pub fn pairedTail(wins: usize, losses: usize) f64 {
    const n = wins + losses;
    if (n == 0 or wins * 2 <= n) return 1.0;
    const nf: f64 = @floatFromInt(n);
    const wf: f64 = @floatFromInt(wins);
    const lf: f64 = @floatFromInt(n - wins);
    const log_term = std.math.lgamma(f64, nf + 1.0) - std.math.lgamma(f64, wf + 1.0) - std.math.lgamma(f64, lf + 1.0) - nf * @log(2.0);
    var term = @exp(log_term);
    var total = term;
    var k = wins;
    while (k < n) : (k += 1) {
        term *= @as(f64, @floatFromInt(n - k)) / @as(f64, @floatFromInt(k + 1));
        total += term;
    }
    return @min(1.0, total);
}

fn toPpb(p: f64) u64 {
    if (p >= 1.0) return 1_000_000_000;
    if (p <= 0.0) return 0;
    return @intFromFloat(@ceil(p * 1_000_000_000.0));
}

fn checkedMetricAdd(a: u64, b: u64) !u64 {
    const sum = std.math.add(u64, a, b) catch return error.InvalidMetric;
    if (sum > js_exact_max) return error.InvalidMetric;
    return sum;
}

fn computeComparison(config: store_mod.Config, suite_sha256: []const u8, request_id: []const u8, response_id: []const u8, requested: []const PairRequest, response: EvaluationResponse, planned_candidates: usize) !ComparisonRecord {
    if (response.pairs.len != requested.len) return error.MissingPair;
    var parent_passes: usize = 0;
    var child_passes: usize = 0;
    var statistical_units: usize = 0;
    var wins: usize = 0;
    var losses: usize = 0;
    var critical_regressions: usize = 0;
    var score_delta: i128 = 0;
    var parent_cost: u64 = 0;
    var child_cost: u64 = 0;
    for (response.pairs, requested) |result, pair| {
        if (!std.mem.eql(u8, result.case_id, pair.case_id) or !std.mem.eql(u8, result.seed, pair.seed)) return error.PairMismatch;
        if (result.parent_score_ppm > 1_000_000 or result.child_score_ppm > 1_000_000) return error.InvalidScore;
        if (result.parent_cost_micros > js_exact_max or result.child_cost_micros > js_exact_max or result.parent_latency_ms > js_exact_max or result.child_latency_ms > js_exact_max) return error.InvalidMetric;
        if (result.parent_pass) parent_passes += 1;
        if (result.child_pass) child_passes += 1;
        if (result.parent_pass and !result.child_pass and pair.critical) critical_regressions += 1;
        score_delta += @as(i128, result.child_score_ppm) - @as(i128, result.parent_score_ppm);
        parent_cost = try checkedMetricAdd(parent_cost, result.parent_cost_micros);
        child_cost = try checkedMetricAdd(child_cost, result.child_cost_micros);
    }

    // Repetitions are repeated measurements of one case, not independent
    // statistical samples. Collapse each unique case to one sign-test unit by
    // comparing its aggregate parent/child pass counts across repetitions.
    for (requested, 0..) |pair, index| {
        var seen = false;
        for (requested[0..index]) |prior| {
            if (std.mem.eql(u8, prior.case_id, pair.case_id)) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        statistical_units += 1;
        var parent_case_passes: usize = 0;
        var child_case_passes: usize = 0;
        for (response.pairs, requested) |result, grouped_pair| {
            if (!std.mem.eql(u8, grouped_pair.case_id, pair.case_id)) continue;
            if (result.parent_pass) parent_case_passes += 1;
            if (result.child_pass) child_case_passes += 1;
        }
        if (child_case_passes > parent_case_passes) wins += 1;
        if (parent_case_passes > child_case_passes) losses += 1;
    }

    const pair_count = requested.len;
    const pass_delta: i128 = @as(i128, @intCast(child_passes)) - @as(i128, @intCast(parent_passes));
    const delta_ppm: i64 = @intCast(@divTrunc(pass_delta * 1_000_000, @as(i128, @intCast(pair_count))));
    const mean_score_delta: i64 = @intCast(@divTrunc(score_delta, @as(i128, @intCast(pair_count))));
    const p = pairedTail(wins, losses);
    const alpha: f64 = @as(f64, @floatFromInt(config.gate.alpha_ppm)) / 1_000_000.0;
    const significant = p * @as(f64, @floatFromInt(planned_candidates)) <= alpha;

    var eligible = true;
    var reason: []const u8 = "eligible";
    if (critical_regressions > 0) {
        eligible = false;
        reason = "critical_regression";
    } else if (statistical_units < config.gate.minimum_pairs) {
        eligible = false;
        reason = "minimum_pairs";
    } else if (delta_ppm < config.gate.minimum_delta_ppm) {
        eligible = false;
        reason = "minimum_delta";
    } else if (!significant) {
        eligible = false;
        reason = "not_significant";
    }
    return .{
        .suite_sha256 = suite_sha256,
        .request_evidence_id = request_id,
        .response_evidence_id = response_id,
        .pairs = pair_count,
        .statistical_units = statistical_units,
        .parent_passes = parent_passes,
        .child_passes = child_passes,
        .wins = wins,
        .losses = losses,
        .ties = statistical_units - wins - losses,
        .critical_regressions = critical_regressions,
        .delta_ppm = delta_ppm,
        .mean_score_delta_ppm = mean_score_delta,
        .p_value_ppb = toPpb(p),
        .parent_cost_micros = parent_cost,
        .child_cost_micros = child_cost,
        .eligible = eligible,
        .reason = reason,
    };
}

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

    try invoke(gpa, io, parent_env, scratch_created.dir, config.evaluator, "evaluate", config.limits.stdout_bytes, config.limits.stderr_bytes, config.limits.evaluator_timeout_ms);
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

fn comparisonEqual(a: ComparisonRecord, b: ComparisonRecord) bool {
    return std.mem.eql(u8, a.suite_sha256, b.suite_sha256) and
        std.mem.eql(u8, a.request_evidence_id, b.request_evidence_id) and
        std.mem.eql(u8, a.response_evidence_id, b.response_evidence_id) and
        a.pairs == b.pairs and a.statistical_units == b.statistical_units and
        a.parent_passes == b.parent_passes and a.child_passes == b.child_passes and
        a.wins == b.wins and a.losses == b.losses and a.ties == b.ties and a.critical_regressions == b.critical_regressions and
        a.delta_ppm == b.delta_ppm and a.mean_score_delta_ppm == b.mean_score_delta_ppm and a.p_value_ppb == b.p_value_ppb and
        a.parent_cost_micros == b.parent_cost_micros and a.child_cost_micros == b.child_cost_micros and
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
    if (!std.mem.eql(u8, run.schema, run_schema) or !store_mod.validId(run.trial_id) or !store_mod.validId(run.nonce) or !store_mod.validId(run.config_id) or !store_mod.validId(run.parent_genome_id) or !store_mod.validId(run.parent_transaction_id)) return error.InvalidRun;
    if (run.planned_candidates == 0 or run.planned_candidates > 16 or run.candidates.len != run.planned_candidates) return error.InvalidRun;
    if (run.repetitions == 0 or run.repetitions > 100 or run.harness_version.len == 0 or run.harness_version.len > 128) return error.InvalidRun;
    if (run.selected_genome_id) |id| if (!store_mod.validId(id)) return error.InvalidRun;
    for (run.candidates) |candidate| {
        if (!store_mod.validId(candidate.genome_id) or !store_mod.validId(candidate.mutation.seed) or !store_mod.validId(candidate.mutation.request_evidence_id) or !store_mod.validId(candidate.mutation.response_evidence_id)) return error.InvalidRun;
        if (candidate.eligible and candidate.primary == null) return error.InvalidRun;
    }
}

test "paired tail has known exact values" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), pairedTail(1, 0), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0546875), pairedTail(8, 2), 1e-12);
    try std.testing.expectEqual(@as(f64, 1.0), pairedTail(2, 2));
}

test "paired gate rejects critical regressions and requires corrected significance" {
    const config: store_mod.Config = .{
        .schema = store_mod.config_schema,
        .agent_name = "test",
        .mutation_instruction = "change",
        .mutator = .{ .program = "/bin/a", .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
        .evaluator = .{ .program = "/bin/b", .sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
        .evaluation_suite = .{ .path = "/suite", .sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" },
        .gate = .{ .alpha_ppm = 50_000, .minimum_delta_ppm = 0, .minimum_pairs = 1 },
        .cohort = .{ .provider = "p", .model = "m", .task_family = "t", .adapter_version = "a", .verifier_version = "v" },
    };
    const case_ids = [_][]const u8{ "case-0", "case-1", "case-2", "case-3", "case-4", "case-5", "case-6", "case-7", "case-8", "case-9" };
    var requested: [10]PairRequest = undefined;
    var results: [10]PairResult = undefined;
    for (0..10) |i| {
        requested[i] = .{ .case_id = case_ids[i], .seed = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .critical = i == 0 };
        results[i] = .{ .case_id = requested[i].case_id, .seed = requested[i].seed, .parent_pass = false, .child_pass = true, .parent_score_ppm = 0, .child_score_ppm = 1_000_000 };
    }
    const response: EvaluationResponse = .{ .schema = evaluation_response_schema, .trial_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .candidate_index = 0, .cohort_id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .suite_sha256 = config.evaluation_suite.sha256, .parent_id = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", .child_id = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", .pairs = &results };
    const comparison = try computeComparison(config, config.evaluation_suite.sha256, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "1111111111111111111111111111111111111111111111111111111111111111", &requested, response, 1);
    try std.testing.expect(comparison.eligible);
    try std.testing.expectEqual(@as(usize, 10), comparison.statistical_units);

    results[0].parent_cost_micros = js_exact_max;
    results[1].parent_cost_micros = 1;
    try std.testing.expectError(error.InvalidMetric, computeComparison(config, config.evaluation_suite.sha256, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "1111111111111111111111111111111111111111111111111111111111111111", &requested, response, 1));
    results[0].parent_cost_micros = 0;
    results[1].parent_cost_micros = 0;

    for (0..10) |i| {
        requested[i].case_id = "repeated-case";
        results[i].case_id = "repeated-case";
    }
    const repeated = try computeComparison(config, config.evaluation_suite.sha256, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "1111111111111111111111111111111111111111111111111111111111111111", &requested, response, 1);
    try std.testing.expect(!repeated.eligible);
    try std.testing.expectEqual(@as(usize, 1), repeated.statistical_units);
    try std.testing.expectEqualStrings("not_significant", repeated.reason);

    results[0].parent_pass = true;
    results[0].child_pass = false;
    const critical = try computeComparison(config, config.evaluation_suite.sha256, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "1111111111111111111111111111111111111111111111111111111111111111", &requested, response, 1);
    try std.testing.expect(!critical.eligible);
    try std.testing.expectEqualStrings("critical_regression", critical.reason);
}

test "tool invocation executes verified private program and input snapshots" {
    if (builtin.os.tag == .windows) return;
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writePrivateWithPermissions(io, tmp.dir, "tool.sh",
        \\#!/bin/sh
        \\set -eu
        \\[ "$0" != "$ORIGINAL_PROGRAM" ]
        \\[ "$1" != "$ORIGINAL_INPUT" ]
        \\[ "$1" = "$GRAFF_LEARN_INPUT_0" ]
        \\[ "$GRAFF_LEARN_INPUT_COUNT" = "1" ]
        \\[ "$(cat "$1")" = "pinned-data" ]
        \\printf 'snapshot-ok' > "$4"
        \\
    , executable_permissions);
    try writePrivate(io, tmp.dir, "input.txt", "pinned-data\n");

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];
    const program_path = try std.fmt.allocPrint(allocator, "{s}{c}tool.sh", .{ root, std.fs.path.sep });
    defer allocator.free(program_path);
    const input_path = try std.fmt.allocPrint(allocator, "{s}{c}input.txt", .{ root, std.fs.path.sep });
    defer allocator.free(input_path);
    const program_bytes = try store_mod.readFileNoFollow(io, tmp.dir, "tool.sh", allocator, 4096);
    defer allocator.free(program_bytes);
    const input_bytes = try store_mod.readFileNoFollow(io, tmp.dir, "input.txt", allocator, 4096);
    defer allocator.free(input_bytes);
    const program_hash = store_mod.rawSha256(program_bytes);
    const input_hash = store_mod.rawSha256(input_bytes);

    var store = try store_mod.Store.initAt(io, tmp.dir);
    defer store.deinit();
    var scratch_created = try createScratch(io, &store);
    defer store.tmp.deleteTree(io, &scratch_created.name) catch {};
    defer scratch_created.dir.close(io);
    try scratch_created.dir.createDir(io, "home", dir_permissions);
    try scratch_created.dir.createDir(io, "tmp", dir_permissions);

    var parent_env = std.process.Environ.Map.init(allocator);
    defer parent_env.deinit();
    try parent_env.put("ORIGINAL_PROGRAM", program_path);
    try parent_env.put("ORIGINAL_INPUT", input_path);
    const inputs = [_]store_mod.PinnedFile{.{ .path = input_path, .sha256 = &input_hash }};
    const args = [_][]const u8{input_path};
    const pass_env = [_][]const u8{ "ORIGINAL_PROGRAM", "ORIGINAL_INPUT" };
    const program: store_mod.Program = .{
        .program = program_path,
        .sha256 = &program_hash,
        .args = &args,
        .inputs = &inputs,
        .pass_env = &pass_env,
    };
    try invoke(allocator, io, &parent_env, scratch_created.dir, program, "test", 1024, 1024, 10_000);
    const response = try store_mod.readFileNoFollow(io, scratch_created.dir, "response.json", allocator, 1024);
    defer allocator.free(response);
    try std.testing.expectEqualStrings("snapshot-ok", response);
}
