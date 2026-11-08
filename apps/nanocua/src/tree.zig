//! The accessibility tree as text for a model: one line per element worth
//! naming, indented by depth, with a ref to act on it. Containers with
//! nothing to say (a group with no title) are left out and their children
//! moved up, which keeps deep web pages and toolbars short.
const std = @import("std");

pub const Node = struct {
    /// "AXButton", as the platform names it; written without "AX".
    role: []const u8,
    subrole: []const u8 = "",
    title: []const u8 = "",
    description: []const u8 = "",
    value: []const u8 = "",
    /// x, y, width, height in screen points.
    frame: ?[4]f64 = null,
    enabled: bool = true,
    focused: bool = false,
    selected: bool = false,
};

/// Keep all readable content by default; geometry is opt-in for coordinate work.
pub const Options = struct {
    max_nodes: usize = 400,
    menus: bool = false,
    interactive_only: bool = false,
    include_frames: bool = false,

    pub fn fromArgs(a: @import("tools.zig").Args) Options {
        return .{
            .max_nodes = @intCast(std.math.clamp(a.int("max_nodes") orelse 400, 1, 2000)),
            .interactive_only = a.boolean("interactive_only") orelse false,
            .include_frames = a.boolean("include_frames") orelse false,
        };
    }

    pub fn includes(o: Options, n: Node) bool {
        if (!o.interactive_only) return shown(n);
        // Keep window context and selected/focused content, even custom roles.
        // Images are not controls unless focused or selected.
        return n.focused or n.selected or
            (in(bare(n.role), &actionable) and !std.mem.eql(u8, bare(n.role), "Image")) or
            std.mem.eql(u8, bare(n.subrole), "SearchField");
    }

    pub fn write(o: Options, w: *std.Io.Writer, n: Node, ref: u32, depth: usize) !void {
        var node = n;
        if (!o.include_frames) node.frame = null;
        try writeLine(w, node, ref, depth);
    }
};

/// Roles a model may act on, named even when they say nothing.
const actionable = [_][]const u8{
    "Button",      "CheckBox",           "RadioButton", "TextField", "TextArea", "SecureTextField", "ComboBox", "PopUpButton",
    "MenuItem",    "MenuButton",         "MenuBarItem", "Slider",    "Link",     "Tab",             "Cell",     "Row",
    "Incrementor", "DisclosureTriangle", "SearchField", "Window",    "Sheet",    "Dialog",          "Image",    "ColorWell",
};

/// Roles that are only containers.
const plumbing = [_][]const u8{ "Group", "Unknown", "SplitGroup", "ScrollArea", "LayoutArea", "LayoutItem", "Splitter", "Matte", "Column" };

fn bare(role: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, role, "AX")) role[2..] else role;
}

/// A role as it reads in a reply: "Button".
pub const bareRole = bare;

/// Roles an accessibility press does what a click would.
const pressed = [_][]const u8{ "Button", "CheckBox", "RadioButton", "PopUpButton", "MenuButton", "MenuItem", "MenuBarItem", "Link", "DisclosureTriangle", "Incrementor" };

pub fn pressable(role: []const u8) bool {
    return in(bare(role), &pressed);
}

/// Roles that are likely a control's label or icon, so its control is above.
pub fn insideControl(role: []const u8) bool {
    return in(bare(role), &.{ "StaticText", "Image" });
}

fn in(s: []const u8, list: []const []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, s, x)) return true;
    return false;
}

/// Whether the node gets a line (and a ref).
pub fn shown(n: Node) bool {
    const r = bare(n.role);
    if (in(r, &actionable)) return true;
    if (n.title.len > 0 or n.description.len > 0) return true;
    if (n.value.len > 0 and !in(r, &plumbing)) return true;
    if (in(r, &plumbing)) return false;
    // Static text with nothing in it, separators, and the like.
    return !std.mem.eql(u8, r, "StaticText") and !std.mem.eql(u8, r, "Splitter");
}

/// Writes `n`'s line: `  [12] Button "Save" (desc) value="…" @x,y wxh`.
pub fn writeLine(w: *std.Io.Writer, n: Node, ref: u32, depth: usize) !void {
    try w.splatByteAll(' ', @min(depth, 40) * 2);
    try w.print("[{d}] {s}", .{ ref, bare(n.role) });
    if (n.subrole.len > 0 and !std.mem.eql(u8, bare(n.subrole), bare(n.role))) try w.print("/{s}", .{bare(n.subrole)});
    if (n.title.len > 0) try quoted(w, " ", n.title, 120);
    if (n.description.len > 0 and !std.mem.eql(u8, n.description, n.title)) try quoted(w, " desc=", n.description, 120);
    if (n.value.len > 0 and !std.mem.eql(u8, n.value, n.title)) try quoted(w, " value=", n.value, 200);
    if (n.frame) |f| try w.print(" @{d:.0},{d:.0} {d:.0}x{d:.0}", .{ f[0], f[1], f[2], f[3] });
    if (!n.enabled) try w.writeAll(" disabled");
    if (n.focused) try w.writeAll(" focused");
    if (n.selected) try w.writeAll(" selected");
    try w.writeByte('\n');
}

/// `s` in quotes on one line, cut after `max` bytes at a character's start.
fn quoted(w: *std.Io.Writer, prefix: []const u8, s: []const u8, max: usize) !void {
    var end = @min(s.len, max);
    while (end < s.len and end > 0 and (s[end] & 0xc0) == 0x80) end -= 1;
    try w.writeAll(prefix);
    try w.writeByte('"');
    for (s[0..end]) |ch| switch (ch) {
        '\n' => try w.writeAll("\\n"),
        '"' => try w.writeAll("\\\""),
        '\r', '\t' => try w.writeByte(' '),
        else => try w.writeByte(ch),
    };
    if (end < s.len) try w.writeAll("…");
    try w.writeByte('"');
}

test "what a press reaches" {
    try std.testing.expect(pressable("AXButton") and pressable("AXLink"));
    try std.testing.expect(!pressable("AXTextArea") and !pressable("AXGroup"));
    try std.testing.expect(insideControl("AXStaticText") and !insideControl("AXTextArea"));
    try std.testing.expectEqualStrings("Button", bareRole("AXButton"));
}

test "lines name what can be acted on and skip plumbing" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expect(!shown(.{ .role = "AXGroup" }));
    try std.testing.expect(shown(.{ .role = "AXGroup", .title = "Sidebar" }));
    try std.testing.expect(shown(.{ .role = "AXButton" }));
    try std.testing.expect(!shown(.{ .role = "AXStaticText" }));
    try std.testing.expect(shown(.{ .role = "AXStaticText", .value = "Hello" }));
    try writeLine(&w, .{ .role = "AXButton", .title = "Save", .description = "Save", .frame = .{ 10, 20.4, 80, 24 }, .enabled = false }, 3, 1);
    try writeLine(&w, .{ .role = "AXTextField", .subrole = "AXSearchField", .value = "a \"b\"\nc", .focused = true }, 4, 0);
    try std.testing.expectEqualStrings(
        \\  [3] Button "Save" @10,20 80x24 disabled
        \\[4] TextField/SearchField value="a \"b\"\nc" focused
        \\
    , w.buffered());
    w = .fixed(&buf);
    const long: [300]u8 = @splat('x');
    try writeLine(&w, .{ .role = "AXStaticText", .value = &long }, 5, 0);
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "x…\"\n"));
}

test "tree read options preserve defaults and clamp limits" {
    const Args = @import("tools.zig").Args;
    const defaults = Options.fromArgs(.{ .obj = null });
    try std.testing.expectEqual(@as(usize, 400), defaults.max_nodes);
    try std.testing.expect(!defaults.interactive_only and !defaults.include_frames);
    const cases = [_]struct { json: []const u8, max: usize, interactive: bool, frames: bool }{
        .{ .json = "{\"max_nodes\":0,\"interactive_only\":true,\"include_frames\":false}", .max = 1, .interactive = true, .frames = false },
        .{ .json = "{\"max_nodes\":9000,\"interactive_only\":false,\"include_frames\":true}", .max = 2000, .interactive = false, .frames = true },
        .{ .json = "{\"max_nodes\":\"bad\",\"interactive_only\":1,\"include_frames\":\"false\"}", .max = 400, .interactive = false, .frames = false },
    };
    for (cases) |case| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, case.json, .{});
        defer parsed.deinit();
        const opts = Options.fromArgs(Args.of(parsed.value));
        try std.testing.expectEqual(case.max, opts.max_nodes);
        try std.testing.expectEqual(case.interactive, opts.interactive_only);
        try std.testing.expectEqual(case.frames, opts.include_frames);
    }
}

test "default reads retain results, labels and state with opt-in geometry" {
    const opts: Options = .{};
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const result: Node = .{ .role = "AXStaticText", .value = "42", .frame = .{ 1, 2, 30, 40 } };
    const field: Node = .{ .role = "AXTextField", .title = "Email", .value = "bad", .focused = true, .selected = true, .enabled = false, .frame = .{ 1, 2, 30, 40 } };
    try std.testing.expect(opts.includes(result) and opts.includes(field));
    try opts.write(&w, result, 7, 0);
    try opts.write(&w, field, 8, 1);
    try std.testing.expectEqualStrings("[7] StaticText value=\"42\"\n  [8] TextField \"Email\" value=\"bad\" disabled focused selected\n", w.buffered());
    w = .fixed(&buf);
    try (Options{ .include_frames = true }).write(&w, result, 7, 0);
    try std.testing.expectEqualStrings("[7] StaticText value=\"42\" @1,2 30x40\n", w.buffered());
}

test "controls view keeps context and state but not decorative content" {
    const opts: Options = .{ .interactive_only = true, .include_frames = false };
    for (actionable) |role| {
        try std.testing.expectEqual(!std.mem.eql(u8, role, "Image"), opts.includes(.{ .role = role }));
    }
    try std.testing.expect(opts.includes(.{ .role = "AXGroup", .focused = true }));
    try std.testing.expect(opts.includes(.{ .role = "AXStaticText", .value = "chosen", .selected = true }));
    try std.testing.expect(opts.includes(.{ .role = "AXUnknown", .subrole = "AXSearchField" }));
    try std.testing.expect(!opts.includes(.{ .role = "AXGroup", .title = "Sidebar" }));
    const result: Node = .{ .role = "AXStaticText", .value = "42" };
    try std.testing.expect(!opts.includes(result));
    try std.testing.expect((Options{}).includes(result));
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try opts.write(&w, .{ .role = "AXTextField", .value = "hello", .frame = .{ 1, 2, 30, 40 }, .focused = true, .enabled = false }, 7, 1);
    try std.testing.expectEqualStrings("  [7] TextField value=\"hello\" disabled focused\n", w.buffered());
}

test "synthetic observation size comparison uses the real serializer" {
    const gpa = std.testing.allocator;
    var full: std.Io.Writer.Allocating = .init(gpa);
    defer full.deinit();
    var controls: std.Io.Writer.Allocating = .init(gpa);
    defer controls.deinit();
    var no_frames: std.Io.Writer.Allocating = .init(gpa);
    defer no_frames.deinit();
    var legacy: std.Io.Writer.Allocating = .init(gpa);
    defer legacy.deinit();
    const compact: Options = .{ .interactive_only = true, .include_frames = false };
    var ref: u32 = 0;
    // A synthetic text-heavy screen: 80 paragraphs and 20 buttons. Not a
    // live-app or model-billing benchmark; only serialized observation bytes.
    for (0..100) |i| {
        const n: Node = if (i % 5 == 0)
            .{ .role = "AXButton", .title = "Continue", .frame = .{ 10, 20, 120, 30 } }
        else
            .{ .role = "AXStaticText", .value = "A paragraph of content the agent need not read while navigating controls.", .frame = .{ 10, 60, 500, 24 } };
        const old_ref: u32 = @intCast(i + 1);
        try writeLine(&legacy.writer, n, old_ref, 0);
        try (Options{ .include_frames = true }).write(&full.writer, n, old_ref, 0);
        try (Options{ .include_frames = false }).write(&no_frames.writer, n, old_ref, 0);
        if (compact.includes(n)) {
            ref += 1;
            try compact.write(&controls.writer, n, ref, 0);
        }
    }
    try std.testing.expectEqualStrings(legacy.written(), full.written());
    try std.testing.expectEqual(@as(u32, 20), ref);
    try std.testing.expect(controls.written().len < full.written().len / 2);
    try std.testing.expect(no_frames.written().len < full.written().len);
    std.debug.print("synthetic observation bytes: full={d}, no_frames={d}, controls_no_frames={d}\n", .{
        full.written().len, no_frames.written().len, controls.written().len,
    });
}
