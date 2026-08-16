//! THROWAWAY probe — do not commit. Kitty keyboard protocol conformance checks.
const std = @import("std");
const key = @import("key.zig");

var out_buf: [64]key.Key = undefined;

fn tok(bytes: []const u8) []key.Key {
    var i: usize = 0;
    var n: usize = 0;
    while (key.next(bytes, &i)) |k| {
        out_buf[n] = k;
        n += 1;
        if (n == out_buf.len) break;
    }
    return out_buf[0..n];
}

fn dump(label: []const u8, bytes: []const u8) void {
    key.resetInputState();
    const ks = tok(bytes);
    std.debug.print("{s} -> {d} tok:", .{ label, ks.len });
    for (ks) |k| {
        switch (k) {
            .char => |c| std.debug.print(" char('{c}')", .{c}),
            .codepoint => |c| std.debug.print(" cp({d})", .{c}),
            .ctrl => |c| std.debug.print(" ctrl({c})", .{c}),
            .mouse => |m| std.debug.print(" mouse(b{d},{d},{d},{})", .{ m.btn, m.x, m.y, m.down }),
            .bg_report => |r| std.debug.print(" bg({d},{d},{d})", .{ r[0], r[1], r[2] }),
            else => std.debug.print(" {s}", .{@tagName(k)}),
        }
    }
    std.debug.print("\n", .{});
}

test "probe" {
    std.debug.print("\n=== kitty CSI-u decode probe ===\n", .{});
    dump("press a      CSI 97;1:1u", "\x1b[97;1:1u");
    dump("repeat a     CSI 97;1:2u", "\x1b[97;1:2u");
    dump("RELEASE a    CSI 97;1:3u", "\x1b[97;1:3u");
    dump("RELEASE C-c  CSI 99;5:3u", "\x1b[99;5:3u");
    dump("RELEASE esc  CSI 27;1:3u", "\x1b[27;1:3u");
    dump("RELEASE Fesc CSI 57344;1:3u", "\x1b[57344;1:3u");
    dump("RELEASE up   CSI 1;1:3A", "\x1b[1;1:3A");
    dump("RELEASE del  CSI 3;1:3~", "\x1b[3;1:3~");
    dump("shift+a      CSI 97;2u", "\x1b[97;2u");
    dump("alt+a        CSI 97;3u", "\x1b[97;3u");
    dump("ctrl+a       CSI 97;5u", "\x1b[97;5u");
    dump("super+a      CSI 97;9u", "\x1b[97;9u");
    dump("shift8 US    CSI 56:42;2u", "\x1b[56:42;2u");
    dump("shift8 DE    CSI 56:40;2u", "\x1b[56:40;2u");
    dump("a +text      CSI 97;1;97u", "\x1b[97;1;97u");
    dump("a +multitext CSI 97;1;97:98u", "\x1b[97;1;97:98u");
    dump("REL a +text  CSI 97;1:3;97u", "\x1b[97;1:3;97u");
    dump("caps a       CSI 97;65u", "\x1b[97;65u");
    dump("caps+shift a CSI 97;66u", "\x1b[97;66u");
    dump("numlock a    CSI 97;129u", "\x1b[97;129u");
    dump("KP_0   57399 CSI 57399u", "\x1b[57399u");
    dump("KP_1   57400 CSI 57400u", "\x1b[57400u");
    dump("KP_DEC 57409 CSI 57409u", "\x1b[57409u");
    dump("KP_DIV 57410 CSI 57410u", "\x1b[57410u");
    dump("KP_MUL 57411 CSI 57411u", "\x1b[57411u");
    dump("KP_SUB 57412 CSI 57412u", "\x1b[57412u");
    dump("KP_ADD 57413 CSI 57413u", "\x1b[57413u");
    dump("KP_ENT 57414 CSI 57414u", "\x1b[57414u");
    dump("KP_BEG 57427 CSI 57427u", "\x1b[57427u");
    dump("INSERT 57348 CSI 57348u", "\x1b[57348u");
    dump("F13    57364 CSI 57364u", "\x1b[57364u");
    dump("legacy up    CSI A", "\x1b[A");
    dump("legacy ss3   SS3 A", "\x1bOA");
    dump("legacy stab  CSI Z", "\x1b[Z");
    dump("hyper+a      CSI 97;17u", "\x1b[97;17u");
    dump("meta+a       CSI 97;33u", "\x1b[97;33u");
    dump("L-super down CSI 57444;1:1u", "\x1b[57444;1:1u");
    dump("L-super up   CSI 57444;1:3u", "\x1b[57444;1:3u");
    dump("osc11 BEL", "\x1b]11;rgb:1a1a/1b1b/1c1c\x07");
    dump("osc11 ST", "\x1b]11;rgb:1a1a/1b1b/1c1c\x1b\\");
    dump("#516 alt-] then typed text + CR", "\x1b]hello world\r");
    dump("kitty ack CSI ?11u (query reply)", "\x1b[?11u");
    dump("uppercase A via caps CSI 65;65u", "\x1b[65;65u");
    std.debug.print("=== end ===\n", .{});
}
