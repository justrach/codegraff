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
const process_runner = @import("process_runner.zig");
const verify_fingerprint = @import("verify_fingerprint.zig");

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

/// Run a command in the process cwd, failing the test if it did not succeed.
/// The #412 test needs a REAL git repo: reading git is the whole feature, and
/// a mocked probe would prove nothing about the porcelain/diff/untracked split.
fn fixtureCmd(gpa: std.mem.Allocator, io: Io, argv: []const []const u8) !void {
    const r = process_runner.runCapped(gpa, io, argv, 1 << 16, 1 << 16, 60_000) catch
        return error.SkipZigTest; // no git on this machine: skip rather than fail on the environment
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (!process_runner.ranOk(r)) return error.FixtureCommandFailed;
}

/// How many times the --eval command was actually SPAWNED. The counter lives
/// under .graff/, which the fixture repo gitignores, so counting can never
/// itself move the fingerprint the guard is reading.
fn verifierCalls(gpa: std.mem.Allocator, io: Io) usize {
    const body = Io.Dir.cwd().readFileAlloc(io, ".graff/verifier-calls", gpa, .limited(4096)) catch return 0;
    defer gpa.free(body);
    return body.len;
}

test "#412: an unchanged worktree is not re-verified, and any change re-arms the verifier" {
    // POSIX-only for the same reason as the test above: the fchdir isolation.
    if (builtin.os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var orig_dir = try Io.Dir.cwd().openDir(io, ".", .{});
    defer orig_dir.close(io);
    defer _ = std.posix.system.fchdir(orig_dir.handle);
    if (std.posix.system.fchdir(tmp.dir.handle) != 0) return error.ChdirFailed;

    // A real single-commit repo. `.graff/` is ignored so the harness's own eval
    // log, its notes and the call counter can never read as work the model did
    // - without that the tree would move on every eval and never skip.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = ".gitignore", .data = ".graff/\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = "work.txt", .data = "one\n" });
    try fixtureCmd(gpa, io, &.{ "git", "init", "-q" });
    try fixtureCmd(gpa, io, &.{ "git", "add", "-A" });
    try fixtureCmd(gpa, io, &.{ "git", "-c", "user.email=t@example.com", "-c", "user.name=t", "-c", "commit.gpgsign=false", "commit", "-q", "--no-verify", "-m", "fixture" });

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
        .tracer = null,
        // Always RED, and it leaves one byte behind per real invocation.
        .eval_cmd = "mkdir -p .graff && printf x >> .graff/verifier-calls; exit 1",
        .eval_target = 90,
    };

    // Attempt 1: nothing to compare against, so the verifier runs. Its RED
    // verdict arms the guard over the tree it failed on.
    const first = try agent.runEval("");
    try std.testing.expect(!first.is_error); // a RED is a verdict, not a tool error
    try std.testing.expectEqual(@as(usize, 1), verifierCalls(gpa, io));
    try std.testing.expect(agent.eval_repair_pending);
    try std.testing.expect(agent.eval_fp != null);

    // Attempt 2, workspace untouched. This is the whole feature: before it, a
    // /goal continuation re-ran the entire scoring command (plus a --judge
    // model call) to re-derive a verdict that could not have changed.
    const second = try agent.runEval("");
    try std.testing.expectEqual(@as(usize, 1), verifierCalls(gpa, io)); // NOT spawned
    try std.testing.expectEqual(@as(u32, 2), agent.eval_iter); // but the attempt still counts
    try std.testing.expect(second.is_error);
    try std.testing.expect(std.mem.indexOf(u8, second.text, verify_fingerprint.no_progress_steer) != null);
    try std.testing.expect(std.mem.indexOf(u8, second.text, "eval output (tail)") == null); // no verdict was manufactured
    // A skipped run verifies nothing, so completion stays blocked.
    try std.testing.expect(agent.eval_repair_pending and !agent.eval_verified);

    // A TRACKED edit is progress: the verifier runs again...
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = "work.txt", .data = "two\n" });
    _ = try agent.runEval("");
    try std.testing.expectEqual(@as(usize, 2), verifierCalls(gpa, io));
    // ...and its RED arms the skip over the NEW tree, not the old one.
    _ = try agent.runEval("");
    try std.testing.expectEqual(@as(usize, 2), verifierCalls(gpa, io));

    // An UNTRACKED file is progress too, and its CONTENTS are what prove it:
    // `git status --porcelain` says `?? scratch.txt` either way and
    // `git diff HEAD` stays empty, so a fingerprint built from those two alone
    // would skip both of these attempts over real work.
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = "scratch.txt", .data = "a" });
    _ = try agent.runEval("");
    try std.testing.expectEqual(@as(usize, 3), verifierCalls(gpa, io));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = "scratch.txt", .data = "b" });
    _ = try agent.runEval("");
    try std.testing.expectEqual(@as(usize, 4), verifierCalls(gpa, io));

    // Six attempts, four verifier runs: the two no-progress ones were free.
    try std.testing.expectEqual(@as(u32, 6), agent.eval_iter);

    // A green eval disarms the guard entirely - the next RED must be measured
    // against its own tree, never against one this run already left behind.
    agent.eval_cmd = "printf 'score: 100\\n'";
    _ = try agent.runEval("");
    try std.testing.expect(agent.eval_verified and agent.eval_fp == null);
}
