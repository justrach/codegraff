//! Kitty / iTerm2 pixels for the image overlay, after the cell paint.
//!
//! Grok-build's rule: the frame stays a cell grid (no APC in overlay text).
//! After paint() flushes, we place the image at the reserved blank rows with
//! `C=1` (cursor stays put) and `z=1` (above cells). Closing the overlay, a
//! geometry change, or a full wipe deletes the placement so it cannot survive
//! as a gray slab on scroll. Unit tests force this off (`builtin.is_test`).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const app = @import("app.zig");
const Model = app.Model;

pub const max_bytes: usize = 2 * 1024 * 1024;
pub const max_pixel_rows: usize = 12;
const chunk_b64: usize = 4096;
const kitty_id: u32 = 1;

pub const Protocol = enum { none, kitty, iterm2 };

pub const Place = struct {
    x: u16,
    y: u16,
    cols: u16,
    rows: u16,
};

pub const Slot = struct {
    on: bool = false,
    path_hash: u64 = 0,
    x: u16 = 0,
    y: u16 = 0,
    cols: u16 = 0,
    rows: u16 = 0,

    fn matches(self: Slot, path: []const u8, p: Place) bool {
        if (!self.on) return false;
        if (self.x != p.x or self.y != p.y or self.cols != p.cols or self.rows != p.rows) return false;
        return self.path_hash == std.hash.Wyhash.hash(0, path);
    }

    fn remember(self: *Slot, path: []const u8, p: Place) void {
        self.on = true;
        self.path_hash = std.hash.Wyhash.hash(0, path);
        self.x = p.x;
        self.y = p.y;
        self.cols = p.cols;
        self.rows = p.rows;
    }
};

pub const clear_all = "\x1b_Ga=d,d=A,q=2\x1b\\";

var test_on: bool = false;

pub fn setSupportedForTest(on: bool) void {
    test_on = on;
}

pub fn supported() bool {
    if (builtin.is_test) return test_on;
    return protocol() != .none;
}

pub fn protocol() Protocol {
    if (builtin.os.tag == .windows) return .none;
    if (std.c.getenv("TMUX") != null) return .none;
    const program = if (std.c.getenv("TERM_PROGRAM")) |z| std.mem.span(z) else "";
    const term = if (std.c.getenv("TERM")) |z| std.mem.span(z) else "";
    return protocolFor(program, term);
}

pub fn protocolFor(term_program: []const u8, term: []const u8) Protocol {
    if (eq(term_program, "ghostty") or eq(term_program, "kitty") or
        eq(term_program, "WezTerm") or eq(term_program, "WarpTerminal") or
        eq(term, "xterm-ghostty") or eq(term, "xterm-kitty"))
        return .kitty;
    if (eq(term_program, "iTerm.app")) return .iterm2;
    return .none;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

const Box = struct { cols: usize, rows: usize };

pub fn pixelBox(path: []const u8, width: usize) Box {
    const max_cols = if (width > 4) width - 2 else 1;
    const px = pixelsAt(path) orelse return .{ .cols = max_cols, .rows = @min(max_pixel_rows, 8) };
    return fitImageToCells(px.w, px.h, max_cols, max_pixel_rows);
}

/// Grok Build `fit_image_to_cells`: monospace cells are ~0.5 as wide as tall.
pub fn fitImageToCells(img_w: u32, img_h: u32, max_cols: usize, max_rows: usize) Box {
    if (img_w == 0 or img_h == 0 or max_cols == 0 or max_rows == 0)
        return .{ .cols = @max(max_cols, 1), .rows = @max(max_rows, 1) };
    const cols_per_row = (@as(f64, @floatFromInt(img_w)) / @as(f64, @floatFromInt(img_h))) / 0.5;
    const rows_by_width: usize = @intFromFloat(@round(@as(f64, @floatFromInt(max_cols)) / cols_per_row));
    if (rows_by_width <= max_rows) return .{ .cols = max_cols, .rows = @max(rows_by_width, 1) };
    const cols_by_height: usize = @intFromFloat(@round(@as(f64, @floatFromInt(max_rows)) * cols_per_row));
    return .{ .cols = @min(@max(cols_by_height, 1), max_cols), .rows = max_rows };
}

pub fn place(m: *const Model, term_cols: usize) ?Place {
    if (!supported()) return null;
    if (m.overlay != .image or m.preview_path.len == 0) return null;
    const box = pixelBox(m.preview_path, term_cols);
    if (box.cols == 0 or box.rows == 0) return null;
    var headers: usize = 1;
    if (m.preview_path.len > 0) headers += 1;
    const y0 = m.prompt_origin -| m.preview_rows + headers;
    return .{
        .x = 1,
        .y = @intCast(@min(y0 + 1, 9999)),
        .cols = @intCast(@min(box.cols, 9999)),
        .rows = @intCast(@min(box.rows, 9999)),
    };
}

/// After the cell paint, inside ?2026. `wiping` means the screen was cleared
/// or every row rewritten — re-place even if geometry matches.
pub fn sync(
    w: *Io.Writer,
    alloc: std.mem.Allocator,
    slot: *Slot,
    m: *const Model,
    term_cols: usize,
    wiping: bool,
) void {
    const p = place(m, term_cols);
    const keep = if (p) |pl| slot.matches(m.preview_path, pl) and !wiping else false;
    if (slot.on and !keep) {
        w.writeAll(clear_all) catch {};
        slot.on = false;
    }
    if (keep) return;
    const pl = p orelse return;
    if (draw(w, alloc, m.preview_path, pl, protocol())) slot.remember(m.preview_path, pl);
}

fn draw(w: *Io.Writer, alloc: std.mem.Allocator, path: []const u8, p: Place, proto: Protocol) bool {
    if (proto == .none) return false;
    const png = loadPng(alloc, path) orelse return false;
    defer alloc.free(png);
    w.print("\x1b[{d};{d}H", .{ p.y, p.x }) catch return false;
    switch (proto) {
        .kitty => kittyPlace(w, alloc, png, p.cols, p.rows) catch return false,
        .iterm2 => itermPlace(w, alloc, png, p.cols, p.rows) catch return false,
        .none => return false,
    }
    return true;
}

fn loadPng(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const io = ioHandle();
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const st = file.stat(io) catch return null;
    if (st.size == 0 or st.size > max_bytes) return null;
    const buf = alloc.alloc(u8, @intCast(st.size)) catch return null;
    const n = file.readPositionalAll(io, buf, 0) catch {
        alloc.free(buf);
        return null;
    };
    if (n < buf.len) {
        alloc.free(buf);
        return null;
    }
    if (isPng(buf)) return buf;
    alloc.free(buf);
    return convertToPng(alloc, path);
}

fn convertToPng(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    if (builtin.os.tag != .macos) return null;
    const io = ioHandle();
    var dst_buf: [80]u8 = undefined;
    const dst = std.fmt.bufPrint(&dst_buf, "/tmp/graff-img-{d}.png", .{std.c.getpid()}) catch return null;
    var child = std.process.spawn(io, .{
        .argv = &.{ "sips", "-s", "format", "png", path, "--out", dst },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return null;
    _ = child.wait(io) catch return null;
    const file = std.Io.Dir.cwd().openFile(io, dst, .{}) catch return null;
    defer file.close(io);
    const info = file.stat(io) catch return null;
    if (info.size == 0 or info.size > max_bytes) return null;
    const buf = alloc.alloc(u8, @intCast(info.size)) catch return null;
    const n = file.readPositionalAll(io, buf, 0) catch {
        alloc.free(buf);
        return null;
    };
    if (n < buf.len or !isPng(buf)) {
        alloc.free(buf);
        return null;
    }
    return buf;
}

fn isPng(h: []const u8) bool {
    return h.len >= 8 and std.mem.eql(u8, h[0..8], "\x89PNG\r\n\x1a\n");
}

const Px = struct { w: u32, h: u32 };

fn pixelsAt(path: []const u8) ?Px {
    if (path.len == 0) return null;
    const io = ioHandle();
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    var hdr: [8192]u8 = undefined;
    const n = file.readPositionalAll(io, &hdr, 0) catch 0;
    return pixelsFromHeader(hdr[0..n]);
}

fn pixelsFromHeader(h: []const u8) ?Px {
    if (h.len >= 24 and isPng(h))
        return .{ .w = std.mem.readInt(u32, h[16..20], .big), .h = std.mem.readInt(u32, h[20..24], .big) };
    if (h.len >= 10 and (std.mem.eql(u8, h[0..6], "GIF89a") or std.mem.eql(u8, h[0..6], "GIF87a")))
        return .{ .w = std.mem.readInt(u16, h[6..8], .little), .h = std.mem.readInt(u16, h[8..10], .little) };
    return jpegPx(h) orelse webpPx(h);
}

fn jpegPx(h: []const u8) ?Px {
    if (h.len < 4 or h[0] != 0xff or h[1] != 0xd8) return null;
    var i: usize = 2;
    while (i + 8 < h.len) {
        if (h[i] != 0xff) return null;
        const marker = h[i + 1];
        if (marker == 0xd8 or marker == 0xd9 or (marker >= 0xd0 and marker <= 0xd7)) {
            i += 2;
            continue;
        }
        if (i + 4 > h.len) return null;
        const seglen = std.mem.readInt(u16, h[i + 2 .. i + 4][0..2], .big);
        if (marker >= 0xc0 and marker <= 0xc3 and i + 8 < h.len) {
            return .{
                .h = std.mem.readInt(u16, h[i + 5 .. i + 7][0..2], .big),
                .w = std.mem.readInt(u16, h[i + 7 .. i + 9][0..2], .big),
            };
        }
        if (seglen < 2) return null;
        i += 2 + @as(usize, seglen);
    }
    return null;
}

fn webpPx(h: []const u8) ?Px {
    if (h.len < 30 or !std.mem.eql(u8, h[0..4], "RIFF") or !std.mem.eql(u8, h[8..12], "WEBP")) return null;
    const tag = h[12..16];
    if (std.mem.eql(u8, tag, "VP8 "))
        return .{
            .w = std.mem.readInt(u16, h[26..28][0..2], .little) & 0x3fff,
            .h = std.mem.readInt(u16, h[28..30][0..2], .little) & 0x3fff,
        };
    if (std.mem.eql(u8, tag, "VP8X"))
        return .{
            .w = 1 + (@as(u32, h[24]) | (@as(u32, h[25]) << 8) | (@as(u32, h[26]) << 16)),
            .h = 1 + (@as(u32, h[27]) | (@as(u32, h[28]) << 8) | (@as(u32, h[29]) << 16)),
        };
    return null;
}

pub fn kittyPlace(w: *Io.Writer, alloc: std.mem.Allocator, png: []const u8, cols: u16, rows: u16) !void {
    const enc = std.base64.standard.Encoder;
    const total = enc.calcSize(png.len);
    const b64 = try alloc.alloc(u8, total);
    defer alloc.free(b64);
    _ = enc.encode(b64, png);
    var off: usize = 0;
    var first = true;
    while (off < b64.len) {
        const n = @min(chunk_b64, b64.len - off);
        const last = off + n == b64.len;
        const m: u8 = if (last) 0 else 1;
        if (first) {
            try w.print("\x1b_Ga=T,f=100,t=d,q=2,C=1,z=1,i={d},p={d},c={d},r={d},m={d};", .{
                kitty_id, kitty_id, cols, rows, m,
            });
            first = false;
        } else {
            try w.print("\x1b_Gq=2,m={d};", .{m});
        }
        try w.writeAll(b64[off .. off + n]);
        try w.writeAll("\x1b\\");
        off += n;
    }
}

fn itermPlace(w: *Io.Writer, alloc: std.mem.Allocator, bytes: []const u8, cols: u16, rows: u16) !void {
    const enc = std.base64.standard.Encoder;
    const total = enc.calcSize(bytes.len);
    const b64 = try alloc.alloc(u8, total);
    defer alloc.free(b64);
    _ = enc.encode(b64, bytes);
    try w.print("\x1b]1337;File=inline=1;doNotMoveCursor=1;width={d};height={d};preserveAspectRatio=1:", .{ cols, rows });
    try w.writeAll(b64);
    try w.writeAll("\x07");
}

fn ioHandle() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

test "protocolFor matches Grok brands" {
    try std.testing.expectEqual(Protocol.kitty, protocolFor("ghostty", "xterm-256color"));
    try std.testing.expectEqual(Protocol.kitty, protocolFor("kitty", "xterm-kitty"));
    try std.testing.expectEqual(Protocol.kitty, protocolFor("", "xterm-ghostty"));
    try std.testing.expectEqual(Protocol.iterm2, protocolFor("iTerm.app", "xterm-256color"));
    try std.testing.expectEqual(Protocol.none, protocolFor("Apple_Terminal", "xterm-256color"));
}

test "supported is off under zig test" {
    try std.testing.expect(!supported());
    setSupportedForTest(true);
    defer setSupportedForTest(false);
    try std.testing.expect(supported());
}

test "kittyPlace is APC, PNG, cursor-preserving, not in a text row" {
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const png = "\x89PNG\r\n\x1a\n" ++ "xxxx";
    try kittyPlace(&aw.writer, std.testing.allocator, png, 20, 8);
    const s = aw.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, s, "\x1b_Ga=T,f=100,t=d,q=2,C=1,z=1"));
    try std.testing.expect(std.mem.indexOf(u8, s, "c=20,r=8") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\x1b\\") != null);
}

test "sync keep-path does not retransmit" {
    setSupportedForTest(true);
    defer setSupportedForTest(false);
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.overlay = .image;
    m.preview_path = "/tmp/missing-imgproto.png";
    m.preview_rows = 12;
    m.prompt_origin = 20;
    var slot: Slot = .{};
    slot.remember("/tmp/missing-imgproto.png", place(&m, 80).?);
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    sync(&aw.writer, std.testing.allocator, &slot, &m, 80, false);
    try std.testing.expectEqual(@as(usize, 0), aw.writer.buffered().len);
    try std.testing.expect(slot.on);
}

test "sync wipe deletes even when geometry matches" {
    setSupportedForTest(true);
    defer setSupportedForTest(false);
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.overlay = .image;
    m.preview_path = "/tmp/missing-imgproto.png";
    m.preview_rows = 12;
    m.prompt_origin = 20;
    var slot: Slot = .{};
    slot.remember("/tmp/missing-imgproto.png", place(&m, 80).?);
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    sync(&aw.writer, std.testing.allocator, &slot, &m, 80, true);
    const s = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, s, clear_all) != null);
}

test "sync close overlay deletes" {
    setSupportedForTest(true);
    defer setSupportedForTest(false);
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.overlay = .none;
    var slot: Slot = .{ .on = true };
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    sync(&aw.writer, std.testing.allocator, &slot, &m, 80, false);
    try std.testing.expectEqualStrings(clear_all, aw.writer.buffered());
    try std.testing.expect(!slot.on);
}

test "fitImageToCells matches Grok cell-aspect 0.5" {
    const wide = fitImageToCells(1512, 644, 72, 10);
    try std.testing.expectEqual(@as(usize, 47), wide.cols);
    try std.testing.expectEqual(@as(usize, 10), wide.rows);
    const sq = fitImageToCells(100, 100, 40, 10);
    try std.testing.expectEqual(@as(usize, 20), sq.cols);
    try std.testing.expectEqual(@as(usize, 10), sq.rows);
}
