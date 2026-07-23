//! Shared primary-baseline execution and verification.
//!
//! A parent is evaluated once, then every concurrent child response must copy
//! that immutable parent projection exactly. The ordinary paired evaluator is
//! retained for the single winner's holdout.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const eval = @import("learn_eval.zig");
const store_mod = @import("learn_store.zig");

const baseline_path = "baseline.json";

fn validateRequestedPairs(actual: []const eval.PairRequest, expected: []const eval.PairRequest) !void {
    if (actual.len != expected.len) return error.PairMismatch;
    for (actual, expected) |got, want| {
        if (!std.mem.eql(u8, got.case_id, want.case_id) or
            !std.mem.eql(u8, eval.statisticalUnitId(got), eval.statisticalUnitId(want)) or
            !std.mem.eql(u8, got.seed, want.seed) or got.critical != want.critical) return error.PairMismatch;
    }
}

fn validateBaselineEnvelope(
    request: eval.PrimaryBaselineRequest,
    response: eval.PrimaryBaselineResponse,
    trial_id: []const u8,
    cohort_id: []const u8,
    suite: store_mod.Suite,
    parent_id: []const u8,
    repetitions: usize,
) !void {
    if (!std.mem.eql(u8, request.schema, eval.primary_baseline_request_schema) or
        !std.mem.eql(u8, request.trial_id, trial_id) or
        !std.mem.eql(u8, request.cohort_id, cohort_id) or
        !std.mem.eql(u8, request.suite_sha256, suite.sha256) or
        !std.mem.eql(u8, request.suite_path, "suite.json") or
        !std.mem.eql(u8, request.parent.id, parent_id) or
        !std.mem.eql(u8, request.parent.path, "parent.genome") or
        request.repetitions != repetitions) return error.InvalidBaselineRequest;
    if (!std.mem.eql(u8, response.schema, eval.primary_baseline_response_schema) or
        !std.mem.eql(u8, response.trial_id, trial_id) or
        !std.mem.eql(u8, response.cohort_id, cohort_id) or
        !std.mem.eql(u8, response.suite_sha256, suite.sha256) or
        !std.mem.eql(u8, response.parent_id, parent_id)) return error.InvalidBaselineResponse;
}

fn validateBaselinePairs(response: eval.PrimaryBaselineResponse, requested: []const eval.PairRequest) !void {
    if (response.pairs.len != requested.len) return error.MissingPair;
    for (response.pairs, requested) |result, pair| {
        if (!std.mem.eql(u8, result.case_id, pair.case_id) or !std.mem.eql(u8, result.seed, pair.seed)) return error.PairMismatch;
        if (result.score_ppm > 1_000_000) return error.InvalidScore;
        if (result.behavior_score_ppm > 1_000_000) return error.InvalidScore;
        if (!result.behavior_measured and result.behavior_score_ppm != 0) return error.InvalidMetric;
        if (result.cost_micros > eval.js_exact_max or result.latency_ms > eval.js_exact_max or result.tool_calls > eval.js_exact_max) return error.InvalidMetric;
    }
}

fn validatePrimaryEnvelope(
    request: eval.PrimaryEvaluationRequest,
    response: eval.PrimaryEvaluationResponse,
    baseline: eval.PrimaryBaselineRecord,
    trial_id: []const u8,
    candidate_index: usize,
    cohort_id: []const u8,
    suite: store_mod.Suite,
    parent_id: []const u8,
    child_id: []const u8,
    repetitions: usize,
) !void {
    if (!std.mem.eql(u8, request.schema, eval.primary_evaluation_request_schema) or
        !std.mem.eql(u8, request.trial_id, trial_id) or request.candidate_index != candidate_index or
        !std.mem.eql(u8, request.cohort_id, cohort_id) or
        !std.mem.eql(u8, request.suite_sha256, suite.sha256) or
        !std.mem.eql(u8, request.suite_path, "suite.json") or
        !std.mem.eql(u8, request.parent_id, parent_id) or
        !std.mem.eql(u8, request.baseline.request_evidence_id, baseline.request_evidence_id) or
        !std.mem.eql(u8, request.baseline.response_evidence_id, baseline.response_evidence_id) or
        !std.mem.eql(u8, request.baseline.path, baseline_path) or
        !std.mem.eql(u8, request.child.id, child_id) or
        !std.mem.eql(u8, request.child.path, "child.genome") or
        request.repetitions != repetitions) return error.InvalidPrimaryRequest;
    if (!std.mem.eql(u8, response.schema, eval.primary_evaluation_response_schema) or
        !std.mem.eql(u8, response.trial_id, trial_id) or response.candidate_index != candidate_index or
        !std.mem.eql(u8, response.cohort_id, cohort_id) or
        !std.mem.eql(u8, response.suite_sha256, suite.sha256) or
        !std.mem.eql(u8, response.parent_id, parent_id) or
        !std.mem.eql(u8, response.child_id, child_id)) return error.InvalidPrimaryResponse;
}

fn validateParentProjection(baseline: eval.PrimaryBaselineResponse, response: eval.PrimaryEvaluationResponse) !void {
    if (response.pairs.len != baseline.pairs.len) return error.MissingPair;
    for (response.pairs, baseline.pairs) |pair, parent| {
        if (!std.mem.eql(u8, pair.case_id, parent.case_id) or
            !std.mem.eql(u8, pair.seed, parent.seed) or
            pair.parent_pass != parent.pass or
            pair.parent_score_ppm != parent.score_ppm or
            pair.parent_cost_micros != parent.cost_micros or
            pair.parent_latency_ms != parent.latency_ms or
            pair.latency_measured != parent.latency_measured or
            pair.parent_tool_calls != parent.tool_calls or
            pair.tool_calls_measured != parent.tool_calls_measured or
            pair.parent_behavior_score_ppm != parent.behavior_score_ppm or
            pair.behavior_measured != parent.behavior_measured) return error.BaselineProjectionMismatch;
    }
}

pub fn evaluateBaseline(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    parent_env: *const std.process.Environ.Map,
    store: *store_mod.Store,
    config: store_mod.Config,
    config_id: []const u8,
    harness_version: []const u8,
    trial_id: []const u8,
    parent_id: []const u8,
    parent_prompt: []const u8,
    suite: store_mod.Suite,
    repetitions: usize,
) !eval.PrimaryBaselineRecord {
    const loaded_suite = try store_mod.loadSuite(io, arena, suite);
    const pairs = try eval.buildPairs(gpa, trial_id, suite, loaded_suite.manifest, 0, repetitions);
    defer eval.freePairs(gpa, pairs);
    const cohort = eval.cohortId(config_id, suite.sha256, harness_version);

    var scratch = try eval.createScratch(io, store);
    defer store.tmp.deleteTree(io, &scratch.name) catch {};
    defer scratch.dir.close(io);
    try scratch.dir.createDir(io, "home", eval.dir_permissions);
    try scratch.dir.createDir(io, "tmp", eval.dir_permissions);
    try eval.writePrivate(io, scratch.dir, "parent.genome", parent_prompt);
    try eval.writePrivate(io, scratch.dir, "suite.json", loaded_suite.bytes);

    const request: eval.PrimaryBaselineRequest = .{
        .schema = eval.primary_baseline_request_schema,
        .trial_id = trial_id,
        .cohort_id = &cohort,
        .suite_sha256 = suite.sha256,
        .suite_path = "suite.json",
        .parent = .{ .id = parent_id, .path = "parent.genome" },
        .repetitions = repetitions,
        .pairs = pairs,
    };
    const request_bytes = try store_mod.jsonBytes(gpa, request);
    defer gpa.free(request_bytes);
    if (request_bytes.len > config.limits.request_bytes) return error.RequestTooLarge;
    const request_id = try store.writeEvidence(gpa, request_bytes);
    try eval.writePrivate(io, scratch.dir, "request.json", request_bytes);

    try eval.invokeEvaluator(gpa, io, parent_env, scratch.dir, config.evaluator, "baseline", config.limits.stdout_bytes, config.limits.stderr_bytes, config.limits.evaluator_timeout_ms);
    const response_bytes = try store_mod.readFileNoFollow(io, scratch.dir, "response.json", gpa, config.limits.response_bytes);
    defer gpa.free(response_bytes);
    const response = try std.json.parseFromSliceLeaky(eval.PrimaryBaselineResponse, arena, response_bytes, .{});
    try validateBaselineEnvelope(request, response, trial_id, &cohort, suite, parent_id, repetitions);
    try validateBaselinePairs(response, pairs);
    const response_id = try store.writeEvidence(gpa, response_bytes);
    return .{
        .suite_sha256 = try arena.dupe(u8, suite.sha256),
        .request_evidence_id = try arena.dupe(u8, &request_id),
        .response_evidence_id = try arena.dupe(u8, &response_id),
    };
}

pub fn evaluateCandidate(
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
    child_id: []const u8,
    child_prompt: []const u8,
    suite: store_mod.Suite,
    repetitions: usize,
    planned_candidates: usize,
    baseline_record: eval.PrimaryBaselineRecord,
) !eval.ComparisonRecord {
    if (!std.mem.eql(u8, baseline_record.suite_sha256, suite.sha256)) return error.BaselineSuiteMismatch;
    const loaded_suite = try store_mod.loadSuite(io, arena, suite);
    const pairs = try eval.buildPairs(gpa, trial_id, suite, loaded_suite.manifest, candidate_index, repetitions);
    defer eval.freePairs(gpa, pairs);
    const cohort = eval.cohortId(config_id, suite.sha256, harness_version);
    const baseline_bytes = try store.readEvidence(arena, baseline_record.response_evidence_id, config.limits.response_bytes);
    const baseline = try std.json.parseFromSliceLeaky(eval.PrimaryBaselineResponse, arena, baseline_bytes, .{});
    try validateBaselinePairs(baseline, pairs);

    var scratch = try eval.createScratch(io, store);
    defer store.tmp.deleteTree(io, &scratch.name) catch {};
    defer scratch.dir.close(io);
    try scratch.dir.createDir(io, "home", eval.dir_permissions);
    try scratch.dir.createDir(io, "tmp", eval.dir_permissions);
    try eval.writePrivate(io, scratch.dir, "child.genome", child_prompt);
    try eval.writePrivate(io, scratch.dir, "suite.json", loaded_suite.bytes);
    try eval.writePrivate(io, scratch.dir, baseline_path, baseline_bytes);

    const request: eval.PrimaryEvaluationRequest = .{
        .schema = eval.primary_evaluation_request_schema,
        .trial_id = trial_id,
        .candidate_index = candidate_index,
        .cohort_id = &cohort,
        .suite_sha256 = suite.sha256,
        .suite_path = "suite.json",
        .parent_id = parent_id,
        .baseline = .{
            .request_evidence_id = baseline_record.request_evidence_id,
            .response_evidence_id = baseline_record.response_evidence_id,
            .path = baseline_path,
        },
        .child = .{ .id = child_id, .path = "child.genome" },
        .repetitions = repetitions,
        .pairs = pairs,
    };
    const request_bytes = try store_mod.jsonBytes(gpa, request);
    defer gpa.free(request_bytes);
    if (request_bytes.len > config.limits.request_bytes) return error.RequestTooLarge;
    const request_id = try store.writeEvidence(gpa, request_bytes);
    try eval.writePrivate(io, scratch.dir, "request.json", request_bytes);

    try eval.invokeEvaluator(gpa, io, parent_env, scratch.dir, config.evaluator, "evaluate_primary", config.limits.stdout_bytes, config.limits.stderr_bytes, config.limits.evaluator_timeout_ms);
    const response_bytes = try store_mod.readFileNoFollow(io, scratch.dir, "response.json", gpa, config.limits.response_bytes);
    defer gpa.free(response_bytes);
    const response = try std.json.parseFromSliceLeaky(eval.PrimaryEvaluationResponse, arena, response_bytes, .{});
    try validatePrimaryEnvelope(request, response, baseline_record, trial_id, candidate_index, &cohort, suite, parent_id, child_id, repetitions);
    try validateParentProjection(baseline, response);
    const response_id = try store.writeEvidence(gpa, response_bytes);
    var comparison = try eval.computeComparison(config, suite.sha256, &request_id, &response_id, pairs, .{
        .schema = eval.evaluation_response_schema,
        .trial_id = response.trial_id,
        .candidate_index = response.candidate_index,
        .cohort_id = response.cohort_id,
        .suite_sha256 = response.suite_sha256,
        .parent_id = response.parent_id,
        .child_id = response.child_id,
        .pairs = response.pairs,
    }, planned_candidates);
    comparison.request_evidence_id = try arena.dupe(u8, &request_id);
    comparison.response_evidence_id = try arena.dupe(u8, &response_id);
    return comparison;
}

pub fn verifyBaseline(
    arena: Allocator,
    io: Io,
    store: *store_mod.Store,
    config: store_mod.Config,
    config_id: []const u8,
    harness_version: []const u8,
    trial_id: []const u8,
    parent_id: []const u8,
    suite: store_mod.Suite,
    repetitions: usize,
    record: eval.PrimaryBaselineRecord,
) !eval.PrimaryBaselineResponse {
    if (!std.mem.eql(u8, record.suite_sha256, suite.sha256)) return error.BaselineSuiteMismatch;
    const loaded_suite = try store_mod.loadSuite(io, arena, suite);
    const expected = try eval.buildPairs(arena, trial_id, suite, loaded_suite.manifest, 0, repetitions);
    const request_bytes = try store.readEvidence(arena, record.request_evidence_id, config.limits.request_bytes);
    const response_bytes = try store.readEvidence(arena, record.response_evidence_id, config.limits.response_bytes);
    const request = try std.json.parseFromSliceLeaky(eval.PrimaryBaselineRequest, arena, request_bytes, .{});
    const response = try std.json.parseFromSliceLeaky(eval.PrimaryBaselineResponse, arena, response_bytes, .{});
    const cohort = eval.cohortId(config_id, suite.sha256, harness_version);
    try validateBaselineEnvelope(request, response, trial_id, &cohort, suite, parent_id, repetitions);
    try validateRequestedPairs(request.pairs, expected);
    try validateBaselinePairs(response, request.pairs);
    return response;
}

pub fn verifyCandidate(
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
    baseline_record: eval.PrimaryBaselineRecord,
    baseline: eval.PrimaryBaselineResponse,
    recorded: eval.ComparisonRecord,
) !eval.ComparisonRecord {
    if (!std.mem.eql(u8, recorded.suite_sha256, suite.sha256)) return error.ComparisonMismatch;
    const loaded_suite = try store_mod.loadSuite(io, arena, suite);
    const expected = try eval.buildPairs(arena, trial_id, suite, loaded_suite.manifest, candidate_index, repetitions);
    const request_bytes = try store.readEvidence(arena, recorded.request_evidence_id, config.limits.request_bytes);
    const response_bytes = try store.readEvidence(arena, recorded.response_evidence_id, config.limits.response_bytes);
    const request = try std.json.parseFromSliceLeaky(eval.PrimaryEvaluationRequest, arena, request_bytes, .{});
    const response = try std.json.parseFromSliceLeaky(eval.PrimaryEvaluationResponse, arena, response_bytes, .{});
    const cohort = eval.cohortId(config_id, suite.sha256, harness_version);
    try validatePrimaryEnvelope(request, response, baseline_record, trial_id, candidate_index, &cohort, suite, parent_id, child_id, repetitions);
    try validateRequestedPairs(request.pairs, expected);
    try validateParentProjection(baseline, response);
    const recomputed = try eval.computeComparison(config, suite.sha256, recorded.request_evidence_id, recorded.response_evidence_id, request.pairs, .{
        .schema = eval.evaluation_response_schema,
        .trial_id = response.trial_id,
        .candidate_index = response.candidate_index,
        .cohort_id = response.cohort_id,
        .suite_sha256 = response.suite_sha256,
        .parent_id = response.parent_id,
        .child_id = response.child_id,
        .pairs = response.pairs,
    }, planned_candidates);
    if (!eval.comparisonEqual(recomputed, recorded)) return error.ComparisonMismatch;
    return recomputed;
}
