//! Read-only path fallback normalization for `read_file` and `read_image`.
//!
//! Invoked ONLY when opening the exact caller-supplied path fails with
//! `error.FileNotFound`:
//!   1. Strips a single leading `@` mention prefix (`@src/foo.zig` -> `src/foo.zig`).
//!   2. Matches parent-directory entries whose basename differs only by macOS
//!      screenshot spaces (`U+202F` narrow no-break space / `U+00A0` no-break
//!      space <-> ASCII `' '`) or canonical Unicode NFD <-> NFC composition.
//!
//! Security invariant: every candidate path and matched directory entry must
//! pass `harness_policy.confinedPath` and `harness_policy.noSymlinkEscape`
//! before any parent scan or file open. Never call from mutating file tools.

const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const policy = @import("harness_policy.zig");
const codedbpro_paths = @import("codedbpro_paths.zig");

pub const Fallback = struct {
    display_path: []const u8,
    resolved: []const u8,
};

pub fn stripAtPrefix(raw_path: []const u8) ?[]const u8 {
    if (raw_path.len > 1 and raw_path[0] == '@') return raw_path[1..];
    return null;
}

const Pair = struct { cp: u21, b: u21, m: u21 };

const ext_pairs = [_]Pair{
    .{ .cp = 0x0100, .b = 'A', .m = 0x0304 },    .{ .cp = 0x0102, .b = 'A', .m = 0x0306 },    .{ .cp = 0x0104, .b = 'A', .m = 0x0328 },
    .{ .cp = 0x0106, .b = 'C', .m = 0x0301 },    .{ .cp = 0x0108, .b = 'C', .m = 0x0302 },    .{ .cp = 0x010A, .b = 'C', .m = 0x0307 },
    .{ .cp = 0x010C, .b = 'C', .m = 0x030C },    .{ .cp = 0x010E, .b = 'D', .m = 0x030C },    .{ .cp = 0x0112, .b = 'E', .m = 0x0304 },
    .{ .cp = 0x0114, .b = 'E', .m = 0x0306 },    .{ .cp = 0x0116, .b = 'E', .m = 0x0307 },    .{ .cp = 0x0118, .b = 'E', .m = 0x0328 },
    .{ .cp = 0x011A, .b = 'E', .m = 0x030C },    .{ .cp = 0x011C, .b = 'G', .m = 0x0302 },    .{ .cp = 0x011E, .b = 'G', .m = 0x0306 },
    .{ .cp = 0x0120, .b = 'G', .m = 0x0307 },    .{ .cp = 0x0122, .b = 'G', .m = 0x0327 },    .{ .cp = 0x0124, .b = 'H', .m = 0x0302 },
    .{ .cp = 0x0128, .b = 'I', .m = 0x0303 },    .{ .cp = 0x012A, .b = 'I', .m = 0x0304 },    .{ .cp = 0x012C, .b = 'I', .m = 0x0306 },
    .{ .cp = 0x012E, .b = 'I', .m = 0x0328 },    .{ .cp = 0x0134, .b = 'J', .m = 0x0302 },    .{ .cp = 0x0136, .b = 'K', .m = 0x0327 },
    .{ .cp = 0x0139, .b = 'L', .m = 0x0301 },    .{ .cp = 0x013B, .b = 'L', .m = 0x0327 },    .{ .cp = 0x013D, .b = 'L', .m = 0x030C },
    .{ .cp = 0x0143, .b = 'N', .m = 0x0301 },    .{ .cp = 0x0145, .b = 'N', .m = 0x0327 },    .{ .cp = 0x0147, .b = 'N', .m = 0x030C },
    .{ .cp = 0x014C, .b = 'O', .m = 0x0304 },    .{ .cp = 0x014E, .b = 'O', .m = 0x0306 },    .{ .cp = 0x0150, .b = 'O', .m = 0x030B },
    .{ .cp = 0x0154, .b = 'R', .m = 0x0301 },    .{ .cp = 0x0156, .b = 'R', .m = 0x0327 },    .{ .cp = 0x0158, .b = 'R', .m = 0x030C },
    .{ .cp = 0x015A, .b = 'S', .m = 0x0301 },    .{ .cp = 0x015C, .b = 'S', .m = 0x0302 },    .{ .cp = 0x015E, .b = 'S', .m = 0x0327 },
    .{ .cp = 0x0160, .b = 'S', .m = 0x030C },    .{ .cp = 0x0162, .b = 'T', .m = 0x0327 },    .{ .cp = 0x0164, .b = 'T', .m = 0x030C },
    .{ .cp = 0x0168, .b = 'U', .m = 0x0303 },    .{ .cp = 0x016A, .b = 'U', .m = 0x0304 },    .{ .cp = 0x016C, .b = 'U', .m = 0x0306 },
    .{ .cp = 0x016E, .b = 'U', .m = 0x030A },    .{ .cp = 0x0170, .b = 'U', .m = 0x030B },    .{ .cp = 0x0172, .b = 'U', .m = 0x0328 },
    .{ .cp = 0x0174, .b = 'W', .m = 0x0302 },    .{ .cp = 0x0176, .b = 'Y', .m = 0x0302 },    .{ .cp = 0x0179, .b = 'Z', .m = 0x0301 },
    .{ .cp = 0x017B, .b = 'Z', .m = 0x0307 },    .{ .cp = 0x017D, .b = 'Z', .m = 0x030C },    .{ .cp = 0x01A0, .b = 'O', .m = 0x031B },
    .{ .cp = 0x01AF, .b = 'U', .m = 0x031B },    .{ .cp = 0x0218, .b = 'S', .m = 0x0326 },    .{ .cp = 0x021A, .b = 'T', .m = 0x0326 },
    .{ .cp = 0x1EA0, .b = 'A', .m = 0x0323 },    .{ .cp = 0x1EA2, .b = 'A', .m = 0x0309 },    .{ .cp = 0x1EA4, .b = 0x00C2, .m = 0x0301 },
    .{ .cp = 0x1EA6, .b = 0x00C2, .m = 0x0300 }, .{ .cp = 0x1EA8, .b = 0x00C2, .m = 0x0309 }, .{ .cp = 0x1EAA, .b = 0x00C2, .m = 0x0303 },
    .{ .cp = 0x1EAC, .b = 0x1EA0, .m = 0x0302 }, .{ .cp = 0x1EB8, .b = 'E', .m = 0x0323 },    .{ .cp = 0x1EBA, .b = 'E', .m = 0x0309 },
    .{ .cp = 0x1EBC, .b = 'E', .m = 0x0303 },    .{ .cp = 0x1EBE, .b = 0x00CA, .m = 0x0301 }, .{ .cp = 0x1EC0, .b = 0x00CA, .m = 0x0300 },
    .{ .cp = 0x1EC2, .b = 0x00CA, .m = 0x0309 }, .{ .cp = 0x1EC4, .b = 0x00CA, .m = 0x0303 }, .{ .cp = 0x1EC6, .b = 0x1EB8, .m = 0x0302 },
    .{ .cp = 0x1EC8, .b = 'I', .m = 0x0309 },    .{ .cp = 0x1ECA, .b = 'I', .m = 0x0323 },    .{ .cp = 0x1ECC, .b = 'O', .m = 0x0323 },
    .{ .cp = 0x1ECE, .b = 'O', .m = 0x0309 },    .{ .cp = 0x1ED0, .b = 0x00D4, .m = 0x0301 }, .{ .cp = 0x1ED2, .b = 0x00D4, .m = 0x0300 },
    .{ .cp = 0x1ED4, .b = 0x00D4, .m = 0x0309 }, .{ .cp = 0x1ED6, .b = 0x00D4, .m = 0x0303 }, .{ .cp = 0x1ED8, .b = 0x1ECC, .m = 0x0302 },
    .{ .cp = 0x1EE4, .b = 'U', .m = 0x0323 },    .{ .cp = 0x1EE6, .b = 'U', .m = 0x0309 },    .{ .cp = 0x1EF2, .b = 'Y', .m = 0x0300 },
    .{ .cp = 0x1EF4, .b = 'Y', .m = 0x0323 },    .{ .cp = 0x1EF6, .b = 'Y', .m = 0x0309 },    .{ .cp = 0x1EF8, .b = 'Y', .m = 0x0303 },
};

fn latin1UpperDecomp(cp: u21) ?[2]u21 {
    return switch (cp) {
        0x00C0 => .{ 'A', 0x0300 },
        0x00C1 => .{ 'A', 0x0301 },
        0x00C2 => .{ 'A', 0x0302 },
        0x00C3 => .{ 'A', 0x0303 },
        0x00C4 => .{ 'A', 0x0308 },
        0x00C5 => .{ 'A', 0x030A },
        0x00C7 => .{ 'C', 0x0327 },
        0x00C8 => .{ 'E', 0x0300 },
        0x00C9 => .{ 'E', 0x0301 },
        0x00CA => .{ 'E', 0x0302 },
        0x00CB => .{ 'E', 0x0308 },
        0x00CC => .{ 'I', 0x0300 },
        0x00CD => .{ 'I', 0x0301 },
        0x00CE => .{ 'I', 0x0302 },
        0x00CF => .{ 'I', 0x0308 },
        0x00D1 => .{ 'N', 0x0303 },
        0x00D2 => .{ 'O', 0x0300 },
        0x00D3 => .{ 'O', 0x0301 },
        0x00D4 => .{ 'O', 0x0302 },
        0x00D5 => .{ 'O', 0x0303 },
        0x00D6 => .{ 'O', 0x0308 },
        0x00D9 => .{ 'U', 0x0300 },
        0x00DA => .{ 'U', 0x0301 },
        0x00DB => .{ 'U', 0x0302 },
        0x00DC => .{ 'U', 0x0308 },
        0x00DD => .{ 'Y', 0x0301 },
        else => null,
    };
}

fn kanaDecomp(cp: u21) ?[2]u21 {
    if (cp == 0x3094) return .{ 0x3046, 0x3099 }; // ゔ
    if (cp == 0x30F4) return .{ 0x30A6, 0x3099 }; // ヴ
    const base: u21 = if (cp >= 0x304C and cp <= 0x307D) 0x3040 else if (cp >= 0x30AC and cp <= 0x30DD) 0x30A0 else return null;
    const off = cp - base;
    // か..ぢ (0x0C..0x22 even -> dakuten), つ..ど (0x25,0x27,0x29 -> dakuten)
    if (off >= 0x0C and off <= 0x22 and (off & 1) == 0) return .{ cp - 1, 0x3099 };
    if (off == 0x25 or off == 0x27 or off == 0x29) return .{ cp - 1, 0x3099 };
    // は/ば/ぱ..ほ/ぼ/ぽ: offsets 0x30,0x33,0x36,0x39,0x3C (dakuten) & +1 (handakuten)
    if (off >= 0x30 and off <= 0x3D) {
        const mod = (off - 0x2F) % 3;
        if (mod == 1) return .{ cp - 1, 0x3099 };
        if (mod == 2) return .{ cp - 2, 0x309A };
    }
    return null;
}

fn lowerOf(cp: u21) u21 {
    if (cp >= 'A' and cp <= 'Z') return cp + 32;
    if (cp >= 0x00C0 and cp <= 0x00DD) return cp + 32;
    return cp + 1;
}

fn decomposePair(cp: u21) ?[2]u21 {
    if (cp == 0x212B) return .{ 0x00C5, 0 }; // Å -> Å -> A + ring
    if (cp == 0x2126) return .{ 0x03A9, 0 }; // Ω -> Ω
    if (cp >= 0x00C0 and cp <= 0x00DD) return latin1UpperDecomp(cp);
    if (cp >= 0x00E0 and cp <= 0x00FD) {
        const up = latin1UpperDecomp(cp - 0x20) orelse return null;
        return .{ up[0] + 32, up[1] };
    }
    if (cp == 0x00FF) return .{ 'y', 0x0308 };
    if (cp == 0x0130) return .{ 'I', 0x0307 };
    if (cp == 0x0178) return .{ 'Y', 0x0308 };
    if (cp == 0x0401) return .{ 0x0415, 0x0308 }; // Ё
    if (cp == 0x0451) return .{ 0x0435, 0x0308 }; // ё
    if (cp == 0x0419) return .{ 0x0418, 0x0306 }; // Й
    if (cp == 0x0439) return .{ 0x0438, 0x0306 }; // й
    if (kanaDecomp(cp)) |k| return k;
    for (ext_pairs) |p| {
        if (cp == p.cp) return .{ p.b, p.m };
        if (cp == p.cp + 1) return .{ lowerOf(p.b), p.m };
    }
    return null;
}

fn combiningClass(cp: u21) u8 {
    return switch (cp) {
        0x3099, 0x309A => 8,
        0x0327, 0x0328 => 202,
        0x031B => 216,
        0x0316...0x0319, 0x031C...0x0320, 0x0323...0x0326, 0x0329...0x0333, 0x0339...0x033C => 220,
        0x0300...0x0314, 0x033D...0x0342, 0x0344, 0x0346, 0x034A...0x034C => 230,
        0x0315, 0x0343 => 232,
        else => 0,
    };
}

const MaxNormCodepoints = 512;

const NormBuf = struct {
    items: [MaxNormCodepoints]u21 = undefined,
    len: usize = 0,

    fn push(self: *NormBuf, cp: u21) bool {
        if (self.len >= MaxNormCodepoints) return false;
        self.items[self.len] = cp;
        self.len += 1;
        return true;
    }

    fn emitDecomposed(self: *NormBuf, cp: u21) bool {
        if (cp == 0x00A0 or cp == 0x202F) return self.push(' ');
        // Unicode §3.12 algorithmic Hangul syllable NFD decomposition.
        if (cp >= 0xAC00 and cp < 0xAC00 + 11172) {
            const s_idx = cp - 0xAC00;
            if (!self.push(0x1100 + s_idx / 588)) return false;
            if (!self.push(0x1161 + (s_idx % 588) / 28)) return false;
            if (s_idx % 28 != 0 and !self.push(0x11A7 + (s_idx % 28))) return false;
            return true;
        }
        if (decomposePair(cp)) |pair| {
            if (!self.emitDecomposed(pair[0])) return false;
            if (pair[1] != 0 and !self.emitDecomposed(pair[1])) return false;
            return true;
        }
        return self.push(cp);
    }

    fn sortCombiningRuns(self: *NormBuf) void {
        var i: usize = 1;
        while (i < self.len) : (i += 1) {
            const ccc_i = combiningClass(self.items[i]);
            if (ccc_i == 0) continue;
            var j = i;
            while (j > 0) {
                const ccc_prev = combiningClass(self.items[j - 1]);
                if (ccc_prev == 0 or ccc_prev <= ccc_i) break;
                const tmp = self.items[j - 1];
                self.items[j - 1] = self.items[j];
                self.items[j] = tmp;
                j -= 1;
            }
        }
    }
};

fn normalizeBasename(s: []const u8, out: *NormBuf) bool {
    const view = std.unicode.Utf8View.init(s) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (!out.emitDecomposed(cp)) return false;
    }
    out.sortCombiningRuns();
    return true;
}

/// True when `a` and `b` are canonically equivalent UTF-8 basenames modulo
/// ASCII space `' '` <-> `U+00A0` / `U+202F` and Unicode NFD <-> NFC.
pub fn equivBasename(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    var na: NormBuf = .{};
    var nb: NormBuf = .{};
    if (!normalizeBasename(a, &na) or !normalizeBasename(b, &nb)) return false;
    return std.mem.eql(u21, na.items[0..na.len], nb.items[0..nb.len]);
}

fn tryExactFile(io: Io, arena: Allocator, base_dir: ?[]const u8, candidate: []const u8) ?Fallback {
    if (candidate.len == 0 or std.fs.path.isSep(candidate[candidate.len - 1])) return null;
    if (!policy.confinedPath(candidate) or !policy.noSymlinkEscape(io, candidate, base_dir)) return null;
    const resolved = codedbpro_paths.sessionAbs(arena, io, base_dir, candidate) catch return null;
    const st = Io.Dir.cwd().statFile(io, resolved, .{}) catch return null;
    if (st.kind != .file) return null;
    const disp = arena.dupe(u8, candidate) catch return null;
    return .{ .display_path = disp, .resolved = resolved };
}

fn tryBasenameScan(io: Io, arena: Allocator, base_dir: ?[]const u8, candidate: []const u8) ?Fallback {
    if (candidate.len == 0 or std.fs.path.isSep(candidate[candidate.len - 1])) return null;
    // Security gate #1: verify candidate confinement BEFORE opening parent dir.
    if (!policy.confinedPath(candidate) or !policy.noSymlinkEscape(io, candidate, base_dir)) return null;

    var dir_part: ?[]const u8 = null;
    var want_base: []const u8 = candidate;
    if (std.mem.lastIndexOfAny(u8, candidate, "/\\")) |sep_idx| {
        dir_part = if (sep_idx == 0) candidate[0..1] else candidate[0..sep_idx];
        want_base = candidate[sep_idx + 1 ..];
    }
    if (want_base.len == 0 or std.mem.eql(u8, want_base, ".") or std.mem.eql(u8, want_base, "..")) return null;

    const parent_resolved = codedbpro_paths.sessionAbs(arena, io, base_dir, dir_part orelse ".") catch return null;
    var dir = Io.Dir.cwd().openDir(io, parent_resolved, .{ .iterate = true }) catch return null;
    defer dir.close(io);

    var matched_name: ?[]const u8 = null;
    var it = dir.iterate();
    while (it.next(io) catch return null) |entry| {
        if (entry.kind == .directory) continue;
        if (!equivBasename(entry.name, want_base)) continue;
        if (matched_name != null) return null; // ambiguous collision fails closed
        matched_name = arena.dupe(u8, entry.name) catch return null;
    }
    const name = matched_name orelse return null;

    const matched_path = if (dir_part) |dp|
        (if (dp.len == 1 and std.fs.path.isSep(dp[0]))
            std.fmt.allocPrint(arena, "{s}{s}", .{ dp, name })
        else
            std.fmt.allocPrint(arena, "{s}/{s}", .{ dp, name })) catch return null
    else
        name;

    // Security gate #2: re-check `confinedPath` + `noSymlinkEscape` on the
    // actual matched entry so an escaping symlink with a U+202F/NFD name is denied.
    if (!policy.confinedPath(matched_path) or !policy.noSymlinkEscape(io, matched_path, base_dir)) return null;

    const resolved = codedbpro_paths.sessionAbs(arena, io, base_dir, matched_path) catch return null;
    const st = Io.Dir.cwd().statFile(io, resolved, .{}) catch return null;
    if (st.kind != .file) return null;
    return .{ .display_path = matched_path, .resolved = resolved };
}

/// Fallback resolver for `read_file` and `read_image` after `error.FileNotFound`.
pub fn resolveFallback(io: Io, arena: Allocator, base_dir: ?[]const u8, raw_path: []const u8) ?Fallback {
    if (stripAtPrefix(raw_path)) |stripped| {
        if (tryExactFile(io, arena, base_dir, stripped)) |hit| return hit;
        if (tryBasenameScan(io, arena, base_dir, stripped)) |hit| return hit;
    }
    return tryBasenameScan(io, arena, base_dir, raw_path);
}

test "equivBasename: macOS U+202F/U+00A0 screenshot spaces and NFD/NFC canonical equivalence" {
    // macOS screenshot narrow no-break space (U+202F) and no-break space (U+00A0) <-> ASCII space.
    try std.testing.expect(equivBasename(
        "Screenshot 2026-11-09 at 1.02.15\u{202F}AM.png",
        "Screenshot 2026-11-09 at 1.02.15 AM.png",
    ));
    try std.testing.expect(equivBasename(
        "Screenshot 2026-11-09 at 1.02.15\u{00A0}AM.png",
        "Screenshot 2026-11-09 at 1.02.15\u{202F}AM.png",
    ));
    // NFC precomposed <-> APFS NFD decomposed Latin, multi-mark Vietnamese, Kana, and Hangul.
    try std.testing.expect(equivBasename("caf\u{00E9}-r\u{00E9}sum\u{00E9}.md", "cafe\u{0301}-re\u{0301}sume\u{0301}.md"));
    try std.testing.expect(equivBasename("na\u{00EF}ve-fa\u{00E7}ade-\u{00C5}ngstr\u{00F6}m.txt", "nai\u{0308}ve-fac\u{0327}ade-A\u{030A}ngstro\u{0308}m.txt"));
    try std.testing.expect(equivBasename("vi\u{1EC7}t.txt", "vie\u{0302}\u{0323}t.txt"));
    try std.testing.expect(equivBasename("vi\u{1EC7}t.txt", "vie\u{0323}\u{0302}t.txt"));
    try std.testing.expect(equivBasename("\u{304C}\u{3071}.png", "\u{304B}\u{3099}\u{306F}\u{309A}.png"));
    try std.testing.expect(equivBasename("\u{D55C}\u{AE00}.md", "\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}.md"));
    // Non-equivalent names (accent stripping or case difference) never match.
    try std.testing.expect(!equivBasename("caf\u{00E9}.md", "cafe.md"));
    try std.testing.expect(!equivBasename("Readme.md", "readme.md"));
}

test "resolveFallback: @-prefix, macOS U+202F screenshot, NFD/NFC, and symlink/traversal confinement" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "checkout/src");
    try tmp.dir.createDirPath(io, "checkout/docs");
    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.writeFile(io, .{ .sub_path = "checkout/src/foo.zig", .data = "pub const ok = true;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "checkout/docs/Screenshot 2026-11-09 at 1.02.15\u{202F}AM.png", .data = "png-bytes" });
    try tmp.dir.writeFile(io, .{ .sub_path = "checkout/docs/cafe\u{0301}.md", .data = "notes\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "outside/secret.txt", .data = "secret\n" });
    try tmp.dir.symLink(io, "../../outside/secret.txt", "checkout/docs/Escape\u{202F}Shot.txt", .{});
    try tmp.dir.symLink(io, "../src/foo.zig", "checkout/docs/InRoot\u{202F}Link.zig", .{});

    const root = try tmp.dir.realPathFileAlloc(io, "checkout", a);

    // 1. `@src/foo.zig` -> `src/foo.zig`
    const at_hit = resolveFallback(io, a, root, "@src/foo.zig") orelse return error.TestExpectedFallback;
    try std.testing.expectEqualStrings("src/foo.zig", at_hit.display_path);

    // 2. Combined `@` + ASCII space -> `Screenshot 2026-11-09 at 1.02.15\u{202F}AM.png`
    const shot_hit = resolveFallback(io, a, root, "@docs/Screenshot 2026-11-09 at 1.02.15 AM.png") orelse return error.TestExpectedFallback;
    try std.testing.expectEqualStrings("docs/Screenshot 2026-11-09 at 1.02.15\u{202F}AM.png", shot_hit.display_path);

    // 3. NFC query -> NFD file on disk
    const nfd_hit = resolveFallback(io, a, root, "docs/caf\u{00E9}.md") orelse return error.TestExpectedFallback;
    try std.testing.expect(equivBasename("caf\u{00E9}.md", std.fs.path.basename(nfd_hit.display_path)));

    // 4. In-root symlink with U+202F name passes confinement
    try std.testing.expect(resolveFallback(io, a, root, "docs/InRoot Link.zig") != null);

    // 5. Traversal, absolute paths, and U+202F symlinks escaping root are all rejected
    try std.testing.expect(resolveFallback(io, a, root, "@/etc/passwd") == null);
    try std.testing.expect(resolveFallback(io, a, root, "@../outside/secret.txt") == null);
    try std.testing.expect(resolveFallback(io, a, root, "../outside/secret.txt") == null);
    try std.testing.expect(resolveFallback(io, a, root, "docs/Escape Shot.txt") == null);
    try std.testing.expect(resolveFallback(io, a, root, "@docs/Escape Shot.txt") == null);
}

test "read_file and read_image end-to-end: read tools normalize @ and U+202F; write/edit never do" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const exec = @import("exec.zig");
    const tools = @import("tools.zig");
    const read_image = @import("read_image.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tiny_png = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x01\x00\x00\x00\x01\x08\x04\x00\x00\x00\xb5\x1c\x0c\x02\x00\x00\x00\x0b\x49\x44\x41\x54\x78\xda\x63\xfc\xff\x1f\x00\x03\x03\x02\x00\xef\x9a\x0f\x5b\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/hello.txt", .data = "hello norm\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Screenshot 2026-11-09 at 1.02.15\u{202F}AM.png", .data = tiny_png });

    const cwd = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(cwd);

    var reg = @import("mcp.zig").Registry.empty(gpa, io);
    defer reg.deinit();
    var client: std.http.Client = undefined;
    const ctx: tools.ToolCtx = .{
        .gpa = gpa,
        .io = io,
        .client = &client,
        .provider = .{ .id = "test", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 100000 },
        .registry = &reg,
        .from_sub = false,
        .approvals = null,
        .tracer = null,
        .agent_cwd = cwd,
    };

    // read_file with `@src/hello.txt` succeeds.
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"path\":\"@src/hello.txt\"}", .{});
        defer parsed.deinit();
        const out = exec.execTool(ctx, .{ .id = "r1", .name = "read_file", .input = parsed.value });
        defer gpa.free(out.text);
        try std.testing.expect(!out.is_error);
        try std.testing.expectEqualStrings("hello norm\n", out.text);
    }

    // read_file on `@Screenshot 2026-11-09 at 1.02.15 AM.png` stages the U+202F PNG!
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"path\":\"@Screenshot 2026-11-09 at 1.02.15 AM.png\"}", .{});
        defer parsed.deinit();
        const out = exec.execTool(ctx, .{ .id = "r2", .name = "read_file", .input = parsed.value });
        defer gpa.free(out.text);
        try std.testing.expect(!out.is_error);
        try std.testing.expect(reg.pending_image != null);
        reg.pending_image = null;
    }

    // Direct `read_image.stage` on unnormalized `resolved` also falls back on FileNotFound.
    {
        const raw_rel = "Screenshot 2026-11-09 at 1.02.15 AM.png";
        const missing_abs = try codedbpro_paths.sessionAbs(gpa, io, cwd, raw_rel);
        defer gpa.free(missing_abs);
        const staged = (try read_image.stage(gpa, io, ctx, missing_abs, raw_rel, tiny_png.len)).?;
        defer gpa.free(staged.text);
        try std.testing.expect(!staged.is_error);
        try std.testing.expect(reg.pending_image != null);
        reg.pending_image = null;
    }

    // edit_file does NOT normalize `@src/hello.txt` (read-only tools ONLY!).
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"path\":\"@src/hello.txt\",\"old_string\":\"hello\",\"new_string\":\"mutated\"}", .{});
        defer parsed.deinit();
        const out = exec.execTool(ctx, .{ .id = "e1", .name = "edit_file", .input = parsed.value });
        defer gpa.free(out.text);
        try std.testing.expect(out.is_error);
    }
}
