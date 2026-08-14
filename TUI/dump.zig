//! Visible-terminal dump and layout debug for the pager frame.
//! Strips SGR / Kitty APC so a reader sees the same glyphs as a user.
//! Agents that need to type or click use TUI/sim.zig (`Term`), not a PTY.

const std = @import("std");
const app = @import("app.zig");
const Model = app.Model;

/// SGR/APC/OSC stripped; one screen row per line. Caller owns the slice.
pub fn visible(a: std.mem.Allocator, frame: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(a);
    var i: usize = 0;
    while (i < frame.len) {
        if (frame[i] == 0x1b) {
            i = skipEsc(frame, i);
            continue;
        }
        if (frame[i] == '\r') {
            i += 1;
            continue;
        }
        try out.append(frame[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

fn skipEsc(s: []const u8, start: usize) usize {
    var i = start + 1;
    if (i >= s.len) return s.len;
    const c = s[i];
    if (c == '[') {
        i += 1;
        while (i < s.len and (s[i] < 0x40 or s[i] > 0x7e)) i += 1;
        if (i < s.len) i += 1;
        return i;
    }
    // OSC ]  DCS P  SOS X  PM ^  APC _  (Kitty graphics is APC _G)
    if (c == ']' or c == 'P' or c == 'X' or c == '^' or c == '_') {
        i += 1;
        while (i < s.len) {
            if (s[i] == 0x07) return i + 1;
            if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '\\') return i + 2;
            i += 1;
        }
        return i;
    }
    return i + 1;
}

/// Layout the cost HUD does not show. Stack buffer; no allocation.
pub fn layoutBuf(buf: []u8, self: *const Model) []const u8 {
    return std.fmt.bufPrint(buf,
        \\layout
        \\  overlay       {s}
        \\  focus         {s}
        \\  prompt-origin {d}
        \\  mid-origin    {d}
        \\  images        {d}
        \\  pending       {s}
        \\
    , .{
        @tagName(self.overlay),
        @tagName(self.focus),
        self.prompt_origin,
        self.mid_origin,
        self.images.items.len,
        if (self.pending != null) "yes" else "no",
    }) catch "";
}

pub fn layout(a: std.mem.Allocator, self: *const Model) ![]u8 {
    var buf: [256]u8 = undefined;
    return a.dupe(u8, layoutBuf(&buf, self));
}

test "visible strips SGR and Kitty APC and keeps row breaks" {
    const raw = "\x1b[32mhi\x1b[0m\n\x1b_Ga=T,f=100,t=f;abc\x1b\\there\n";
    const got = try visible(std.testing.allocator, raw);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hi\nthere\n", got);
    try std.testing.expect(std.mem.indexOf(u8, got, "\x1b") == null);
}

test "layout names overlay focus origins images pending" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.prompt_origin = 18;
    m.mid_origin = 1;
    m.attachImage("/tmp/a.png");
    const text = try layout(std.testing.allocator, &m);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "overlay       none") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "focus         prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "prompt-origin 18") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mid-origin    1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "images        1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pending       no") != null);
    m.openOverlay(.debug);
    const after = try layout(std.testing.allocator, &m);
    defer std.testing.allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "overlay       debug") != null);
}
