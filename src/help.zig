//! /help, organized for humans: the flat command catalog grouped into themes
//! with plain-language headers and a short prose explainer where a one-line
//! desc cannot carry the semantics (today: who hears what on the #469 peer
//! channel). Command names/usages/descs still come from command_catalog — this
//! file only chooses the grouping, and its test fails the suite the day a new
//! command ships without a section, so help can never quietly drift.

const std = @import("std");
const Io = std.Io;
const command_catalog = @import("command_catalog.zig");

pub const Section = struct {
    title: []const u8,
    names: []const []const u8,
    /// Prose printed under the section's commands (leading spaces included).
    blurb: []const u8 = "",
};

const peers_blurb =
    \\    how hearing works: graff sessions in the SAME folder hear each other's
    \\    coordination posts automatically — announce what you're restructuring,
    \\    ask the others to hold off a file, split the work. Nothing crosses
    \\    folders unless it names your session or comes from you: /tell to one
    \\    session is a DM (only it hears, any folder), /tell all is YOUR
    \\    broadcast to every graff on this device. Other folders' chatter
    \\    collapses into a one-line "skipped" marker, never a wall of text.
    \\
;

pub const sections = [_]Section{
    .{ .title = "getting around", .names = &.{ "/new", "/clear", "/resume", "/save", "/sessions", "/rename", "/rewind" } },
    .{ .title = "the model", .names = &.{ "/model", "/models", "/effort", "/reasoning", "/fast", "/thinking", "/keepcontext", "/fallback", "/routes" } },
    .{ .title = "working autonomously", .names = &.{ "/goal", "/loop", "/review", "/plan", "/todo", "/jobs", "/ultracode", "/strict", "/yolo", "/never" } },
    .{ .title = "talking to other graffs", .names = &.{ "/tell", "/peek" }, .blurb = peers_blurb },
    .{ .title = "your setup", .names = &.{ "/login", "/key", "/cost", "/usage", "/privacy", "/mcp", "/skills", "/agents", "/hooks", "/tools", "/fleet" } },
    .{ .title = "context & history", .names = &.{ "/compact", "/btw", "/doctor", "/debug", "/trace", "/trajectory" } },
    .{ .title = "shell & images", .names = &.{ "/bash", "/image", "/images", "/paste" } },
    .{ .title = "look & feel", .names = &.{ "/theme", "/animation", "/title" } },
    .{ .title = "this list", .names = &.{"/help"} },
};

fn find(name: []const u8) ?command_catalog.Item {
    for (command_catalog.commands) |cmd| if (std.mem.eql(u8, cmd.name, name)) return cmd;
    return null;
}

pub fn render(out: *Io.Writer) !void {
    try out.writeAll("graff — type naturally; bare / opens the filterable menu. commands by theme:\n");
    for (sections) |sec| {
        try out.print("\n  {s}\n", .{sec.title});
        for (sec.names) |name| {
            const cmd = find(name) orelse continue;
            const usage = if (cmd.usage.len > 0) cmd.usage else cmd.name;
            try out.print("    {s:<28} {s}\n", .{ usage, cmd.desc });
        }
        if (sec.blurb.len > 0) try out.writeAll(sec.blurb);
    }
    try out.writeAll(
        \\
        \\  exit | /exit | /quit             quit (also ctrl-d or ctrl-c on an empty line)
        \\
        \\esc during a response interrupts the turn; streamed output remains in history.
        \\"always allow" answers persist to .harness/settings.json in the cwd.
        \\launch flags: --model <name> · --yolo · -p "prompt" · --json · --help · --version
        \\subcommands: graff login [codex] · graff key set <provider> <key> · graff --schema
        \\
    );
}

test "every catalog command appears in exactly one /help section" {
    for (command_catalog.commands) |cmd| {
        var count: usize = 0;
        for (sections) |sec| {
            for (sec.names) |name| {
                if (std.mem.eql(u8, name, cmd.name)) count += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), count);
    }
}

test "render prints every section title, the peers blurb, and the exit footer" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try render(&aw.writer);
    const text = aw.writer.buffered();
    for (sections) |sec| try std.testing.expect(std.mem.indexOf(u8, text, sec.title) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "how hearing works") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "exit | /exit | /quit") != null);
}
