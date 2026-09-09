//! REPL-only compaction presentation. Call begin only after committing to real
//! compaction (or an explicit provider compaction-start event), never merely
//! because a request supports automatic compaction. Always defer end, including
//! errors/cancellation. The caller retains responsibility for visible failures.
const std = @import("std");
const Agent = @import("agent.zig").Agent;
const main = @import("main.zig");
const render = @import("agent_stream_render.zig");
const anim = @import("anim.zig");

pub const label = "Compacting…";
var active = std.atomic.Value(bool).init(false);

pub fn isActive() bool {
    return active.load(.acquire);
}

pub const Scope = struct {
    engaged: bool = false,
    resume_spinner: bool = false,

    pub fn end(self: *Scope, agent: *Agent) void {
        if (!self.engaged) return;
        render.spinnerStop(agent);
        active.store(false, .release);
        self.engaged = false;
        if (self.resume_spinner) render.spinnerStart(agent);
    }
};

/// Root human output only: no GUI/JSON, child, title, or quiet-stream output.
/// A nested begin is inert; the outer scope owns cleanup.
pub fn begin(agent: *Agent) Scope {
    if (!eligible(agent.sub, main.json_mode, agent.stream_quiet, agent.call_kind == .title, agent.out != null)) return .{};
    if (active.swap(true, .acq_rel)) return .{};
    const had_spinner = Agent.g_spin_future != null;
    render.spinnerStop(agent);
    // Print immediately: progress must survive disabled animation, no color,
    // and failure to schedule the animation task. No diagnostic payload.
    agent.say("{s}\n", .{label}) catch {};
    if (main.use_color and !anim.g_anim_off) render.spinnerStart(agent);
    return .{ .engaged = true, .resume_spinner = had_spinner };
}

fn eligible(sub: bool, json: bool, quiet: bool, title: bool, has_writer: bool) bool {
    return !sub and !json and !quiet and !title and has_writer;
}

test "compact status is explicit and restricted to root REPL output" {
    try std.testing.expect(!isActive());
    try std.testing.expect(eligible(false, false, false, false, true));
    try std.testing.expect(!eligible(true, false, false, false, true));
    try std.testing.expect(!eligible(false, true, false, false, true));
    try std.testing.expect(!eligible(false, false, true, false, true));
    try std.testing.expect(!eligible(false, false, false, true, true));
    try std.testing.expect(!eligible(false, false, false, false, false));
    try std.testing.expectEqualStrings("Compacting…", label);
}

test "compact status displays progress without animation and cleans up a failed scope" {
    const old_color = main.use_color;
    const old_json = main.json_mode;
    main.use_color = false;
    main.json_mode = false;
    defer main.use_color = old_color;
    defer main.json_mode = old_json;
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var agent: Agent = undefined;
    agent.sub = false;
    agent.call_kind = .root;
    agent.stream_quiet = false;
    agent.out = &output.writer;
    agent.io = std.testing.io;
    var scope = begin(&agent);
    defer scope.end(&agent);
    try std.testing.expect(isActive());
    try std.testing.expectEqualStrings("Compacting…\n", output.written());
    var nested = begin(&agent);
    nested.end(&agent);
    try std.testing.expect(isActive());
    // This is the same deferred cleanup used on cancellation/request failure.
    scope.end(&agent);
    try std.testing.expect(!isActive());
}
