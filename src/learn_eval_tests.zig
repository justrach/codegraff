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
