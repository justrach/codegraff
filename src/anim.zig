//! Model-wait spinner animations + opt-in terminal color themes, plus the
//! settings persistence for both. Split out of main.zig (#123). Spinners
//! ported in spirit from arpagon/pi-animations (MIT).
//!
//! Imports ansi for the live color palette; back-imports main only for
//! Approvals.settings_path (the .harness/settings.json the theme/animation
//! prefs read from and write to). The spinner CONSUMERS (Agent.spinnerTask,
//! the /animation and /theme handlers) stay in main and call into here.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const ansi = @import("ansi.zig");
const style = &ansi.style;

const root = @import("main.zig");
const approvals_mod = @import("approvals.zig");
const Approvals = approvals_mod.Approvals;

// Named single-line indicators for the model-wait spinner, ported in spirit
// from arpagon/pi-animations (MIT). Plain Unicode + ANSI 256-color only (no
// Nerd Fonts), each frame ≤ ~30 columns. Selected via /animation, persisted
// as {"animation": "<name>"} in .harness/settings.json.

pub const Anim = struct {
    name: []const u8,
    desc: []const u8,
    frame_ms: u16,
    frame: *const fn (w: *Io.Writer, i: usize) Io.Writer.Error!void,
};

pub const anims = [_]Anim{
    .{ .name = "enso", .desc = "quiet brush-circle turn (default)", .frame_ms = 160, .frame = animEnso },
    .{ .name = "braille", .desc = "classic braille spinner", .frame_ms = 80, .frame = animBraille },
    .{ .name = "pulse", .desc = "pulsing star", .frame_ms = 100, .frame = animPulse },
    .{ .name = "orbit-dots", .desc = "dot orbiting a ring", .frame_ms = 100, .frame = animOrbit },
    .{ .name = "block-wave", .desc = "unicode block wave", .frame_ms = 80, .frame = animBlockWave },
    .{ .name = "shimmer", .desc = "highlight sweeping the word", .frame_ms = 100, .frame = animShimmer },
    .{ .name = "matrix", .desc = "matrix rain strip", .frame_ms = 80, .frame = animMatrix },
    .{ .name = "pacman", .desc = "pac-man eating dots", .frame_ms = 100, .frame = animPacman },
    .{ .name = "starfield", .desc = "parallax stars", .frame_ms = 100, .frame = animStarfield },
    .{ .name = "comet-tail", .desc = "streaking comet indicator", .frame_ms = 80, .frame = animCometTail },
};

pub var g_anim_index: usize = 0; // /animation selection (index into anims)
pub var g_anim_random = false; // the calm enso is stable by default; /animation random opts into variety
pub var g_anim_off = false; // /animation off
pub var g_anim_current: usize = 0; // what spinnerTask draws right now
// 🎂 Birthday easter egg (flagged, temporary) — when graff runs from
// limyuxi/yxlyx's home dir it paints her Ghostty white (OSC 11 bg + OSC 10 fg),
// reset on exit. Cosmetic and gated to her cwd, like the old dragon spinner.
// Flip to false / delete to remove after the bday.
pub const limyuxi_birthday_white = false; // retired: ship the default theme/spinner for everyone

// 🎂 yxlyx's birthday glam: a pastel-pink Ghostty theme — light pink bg, dark
// plum text, and a pink-leaning ANSI palette so graff's colored UI stays legible
// (every entry is dark/saturated enough to read on light pink). Reset with OSC
// 104/110/111/112 on exit. Paired with the "glitter" spinner; gated by the flag.
pub const limyuxi_theme =
    "\x1b]11;#fce4ec\x07" ++ // bg: pastel pink
    "\x1b]10;#4a1942\x07" ++ // fg: dark plum (~9:1 contrast)
    "\x1b]12;#d81b60\x07" ++ // cursor: hot pink
    "\x1b]4;0;#4a1942\x07\x1b]4;1;#c2185b\x07\x1b]4;2;#2e7d32\x07\x1b]4;3;#b26a00\x07" ++
    "\x1b]4;4;#6a1b9a\x07\x1b]4;5;#ad1457\x07\x1b]4;6;#00796b\x07\x1b]4;7;#5d4357\x07" ++
    "\x1b]4;8;#8a6680\x07\x1b]4;9;#e91e63\x07\x1b]4;10;#388e3c\x07\x1b]4;11;#c77800\x07" ++
    "\x1b]4;12;#8e24aa\x07\x1b]4;13;#d81b60\x07\x1b]4;14;#00897b\x07\x1b]4;15;#3a1133\x07";
pub const limyuxi_reset = "\x1b]104\x07\x1b]110\x07\x1b]111\x07\x1b]112\x07"; // palette, fg, bg, cursor

// ── color themes ────────────────────────────────────────────────────────────
// Opt-in terminal color themes (OSC 10/11/12 = fg/bg/cursor; the light theme
// also sets the ANSI palette so graff's colored UI stays legible). Selected via
// /theme, persisted as {"theme": "<name>"} in .harness/settings.json, reset on
// exit. No theme by default — graff leaves your terminal colors alone unless you
// pick one. PastelPink is the former limyuxi glam, now a normal choice.
pub const theme_reset = "\x1b]104\x07\x1b]110\x07\x1b]111\x07\x1b]112\x07"; // palette, fg, bg, cursor
pub const Theme = struct { name: []const u8, desc: []const u8, seq: []const u8 };
pub const themes = [_]Theme{
    .{ .name = "PastelPink", .desc = "light pink bg, dark plum text", .seq = limyuxi_theme },
    .{ .name = "Midnight", .desc = "deep navy bg, soft slate text, sky cursor", .seq = "\x1b]11;#0f172a\x07\x1b]10;#e2e8f0\x07\x1b]12;#38bdf8\x07" },
    .{ .name = "Forest", .desc = "dark green bg, pale green text", .seq = "\x1b]11;#0e1a12\x07\x1b]10;#d7e8d0\x07\x1b]12;#4ade80\x07" },
    .{ .name = "Amber", .desc = "warm dark bg, amber text (retro CRT)", .seq = "\x1b]11;#1a1206\x07\x1b]10;#ffcf8f\x07\x1b]12;#ff9e3d\x07" },
};
pub var g_theme: ?usize = null; // index into themes, or null = no theme (terminal default)

pub fn themeIndex(name: []const u8) ?usize {
    for (themes, 0..) |t, i| if (std.ascii.eqlIgnoreCase(t.name, name)) return i;
    return null;
}

/// Load {"theme": "<name>"} from settings at startup.
pub fn loadThemeSetting(io: Io, arena: Allocator) void {
    const data = Io.Dir.cwd().readFileAlloc(io, Approvals.settings_path, arena, .limited(1 << 20)) catch return;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return;
    if (v != .object) return;
    const t = v.object.get("theme") orelse return;
    if (t != .string) return;
    if (themeIndex(t.string)) |i| g_theme = i;
}

/// Persist the /theme choice, preserving every other settings key. "off"/"none"
/// removes the key (back to the terminal default). Best-effort.
pub fn saveThemeSetting(io: Io, gpa: Allocator, value: []const u8) bool {
    Io.Dir.cwd().createDir(io, Approvals.settings_dir, .default_dir) catch {};
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var root_obj: std.json.ObjectMap = .empty;
    if (Io.Dir.cwd().readFileAlloc(io, Approvals.settings_path, a, .limited(1 << 20))) |data| {
        if (std.json.parseFromSliceLeaky(Value, a, data, .{ .allocate = .alloc_always })) |v| {
            if (v == .object) root_obj = v.object;
        } else |_| {}
    } else |_| {}
    if (std.ascii.eqlIgnoreCase(value, "off") or std.ascii.eqlIgnoreCase(value, "none")) {
        _ = root_obj.orderedRemove("theme");
    } else {
        root_obj.put(a, "theme", .{ .string = value }) catch return false;
    }
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    s.write(Value{ .object = root_obj }) catch return false;
    const f = Io.Dir.cwd().createFile(io, Approvals.settings_path, .{}) catch return false;
    defer f.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    fw.interface.writeAll(aw.writer.buffered()) catch return false;
    fw.interface.writeAll("\n") catch return false;
    fw.interface.flush() catch return false;
    return true;
}

/// Restrained ember sweep for `ultracode`: sumi-adjacent rust through the
/// Codegraff coral accent to warm gold, without the old full-spectrum flash.
pub const ultracode_ember = [_][]const u8{
    "\x1b[38;2;168;99;67m", "\x1b[38;2;179;92;73m",  "\x1b[38;2;196;81;61m",
    "\x1b[38;2;179;92;73m", "\x1b[38;2;155;106;53m", "\x1b[38;2;165;101;59m",
};

/// `ultracode` codeword banner: a slow ember shine sweeps across the word in
/// interactive (color) mode when the codeword engages multi-agent workflow
/// mode. Truecolor ANSI; best-effort (any write failure aborts silently).
pub fn ultracodeShine(w: *Io.Writer, io: Io) void {
    const word = "ULTRACODE";
    const ember = "\x1b[38;2;155;106;53m";
    const frames = 9;
    var f: usize = 0;
    while (f < frames) : (f += 1) {
        w.writeAll("\r\x1b[2K") catch return;
        w.writeAll(style.bold) catch return;
        w.print("{s}◇ ", .{ember}) catch return;
        for (word, 0..) |c, i| {
            w.writeAll(ultracode_ember[(i + f) % ultracode_ember.len]) catch return;
            w.print("{c}", .{c}) catch return;
        }
        w.print("{s} ◇{s}", .{ ember, style.reset }) catch return;
        w.flush() catch return;
        io.sleep(.fromMilliseconds(110), .awake) catch {};
    }
    w.writeAll("\n") catch {};
    w.flush() catch {};
}

pub fn animIndex(name: []const u8) ?usize {
    for (anims, 0..) |a, i| if (std.mem.eql(u8, a.name, name)) return i;
    return null;
}

fn animThinking(w: *Io.Writer) Io.Writer.Error!void {
    try w.print(" {s}thinking…{s}", .{ style.dim, style.reset });
}

fn animEnso(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    // A deliberately small, unhurried brush-circle. Each pose holds for two
    // frames so it reads as breathing rather than a busy loading indicator.
    const frames = [_][]const u8{ "◜", "◜", "◝", "◝", "◞", "◞", "◟", "◟" };
    try w.print("{s}{s}{s}", .{ style.accent, frames[i % frames.len], style.reset });
    try animThinking(w);
}

fn animGlitter(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    // 🎂 EGG (limyuxi_birthday_white): a glittery pink sparkle spinner. Saturated
    // pinks/purples/gold pop on the pastel-pink bg; "thinking…" in deep plum
    // stays legible.
    const sparks = [_][]const u8{ "✨", "✧", "⋆", "˖", "✦", "♡", "⭒", "·" };
    const cols = [_][]const u8{
        "\x1b[38;2;255;20;147m", // deep pink
        "\x1b[38;2;233;30;99m", // pink
        "\x1b[38;2;156;39;176m", // purple
        "\x1b[38;2;255;152;0m", // gold
        "\x1b[38;2;216;27;96m", // magenta
    };
    var j: usize = 0;
    while (j < 3) : (j += 1) {
        try w.writeAll(cols[(i +% j) % cols.len]);
        try w.writeAll(sparks[(i *% 2 +% j *% 3) % sparks.len]);
        if (j + 1 < 3) try w.writeAll(" ");
    }
    try w.writeAll("\x1b[0m \x1b[38;2;106;27;90mthinking…\x1b[0m");
}

fn animDragon(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    // 🎂 EGG (limyuxi_birthday_white): a wee ASCII fire-breathing dragon for
    // yxlyx — brought back, but drawn (no emoji). Spiky body undulates, the head
    // breathes a flickering flame. style.yellow → legible amber on her pink bg,
    // bright yellow on a dark terminal.
    const body = [_][]const u8{ "_^_^_^", "^_^_^_", "_^^_^^", "^^_^^_" };
    const flame = [_][]const u8{ "~", "=", "<", "*", "" };
    try w.print("{s}{s}", .{ style.bold, style.yellow });
    try w.writeAll(body[i % body.len]);
    try w.writeAll("(O>");
    try w.writeAll(flame[i % flame.len]);
    try w.writeAll(style.reset);
    try animThinking(w);
}

fn animCometTail(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    // A streaking comet: a coral head trailing a fading dash tail.
    const tail = [_][]const u8{ "    ", "·   ", "-·  ", "=-· ", "≈=-·" };
    try w.print("{s}{s}☄{s}", .{ style.accent, tail[i % tail.len], style.reset });
    try animThinking(w);
}

fn animBraille(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    try w.print("{s}{s} thinking…{s}", .{ style.dim, frames[i % frames.len], style.reset });
}

fn animPulse(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    const glyphs = [_][]const u8{ "·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢" };
    const g = glyphs[i % glyphs.len];
    const bright = (i % glyphs.len) >= 3 and (i % glyphs.len) <= 6;
    try w.print("{s}{s}{s}", .{ if (bright) style.accent else style.dim, g, style.reset });
    try animThinking(w);
}

fn animOrbit(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    const slots = 6;
    const pos = i % slots;
    var j: usize = 0;
    while (j < slots) : (j += 1) {
        if (j == pos) {
            try w.print("{s}●{s}", .{ style.accent, style.reset });
        } else {
            try w.print("{s}·{s}", .{ style.dim, style.reset });
        }
        if (j + 1 < slots) try w.writeAll(" ");
    }
    try animThinking(w);
}

fn animBlockWave(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    const lvls = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
    try w.writeAll(style.accent);
    var j: usize = 0;
    while (j < 10) : (j += 1) {
        const tri = @abs(@as(i64, @intCast((i + j) % 14)) - 7); // 0..7 triangle wave
        try w.writeAll(lvls[@intCast(7 - tri)]);
    }
    try w.writeAll(style.reset);
    try animThinking(w);
}

fn animShimmer(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    const chs = [_][]const u8{ "t", "h", "i", "n", "k", "i", "n", "g", "…" };
    const pos = i % (chs.len + 4); // a little off-screen pause each sweep
    for (chs, 0..) |c, j| {
        if (j == pos) {
            try w.print("{s}{s}{s}{s}", .{ style.bold, style.accent, c, style.reset });
        } else {
            try w.print("{s}{s}{s}", .{ style.dim, c, style.reset });
        }
    }
}

fn animMatrix(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    const glyphs = [_][]const u8{ "ｱ", "ｼ", "ﾂ", "ｴ", "ｵ", "ｶ", "ｷ", "ﾒ", "ｹ", "ｺ", "ﾅ", "ﾈ", "ｽ", "ﾎ", "ﾜ", "ﾀ" };
    var j: usize = 0;
    while (j < 8) : (j += 1) {
        const g = glyphs[(i / 2 +% j *% 7 +% j * j) % glyphs.len];
        const head = (i + j) % 5 == 0;
        try w.print("{s}{s}{s}", .{ if (head) style.green else style.dim, g, style.reset });
    }
    try animThinking(w);
}

fn animPacman(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    const track = 10;
    const pos = (i / 2) % (track + 2); // 2 spare ticks off the right edge
    var j: usize = 0;
    while (j < track) : (j += 1) {
        if (j < pos) {
            try w.writeAll("  ");
        } else if (j == pos) {
            try w.print("{s}{s}{s} ", .{ style.yellow, if (i % 2 == 0) "ᗧ" else "○", style.reset });
        } else {
            try w.print("{s}·{s} ", .{ style.dim, style.reset });
        }
    }
    try animThinking(w);
}

fn animStarfield(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    var j: usize = 0;
    while (j < 14) : (j += 1) {
        if ((j + i) % 7 == 0) {
            try w.print("{s}✦{s}", .{ style.accent, style.reset });
        } else if ((j + i * 2) % 11 == 0) {
            try w.print("{s}·{s}", .{ style.dim, style.reset });
        } else {
            try w.writeAll(" ");
        }
    }
    try animThinking(w);
}

test "no spinner frame ever emits a supplementary-plane glyph (anti-stealth, #106)" {
    // Regression guard for the runtime-built poop prank (U+1F4A9): it lived inside a
    // frame fn and constructed the codepoint at runtime, so strings/grep never saw it.
    // Every legitimate spinner glyph is BMP (braille, blocks, the comet, sparkles), so
    // a terminal spinner has no business ever emitting a supplementary-plane codepoint.
    // Render every production spinner — plus the gated birthday eggs — across several
    // cycles and assert it. This is the unit-level test that would have caught the poop.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const FrameFn = *const fn (*Io.Writer, usize) Io.Writer.Error!void;
    var fns: [anims.len + 2]FrameFn = undefined;
    for (anims, 0..) |a, k| fns[k] = a.frame;
    fns[anims.len] = animGlitter; // gated birthday eggs are still real spinner output
    fns[anims.len + 1] = animDragon;

    for (fns, 0..) |f, fi| {
        var i: usize = 0;
        while (i < 96) : (i += 1) {
            var aw: Io.Writer.Allocating = .init(arena);
            try f(&aw.writer, i);
            const view = std.unicode.Utf8View.init(aw.writer.buffered()) catch {
                std.debug.print("spinner #{d} i={d}: invalid UTF-8\n", .{ fi, i });
                return error.InvalidFrameUtf8;
            };
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                if (cp >= 0x10000) {
                    std.debug.print("spinner #{d} i={d} emitted U+{X} (supplementary-plane/emoji, the old poop class)\n", .{ fi, i, cp });
                    return error.ForbiddenSpinnerGlyph;
                }
            }
        }
    }
}

test "spinner pool is exactly the expected 10 animations (no silent additions)" {
    // Lock the user-facing spinner set: adding or renaming one must be a deliberate,
    // reviewed change, not something that slips in unnoticed.
    const expected = [_][]const u8{
        "enso",    "braille", "pulse",  "orbit-dots", "block-wave",
        "shimmer", "matrix",  "pacman", "starfield",  "comet-tail",
    };
    try std.testing.expectEqual(expected.len, anims.len);
    for (anims, 0..) |a, k| try std.testing.expectEqualStrings(expected[k], a.name);
    try std.testing.expectEqualStrings("enso", anims[0].name);
    try std.testing.expectEqual(@as(u16, 160), anims[0].frame_ms);
}

/// Check .harness/settings.json for "dev_spinner": if truthy, the
/// caller should use the normal spinner regardless of host profile.
var g_dev_spinner_opt_out: bool = false;

fn devSpinnerOptOut(_: Io, _: Allocator) bool {
    return g_dev_spinner_opt_out;
}

pub fn loadDevSpinnerOptOut(io: Io, arena: Allocator, environ: anytype) void {
    if (environ.get("GRAFF_DEV_SPINNER")) |v| {
        if (!std.mem.eql(u8, v, "0") and !std.ascii.eqlIgnoreCase(v, "false")) {
            g_dev_spinner_opt_out = true;
            return;
        }
    }
    const data = Io.Dir.cwd().readFileAlloc(io, Approvals.settings_path, arena, .limited(1 << 20)) catch return;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return;
    if (v != .object) return;
    const ds = v.object.get("dev_spinner") orelse return;
    g_dev_spinner_opt_out = switch (ds) {
        .bool => |b| b,
        .integer => |n| n != 0,
        .string => |s| !std.mem.eql(u8, s, "0") and !std.mem.eql(u8, s, "false"),
        else => false,
    };
}

/// Load {"animation": "<name>|random|off"} from settings at startup.
pub fn loadAnimationSetting(io: Io, arena: Allocator) void {
    const data = Io.Dir.cwd().readFileAlloc(io, Approvals.settings_path, arena, .limited(1 << 20)) catch return;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return;
    if (v != .object) return;
    const a = v.object.get("animation") orelse return;
    if (a != .string) return;
    if (std.mem.eql(u8, a.string, "off")) {
        g_anim_off = true;
        g_anim_random = false;
    } else if (std.mem.eql(u8, a.string, "random")) {
        g_anim_random = true;
    } else if (animIndex(a.string)) |i| {
        g_anim_index = i;
        g_anim_random = false; // a pinned spinner overrides the random default
    }
}

/// Pick which animation the thinking spinner shows — the EXACT logic spinnerStart
/// uses, factored so the headless --selftest-spinner render and the live spinner
/// always agree (a cwd-gated override would surface in both). Sets g_anim_current.
pub fn selectSpinner(io: Io) void {
    if (g_anim_random) {
        var b: [1]u8 = undefined;
        io.random(&b);
        g_anim_current = b[0] % anims.len;
    } else g_anim_current = g_anim_index;
}

/// Persist the /animation choice, preserving every other settings key.
/// The default ("enso") removes the key. Best-effort.
pub fn saveAnimationSetting(io: Io, gpa: Allocator, value: []const u8) bool {
    Io.Dir.cwd().createDir(io, Approvals.settings_dir, .default_dir) catch {};
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var root_obj: std.json.ObjectMap = .empty;
    if (Io.Dir.cwd().readFileAlloc(io, Approvals.settings_path, a, .limited(1 << 20))) |data| {
        if (std.json.parseFromSliceLeaky(Value, a, data, .{ .allocate = .alloc_always })) |v| {
            if (v == .object) root_obj = v.object;
        } else |_| {}
    } else |_| {}
    if (std.mem.eql(u8, value, "enso")) { // enso is the default → no stored key needed
        _ = root_obj.orderedRemove("animation");
    } else {
        root_obj.put(a, "animation", .{ .string = value }) catch return false;
    }
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    s.write(Value{ .object = root_obj }) catch return false;
    const f = Io.Dir.cwd().createFile(io, Approvals.settings_path, .{}) catch return false;
    defer f.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    fw.interface.writeAll(aw.writer.buffered()) catch return false;
    fw.interface.writeAll("\n") catch return false;
    fw.interface.flush() catch return false;
    return true;
}
