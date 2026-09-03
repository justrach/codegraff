//! Who cancelled the turn (#728). `Agent.esc_cancel` is one process-wide
//! bool with six setters — a lone Esc on raw stdin, a double-Enter force
//! steer, a `--json` cancel line, an ACP session/cancel, the TUI's cancel —
//! and the turn-ending marker always read "[response interrupted by user]".
//! When the flag flips for any other reason, that label is wrong twice: it
//! blames the user, and it leaves no trace of the real source. Every setter
//! now goes through `cancel(source)`, and mainloop reads the source back: a
//! turn that ends cancelled with no recorded source is labelled a harness
//! cancel, not a user interrupt, and the source lands in the trace.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const main_mod = @import("main.zig");
const Tracer = @import("trace.zig").Tracer;

pub const Source = enum(u8) {
    /// Nobody recorded one: the harness ended the turn, not the user.
    none,
    /// A lone Esc on the line REPL's raw stdin.
    esc_key,
    /// Double Enter with a queued steer line (escPressed marks it force).
    force_steer,
    /// --json `{"type":"cancel"}`.
    json_cancel,
    /// ACP `session/cancel`.
    acp_cancel,
    /// The fullscreen TUI's Esc / Ctrl+C / force / quit.
    ui_cancel,
};

var source: std.atomic.Value(u8) = .init(0);

/// Raise the flag and remember who did.
pub fn cancel(s: Source) void {
    source.store(@intFromEnum(s), .release);
    Agent.esc_cancel.store(true, .release);
}

/// A cancel that came off raw stdin: a double Enter with a queued steer
/// line is the force path, anything else is a real Esc.
pub fn cancelFromStdin() void {
    cancel(if (main_mod.g_force_interrupt) .force_steer else .esc_key);
}

/// Fresh turn: the flag and the source clear together.
pub fn clear() void {
    Agent.esc_cancel.store(false, .release);
    source.store(0, .release);
}

/// The source of the cancel that just ended a turn; consumed, and traced
/// (`interrupted source=…`) so the next false interrupt can be attributed.
pub fn take(tracer: ?*Tracer) Source {
    const s: Source = @enumFromInt(source.swap(0, .acq_rel));
    if (tracer) |tr| {
        var buf: [48]u8 = undefined;
        tr.note("turn", note(&buf, s));
    }
    return s;
}

pub fn byUser(s: Source) bool {
    return s != .none;
}

/// The transcript marker appended as the (incomplete) assistant turn.
pub fn marker(s: Source) []const u8 {
    return if (byUser(s)) "[response interrupted by user]" else "[response ended early: cancelled by the harness, not the user]";
}

/// The yellow chrome line the line REPL prints.
pub fn chrome(s: Source) []const u8 {
    return switch (s) {
        .esc_key => "✗ interrupted (esc)",
        .force_steer => "✗ interrupted (force)",
        .json_cancel, .acp_cancel, .ui_cancel => "✗ interrupted (cancel)",
        .none => "✗ ended early (harness cancel — no user action recorded)",
    };
}

/// The --json error message.
pub fn jsonMessage(s: Source) []const u8 {
    return if (byUser(s)) "turn cancelled" else "turn cancelled by the harness (no user cancel recorded)";
}

/// The trace note: `interrupted source=esc_key`.
pub fn note(buf: []u8, s: Source) []const u8 {
    return std.fmt.bufPrint(buf, "interrupted source={t}", .{s}) catch "interrupted";
}

test "cancel raises the flag with its source; take consumes; clear drops both" {
    clear();
    try std.testing.expectEqual(Source.none, take(null));
    cancel(.json_cancel);
    try std.testing.expect(Agent.esc_cancel.load(.acquire));
    try std.testing.expectEqual(Source.json_cancel, take(null));
    try std.testing.expectEqual(Source.none, take(null)); // consumed
    cancel(.acp_cancel);
    clear();
    try std.testing.expect(!Agent.esc_cancel.load(.acquire));
    try std.testing.expectEqual(Source.none, take(null));
}

test "cancelFromStdin is force after a double Enter, else Esc" {
    const saved = main_mod.g_force_interrupt;
    defer main_mod.g_force_interrupt = saved;
    main_mod.g_force_interrupt = true;
    cancelFromStdin();
    try std.testing.expectEqual(Source.force_steer, take(null));
    main_mod.g_force_interrupt = false;
    cancelFromStdin();
    try std.testing.expectEqual(Source.esc_key, take(null));
    clear();
}

test "#728: an unsourced cancel is labelled a harness cancel, never a user one" {
    try std.testing.expectEqualStrings("[response interrupted by user]", marker(.esc_key));
    try std.testing.expectEqualStrings("[response interrupted by user]", marker(.ui_cancel));
    try std.testing.expectEqualStrings("[response ended early: cancelled by the harness, not the user]", marker(.none));
    try std.testing.expect(std.mem.indexOf(u8, chrome(.none), "harness") != null);
    try std.testing.expect(std.mem.indexOf(u8, chrome(.force_steer), "force") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonMessage(.none), "harness") != null);
    try std.testing.expectEqualStrings("turn cancelled", jsonMessage(.json_cancel));
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("interrupted source=none", note(&buf, .none));
    try std.testing.expectEqualStrings("interrupted source=acp_cancel", note(&buf, .acp_cancel));
}
