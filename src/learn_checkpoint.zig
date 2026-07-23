//! Crash-durable progress for an in-flight local learning tournament.
//!
//! This mutable ref contains only IDs and verified aggregates. Resume never
//! trusts it directly: every referenced immutable genome/evidence object is
//! revalidated by the normal mutation/evaluation verifiers before reuse.

const std = @import("std");
const Allocator = std.mem.Allocator;
const eval = @import("learn_eval.zig");
const store_mod = @import("learn_store.zig");

pub const schema = "codegraff.learn.pending.v1";
pub const file_name = "pending.json";

pub const Record = struct {
    schema: []const u8 = schema,
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
    primary_baseline: ?eval.PrimaryBaselineRecord = null,
    candidates: []const eval.CandidateRecord,
};

fn validCandidate(candidate: eval.CandidateRecord) bool {
    return store_mod.validId(candidate.genome_id) and
        store_mod.validId(candidate.mutation.seed) and
        store_mod.validId(candidate.mutation.request_evidence_id) and
        store_mod.validId(candidate.mutation.response_evidence_id) and
        candidate.mutation.description.len <= 512 and
        std.unicode.utf8ValidateSlice(candidate.mutation.description) and
        std.mem.indexOfScalar(u8, candidate.mutation.description, 0) == null and
        !candidate.eligible;
}

pub fn validate(record: Record) !void {
    if (!std.mem.eql(u8, record.schema, schema) or
        !store_mod.validId(record.trial_id) or
        !store_mod.validId(record.nonce) or
        !store_mod.validId(record.config_id) or
        !store_mod.validId(record.parent_genome_id) or
        !store_mod.validId(record.parent_transaction_id)) return error.InvalidPendingRun;
    if (record.harness_version.len == 0 or record.harness_version.len > 128 or
        record.planned_candidates == 0 or record.planned_candidates > 16 or
        record.candidates.len != record.planned_candidates or
        record.repetitions == 0 or record.repetitions > 100) return error.InvalidPendingRun;
    if (record.primary_baseline) |baseline| {
        if (!store_mod.validId(baseline.suite_sha256) or
            !store_mod.validId(baseline.request_evidence_id) or
            !store_mod.validId(baseline.response_evidence_id)) return error.InvalidPendingRun;
    }
    for (record.candidates) |candidate| if (!validCandidate(candidate)) return error.InvalidPendingRun;
}

pub fn load(arena: Allocator, store: *store_mod.Store) !?Record {
    const bytes = store_mod.readFileNoFollow(store.io, store.refs, file_name, arena, store_mod.max_record_bytes) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const record = try std.json.parseFromSliceLeaky(Record, arena, bytes, .{});
    try validate(record);
    return record;
}

pub fn write(gpa: Allocator, store: *store_mod.Store, record: Record) !void {
    try validate(record);
    const bytes = try store_mod.jsonBytes(gpa, record);
    defer gpa.free(bytes);
    if (bytes.len > store_mod.max_record_bytes) return error.PendingRunTooLarge;
    try store.writeAtomicReplace(store.refs, file_name, bytes);
}

pub fn clear(store: *store_mod.Store) !void {
    store.refs.deleteFile(store.io, file_name) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try store_mod.syncDirectory(store.io, store.refs);
}
