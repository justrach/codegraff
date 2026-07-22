//! Privacy-preserving publication of verified local-learning grades.
//!
//! Candidate genomes and evaluation payloads stay in the local immutable
//! store. Only the existing signed OTLP score envelope leaves the machine:
//! short prompt/parent fingerprints, aggregate pass rate, suite/cohort
//! metadata, and content-addressed evidence ids.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");

const eval = @import("learn_eval.zig");
const store = @import("learn_store.zig");
const scoring = @import("scoring.zig");
const telemetry = @import("telemetry.zig");
const telemetry_net = @import("telemetry_net.zig");
const keys_cli = @import("keys_cli.zig");
const learning_privacy = @import("learning_privacy.zig");

pub const SubmitResult = struct {
    grades: usize,
    endpoint: []const u8,
};

fn endpoint(environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("GRAFF_NO_TELEMETRY") != null) return error.TelemetryDisabled;
    if (environ.get("GRAFF_FLEET")) |value| {
        if (std.ascii.eqlIgnoreCase(value, "off") or std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false"))
            return error.TelemetryDisabled;
    }
    const value = environ.get("OTEL_EXPORTER_OTLP_ENDPOINT") orelse
        environ.get("GRAFF_OTEL_ENDPOINT") orelse
        build_options.telemetry_endpoint;
    if (value.len == 0) return error.TelemetryDisabled;
    return value;
}

/// Fail before an expensive learning run when an explicit submit could not
/// produce the backend's required authenticated score envelope.
pub fn preflight(io: Io, arena: Allocator, environ: *const std.process.Environ.Map) !void {
    if (!learning_privacy.allowsAggregate()) return error.LearningPrivacyLocal;
    _ = try endpoint(environ);
    scoring.g_score_key = scoring.loadScoreKey(io, arena, environ) orelse
        return error.ScoreSigningKeyRequired;
}

fn passRate(comparison: eval.ComparisonRecord) !f64 {
    if (comparison.pairs == 0 or comparison.child_passes > comparison.pairs)
        return error.InvalidComparison;
    return @as(f64, @floatFromInt(comparison.child_passes)) /
        @as(f64, @floatFromInt(comparison.pairs));
}

fn appendGrade(
    sink: *telemetry.Telemetry,
    config: store.Config,
    run_id: []const u8,
    run: eval.RunRecord,
    candidate: eval.CandidateRecord,
    comparison: eval.ComparisonRecord,
    judge_id: []const u8,
) !void {
    const prompt_sha = candidate.genome_id[0..16];
    const parent_sha = run.parent_genome_id[0..16];
    const value = try passRate(comparison);
    const provider_class = scoring.providerClass(config.cohort.model);
    // A configured agent name may be an internal project label. Use an opaque
    // config fingerprint for grouping instead of transmitting it verbatim.
    const niche = run.config_id[0..16];
    const signature = scoring.signScore(
        prompt_sha,
        parent_sha,
        value,
        run_id,
        judge_id,
        comparison.response_evidence_id,
        comparison.suite_sha256,
        niche,
        provider_class,
    );
    if (signature[0] == 0) return error.ScoreSigningKeyRequired;
    var provenance_buf: [320]u8 = undefined;
    const provenance = std.fmt.bufPrint(&provenance_buf, "{s}\t{s}\t{s}\t{s}\t{s}", .{
        judge_id,
        comparison.response_evidence_id,
        comparison.suite_sha256,
        provider_class,
        niche,
    }) catch return error.ProvenanceTooLong;
    sink.scoreEvent(prompt_sha, parent_sha, value, run_id, &signature, provenance);
}

pub fn submitVerifiedRun(
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    environ: *const std.process.Environ.Map,
    config: store.Config,
    run_id: []const u8,
    run: eval.RunRecord,
) !SubmitResult {
    try preflight(io, arena, environ);
    var primary_count: usize = 0;
    var holdout_count: usize = 0;
    var primary_winner_eligible = false;
    for (run.candidates) |candidate| {
        if (candidate.primary != null) primary_count += 1;
        if (candidate.holdout != null) holdout_count += 1;
        if (run.primary_winner_genome_id) |winner_id| {
            if (std.mem.eql(u8, candidate.genome_id, winner_id) and candidate.primary != null)
                primary_winner_eligible = candidate.primary.?.eligible;
        }
    }
    if (primary_count == 0 or primary_count > run.planned_candidates) return error.InvalidTournamentTopology;
    if (config.holdout_suite != null) {
        const expected_holdouts: usize = if (primary_winner_eligible) 1 else 0;
        if (holdout_count != expected_holdouts) return error.InvalidTournamentTopology;
    } else if (holdout_count != 0) return error.InvalidTournamentTopology;
    const target = try endpoint(environ);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const home = keys_cli.homeEnv(environ) orelse "";
    var sink: telemetry.Telemetry = .{
        .io = io,
        .gpa = gpa,
        .client = &client,
        .endpoint = target,
        .auth_key = telemetry.validatedAuthKey(environ.get("GRAFF_TELEMETRY_KEY")),
        .install_id = keys_cli.loadOrCreateId(io, gpa, home, ".simple-harness-install-id"),
        .client_name = "harness-learn",
        .sdk_install_id = "",
        .start = Io.Timestamp.now(io, .awake),
        .start_unix_ms = run.created_unix_ms,
    };
    defer sink.deinit();

    var grades: usize = 0;
    for (run.candidates) |candidate| {
        if (candidate.primary) |comparison| {
            try appendGrade(&sink, config, run_id, run, candidate, comparison, "learn-primary-v2");
            grades += 1;
        }
        if (candidate.holdout) |comparison| {
            try appendGrade(&sink, config, run_id, run, candidate, comparison, "learn-holdout-v2");
            grades += 1;
        }
    }
    if (grades == 0) return error.NoEvaluatedCandidates;

    var payload: Io.Writer.Allocating = .init(gpa);
    defer payload.deinit();
    try sink.writeOtlp(&payload.writer, sink.events.items, false);
    const url = (try telemetry_net.otlpLogsUrl(gpa, target)) orelse return error.InvalidTelemetryEndpoint;
    defer gpa.free(url);
    const accepted = telemetry_net.postOtlpWithDeadline(
        io,
        &client,
        url,
        payload.writer.buffered(),
        sink.auth_key orelse "",
        .fromSeconds(10),
    );
    if (!accepted) return error.SubmissionFailed;
    return .{ .grades = grades, .endpoint = target };
}

test "learning pass-rate grade uses repeated pair count" {
    const comparison: eval.ComparisonRecord = .{
        .suite_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .request_evidence_id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .response_evidence_id = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        .pairs = 4,
        .statistical_units = 2,
        .parent_passes = 1,
        .child_passes = 3,
        .wins = 2,
        .losses = 0,
        .ties = 2,
        .critical_regressions = 0,
        .delta_ppm = 500_000,
        .mean_score_delta_ppm = 0,
        .p_value_ppb = 1,
        .parent_cost_micros = 0,
        .child_cost_micros = 0,
        .eligible = true,
        .reason = "eligible",
    };
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), try passRate(comparison), 1e-12);
}
