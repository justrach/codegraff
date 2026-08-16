//! Append-only TUI input log so a leak or cancelled turn can be replayed.
//! `.graff/tui-traj.jsonl` — raw stdin hex, no prompts, no model text.

const std = @import("std");
const Io = std.Io;

pub const path = ".graff/tui-traj.jsonl";
const cap: u64 = 512 * 1024;
const chunk_max: usize = 256;

var ready: bool = false;
var test_path: ?[]const u8 = null;

fn dest() []const u8 {
    return test_path orelse path;
}

pub fn open(io: Io) void {
    Io.Dir.cwd().createDirPath(io, ".graff") catch {};
    ready = true;
}

pub fn note(io: Io, now_ms: u64, bytes: []const u8) void {
    if (!ready or bytes.len == 0) return;
    const slice = if (bytes.len > chunk_max) bytes[0..chunk_max] else bytes;
    var hex: [chunk_max * 2]u8 = undefined;
    const hexed = toHex(slice, &hex);
    var line_buf: [64 + chunk_max * 2]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{{\"t\":{d},\"n\":{d},\"hex\":\"{s}\"}}\n", .{
        now_ms, bytes.len, hexed,
    }) catch return;
    append(io, line);
}

pub fn snap(io: Io, now_ms: u64, visible: []const u8) void {
    if (!ready) return;
    const slice = if (visible.len > chunk_max) visible[visible.len - chunk_max ..] else visible;
    var esc: [chunk_max * 2]u8 = undefined;
    const n = jsonEscape(slice, &esc);
    var line_buf: [80 + chunk_max * 2]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{{\"t\":{d},\"vis\":\"{s}\"}}\n", .{ now_ms, esc[0..n] }) catch return;
    append(io, line);
}

fn append(io: Io, line: []const u8) void {
    rotateIfHuge(io);
    const f = Io.Dir.cwd().createFile(io, dest(), .{ .truncate = false }) catch return;
    defer f.close(io);
    const st = f.stat(io) catch return;
    f.writePositionalAll(io, line, st.size) catch {};
}

fn rotateIfHuge(io: Io) void {
    const st = Io.Dir.cwd().statFile(io, dest(), .{}) catch return;
    if (st.size < cap) return;
    Io.Dir.cwd().deleteFile(io, dest()) catch {};
}

fn toHex(src: []const u8, out: []u8) []const u8 {
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        out[i * 2] = hex[src[i] >> 4];
        out[i * 2 + 1] = hex[src[i] & 0xf];
    }
    return out[0 .. src.len * 2];
}

fn jsonEscape(src: []const u8, out: []u8) usize {
    var o: usize = 0;
    for (src) |c| {
        if (o + 2 >= out.len) break;
        if (c == '"' or c == '\\') {
            out[o] = '\\';
            o += 1;
            out[o] = c;
            o += 1;
        } else if (c == '\n') {
            out[o] = '\\';
            o += 1;
            out[o] = 'n';
            o += 1;
        } else if (c >= 32 and c < 127) {
            out[o] = c;
            o += 1;
        } else {
            if (o + 1 >= out.len) break;
            out[o] = '?';
            o += 1;
        }
    }
    return o;
}

test "note writes hex stdin and snap writes visible tail" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const tmp = "TUI/testdata-tui-traj.jsonl";
    test_path = tmp;
    defer {
        test_path = null;
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
    }
    Io.Dir.cwd().deleteFile(io, tmp) catch {};
    ready = true;
    note(io, 42, "\x1b[57444;9u");
    snap(io, 43, "thinking.\n3u7444;9u");
    const text = Io.Dir.cwd().readFileAlloc(io, tmp, std.testing.allocator, .limited(4096)) catch return error.TestUnexpectedResult;
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "1b5b35373434343b3975") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "3u7444;9u") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"t\":42") != null);
}
