//! Codegraff fullscreen TUI — Grok Build pager UX, no zigzag.
//! Live entry: `graff tui` and TTY `graff repl`.

const std = @import("std");

const app = @import("app.zig");
const engine = @import("engine.zig");
const run_mod = @import("run.zig");

pub const Model = app.Model;
pub const Screen = app.Screen;
pub const Focus = app.Focus;
pub const Overlay = app.Overlay;
pub const AgentMode = app.AgentMode;
pub const Effort = engine.Effort;
pub const HudKind = engine.HudKind;
pub const Turn = engine.Turn;
pub const Params = engine.Params;
pub const StreamBuf = engine.StreamBuf;
pub const TurnFn = engine.TurnFn;
pub const ModelFn = engine.ModelFn;
pub const CancelFn = engine.CancelFn;
pub const CompactOut = engine.CompactOut;
pub const CompactFn = engine.CompactFn;
pub const RunOpts = run_mod.RunOpts;
pub const run = run_mod.run;
pub const restore = @import("restore.zig");
/// Restore the terminal BEFORE std prints a panic, or the alt-screen exit in
/// the restore sequence erases the message and the stack trace (#535).
pub const panic = restore.Panic;
pub const theme = @import("theme.zig");
pub const catalog = @import("catalog.zig");
pub const dump = @import("dump.zig");
pub const sim = @import("sim.zig");

test {
    _ = engine;
    _ = theme;
    _ = catalog;
    _ = app;
    _ = @import("dispatch.zig");
    _ = @import("key.zig");
    _ = @import("key_orphan.zig");
    _ = @import("key_tests.zig");
    _ = @import("spec_terminal_modes_conformance.zig");
    _ = @import("key_loop_tests.zig");
    _ = @import("input.zig");
    _ = @import("keys.zig");
    _ = @import("nav.zig");
    _ = @import("image.zig");
    _ = @import("turn.zig");
    _ = @import("bgop.zig");
    _ = @import("welcome.zig");
    _ = @import("scrollback.zig");
    _ = @import("chrome.zig");
    _ = @import("models.zig");
    _ = @import("markdown.zig");
    _ = @import("syntax.zig");
    _ = @import("dump.zig");
    _ = @import("effort.zig");
    _ = @import("sim.zig");
    _ = @import("render.zig");
    _ = @import("tty.zig");
    _ = @import("restore.zig");
    _ = @import("files.zig");
    _ = @import("overlays.zig");
    _ = run_mod;
    _ = @import("traj.zig");
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io, init.environ_map, .{ .cwd = "." });
}
