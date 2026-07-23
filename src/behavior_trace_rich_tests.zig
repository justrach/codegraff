//! Opt-in rich behavioral capture tests, split from the lifecycle suite.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const btrace = @import("behavior_trace.zig");
const BehaviorTrace = btrace.BehaviorTrace;
const max_text_delta_bytes = btrace.max_text_delta_bytes;
const max_tool_args_bytes = btrace.max_tool_args_bytes;
const behavior_upload = @import("behavior_upload.zig");
const Tracer = @import("trace.zig").Tracer;

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

test "BehaviorTrace: rich metadata reaches uploader without content (#246)" {
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
        .mode = .metadata,
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
    try std.testing.expectEqual(@as(usize, 2), upload.events.items.len);

    const call_id = behavior.reserveCallId();
    behavior.toolStarted(1, call_id, "bash", "{\"command\":\"ls\"}");
    behavior.toolFinished(1, call_id, "bash", 5, false, 10);
    behavior.actionTaken(1, call_id, "bash", false);
    behavior.textDelta(1, "hello");

    try std.testing.expectEqual(@as(usize, 6), upload.events.items.len);
    try std.testing.expectEqual(@as(u64, 0), upload.dropped_events);
    try std.testing.expectEqual(@as(u64, 6), behavior.seq);
    const payload = upload.events.items[2];
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"tool_class\":\"shell\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"args_bytes\":16") != null);
    for (upload.events.items[2..]) |event| {
        try std.testing.expect(std.mem.indexOf(u8, event, "\"name\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, event, "\"command\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, event, "hello") == null);
    }
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
