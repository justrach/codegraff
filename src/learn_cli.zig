//! `graff learn`: a local-first parent → mutate → paired-evaluate → select
//! engine with immutable evidence, manual promotion by default, an explicit
//! two-key automatic gate, and atomic active-reference rollback.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

const store_mod = @import("learn_store.zig");
const eval = @import("learn_eval.zig");
const util = @import("util.zig");

pub const usage =
    \\graff learn — safe local prompt-policy learning
    \\
    \\usage:
    \\  graff learn init --parent PATH --config PATH
    \\  graff learn run [--candidates N] [--repetitions N] [--auto] [--lock-timeout-ms N]
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

const InitArgs = struct { parent: []const u8, config: []const u8 };
const RunArgs = struct { candidates: ?usize = null, repetitions: ?usize = null, auto: bool = false, lock_timeout_ms: u64 = 0 };
const StatusArgs = struct { lock_timeout_ms: u64 = 0 };
const PromoteArgs = struct { run_id: []const u8, lock_timeout_ms: u64 = 0 };
const RollbackArgs = struct { to: ?[]const u8 = null, lock_timeout_ms: u64 = 0 };
const HashArgs = struct { path: []const u8 };

pub const Parsed = union(enum) {
    help,
    init: InitArgs,
    run: RunArgs,
    status: StatusArgs,
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
            } else return error.UnknownOption;
        }
        return .{ .init = .{ .parent = parent orelse return error.MissingOption, .config = config orelse return error.MissingOption } };
    }
    if (std.mem.eql(u8, command_name, "run")) {
        var result: RunArgs = .{};
        var seen_candidates = false;
        var seen_repetitions = false;
        var seen_auto = false;
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
            } else if (!try parseLockOption(args, &index, &seen_lock, &result.lock_timeout_ms)) return error.UnknownOption;
        }
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

fn verifyPins(io: Io, arena: Allocator, config: store_mod.Config) !void {
    try store_mod.verifyProgram(io, config.mutator);
    try store_mod.verifyProgram(io, config.evaluator);
    _ = try store_mod.loadSuite(io, arena, config.evaluation_suite);
    if (config.holdout_suite) |suite| _ = try store_mod.loadSuite(io, arena, suite);
}

fn trialId(
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

fn betterCandidate(a: eval.CandidateRecord, b: eval.CandidateRecord) bool {
    const ac = a.primary.?;
    const bc = b.primary.?;
    if (ac.delta_ppm != bc.delta_ppm) return ac.delta_ppm > bc.delta_ppm;
    if (ac.p_value_ppb != bc.p_value_ppb) return ac.p_value_ppb < bc.p_value_ppb;
    if (ac.mean_score_delta_ppm != bc.mean_score_delta_ppm) return ac.mean_score_delta_ppm > bc.mean_score_delta_ppm;
    if (ac.child_cost_micros != bc.child_cost_micros) return ac.child_cost_micros < bc.child_cost_micros;
    return std.mem.order(u8, a.genome_id, b.genome_id) == .lt;
}

fn selectCandidate(candidates: []const eval.CandidateRecord) ?[]const u8 {
    var selected: ?usize = null;
    for (candidates, 0..) |candidate, index| {
        if (!candidate.eligible) continue;
        if (selected == null or betterCandidate(candidate, candidates[selected.?])) selected = index;
    }
    return if (selected) |index| candidates[index].genome_id else null;
}

fn verifyMutationEvidence(arena: Allocator, store: *store_mod.Store, config: store_mod.Config, run: eval.RunRecord, index: usize, candidate: eval.CandidateRecord) !void {
    const expected_seed = eval.candidateSeed(run.trial_id, index);
    if (!std.mem.eql(u8, candidate.mutation.seed, &expected_seed)) return error.MutationMismatch;
    const request_bytes = try store.readEvidence(arena, candidate.mutation.request_evidence_id, config.limits.request_bytes);
    const response_bytes = try store.readEvidence(arena, candidate.mutation.response_evidence_id, config.limits.response_bytes);
    const request = try std.json.parseFromSliceLeaky(eval.MutationRequest, arena, request_bytes, .{});
    const response = try std.json.parseFromSliceLeaky(eval.MutationResponse, arena, response_bytes, .{});
    if (!std.mem.eql(u8, request.schema, eval.mutation_request_schema) or
        !std.mem.eql(u8, request.trial_id, run.trial_id) or request.candidate_index != index or
        !std.mem.eql(u8, request.seed, &expected_seed) or !std.mem.eql(u8, request.parent.id, run.parent_genome_id) or
        !std.mem.eql(u8, request.parent.path, "parent.genome") or !std.mem.eql(u8, request.child_path, "child.genome") or
        request.maximum_bytes != config.limits.genome_bytes or !std.mem.eql(u8, request.instruction, config.mutation_instruction)) return error.MutationMismatch;
    if (!std.mem.eql(u8, response.schema, eval.mutation_response_schema) or
        !std.mem.eql(u8, response.trial_id, run.trial_id) or response.candidate_index != index or
        !std.mem.eql(u8, response.parent_id, run.parent_genome_id) or !std.mem.eql(u8, response.child_path, "child.genome") or
        !store_mod.validId(response.child_sha256) or response.description.len > 512 or
        !std.unicode.utf8ValidateSlice(response.description) or std.mem.indexOfScalar(u8, response.description, 0) != null) return error.MutationMismatch;
    const child = try store.readGenome(arena, candidate.genome_id, config.limits.genome_bytes);
    const child_sha256 = store_mod.rawSha256(child);
    if (!std.mem.eql(u8, response.child_sha256, &child_sha256)) return error.MutationOutputMismatch;
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
    if (!std.mem.eql(u8, run.config_id, &config.id) or !std.mem.eql(u8, run.harness_version, build_options.version)) return error.CohortMismatch;
    const expected_trial_id = trialId(run.config_id, run.parent_genome_id, run.parent_generation, run.parent_transaction_id, run.nonce);
    if (!std.mem.eql(u8, run.trial_id, &expected_trial_id)) return error.TrialMismatch;
    const parent_tx_bytes = try store.readTransaction(arena, run.parent_transaction_id);
    const parent_tx = try std.json.parseFromSliceLeaky(store_mod.Transaction, arena, parent_tx_bytes, .{});
    try store_mod.validateTransaction(parent_tx);
    if (parent_tx.generation != run.parent_generation or !std.mem.eql(u8, parent_tx.next_genome_id, run.parent_genome_id)) return error.ParentTransactionMismatch;
    _ = try store.readGenome(arena, run.parent_genome_id, config.value.limits.genome_bytes);
    try verifyPins(io, arena, config.value);

    for (run.candidates, 0..) |candidate, index| {
        _ = try store.readGenome(arena, candidate.genome_id, config.value.limits.genome_bytes);
        try verifyMutationEvidence(arena, store, config.value, run, index, candidate);
        var duplicate_reason: ?[]const u8 = null;
        if (std.mem.eql(u8, candidate.genome_id, run.parent_genome_id)) duplicate_reason = "identical_parent";
        for (run.candidates[0..index]) |prior| if (std.mem.eql(u8, candidate.genome_id, prior.genome_id)) {
            duplicate_reason = "duplicate_candidate";
            break;
        };
        if (duplicate_reason) |reason| {
            if (candidate.primary != null or candidate.holdout != null or candidate.eligible or !std.mem.eql(u8, candidate.reason, reason)) return error.CandidateMismatch;
            continue;
        }
        const primary_record = candidate.primary orelse return error.CandidateMismatch;
        const primary = try eval.verifyComparison(arena, io, store, config.value, &config.id, build_options.version, run.trial_id, index, run.parent_genome_id, candidate.genome_id, config.value.evaluation_suite, run.repetitions, run.planned_candidates, primary_record);
        var eligible = primary.eligible;
        var reason = primary.reason;
        if (primary.eligible) {
            if (config.value.holdout_suite) |suite| {
                const holdout_record = candidate.holdout orelse return error.CandidateMismatch;
                const holdout = try eval.verifyComparison(arena, io, store, config.value, &config.id, build_options.version, run.trial_id, index, run.parent_genome_id, candidate.genome_id, suite, run.repetitions, run.planned_candidates, holdout_record);
                eligible = holdout.eligible;
                reason = if (holdout.eligible) "eligible" else "holdout_rejected";
            } else if (candidate.holdout != null) return error.CandidateMismatch;
        } else if (candidate.holdout != null) return error.CandidateMismatch;
        if (candidate.eligible != eligible or !std.mem.eql(u8, candidate.reason, reason)) return error.CandidateMismatch;
    }
    const selected = selectCandidate(run.candidates);
    if ((selected == null) != (run.selected_genome_id == null)) return error.SelectionMismatch;
    if (selected) |id| if (!std.mem.eql(u8, id, run.selected_genome_id.?)) return error.SelectionMismatch;
    return .{ .run = run, .selected = selected };
}

fn activeMatchesRun(active: store_mod.ActiveRef, run: eval.RunRecord) bool {
    return active.generation == run.parent_generation and
        std.mem.eql(u8, active.genome_id, run.parent_genome_id) and
        std.mem.eql(u8, active.transaction_id, run.parent_transaction_id);
}

fn initCommand(gpa: Allocator, arena: Allocator, io: Io, args: InitArgs, out: *Io.Writer) !void {
    const config_bytes = try store_mod.readFileNoFollow(io, Io.Dir.cwd(), args.config, arena, store_mod.max_config_bytes);
    const config = try std.json.parseFromSliceLeaky(store_mod.Config, arena, config_bytes, .{});
    try store_mod.validateConfig(config);
    try verifyPins(io, arena, config);
    const parent = try store_mod.readFileNoFollow(io, Io.Dir.cwd(), args.parent, arena, config.limits.genome_bytes);

    var store = try store_mod.Store.initAt(io, Io.Dir.cwd());
    defer store.deinit();
    var lock = try store.acquireLock(0);
    defer lock.deinit();
    const genome_id = try store.bootstrap(gpa, arena, config_bytes, parent, util.unixMs(io));
    try out.print("initialized learned agent '{s}'\nactive genome {s}\n", .{ config.agent_name, genome_id });
}

fn runCommand(gpa: Allocator, arena: Allocator, io: Io, environ: *const std.process.Environ.Map, args: RunArgs, out: *Io.Writer) !void {
    var store = try store_mod.Store.openAt(io, Io.Dir.cwd());
    defer store.deinit();
    var lock = try store.acquireLock(args.lock_timeout_ms);
    defer lock.deinit();
    const config = try store.loadConfig(arena);
    const active = try store.loadActive(arena, config);
    try verifyPins(io, arena, config.value);

    const candidate_count = args.candidates orelse config.value.gate.default_candidates;
    const repetitions = args.repetitions orelse config.value.gate.default_repetitions;
    if (candidate_count == 0 or candidate_count > 16 or repetitions == 0 or repetitions > 100) return error.InvalidNumber;
    if (args.auto and !config.value.auto.enabled) return error.AutoNotEnabled;
    if (args.auto and config.value.holdout_suite == null) return error.AutoRequiresHoldout;

    try out.writeAll("warning: mutator and evaluator execute as your OS user; scratch isolation is not a sandbox\n");
    const nonce = store_mod.randomId(io);
    const trial_id = trialId(&config.id, active.ref.genome_id, active.ref.generation, active.ref.transaction_id, &nonce);
    const candidates = try arena.alloc(eval.CandidateRecord, candidate_count);

    for (candidates, 0..) |*candidate, index| {
        var mutation = try eval.mutate(gpa, arena, io, environ, &store, config.value, &trial_id, index, active.ref.genome_id, active.genome);
        defer gpa.free(mutation.prompt);
        const genome_id = try arena.dupe(u8, &mutation.genome_id);
        candidate.* = .{
            .genome_id = genome_id,
            .mutation = mutation.record,
            .primary = null,
            .holdout = null,
            .eligible = false,
            .reason = "unevaluated",
        };
        if (std.mem.eql(u8, genome_id, active.ref.genome_id)) {
            candidate.reason = "identical_parent";
            continue;
        }
        var duplicate = false;
        for (candidates[0..index]) |prior| if (std.mem.eql(u8, genome_id, prior.genome_id)) {
            duplicate = true;
            break;
        };
        if (duplicate) {
            candidate.reason = "duplicate_candidate";
            continue;
        }

        candidate.primary = try eval.evaluate(gpa, arena, io, environ, &store, config.value, &config.id, build_options.version, &trial_id, index, active.ref.genome_id, active.genome, genome_id, mutation.prompt, config.value.evaluation_suite, repetitions, candidate_count);
        if (!candidate.primary.?.eligible) {
            candidate.reason = candidate.primary.?.reason;
            continue;
        }
        if (config.value.holdout_suite) |suite| {
            candidate.holdout = try eval.evaluate(gpa, arena, io, environ, &store, config.value, &config.id, build_options.version, &trial_id, index, active.ref.genome_id, active.genome, genome_id, mutation.prompt, suite, repetitions, candidate_count);
            if (!candidate.holdout.?.eligible) {
                candidate.reason = "holdout_rejected";
                continue;
            }
        }
        candidate.eligible = true;
        candidate.reason = "eligible";
    }

    try verifyPins(io, arena, config.value);
    const selected = selectCandidate(candidates);
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
        .auto_requested = args.auto,
        .candidates = candidates,
        .selected_genome_id = selected,
    };
    const record_bytes = try store_mod.jsonBytes(gpa, record);
    defer gpa.free(record_bytes);
    if (record_bytes.len > store_mod.max_record_bytes) return error.RunTooLarge;
    const run_id = try store.writeRun(gpa, record_bytes);
    try out.print("run {s}\n", .{run_id});
    if (selected) |genome_id| {
        try out.print("selected {s}\n", .{genome_id});
        if (args.auto) {
            const verified = try verifyRun(arena, io, &store, config, &run_id);
            if (verified.selected == null or !std.mem.eql(u8, verified.selected.?, genome_id)) return error.SelectionMismatch;
            const current = try store.loadActive(arena, config);
            if (!activeMatchesRun(current.ref, record)) return error.ActiveParentChanged;
            try store.activate(gpa, current.ref, &config.id, genome_id, &run_id, "promote", config.value.limits.genome_bytes, util.unixMs(io));
            try out.writeAll("automatic promotion committed atomically\n");
        } else try out.print("manual promotion: graff learn promote {s}\n", .{run_id});
    } else try out.writeAll("no candidate passed all promotion gates; active genome unchanged\n");
}

fn statusCommand(arena: Allocator, io: Io, timeout_ms: u64, out: *Io.Writer, verify_all: bool) !void {
    var store = try store_mod.Store.openAt(io, Io.Dir.cwd());
    defer store.deinit();
    var lock = try store.acquireLock(timeout_ms);
    defer lock.deinit();
    const config = try store.loadConfig(arena);
    const active = try store.loadActive(arena, config);
    if (verify_all) try verifyPins(io, arena, config.value);
    const Status = struct {
        schema: []const u8 = "codegraff.learn.status.v1",
        integrity: []const u8 = "ok",
        agent_name: []const u8,
        generation: u64,
        active_genome_id: []const u8,
        transaction_id: []const u8,
        config_id: []const u8,
        pins_verified: bool,
    };
    const value: Status = .{
        .agent_name = config.value.agent_name,
        .generation = active.ref.generation,
        .active_genome_id = active.ref.genome_id,
        .transaction_id = active.ref.transaction_id,
        .config_id = &config.id,
        .pins_verified = verify_all,
    };
    var stringify: std.json.Stringify = .{ .writer = out };
    try stringify.write(value);
    try out.writeByte('\n');
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

fn ancestorTarget(arena: Allocator, store: *store_mod.Store, active: store_mod.LoadedActive, requested: ?[]const u8) ![]const u8 {
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
        .init => |args| try initCommand(gpa, arena, io, args, out),
        .run => |args| try runCommand(gpa, arena, io, init.environ_map, args, out),
        .status => |args| try statusCommand(arena, io, args.lock_timeout_ms, out, false),
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
    const parsed = try parse(&.{ "run", "--candidates", "4", "--repetitions", "2", "--auto", "--lock-timeout-ms", "50" });
    try std.testing.expectEqual(@as(usize, 4), parsed.run.candidates.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.run.repetitions.?);
    try std.testing.expect(parsed.run.auto);
    try std.testing.expectEqual(@as(u64, 50), parsed.run.lock_timeout_ms);
    try std.testing.expectError(error.DuplicateOption, parse(&.{ "run", "--auto", "--auto" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "run", "--mystery" }));
    try std.testing.expectError(error.InvalidId, parse(&.{ "promote", "abcd" }));
}

test "trial IDs bind the exact active generation and transaction" {
    const original = trialId("config", "parent", 7, "transaction-a", "nonce");
    const identical = trialId("config", "parent", 7, "transaction-a", "nonce");
    const later_generation = trialId("config", "parent", 8, "transaction-a", "nonce");
    const later_transaction = trialId("config", "parent", 7, "transaction-b", "nonce");
    try std.testing.expectEqualSlices(u8, &original, &identical);
    try std.testing.expect(!std.mem.eql(u8, &original, &later_generation));
    try std.testing.expect(!std.mem.eql(u8, &original, &later_transaction));
}

test "learning selection is deterministic and correctness-first" {
    const mutation: eval.MutationRecord = .{ .seed = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .request_evidence_id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .response_evidence_id = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" };
    const base: eval.ComparisonRecord = .{ .suite_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", .request_evidence_id = mutation.request_evidence_id, .response_evidence_id = mutation.response_evidence_id, .pairs = 20, .statistical_units = 20, .parent_passes = 10, .child_passes = 15, .wins = 5, .losses = 0, .ties = 15, .critical_regressions = 0, .delta_ppm = 250_000, .mean_score_delta_ppm = 100_000, .p_value_ppb = 10_000_000, .parent_cost_micros = 100, .child_cost_micros = 100, .eligible = true, .reason = "eligible" };
    var candidates = [_]eval.CandidateRecord{
        .{ .genome_id = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", .mutation = mutation, .primary = base, .holdout = null, .eligible = true, .reason = "eligible" },
        .{ .genome_id = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", .mutation = mutation, .primary = base, .holdout = null, .eligible = false, .reason = "holdout_rejected" },
    };
    try std.testing.expectEqualStrings(candidates[0].genome_id, selectCandidate(&candidates).?);
    candidates[1].eligible = true;
    candidates[1].primary.?.delta_ppm = 300_000;
    try std.testing.expectEqualStrings(candidates[1].genome_id, selectCandidate(&candidates).?);
}
