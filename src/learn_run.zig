//! Concurrent four-arm tournament execution for `graff learn run`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

const checkpoint = @import("learn_checkpoint.zig");
const eval = @import("learn_eval.zig");
const holdout = @import("learn_holdout.zig");
const mutation_verify = @import("learn_mutation_verify.zig");
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
    resume_run: bool,
    restart: bool,
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
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const outcome = eval.mutate(gpa, task_arena.allocator(), io, environ, store, config, trial_id, index, parent_id, parent_prompt) catch |err| switch (err) {
            // A new mutate call creates a new private scratch directory. Keep
            // the registered arm identity and seed, but trust none of the
            // failed process's partial files.
            error.ProcessFailed, error.ProcessTimedOut => if (attempt == 0) continue else return err,
            else => return err,
        };
        return .{ .arena = task_arena, .outcome = outcome };
    }
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
    const primary_suite = try store_mod.loadSuite(io, arena, config.evaluation_suite);
    try store_mod.validateSuitePower(primary_suite.manifest, config.gate);
    if (config.holdout_suite) |suite| {
        const holdout_suite = try store_mod.loadSuite(io, arena, suite);
        try store_mod.validateHoldoutIndependence(config.evaluation_suite.sha256, primary_suite.manifest, suite.sha256, holdout_suite.manifest);
        try store_mod.validateSuitePower(holdout_suite.manifest, config.gate);
    }
}

pub fn verifyTrialPower(io: Io, arena: Allocator, config: store_mod.Config, planned_candidates: usize) !void {
    const primary_suite = try store_mod.loadSuite(io, arena, config.evaluation_suite);
    try store_mod.validateSuiteTrialPower(primary_suite.manifest, config.gate, planned_candidates);
    if (config.holdout_suite) |suite| {
        const holdout_suite = try store_mod.loadSuite(io, arena, suite);
        try store_mod.validateHoldoutIndependence(config.evaluation_suite.sha256, primary_suite.manifest, suite.sha256, holdout_suite.manifest);
        try store_mod.validateSuiteTrialPower(holdout_suite.manifest, config.gate, 1);
    }
}

fn requireCompleteCandidateSet(required: bool, planned: usize, actual: usize) !void {
    if (required and actual != planned) return error.IncompleteCandidateSet;
}

fn copyMutationCandidate(arena: Allocator, outcome: eval.MutationOutcome) !eval.CandidateRecord {
    return .{
        .genome_id = try arena.dupe(u8, &outcome.genome_id),
        .mutation = .{
            .seed = try arena.dupe(u8, outcome.record.seed),
            .request_evidence_id = try arena.dupe(u8, outcome.record.request_evidence_id),
            .response_evidence_id = try arena.dupe(u8, outcome.record.response_evidence_id),
            .description = try arena.dupe(u8, outcome.record.description),
            .genome_bytes = outcome.record.genome_bytes,
        },
        .primary = null,
        .holdout = null,
        .eligible = false,
        .reason = "unevaluated",
    };
}

fn progressRecord(
    config_id: []const u8,
    active: store_mod.LoadedActive,
    nonce: []const u8,
    trial_id: []const u8,
    created_unix_ms: i64,
    candidate_count: usize,
    repetitions: usize,
    auto_requested: bool,
    primary_baseline: ?eval.PrimaryBaselineRecord,
    candidates: []const eval.CandidateRecord,
) checkpoint.Record {
    return .{
        .trial_id = trial_id,
        .nonce = nonce,
        .created_unix_ms = created_unix_ms,
        .harness_version = build_options.version,
        .config_id = config_id,
        .parent_genome_id = active.ref.genome_id,
        .parent_generation = active.ref.generation,
        .parent_transaction_id = active.ref.transaction_id,
        .planned_candidates = candidate_count,
        .repetitions = repetitions,
        .auto_requested = auto_requested,
        .primary_baseline = primary_baseline,
        .candidates = candidates,
    };
}

fn verifyRestoredProgress(
    arena: Allocator,
    io: Io,
    store: *store_mod.Store,
    config: store_mod.LoadedConfig,
    active: store_mod.LoadedActive,
    record: checkpoint.Record,
    candidates: []eval.CandidateRecord,
) !void {
    var baseline_response: ?eval.PrimaryBaselineResponse = null;
    if (record.primary_baseline) |baseline| baseline_response = try primary.verifyBaseline(
        arena,
        io,
        store,
        config.value,
        &config.id,
        build_options.version,
        record.trial_id,
        active.ref.genome_id,
        config.value.evaluation_suite,
        record.repetitions,
        baseline,
    );

    var unique_count: usize = 0;
    var completed_primary: usize = 0;
    for (candidates, 0..) |*candidate, index| {
        try mutation_verify.verify(arena, store, config.value, record.trial_id, active.ref.genome_id, index, candidate.*);
        if (mutationIsDuplicate(active.ref.genome_id, candidates, index)) |reason| {
            if (candidate.primary != null or candidate.holdout != null) return error.InvalidPendingTopology;
            candidate.reason = reason;
            continue;
        }
        unique_count += 1;
        if (candidate.primary) |comparison| {
            const baseline = record.primary_baseline orelse return error.MissingPrimaryBaseline;
            candidate.primary = try primary.verifyCandidate(
                arena,
                io,
                store,
                config.value,
                &config.id,
                build_options.version,
                record.trial_id,
                index,
                active.ref.genome_id,
                candidate.genome_id,
                config.value.evaluation_suite,
                record.repetitions,
                record.planned_candidates,
                baseline,
                baseline_response orelse return error.MissingPrimaryBaseline,
                comparison,
            );
            completed_primary += 1;
            candidate.reason = candidate.primary.?.reason;
        } else candidate.reason = "unevaluated";
    }
    if (unique_count == 0 and record.primary_baseline != null) return error.PrimaryBaselineTopologyMismatch;

    var holdout_count: usize = 0;
    for (candidates) |candidate| if (candidate.holdout != null) {
        holdout_count += 1;
    };
    if (record.primary_baseline == null) {
        if (completed_primary != 0 or holdout_count != 0) return error.PrimaryBaselineTopologyMismatch;
        return;
    }
    if (holdout_count == 0) return;
    if (holdout_count != 1 or completed_primary != unique_count) return error.InvalidPendingTopology;
    const winner_index = tournament.primaryWinnerIndex(active.ref.genome_id, candidates) orelse return error.InvalidPendingTopology;
    if (!candidates[winner_index].primary.?.eligible or candidates[winner_index].holdout == null) return error.InvalidPendingTopology;
    for (candidates, 0..) |*candidate, index| {
        if (candidate.holdout) |comparison| {
            if (index != winner_index) return error.InvalidPendingTopology;
            const suite = config.value.holdout_suite orelse return error.InvalidPendingTopology;
            try holdout.verify(io, store.root, arena, suite.sha256, record.trial_id);
            candidate.holdout = try eval.verifyComparison(
                arena,
                io,
                store,
                config.value,
                &config.id,
                build_options.version,
                record.trial_id,
                index,
                active.ref.genome_id,
                candidate.genome_id,
                suite,
                record.repetitions,
                1,
                comparison,
            );
        }
    }
}

pub fn restorePending(
    arena: Allocator,
    io: Io,
    store: *store_mod.Store,
    config: store_mod.LoadedConfig,
    active: store_mod.LoadedActive,
    record: checkpoint.Record,
) ![]eval.CandidateRecord {
    try checkpoint.validate(record);
    if (!std.mem.eql(u8, record.config_id, &config.id) or
        !std.mem.eql(u8, record.harness_version, build_options.version) or
        record.parent_generation != active.ref.generation or
        !std.mem.eql(u8, record.parent_genome_id, active.ref.genome_id) or
        !std.mem.eql(u8, record.parent_transaction_id, active.ref.transaction_id)) return error.PendingContextMismatch;
    const expected_trial = trialId(record.config_id, record.parent_genome_id, record.parent_generation, record.parent_transaction_id, record.nonce);
    if (!std.mem.eql(u8, record.trial_id, &expected_trial)) return error.TrialMismatch;
    const candidates = try arena.dupe(eval.CandidateRecord, record.candidates);
    try verifyRestoredProgress(arena, io, store, config, active, record, candidates);
    return candidates;
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
    if (options.resume_run and options.restart) return error.ConflictingOptions;
    if (options.restart) try checkpoint.clear(store);
    const pending = try checkpoint.load(arena, store);

    var nonce_buffer: [64]u8 = undefined;
    var trial_buffer: [64]u8 = undefined;
    var nonce: []const u8 = undefined;
    var trial_id: []const u8 = undefined;
    var created_unix_ms: i64 = undefined;
    var candidate_count: usize = undefined;
    var repetitions: usize = undefined;
    var primary_baseline: ?eval.PrimaryBaselineRecord = null;
    var candidates: []eval.CandidateRecord = undefined;

    if (options.resume_run) {
        const saved = pending orelse return error.NoPendingRun;
        if ((options.candidates != null and options.candidates.? != saved.planned_candidates) or
            (options.repetitions != null and options.repetitions.? != saved.repetitions) or
            options.auto != saved.auto_requested) return error.ResumeOptionMismatch;
        nonce = saved.nonce;
        trial_id = saved.trial_id;
        created_unix_ms = saved.created_unix_ms;
        candidate_count = saved.planned_candidates;
        repetitions = saved.repetitions;
        try verifyTrialPower(io, arena, config.value, candidate_count);
        primary_baseline = saved.primary_baseline;
        candidates = try restorePending(arena, io, store, config, active, saved);
        try out.print("resuming checkpointed trial {s}\n", .{trial_id});
    } else {
        if (pending != null) {
            try out.writeAll("a recoverable tournament exists; use `graff learn run --resume` or explicitly discard it with `--restart`\n");
            return error.PendingRunExists;
        }
        if (config.value.holdout_suite) |suite|
            try holdout.ensureUnused(io, store.root, suite.sha256);
        candidate_count = options.candidates orelse config.value.gate.default_candidates;
        repetitions = options.repetitions orelse config.value.gate.default_repetitions;
        if (candidate_count == 0 or candidate_count > 16 or repetitions == 0 or repetitions > 100) return error.InvalidNumber;
        try verifyTrialPower(io, arena, config.value, candidate_count);
        nonce_buffer = try store_mod.randomId(io);
        trial_buffer = trialId(&config.id, active.ref.genome_id, active.ref.generation, active.ref.transaction_id, &nonce_buffer);
        nonce = &nonce_buffer;
        trial_id = &trial_buffer;
        created_unix_ms = util.unixMs(io);
        candidates = try arena.alloc(eval.CandidateRecord, candidate_count);

        const mutation_futures = try arena.alloc(Io.Future(anyerror!MutationTaskResult), candidate_count);
        const mutation_results = try arena.alloc(anyerror!MutationTaskResult, candidate_count);
        for (mutation_futures, 0..) |*future, index| {
            future.* = io.async(mutationTask, .{ gpa, io, environ, store, config.value, trial_id, index, active.ref.genome_id, active.genome });
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
            candidate.* = try copyMutationCandidate(arena, completed.outcome);
        }
        for (candidates, 0..) |*candidate, index| if (mutationIsDuplicate(active.ref.genome_id, candidates, index)) |reason| {
            candidate.reason = reason;
        };
        try checkpoint.write(gpa, store, progressRecord(
            &config.id,
            active,
            nonce,
            trial_id,
            created_unix_ms,
            candidate_count,
            repetitions,
            options.auto,
            null,
            candidates,
        ));
    }

    var primary_indices: std.ArrayList(usize) = .empty;
    defer primary_indices.deinit(gpa);
    for (candidates, 0..) |*candidate, index| {
        if (mutationIsDuplicate(active.ref.genome_id, candidates, index)) |reason| {
            candidate.reason = reason;
        } else try primary_indices.append(gpa, index);
    }
    try requireCompleteCandidateSet(config.value.gate.require_all_candidates, candidate_count, primary_indices.items.len);

    if (primary_indices.items.len > 0 and primary_baseline == null) {
        primary_baseline = try primary.evaluateBaseline(
            gpa,
            arena,
            io,
            environ,
            store,
            config.value,
            &config.id,
            build_options.version,
            trial_id,
            active.ref.genome_id,
            active.genome,
            config.value.evaluation_suite,
            repetitions,
        );
        try checkpoint.write(gpa, store, progressRecord(&config.id, active, nonce, trial_id, created_unix_ms, candidate_count, repetitions, options.auto, primary_baseline, candidates));
    }

    var missing_primary: std.ArrayList(usize) = .empty;
    defer missing_primary.deinit(gpa);
    for (primary_indices.items) |index| if (candidates[index].primary == null) try missing_primary.append(gpa, index);
    const primary_futures = try arena.alloc(Io.Future(anyerror!EvaluationTaskResult), missing_primary.items.len);
    const primary_results = try arena.alloc(anyerror!EvaluationTaskResult, missing_primary.items.len);
    const child_prompts = try arena.alloc([]const u8, missing_primary.items.len);
    for (missing_primary.items, child_prompts) |index, *prompt| {
        prompt.* = try store.readGenome(arena, candidates[index].genome_id, config.value.limits.genome_bytes);
    }
    for (missing_primary.items, child_prompts, primary_futures) |index, child_prompt, *future| {
        future.* = io.async(primaryTask, .{
            gpa,         io,              environ,              store,                       config.value, &config.id,
            trial_id,    index,           active.ref.genome_id, candidates[index].genome_id, child_prompt, config.value.evaluation_suite,
            repetitions, candidate_count, primary_baseline.?,
        });
    }
    for (primary_futures, primary_results) |*future, *result| result.* = future.await(io);
    defer for (primary_results) |*result| {
        if (result.*) |*task_result| task_result.arena.deinit() else |_| {}
    };
    var primary_failure: ?anyerror = null;
    for (missing_primary.items, primary_results) |index, result| {
        if (result) |completed| {
            candidates[index].primary = completed.comparison;
            candidates[index].reason = candidates[index].primary.?.reason;
            try checkpoint.write(gpa, store, progressRecord(&config.id, active, nonce, trial_id, created_unix_ms, candidate_count, repetitions, options.auto, primary_baseline, candidates));
        } else |err| if (primary_failure == null) {
            primary_failure = err;
        }
    }
    if (primary_failure) |err| return err;

    const primary_winner_index = tournament.primaryWinnerIndex(active.ref.genome_id, candidates);
    if (primary_winner_index) |winner_index| {
        if (candidates[winner_index].primary.?.eligible) if (config.value.holdout_suite) |holdout_suite| {
            if (candidates[winner_index].holdout == null) {
                try holdout.reserveOrVerify(io, store.root, arena, holdout_suite.sha256, trial_id);
                const child_prompt = try store.readGenome(arena, candidates[winner_index].genome_id, config.value.limits.genome_bytes);
                candidates[winner_index].holdout = try eval.evaluate(
                    gpa,
                    arena,
                    io,
                    environ,
                    store,
                    config.value,
                    &config.id,
                    build_options.version,
                    trial_id,
                    winner_index,
                    active.ref.genome_id,
                    active.genome,
                    candidates[winner_index].genome_id,
                    child_prompt,
                    holdout_suite,
                    repetitions,
                    1,
                );
                try checkpoint.write(gpa, store, progressRecord(&config.id, active, nonce, trial_id, created_unix_ms, candidate_count, repetitions, options.auto, primary_baseline, candidates));
            }
        };
    }
    const finalized = try tournament.finalize(active.ref.genome_id, candidates, config.value.holdout_suite != null);
    const primary_winner = if (finalized.primary_winner_index) |index| candidates[index].genome_id else null;

    // Re-check every externally controlled executable and suite after use and
    // before committing the immutable run record.
    try verifyPins(io, arena, config.value);
    try verifyTrialPower(io, arena, config.value, candidate_count);

    const record: eval.RunRecord = .{
        .schema = eval.run_schema,
        .trial_id = trial_id,
        .nonce = nonce,
        .created_unix_ms = created_unix_ms,
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
    try out.flush();
    try checkpoint.clear(store);
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
