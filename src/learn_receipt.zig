//! Versioned, signed aggregate receipt for one verified learning comparison.
//! The contract intentionally has no fields for prompts, paths, task payloads,
//! adapter output, or arbitrary metadata.

const std = @import("std");
const eval = @import("learn_eval.zig");
const scoring = @import("scoring.zig");
const store = @import("learn_store.zig");

pub const schema = "codegraff.learn.grade.v2";
pub const delete_token_domain = "codegraff.learn.delete.v1\n";

pub const Grade = struct {
    pairs: usize,
    statistical_units: usize,
    parent_passes: usize,
    child_passes: usize,
    child_critical_failures: usize,
    critical_regressions: usize,
    correctness_regressions: usize,
    delta_ppm: i64,
    mean_score_delta_ppm: i64,
    p_value_ppb: u64,
    tool_calls_measured: bool,
    parent_tool_calls: u64,
    child_tool_calls: u64,
    tool_wins: usize,
    tool_losses: usize,
    tool_ties: usize,
    tool_delta_ppm: i64,
    tool_p_value_ppb: u64,
    parent_cost_micros: u64,
    child_cost_micros: u64,
    latency_measured: bool,
    parent_latency_ms: u64,
    child_latency_ms: u64,
    economy_eligible: bool,
    eligible: bool,
    economy_gate_enabled: bool,
    alpha_ppm: u32,
    minimum_delta_ppm: u32,
    minimum_pairs: usize,
    minimum_tool_reduction_ppm: u32,
    minimum_economy_pairs: usize,
    multiplicity: usize,
    reason: []const u8,
    promotion_mode: []const u8,
};

pub fn fromComparison(gate: store.Gate, comparison: eval.ComparisonRecord, multiplicity: usize) Grade {
    return .{
        .pairs = comparison.pairs,
        .statistical_units = comparison.statistical_units,
        .parent_passes = comparison.parent_passes,
        .child_passes = comparison.child_passes,
        .child_critical_failures = comparison.child_critical_failures,
        .critical_regressions = comparison.critical_regressions,
        .correctness_regressions = comparison.correctness_regressions,
        .delta_ppm = comparison.delta_ppm,
        .mean_score_delta_ppm = comparison.mean_score_delta_ppm,
        .p_value_ppb = comparison.p_value_ppb,
        .tool_calls_measured = comparison.tool_calls_measured,
        .parent_tool_calls = comparison.parent_tool_calls,
        .child_tool_calls = comparison.child_tool_calls,
        .tool_wins = comparison.tool_wins,
        .tool_losses = comparison.tool_losses,
        .tool_ties = comparison.tool_ties,
        .tool_delta_ppm = comparison.tool_delta_ppm,
        .tool_p_value_ppb = comparison.tool_p_value_ppb,
        .parent_cost_micros = comparison.parent_cost_micros,
        .child_cost_micros = comparison.child_cost_micros,
        .latency_measured = comparison.latency_measured,
        .parent_latency_ms = comparison.parent_latency_ms,
        .child_latency_ms = comparison.child_latency_ms,
        .economy_eligible = comparison.economy_eligible,
        .eligible = comparison.eligible,
        .economy_gate_enabled = gate.economy_gate_enabled,
        .alpha_ppm = gate.alpha_ppm,
        .minimum_delta_ppm = gate.minimum_delta_ppm,
        .minimum_pairs = gate.minimum_pairs,
        .minimum_tool_reduction_ppm = gate.minimum_tool_reduction_ppm,
        .minimum_economy_pairs = gate.minimum_economy_pairs,
        .multiplicity = multiplicity,
        .reason = comparison.reason,
        .promotion_mode = @tagName(gate.promotion_mode),
    };
}

fn format(
    buffer: []u8,
    separator: u8,
    prefix: []const u8,
    prompt_sha: []const u8,
    parent_sha: []const u8,
    value: f64,
    run_id: []const u8,
    judge_id: []const u8,
    artifact_sha: []const u8,
    eval_set_hash: []const u8,
    niche: []const u8,
    provider_class: []const u8,
    delete_token: []const u8,
    run_created_unix_ms: i64,
    grade: Grade,
) ?[]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    writer.print("{s}{c}{s}{c}{s}{c}{d:.6}{c}{s}{c}{s}{c}{s}{c}{s}{c}{s}{c}{s}", .{
        prefix,        separator, prompt_sha, separator, parent_sha,     separator,    value,
        separator,     run_id,    separator,  judge_id,  separator,      artifact_sha, separator,
        eval_set_hash, separator, niche,      separator, provider_class,
    }) catch return null;
    writer.print("{c}{s}{c}{d}", .{ separator, delete_token, separator, run_created_unix_ms }) catch return null;
    const metrics = [_]i64{
        @intCast(grade.pairs),
        @intCast(grade.statistical_units),
        @intCast(grade.parent_passes),
        @intCast(grade.child_passes),
        @intCast(grade.child_critical_failures),
        @intCast(grade.critical_regressions),
        @intCast(grade.correctness_regressions),
        grade.delta_ppm,
        grade.mean_score_delta_ppm,
        @intCast(grade.p_value_ppb),
        @intFromBool(grade.tool_calls_measured),
        @intCast(grade.parent_tool_calls),
        @intCast(grade.child_tool_calls),
        @intCast(grade.tool_wins),
        @intCast(grade.tool_losses),
        @intCast(grade.tool_ties),
        grade.tool_delta_ppm,
        @intCast(grade.tool_p_value_ppb),
        @intCast(grade.parent_cost_micros),
        @intCast(grade.child_cost_micros),
        @intFromBool(grade.latency_measured),
        @intCast(grade.parent_latency_ms),
        @intCast(grade.child_latency_ms),
        @intFromBool(grade.economy_eligible),
        @intFromBool(grade.eligible),
        @intFromBool(grade.economy_gate_enabled),
        grade.alpha_ppm,
        grade.minimum_delta_ppm,
        @intCast(grade.minimum_pairs),
        grade.minimum_tool_reduction_ppm,
        @intCast(grade.minimum_economy_pairs),
        @intCast(grade.multiplicity),
    };
    for (metrics) |metric| writer.print("{c}{d}", .{ separator, metric }) catch return null;
    writer.print("{c}{s}{c}{s}", .{ separator, grade.reason, separator, grade.promotion_mode }) catch return null;
    return writer.buffered();
}

pub fn message(buffer: []u8, prompt_sha: []const u8, parent_sha: []const u8, value: f64, run_id: []const u8, judge_id: []const u8, artifact_sha: []const u8, eval_set_hash: []const u8, niche: []const u8, provider_class: []const u8, delete_token: []const u8, run_created_unix_ms: i64, grade: Grade) ?[]const u8 {
    return format(buffer, '\n', schema, prompt_sha, parent_sha, value, run_id, judge_id, artifact_sha, eval_set_hash, niche, provider_class, delete_token, run_created_unix_ms, grade);
}

pub fn sign(prompt_sha: []const u8, parent_sha: []const u8, value: f64, run_id: []const u8, judge_id: []const u8, artifact_sha: []const u8, eval_set_hash: []const u8, niche: []const u8, provider_class: []const u8, delete_token: []const u8, run_created_unix_ms: i64, grade: Grade) [64]u8 {
    const key = scoring.g_score_key orelse return @splat(0);
    var buffer: [2304]u8 = undefined;
    const bytes = message(&buffer, prompt_sha, parent_sha, value, run_id, judge_id, artifact_sha, eval_set_hash, niche, provider_class, delete_token, run_created_unix_ms, grade) orelse return @splat(0);
    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, bytes, key);
    return std.fmt.bytesToHex(mac, .lower);
}

/// Run-scoped bearer capability. The immutable run nonce never leaves the
/// machine, so possession of the shared score key plus a leaked run id is not
/// enough to delete a receipt.
pub fn deletionToken(run_id: []const u8, nonce: []const u8) [64]u8 {
    const key = scoring.g_score_key orelse return @splat(0);
    var buffer: [192]u8 = undefined;
    const bytes = std.fmt.bufPrint(&buffer, delete_token_domain ++ "{s}\n{s}", .{ run_id, nonce }) catch return @splat(0);
    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, bytes, key);
    return std.fmt.bytesToHex(mac, .lower);
}

pub fn provenance(buffer: []u8, judge_id: []const u8, artifact_sha: []const u8, eval_set_hash: []const u8, provider_class: []const u8, niche: []const u8, grade_signature: []const u8, delete_token: []const u8, run_created_unix_ms: i64, grade: Grade) ?[]const u8 {
    var detail_buffer: [1792]u8 = undefined;
    const detail = format(&detail_buffer, '\t', schema, "", "", 0, "", "", "", "", "", "", delete_token, run_created_unix_ms, grade) orelse return null;
    // Drop the empty core fields and fixed 0.000000 value; the ordinary score
    // transport already carries them. Keep the schema and all signed metrics.
    var parts = std.mem.splitScalar(u8, detail, '\t');
    const receipt_schema = parts.next() orelse return null;
    var skipped: usize = 0;
    while (skipped < 9) : (skipped += 1) _ = parts.next() orelse return null;
    const metrics = parts.rest();
    return std.fmt.bufPrint(buffer, "{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}", .{
        judge_id, artifact_sha, eval_set_hash, provider_class, niche, receipt_schema, grade_signature, metrics,
    }) catch null;
}

test "learning grade message is deterministic and prompt-free" {
    const grade: Grade = .{
        .pairs = 20,
        .statistical_units = 20,
        .parent_passes = 10,
        .child_passes = 15,
        .child_critical_failures = 0,
        .critical_regressions = 0,
        .correctness_regressions = 0,
        .delta_ppm = 250_000,
        .mean_score_delta_ppm = 100_000,
        .p_value_ppb = 7_812_500,
        .tool_calls_measured = true,
        .parent_tool_calls = 100,
        .child_tool_calls = 80,
        .tool_wins = 8,
        .tool_losses = 1,
        .tool_ties = 11,
        .tool_delta_ppm = 200_000,
        .tool_p_value_ppb = 19_531_250,
        .parent_cost_micros = 200,
        .child_cost_micros = 180,
        .latency_measured = true,
        .parent_latency_ms = 400,
        .child_latency_ms = 350,
        .economy_eligible = false,
        .eligible = true,
        .economy_gate_enabled = false,
        .alpha_ppm = 50_000,
        .minimum_delta_ppm = 50_000,
        .minimum_pairs = 20,
        .minimum_tool_reduction_ppm = 100_000,
        .minimum_economy_pairs = 8,
        .multiplicity = 4,
        .reason = "eligible",
        .promotion_mode = "correctness",
    };
    var buffer: [2048]u8 = undefined;
    const prompt = "aaaaaaaaaaaaaaaa";
    const parent = "bbbbbbbbbbbbbbbb";
    const run = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    const artifact = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
    const suite = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
    const niche = "ffffffffffffffff";
    const delete_token = "1111111111111111111111111111111111111111111111111111111111111111";
    const created_unix_ms: i64 = 1_784_700_000_000;
    const bytes = message(&buffer, prompt, parent, 0.75, run, "learn-primary-v2", artifact, suite, niche, "frontier", delete_token, created_unix_ms, grade).?;
    try std.testing.expect(std.mem.startsWith(u8, bytes, schema ++ "\naaaaaaaaaaaaaaaa\nbbbbbbbbbbbbbbbb\n0.750000\n"));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "private prompt") == null);
    const saved_key = scoring.g_score_key;
    defer scoring.g_score_key = saved_key;
    scoring.g_score_key = "test-key";
    const signature = sign(prompt, parent, 0.75, run, "learn-primary-v2", artifact, suite, niche, "frontier", delete_token, created_unix_ms, grade);
    try std.testing.expectEqualStrings("e4d78b0a0236fb9719272a016f41685a10d93a4f488cb704e0f7f8c963b546bb", &signature);

    const token = deletionToken(run, "2222222222222222222222222222222222222222222222222222222222222222");
    try std.testing.expectEqualStrings("5abd1867608b678b6679e00f24f7f457eccef7977a4df149f03c002a1885f5d9", &token);
}
