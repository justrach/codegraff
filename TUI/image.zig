//! [Image #N] chips: hover preview, click to pin, drop/paste paths, copy/open.

const std = @import("std");
const app = @import("app.zig");
const theme_mod = @import("theme.zig");
const key_mod = @import("key.zig");
const Model = app.Model;

pub fn render(self: *const Model, a: std.mem.Allocator, width: usize) ![]const u8 {
    const th = self.theme();
    const path = self.preview_path;
    const meta = inspect(path);
    const title = try std.fmt.allocPrint(a, " Image #{d}  —  {s}  ·  {s}  ·  {s} ", .{
        if (self.preview_n == 0) 1 else self.preview_n,
        meta.kind,
        meta.dims,
        meta.size,
    });
    var out = std.array_list.Managed(u8).init(a);
    try out.appendSlice(try theme_mod.paint(a, th.accent, title));
    try out.append('\n');
    if (path.len > 0) {
        try out.appendSlice(try theme_mod.paint(a, th.muted, path));
        try out.append('\n');
    }
    // Pixels stay out of the cell stream: Kitty images sit above the grid and
    // survived scroll as a gray slab. Metadata + open is enough to inspect.
    _ = width;
    try out.appendSlice(try theme_mod.paint(a, th.muted, " y copy path  ·  Enter open  ·  Esc"));
    try out.append('\n');
    return out.toOwnedSlice();
}

const Meta = struct { kind: []const u8, dims: []const u8, size: []const u8, px_w: u32 = 0, px_h: u32 = 0 };

fn inspect(path: []const u8) Meta {
    if (path.len == 0) return .{ .kind = "image", .dims = "?", .size = "?" };
    const io = ioHandle();
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch
        return .{ .kind = kindFromExt(path), .dims = "?", .size = "?" };
    defer file.close(io);
    const st = file.stat(io) catch
        return .{ .kind = kindFromExt(path), .dims = "?", .size = "?" };
    var hdr: [8192]u8 = undefined;
    const n = file.readPositionalAll(io, &hdr, 0) catch 0;
    const px = pixelsFromHeader(hdr[0..n]);
    return .{
        .kind = kindFromHeader(hdr[0..n], path),
        .dims = if (px) |p| (std.fmt.bufPrint(&dims_buf, "{d}×{d}", .{ p.w, p.h }) catch "?") else "?",
        .size = fmtSize(st.size),
        .px_w = if (px) |p| p.w else 0,
        .px_h = if (px) |p| p.h else 0,
    };
}

fn kindFromExt(path: []const u8) []const u8 {
    if (std.ascii.endsWithIgnoreCase(path, ".png")) return "PNG";
    if (std.ascii.endsWithIgnoreCase(path, ".jpg") or std.ascii.endsWithIgnoreCase(path, ".jpeg")) return "JPEG";
    if (std.ascii.endsWithIgnoreCase(path, ".gif")) return "GIF";
    if (std.ascii.endsWithIgnoreCase(path, ".webp")) return "WEBP";
    return "image";
}

fn kindFromHeader(h: []const u8, path: []const u8) []const u8 {
    if (h.len >= 8 and std.mem.eql(u8, h[0..8], "\x89PNG\r\n\x1a\n")) return "PNG";
    if (h.len >= 3 and h[0] == 0xff and h[1] == 0xd8 and h[2] == 0xff) return "JPEG";
    if (h.len >= 6 and (std.mem.eql(u8, h[0..6], "GIF87a") or std.mem.eql(u8, h[0..6], "GIF89a"))) return "GIF";
    if (h.len >= 12 and std.mem.eql(u8, h[0..4], "RIFF") and std.mem.eql(u8, h[8..12], "WEBP")) return "WEBP";
    return kindFromExt(path);
}

var dims_buf: [32]u8 = undefined;

const Px = struct { w: u32, h: u32 };

fn dimsFromHeader(h: []const u8) []const u8 {
    const px = pixelsFromHeader(h) orelse return "?";
    return std.fmt.bufPrint(&dims_buf, "{d}×{d}", .{ px.w, px.h }) catch "?";
}

fn pixelsFromHeader(h: []const u8) ?Px {
    if (h.len >= 24 and std.mem.eql(u8, h[0..8], "\x89PNG\r\n\x1a\n"))
        return .{ .w = std.mem.readInt(u32, h[16..20], .big), .h = std.mem.readInt(u32, h[20..24], .big) };
    if (h.len >= 10 and (std.mem.eql(u8, h[0..6], "GIF89a") or std.mem.eql(u8, h[0..6], "GIF87a")))
        return .{ .w = std.mem.readInt(u16, h[6..8], .little), .h = std.mem.readInt(u16, h[8..10], .little) };
    if (jpegPx(h)) |p| return p;
    if (webpPx(h)) |p| return p;
    return null;
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

var size_buf: [24]u8 = undefined;

fn fmtSize(n: u64) []const u8 {
    if (n >= 1024 * 1024) return std.fmt.bufPrint(&size_buf, "{d:.1} MB", .{@as(f64, @floatFromInt(n)) / (1024.0 * 1024.0)}) catch "?";
    if (n >= 1024) return std.fmt.bufPrint(&size_buf, "{d:.1} KB", .{@as(f64, @floatFromInt(n)) / 1024.0}) catch "?";
    return std.fmt.bufPrint(&size_buf, "{d} B", .{n}) catch "?";
}

pub fn pathInUserText(src: []const u8, n: u32) ?[]const u8 {
    var i: usize = 0;
    var k: u32 = 0;
    while (i < src.len) {
        if (std.mem.startsWith(u8, src[i..], "@[")) {
            if (std.mem.indexOfScalarPos(u8, src, i + 2, ']')) |close| {
                k += 1;
                if (k == n) return src[i + 2 .. close];
                i = close + 1;
                continue;
            }
        }
        i += 1;
    }
    return null;
}

fn parseChip(line: []const u8, x: usize) ?u32 {
    const at = std.mem.indexOf(u8, line, "[Image #") orelse return null;
    const vis = theme_mod.visibleLen(line[0..at]);
    var p = at + "[Image #".len;
    var n: u32 = 0;
    while (p < line.len and line[p] >= '0' and line[p] <= '9') : (p += 1) n = n * 10 + (line[p] - '0');
    if (n == 0 or p >= line.len or line[p] != ']') return null;
    const w = theme_mod.visibleLen(line[at .. p + 1]);
    if (x < vis or x >= vis + w) return null;
    return n;
}

fn pathForChip(self: *const Model, n: u32, hist_idx: ?usize) []const u8 {
    if (hist_idx) |i| {
        if (i < self.history.items.len and self.history.items[i].kind == .user) {
            if (pathInUserText(self.history.items[i].text, n)) |p| return p;
        }
    }
    if (n > 0 and n <= self.images.items.len) return self.images.items[n - 1];
    return "";
}

fn show(self: *Model, path: []const u8, n: u32, pin: bool) void {
    if (path.len == 0) return;
    self.preview_path = path;
    self.preview_n = n;
    if (pin) self.preview_pin = true;
    if (self.preview_rows == 0) self.preview_rows = 16;
    self.openOverlay(.image);
}

/// Hover (btn 35) opens the card; click pins it. Returns true when consumed.
pub fn mouse(self: *Model, ev: key_mod.Mouse) bool {
    const hover = ev.btn == 35;
    const click = ev.down and ev.btn == 0;
    if (!hover and !click) return false;
    const y: usize = if (ev.y > 0) ev.y - 1 else 0;
    const x: usize = if (ev.x > 0) ev.x - 1 else 0;
    const n = chipAt(self, x, y) orelse {
        if (hover and self.overlay == .image) {
            const top = self.prompt_origin -| self.preview_rows;
            if (y >= top and y < self.prompt_origin) return true;
            if (!self.preview_pin) self.closeOverlay();
        }
        return false;
    };
    const hist = if (y >= self.prompt_origin or y < self.mid_origin + self.sticky_rows) null else @import("layout_cache.zig").indexAtVisual(self, y -| self.mid_origin + self.mid_skip, self.last_term_width);
    const path = pathForChip(self, n, hist);
    show(self, path, n, click);
    return true;
}

fn chipAt(self: *Model, x: usize, y: usize) ?u32 {
    if (self.images.items.len > 0 and y == self.prompt_origin + 1) {
        const box_pad: usize = 4;
        if (x < box_pad) return null;
        var buf: [128]u8 = undefined;
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.images.items.len) : (i += 1) {
            const s = std.fmt.bufPrint(buf[n..], "[Image #{d}] ", .{i + 1}) catch break;
            n += s.len;
        }
        return parseChip(buf[0..n], x - box_pad);
    }
    if (y >= self.prompt_origin) return null;
    if (y < self.mid_origin) return null;
    if (y < self.mid_origin + self.sticky_rows) return null; // sticky chrome is inert
    const vis = y - self.mid_origin + self.mid_skip;
    const idx = @import("layout_cache.zig").indexAtVisual(self, vis, self.last_term_width) orelse return null;
    if (self.history.items[idx].kind != .user) return null;
    if (pathInUserText(self.history.items[idx].text, 1) == null) return null;
    return parseChipOnUser(self, idx, x);
}

fn parseChipOnUser(self: *const Model, idx: usize, x: usize) ?u32 {
    var no: u32 = 0;
    var i: usize = 0;
    while (i <= idx and i < self.history.items.len) : (i += 1) {
        if (self.history.items[i].kind == .user) no += 1;
    }
    if (no == 0) no = 1;
    var digits: usize = 1;
    var t = no;
    while (t >= 10) : (t /= 10) digits += 1;
    // "  " + "#" + digits + "  "
    var col: usize = 2 + 1 + digits + 2;
    var n: u32 = 0;
    const src = self.history.items[idx].text;
    var p: usize = 0;
    while (p < src.len) {
        if (std.mem.startsWith(u8, src[p..], "@[")) {
            if (std.mem.indexOfScalarPos(u8, src, p + 2, ']')) |close| {
                n += 1;
                var chip: [24]u8 = undefined;
                const label = std.fmt.bufPrint(&chip, "[Image #{d}]", .{n}) catch "[Image]";
                if (x >= col and x < col + label.len) return n;
                col += label.len;
                p = close + 1;
                if (p < src.len and src[p] == ' ') p += 1;
                continue;
            }
        }
        col += 1;
        p += 1;
    }
    return null;
}

pub fn lineChip(line: []const u8, x: usize) ?u32 {
    return parseChip(line, x);
}

pub fn key(self: *Model, k: @import("key.zig").Key) bool {
    if (self.overlay != .image) return false;
    if (k == .escape) {
        self.preview_pin = false;
        self.closeOverlay();
        return true;
    }
    if (k == .enter) {
        openPath(self.preview_path);
        return true;
    }
    if (k == .char and (k.char == 'y' or k.char == 'c')) {
        copyPath(self.preview_path);
        self.setToast("path copied");
        return true;
    }
    return false;
}

fn ioHandle() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn openPath(path: []const u8) void {
    if (path.len == 0) return;
    const io = ioHandle();
    var child = std.process.spawn(io, .{
        .argv = &.{ "open", path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch {};
}

fn copyPath(path: []const u8) void {
    _ = @import("selection.zig").copyText(path);
}

pub fn attachDropped(self: *Model, raw: []const u8) bool {
    var any = false;
    var decoded: [4096]u8 = undefined;
    const whole = normalizePath(&decoded, raw);
    if (@import("dispatch.zig").looksLikeImagePath(whole)) {
        if (!alreadyHas(self, whole)) self.attachImage(whole);
        return true;
    }
    var i: usize = 0;
    while (nextToken(raw, &i)) |tok| {
        var buf: [4096]u8 = undefined;
        const p = normalizePath(&buf, tok);
        if (!@import("dispatch.zig").looksLikeImagePath(p)) continue;
        if (alreadyHas(self, p)) continue;
        self.attachImage(p);
        any = true;
    }
    return any;
}

fn alreadyHas(self: *const Model, p: []const u8) bool {
    for (self.images.items) |q| {
        if (std.mem.eql(u8, q, p)) return true;
    }
    return false;
}

fn nextToken(src: []const u8, i: *usize) ?[]const u8 {
    while (i.* < src.len and std.ascii.isWhitespace(src[i.*])) i.* += 1;
    if (i.* >= src.len) return null;
    const q = src[i.*];
    if (q == '\'' or q == '"') {
        i.* += 1;
        const start = i.*;
        while (i.* < src.len and src[i.*] != q) i.* += 1;
        const tok = src[start..i.*];
        if (i.* < src.len) i.* += 1;
        return tok;
    }
    const start = i.*;
    while (i.* < src.len and !std.ascii.isWhitespace(src[i.*])) i.* += 1;
    return src[start..i.*];
}

pub fn stripPath(s: []const u8) []const u8 {
    var t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len >= 2 and ((t[0] == '\'' and t[t.len - 1] == '\'') or (t[0] == '"' and t[t.len - 1] == '"'))) {
        t = t[1 .. t.len - 1];
    }
    if (std.mem.startsWith(u8, t, "file://")) t = t["file://".len..];
    return t;
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn normalizePath(dest: []u8, raw: []const u8) []const u8 {
    const src = stripPath(raw);
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len and o < dest.len) {
        if (src[i] == '%' and i + 2 < src.len) {
            if (hexNibble(src[i + 1])) |hi| {
                if (hexNibble(src[i + 2])) |lo| {
                    dest[o] = (hi << 4) | lo;
                    o += 1;
                    i += 3;
                    continue;
                }
            }
        }
        if (src[i] == '\\' and i + 1 < src.len) {
            dest[o] = src[i + 1];
            o += 1;
            i += 2;
            continue;
        }
        dest[o] = src[i];
        o += 1;
        i += 1;
    }
    return dest[0..o];
}

const Box = struct { cols: usize, rows: usize };

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

test "pathInUserText finds the nth @[path]" {
    try std.testing.expectEqualStrings("/tmp/a.png", pathInUserText("@[/tmp/a.png] hi", 1).?);
    try std.testing.expectEqualStrings("/tmp/b.jpg", pathInUserText("@[/tmp/a.png] @[/tmp/b.jpg]", 2).?);
    try std.testing.expect(pathInUserText("nope", 1) == null);
}

test "parseChip hits only the chip columns" {
    const line = "  #4  [Image #1] hello";
    const at = std.mem.indexOf(u8, line, "[Image #1]").?;
    try std.testing.expectEqual(@as(u32, 1), parseChip(line, at).?);
    try std.testing.expect(parseChip(line, 0) == null);
}

test "dimsFromHeader reads PNG IHDR" {
    var h: [24]u8 = undefined;
    @memcpy(h[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, h[16..20], 1402, .big);
    std.mem.writeInt(u32, h[20..24], 394, .big);
    try std.testing.expectEqualStrings("1402×394", dimsFromHeader(&h));
}

test "fitImageToCells matches Grok cell-aspect 0.5" {
    const wide = fitImageToCells(1512, 644, 72, 10);
    try std.testing.expectEqual(@as(usize, 47), wide.cols);
    try std.testing.expectEqual(@as(usize, 10), wide.rows);
    const sq = fitImageToCells(100, 100, 40, 10);
    try std.testing.expectEqual(@as(usize, 20), sq.cols);
    try std.testing.expectEqual(@as(usize, 10), sq.rows);
}

test "image overlay stays in the cell grid — no Kitty APC" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.preview_path = "/tmp/a.png";
    m.preview_n = 1;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = try render(&m, arena.allocator(), 80);
    try std.testing.expect(std.mem.indexOf(u8, text, "\x1b_G") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Image #1") != null);
}

test "fmtSize matches the Grok card" {
    try std.testing.expectEqualStrings("74.0 KB", fmtSize(74 * 1024));
    try std.testing.expectEqualStrings("12 B", fmtSize(12));
}

test "stripPath unwraps quotes and file URLs" {
    try std.testing.expectEqualStrings("/tmp/a.png", stripPath("'/tmp/a.png'"));
    try std.testing.expectEqualStrings("/tmp/a.png", stripPath("file:///tmp/a.png"));
    try std.testing.expectEqualStrings("/tmp/a.png", stripPath("  \"/tmp/a.png\"  "));
}

test "attachDropped accepts quoted paths with spaces" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try std.testing.expect(attachDropped(&m, "'/Users/me/My Shot.png'"));
    try std.testing.expectEqual(@as(usize, 1), m.images.items.len);
    try std.testing.expectEqualStrings("/Users/me/My Shot.png", m.images.items[0]);
    try std.testing.expect(attachDropped(&m, "file:///Users/me/My%20Shot.png"));
    try std.testing.expectEqual(@as(usize, 1), m.images.items.len);
}

test "click on a user image chip opens the preview overlay" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    try m.push(.user, "@[/tmp/shot.png] can you see this");
    m.last_term_width = 80;
    m.last_term_height = 24;
    m.mid_origin = 0;
    m.mid_skip = 0;
    m.prompt_origin = 20;
    try std.testing.expect(mouse(&m, .{ .btn = 0, .x = 10, .y = 1, .down = true }));
    try std.testing.expectEqual(app.Overlay.image, m.overlay);
    try std.testing.expectEqualStrings("/tmp/shot.png", m.preview_path);
    try std.testing.expect(m.preview_pin);
}

test "hover on a composer chip opens an unpinned preview" {
    var m: Model = undefined;
    m.setup(std.testing.allocator);
    defer m.deinit();
    m.attachImage("/tmp/shot.png");
    m.prompt_origin = 10;
    try std.testing.expect(mouse(&m, .{ .btn = 35, .x = 5, .y = 12, .down = false }));
    try std.testing.expectEqual(app.Overlay.image, m.overlay);
    try std.testing.expectEqualStrings("/tmp/shot.png", m.preview_path);
    try std.testing.expect(!m.preview_pin);
}
