//! Tests for learn_eval.zig (600-line goal). Reached through the
//! `test { _ = ... }` hook in learn_eval.zig.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const learn_eval = @import("learn_eval.zig");
const store_mod = @import("learn_store.zig");

const PairRequest = learn_eval.PairRequest;
const PairResult = learn_eval.PairResult;
const EvaluationRequest = learn_eval.EvaluationRequest;
const EvaluationResponse = learn_eval.EvaluationResponse;
const ComparisonRecord = learn_eval.ComparisonRecord;
const pairedTail = learn_eval.pairedTail;
const computeComparison = learn_eval.computeComparison;
const buildPairs = learn_eval.buildPairs;
const freePairs = learn_eval.freePairs;
const createScratch = learn_eval.createScratch;
const writePrivate = learn_eval.writePrivate;
const invoke = learn_eval.invoke;
const evaluation_response_schema = learn_eval.evaluation_response_schema;
const js_exact_max = learn_eval.js_exact_max;
const writePrivateWithPermissions = learn_eval.writePrivateWithPermissions;
const executable_permissions = learn_eval.executable_permissions;
const dir_permissions = learn_eval.dir_permissions;
const builtin = @import("builtin");

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

    results[0].parent_behavior_score_ppm = 1;
    try std.testing.expectError(error.InvalidMetric, computeComparison(config, config.evaluation_suite.sha256, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "1111111111111111111111111111111111111111111111111111111111111111", &requested, response, 1));
    results[0].behavior_measured = true;
    results[0].parent_behavior_score_ppm = 1_000_001;
    try std.testing.expectError(error.InvalidScore, computeComparison(config, config.evaluation_suite.sha256, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "1111111111111111111111111111111111111111111111111111111111111111", &requested, response, 1));
    results[0].behavior_measured = false;
    results[0].parent_behavior_score_ppm = 0;

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

    results[0].parent_pass = false;
    const jointly_failed_critical = try computeComparison(config, config.evaluation_suite.sha256, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "1111111111111111111111111111111111111111111111111111111111111111", &requested, response, 1);
    try std.testing.expect(!jointly_failed_critical.eligible);
    try std.testing.expectEqual(@as(usize, 1), jointly_failed_critical.child_critical_failures);
    try std.testing.expectEqual(@as(usize, 0), jointly_failed_critical.critical_regressions);
    try std.testing.expectEqualStrings("critical_failure", jointly_failed_critical.reason);
}

test "statistical units group repetitions and cloned case ids once" {
    const config: store_mod.Config = .{
        .schema = store_mod.config_schema,
        .agent_name = "test",
        .mutation_instruction = "change",
        .mutator = .{ .program = "/bin/a", .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
        .evaluator = .{ .program = "/bin/b", .sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
        .evaluation_suite = .{ .path = "/suite", .sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" },
        .gate = .{ .minimum_pairs = 1 },
        .cohort = .{ .provider = "p", .model = "m", .task_family = "t", .adapter_version = "a", .verifier_version = "v" },
    };
    const requested = [_]PairRequest{
        .{ .case_id = "clone-a", .statistical_unit_id = "edit-filter", .seed = "seed-a1", .critical = false },
        .{ .case_id = "clone-a", .statistical_unit_id = "edit-filter", .seed = "seed-a2", .critical = false },
        .{ .case_id = "clone-b", .statistical_unit_id = "edit-filter", .seed = "seed-b1", .critical = false },
        .{ .case_id = "clone-b", .statistical_unit_id = "edit-filter", .seed = "seed-b2", .critical = false },
        .{ .case_id = "independent", .seed = "seed-i1", .critical = false },
    };
    const results = [_]PairResult{
        .{ .case_id = "clone-a", .seed = "seed-a1", .parent_pass = true, .child_pass = false, .parent_score_ppm = 1_000_000, .child_score_ppm = 0, .tool_calls_measured = true, .parent_tool_calls = 3, .child_tool_calls = 2 },
        .{ .case_id = "clone-a", .seed = "seed-a2", .parent_pass = false, .child_pass = true, .parent_score_ppm = 0, .child_score_ppm = 1_000_000, .tool_calls_measured = true, .parent_tool_calls = 3, .child_tool_calls = 2 },
        .{ .case_id = "clone-b", .seed = "seed-b1", .parent_pass = true, .child_pass = true, .parent_score_ppm = 1_000_000, .child_score_ppm = 1_000_000, .tool_calls_measured = true, .parent_tool_calls = 3, .child_tool_calls = 2 },
        .{ .case_id = "clone-b", .seed = "seed-b2", .parent_pass = false, .child_pass = true, .parent_score_ppm = 0, .child_score_ppm = 1_000_000, .tool_calls_measured = true, .parent_tool_calls = 3, .child_tool_calls = 2 },
        .{ .case_id = "independent", .seed = "seed-i1", .parent_pass = true, .child_pass = true, .parent_score_ppm = 1_000_000, .child_score_ppm = 1_000_000, .tool_calls_measured = true, .parent_tool_calls = 1, .child_tool_calls = 2 },
    };
    const response: EvaluationResponse = .{ .schema = evaluation_response_schema, .trial_id = "trial", .candidate_index = 0, .cohort_id = "cohort", .suite_sha256 = config.evaluation_suite.sha256, .parent_id = "parent", .child_id = "child", .pairs = &results };
    const comparison = try computeComparison(config, config.evaluation_suite.sha256, "request", "response", &requested, response, 1);
    try std.testing.expectEqual(@as(usize, 5), comparison.pairs);
    try std.testing.expectEqual(@as(usize, 2), comparison.statistical_units);
    try std.testing.expectEqual(@as(usize, 1), comparison.wins);
    try std.testing.expectEqual(@as(usize, 0), comparison.losses);
    try std.testing.expectEqual(@as(usize, 1), comparison.ties);
    try std.testing.expectEqual(@as(usize, 1), comparison.tool_wins);
    try std.testing.expectEqual(@as(usize, 1), comparison.tool_losses);
    try std.testing.expectEqual(@as(usize, 0), comparison.tool_ties);
}

test "clone rows cannot satisfy minimum statistical-unit gate" {
    var config: store_mod.Config = .{
        .schema = store_mod.config_schema,
        .agent_name = "test",
        .mutation_instruction = "change",
        .mutator = .{ .program = "/bin/a", .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
        .evaluator = .{ .program = "/bin/b", .sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
        .evaluation_suite = .{ .path = "/suite", .sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" },
        .gate = .{ .minimum_pairs = 2 },
        .cohort = .{ .provider = "p", .model = "m", .task_family = "t", .adapter_version = "a", .verifier_version = "v" },
    };
    const ids = [_][]const u8{ "clone-0", "clone-1", "clone-2", "clone-3", "clone-4", "clone-5", "clone-6", "clone-7", "clone-8", "clone-9" };
    var requested: [10]PairRequest = undefined;
    var results: [10]PairResult = undefined;
    for (ids, 0..) |id, i| {
        requested[i] = .{ .case_id = id, .statistical_unit_id = "one-scenario", .seed = "seed", .critical = false };
        results[i] = .{ .case_id = id, .seed = "seed", .parent_pass = false, .child_pass = true, .parent_score_ppm = 0, .child_score_ppm = 1_000_000 };
    }
    const response: EvaluationResponse = .{ .schema = evaluation_response_schema, .trial_id = "trial", .candidate_index = 0, .cohort_id = "cohort", .suite_sha256 = config.evaluation_suite.sha256, .parent_id = "parent", .child_id = "child", .pairs = &results };
    const comparison = try computeComparison(config, config.evaluation_suite.sha256, "request", "response", &requested, response, 1);
    try std.testing.expectEqual(@as(usize, 1), comparison.statistical_units);
    try std.testing.expect(!comparison.eligible);
    try std.testing.expectEqualStrings("minimum_pairs", comparison.reason);

    config.gate.minimum_pairs = 1;
    config.gate.economy_gate_enabled = true;
    config.gate.promotion_mode = .economy;
    config.gate.minimum_economy_pairs = 2;
    for (&results) |*result| {
        result.parent_pass = true;
        result.child_pass = true;
        result.parent_score_ppm = 1_000_000;
        result.tool_calls_measured = true;
        result.parent_tool_calls = 2;
        result.child_tool_calls = 1;
    }
    const economy = try computeComparison(config, config.evaluation_suite.sha256, "request", "response", &requested, response, 1);
    try std.testing.expectEqualStrings("minimum_economy_pairs", economy.reason);
}

test "buildPairs preserves statistical units while repetition seeds stay distinct" {
    const cases = [_]store_mod.SuiteCase{
        .{ .id = "clone-a", .statistical_unit_id = "scenario" },
        .{ .id = "clone-b", .statistical_unit_id = "scenario" },
    };
    const manifest: store_mod.SuiteManifest = .{
        .schema = store_mod.suite_schema,
        .suite_id = "suite",
        .cases = &cases,
    };
    const suite: store_mod.Suite = .{ .path = "/suite", .sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" };
    const pairs = try buildPairs(std.testing.allocator, "trial", suite, manifest, 0, 2);
    defer freePairs(std.testing.allocator, pairs);
    try std.testing.expectEqual(@as(usize, 4), pairs.len);
    for (pairs) |pair| try std.testing.expectEqualStrings("scenario", learn_eval.statisticalUnitId(pair));
    try std.testing.expect(!std.mem.eql(u8, pairs[0].seed, pairs[2].seed));
    try std.testing.expect(!std.mem.eql(u8, pairs[1].seed, pairs[3].seed));
}

test "economy gate requires corrected per-case evidence without correctness loss" {
    const config: store_mod.Config = .{
        .schema = store_mod.config_schema,
        .agent_name = "test",
        .mutation_instruction = "change",
        .mutator = .{ .program = "/bin/a", .sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
        .evaluator = .{ .program = "/bin/b", .sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
        .evaluation_suite = .{ .path = "/suite", .sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" },
        .gate = .{
            .alpha_ppm = 50_000,
            .minimum_delta_ppm = 50_000,
            .minimum_pairs = 8,
            .economy_gate_enabled = true,
            .promotion_mode = .economy,
            .minimum_tool_reduction_ppm = 100_000,
            .minimum_economy_pairs = 6,
        },
        .cohort = .{ .provider = "p", .model = "m", .task_family = "t", .adapter_version = "a", .verifier_version = "v" },
    };
    const case_ids = [_][]const u8{ "case-0", "case-1", "case-2", "case-3", "case-4", "case-5", "case-6", "case-7" };
    var requested: [8]PairRequest = undefined;
    var results: [8]PairResult = undefined;
    for (0..8) |i| {
        requested[i] = .{ .case_id = case_ids[i], .seed = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .critical = i == 0 };
        results[i] = .{
            .case_id = case_ids[i],
            .seed = requested[i].seed,
            .parent_pass = true,
            .child_pass = true,
            .parent_score_ppm = 1_000_000,
            .child_score_ppm = 1_000_000,
            .parent_latency_ms = 5,
            .child_latency_ms = 4,
            .latency_measured = true,
            .tool_calls_measured = true,
            .parent_tool_calls = 2,
            .child_tool_calls = 1,
        };
    }
    const response: EvaluationResponse = .{ .schema = evaluation_response_schema, .trial_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .candidate_index = 0, .cohort_id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .suite_sha256 = config.evaluation_suite.sha256, .parent_id = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", .child_id = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", .pairs = &results };
    const strong = try computeComparison(config, config.evaluation_suite.sha256, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "1111111111111111111111111111111111111111111111111111111111111111", &requested, response, 4);
    try std.testing.expect(strong.eligible);
    try std.testing.expect(strong.economy_eligible);
    try std.testing.expectEqual(@as(usize, 0), strong.correctness_regressions);
    try std.testing.expectEqualStrings("economy_eligible", strong.reason);
    try std.testing.expectEqual(@as(usize, 8), strong.tool_wins);
    try std.testing.expectEqual(@as(u64, 40), strong.parent_latency_ms);
    try std.testing.expectEqual(@as(u64, 32), strong.child_latency_ms);

    var correctness_only = results;
    for (&correctness_only) |*result| {
        result.parent_pass = false;
        result.child_pass = true;
        result.parent_score_ppm = 0;
        result.child_score_ppm = 1_000_000;
        result.child_tool_calls = result.parent_tool_calls;
    }
    const correctness_response: EvaluationResponse = .{ .schema = evaluation_response_schema, .trial_id = response.trial_id, .candidate_index = 0, .cohort_id = response.cohort_id, .suite_sha256 = response.suite_sha256, .parent_id = response.parent_id, .child_id = response.child_id, .pairs = &correctness_only };
    const wrong_endpoint = try computeComparison(config, config.evaluation_suite.sha256, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "1111111111111111111111111111111111111111111111111111111111111111", &requested, correctness_response, 4);
    try std.testing.expect(!wrong_endpoint.eligible);
    var correctness_config = config;
    correctness_config.gate.promotion_mode = .correctness;
    const registered_endpoint = try computeComparison(correctness_config, config.evaluation_suite.sha256, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "1111111111111111111111111111111111111111111111111111111111111111", &requested, correctness_response, 4);
    try std.testing.expect(registered_endpoint.eligible);

    // Six directional wins are not enough after correcting for four arms,
    // even though the aggregate call reduction remains above ten percent.
    results[6].child_tool_calls = 2;
    results[7].child_tool_calls = 2;
    const weak = try computeComparison(config, config.evaluation_suite.sha256, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "1111111111111111111111111111111111111111111111111111111111111111", &requested, response, 4);
    try std.testing.expect(!weak.eligible);
    try std.testing.expectEqualStrings("economy_not_significant", weak.reason);

    results[5].child_tool_calls = 2;
    const too_few_directions = try computeComparison(config, config.evaluation_suite.sha256, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "1111111111111111111111111111111111111111111111111111111111111111", &requested, response, 4);
    try std.testing.expect(!too_few_directions.eligible);
    try std.testing.expectEqualStrings("minimum_economy_pairs", too_few_directions.reason);

    results[0].tool_calls_measured = false;
    const unmeasured = try computeComparison(config, config.evaluation_suite.sha256, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "1111111111111111111111111111111111111111111111111111111111111111", &requested, response, 4);
    try std.testing.expect(!unmeasured.eligible);
    try std.testing.expectEqualStrings("tool_calls_unmeasured", unmeasured.reason);

    results[0].tool_calls_measured = true;
    results[0].parent_pass = true;
    results[0].child_pass = false;
    results[1].parent_pass = false;
    results[1].child_pass = true;
    const traded_correctness = try computeComparison(config, config.evaluation_suite.sha256, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "1111111111111111111111111111111111111111111111111111111111111111", &requested, response, 4);
    try std.testing.expect(!traded_correctness.eligible);
    try std.testing.expectEqualStrings("critical_regression", traded_correctness.reason);

    requested[0].critical = false;
    const noncritical_trade = try computeComparison(config, config.evaluation_suite.sha256, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "1111111111111111111111111111111111111111111111111111111111111111", &requested, response, 4);
    try std.testing.expect(!noncritical_trade.eligible);
    try std.testing.expectEqualStrings("correctness_regression", noncritical_trade.reason);

    // A regression and improvement inside one repeated/related unit cancel in
    // the unit-level sign test, but economy mode must still reject the raw
    // regression rather than trading correctness for lower tool use.
    var grouped_config = config;
    grouped_config.gate.minimum_pairs = 7;
    for (&requested, &results) |*pair, *result| {
        pair.critical = false;
        pair.statistical_unit_id = null;
        result.parent_pass = true;
        result.child_pass = true;
        result.parent_score_ppm = 1_000_000;
        result.child_score_ppm = 1_000_000;
        result.tool_calls_measured = true;
        result.parent_tool_calls = 2;
        result.child_tool_calls = 1;
    }
    requested[0].statistical_unit_id = "traded-unit";
    requested[1].statistical_unit_id = "traded-unit";
    results[0].child_pass = false;
    results[0].child_score_ppm = 0;
    results[1].parent_pass = false;
    results[1].parent_score_ppm = 0;
    const hidden_trade = try computeComparison(grouped_config, config.evaluation_suite.sha256, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "1111111111111111111111111111111111111111111111111111111111111111", &requested, response, 4);
    try std.testing.expectEqual(@as(usize, 7), hidden_trade.statistical_units);
    try std.testing.expectEqual(@as(usize, 0), hidden_trade.losses);
    try std.testing.expectEqual(@as(usize, 1), hidden_trade.correctness_regressions);
    try std.testing.expect(!hidden_trade.economy_eligible);
    try std.testing.expectEqualStrings("correctness_regression", hidden_trade.reason);
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
