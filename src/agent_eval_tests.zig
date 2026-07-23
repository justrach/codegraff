//! Tests for agent_eval.zig's eval-driven-loop behavioral producer (issue
//! #256): the first production caller of turn_committed/model_mispredicted.
//! Reached through the `test { _ = @import(...) }` hook at the bottom of
//! agent_eval.zig, mirroring behavior_trace.zig's own test-file pattern.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Value = std.json.Value;

const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const trace = @import("trace.zig");
const Tracer = trace.Tracer;
const btrace = @import("behavior_trace.zig");
const BehaviorTrace = btrace.BehaviorTrace;

test "runEval: commits before the command runs, mispredicts on a missed target, and leaves a met target commitment-only (#256)" {
    // The chdir below is POSIX-only, matching session_start.zig's own
    // --worktree isolation (Windows has no libc chdir link here).
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // runEval's appendEvalLog() writes .graff/eval-log.tsv against the real
    // process cwd (it takes no Dir param), so this test moves the process
    // into a scratch directory for its duration instead of touching the repo
    // checkout. fchdir on real directory handles is used instead of
    // path-based chdir/realPath: realPath on Dir.cwd()'s AT_FDCWD handle is
    // unreliable on this platform (see session_start.zig's own PWD
    // fallback), and this way sidesteps it entirely in both directions.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var orig_dir = try Io.Dir.cwd().openDir(io, ".", .{});
    defer orig_dir.close(io);
    defer _ = std.posix.system.fchdir(orig_dir.handle);
    if (std.posix.system.fchdir(tmp.dir.handle) != 0) return error.ChdirFailed;

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var behavior: BehaviorTrace = .{
        .io = io,
        .gpa = gpa,
        .out = &aw.writer,
        .run_id = "runeval-test",
    };
    behavior.start("test", 1);
    const turn = behavior.beginTurn(0);
    var tracer: Tracer = .{
        .io = io,
        .gpa = gpa,
        .out = null,
        .start = Io.Timestamp.now(io, .awake),
        .behavior = &behavior,
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var agent: Agent = .{
        .gpa = gpa,
        .arena = arena_state.allocator(),
        .io = io,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = null,
        .tracer = &tracer,
        .eval_cmd = "printf 'score: 10\\n'; exit 1",
        .eval_target = 90,
    };

    const failure = try agent.runEval("");
    try std.testing.expect(!failure.is_error);
    try std.testing.expectEqual(@as(u32, 1), agent.eval_iter);
    try std.testing.expect(!agent.eval_verified);
    try std.testing.expect(agent.eval_repair_pending);
    try std.testing.expect(agent.completed == null);

    agent.eval_cmd = "printf 'score: 100\\n'";
    const success = try agent.runEval("");
    try std.testing.expect(!success.is_error);
    try std.testing.expectEqual(@as(u32, 2), agent.eval_iter);
    try std.testing.expect(agent.eval_verified);
    try std.testing.expect(!agent.eval_repair_pending);
    try std.testing.expect(agent.completed == null);
    const notes = try Io.Dir.cwd().readFileAlloc(io, ".graff/eval-notes/session.md", gpa, .limited(16 * 1024));
    defer gpa.free(notes);
    try std.testing.expect(std.mem.indexOf(u8, notes, "eval #1") != null);
    try std.testing.expect(std.mem.indexOf(u8, notes, "met=no") != null);
    try std.testing.expect(std.mem.indexOf(u8, notes, "eval #2") != null);
    try std.testing.expect(std.mem.indexOf(u8, notes, "met=yes") != null);

    const out = aw.writer.buffered();
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out, "\n"), '\n');
    _ = lines.next(); // run_started
    _ = lines.next(); // turn_started

    var committed1 = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer committed1.deinit();
    try std.testing.expectEqualStrings("turn_committed", committed1.value.object.get("kind").?.string);
    const commitment_id_1 = committed1.value.object.get("commitment_id").?.string;
    try std.testing.expectEqual(@as(i64, @intCast(turn)), committed1.value.object.get("turn").?.integer);
    try std.testing.expectEqualStrings("eval", committed1.value.object.get("action").?.object.get("kind").?.string);
    try std.testing.expect(committed1.value.object.get("expect").?.object.get("pass").?.bool);

    var mispredicted = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer mispredicted.deinit();
    try std.testing.expectEqualStrings("model_mispredicted", mispredicted.value.object.get("kind").?.string);
    try std.testing.expectEqualStrings(commitment_id_1, mispredicted.value.object.get("commitment_id").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(turn)), mispredicted.value.object.get("turn").?.integer);
    try std.testing.expectEqual(@as(i64, 1), mispredicted.value.object.get("actual").?.object.get("exit").?.integer);
    try std.testing.expect(!mispredicted.value.object.get("actual").?.object.get("pass").?.bool);

    // Privacy contract: the command text and its stdout/stderr are content
    // and must never reach the local behavioral stream for this producer
    // (docs/behavioral-trajectories.md).
    try std.testing.expect(std.mem.indexOf(u8, out, "printf") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "exit 1") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "score: 10") == null);

    var committed2 = try std.json.parseFromSlice(Value, gpa, lines.next().?, .{});
    defer committed2.deinit();
    try std.testing.expectEqualStrings("turn_committed", committed2.value.object.get("kind").?.string);
    const commitment_id_2 = committed2.value.object.get("commitment_id").?.string;
    try std.testing.expect(!std.mem.eql(u8, commitment_id_1, commitment_id_2));

    // The met-target commitment has no paired misprediction: absence is the
    // success signal (docs/behavioral-trajectories.md).
    try std.testing.expect(lines.next() == null);
}
