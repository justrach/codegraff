//! Modified-Backspace decoding for the line REPL (#981).
//!
//! Legacy ESC DEL remains Option/Alt word-delete. While the editor is active,
//! xterm modifyOtherKeys gives Cmd/Super and Ctrl distinct modifier bits; direct
//! Kitty CSI-u forms are accepted too when a terminal already emits them.

const std = @import("std");

pub const enable_seq = "\x1b[?2004h\x1b[>4;2m";
pub const restore_seq = "\x1b[>4;0m\x1b[?2004l";

pub const ModifiedDelete = enum {
    delete_word,
    delete_to_start,
};

pub fn legacyDelete(byte: u8) ?ModifiedDelete {
    return if (byte == 0x7f or byte == 0x08) .delete_word else null;
}

pub fn csiDelete(params: []const u8, final: u8) ?ModifiedDelete {
    return switch (final) {
        'u' => kittyDelete(params),
        '~' => modifyOtherKeysDelete(params),
        else => null,
    };
}

fn kittyDelete(params: []const u8) ?ModifiedDelete {
    var fields = std.mem.splitScalar(u8, params, ';');
    const code = fieldNumber(fields.next() orelse return null) orelse return null;
    const modifier_field = fields.next() orelse return null;
    const encoded_mods = fieldNumber(modifier_field) orelse return null;
    const event = fieldEvent(modifier_field) orelse 1;
    return modifiedDelete(code, encoded_mods, event);
}

fn modifyOtherKeysDelete(params: []const u8) ?ModifiedDelete {
    var fields = std.mem.splitScalar(u8, params, ';');
    if ((fieldNumber(fields.next() orelse return null) orelse return null) != 27) return null;
    const encoded_mods = fieldNumber(fields.next() orelse return null) orelse return null;
    const code = fieldNumber(fields.next() orelse return null) orelse return null;
    return modifiedDelete(code, encoded_mods, 1);
}

fn modifiedDelete(code: u32, encoded_mods: u32, event: u32) ?ModifiedDelete {
    if (code != 0x7f and code != 0x08) return null;
    if (event == 3 or (event != 1 and event != 2)) return null;
    const mods = encoded_mods -| 1;
    if (mods & (8 | 4) != 0) return .delete_to_start; // Super/Cmd or Ctrl
    if (mods & 2 != 0) return .delete_word; // Alt/Option
    return null;
}

/// Normalize xterm modifyOtherKeys back into the editor's existing byte paths.
/// Level 2 reports Ctrl/Alt/Shift chords as CSI 27;mods;code~, not only Cmd+BS.
pub fn csiReplay(params: []const u8, final: u8, out: *[2]u8) []const u8 {
    if (final != '~') return "";
    var fields = std.mem.splitScalar(u8, params, ';');
    if ((fieldNumber(fields.next() orelse return "") orelse return "") != 27) return "";
    const encoded_mods = fieldNumber(fields.next() orelse return "") orelse return "";
    const code = fieldNumber(fields.next() orelse return "") orelse return "";
    if (code > 0x7f or code == 0x7f or code == 0x08) return "";
    const mods = encoded_mods -| 1;
    if (mods & 8 != 0) return ""; // unsupported Super chords stay inert
    if (mods & 4 != 0) {
        out[0] = @intCast(code & 0x1f);
        return out[0..1];
    }
    const byte: u8 = @intCast(code);
    if (mods & 2 != 0) {
        out[0] = 0x1b;
        out[1] = if (mods & 1 != 0) shiftedAscii(byte) else byte;
        return out[0..2];
    }
    out[0] = if (mods & 1 != 0) shiftedAscii(byte) else byte;
    return out[0..1];
}

fn shiftedAscii(byte: u8) u8 {
    return switch (byte) {
        'a'...'z' => byte - 32,
        '1' => '!',
        '2' => '@',
        '3' => '#',
        '4' => '$',
        '5' => '%',
        '6' => '^',
        '7' => '&',
        '8' => '*',
        '9' => '(',
        '0' => ')',
        '-' => '_',
        '=' => '+',
        '[' => '{',
        ']' => '}',
        '\\' => '|',
        ';' => ':',
        '\'' => '"',
        ',' => '<',
        '.' => '>',
        '/' => '?',
        '`' => '~',
        else => byte,
    };
}

fn fieldNumber(field: []const u8) ?u32 {
    const end = std.mem.indexOfScalar(u8, field, ':') orelse field.len;
    if (end == 0) return null;
    return std.fmt.parseInt(u32, field[0..end], 10) catch null;
}

fn fieldEvent(field: []const u8) ?u32 {
    const colon = std.mem.indexOfScalar(u8, field, ':') orelse return null;
    const tail = field[colon + 1 ..];
    if (tail.len == 0) return null;
    return std.fmt.parseInt(u32, tail, 10) catch null;
}

test "line REPL keyboard protocol setup and restore are balanced (#981)" {
    try std.testing.expectEqualStrings("\x1b[?2004h\x1b[>4;2m", enable_seq);
    try std.testing.expectEqualStrings("\x1b[>4;0m\x1b[?2004l", restore_seq);
}

test "legacy ESC Delete remains Option word-delete (#981)" {
    try std.testing.expect(legacyDelete(0x7f) == .delete_word);
    try std.testing.expect(legacyDelete(0x08) == .delete_word);
    try std.testing.expect(legacyDelete('x') == null);
}

test "Kitty modified Backspace distinguishes Command Option and releases (#981)" {
    try std.testing.expect(csiDelete("127;9", 'u') == .delete_to_start);
    try std.testing.expect(csiDelete("8;5", 'u') == .delete_to_start);
    try std.testing.expect(csiDelete("127;3", 'u') == .delete_word);
    try std.testing.expect(csiDelete("127;9:1", 'u') == .delete_to_start);
    try std.testing.expect(csiDelete("127;9:2", 'u') == .delete_to_start);
    try std.testing.expect(csiDelete("127;9:3", 'u') == null);
    try std.testing.expect(csiDelete("127;9:4", 'u') == null);
    try std.testing.expect(csiDelete("97;9", 'u') == null);
}

test "modifyOtherKeys distinguishes Command Option and malformed input (#981)" {
    try std.testing.expect(csiDelete("27;9;127", '~') == .delete_to_start);
    try std.testing.expect(csiDelete("27;5;8", '~') == .delete_to_start);
    try std.testing.expect(csiDelete("27;3;127", '~') == .delete_word);
    try std.testing.expect(csiDelete("27;1;127", '~') == null);
    try std.testing.expect(csiDelete("27;9", '~') == null);
    try std.testing.expect(csiDelete("26;9;127", '~') == null);
    try std.testing.expect(csiDelete("27;9;97", '~') == null);
    try std.testing.expect(csiDelete("27;9;127", 'R') == null);
}

test "modifyOtherKeys replay preserves existing Ctrl Alt and Shift editing (#981)" {
    var out: [2]u8 = undefined;
    try std.testing.expectEqualStrings("\x15", csiReplay("27;5;117", '~', &out)); // Ctrl-U
    try std.testing.expectEqualStrings("\x01", csiReplay("27;5;97", '~', &out)); // Ctrl-A
    try std.testing.expectEqualStrings("\x1bb", csiReplay("27;3;98", '~', &out)); // Alt-b
    try std.testing.expectEqualStrings("A", csiReplay("27;2;97", '~', &out));
    try std.testing.expectEqualStrings("!", csiReplay("27;2;49", '~', &out));
    try std.testing.expectEqualStrings("", csiReplay("27;9;122", '~', &out));
    try std.testing.expectEqualStrings("", csiReplay("27;9;127", '~', &out)); // handled as delete
    try std.testing.expectEqualStrings("", csiReplay("127;9", 'u', &out));
}
