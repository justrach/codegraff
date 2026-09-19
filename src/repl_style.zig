//! Local ANSI style, rounded box, and line input for the scripted `graff repl`
//! Model. The Grok-style pager (`TUI/`) is the live fullscreen UI; this file
//! exists so piped/CI `graff repl` and Model unit tests do not vendor zigzag.

const std = @import("std");

pub const Color = union(enum) {
    none,
    brightBlack,
    green,
    red,
    rgb: struct { r: u8, g: u8, b: u8 },

    pub fn fromRgb(r: u8, g: u8, b: u8) Color {
        return .{ .rgb = .{ .r = r, .g = g, .b = b } };
    }
};

pub const Border = struct {
    pub const rounded = {};
};

pub const Style = struct {
    foreground: Color = .none,
    bold_on: bool = false,
    dim_on: bool = false,
    border_on: bool = false,
    border_fg: Color = .none,
    pad_left: u16 = 0,
    pad_right: u16 = 0,
    width_val: ?u16 = null,

    pub fn fg(self: Style, c: Color) Style {
        var s = self;
        s.foreground = c;
        return s;
    }
    pub fn bold(self: Style, v: bool) Style {
        var s = self;
        s.bold_on = v;
        return s;
    }
    pub fn dim(self: Style, v: bool) Style {
        var s = self;
        s.dim_on = v;
        return s;
    }
    pub fn borderAll(self: Style, _: anytype) Style {
        var s = self;
        s.border_on = true;
        return s;
    }
    pub fn borderForeground(self: Style, c: Color) Style {
        var s = self;
        s.border_fg = c;
        return s;
    }
    pub fn paddingLeft(self: Style, n: u16) Style {
        var s = self;
        s.pad_left = n;
        return s;
    }
    pub fn paddingRight(self: Style, n: u16) Style {
        var s = self;
        s.pad_right = n;
        return s;
    }
    pub fn width(self: Style, n: u16) Style {
        var s = self;
        s.width_val = n;
        return s;
    }

    pub fn render(self: Style, allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
        if (self.border_on) return renderBox(self, allocator, text);
        return paint(allocator, self.foreground, self.bold_on, self.dim_on, text);
    }
};

fn sgr(c: Color) []const u8 {
    return switch (c) {
        .none => "",
        .brightBlack => "\x1b[90m",
        .green => "\x1b[32m",
        .red => "\x1b[31m",
        .rgb => "",
    };
}

fn paint(allocator: std.mem.Allocator, c: Color, bold_on: bool, dim_on: bool, text: []const u8) ![]const u8 {
    var open = std.array_list.Managed(u8).init(allocator);
    if (bold_on) try open.appendSlice("\x1b[1m");
    if (dim_on) try open.appendSlice("\x1b[2m");
    switch (c) {
        .rgb => |rgb| {
            const seq = try std.fmt.allocPrint(allocator, "\x1b[38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b });
            try open.appendSlice(seq);
        },
        else => {
            const seq = sgr(c);
            if (seq.len > 0) try open.appendSlice(seq);
        },
    }
    if (open.items.len == 0) return allocator.dupe(u8, text);
    return std.fmt.allocPrint(allocator, "{s}{s}\x1b[0m", .{ open.items, text });
}

fn visibleWidth(s: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            i += 1;
            if (i < s.len and s[i] == '[') {
                i += 1;
                while (i < s.len and !std.ascii.isAlphabetic(s[i])) i += 1;
                if (i < s.len) i += 1;
            } else if (i < s.len) {
                i += 1;
            }
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        w += 1;
        i += n;
    }
    return w;
}

fn renderBox(self: Style, allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const inner = self.width_val orelse 40;
    const content_w: usize = @max(@as(usize, 1), @as(usize, inner) -| self.pad_left -| self.pad_right);
    var lines = std.array_list.Managed([]const u8).init(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |ln| try lines.append(ln);
    if (lines.items.len == 0) try lines.append("");

    const bar_w = self.pad_left + content_w + self.pad_right;
    const edge = try paint(allocator, self.border_fg, false, false, "─");
    const tl = try paint(allocator, self.border_fg, false, false, "╭");
    const tr = try paint(allocator, self.border_fg, false, false, "╮");
    const bl = try paint(allocator, self.border_fg, false, false, "╰");
    const br = try paint(allocator, self.border_fg, false, false, "╯");
    const v = try paint(allocator, self.border_fg, false, false, "│");

    var out = std.array_list.Managed(u8).init(allocator);
    try out.appendSlice(tl);
    for (0..bar_w) |_| try out.appendSlice(edge);
    try out.appendSlice(tr);
    try out.append('\n');
    for (lines.items) |ln| {
        try out.appendSlice(v);
        for (0..self.pad_left) |_| try out.append(' ');
        try out.appendSlice(ln);
        const used = visibleWidth(ln);
        const pad = if (used < content_w) content_w - used else 0;
        for (0..pad) |_| try out.append(' ');
        for (0..self.pad_right) |_| try out.append(' ');
        try out.appendSlice(v);
        try out.append('\n');
    }
    try out.appendSlice(bl);
    for (0..bar_w) |_| try out.appendSlice(edge);
    try out.appendSlice(br);
    return out.toOwnedSlice();
}

/// Scripted Model input: prompt + value. No key handling — applyLine owns submit.
pub const TextInput = struct {
    alloc: std.mem.Allocator,
    value: std.array_list.Managed(u8),
    prompt: []const u8 = "> ",
    placeholder: []const u8 = "",

    pub fn init(alloc: std.mem.Allocator) TextInput {
        return .{ .alloc = alloc, .value = std.array_list.Managed(u8).init(alloc) };
    }
    pub fn deinit(self: *TextInput) void {
        self.value.deinit();
    }
    pub fn setPrompt(self: *TextInput, text: []const u8) void {
        self.prompt = text;
    }
    pub fn setPlaceholder(self: *TextInput, text: []const u8) void {
        self.placeholder = text;
    }
    pub fn setValue(self: *TextInput, text: []const u8) !void {
        self.value.clearRetainingCapacity();
        try self.value.appendSlice(text);
    }
    pub fn getValue(self: *const TextInput) []const u8 {
        return self.value.items;
    }
    pub fn view(self: *const TextInput, allocator: std.mem.Allocator) ![]const u8 {
        const body = if (self.value.items.len == 0) self.placeholder else self.value.items;
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ self.prompt, body });
    }
};

test "paint wraps SGR and box contains the body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const painted = try (Style{}).fg(.green).bold(true).render(a, "ok");
    try std.testing.expect(std.mem.indexOf(u8, painted, "ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, painted, "\x1b[32m") != null);
    const box = try (Style{}).borderAll(Border.rounded).paddingLeft(1).paddingRight(1).width(20).render(a, "Welcome to graff repl");
    try std.testing.expect(std.mem.indexOf(u8, box, "Welcome to graff repl") != null);
    try std.testing.expect(std.mem.indexOf(u8, box, "╭") != null);
}
