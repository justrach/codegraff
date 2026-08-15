//! Slash / palette catalog: Grok Build's pager commands plus the harness
//! session set, so `/` and Ctrl+P feel like grok and still drive codegraff.

const std = @import("std");

pub const Item = struct {
    name: []const u8,
    desc: []const u8,
    aliases: []const []const u8 = &.{},
};

pub const items = [_]Item{
    .{ .name = "/new", .desc = "Start a fresh session", .aliases = &.{"/clear"} },
    .{ .name = "/home", .desc = "Return to the welcome screen", .aliases = &.{"/welcome"} },
    .{ .name = "/compact", .desc = "Engine-compact model-visible history" },
    .{ .name = "/resume", .desc = "Resume a saved session", .aliases = &.{"/sessions"} },
    .{ .name = "/context", .desc = "Show context-window use" },
    .{ .name = "/session-info", .desc = "Session details", .aliases = &.{ "/status", "/info" } },
    .{ .name = "/usage", .desc = "Token usage and cost", .aliases = &.{"/cost"} },
    .{ .name = "/debug", .desc = "Live observability HUD" },
    .{ .name = "/rewind", .desc = "Undo the last turn", .aliases = &.{"/undo"} },
    .{ .name = "/quit", .desc = "Quit", .aliases = &.{ "/exit", "/q" } },
    .{ .name = "/rename", .desc = "Rename this session", .aliases = &.{"/title"} },
    .{ .name = "/model", .desc = "Switch model", .aliases = &.{ "/m", "/models" } },
    .{ .name = "/settings", .desc = "Model, effort, mode, theme", .aliases = &.{ "/set", "/config" } },
    .{ .name = "/effort", .desc = "Reasoning depth (menu or low|medium|…)", .aliases = &.{"/reasoning"} },
    .{ .name = "/always-approve", .desc = "Skip permission prompts", .aliases = &.{ "/yolo", "/auto" } },
    .{ .name = "/multiline", .desc = "Toggle multiline input", .aliases = &.{"/ml"} },
    .{ .name = "/history", .desc = "Search prompt history" },
    .{ .name = "/compact-mode", .desc = "Tighter padding" },
    .{ .name = "/plan", .desc = "Toggle plan mode" },
    .{ .name = "/theme", .desc = "Switch color theme", .aliases = &.{"/t"} },
    .{ .name = "/goal", .desc = "Set a standing objective" },
    .{ .name = "/thinking", .desc = "Show live reasoning" },
    .{ .name = "/fast", .desc = "Priority service tier" },
    .{ .name = "/ultracode", .desc = "Persistent workflow mode", .aliases = &.{"/ult"} },
    .{ .name = "/strict", .desc = "Every message is a tool" },
    .{ .name = "/image", .desc = "Attach an image to the next message" },
    .{ .name = "/paste", .desc = "Attach the clipboard image (Ctrl+V)" },
    .{ .name = "/import-claude", .desc = "Adopt Claude and Cursor MCP + skills into graff folders" },
    .{ .name = "/jump", .desc = "Jump to a previous turn" },
    .{ .name = "/copy", .desc = "Copy the last reply to the clipboard" },
    .{ .name = "/btw", .desc = "Queue an aside without interrupting" },
    .{ .name = "/vim-mode", .desc = "Vim keys in the scrollback", .aliases = &.{"/vim"} },
    .{ .name = "/help", .desc = "List commands" },
    .{ .name = "/doctor", .desc = "Health check" },
    .{ .name = "/shortcuts", .desc = "Keyboard shortcuts", .aliases = &.{"/keys"} },
};

pub fn matches(item: Item, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (containsIgnoreCase(item.name, needle) or containsIgnoreCase(item.desc, needle)) return true;
    for (item.aliases) |a| {
        if (containsIgnoreCase(a, needle)) return true;
    }
    return false;
}

pub fn lookup(token: []const u8) ?Item {
    for (items) |it| {
        if (eqlIgnoreCase(it.name, token)) return it;
        for (it.aliases) |a| {
            if (eqlIgnoreCase(a, token)) return it;
        }
    }
    return null;
}

pub fn filter(needle: []const u8, out: []usize) usize {
    var n: usize = 0;
    for (items, 0..) |it, i| {
        if (!matches(it, needle)) continue;
        if (n >= out.len) break;
        out[n] = i;
        n += 1;
    }
    return n;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "filter: slash prefix and alias" {
    var buf: [items.len]usize = undefined;
    try std.testing.expect(filter("rew", &buf) >= 1);
    try std.testing.expect(lookup("/undo") != null);
    try std.testing.expect(lookup("/yolo") != null);
    try std.testing.expect(lookup("/debug") != null);
    try std.testing.expect(lookup("/cost") != null);
    try std.testing.expect(lookup("/not-a-cmd") == null);
}

test "catalog names start with slash" {
    for (items) |it| try std.testing.expect(it.name.len > 1 and it.name[0] == '/');
}
