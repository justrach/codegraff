//! Persistent schemas and value types for the local learning store.

const std = @import("std");

pub const config_schema = "codegraff.learn.config.v1";
pub const suite_schema = "codegraff.learn.suite.v1";
pub const active_schema = "codegraff.learn.active.v1";
pub const transaction_schema = "codegraff.learn.transaction.v1";
pub const version_bytes = "1\n";

pub const max_config_bytes: usize = 1 << 20;
pub const max_record_bytes: usize = 8 << 20;
pub const max_program_bytes: u64 = 128 << 20;
pub const max_suite_bytes: usize = 8 << 20;
pub const max_pairs: usize = 4096;

pub const PinnedFile = struct {
    path: []const u8,
    sha256: []const u8,
};

pub const Program = struct {
    program: []const u8,
    sha256: []const u8,
    args: []const []const u8 = &.{},
    inputs: []const PinnedFile = &.{},
    pass_env: []const []const u8 = &.{},
};

pub const Suite = struct {
    path: []const u8,
    sha256: []const u8,
};

pub const Limits = struct {
    genome_bytes: usize = 1 << 20,
    request_bytes: usize = 1 << 20,
    response_bytes: usize = 4 << 20,
    stdout_bytes: usize = 64 << 10,
    stderr_bytes: usize = 64 << 10,
    mutator_timeout_ms: u64 = 300_000,
    evaluator_timeout_ms: u64 = 1_800_000,
};

pub const PromotionMode = enum {
    correctness,
    economy,
};

pub const Gate = struct {
    alpha_ppm: u32 = 50_000,
    minimum_delta_ppm: u32 = 50_000,
    minimum_pairs: usize = 20,
    /// Allow an equally correct candidate to clear the gate through a
    /// statistically significant reduction in measured tool calls.
    economy_gate_enabled: bool = false,
    /// Pre-registered superiority endpoint. Safety and minimum sample gates
    /// remain mandatory in either mode.
    promotion_mode: PromotionMode = .correctness,
    minimum_tool_reduction_ppm: u32 = 100_000,
    /// Minimum number of case-level tool-call wins plus losses. Ties carry no
    /// information for the exact directional economy test.
    minimum_economy_pairs: usize = 8,
    /// Fail the run before any evaluation unless every requested arm produced
    /// a unique genome distinct from the parent.
    require_all_candidates: bool = false,
    default_candidates: usize = 1,
    default_repetitions: usize = 1,
};

pub const AutoPolicy = struct {
    enabled: bool = false,
};

pub const Cohort = struct {
    provider: []const u8,
    model: []const u8,
    task_family: []const u8,
    adapter_version: []const u8,
    verifier_version: []const u8,
};

pub const Config = struct {
    schema: []const u8,
    agent_name: []const u8,
    agent_description: []const u8 = "locally learned prompt policy",
    mutation_instruction: []const u8,
    mutator: Program,
    evaluator: Program,
    evaluation_suite: Suite,
    holdout_suite: ?Suite = null,
    limits: Limits = .{},
    gate: Gate = .{},
    auto: AutoPolicy = .{},
    cohort: Cohort,
};

pub const SuiteCase = struct {
    id: []const u8,
    critical: bool = false,
    payload: std.json.Value = .null,
};

pub const SuiteManifest = struct {
    schema: []const u8,
    suite_id: []const u8,
    cases: []const SuiteCase,
};

pub const ActiveRef = struct {
    schema: []const u8,
    config_id: []const u8,
    generation: u64,
    genome_id: []const u8,
    transaction_id: []const u8,
};

pub const Transaction = struct {
    schema: []const u8,
    generation: u64,
    operation: []const u8,
    previous_genome_id: ?[]const u8,
    next_genome_id: []const u8,
    run_id: ?[]const u8,
    previous_transaction_id: ?[]const u8,
    created_unix_ms: i64,
};

pub const LoadedConfig = struct {
    value: Config,
    id: [64]u8,
    bytes: []const u8,
};

pub const LoadedActive = struct {
    ref: ActiveRef,
    transaction: Transaction,
    genome: []const u8,
};

pub const ActiveAgent = struct {
    name: []const u8,
    description: []const u8,
    prompt: []const u8,
    genome_id: []const u8,
    generation: u64,
};
