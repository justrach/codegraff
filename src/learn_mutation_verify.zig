//! Re-verification of immutable mutation evidence shared by final-run and
//! pending-checkpoint validation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const eval = @import("learn_eval.zig");
const store_mod = @import("learn_store.zig");

pub fn verify(
    arena: Allocator,
    store: *store_mod.Store,
    config: store_mod.Config,
    trial_id: []const u8,
    parent_genome_id: []const u8,
    index: usize,
    candidate: eval.CandidateRecord,
) !void {
    const expected_seed = eval.candidateSeed(trial_id, index);
    if (!std.mem.eql(u8, candidate.mutation.seed, &expected_seed)) return error.MutationMismatch;
    const request_bytes = try store.readEvidence(arena, candidate.mutation.request_evidence_id, config.limits.request_bytes);
    const response_bytes = try store.readEvidence(arena, candidate.mutation.response_evidence_id, config.limits.response_bytes);
    const request = try std.json.parseFromSliceLeaky(eval.MutationRequest, arena, request_bytes, .{});
    const response = try std.json.parseFromSliceLeaky(eval.MutationResponse, arena, response_bytes, .{});
    if (!std.mem.eql(u8, request.schema, eval.mutation_request_schema) or
        !std.mem.eql(u8, request.trial_id, trial_id) or request.candidate_index != index or
        !std.mem.eql(u8, request.seed, &expected_seed) or !std.mem.eql(u8, request.parent.id, parent_genome_id) or
        !std.mem.eql(u8, request.parent.path, "parent.genome") or !std.mem.eql(u8, request.child_path, "child.genome") or
        request.maximum_bytes != config.limits.genome_bytes or !std.mem.eql(u8, request.instruction, config.mutation_instruction)) return error.MutationMismatch;
    if (!std.mem.eql(u8, response.schema, eval.mutation_response_schema) or
        !std.mem.eql(u8, response.trial_id, trial_id) or response.candidate_index != index or
        !std.mem.eql(u8, response.parent_id, parent_genome_id) or !std.mem.eql(u8, response.child_path, "child.genome") or
        !store_mod.validId(response.child_sha256) or response.description.len > 512 or
        !std.unicode.utf8ValidateSlice(response.description) or std.mem.indexOfScalar(u8, response.description, 0) != null or
        !std.mem.eql(u8, response.description, candidate.mutation.description)) return error.MutationMismatch;
    const child = try store.readGenome(arena, candidate.genome_id, config.limits.genome_bytes);
    if (candidate.mutation.genome_bytes != child.len) return error.MutationOutputMismatch;
    const child_sha256 = store_mod.rawSha256(child);
    if (!std.mem.eql(u8, response.child_sha256, &child_sha256)) return error.MutationOutputMismatch;
}
