//! Tests for behavior_trace.zig (600-line goal). Reached through the
//! `test { _ = @import(...) }` hook at the bottom of behavior_trace.zig's
//! declarations, mirroring the mcp.zig pattern in main.zig.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const behavior_upload = @import("behavior_upload.zig");
const trace = @import("trace.zig");
const btrace = @import("behavior_trace.zig");

const BehaviorTrace = btrace.BehaviorTrace;
const BehaviorRunMetadata = btrace.BehaviorRunMetadata;
const behavior_schema = btrace.behavior_schema;
const writeBehaviorLine = btrace.writeBehaviorLine;
const max_local_behavior_event_bytes = btrace.max_local_behavior_event_bytes;
const max_tool_args_bytes = btrace.max_tool_args_bytes;
const max_text_delta_bytes = btrace.max_text_delta_bytes;
const Tracer = trace.Tracer;
const Trajectory = trace.Trajectory;
const beginRootTurn = trace.beginRootTurn;
const endRootTurn = trace.endRootTurn;

fn expectObjectKeys(object: std.json.ObjectMap, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, object.count());
    for (expected) |key| try std.testing.expect(object.get(key) != null);
}

test "writeBehaviorLine: oversized adapter content is rejected before local allocation can grow" {
    const gpa = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const oversized = try gpa.alloc(u8, max_local_behavior_event_bytes + 1);
    defer gpa.free(oversized);
    @memset(oversized, 'x');
    // Pre-existing #246 bug fixed in passing: writeBehaviorLine returns
    // LineResult (.written/.dropped/.sink_failed), not bool — this call site
    // still compared against `!bool` and failed to compile.
    try std.testing.expectEqual(btrace.LineResult.dropped, writeBehaviorLine(gpa, &out.writer, .turn_committed, 1, 1.0, "0123456789abcdef", .{
        .turn = @as(u64, 1),
        .reason = oversized,
    }));
    try std.testing.expectEqual(@as(usize, 0), out.writer.buffered().len);
}

test "BehaviorTrace: events are flat, attributable, and ordered" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = gpa,
        .out = &aw.writer,
        .run_id = "run-test-1",
    };

    behavior.start("test", 1_234);
    behavior.start("ignored-duplicate", 9_999);
    try std.testing.expectEqual(@as(u64, 1), behavior.beginTurn(7));
    behavior.recordExpectedAction(
        1,
        "commit-1",
        .{ .tool = "edit_file", .note = "line one\nline two ☃" },
        .{ .build = "passes", .attempts = @as(u64, 1) },
        "verify the edit compiles",
    );
    behavior.recordMisprediction(
        1,
        "commit-1",
        .{ .build = "passes" },
        .{ .build = "fails", .exit_code = @as(i64, 1) },
        "reported by a task-specific verifier",
    );
    behavior.finish(.closed);
    // Typed lifecycle methods cannot append after closure.
    behavior.recordExpectedAction(1, "late", .{ .tool = "bash" }, .{ .ok = true }, "too late");

    const out = aw.writer.buffered();
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, out, "\n"));
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out, "\n"), '\n');

    var started = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer started.deinit();
    try std.testing.expectEqualStrings("run_started", started.value.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 1), started.value.object.get("seq").?.integer);
    try std.testing.expect(started.value.object.get("ts").? == .float);
    try std.testing.expectEqualStrings("run-test-1", started.value.object.get("run_id").?.string);
    try std.testing.expectEqualStrings(behavior_schema, started.value.object.get("schema").?.string);
    try std.testing.expectEqualStrings("test", started.value.object.get("version").?.string);
    try std.testing.expectEqual(@as(i64, 1_234), started.value.object.get("unix_ms").?.integer);
    try std.testing.expect(started.value.object.get("payload") == null);

    var turn = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer turn.deinit();
    try std.testing.expectEqualStrings("turn_started", turn.value.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 2), turn.value.object.get("seq").?.integer);
    try std.testing.expectEqual(@as(i64, 1), turn.value.object.get("turn").?.integer);
    try std.testing.expectEqual(@as(i64, 0), turn.value.object.get("parent_turn").?.integer);
    try std.testing.expectEqual(@as(i64, 7), turn.value.object.get("trajectory_node").?.integer);
    try std.testing.expectEqualStrings("run-test-1", turn.value.object.get("run_id").?.string);

    var committed = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer committed.deinit();
    try std.testing.expectEqualStrings("turn_committed", committed.value.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 3), committed.value.object.get("seq").?.integer);
    try std.testing.expectEqual(@as(i64, 1), committed.value.object.get("turn").?.integer);
    try std.testing.expectEqualStrings("commit-1", committed.value.object.get("commitment_id").?.string);
    try std.testing.expectEqualStrings("line one\nline two ☃", committed.value.object.get("action").?.object.get("note").?.string);
    try std.testing.expectEqualStrings("passes", committed.value.object.get("expect").?.object.get("build").?.string);
    try std.testing.expectEqualStrings("verify the edit compiles", committed.value.object.get("reason").?.string);

    var mismatch = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer mismatch.deinit();
    try std.testing.expectEqualStrings("model_mispredicted", mismatch.value.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 4), mismatch.value.object.get("seq").?.integer);
    try std.testing.expectEqualStrings("commit-1", mismatch.value.object.get("commitment_id").?.string);
    try std.testing.expectEqualStrings("fails", mismatch.value.object.get("actual").?.object.get("build").?.string);
    try std.testing.expectEqualStrings("reported by a task-specific verifier", mismatch.value.object.get("detail").?.string);

    var finished = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer finished.deinit();
    try std.testing.expectEqualStrings("run_finished", finished.value.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 5), finished.value.object.get("seq").?.integer);
    try std.testing.expectEqualStrings("closed", finished.value.object.get("status").?.string);
    try std.testing.expectEqualStrings("run-test-1", finished.value.object.get("run_id").?.string);
    try std.testing.expect(lines.next() == null);
}

test "BehaviorTrace: disabled writes do not consume sequence numbers" {
    const io = std.testing.io;
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = std.testing.allocator,
        .out = null,
        .run_id = "disabled-run",
    };

    behavior.start("test", 0);
    try std.testing.expectEqual(@as(u64, 1), behavior.beginTurn(0));
    try std.testing.expectEqual(@as(u64, 0), behavior.seq);
    try std.testing.expectEqual(@as(u64, 1), behavior.currentTurn());
}

test "BehaviorTrace: typed APIs reject out-of-lifecycle adapter events" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = gpa,
        .out = &aw.writer,
        .run_id = "lifecycle-run",
    };

    try std.testing.expectEqual(@as(u64, 0), behavior.beginTurn(9));
    behavior.recordExpectedAction(1, "early", .{ .kind = "edit" }, .{ .ok = true }, "before start");
    behavior.start("test", 1);
    behavior.recordExpectedAction(1, "early", .{ .kind = "edit" }, .{ .ok = true }, "before turn");
    try std.testing.expectEqual(@as(u64, 1), behavior.beginTurn(9));
    behavior.recordExpectedAction(0, "zero-turn", .{ .kind = "edit" }, .{ .ok = true }, "invalid turn");
    behavior.recordExpectedAction(2, "future-turn", .{ .kind = "edit" }, .{ .ok = true }, "invalid turn");
    behavior.recordExpectedAction(1, "", .{ .kind = "edit" }, .{ .ok = true }, "empty commitment");
    behavior.recordMisprediction(1, "", .{ .ok = true }, .{ .ok = false }, "empty commitment");

    try std.testing.expectEqual(@as(u64, 2), behavior.seq);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, aw.writer.buffered(), "\n"));
    behavior.finish(.failed);
    behavior.finish(.closed); // the first terminal status wins
    try std.testing.expectEqual(@as(u64, 3), behavior.seq);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, aw.writer.buffered(), "\n"), '\n');
    _ = lines.next();
    _ = lines.next();
    var finished = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer finished.deinit();
    try std.testing.expectEqualStrings("error", finished.value.object.get("status").?.string);
}

test "BehaviorTrace: a full upload queue cannot claim a complete terminal lifecycle" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var upload: behavior_upload.Upload = .{
        .io = io,
        .gpa = gpa,
        .client = null,
        .endpoint = "https://collector.example/v1/logs",
        .install_id = @splat('q'),
        .client_name = "harness",
        .service_version = "test",
        .run_id = "0123456789abcdef",
        .mode = .metadata,
    };
    defer upload.deinit();
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = gpa,
        .out = null,
        .upload = &upload,
        .run_id = "0123456789abcdef",
    };

    behavior.start("test", 1);
    try std.testing.expectEqual(@as(usize, 1), upload.events.items.len);
    const placeholder = upload.events.items[0][0..0];
    try upload.events.resize(gpa, behavior_upload.max_events);
    for (upload.events.items[1..]) |*event| event.* = placeholder;

    const state = behavior.prepareFinish("closed").?;
    try std.testing.expect(!state.complete);
    try std.testing.expectEqual(@as(u64, 1), upload.dropped_events);
    try std.testing.expectEqual(@as(usize, behavior_upload.max_events), upload.events.items.len);

    // Remove synthetic queue entries before normal deinit and payload parsing.
    upload.events.shrinkRetainingCapacity(1);
    const payload = try upload.buildPayload(state.complete, "closed");
    defer gpa.free(payload);
    var parsed = try std.json.parseFromSlice(Value, gpa, payload, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("complete").?.bool);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("events").?.array.items.len);
}

test "BehaviorTrace: terminal allocation failure leaves upload incomplete" {
    const backing_gpa = std.testing.allocator;
    const io = std.testing.io;
    // run_started uses one allocation for its event and one for ArrayList
    // storage. Fail the next allocation, which is run_finished serialization.
    var failing = std.testing.FailingAllocator.init(backing_gpa, .{ .fail_index = 2 });
    const failing_gpa = failing.allocator();
    var upload: behavior_upload.Upload = .{
        .io = io,
        .gpa = failing_gpa,
        .client = null,
        .endpoint = "https://collector.example/v1/logs",
        .install_id = @splat('a'),
        .client_name = "harness",
        .service_version = "test",
        .run_id = "0123456789abcdef",
        .mode = .metadata,
    };
    defer upload.deinit();
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = backing_gpa,
        .out = null,
        .upload = &upload,
        .run_id = "0123456789abcdef",
    };

    behavior.start("test", 1);
    try std.testing.expectEqual(@as(usize, 1), upload.events.items.len);
    const state = behavior.prepareFinish("error").?;
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(!state.complete);
    try std.testing.expectEqual(@as(u64, 1), upload.dropped_events);
    try std.testing.expectEqual(@as(usize, 1), upload.events.items.len);

    failing.fail_index = std.math.maxInt(usize);
    const payload = try upload.buildPayload(state.complete, "error");
    defer failing_gpa.free(payload);
    var parsed = try std.json.parseFromSlice(Value, backing_gpa, payload, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("complete").?.bool);
}

test "BehaviorTrace: metadata-default upload is an exact content-free projection" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var local: Io.Writer.Allocating = .init(gpa);
    defer local.deinit();
    var upload: behavior_upload.Upload = .{
        .io = io,
        .gpa = gpa,
        .client = null,
        .endpoint = "https://collector.example/v1/logs",
        .install_id = @splat('c'),
        .client_name = "test",
        .service_version = "test",
        .run_id = "0123456789abcdef",
        .mode = behavior_upload.resolveMode(null, true),
    };
    defer upload.deinit();
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = gpa,
        .out = &local.writer,
        .upload = &upload,
        .run_id = "0123456789abcdef",
    };
    behavior.startWithMetadata("test", 1_234, .{
        .provider = "anthropic",
        .model = "test-model",
        .prompt_sha = "0011223344556677",
        .effort = "high",
    });
    try std.testing.expectEqual(@as(u64, 1), behavior.beginTurn(7));
    behavior.recordExpectedAction(
        1,
        "COMMITMENT_SECRET",
        .{ .source = "SOURCE_SECRET", .tool_args = "TOOL_ARGUMENT_SECRET" },
        .{ .tool_result = "TOOL_RESULT_SECRET" },
        "REASON_SECRET",
    );
    behavior.recordMisprediction(
        1,
        "COMMITMENT_SECRET",
        .{ .model_output = "MODEL_OUTPUT_SECRET" },
        .{ .workspace_path = "PRIVATE_PATH_SECRET" },
        "DETAIL_SECRET",
    );
    var tracer: Tracer = .{
        .io = io,
        .gpa = gpa,
        .out = null,
        .start = Io.Timestamp.now(io, .awake),
        .behavior = &behavior,
    };
    tracer.api("repl", false, "test-model", 20, 100, 200, 300, 250, false);
    tracer.tool("mcp__private_server__lookup_customer", 7, true, 80, true);
    behavior.finish(.closed);
    behavior.finish(.failed);
    // Late callbacks may race terminal teardown. They must observe closure and
    // leave the uploader untouched after send can begin.
    try std.testing.expectEqual(@as(u64, 0), behavior.recordApiMetric(false, 99, 999, 999, 999, 999, true));
    try std.testing.expectEqual(@as(u64, 0), behavior.recordToolMetric("bash", false, 99, 999, true));

    const secrets = [_][]const u8{
        "COMMITMENT_SECRET",
        "SOURCE_SECRET",
        "TOOL_ARGUMENT_SECRET",
        "TOOL_RESULT_SECRET",
        "REASON_SECRET",
        "MODEL_OUTPUT_SECRET",
        "PRIVATE_PATH_SECRET",
        "DETAIL_SECRET",
        "0011223344556677",
        "private_server",
        "lookup_customer",
    };
    const local_jsonl = local.writer.buffered();
    for (secrets[0..9]) |secret| try std.testing.expect(std.mem.indexOf(u8, local_jsonl, secret) != null);

    const payload = try upload.buildPayload(true, "closed");
    defer gpa.free(payload);
    for (&secrets) |secret| try std.testing.expect(std.mem.indexOf(u8, payload, secret) == null);
    var parsed = try std.json.parseFromSlice(Value, gpa, payload, .{});
    defer parsed.deinit();
    const batch = parsed.value.object;
    try expectObjectKeys(batch, &.{
        "schema",
        "event_schema",
        "privacy",
        "run_id",
        "install_id",
        "client_name",
        "service_version",
        "complete",
        "terminal_status",
        "dropped_events",
        "dropped_metrics",
        "events",
        "turn_metrics",
    });
    try std.testing.expectEqualStrings("metadata", batch.get("privacy").?.string);
    const events = batch.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 5), events.len);
    // Pre-existing staleness fixed in passing: startWithMetadata's
    // upload_fields already carries local_sink (sink-health diagnostics,
    // #246) but this key list predated that field.
    try expectObjectKeys(events[0].object, &.{ "kind", "seq", "ts", "run_id", "schema", "version", "unix_ms", "provider", "model", "effort", "local_sink" });
    try expectObjectKeys(events[1].object, &.{ "kind", "seq", "ts", "run_id", "schema", "turn", "parent_turn", "trajectory_node" });
    try expectObjectKeys(events[2].object, &.{ "kind", "seq", "ts", "run_id", "schema", "turn", "commitment_ref" });
    try expectObjectKeys(events[3].object, &.{ "kind", "seq", "ts", "run_id", "schema", "turn", "commitment_ref" });
    // Same staleness: run_finished's fields already carry local_dropped
    // (#246 audit reconciliation) alongside status.
    try expectObjectKeys(events[4].object, &.{ "kind", "seq", "ts", "run_id", "schema", "status", "local_dropped" });
    try std.testing.expectEqualStrings(events[2].object.get("commitment_ref").?.string, events[3].object.get("commitment_ref").?.string);

    const metrics = batch.get("turn_metrics").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), metrics.len);
    try std.testing.expectEqual(@as(i64, 0), metrics[0].object.get("api_subagent_calls").?.integer);
    try std.testing.expectEqual(@as(i64, 1), metrics[0].object.get("tool_subagent_calls").?.integer);
    try std.testing.expectEqual(@as(i64, 1), metrics[0].object.get("tool_mcp").?.integer);
    try std.testing.expectEqual(@as(i64, 1), metrics[0].object.get("tool_errors").?.integer);
}

test "BehaviorTrace: prompt fingerprint stays local in content mode" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var local: Io.Writer.Allocating = .init(gpa);
    defer local.deinit();
    var upload: behavior_upload.Upload = .{
        .io = io,
        .gpa = gpa,
        .client = null,
        .endpoint = "https://collector.example/v1/logs",
        .install_id = @splat('c'),
        .client_name = "harness",
        .service_version = "test",
        .run_id = "0123456789abcdef",
        .mode = .content,
    };
    defer upload.deinit();
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = gpa,
        .out = &local.writer,
        .upload = &upload,
        .run_id = "0123456789abcdef",
    };
    behavior.startWithMetadata("test", 1, .{ .prompt_sha = "0011223344556677" });
    try std.testing.expect(std.mem.indexOf(u8, local.writer.buffered(), "0011223344556677") != null);
    try std.testing.expectEqual(@as(usize, 1), upload.events.items.len);
    try std.testing.expect(std.mem.indexOf(u8, upload.events.items[0], "0011223344556677") == null);
    try std.testing.expect(std.mem.indexOf(u8, upload.events.items[0], "prompt_sha") == null);
}

test "beginRootTurn: correlates without allocating a legacy node" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = gpa,
        .out = &aw.writer,
        .run_id = "root-turn-run",
    };
    var trajectory: Trajectory = .{
        .io = io,
        .gpa = gpa,
        .out = null,
        .start = Io.Timestamp.now(io, .awake),
    };
    defer trajectory.deinit();

    behavior.start("test", 1);
    const trajectory_node = trajectory.nextId();
    trajectory.setTurn(trajectory_node);
    const legacy_next_id = trajectory.next_id;
    var tracer: Tracer = .{
        .io = io,
        .gpa = gpa,
        .out = null,
        .start = Io.Timestamp.now(io, .awake),
        .behavior = &behavior,
    };
    const previous_trajectory = trace.g_traj;
    trace.g_traj = &trajectory;
    defer trace.g_traj = previous_trajectory;

    try std.testing.expectEqual(@as(u64, 1), beginRootTurn(&tracer));
    try std.testing.expectEqual(legacy_next_id, trajectory.next_id);
    try std.testing.expectEqual(trajectory_node, trajectory.currentTurn());

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, aw.writer.buffered(), "\n"), '\n');
    _ = lines.next(); // run_started
    var turn = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer turn.deinit();
    try std.testing.expectEqual(@as(i64, 1), turn.value.object.get("turn").?.integer);
    try std.testing.expectEqual(@as(i64, @intCast(trajectory_node)), turn.value.object.get("trajectory_node").?.integer);
}

test "endRootTurn: clears attribution while preserving the dense parent chain" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = gpa,
        .out = &aw.writer,
        .run_id = "root-scope-run",
    };
    var tracer: Tracer = .{
        .io = io,
        .gpa = gpa,
        .out = null,
        .start = Io.Timestamp.now(io, .awake),
        .behavior = &behavior,
    };
    const previous_trajectory = trace.g_traj;
    trace.g_traj = null;
    defer trace.g_traj = previous_trajectory;

    behavior.start("test", 1);
    const first = beginRootTurn(&tracer);
    try std.testing.expectEqual(@as(u64, 1), first);
    try std.testing.expectEqual(first, behavior.recordApiMetric(false, 1, 1, 1, 1, 1, false));
    try std.testing.expectEqual(first, behavior.recordToolMetric("bash", false, 1, 1, false));

    endRootTurn(&tracer, first);
    try std.testing.expectEqual(@as(u64, 0), behavior.currentTurn());
    try std.testing.expectEqual(@as(u64, 0), behavior.recordApiMetric(false, 1, 1, 1, 1, 1, false));
    try std.testing.expectEqual(@as(u64, 0), behavior.recordToolMetric("bash", false, 1, 1, false));
    behavior.recordExpectedAction(first, "late", .{ .tool = "bash" }, .{ .ok = true }, "outside the root turn");

    const second = beginRootTurn(&tracer);
    try std.testing.expectEqual(@as(u64, 2), second);
    endRootTurn(&tracer, first); // a stale scope cannot clear the new turn
    try std.testing.expectEqual(second, behavior.currentTurn());
    endRootTurn(&tracer, second);
    try std.testing.expectEqual(@as(u64, 0), behavior.currentTurn());
    try std.testing.expectEqual(@as(u64, 3), behavior.seq);

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, aw.writer.buffered(), "\n"), '\n');
    _ = lines.next(); // run_started
    _ = lines.next(); // first turn_started
    var second_started = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer second_started.deinit();
    try std.testing.expectEqual(@as(i64, 2), second_started.value.object.get("turn").?.integer);
    try std.testing.expectEqual(@as(i64, 1), second_started.value.object.get("parent_turn").?.integer);
    try std.testing.expect(lines.next() == null);
}

test "BehaviorTrace: rich kinds are gated by GRAFF_BEHAVIOR_TRACE=full (#255)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = gpa,
        .out = &aw.writer,
        .run_id = "rich-gate-run",
    };
    behavior.start("test", 1);
    try std.testing.expectEqual(@as(u64, 1), behavior.beginTurn(0));
    try std.testing.expectEqual(@as(u64, 2), behavior.seq); // run_started + turn_started

    // rich defaults to false: every typed rich emitter is a no-op, even with
    // a live local sink and a valid turn/call_id.
    const call_id = behavior.reserveCallId();
    behavior.toolStarted(1, call_id, "edit_file", "{}");
    behavior.toolFinished(1, call_id, "edit_file", 5, false, 10);
    behavior.actionTaken(1, call_id, "edit_file", false);
    behavior.textDelta(1, "hello");
    try std.testing.expectEqual(@as(u64, 2), behavior.seq);

    // rich == true: the same calls now emit tool_started, tool_finished,
    // action_taken (edit_file is a write-class tool), and text_delta.
    behavior.rich = true;
    const call_id2 = behavior.reserveCallId();
    behavior.toolStarted(1, call_id2, "edit_file", "{\"path\":\"a.zig\"}");
    behavior.toolFinished(1, call_id2, "edit_file", 5, false, 10);
    behavior.actionTaken(1, call_id2, "edit_file", false);
    behavior.textDelta(1, "hello");
    try std.testing.expectEqual(@as(u64, 6), behavior.seq);

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, aw.writer.buffered(), "\n"), '\n');
    _ = lines.next(); // run_started
    _ = lines.next(); // turn_started

    var started = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer started.deinit();
    try std.testing.expectEqualStrings("tool_started", started.value.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(call_id2)), started.value.object.get("call_id").?.integer);
    try std.testing.expectEqualStrings("a.zig", started.value.object.get("args").?.object.get("path").?.string);
    try std.testing.expect(!started.value.object.get("args_truncated").?.bool);

    var finished = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer finished.deinit();
    try std.testing.expectEqualStrings("tool_finished", finished.value.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(call_id2)), finished.value.object.get("call_id").?.integer);
    try std.testing.expect(!finished.value.object.get("is_error").?.bool);

    var action = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer action.deinit();
    try std.testing.expectEqualStrings("action_taken", action.value.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(call_id2)), action.value.object.get("call_id").?.integer);

    var text = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer text.deinit();
    try std.testing.expectEqualStrings("text_delta", text.value.object.get("kind").?.string);
    try std.testing.expectEqualStrings("hello", text.value.object.get("text").?.string);
    try std.testing.expect(lines.next() == null);
}

test "BehaviorTrace: action_taken skips non-mutating tool classes even when rich (#255)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = gpa,
        .out = &aw.writer,
        .run_id = "action-class-run",
        .rich = true,
    };
    behavior.start("test", 1);
    try std.testing.expectEqual(@as(u64, 1), behavior.beginTurn(0));
    const before = behavior.seq;
    // read_file is a read-class tool: an observation, not an action.
    behavior.actionTaken(1, behavior.reserveCallId(), "read_file", false);
    try std.testing.expectEqual(before, behavior.seq);
    // bash is shell-class: a state mutation.
    behavior.actionTaken(1, behavior.reserveCallId(), "bash", true);
    try std.testing.expectEqual(before + 1, behavior.seq);
}

test "BehaviorTrace: rich caps truncate args and text without corrupting JSON (#255)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = gpa,
        .out = &aw.writer,
        .run_id = "cap-run",
        .rich = true,
    };
    behavior.start("test", 1);
    try std.testing.expectEqual(@as(u64, 1), behavior.beginTurn(0));

    // Oversized args are never re-parsed as JSON, even when the raw bytes
    // happen to look JSON-ish up to the cut point — always a plain string.
    const oversized_args = try gpa.alloc(u8, max_tool_args_bytes + 1);
    defer gpa.free(oversized_args);
    @memset(oversized_args, 'a');
    oversized_args[0] = '{';
    behavior.toolStarted(1, 1, "bash", oversized_args);

    const oversized_text = try gpa.alloc(u8, max_text_delta_bytes + 1);
    defer gpa.free(oversized_text);
    @memset(oversized_text, 'b');
    behavior.textDelta(1, oversized_text);

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, aw.writer.buffered(), "\n"), '\n');
    _ = lines.next(); // run_started
    _ = lines.next(); // turn_started

    var started = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer started.deinit();
    try std.testing.expect(started.value.object.get("args_truncated").?.bool);
    try std.testing.expect(started.value.object.get("args").? == .string);
    try std.testing.expectEqual(@as(usize, max_tool_args_bytes), started.value.object.get("args").?.string.len);

    var text = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer text.deinit();
    try std.testing.expect(text.value.object.get("text_truncated").?.bool);
    try std.testing.expectEqual(@as(usize, max_text_delta_bytes), text.value.object.get("text").?.string.len);
    try std.testing.expect(lines.next() == null);
}

test "BehaviorTrace: rich kinds never reach the uploader (#255)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var local: Io.Writer.Allocating = .init(gpa);
    defer local.deinit();
    var upload: behavior_upload.Upload = .{
        .io = io,
        .gpa = gpa,
        .client = null,
        .endpoint = "https://collector.example/v1/logs",
        .install_id = @splat('u'),
        .client_name = "harness",
        .service_version = "test",
        .run_id = "0123456789abcdef",
        .mode = .content, // the most permissive collector mode
    };
    defer upload.deinit();
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = gpa,
        .out = &local.writer,
        .upload = &upload,
        .run_id = "0123456789abcdef",
        .rich = true,
    };
    behavior.start("test", 1);
    try std.testing.expectEqual(@as(u64, 1), behavior.beginTurn(0));
    // run_started + turn_started are upload-eligible.
    try std.testing.expectEqual(@as(usize, 2), upload.events.items.len);

    const call_id = behavior.reserveCallId();
    behavior.toolStarted(1, call_id, "bash", "{\"command\":\"ls\"}");
    behavior.toolFinished(1, call_id, "bash", 5, false, 10);
    behavior.actionTaken(1, call_id, "bash", false);
    behavior.textDelta(1, "hello");

    // The local file grew by four lines, but the uploader saw nothing new,
    // and none of it counted as a drop — a documented exclusion, not a loss.
    try std.testing.expectEqual(@as(usize, 2), upload.events.items.len);
    try std.testing.expectEqual(@as(u64, 0), upload.dropped_events);
    try std.testing.expectEqual(@as(u64, 6), behavior.seq);
}

test "BehaviorTrace.reserveCallId: monotonic per run, independent of lifecycle state (#255)" {
    const io = std.testing.io;
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = std.testing.allocator,
        .out = null,
        .run_id = "call-id-run",
    };
    try std.testing.expectEqual(@as(u64, 1), behavior.reserveCallId());
    try std.testing.expectEqual(@as(u64, 2), behavior.reserveCallId());
    try std.testing.expectEqual(@as(u64, 3), behavior.reserveCallId());
    // Reservation never no-ops, unlike the typed emitters (rich/turn gated).
    behavior.start("test", 1);
    try std.testing.expectEqual(@as(u64, 4), behavior.reserveCallId());
}

test "Tracer.toolStarted/toolFinished: call_id pairs interleaved calls (#255)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = gpa,
        .out = &aw.writer,
        .run_id = "tracer-run",
        .rich = true,
    };
    behavior.start("test", 1);
    try std.testing.expectEqual(@as(u64, 1), behavior.beginTurn(0));
    var tracer: Tracer = .{
        .io = io,
        .gpa = gpa,
        .out = null,
        .start = Io.Timestamp.now(io, .awake),
        .behavior = &behavior,
    };

    var args = try std.json.parseFromSlice(Value, gpa, "{\"command\":\"ls\"}", .{});
    defer args.deinit();
    const call_a = tracer.toolStarted("bash", args.value);
    const call_b = tracer.toolStarted("bash", args.value);
    try std.testing.expect(call_a != 0 and call_b != 0 and call_a != call_b);
    // Finish out of order: the second call started finishes first.
    tracer.toolFinished("bash", call_b, 3, false, 5);
    tracer.toolFinished("bash", call_a, 7, true, 9);

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, aw.writer.buffered(), "\n"), '\n');
    _ = lines.next(); // run_started
    _ = lines.next(); // turn_started

    var started_a = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer started_a.deinit();
    try std.testing.expectEqual(@as(i64, @intCast(call_a)), started_a.value.object.get("call_id").?.integer);

    var started_b = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer started_b.deinit();
    try std.testing.expectEqual(@as(i64, @intCast(call_b)), started_b.value.object.get("call_id").?.integer);

    var finished_b = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer finished_b.deinit();
    try std.testing.expectEqualStrings("tool_finished", finished_b.value.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(call_b)), finished_b.value.object.get("call_id").?.integer);

    var action_b = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer action_b.deinit();
    try std.testing.expectEqualStrings("action_taken", action_b.value.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(call_b)), action_b.value.object.get("call_id").?.integer);

    var finished_a = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer finished_a.deinit();
    try std.testing.expectEqual(@as(i64, @intCast(call_a)), finished_a.value.object.get("call_id").?.integer);
    try std.testing.expect(finished_a.value.object.get("is_error").?.bool);

    var action_a = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer action_a.deinit();
    try std.testing.expectEqualStrings("action_taken", action_a.value.object.get("kind").?.string);
    try std.testing.expect(lines.next() == null);
}
