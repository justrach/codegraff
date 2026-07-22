//! Concurrent four-arm tournament execution for `graff learn run`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

const eval = @import("learn_eval.zig");
const holdout = @import("learn_holdout.zig");
const primary = @import("learn_primary.zig");
const report = @import("learn_report.zig");
const store_mod = @import("learn_store.zig");
const submit = @import("learn_submit.zig");
const tournament = @import("learn_tournament.zig");
const util = @import("util.zig");

pub const Options = struct {
    candidates: ?usize,
    repetitions: ?usize,
    submit: bool,
    auto: bool,
};

pub const Result = struct {
    run_id: [64]u8,
    primary_winner_genome_id: ?[]const u8,
    selected_genome_id: ?[]const u8,
};

pub fn trialId(
    config_id: []const u8,
    parent_id: []const u8,
    parent_generation: u64,
    parent_transaction_id: []const u8,
    nonce: []const u8,
) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("codegraff-learn/trial/v1");
    hash.update(&.{0});
    var generation_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, generation_bytes[0..], parent_generation, .big);
    for ([_][]const u8{ config_id, parent_id, &generation_bytes, parent_transaction_id, nonce }) |field| {
        var len: [8]u8 = undefined;
        std.mem.writeInt(u64, len[0..], @intCast(field.len), .big);
        hash.update(&len);
        hash.update(field);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

const MutationTaskResult = struct {
    arena: std.heap.ArenaAllocator,
    outcome: eval.MutationOutcome,
};

fn mutationTask(
    gpa: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    store: *store_mod.Store,
    config: store_mod.Config,
    trial_id: []const u8,
    index: usize,
    parent_id: []const u8,
    parent_prompt: []const u8,
) anyerror!MutationTaskResult {
    var task_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer task_arena.deinit();
    const outcome = try eval.mutate(gpa, task_arena.allocator(), io, environ, store, config, trial_id, index, parent_id, parent_prompt);
    return .{ .arena = task_arena, .outcome = outcome };
}

const EvaluationTaskResult = struct {
    arena: std.heap.ArenaAllocator,
    comparison: eval.ComparisonRecord,
};

fn primaryTask(
    gpa: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    store: *store_mod.Store,
    config: store_mod.Config,
    config_id: []const u8,
    trial_id: []const u8,
    index: usize,
    parent_id: []const u8,
    child_id: []const u8,
    child_prompt: []const u8,
    suite: store_mod.Suite,
    repetitions: usize,
    planned_candidates: usize,
    baseline: eval.PrimaryBaselineRecord,
) anyerror!EvaluationTaskResult {
    var task_arena = std.heap.ArenaAllocator.init(gpa);
    errdefer task_arena.deinit();
    const comparison = try primary.evaluateCandidate(
        gpa,
        task_arena.allocator(),
        io,
        environ,
        store,
        config,
        config_id,
        build_options.version,
        trial_id,
        index,
        parent_id,
        child_id,
        child_prompt,
        suite,
        repetitions,
        planned_candidates,
        baseline,
    );
    return .{ .arena = task_arena, .comparison = comparison };
}

fn mutationIsDuplicate(parent_id: []const u8, candidates: []const eval.CandidateRecord, index: usize) ?[]const u8 {
    if (std.mem.eql(u8, candidates[index].genome_id, parent_id)) return "identical_parent";
    for (candidates[0..index]) |prior| {
        if (std.mem.eql(u8, prior.genome_id, candidates[index].genome_id)) return "duplicate_candidate";
    }
    return null;
}

fn verifyPins(io: Io, arena: Allocator, config: store_mod.Config) !void {
    try store_mod.verifyProgram(io, config.mutator);
    try store_mod.verifyProgram(io, config.evaluator);
    _ = try store_mod.loadSuite(io, arena, config.evaluation_suite);
    if (config.holdout_suite) |suite| _ = try store_mod.loadSuite(io, arena, suite);
}

fn requireCompleteCandidateSet(required: bool, planned: usize, actual: usize) !void {
    if (required and actual != planned) return error.IncompleteCandidateSet;
}

/// Runs mutations and primary comparisons behind separate barriers. The
/// holdout adapter is invoked only after every primary result has joined and
/// the sole winner has been selected.
pub fn execute(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    store: *store_mod.Store,
    config: store_mod.LoadedConfig,
    active: store_mod.LoadedActive,
    options: Options,
    out: *Io.Writer,
) !Result {
    const candidate_count = options.candidates orelse config.value.gate.default_candidates;
    const repetitions = options.repetitions orelse config.value.gate.default_repetitions;
    if (candidate_count == 0 or candidate_count > 16 or repetitions == 0 or repetitions > 100) return error.InvalidNumber;

    const nonce = try store_mod.randomId(io);
    const trial_id = trialId(&config.id, active.ref.genome_id, active.ref.generation, active.ref.transaction_id, &nonce);
    const candidates = try arena.alloc(eval.CandidateRecord, candidate_count);

    const mutation_futures = try arena.alloc(Io.Future(anyerror!MutationTaskResult), candidate_count);
    const mutation_results = try arena.alloc(anyerror!MutationTaskResult, candidate_count);
    for (mutation_futures, 0..) |*future, index| {
        future.* = io.async(mutationTask, .{ gpa, io, environ, store, config.value, &trial_id, index, active.ref.genome_id, active.genome });
    }
    for (mutation_futures, mutation_results) |*future, *result| result.* = future.await(io);
    defer for (mutation_results) |*result| {
        if (result.*) |*task_result| {
            gpa.free(task_result.outcome.prompt);
            task_result.arena.deinit();
        } else |_| {}
    };

    for (mutation_results, candidates) |result, *candidate| {
        const completed = result catch |err| {
            if (config.value.gate.require_all_candidates) return error.IncompleteCandidateSet;
            return err;
        };
        candidate.* = .{
            .genome_id = try arena.dupe(u8, &completed.outcome.genome_id),
            .mutation = completed.outcome.record,
            .primary = null,
            .holdout = null,
            .eligible = false,
            .reason = "unevaluated",
        };
    }

    var primary_indices: std.ArrayList(usize) = .empty;
    defer primary_indices.deinit(gpa);
    for (candidates, 0..) |*candidate, index| {
        if (mutationIsDuplicate(active.ref.genome_id, candidates, index)) |reason| {
            candidate.reason = reason;
        } else try primary_indices.append(gpa, index);
    }
    try requireCompleteCandidateSet(config.value.gate.require_all_candidates, candidate_count, primary_indices.items.len);

    const primary_baseline: ?eval.PrimaryBaselineRecord = if (primary_indices.items.len > 0)
        try primary.evaluateBaseline(
            gpa,
            arena,
            io,
            environ,
            store,
            config.value,
            &config.id,
            build_options.version,
            &trial_id,
            active.ref.genome_id,
            active.genome,
            config.value.evaluation_suite,
            repetitions,
        )
    else
        null;

    const primary_futures = try arena.alloc(Io.Future(anyerror!EvaluationTaskResult), primary_indices.items.len);
    const primary_results = try arena.alloc(anyerror!EvaluationTaskResult, primary_indices.items.len);
    for (primary_indices.items, primary_futures) |index, *future| {
        const mutation = try mutation_results[index];
        future.* = io.async(primaryTask, .{
            gpa,         io,              environ,              store,                       config.value,            &config.id,
            &trial_id,   index,           active.ref.genome_id, candidates[index].genome_id, mutation.outcome.prompt, config.value.evaluation_suite,
            repetitions, candidate_count, primary_baseline.?,
        });
    }
    for (primary_futures, primary_results) |*future, *result| result.* = future.await(io);
    defer for (primary_results) |*result| {
        if (result.*) |*task_result| task_result.arena.deinit() else |_| {}
    };
    for (primary_indices.items, primary_results) |index, result| {
        candidates[index].primary = (try result).comparison;
    }

    const primary_winner_index = tournament.primaryWinnerIndex(active.ref.genome_id, candidates);
    if (primary_winner_index) |winner_index| {
        if (candidates[winner_index].primary.?.eligible) if (config.value.holdout_suite) |holdout_suite| {
            const mutation = try mutation_results[winner_index];
            try holdout.reserve(io, store.root, holdout_suite.sha256, &trial_id);
            candidates[winner_index].holdout = try eval.evaluate(
                gpa,
                arena,
                io,
                environ,
                store,
                config.value,
                &config.id,
                build_options.version,
                &trial_id,
                winner_index,
                active.ref.genome_id,
                active.genome,
                candidates[winner_index].genome_id,
                mutation.outcome.prompt,
                holdout_suite,
                repetitions,
                1,
            );
        };
    }
    const finalized = try tournament.finalize(active.ref.genome_id, candidates, config.value.holdout_suite != null);
    const primary_winner = if (finalized.primary_winner_index) |index| candidates[index].genome_id else null;

    // Re-check every externally controlled executable and suite after use and
    // before committing the immutable run record.
    try verifyPins(io, arena, config.value);

    const record: eval.RunRecord = .{
        .schema = eval.run_schema,
        .trial_id = &trial_id,
        .nonce = &nonce,
        .created_unix_ms = util.unixMs(io),
        .harness_version = build_options.version,
        .config_id = &config.id,
        .parent_genome_id = active.ref.genome_id,
        .parent_generation = active.ref.generation,
        .parent_transaction_id = active.ref.transaction_id,
        .planned_candidates = candidate_count,
        .repetitions = repetitions,
        .auto_requested = options.auto,
        .primary_baseline = primary_baseline,
        .candidates = candidates,
        .primary_winner_genome_id = primary_winner,
        .selected_genome_id = finalized.selected_genome_id,
    };
    const record_bytes = try store_mod.jsonBytes(gpa, record);
    defer gpa.free(record_bytes);
    if (record_bytes.len > store_mod.max_record_bytes) return error.RunTooLarge;
    const run_id = try store.writeRun(gpa, record_bytes);

    try out.print("run {s}\n", .{run_id});
    try report.writeCandidateSummary(out, candidates);
    if (primary_winner) |id| try out.print("primary winner {s}\n", .{id});
    if (options.submit) {
        const sent = try submit.submitVerifiedRun(io, gpa, arena, environ, config.value, &run_id, record);
        try out.print("submitted {d} signed aggregate grade(s); prompt text stayed local\n", .{sent.grades});
    }
    return .{
        .run_id = run_id,
        .primary_winner_genome_id = primary_winner,
        .selected_genome_id = finalized.selected_genome_id,
    };
}

test "trial IDs bind active generation and transaction" {
    const original = trialId("config", "parent", 7, "transaction-a", "nonce");
    try std.testing.expectEqualSlices(u8, &original, &trialId("config", "parent", 7, "transaction-a", "nonce"));
    try std.testing.expect(!std.mem.eql(u8, &original, &trialId("config", "parent", 8, "transaction-a", "nonce")));
    try std.testing.expect(!std.mem.eql(u8, &original, &trialId("config", "parent", 7, "transaction-b", "nonce")));
}

test "required tournaments reject a partial unique candidate set" {
    try requireCompleteCandidateSet(false, 4, 3);
    try std.testing.expectError(error.IncompleteCandidateSet, requireCompleteCandidateSet(true, 4, 3));
    try requireCompleteCandidateSet(true, 4, 4);
}
