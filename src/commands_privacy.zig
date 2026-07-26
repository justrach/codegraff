//! `/privacy`: session-scoped prompt-learning egress controls.

const std = @import("std");
const Io = std.Io;
const Agent = @import("agent.zig").Agent;
const privacy = @import("learning_privacy.zig");

fn printStatus(out: *Io.Writer) !void {
    const mode = privacy.current();
    try out.print("learning privacy: {s}\n", .{mode.label()});
    try out.writeAll(
        \\  local       no background learning egress; learn_candidate may ask to send one aggregate receipt
        \\  aggregate   signed grades, counts, buckets, and public strategy IDs; no prompt text
        \\  templates   aggregate + individually reviewed reusable persona/template text
        \\  examples    templates + a future one-shot reviewed-example channel
        \\
        \\This controls learning/fleet egress, not requests to your selected model provider
        \\or ordinary operational telemetry. Template approval is exact and session-local;
        \\--yolo cannot bypass it. Raw task prompts, bindings, reports, and traces have no
        \\learning upload path in this build.
        \\
    );
}

/// Marker for the one-time contribution disclosure. Per machine, not per
/// workspace: the fact that learning contributes by default is a property of
/// the install.
const notice_file = ".simple-harness-learning-notice";

/// Say it once, out loud, the first time a session could contribute: a default
/// that ships silently is not consent. Best-effort — if the marker cannot be
/// written the notice simply appears again next time.
pub fn firstRunNotice(io: Io, arena: std.mem.Allocator, home: []const u8, out: *Io.Writer) void {
    if (home.len == 0 or !privacy.allowsAggregate()) return;
    const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ home, notice_file }) catch return;
    const file = Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true }) catch return;
    file.close(io);
    out.writeAll(
        \\learning: this build contributes prompt-free aggregate grades (counts, deltas,
        \\significance, fingerprints) from local learning trials — never prompt text, code,
        \\paths, or traces. Turn it off with /privacy local, GRAFF_LEARNING_PRIVACY=local,
        \\or GRAFF_FLEET=off. Shown once.
        \\
    ) catch return;
    out.flush() catch {};
}

pub fn tryHandle(root: *Agent, line: []const u8, out: *Io.Writer) !bool {
    if (!std.mem.eql(u8, line, "/privacy") and !std.mem.startsWith(u8, line, "/privacy ")) return false;
    const arg = std.mem.trim(u8, line["/privacy".len..], " \t");
    if (arg.len == 0 or std.mem.eql(u8, arg, "status")) {
        try printStatus(out);
        try out.flush();
        return true;
    }
    const mode = privacy.parse(arg) orelse {
        try out.writeAll("usage: /privacy [status|local|aggregate|templates|examples]\n");
        try out.flush();
        return true;
    };
    privacy.setMode(root.io, mode);
    switch (mode) {
        .local => try out.writeAll("learning privacy → Local; background fleet contribution is off and prior approvals are revoked. learn_candidate must ask separately to send once.\n"),
        .aggregate => try out.writeAll("learning privacy → Aggregate; signed grades and prompt-free fleet metadata may be sent.\n"),
        .templates => try out.writeAll("learning privacy → Templates; each private reusable prompt still needs an exact preview approval.\n"),
        .examples => try out.writeAll("learning privacy → Examples ceiling; templates still need approval, and raw-example upload is not implemented yet.\n"),
    }
    try out.flush();
    return true;
}
