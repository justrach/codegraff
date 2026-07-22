//! Input validation for the local learning store: id/name/text/env-name
//! shape checks plus config/program/suite validation. Split out of
//! learn_store.zig (600-line goal); learn_store.zig re-exports the public
//! entry points so external call sites are unchanged.

const std = @import("std");
const store = @import("learn_store_types.zig");

const Config = store.Config;
const Program = store.Program;
const Suite = store.Suite;
const SuiteManifest = store.SuiteManifest;
const config_schema = store.config_schema;
const max_record_bytes = store.max_record_bytes;
const max_pairs = store.max_pairs;
const suite_schema = store.suite_schema;

pub fn validId(id: []const u8) bool {
    if (id.len != 64) return false;
    for (id) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

pub fn validName(value: []const u8, max: usize) bool {
    if (value.len == 0 or value.len > max or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
    }
    return !std.mem.eql(u8, value, ".") and !std.mem.eql(u8, value, "..");
}

pub fn validText(value: []const u8, max: usize) bool {
    return value.len > 0 and value.len <= max and std.unicode.utf8ValidateSlice(value) and std.mem.indexOfScalar(u8, value, 0) == null;
}

pub fn validEnvName(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    if (!(std.ascii.isAlphabetic(value[0]) or value[0] == '_')) return false;
    for (value[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    // Case-insensitive: Windows environment lookups are case-insensitive,
    // and a case-variant of a denied name must not slip through. PATH and
    // the dynamic-linker variables would otherwise let a config override the
    // scrubbed execution environment that buildEnvironment constructs.
    return !std.ascii.eqlIgnoreCase(value, "HOME") and
        !std.ascii.eqlIgnoreCase(value, "USERPROFILE") and
        !std.ascii.eqlIgnoreCase(value, "TMPDIR") and
        !std.ascii.eqlIgnoreCase(value, "TMP") and
        !std.ascii.eqlIgnoreCase(value, "TEMP") and
        !std.ascii.eqlIgnoreCase(value, "PATH") and
        !std.ascii.eqlIgnoreCase(value, "COMSPEC") and
        !std.ascii.eqlIgnoreCase(value, "SYSTEMROOT") and
        !std.ascii.startsWithIgnoreCase(value, "LD_") and
        !std.ascii.startsWithIgnoreCase(value, "DYLD_") and
        !std.mem.startsWith(u8, value, "GRAFF_LEARN_");
}

pub fn validateConfig(config: Config) !void {
    if (!std.mem.eql(u8, config.schema, config_schema)) return error.UnsupportedSchema;
    if (!validName(config.agent_name, 64)) return error.InvalidAgentName;
    if (!validText(config.agent_description, 512)) return error.InvalidDescription;
    if (!validText(config.mutation_instruction, 4096)) return error.InvalidMutationInstruction;
    try validateProgram(config.mutator);
    try validateProgram(config.evaluator);
    try validateSuitePin(config.evaluation_suite);
    if (config.holdout_suite) |suite| try validateSuitePin(suite);

    if (config.limits.genome_bytes == 0 or config.limits.genome_bytes > 8 << 20) return error.InvalidLimit;
    if (config.limits.request_bytes < 1024 or config.limits.request_bytes > max_record_bytes) return error.InvalidLimit;
    if (config.limits.response_bytes < 1024 or config.limits.response_bytes > max_record_bytes) return error.InvalidLimit;
    if (config.limits.stdout_bytes > 1 << 20 or config.limits.stderr_bytes > 1 << 20) return error.InvalidLimit;
    if (config.limits.mutator_timeout_ms == 0 or config.limits.mutator_timeout_ms > 3_600_000) return error.InvalidLimit;
    if (config.limits.evaluator_timeout_ms == 0 or config.limits.evaluator_timeout_ms > 3_600_000) return error.InvalidLimit;

    if (config.gate.alpha_ppm == 0 or config.gate.alpha_ppm > 500_000) return error.InvalidGate;
    if (config.gate.minimum_delta_ppm > 1_000_000) return error.InvalidGate;
    if (config.gate.minimum_pairs == 0 or config.gate.minimum_pairs > max_pairs) return error.InvalidGate;
    if (config.gate.minimum_tool_reduction_ppm > 1_000_000) return error.InvalidGate;
    if (config.gate.minimum_economy_pairs == 0 or config.gate.minimum_economy_pairs > max_pairs) return error.InvalidGate;
    if (config.gate.promotion_mode == .economy and !config.gate.economy_gate_enabled) return error.InvalidGate;
    if (config.gate.default_candidates == 0 or config.gate.default_candidates > 16) return error.InvalidGate;
    if (config.gate.default_repetitions == 0 or config.gate.default_repetitions > 100) return error.InvalidGate;
    if (config.auto.enabled and config.holdout_suite == null) return error.AutoRequiresHoldout;

    inline for (.{ config.cohort.provider, config.cohort.model, config.cohort.task_family, config.cohort.adapter_version, config.cohort.verifier_version }) |field| {
        if (!validText(field, 256)) return error.InvalidCohort;
    }
}

pub fn validateProgram(program: Program) !void {
    if (!std.fs.path.isAbsolute(program.program) or !validText(program.program, std.fs.max_path_bytes)) return error.InvalidProgramPath;
    if (!validId(program.sha256)) return error.InvalidDigest;
    if (program.args.len > 64 or program.inputs.len > 64 or program.pass_env.len > 32) return error.InvalidProgramConfig;
    for (program.args) |arg| if (arg.len > 4096 or std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidProgramConfig;
    for (program.inputs, 0..) |input, i| {
        if (!std.fs.path.isAbsolute(input.path) or !validText(input.path, std.fs.max_path_bytes) or !validId(input.sha256)) return error.InvalidProgramConfig;
        for (program.inputs[0..i]) |prior| if (std.mem.eql(u8, prior.path, input.path)) return error.DuplicateProgramInput;
    }
    for (program.pass_env, 0..) |name, i| {
        if (!validEnvName(name)) return error.InvalidEnvironmentName;
        for (program.pass_env[0..i]) |prior| if (std.mem.eql(u8, prior, name)) return error.DuplicateEnvironmentName;
    }
}

pub fn validateSuitePin(suite: Suite) !void {
    if (!std.fs.path.isAbsolute(suite.path) or !validText(suite.path, std.fs.max_path_bytes)) return error.InvalidSuitePath;
    if (!validId(suite.sha256)) return error.InvalidDigest;
}

pub fn validateSuite(manifest: SuiteManifest) !void {
    if (!std.mem.eql(u8, manifest.schema, suite_schema)) return error.UnsupportedSuiteSchema;
    if (!validName(manifest.suite_id, 128)) return error.InvalidSuiteId;
    if (manifest.cases.len == 0 or manifest.cases.len > max_pairs) return error.InvalidSuiteCases;
    for (manifest.cases, 0..) |case, i| {
        if (!validName(case.id, 128)) return error.InvalidCaseId;
        for (manifest.cases[0..i]) |prior| if (std.mem.eql(u8, prior.id, case.id)) return error.DuplicateCaseId;
    }
}

pub fn validateTransaction(tx: store.Transaction) !void {
    if (!std.mem.eql(u8, tx.schema, store.transaction_schema)) return error.UnsupportedSchema;
    if (!std.mem.eql(u8, tx.operation, "init") and !std.mem.eql(u8, tx.operation, "promote") and !std.mem.eql(u8, tx.operation, "rollback")) return error.InvalidOperation;
    if (!validId(tx.next_genome_id)) return error.InvalidId;
    if (tx.previous_genome_id) |id| if (!validId(id)) return error.InvalidId;
    if (tx.run_id) |id| if (!validId(id)) return error.InvalidId;
    if (tx.previous_transaction_id) |id| if (!validId(id)) return error.InvalidId;
    if (std.mem.eql(u8, tx.operation, "init")) {
        if (tx.generation != 0 or tx.previous_genome_id != null or tx.previous_transaction_id != null or tx.run_id != null) return error.InvalidTransaction;
    } else if (tx.generation == 0 or tx.previous_genome_id == null or tx.previous_transaction_id == null) return error.InvalidTransaction;
    if (std.mem.eql(u8, tx.operation, "promote") and tx.run_id == null) return error.InvalidTransaction;
    if (std.mem.eql(u8, tx.operation, "rollback") and tx.run_id != null) return error.InvalidTransaction;
}
