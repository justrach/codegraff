//! OTLP attribute serialization for score and signed learning-grade events.

const std = @import("std");

const AttrVal = union(enum) { str: []const u8, int: i64, num: f64 };

fn attr(s: *std.json.Stringify, key: []const u8, value: AttrVal) !void {
    try s.beginObject();
    try s.objectField("key");
    try s.write(key);
    try s.objectField("value");
    try s.beginObject();
    switch (value) {
        .str => |item| {
            try s.objectField("stringValue");
            try s.write(item);
        },
        .int => |item| {
            var buffer: [24]u8 = undefined;
            try s.objectField("intValue");
            try s.write(std.fmt.bufPrint(&buffer, "{d}", .{item}) catch unreachable);
        },
        .num => |item| {
            try s.objectField("doubleValue");
            try s.write(item);
        },
    }
    try s.endObject();
    try s.endObject();
}

const metric_names = [_][]const u8{
    "pairs",                      "statistical_units",     "parent_passes",             "child_passes",
    "child_critical_failures",    "critical_regressions",  "correctness_regressions",   "delta_ppm",
    "mean_score_delta_ppm",       "p_value_ppb",           "tool_calls_measured",       "parent_tool_calls",
    "child_tool_calls",           "behavior_measured",     "parent_behavior_score_ppm", "child_behavior_score_ppm",
    "tool_wins",                  "tool_losses",           "tool_ties",                 "tool_delta_ppm",
    "tool_p_value_ppb",           "parent_cost_micros",    "child_cost_micros",         "latency_measured",
    "parent_latency_ms",          "child_latency_ms",      "economy_eligible",          "eligible",
    "economy_gate_enabled",       "alpha_ppm",             "minimum_delta_ppm",         "minimum_pairs",
    "minimum_tool_reduction_ppm", "minimum_economy_pairs", "multiplicity",
};

pub fn write(s: *std.json.Stringify, event: anytype) !void {
    try attr(s, "prompt_sha", .{ .str = event.detail });
    try attr(s, "value", .{ .num = event.score });
    if (event.extra.len > 0) try attr(s, "parent_sha", .{ .str = event.extra });
    if (event.run_id.len > 0) try attr(s, "run_id", .{ .str = event.run_id });
    if (event.sig.len > 0) try attr(s, "sig", .{ .str = event.sig });
    if (event.prov.len == 0) return;

    var parts = std.mem.splitScalar(u8, event.prov, '\t');
    for ([_][]const u8{ "judge_id", "artifact_sha", "eval_set_hash", "provider_class", "niche" }) |name| {
        const value = parts.next() orelse return error.InvalidScoreProvenance;
        if (value.len > 0) try attr(s, name, .{ .str = value });
    }
    const grade_schema = parts.next() orelse return;
    if (grade_schema.len == 0) return;
    const grade_sig = parts.next() orelse return error.InvalidScoreProvenance;
    var delete_token: []const u8 = "";
    var run_created_unix_ms: ?i64 = null;
    if (std.mem.eql(u8, grade_schema, "codegraff.learn.grade.v2") or
        std.mem.eql(u8, grade_schema, "codegraff.learn.grade.v3"))
    {
        delete_token = parts.next() orelse return error.InvalidScoreProvenance;
        const raw_created = parts.next() orelse return error.InvalidScoreProvenance;
        run_created_unix_ms = std.fmt.parseInt(i64, raw_created, 10) catch return error.InvalidScoreProvenance;
    }
    var metrics: [metric_names.len]i64 = undefined;
    for (&metrics) |*metric| {
        const raw = parts.next() orelse return error.InvalidScoreProvenance;
        metric.* = std.fmt.parseInt(i64, raw, 10) catch return error.InvalidScoreProvenance;
    }
    const reason = parts.next() orelse return error.InvalidScoreProvenance;
    const promotion_mode = parts.next() orelse return error.InvalidScoreProvenance;
    if (parts.next() != null) return error.InvalidScoreProvenance;

    try attr(s, "grade_schema", .{ .str = grade_schema });
    try attr(s, "grade_sig", .{ .str = grade_sig });
    if (delete_token.len > 0) try attr(s, "delete_token", .{ .str = delete_token });
    if (run_created_unix_ms) |created| try attr(s, "run_created_unix_ms", .{ .int = created });
    for (metric_names, metrics) |name, metric| try attr(s, name, .{ .int = metric });
    try attr(s, "reason", .{ .str = reason });
    try attr(s, "promotion_mode", .{ .str = promotion_mode });
}
