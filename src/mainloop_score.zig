//! Validation, provenance signing, and event emission for JSON-protocol score
//! requests. Kept separate from the interactive main loop so the protocol's
//! scale and signature contract has one focused implementation.

const std = @import("std");

const agent_mod = @import("agent.zig");
const scoring = @import("scoring.zig");
const telemetry = @import("telemetry.zig");
const trace = @import("trace.zig");
const util = @import("util.zig");

fn isHex16(s: []const u8) bool {
    if (s.len != 16) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    return if (obj.get(key)) |value| (if (value == .string) value.string else "") else "";
}

/// Handle one JSON-protocol score request. Validation failures are protocol
/// errors, so they are emitted to the caller rather than returned as Zig errors.
pub fn handle(root: *agent_mod.Agent, obj: std.json.ObjectMap) void {
    // Fingerprint fields must be exactly 16 hex chars. A length-only check
    // would let an embedded newline shift fields in the signed v2 envelope.
    const sha = stringField(obj, "prompt_sha");
    const raw_score: f64 = if (obj.get("score")) |value| switch (value) {
        .float => |number| number,
        .integer => |number| @floatFromInt(number),
        else => std.math.nan(f64),
    } else std.math.nan(f64);
    if (!isHex16(sha) or std.math.isNan(raw_score)) {
        root.emit(.{ .type = "error", .message = "score needs prompt_sha (16 hex chars) and a numeric score" });
        return;
    }

    // The canonical wire scale is [0,1]. An explicit percent scale always
    // divides by 100; absent a scale, [0,1] passes and (1,100] is normalized.
    const scale = stringField(obj, "scale");
    if (scale.len > 0 and !std.mem.eql(u8, scale, "percent") and !std.mem.eql(u8, scale, "unit")) {
        root.emit(.{ .type = "error", .message = "unknown scale: use \"unit\" or \"percent\" (or omit it for the [0,1]/(1,100] heuristic)" });
        return;
    }
    const normalized: ?f64 = if (std.mem.eql(u8, scale, "percent"))
        (if (raw_score < 0 or raw_score > 100) null else raw_score / 100.0)
    else if (std.mem.eql(u8, scale, "unit"))
        (if (raw_score < 0 or raw_score > 1) null else raw_score)
    else
        scoring.normalizeOutboundScore(raw_score);
    const score = normalized orelse {
        root.emit(.{ .type = "error", .message = "score out of range: scale=\"unit\" requires [0,1], scale=\"percent\" requires [0,100] (sent as value/100); without scale, [0,1] passes, (1,100] is normalized to /100, and values outside [0,100] are rejected" });
        return;
    };

    const notes = stringField(obj, "notes");
    const parent = if (obj.get("parent_sha")) |value| (if (value == .string and isHex16(value.string)) value.string else "") else "";

    // Sanitize user-controlled provenance before signing so the signed bytes
    // exactly match the transported bytes.
    var judge_buf: [64]u8 = undefined;
    var artifact_buf: [64]u8 = undefined;
    const judge_id = scoring.sanitizeMetaField(&judge_buf, util.utf8Prefix(stringField(obj, "judge_id"), 64));
    const artifact_sha = scoring.sanitizeMetaField(&artifact_buf, util.utf8Prefix(stringField(obj, "artifact_sha"), 64));

    // Stamp the configured eval suite when the request omits a hash, allowing
    // scores to group into a promotable niche/provider/suite cell.
    var derived_eval_hash: [16]u8 = undefined;
    var eval_hash_buf: [64]u8 = undefined;
    const eval_set_hash = eval_hash: {
        const provided = scoring.sanitizeMetaField(&eval_hash_buf, util.utf8Prefix(stringField(obj, "eval_set_hash"), 64));
        if (provided.len > 0) break :eval_hash provided;
        if (root.eval_cmd) |command| {
            derived_eval_hash = scoring.promptFingerprint(command);
            break :eval_hash @as([]const u8, &derived_eval_hash);
        }
        break :eval_hash "";
    };

    var run_buf: [64]u8 = undefined;
    const requested_run = scoring.sanitizeMetaField(&run_buf, util.utf8Prefix(stringField(obj, "run_id"), 64));
    const run_id: []const u8 = if (requested_run.len > 0) requested_run else &scoring.g_run_id;

    var niche_buf: [64]u8 = undefined;
    const niche = scoring.sanitizeMetaField(&niche_buf, util.utf8Prefix(stringField(obj, "niche"), 64));
    const provider_class = scoring.providerClass(root.provider.model);
    const signature = scoring.signScore(sha, parent, score, run_id, judge_id, artifact_sha, eval_set_hash, niche, provider_class);
    const signed = scoring.g_score_key != null;

    if (trace.g_traj) |trajectory| trajectory.node(.{
        .kind = "score",
        .prompt_sha = sha,
        .parent_sha = parent,
        .score = score,
        .notes = util.utf8Prefix(notes, 200),
        .run_id = run_id,
        .judge_id = judge_id,
        .artifact_sha = artifact_sha,
        .eval_set_hash = eval_set_hash,
        .niche = niche,
        .provider_class = provider_class,
        .sig = if (signed) @as([]const u8, &signature) else "",
        .t = trajectory.elapsedMs(),
    });

    var provenance_buf: [512]u8 = undefined;
    const provenance = std.fmt.bufPrint(&provenance_buf, "{s}\t{s}\t{s}\t{s}\t{s}", .{ judge_id, artifact_sha, eval_set_hash, provider_class, niche }) catch "";
    if (telemetry.g_telem) |item| item.scoreEvent(sha, parent, score, run_id, if (signed) @as([]const u8, &signature) else "", provenance);
    if (eval_set_hash.len > 0) if (telemetry.g_telem) |item| item.fleetEvent("submit", niche, sha, "", provider_class, eval_set_hash, 0, "");
    root.emit(.{ .type = "score", .ok = true, .prompt_sha = sha, .signed = signed });
}
