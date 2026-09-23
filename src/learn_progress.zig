//! Immutable, resumable tournament progress records.
const build_options = @import("build_options");
const checkpoint = @import("learn_checkpoint.zig");
const eval = @import("learn_eval.zig");
const store = @import("learn_store.zig");

pub fn record(
    config_id: []const u8,
    active: store.LoadedActive,
    nonce: []const u8,
    trial_id: []const u8,
    created_unix_ms: i64,
    candidate_count: usize,
    repetitions: usize,
    auto_requested: bool,
    formal_admission_evidence_id: ?[]const u8,
    primary_baseline: ?eval.PrimaryBaselineRecord,
    candidates: []const eval.CandidateRecord,
) checkpoint.Record {
    return .{
        .schema = if (formal_admission_evidence_id != null) checkpoint.formal_schema else checkpoint.schema,
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
        .formal_admission_evidence_id = formal_admission_evidence_id,
        .primary_baseline = primary_baseline,
        .candidates = candidates,
    };
}
