//! One stable sort for every element type. `std.mem.sort` instantiates its
//! block sort per element type and comparator, ~18 KB of machine code each in
//! a release build; graff's two dozen call sites cost about half a megabyte.
//! Here the merge sort is compiled once and works on bytes; each call site
//! adds only a small comparator thunk. Same contract as `std.mem.sort`:
//! stable, ascending by `lessThanFn`.

const std = @import("std");

const Less = *const fn (ctx: *const anyopaque, a: *const anyopaque, b: *const anyopaque) bool;

/// Drop-in for `std.mem.sort`.
pub fn sort(
    comptime T: type,
    items: []T,
    context: anytype,
    comptime lessThanFn: fn (@TypeOf(context), lhs: T, rhs: T) bool,
) void {
    if (@sizeOf(T) == 0 or items.len < 2) return;
    const Ctx = @TypeOf(context);
    const Thunk = struct {
        fn less(ctx: *const anyopaque, a: *const anyopaque, b: *const anyopaque) bool {
            const c: *const Ctx = @ptrCast(@alignCast(ctx));
            const x: *const T = @ptrCast(@alignCast(a));
            const y: *const T = @ptrCast(@alignCast(b));
            return lessThanFn(c.*, x.*, y.*);
        }
    };
    const ctx_copy = context;
    sortBytes(
        @ptrCast(items.ptr),
        items.len,
        @sizeOf(T),
        .fromByteUnits(@alignOf(T)),
        @ptrCast(&ctx_copy),
        Thunk.less,
    );
}

/// Runs shorter than this are insertion-sorted in place before merging.
const run_len = 16;

fn sortBytes(base: [*]u8, n: usize, size: usize, alignment: std.mem.Alignment, ctx: *const anyopaque, less: Less) void {
    var start: usize = 0;
    while (start < n) : (start += run_len) insertion(base, start, @min(start + run_len, n), size, ctx, less);
    if (n <= run_len) return;

    // Merging needs a second buffer. Without one, finish with insertion sort:
    // still correct and stable, only slower on long lists.
    const gpa = std.heap.smp_allocator;
    const buf = gpa.rawAlloc(n * size, alignment, @returnAddress()) orelse
        return insertion(base, 0, n, size, ctx, less);
    defer gpa.rawFree(buf[0 .. n * size], alignment, @returnAddress());

    var src = base;
    var dst = buf;
    var width: usize = run_len;
    while (width < n) : (width *= 2) {
        var lo: usize = 0;
        while (lo < n) : (lo += 2 * width) {
            const mid = @min(lo + width, n);
            const hi = @min(lo + 2 * width, n);
            merge(src, dst, lo, mid, hi, size, ctx, less);
        }
        std.mem.swap([*]u8, &src, &dst);
    }
    if (src != base) @memcpy(base[0 .. n * size], src[0 .. n * size]);
}

fn insertion(base: [*]u8, lo: usize, hi: usize, size: usize, ctx: *const anyopaque, less: Less) void {
    var i = lo + 1;
    while (i < hi) : (i += 1) {
        var j = i;
        while (j > lo and less(ctx, base + j * size, base + (j - 1) * size)) : (j -= 1) {
            swapBytes(base + j * size, base + (j - 1) * size, size);
        }
    }
}

/// Merge src[lo..mid] and src[mid..hi] into dst[lo..hi]; ties keep the left run first.
fn merge(src: [*]const u8, dst: [*]u8, lo: usize, mid: usize, hi: usize, size: usize, ctx: *const anyopaque, less: Less) void {
    var i = lo;
    var j = mid;
    var k = lo;
    while (i < mid and j < hi) : (k += 1) {
        if (less(ctx, src + j * size, src + i * size)) {
            @memcpy(dst[k * size ..][0..size], src[j * size ..][0..size]);
            j += 1;
        } else {
            @memcpy(dst[k * size ..][0..size], src[i * size ..][0..size]);
            i += 1;
        }
    }
    if (i < mid) @memcpy(dst[k * size .. hi * size], src[i * size .. mid * size]);
    if (j < hi) @memcpy(dst[k * size .. hi * size], src[j * size .. hi * size]);
}

fn swapBytes(a: [*]u8, b: [*]u8, size: usize) void {
    for (a[0..size], b[0..size]) |*x, *y| std.mem.swap(u8, x, y);
}

const Pair = struct { key: u32, seq: u32 };

fn byKey(_: void, a: Pair, b: Pair) bool {
    return a.key < b.key;
}

test "sort is stable and matches std.mem.sort across run boundaries" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    for ([_]usize{ 0, 1, 2, 15, 16, 17, 31, 33, 100, 1000, 4097 }) |n| {
        const ours = try std.testing.allocator.alloc(Pair, n);
        defer std.testing.allocator.free(ours);
        const want = try std.testing.allocator.alloc(Pair, n);
        defer std.testing.allocator.free(want);
        for (ours, 0..) |*p, i| p.* = .{ .key = rand.uintLessThan(u32, 8), .seq = @intCast(i) };
        @memcpy(want, ours);
        sort(Pair, ours, {}, byKey);
        std.mem.sort(Pair, want, {}, byKey);
        try std.testing.expectEqualSlices(Pair, want, ours);
    }
}

test "sort passes its context and handles slices and pointers" {
    const Desc = struct {
        fn less(flip: bool, a: []const u8, b: []const u8) bool {
            const lt = std.mem.lessThan(u8, a, b);
            return if (flip) !lt and !std.mem.eql(u8, a, b) else lt;
        }
    };
    var words = [_][]const u8{ "pear", "apple", "fig", "kiwi", "banana" };
    sort([]const u8, &words, true, Desc.less);
    try std.testing.expectEqualStrings("pear", words[0]);
    try std.testing.expectEqualStrings("apple", words[4]);

    var nums = [_]u64{ 9, 3, 7, 1 };
    sort(u64, &nums, {}, std.sort.asc(u64));
    try std.testing.expectEqualSlices(u64, &.{ 1, 3, 7, 9 }, &nums);
}
