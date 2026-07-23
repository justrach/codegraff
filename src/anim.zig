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

// Private profile-gated easter egg: it deliberately stays out of `anims`, so
// random selection and /animation never expose it to other users.
var g_justrach_spinner = false;
var g_justrach_seed: u64 = 0;
const justrach_anim: Anim = .{
    .name = "justrach",
    .desc = "private profile spinner",
    .frame_ms = 140,
    .frame = animJustrach,
};
const justrach_muck_colors = [_][]const u8{
    "\x1b[38;2;166;107;55m", // muddy brown
    "\x1b[38;2;180;160;55m", // murky yellow
    "\x1b[38;2;116;125;62m", // swamp olive
    "\x1b[38;2;198;127;35m", // ochre
};

// ── color themes ────────────────────────────────────────────────────────────
// Opt-in terminal color themes (OSC 10/11/12 = fg/bg/cursor; the light theme
// also sets the ANSI palette so graff's colored UI stays legible). Selected via
// /theme, persisted as {"theme": "<name>"} in .harness/settings.json, reset on
// exit. No theme by default — graff leaves your terminal colors alone unless you
// pick one.
pub const theme_reset = "\x1b]104\x07\x1b]110\x07\x1b]111\x07\x1b]112\x07"; // palette, fg, bg, cursor
pub const Theme = struct { name: []const u8, desc: []const u8, seq: []const u8 };
// PastelPink: light pink bg, dark plum text, pink-leaning ANSI palette.
pub const pastel_pink_seq =
    "\x1b]11;#fce4ec\x07" ++ // bg: pastel pink
    "\x1b]10;#4a1942\x07" ++ // fg: dark plum (~9:1 contrast)
    "\x1b]12;#d81b60\x07" ++ // cursor: hot pink
    "\x1b]4;0;#4a1942\x07\x1b]4;1;#c2185b\x07\x1b]4;2;#2e7d32\x07\x1b]4;3;#b26a00\x07" ++
    "\x1b]4;4;#6a1b9a\x07\x1b]4;5;#ad1457\x07\x1b]4;6;#00796b\x07\x1b]4;7;#5d4357\x07" ++
    "\x1b]4;8;#8a6680\x07\x1b]4;9;#e91e63\x07\x1b]4;10;#388e3c\x07\x1b]4;11;#c77800\x07" ++
    "\x1b]4;12;#8e24aa\x07\x1b]4;13;#d81b60\x07\x1b]4;14;#00897b\x07\x1b]4;15;#3a1133\x07";
pub const themes = [_]Theme{
    .{ .name = "PastelPink", .desc = "light pink bg, dark plum text", .seq = pastel_pink_seq },
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

fn justrachRandom(i: usize, salt: u64, upper: usize) usize {
    var x = @as(u64, g_justrach_seed) +% @as(u64, @intCast(i)) *% 0x9E3779B97F4A7C15 +% salt;
    x = (x ^ (x >> 30)) *% 0xBF58476D1CE4E5B9;
    x = (x ^ (x >> 27)) *% 0x94D049BB133111EB;
    return @intCast((x ^ (x >> 31)) % upper);
}

fn animJustrach(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    const poop_count = 1 + justrachRandom(i, 0x504F4F50, 3);
    const fly_count = 1 + justrachRandom(i, 0x464C4945, 4);
    const duplicate_at = justrachRandom(i, 0x5459504F, "thinking".len);

    try w.writeAll(style.dim);
    var n: usize = 0;
    while (n < fly_count) : (n += 1) try w.writeAll("🪰");
    try w.writeAll(style.reset);
    try w.writeByte(' ');
    n = 0;
    while (n < poop_count) : (n += 1) {
        const color = justrach_muck_colors[justrachRandom(i, 0x504F4F43 + n, justrach_muck_colors.len)];
        // VS15 requests a text glyph so terminals can apply the ANSI tint.
        try w.print("{s}{s}💩\u{fe0e}{s}", .{ style.bold, color, style.reset });
    }
    try w.writeByte(' ');
    const typo_color = justrach_muck_colors[justrachRandom(i, 0x54455854, justrach_muck_colors.len)];
    try w.writeAll(typo_color);
    for ("thinking", 0..) |c, j| {
        try w.writeByte(c);
        if (j == duplicate_at) try w.writeByte(c);
    }
    try w.print("…{s}", .{style.reset});
}

fn animEnso(w: *Io.Writer, i: usize) Io.Writer.Error!void {
    // A deliberately small, unhurried brush-circle. Each pose holds for two
    // frames so it reads as breathing rather than a busy loading indicator.
    const frames = [_][]const u8{ "◜", "◜", "◝", "◝", "◞", "◞", "◟", "◟" };
    try w.print("{s}{s}{s}", .{ style.accent, frames[i % frames.len], style.reset });
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

/// Check .harness/settings.json for "dev_spinner": if truthy, the
/// caller should use the normal spinner regardless of host profile.
var g_dev_spinner_opt_out: bool = false;

const justrach_profile_aliases = [_][]const u8{ "justrach", "blackfloofie" };

fn justrachProfileName(value: []const u8) bool {
    for (justrach_profile_aliases) |alias| {
        if (std.ascii.eqlIgnoreCase(value, alias)) return true;
    }
    return false;
}

fn justrachProfileValues(user: ?[]const u8, logname: ?[]const u8, home_value: ?[]const u8) bool {
    if (user) |value| {
        if (value.len > 0) return justrachProfileName(value);
    }
    if (logname) |value| {
        if (value.len > 0) return justrachProfileName(value);
    }
    if (home_value) |home| {
        const trimmed = std.mem.trim(u8, home, "/\\");
        for (justrach_profile_aliases) |alias| {
            if (trimmed.len < alias.len) continue;
            const start = trimmed.len - alias.len;
            if (std.ascii.eqlIgnoreCase(trimmed[start..], alias) and
                (start == 0 or trimmed[start - 1] == '/' or trimmed[start - 1] == '\\')) return true;
        }
    }
    return false;
}

fn justrachProfile(environ: anytype) bool {
    const user = environ.get("USER") orelse environ.get("USERNAME");
    const home = environ.get("HOME") orelse environ.get("USERPROFILE");
    return justrachProfileValues(user, environ.get("LOGNAME"), home);
}

pub fn loadDevSpinnerOptOut(io: Io, arena: Allocator, environ: anytype) void {
    g_dev_spinner_opt_out = false;
    defer g_justrach_spinner = justrachProfile(environ) and !g_dev_spinner_opt_out;
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
        .string => |s| !std.mem.eql(u8, s, "0") and !std.ascii.eqlIgnoreCase(s, "false"),
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

/// Pick which animation the thinking spinner shows. Sets g_anim_current and
/// gives the private spinner a fresh sequence for each request.
pub fn selectSpinner(io: Io) void {
    var entropy: [8]u8 = undefined;
    if (g_anim_random or g_justrach_spinner) io.random(&entropy);
    if (g_anim_random) g_anim_current = entropy[0] % anims.len else g_anim_current = g_anim_index;
    if (g_justrach_spinner) {
        g_justrach_seed = 0;
        for (entropy, 0..) |byte, i| {
            const shift: u6 = @intCast(i * 8);
            g_justrach_seed |= @as(u64, byte) << shift;
        }
    }
}

pub fn currentSpinner() *const Anim {
    return if (g_justrach_spinner) &justrach_anim else &anims[g_anim_current];
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

fn countSubstring(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOf(u8, haystack[offset..], needle)) |relative| {
        count += 1;
        offset += relative + needle.len;
    }
    return count;
}

test "justrach spinner profile gate only matches recipient aliases" {
    try std.testing.expect(justrachProfileValues("justrach", null, null));
    try std.testing.expect(justrachProfileValues("blackfloofie", null, null));
    try std.testing.expect(justrachProfileValues(null, "BLACKFLOOFIE", null));
    try std.testing.expect(justrachProfileValues(null, null, "/Users/JUSTRACH/"));
    try std.testing.expect(justrachProfileValues(null, null, "C:\\Users\\blackfloofie"));
    try std.testing.expect(!justrachProfileValues("other", "JUSTRACH", "/Users/blackfloofie"));
    try std.testing.expect(!justrachProfileValues("rach", null, "/Users/justrachel"));
    try std.testing.expect(!justrachProfileValues(null, null, "/Users/blackfloofie2"));
    try std.testing.expect(!justrachProfileValues(null, null, "/work/codegraff"));
}

test "justrach spinner stays hidden from the public animation pool" {
    const old_enabled = g_justrach_spinner;
    defer g_justrach_spinner = old_enabled;
    g_justrach_spinner = false;
    try std.testing.expectEqualStrings(anims[g_anim_current].name, currentSpinner().name);
    try std.testing.expect(animIndex("justrach") == null);
    g_justrach_spinner = true;
    try std.testing.expectEqualStrings("justrach", currentSpinner().name);
}

test "justrach spinner varies poop, flies, and thinking typo" {
    const old_seed = g_justrach_seed;
    defer g_justrach_seed = old_seed;
    g_justrach_seed = 23;

    const typos = [_][]const u8{
        "tthinking…",
        "thhinking…",
        "thiinking…",
        "thinnking…",
        "thinkking…",
        "thinkiing…",
        "thinkinng…",
        "thinkingg…",
    };
    var seen_poop = [_]bool{false} ** 4;
    var seen_flies = [_]bool{false} ** 5;
    var seen_typos = [_]bool{false} ** typos.len;
    var seen_colors = [_]bool{false} ** justrach_muck_colors.len;

    for (0..32) |i| {
        var aw: Io.Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        try animJustrach(&aw.writer, i);
        const frame = aw.writer.buffered();
        const poop_count = countSubstring(frame, "💩");
        const fly_count = countSubstring(frame, "🪰");
        try std.testing.expect(poop_count >= 1 and poop_count <= 3);
        try std.testing.expect(fly_count >= 1 and fly_count <= 4);
        seen_poop[poop_count] = true;
        seen_flies[fly_count] = true;
        for (justrach_muck_colors, 0..) |color, j| {
            if (std.mem.indexOf(u8, frame, color) != null) seen_colors[j] = true;
        }

        var found_typo = false;
        for (typos, 0..) |typo, j| {
            if (std.mem.indexOf(u8, frame, typo) != null) {
                seen_typos[j] = true;
                found_typo = true;
            }
        }
        try std.testing.expect(found_typo);
    }

    for (seen_poop[1..]) |seen| try std.testing.expect(seen);
    for (seen_flies[1..]) |seen| try std.testing.expect(seen);
    for (seen_typos) |seen| try std.testing.expect(seen);
    for (seen_colors) |seen| try std.testing.expect(seen);
}
