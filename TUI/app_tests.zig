//! Tests for TUI/app.zig, split out so app.zig stays under 600 lines.

const std = @import("std");
const app = @import("app.zig");
const Model = app.Model;
const AgentMode = app.AgentMode;
const Screen = app.Screen;

test "cycleMode walks Normal → Plan → Always-approve" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try std.testing.expectEqual(AgentMode.normal, m.mode);
    m.cycleMode();
    try std.testing.expectEqual(AgentMode.plan, m.mode);
    m.cycleMode();
    try std.testing.expectEqual(AgentMode.always_approve, m.mode);
}

test "push user flips welcome to agent" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try std.testing.expectEqual(Screen.welcome, m.screen);
    try m.push(.user, "hi");
    try std.testing.expectEqual(Screen.agent, m.screen);
}

test "push strips raw ANSI, OSC, and CR from tool text" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.tool, "⚙ bash | \x1b[31mred\x1b[0m\x1b]0;title\x07 done\r");
    try std.testing.expectEqualStrings("⚙ bash | red done", m.history.items[0].text);
    // No ESC and no CR — the old fast path would have kept these.
    try m.push(.assistant, "beep\x07back\x08null\x00done");
    try std.testing.expectEqualStrings("beepbacknulldone", m.history.items[1].text);
}
