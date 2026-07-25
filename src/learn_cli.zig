//! `graff learn`: a local-first parent → mutate → paired-evaluate → select
//! engine with immutable evidence, manual promotion by default, an explicit
//! two-key automatic gate, and atomic active-reference rollback.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

const store_mod = @import("learn_store.zig");
const checkpoint = @import("learn_checkpoint.zig");
const eval = @import("learn_eval.zig");
const holdout = @import("learn_holdout.zig");
const diagnostics = @import("learn_diagnostics.zig");
const mutation_verify = @import("learn_mutation_verify.zig");
const primary = @import("learn_primary.zig");
const learn_run = @import("learn_run.zig");
const learn_delete = @import("learn_delete.zig");
const submit = @import("learn_submit.zig");
const tournament = @import("learn_tournament.zig");
const learn_init = @import("learn_init.zig");
const credentials = @import("learn_credentials.zig");
const util = @import("util.zig");

pub const usage =
    \\graff learn — safe local prompt-policy learning
    \\
    \\usage:
    \\  graff learn init [--candidates N] [--provider ID] [--model NAME]
    \\  graff learn init --parent PATH --config PATH
    \\  graff learn run [--candidates N] [--repetitions N] [--resume | --restart] [--submit] [--auto] [--show-adapter-stderr] [--lock-timeout-ms N]
    \\  graff learn submit RUN_ID [--lock-timeout-ms N]
    \\  graff learn delete-remote RUN_ID [--lock-timeout-ms N]
    \\  graff learn status [--lock-timeout-ms N]
    \\  graff learn promote RUN_ID [--lock-timeout-ms N]
    \\  graff learn rollback [--to GENOME_ID] [--lock-timeout-ms N]
    \\  graff learn verify [--lock-timeout-ms N]
    \\  graff learn hash ABSOLUTE_PATH
    \\
    \\IDs are complete 64-character lowercase SHA-256 identifiers. Learning
    \\tools execute directly as your OS user; scratch directories and a scrubbed
    \\environment are not an OS sandbox. Promotion never trusts trajectory rows.
    \\
;

/// A bare `learn init` bootstraps everything from the running binary; an
/// explicit pair of paths keeps the hand-authored workflow unchanged.
const InitArgs = learn_init.Args;
const RunArgs = struct {
    candidates: ?usize = null,
    repetitions: ?usize = null,
    submit: bool = false,
    auto: bool = false,
    resume_run: bool = false,
    restart: bool = false,
    show_adapter_stderr: bool = false,
    lock_timeout_ms: u64 = 0,
};
const StatusArgs = struct { lock_timeout_ms: u64 = 0 };
const PromoteArgs = struct { run_id: []const u8, lock_timeout_ms: u64 = 0 };
const SubmitArgs = struct { run_id: []const u8, lock_timeout_ms: u64 = 0 };
const RollbackArgs = struct { to: ?[]const u8 = null, lock_timeout_ms: u64 = 0 };
const HashArgs = struct { path: []const u8 };

pub const Parsed = union(enum) {
    help,
    init: InitArgs,
    run: RunArgs,
    status: StatusArgs,
    submit: SubmitArgs,
    delete_remote: SubmitArgs,
    promote: PromoteArgs,
    rollback: RollbackArgs,
    verify: StatusArgs,
    hash: HashArgs,
};

fn parseUnsigned(comptime T: type, value: []const u8) !T {
    if (value.len == 0 or value[0] == '+' or value[0] == '-') return error.InvalidNumber;
    return std.fmt.parseInt(T, value, 10) catch return error.InvalidNumber;
}

fn parseLockOption(args: []const []const u8, index: *usize, seen: *bool, value: *u64) !bool {
    if (!std.mem.eql(u8, args[index.*], "--lock-timeout-ms")) return false;
    if (seen.*) return error.DuplicateOption;
    seen.* = true;
    index.* += 1;
    if (index.* >= args.len) return error.MissingOptionValue;
    value.* = try parseUnsigned(u64, args[index.*]);
    if (value.* > 600_000) return error.InvalidNumber;
    return true;
}

pub fn parse(args: []const []const u8) !Parsed {
    if (args.len == 0 or std.mem.eql(u8, args[0], "help") or std.mem.eql(u8, args[0], "--help")) return .help;
    const command_name = args[0];
    if (std.mem.eql(u8, command_name, "init")) {
        var parent: ?[]const u8 = null;
        var config: ?[]const u8 = null;
        var candidates: ?usize = null;
        var provider: ?[]const u8 = null;
        var model: ?[]const u8 = null;
        var index: usize = 1;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (std.mem.eql(u8, arg, "--parent")) {
                if (parent != null) return error.DuplicateOption;
                index += 1;
                if (index >= args.len) return error.MissingOptionValue;
                parent = args[index];
            } else if (std.mem.eql(u8, arg, "--config")) {
                if (config != null) return error.DuplicateOption;
                index += 1;
                if (index >= args.len) return error.MissingOptionValue;
                config = args[index];
            } else if (std.mem.eql(u8, arg, "--candidates")) {
                if (candidates != null) return error.DuplicateOption;
                index += 1;
                if (index >= args.len) return error.MissingOptionValue;
                candidates = try parseUnsigned(usize, args[index]);
                if (candidates.? == 0 or candidates.? > 16) return error.InvalidNumber;
            } else if (std.mem.eql(u8, arg, "--provider")) {
                if (provider != null) return error.DuplicateOption;
                index += 1;
                if (index >= args.len) return error.MissingOptionValue;
                provider = args[index];
            } else if (std.mem.eql(u8, arg, "--model")) {
                if (model != null) return error.DuplicateOption;
                index += 1;
                if (index >= args.len) return error.MissingOptionValue;
                model = args[index];
            } else return error.UnknownOption;
        }
        // A generated configuration is generated whole: mixing one hand-written
        // half with a generated other half would silently unpin the pair.
        if ((parent == null) != (config == null)) return error.MissingOption;
        if (parent != null and (candidates != null or provider != null or model != null)) return error.ConflictingOptions;
        return .{ .init = .{ .parent = parent, .config = config, .candidates = candidates, .provider = provider, .model = model } };
    }
    if (std.mem.eql(u8, command_name, "run")) {
        var result: RunArgs = .{};
        var seen_candidates = false;
        var seen_repetitions = false;
        var seen_auto = false;
        var seen_submit = false;
        var seen_resume = false;
        var seen_restart = false;
        var seen_adapter_stderr = false;
        var seen_lock = false;
        var index: usize = 1;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (std.mem.eql(u8, arg, "--candidates")) {
                if (seen_candidates) return error.DuplicateOption;
                seen_candidates = true;
                index += 1;
                if (index >= args.len) return error.MissingOptionValue;
                result.candidates = try parseUnsigned(usize, args[index]);
                if (result.candidates.? == 0 or result.candidates.? > 16) return error.InvalidNumber;
            } else if (std.mem.eql(u8, arg, "--repetitions")) {
                if (seen_repetitions) return error.DuplicateOption;
                seen_repetitions = true;
                index += 1;
                if (index >= args.len) return error.MissingOptionValue;
                result.repetitions = try parseUnsigned(usize, args[index]);
                if (result.repetitions.? == 0 or result.repetitions.? > 100) return error.InvalidNumber;
            } else if (std.mem.eql(u8, arg, "--auto")) {
                if (seen_auto) return error.DuplicateOption;
                seen_auto = true;
                result.auto = true;
            } else if (std.mem.eql(u8, arg, "--submit")) {
                if (seen_submit) return error.DuplicateOption;
                seen_submit = true;
                result.submit = true;
            } else if (std.mem.eql(u8, arg, "--resume")) {
                if (seen_resume) return error.DuplicateOption;
                seen_resume = true;
                result.resume_run = true;
            } else if (std.mem.eql(u8, arg, "--restart")) {
                if (seen_restart) return error.DuplicateOption;
                seen_restart = true;
                result.restart = true;
            } else if (std.mem.eql(u8, arg, "--show-adapter-stderr")) {
                if (seen_adapter_stderr) return error.DuplicateOption;
                seen_adapter_stderr = true;
                result.show_adapter_stderr = true;
            } else if (!try parseLockOption(args, &index, &seen_lock, &result.lock_timeout_ms)) return error.UnknownOption;
        }
        if (result.resume_run and result.restart) return error.ConflictingOptions;
        return .{ .run = result };
    }
    if (std.mem.eql(u8, command_name, "status") or std.mem.eql(u8, command_name, "verify")) {
        var result: StatusArgs = .{};
        var seen_lock = false;
        var index: usize = 1;
        while (index < args.len) : (index += 1) if (!try parseLockOption(args, &index, &seen_lock, &result.lock_timeout_ms)) return error.UnknownOption;
        return if (std.mem.eql(u8, command_name, "status")) .{ .status = result } else .{ .verify = result };
    }
    if (std.mem.eql(u8, command_name, "promote")) {
        if (args.len < 2 or !store_mod.validId(args[1])) return error.InvalidId;
        var result: PromoteArgs = .{ .run_id = args[1] };
        var seen_lock = false;
        var index: usize = 2;
        while (index < args.len) : (index += 1) if (!try parseLockOption(args, &index, &seen_lock, &result.lock_timeout_ms)) return error.UnknownOption;
        return .{ .promote = result };
    }
    if (std.mem.eql(u8, command_name, "submit") or std.mem.eql(u8, command_name, "delete-remote")) {
        if (args.len < 2 or !store_mod.validId(args[1])) return error.InvalidId;
        var result: SubmitArgs = .{ .run_id = args[1] };
        var seen_lock = false;
        var index: usize = 2;
        while (index < args.len) : (index += 1) if (!try parseLockOption(args, &index, &seen_lock, &result.lock_timeout_ms)) return error.UnknownOption;
        return if (std.mem.eql(u8, command_name, "submit"))
            .{ .submit = result }
        else
            .{ .delete_remote = result };
    }
    if (std.mem.eql(u8, command_name, "rollback")) {
        var result: RollbackArgs = .{};
        var seen_to = false;
        var seen_lock = false;
        var index: usize = 1;
        while (index < args.len) : (index += 1) {
            if (std.mem.eql(u8, args[index], "--to")) {
                if (seen_to) return error.DuplicateOption;
                seen_to = true;
                index += 1;
                if (index >= args.len or !store_mod.validId(args[index])) return error.InvalidId;
                result.to = args[index];
            } else if (!try parseLockOption(args, &index, &seen_lock, &result.lock_timeout_ms)) return error.UnknownOption;
        }
        return .{ .rollback = result };
    }
    if (std.mem.eql(u8, command_name, "hash")) {
        if (args.len != 2 or !std.fs.path.isAbsolute(args[1])) return error.InvalidPath;
        return .{ .hash = .{ .path = args[1] } };
    }
    return error.UnknownCommand;
}

fn verifyRun(
    arena: Allocator,
    io: Io,
    store: *store_mod.Store,
    config: store_mod.LoadedConfig,
    run_id: []const u8,
) !struct { run: eval.RunRecord, selected: ?[]const u8 } {
    const bytes = try store.readRun(arena, run_id);
    const run = try std.json.parseFromSliceLeaky(eval.RunRecord, arena, bytes, .{});
    try eval.validateRun(run);
    try learn_run.verifyTrialPower(io, arena, config.value, run.planned_candidates);
    if (!std.mem.eql(u8, run.config_id, &config.id) or !std.mem.eql(u8, run.harness_version, build_options.version)) return error.CohortMismatch;
    const expected_trial_id = learn_run.trialId(run.config_id, run.parent_genome_id, run.parent_generation, run.parent_transaction_id, run.nonce);
    if (!std.mem.eql(u8, run.trial_id, &expected_trial_id)) return error.TrialMismatch;
    const parent_tx_bytes = try store.readTransaction(arena, run.parent_transaction_id);
    const parent_tx = try std.json.parseFromSliceLeaky(store_mod.Transaction, arena, parent_tx_bytes, .{});
    try store_mod.validateTransaction(parent_tx);
    if (parent_tx.generation != run.parent_generation or !std.mem.eql(u8, parent_tx.next_genome_id, run.parent_genome_id)) return error.ParentTransactionMismatch;
    _ = try store.readGenome(arena, run.parent_genome_id, config.value.limits.genome_bytes);
    try learn_init.verifyPins(io, arena, config.value);

    const current_schema = std.mem.eql(u8, run.schema, eval.run_schema);
    var baseline_response: ?eval.PrimaryBaselineResponse = null;
    if (current_schema) if (run.primary_baseline) |baseline| {
        baseline_response = try primary.verifyBaseline(
            arena,
            io,
            store,
            config.value,
            &config.id,
            build_options.version,
            run.trial_id,
            run.parent_genome_id,
            config.value.evaluation_suite,
            run.repetitions,
            baseline,
        );
    };

    const computed = try arena.dupe(eval.CandidateRecord, run.candidates);
    var primary_count: usize = 0;
    for (run.candidates, computed, 0..) |candidate, *recomputed_candidate, index| {
        _ = try store.readGenome(arena, candidate.genome_id, config.value.limits.genome_bytes);
        try mutation_verify.verify(arena, store, config.value, run.trial_id, run.parent_genome_id, index, candidate);
        var excluded = false;
        if (std.mem.eql(u8, candidate.genome_id, run.parent_genome_id)) {
            excluded = true;
        } else for (run.candidates[0..index]) |prior| if (std.mem.eql(u8, candidate.genome_id, prior.genome_id)) {
            excluded = true;
            break;
        };
        if (excluded) {
            if (candidate.primary != null or candidate.holdout != null or candidate.eligible) return error.CandidateMismatch;
            continue;
        }
        const primary_record = candidate.primary orelse return error.CandidateMismatch;
        primary_count += 1;
        recomputed_candidate.primary = if (current_schema) try primary.verifyCandidate(
            arena,
            io,
            store,
            config.value,
            &config.id,
            build_options.version,
            run.trial_id,
            index,
            run.parent_genome_id,
            candidate.genome_id,
            config.value.evaluation_suite,
            run.repetitions,
            run.planned_candidates,
            run.primary_baseline orelse return error.MissingPrimaryBaseline,
            baseline_response orelse return error.MissingPrimaryBaseline,
            primary_record,
        ) else try eval.verifyComparison(arena, io, store, config.value, &config.id, build_options.version, run.trial_id, index, run.parent_genome_id, candidate.genome_id, config.value.evaluation_suite, run.repetitions, run.planned_candidates, primary_record);
        recomputed_candidate.holdout = null;
        recomputed_candidate.eligible = false;
    }
    if (current_schema and ((primary_count == 0) != (run.primary_baseline == null))) return error.PrimaryBaselineTopologyMismatch;

    const primary_winner_index = tournament.primaryWinnerIndex(run.parent_genome_id, computed);
    for (run.candidates, computed, 0..) |candidate, *recomputed_candidate, index| {
        const is_winner = primary_winner_index != null and index == primary_winner_index.?;
        if (candidate.holdout != null and !is_winner) return error.CandidateMismatch;
        if (is_winner) {
            const should_have_holdout = !current_schema or recomputed_candidate.primary.?.eligible;
            if (should_have_holdout) {
                if (config.value.holdout_suite) |suite| {
                    const holdout_record = candidate.holdout orelse return error.CandidateMismatch;
                    if (current_schema) try holdout.verify(io, store.root, arena, suite.sha256, run.trial_id);
                    recomputed_candidate.holdout = try eval.verifyComparison(arena, io, store, config.value, &config.id, build_options.version, run.trial_id, index, run.parent_genome_id, candidate.genome_id, suite, run.repetitions, 1, holdout_record);
                } else if (candidate.holdout != null) return error.CandidateMismatch;
            } else if (candidate.holdout != null) return error.CandidateMismatch;
        }
    }
    const finalized = try tournament.finalize(run.parent_genome_id, computed, config.value.holdout_suite != null);
    for (run.candidates, computed) |candidate, expected| {
        if (candidate.eligible != expected.eligible or !std.mem.eql(u8, candidate.reason, expected.reason)) return error.CandidateMismatch;
    }
    const primary_winner = if (finalized.primary_winner_index) |index| computed[index].genome_id else null;
    if ((primary_winner == null) != (run.primary_winner_genome_id == null)) return error.SelectionMismatch;
    if (primary_winner) |id| if (!std.mem.eql(u8, id, run.primary_winner_genome_id.?)) return error.SelectionMismatch;
    if ((finalized.selected_genome_id == null) != (run.selected_genome_id == null)) return error.SelectionMismatch;
    if (finalized.selected_genome_id) |id| if (!std.mem.eql(u8, id, run.selected_genome_id.?)) return error.SelectionMismatch;
    return .{ .run = run, .selected = finalized.selected_genome_id };
}

fn activeMatchesRun(active: store_mod.ActiveRef, run: eval.RunRecord) bool {
    return active.generation == run.parent_generation and
        std.mem.eql(u8, active.genome_id, run.parent_genome_id) and
        std.mem.eql(u8, active.transaction_id, run.parent_transaction_id);
}

fn runCommand(gpa: Allocator, arena: Allocator, io: Io, environ: *const std.process.Environ.Map, args: RunArgs, out: *Io.Writer) !void {
    diagnostics.setDetailed(args.show_adapter_stderr);
    defer diagnostics.setDetailed(false);
    var store = try store_mod.Store.openAt(io, Io.Dir.cwd());
    defer store.deinit();
    var lock = try store.acquireLock(args.lock_timeout_ms);
    defer lock.deinit();
    const config = try store.loadConfig(arena);
    const active = try store.loadActive(arena, config);
    try learn_init.verifyPins(io, arena, config.value);

    if (args.auto and !config.value.auto.enabled) return error.AutoNotEnabled;
    if (args.auto and config.value.holdout_suite == null) return error.AutoRequiresHoldout;
    if (args.submit) try submit.preflight(io, arena, environ);

    // The adapters see a scrubbed environment, so a `graff login` credential
    // has to be handed to the names this configuration already declares.
    var adapter_env = try credentials.withResolvedCredentials(gpa, arena, io, environ, config.value);
    defer adapter_env.deinit();

    try out.writeAll("warning: mutator and evaluator execute as your OS user; scratch isolation is not a sandbox\n");
    const result = try learn_run.execute(gpa, arena, io, &adapter_env, &store, config, active, .{
        .candidates = args.candidates,
        .repetitions = args.repetitions,
        .submit = args.submit,
        .auto = args.auto,
        .resume_run = args.resume_run,
        .restart = args.restart,
    }, out);
    if (result.selected_genome_id) |genome_id| {
        try out.print("selected {s}\n", .{genome_id});
        if (args.auto) {
            const verified = try verifyRun(arena, io, &store, config, &result.run_id);
            if (verified.selected == null or !std.mem.eql(u8, verified.selected.?, genome_id)) return error.SelectionMismatch;
            const current = try store.loadActive(arena, config);
            if (!activeMatchesRun(current.ref, verified.run)) return error.ActiveParentChanged;
            try store.activate(gpa, current.ref, &config.id, genome_id, &result.run_id, "promote", config.value.limits.genome_bytes, util.unixMs(io));
            try out.writeAll("automatic promotion committed atomically\n");
        } else try out.print("manual promotion: graff learn promote {s}\n", .{result.run_id});
    } else if (result.primary_winner_genome_id != null) {
        try out.writeAll("primary winner recorded, but it did not clear every promotion gate; active genome unchanged\n");
    } else try out.writeAll("no unique candidate produced primary evidence; active genome unchanged\n");
}

fn statusCommand(arena: Allocator, io: Io, timeout_ms: u64, out: *Io.Writer, verify_all: bool) !void {
    var store = try store_mod.Store.openAt(io, Io.Dir.cwd());
    defer store.deinit();
    var lock = try store.acquireLock(timeout_ms);
    defer lock.deinit();
    const config = try store.loadConfig(arena);
    const active = try store.loadActive(arena, config);
    const pending = try checkpoint.load(arena, &store);
    if (verify_all) {
        try learn_init.verifyPins(io, arena, config.value);
        if (pending) |item| _ = try learn_run.restorePending(arena, io, &store, config, active, item);
    }
    const Status = struct {
        schema: []const u8 = "codegraff.learn.status.v1",
        integrity: []const u8 = "ok",
        agent_name: []const u8,
        generation: u64,
        active_genome_id: []const u8,
        transaction_id: []const u8,
        config_id: []const u8,
        pins_verified: bool,
        pending_trial_id: ?[]const u8,
        pending_primary_arms: usize,
        pending_holdout_arms: usize,
        pending_verified: bool,
    };
    const value: Status = .{
        .agent_name = config.value.agent_name,
        .generation = active.ref.generation,
        .active_genome_id = active.ref.genome_id,
        .transaction_id = active.ref.transaction_id,
        .config_id = &config.id,
        .pins_verified = verify_all,
        .pending_trial_id = if (pending) |item| item.trial_id else null,
        .pending_primary_arms = if (pending) |item| countCompleted(item.candidates, false) else 0,
        .pending_holdout_arms = if (pending) |item| countCompleted(item.candidates, true) else 0,
        .pending_verified = pending == null or verify_all,
    };
    var stringify: std.json.Stringify = .{ .writer = out };
    try stringify.write(value);
    try out.writeByte('\n');
}

fn countCompleted(candidates: []const eval.CandidateRecord, holdouts: bool) usize {
    var count: usize = 0;
    for (candidates) |candidate| if (if (holdouts) candidate.holdout != null else candidate.primary != null) {
        count += 1;
    };
    return count;
}

fn promoteCommand(gpa: Allocator, arena: Allocator, io: Io, args: PromoteArgs, out: *Io.Writer) !void {
    var store = try store_mod.Store.openAt(io, Io.Dir.cwd());
    defer store.deinit();
    var lock = try store.acquireLock(args.lock_timeout_ms);
    defer lock.deinit();
    const config = try store.loadConfig(arena);
    const active = try store.loadActive(arena, config);
    const verified = try verifyRun(arena, io, &store, config, args.run_id);
    const selected = verified.selected orelse return error.NoPromotableCandidate;
    if (!activeMatchesRun(active.ref, verified.run)) return error.ActiveParentChanged;
    try store.activate(gpa, active.ref, &config.id, selected, args.run_id, "promote", config.value.limits.genome_bytes, util.unixMs(io));
    try out.print("promoted {s} from run {s}\n", .{ selected, args.run_id });
}

fn submitCommand(gpa: Allocator, arena: Allocator, io: Io, environ: *const std.process.Environ.Map, args: SubmitArgs, out: *Io.Writer) !void {
    var store = try store_mod.Store.openAt(io, Io.Dir.cwd());
    defer store.deinit();
    var lock = try store.acquireLock(args.lock_timeout_ms);
    defer lock.deinit();
    const config = try store.loadConfig(arena);
    const verified = try verifyRun(arena, io, &store, config, args.run_id);
    const sent = try submit.submitVerifiedRun(io, gpa, arena, environ, config.value, args.run_id, verified.run);
    try out.print("submitted {d} signed aggregate grade(s) for run {s}; prompt text stayed local\n", .{ sent.grades, args.run_id });
}

fn ancestorTarget(arena: Allocator, store: *store_mod.Store, active: store_mod.LoadedActive, requested: ?[]const u8) ![]const u8 {
    // After a rollback, previous_genome_id names the genome just rolled AWAY
    // from, so a default-target rollback would move forward and reinstate it.
    // Require an explicit --to instead of silently undoing the rollback.
    if (requested == null and std.mem.eql(u8, active.transaction.operation, "rollback"))
        return error.RollbackNeedsExplicitTarget;
    const default_target = active.transaction.previous_genome_id orelse return error.NoRollbackAvailable;
    const target = requested orelse default_target;
    if (std.mem.eql(u8, target, active.ref.genome_id)) return error.AlreadyActive;
    var tx = active.transaction;
    while (tx.generation > 0) {
        if (tx.previous_genome_id) |genome_id| if (std.mem.eql(u8, genome_id, target)) return target;
        const previous_id = tx.previous_transaction_id orelse return error.BrokenTransactionChain;
        const previous_bytes = try store.readTransaction(arena, previous_id);
        const previous = try std.json.parseFromSliceLeaky(store_mod.Transaction, arena, previous_bytes, .{});
        try store_mod.validateTransaction(previous);
        const expected_generation = std.math.add(u64, previous.generation, 1) catch return error.BrokenTransactionChain;
        if (expected_generation != tx.generation or !std.mem.eql(u8, previous.next_genome_id, tx.previous_genome_id.?)) return error.BrokenTransactionChain;
        tx = previous;
    }
    return error.NotInAncestry;
}

fn rollbackCommand(gpa: Allocator, arena: Allocator, io: Io, args: RollbackArgs, out: *Io.Writer) !void {
    var store = try store_mod.Store.openAt(io, Io.Dir.cwd());
    defer store.deinit();
    var lock = try store.acquireLock(args.lock_timeout_ms);
    defer lock.deinit();
    const config = try store.loadConfig(arena);
    const active = try store.loadActive(arena, config);
    const target = try ancestorTarget(arena, &store, active, args.to);
    _ = try store.readGenome(arena, target, config.value.limits.genome_bytes);
    try store.activate(gpa, active.ref, &config.id, target, null, "rollback", config.value.limits.genome_bytes, util.unixMs(io));
    try out.print("rolled back to {s}\n", .{target});
}

pub fn command(io: Io, gpa: Allocator, arena: Allocator, init: std.process.Init, argv: []const []const u8) !void {
    const parsed = try parse(argv);
    var out_buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};
    switch (parsed) {
        .help => try out.writeAll(usage),
        .init => |args| if (args.config == null)
            try learn_init.zeroConfig(gpa, arena, io, init.environ_map, args, out)
        else
            try learn_init.fromPaths(gpa, arena, io, args, out),
        .run => |args| try runCommand(gpa, arena, io, init.environ_map, args, out),
        .status => |args| try statusCommand(arena, io, args.lock_timeout_ms, out, false),
        .submit => |args| try submitCommand(gpa, arena, io, init.environ_map, args, out),
        .delete_remote => |args| try learn_delete.command(io, gpa, arena, init.environ_map, args.run_id, args.lock_timeout_ms, out),
        .verify => |args| try statusCommand(arena, io, args.lock_timeout_ms, out, true),
        .promote => |args| try promoteCommand(gpa, arena, io, args, out),
        .rollback => |args| try rollbackCommand(gpa, arena, io, args, out),
        .hash => |args| {
            const digest = try store_mod.hashFileNoFollow(io, args.path);
            try out.print("{s}\n", .{digest});
        },
    }
    try out.flush();
}

test "learn parser preserves strict command-local options" {
    const parsed = try parse(&.{ "run", "--candidates", "4", "--repetitions", "2", "--resume", "--submit", "--auto", "--show-adapter-stderr", "--lock-timeout-ms", "50" });
    try std.testing.expectEqual(@as(usize, 4), parsed.run.candidates.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.run.repetitions.?);
    try std.testing.expect(parsed.run.auto);
    try std.testing.expect(parsed.run.submit);
    try std.testing.expect(parsed.run.resume_run);
    try std.testing.expect(parsed.run.show_adapter_stderr);
    try std.testing.expectEqual(@as(u64, 50), parsed.run.lock_timeout_ms);
    try std.testing.expectError(error.DuplicateOption, parse(&.{ "run", "--auto", "--auto" }));
    try std.testing.expectError(error.DuplicateOption, parse(&.{ "run", "--show-adapter-stderr", "--show-adapter-stderr" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "run", "--mystery" }));
    try std.testing.expectError(error.ConflictingOptions, parse(&.{ "run", "--resume", "--restart" }));
    try std.testing.expectError(error.InvalidId, parse(&.{ "promote", "abcd" }));
}
