//! Wire and persisted record types for the local learning engine.

pub const mutation_request_schema = "codegraff.learn.mutation.request.v1";
pub const mutation_response_schema = "codegraff.learn.mutation.response.v1";
pub const evaluation_request_schema = "codegraff.learn.evaluation.request.v1";
pub const evaluation_response_schema = "codegraff.learn.evaluation.response.v1";
pub const primary_baseline_request_schema = "codegraff.learn.primary-baseline.request.v1";
pub const primary_baseline_response_schema = "codegraff.learn.primary-baseline.response.v1";
pub const primary_evaluation_request_schema = "codegraff.learn.primary-evaluation.request.v1";
pub const primary_evaluation_response_schema = "codegraff.learn.primary-evaluation.response.v1";
pub const legacy_run_schema = "codegraff.learn.run.v2";
pub const run_schema = "codegraff.learn.run.v3";

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
    statistical_unit_id: ?[]const u8 = null,
    seed: []const u8,
    critical: bool,
};

pub fn statisticalUnitId(pair: PairRequest) []const u8 {
    return pair.statistical_unit_id orelse pair.case_id;
}

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
    latency_measured: bool = false,
    /// False means the adapter did not measure calls; zero must not be
    /// interpreted as a free execution.
    tool_calls_measured: bool = false,
    parent_tool_calls: u64 = 0,
    child_tool_calls: u64 = 0,
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

pub const BaselinePairResult = struct {
    case_id: []const u8,
    seed: []const u8,
    pass: bool,
    score_ppm: u32,
    cost_micros: u64 = 0,
    latency_ms: u64 = 0,
    latency_measured: bool = false,
    tool_calls_measured: bool = false,
    tool_calls: u64 = 0,
};

pub const PrimaryBaselineRequest = struct {
    schema: []const u8,
    trial_id: []const u8,
    cohort_id: []const u8,
    suite_sha256: []const u8,
    suite_path: []const u8,
    parent: GenomeRef,
    repetitions: usize,
    pairs: []const PairRequest,
};

pub const PrimaryBaselineResponse = struct {
    schema: []const u8,
    trial_id: []const u8,
    cohort_id: []const u8,
    suite_sha256: []const u8,
    parent_id: []const u8,
    pairs: []const BaselinePairResult,
};

pub const PrimaryBaselineRecord = struct {
    suite_sha256: []const u8,
    request_evidence_id: []const u8,
    response_evidence_id: []const u8,
};

pub const PrimaryBaselineRef = struct {
    request_evidence_id: []const u8,
    response_evidence_id: []const u8,
    path: []const u8,
};

pub const PrimaryEvaluationRequest = struct {
    schema: []const u8,
    trial_id: []const u8,
    candidate_index: usize,
    cohort_id: []const u8,
    suite_sha256: []const u8,
    suite_path: []const u8,
    parent_id: []const u8,
    baseline: PrimaryBaselineRef,
    child: GenomeRef,
    repetitions: usize,
    pairs: []const PairRequest,
};

pub const PrimaryEvaluationResponse = struct {
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
    /// Non-sensitive local arm label supplied by the pinned mutator.
    description: []const u8 = "",
    genome_bytes: usize = 0,
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
    child_critical_failures: usize = 0,
    critical_regressions: usize,
    /// Raw parent-pass/child-fail rows before repetitions or related cases are
    /// collapsed into statistical units. Economy promotion requires zero.
    correctness_regressions: usize = 0,
    delta_ppm: i64,
    mean_score_delta_ppm: i64,
    p_value_ppb: u64,
    parent_cost_micros: u64,
    child_cost_micros: u64,
    tool_calls_measured: bool = false,
    parent_tool_calls: u64 = 0,
    child_tool_calls: u64 = 0,
    tool_wins: usize = 0,
    tool_losses: usize = 0,
    tool_ties: usize = 0,
    tool_delta_ppm: i64 = 0,
    tool_p_value_ppb: u64 = 1_000_000_000,
    latency_measured: bool = false,
    parent_latency_ms: u64 = 0,
    child_latency_ms: u64 = 0,
    economy_eligible: bool = false,
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
    primary_baseline: ?PrimaryBaselineRecord = null,
    candidates: []const CandidateRecord,
    /// Best primary-suite contender. This remains populated when the evidence
    /// is useful but not adequately powered for promotion.
    primary_winner_genome_id: ?[]const u8 = null,
    /// Populated only when the primary winner clears every promotion gate.
    selected_genome_id: ?[]const u8,
};

pub const MutationOutcome = struct {
    genome_id: [64]u8,
    prompt: []u8,
    record: MutationRecord,
};
