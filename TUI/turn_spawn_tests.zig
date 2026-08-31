//! Spawn-failure coverage for every fullscreen-TUI turn entry path.

const std = @import("std");

const app = @import("app.zig");
const engine = @import("engine.zig");
const turn = @import("turn.zig");
const Term = @import("sim.zig").Term;

const Fake = struct {
    var turn_calls: usize = 0;
    var join_calls: usize = 0;
    var wake_calls: usize = 0;

    fn reset() void {
        turn_calls = 0;
        join_calls = 0;
        wake_calls = 0;
    }

    fn spawn(_: *engine.Job) anyerror!std.Thread {
        return error.InjectedSpawnFailure;
    }

    fn joined() void {
        join_calls += 1;
    }

    fn modelWork(_: ?*anyopaque, _: std.mem.Allocator, _: []const engine.Turn, _: engine.Params, _: *engine.StreamBuf, _: *engine.EventQueue) ?[]const u8 {
        // This callback encloses the TUI's provider, tools, and automatic
        // compaction. A spawn failure must not enter any of it.
        turn_calls += 1;
        return null;
    }

    fn wake(_: ?*anyopaque, buf: []u8) ?[]const u8 {
        if (wake_calls != 0) return null;
        wake_calls += 1;
        const text = "automatic follow-up";
        @memcpy(buf[0..text.len], text);
        return buf[0..text.len];
    }
};

fn install() void {
    Fake.reset();
    engine.g_turn_fn = Fake.modelWork;
    engine.setJobThreadHooksForTesting(Fake.spawn, Fake.joined);
}

fn uninstall() void {
    engine.setJobThreadHooksForTesting(null, null);
    engine.g_turn_fn = null;
    engine.g_idle_wake_fn = null;
}

fn expectFailedStart(term: *Term) !void {
    const job = term.model.pending orelse return error.NoPendingJob;
    try std.testing.expect(job.start_failed);
    try std.testing.expect(!job.threaded);
    try std.testing.expect(job.done.load(.acquire));
    try std.testing.expectEqual(turn.QuitStep.reap, turn.quitStep(&term.model, 0));
    try std.testing.expectEqual(@as(usize, 0), Fake.turn_calls);
    try std.testing.expectEqual(@as(usize, 0), Fake.join_calls);
}

fn finishFailedStart(term: *Term) !void {
    turn.finishJob(&term.model);
    try std.testing.expect(term.model.pending == null);
    try std.testing.expect(engine.g_raw == null);
    try std.testing.expect(!term.model.cancel_requested);
    const last = term.model.history.items[term.model.history.items.len - 1];
    try std.testing.expectEqual(app.EntryKind.err, last.kind);
    try std.testing.expectEqualStrings("model turn failed to start — retry your prompt", last.text);
    for (term.model.history.items) |entry| try std.testing.expect(entry.kind != .pending);
    try std.testing.expectEqual(@as(usize, 0), Fake.turn_calls);
    try std.testing.expectEqual(@as(usize, 0), Fake.join_calls);
}

test "turn spawn failure stays off-thread for initial, queued, and subsequent TUI prompts (#537)" {
    install();
    defer uninstall();
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    defer term.deinit();

    // Initial prompt takes dispatch.applyLine -> turn.startJob.
    _ = term.typeText("initial prompt");
    _ = term.enter();
    try expectFailedStart(&term);
    const first = term.model.pending.?;

    // Before the next poll reaps the failed start, paint and input still work;
    // Enter follows the normal live-turn path and queues this draft.
    _ = term.typeText("queued follow-up");
    try std.testing.expectEqualStrings("queued follow-up", term.model.input.getValue());
    const visible = try term.screen();
    defer std.testing.allocator.free(visible);
    try std.testing.expect(std.mem.indexOf(u8, visible, "queued follow-up") != null);
    _ = term.enter();
    try std.testing.expect(term.model.pending.? == first);
    try std.testing.expectEqual(@as(usize, 1), term.model.steer_queue.items.len);

    // The render-loop poll reports and frees the first Job, then its FIFO drain
    // starts the queued turn through the same failing spawn seam.
    try finishFailedStart(&term);
    try std.testing.expectEqual(app.Effect.stay, turn.drainSteer(&term.model));
    try std.testing.expectEqual(@as(usize, 0), term.model.steer_queue.items.len);
    try expectFailedStart(&term);
    try finishFailedStart(&term);

    // A later ordinary prompt is the same trajectory after pending cleared.
    _ = term.typeText("subsequent prompt");
    _ = term.enter();
    try expectFailedStart(&term);
    try finishFailedStart(&term);
    try std.testing.expectEqual(@as(usize, 0), Fake.turn_calls);
    try std.testing.expectEqual(@as(usize, 0), Fake.join_calls);
}

test "idle wake spawn failure is reapable without a thread or model work (#537)" {
    install();
    defer uninstall();
    engine.g_idle_wake_fn = Fake.wake;
    var term: Term = undefined;
    term.init(std.testing.allocator, 80, 24);
    var deinited = false;
    defer if (!deinited) term.deinit();

    turn.maybeJobWake(&term.model);
    try std.testing.expectEqual(@as(usize, 1), Fake.wake_calls);
    try expectFailedStart(&term);
    try std.testing.expectEqualStrings("automatic follow-up", term.model.history.items[0].text);

    // Model.deinit's alternate cleanup path also sees threaded=false: the
    // undefined thread handle is never joined, and all Job ownership is freed.
    term.deinit();
    deinited = true;
    try std.testing.expect(engine.g_raw == null);
    try std.testing.expectEqual(@as(usize, 0), Fake.turn_calls);
    try std.testing.expectEqual(@as(usize, 0), Fake.join_calls);
}
