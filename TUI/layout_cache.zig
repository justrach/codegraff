//! Virtual layout for the transcript viewport.
//!
//! scrollback.render lays the WHOLE history out on every call: every entry is
//! re-wrapped through theme.wrapToWidth and the result concatenated into one
//! string, which render.zig then splits back into lines and throws all but a
//! screenful of away. That makes one wheel tick cost O(total transcript), and
//! on a long session it is exactly why scrolling feels bad.
//!
//! grok-build's answer, and this one: lay each BLOCK out once, keep the wrapped
//! bytes, and keep a prefix sum of where each block starts in virtual-Y. A
//! scroll is then a viewport SLICE — binary search to the block holding the top
//! line, walk forward a screenful — so a frame costs O(view height + log n)
//! instead of O(history).
//!
//! A block is one history entry, or a whole consecutive tool RUN (collapsed or
//! expanded), because that is the unit scrollback.render emits between '\n's.
//! Everything a block's bytes depend on — its entries' identity and fold state,
//! the width, the theme, whether the selection is inside it, and the user
//! ordinal that numbers a prompt — is folded into a 64-bit key, and a block
//! whose key still matches is reused verbatim. Appending to the transcript
//! therefore reuses the entire cached prefix, and a streaming turn re-lays out
//! only its own tail.
//!
//! Presentation state by construction: nothing here is engine state, and the
//! cache is a pure memo — dropping it changes performance and nothing else.
//! scrollback.render stays as the uncached reference that the property tests in
//! layout_cache_tests.zig check this against, byte for byte.

const std = @import("std");

const app = @import("app.zig");
const foldhdr = @import("foldhdr.zig");
const scrollback = @import("scrollback.zig");
const theme_mod = @import("theme.zig");
const Model = app.Model;

/// A laid-out block: the bytes scrollback.render would have emitted for the
/// history range [start, end), plus where they sit in virtual-Y.
pub const Block = struct {
    /// First history index of the block; `end` is exclusive. A live block — the
    /// pending stream tail or the steer notice — is not history at all and
    /// carries start >= history.len so it maps to no entry.
    start: usize,
    end: usize,
    key: u64,
    /// Owned by the cache's allocator. Empty only under OOM.
    text: []u8,
    lines: usize,
    first_line: usize = 0,
    /// Laid out fresh every frame and never reused: a `.pending` row animates
    /// off now_ms, and the live rows below change with the stream.
    vol: bool = false,
    /// Not history: the streaming tail or the steer notice. Maps to no entry.
    live: bool = false,
    /// The nearest `.user` entry's text at or before this block — what the
    /// sticky header pins. Refreshed on every walk, so it can never outlive the
    /// entry it points at.
    user_text: ?[]const u8 = null,
};

pub const Cache = struct {
    blocks: std.ArrayList(Block) = .empty,
    /// The width and theme the cached bytes were laid out at. A change in
    /// either is a cold rebuild: every block rewraps.
    width: usize = 0,
    theme: u8 = 0xff,
    total: usize = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    colds: u64 = 0,

    pub fn deinit(self: *Cache, gpa: std.mem.Allocator) void {
        self.invalidate(gpa);
        self.blocks.deinit(gpa);
        self.* = .{};
    }

    /// Drop every laid-out block, keeping the array's capacity. Callers that
    /// free the entries themselves (clearHistory) must come through here: a
    /// cached `user_text` points into entry storage.
    pub fn invalidate(self: *Cache, gpa: std.mem.Allocator) void {
        for (self.blocks.items) |b| if (b.text.len > 0) gpa.free(b.text);
        self.blocks.clearRetainingCapacity();
        self.total = 0;
    }
};

/// Bring the cache up to date for `width` and return it. Cheap when nothing
/// changed: one key per block, no wrapping and no allocation.
pub fn ensure(m: *Model, width: usize) *Cache {
    const c = &m.layout;
    const th: u8 = @intFromEnum(m.theme_id);
    if (c.width != width or c.theme != th) {
        c.invalidate(m.alloc);
        c.width = width;
        c.theme = th;
        c.colds += 1;
    }
    var arena = std.heap.ArenaAllocator.init(m.alloc);
    defer arena.deinit();

    var w: Walk = .{ .m = m, .c = c, .arena = &arena, .width = width, .th = th };
    var i: usize = 0;
    while (i < m.history.items.len) {
        const e = m.history.items[i];
        const end = if (e.kind == .tool) m.toolRun(i).end else i + 1;
        if (e.kind == .user) {
            w.users += 1;
            w.user_text = e.text;
        }
        w.place(i, end, e.kind == .pending, false);
        i = end;
    }
    w.placeLive();
    // Whatever the walk did not claim describes a transcript that no longer
    // exists — a cleared history, a removed pending row, a collapsed run.
    for (c.blocks.items[w.pos..]) |b| if (b.text.len > 0) m.alloc.free(b.text);
    c.blocks.shrinkRetainingCapacity(w.pos);
    c.total = w.line;
    return c;
}

const Walk = struct {
    m: *Model,
    c: *Cache,
    arena: *std.heap.ArenaAllocator,
    width: usize,
    th: u8,
    pos: usize = 0,
    line: usize = 0,
    users: u32 = 0,
    user_text: ?[]const u8 = null,

    fn place(self: *Walk, start: usize, end: usize, vol: bool, live: bool) void {
        const key = if (vol) 0 else blockKey(self.m, start, end, self.width, self.th, self.users);
        if (self.pos < self.c.blocks.items.len) {
            const b = &self.c.blocks.items[self.pos];
            if (!vol and !b.vol and b.key == key and b.start == start and b.end == end) {
                b.first_line = self.line;
                b.user_text = self.user_text;
                self.line += b.lines;
                self.pos += 1;
                self.c.hits += 1;
                return;
            }
            if (b.text.len > 0) self.m.alloc.free(b.text);
            b.* = self.build(start, end, key, vol, live);
            self.line += b.lines;
            self.pos += 1;
            self.c.misses += 1;
            return;
        }
        const b = self.build(start, end, key, vol, live);
        self.c.blocks.append(self.m.alloc, b) catch {
            if (b.text.len > 0) self.m.alloc.free(b.text);
            return;
        };
        self.line += b.lines;
        self.pos += 1;
        self.c.misses += 1;
    }

    fn build(self: *Walk, start: usize, end: usize, key: u64, vol: bool, live: bool) Block {
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        const text = if (live)
            liveText(self.m, a, start, end, self.width) catch ""
        else
            blockText(self.m, a, start, end, self.width, self.users) catch "";
        const owned: []u8 = self.m.alloc.dupe(u8, text) catch &.{};
        return .{
            .start = start,
            .end = end,
            .key = key,
            .text = owned,
            .lines = scrollback.lineCount(owned),
            .first_line = self.line,
            .vol = vol,
            .live = live,
            .user_text = self.user_text,
        };
    }

    /// The two rows a live turn owns: the streaming prose tail and the steer
    /// notice. Both change every frame, so they are laid out fresh every time
    /// and never claim a cached slot's identity.
    fn placeLive(self: *Walk) void {
        const m = self.m;
        const job = m.pending orelse return;
        if (m.cancel_requested) return;
        const n = m.history.items.len;
        if (job.stream.len.load(.acquire) > 0) self.place(n, n, true, true);
        if (m.steer_queue.items.len > 0) self.place(n, n + 1, true, true);
    }
};

/// Which live row this is: `end == start` is the stream tail, anything else is
/// the steer notice. Keeps the two apart without a third field.
fn liveText(m: *Model, a: std.mem.Allocator, start: usize, end: usize, width: usize) ![]const u8 {
    if (end != start) return steerText(m, a);
    const job = m.pending orelse return "";
    const live = job.stream.snapshot(a) orelse return "";
    return theme_mod.paint(a, m.theme().muted, try scrollback.tail(a, scrollback.strip(a, live), width, 4));
}

fn steerText(m: *Model, a: std.mem.Allocator) ![]const u8 {
    return theme_mod.paint(a, m.theme().muted, try std.fmt.allocPrint(a, "  ↳ {d} queued · empty Enter sends now", .{m.steer_queue.items.len}));
}

/// One block's bytes, composed exactly as scrollback.render composes them —
/// same helpers, same selection rule, same '\n' between the rows of an expanded
/// tool run.
fn blockText(m: *const Model, a: std.mem.Allocator, start: usize, end: usize, width: usize, users: u32) ![]const u8 {
    const e = m.history.items[start];
    if (e.kind != .tool) {
        const sel = m.focus == .scrollback and m.selected >= start and m.selected < end;
        return scrollback.row(m, a, users, e, width, m.now_ms, sel);
    }
    return scrollback.runVisual(m, a, start, end, width, m.now_ms);
}

/// Everything the block's bytes are a function of. Entry identity is the
/// (pointer, length) of its owned strings — entries are immutable once pushed,
/// and freed on replacement — with a bounded content sample mixed in so an
/// allocator that hands the same address and length back for different bytes
/// cannot fake a hit.
fn blockKey(m: *const Model, start: usize, end: usize, width: usize, th: u8, users: u32) u64 {
    var h = std.hash.Wyhash.init(0x1a70c0de);
    h.update(std.mem.asBytes(&width));
    h.update(std.mem.asBytes(&th));
    h.update(std.mem.asBytes(&users));
    const sel: usize = if (m.focus == .scrollback and m.selected >= start and m.selected < end) m.selected + 1 else 0;
    h.update(std.mem.asBytes(&sel));
    // A tool run's header carries a settle FLASH that turns itself off a
    // second after the last call lands (foldhdr.zig). Nothing else about the
    // block moves when it does, so without this the cache would keep serving
    // the tinted row forever — the one place where these bytes are a function
    // of the clock as well as of the entries.
    if (m.history.items[start].kind == .tool) {
        const flash = @intFromBool(foldhdr.flashing(foldhdr.scan(m, start, end), m.now_ms));
        h.update(std.mem.asBytes(&flash));
    }
    var i = start;
    while (i < end) : (i += 1) {
        const e = m.history.items[i];
        var flags: u8 = @intFromEnum(e.kind);
        flags |= @as(u8, @intFromBool(e.folded)) << 4;
        h.update(std.mem.asBytes(&flags));
        mixSlice(&h, e.text);
        var tf: u8 = 0;
        if (e.tool) |t| {
            tf = 1;
            tf |= @as(u8, @intFromBool(t.done)) << 1;
            tf |= @as(u8, @intFromBool(t.is_error)) << 2;
            tf |= @as(u8, @intFromBool(t.denied)) << 3;
            h.update(std.mem.asBytes(&tf));
            mixSlice(&h, t.name);
            mixSlice(&h, t.detail);
        } else h.update(std.mem.asBytes(&tf));
    }
    return h.final();
}

fn mixSlice(h: *std.hash.Wyhash, s: []const u8) void {
    const p = @intFromPtr(s.ptr);
    h.update(std.mem.asBytes(&p));
    const n = s.len;
    h.update(std.mem.asBytes(&n));
    if (s.len <= 32) {
        h.update(s);
        return;
    }
    h.update(s[0..16]);
    h.update(s[s.len - 16 ..]);
}

// --- viewport queries ------------------------------------------------------

/// The `count` display lines starting at virtual row `from`. The slices point
/// into the cache's own bytes, so this allocates only the index array.
pub fn window(c: *const Cache, a: std.mem.Allocator, from: usize, count: usize) ![]const []const u8 {
    var out = std.array_list.Managed([]const u8).init(a);
    if (count == 0) return out.items;
    var bi = blockOfLine(c, from) orelse return out.items;
    while (bi < c.blocks.items.len and out.items.len < count) : (bi += 1) {
        const b = c.blocks.items[bi];
        var it = std.mem.splitScalar(u8, b.text, '\n');
        var ord: usize = 0;
        while (it.next()) |ln| : (ord += 1) {
            if (b.first_line + ord < from) continue;
            if (out.items.len >= count) break;
            try out.append(ln);
        }
    }
    return out.items;
}

/// History index shown on virtual row `y` — a tool run answers with its start,
/// a live row with null. Mirrors scrollback.indexAtVisual.
pub fn indexAt(c: *const Cache, y: usize) ?usize {
    const bi = blockOfLine(c, y) orelse return null;
    const b = c.blocks.items[bi];
    if (b.live) return null;
    return b.start;
}

/// First virtual row of entry `idx` (a tool run answers with its own first
/// row). Mirrors scrollback.visualOfIndex.
pub fn lineOf(c: *const Cache, idx: usize) ?usize {
    const bs = c.blocks.items;
    if (bs.len == 0) return null;
    var lo: usize = 0;
    var hi: usize = bs.len;
    while (lo + 1 < hi) {
        const mid = lo + (hi - lo) / 2;
        if (bs[mid].start <= idx) lo = mid else hi = mid;
    }
    const b = bs[lo];
    if (b.live or idx < b.start or idx >= b.end) return null;
    return b.first_line;
}

/// The last user prompt whose first row sits strictly above `top` — the grok
/// sticky-header candidate, in O(log n) off the per-block back-pointer.
pub fn stickyUserAbove(c: *const Cache, top: usize) ?[]const u8 {
    const bs = c.blocks.items;
    if (bs.len == 0 or top == 0 or bs[0].first_line >= top) return null;
    var lo: usize = 0;
    var hi: usize = bs.len;
    while (lo + 1 < hi) {
        const mid = lo + (hi - lo) / 2;
        if (bs[mid].first_line < top) lo = mid else hi = mid;
    }
    return bs[lo].user_text;
}

fn blockOfLine(c: *const Cache, y: usize) ?usize {
    const bs = c.blocks.items;
    if (bs.len == 0 or y >= c.total) return null;
    var lo: usize = 0;
    var hi: usize = bs.len;
    while (lo + 1 < hi) {
        const mid = lo + (hi - lo) / 2;
        if (bs[mid].first_line <= y) lo = mid else hi = mid;
    }
    return lo;
}

// --- Model-level convenience (same shapes as the scrollback originals) ------

pub fn totalVisualLines(m: *Model, width: usize) usize {
    return ensure(m, width).total;
}

pub fn indexAtVisual(m: *Model, y: usize, width: usize) ?usize {
    return indexAt(ensure(m, width), y);
}

pub fn visualOfIndex(m: *Model, idx: usize, width: usize) ?usize {
    return lineOf(ensure(m, width), idx);
}

test {
    _ = @import("layout_cache_tests.zig");
}
