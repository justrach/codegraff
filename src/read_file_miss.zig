//! Consecutive not-found `read_file` guesses. Same-prefix misses or an
//! incrementing numbered filename pattern stop after N misses in one turn
//! (#1116). Bounded lexical repetition (ADR 0065) is prose-only; this gate
//! is the tool-path counterpart. REPL, TUI, and ACP share exec.zig.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const miss_limit: u8 = 3;
const max_dir = 256;
const max_slots = 8;

const Slot = struct {
    dir: [max_dir]u8 = undefined,
    dir_len: u8 = 0,
    misses: u8 = 0,
    last_number: ?u32 = null,
    sequential: u8 = 0,
    blocked: bool = false,

    fn dirSlice(self: *const Slot) []const u8 {
        return self.dir[0..self.dir_len];
    }
};

/// Spin-lock: this Zig has no `std.Thread.Mutex`, and the io-less helpers
/// (`resetTurn`, `noteMiss`) have no `Io` to park an `Io.Mutex` on.
var lock: std.atomic.Value(bool) = .init(false);
var slots: [max_slots]Slot = @splat(.{});
var used: u8 = 0;
/// Off until a root turn arms the tracker so unrelated unit tests cannot trip it.
var armed: bool = false;

fn lockSlots() void {
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlockSlots() void {
    lock.store(false, .release);
}

pub fn dirOf(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/\\");
    if (trimmed.len == 0) return ".";
    if (std.fs.path.dirname(trimmed)) |d| {
        if (d.len == 0 or std.mem.eql(u8, d, ".")) return ".";
        return d;
    }
    return ".";
}

pub fn leadingNumber(name: []const u8) ?u32 {
    if (name.len == 0 or !std.ascii.isDigit(name[0])) return null;
    var n: u64 = 0;
    for (name) |c| {
        if (!std.ascii.isDigit(c)) break;
        n = n * 10 + (c - '0');
        if (n > 1_000_000) return 1_000_000;
    }
    return @intCast(n);
}

pub fn resetTurn() void {
    lockSlots();
    defer unlockSlots();
    used = 0;
    armed = true;
}

pub fn resetForTest() void {
    lockSlots();
    defer unlockSlots();
    used = 0;
    armed = false;
}

fn sameDir(slot: *const Slot, dir: []const u8) bool {
    return std.mem.eql(u8, slot.dirSlice(), dir);
}

fn findSlotLocked(dir: []const u8) ?*Slot {
    for (slots[0..used]) |*slot| {
        if (sameDir(slot, dir)) return slot;
    }
    return null;
}

fn takeSlotLocked(dir: []const u8) *Slot {
    if (findSlotLocked(dir)) |slot| return slot;
    const store = if (dir.len > max_dir) dir[0..max_dir] else dir;
    if (used < max_slots) {
        const slot = &slots[used];
        used += 1;
        slot.* = .{};
        @memcpy(slot.dir[0..store.len], store);
        slot.dir_len = @intCast(store.len);
        return slot;
    }
    const slot = &slots[0];
    slot.* = .{};
    @memcpy(slot.dir[0..store.len], store);
    slot.dir_len = @intCast(store.len);
    return slot;
}

pub fn blocked(path: []const u8) bool {
    lockSlots();
    defer unlockSlots();
    if (!armed) return false;
    const slot = findSlotLocked(dirOf(path)) orelse return false;
    return slot.blocked;
}

/// Record a not-found. Returns true once this prefix (or incrementing name
/// pattern) has hit the stop.
pub fn noteMiss(path: []const u8) bool {
    lockSlots();
    defer unlockSlots();
    if (!armed) return false;
    const dir = dirOf(path);
    const slot = takeSlotLocked(dir);
    if (slot.misses < 255) slot.misses += 1;
    const number = leadingNumber(std.fs.path.basename(path));
    if (number) |n| {
        if (slot.last_number) |prev| {
            if (n > prev and slot.sequential < 255) slot.sequential += 1;
        } else slot.sequential = 1;
        slot.last_number = n;
    }
    if (slot.misses >= miss_limit or slot.sequential >= miss_limit) slot.blocked = true;
    return slot.blocked;
}

pub fn noteHit(path: []const u8) void {
    lockSlots();
    defer unlockSlots();
    if (!armed) return;
    const slot = findSlotLocked(dirOf(path)) orelse return;
    slot.misses = 0;
    slot.sequential = 0;
    slot.last_number = null;
    slot.blocked = false;
}

pub fn message(gpa: Allocator, path: []const u8) ![]u8 {
    const dir = dirOf(path);
    if (std.mem.eql(u8, dir, ".")) {
        return std.fmt.allocPrint(gpa, "read_file: stopped guessing paths in the working directory after {d} missing files — list the directory with codedb list_dir instead of inventing names", .{miss_limit});
    }
    return std.fmt.allocPrint(gpa, "read_file: stopped guessing paths under {s}/ after {d} missing files — list the directory with codedb list_dir instead of inventing names", .{ dir, miss_limit });
}

fn exists(io: Io, resolved: []const u8) bool {
    const file = Io.Dir.cwd().openFile(io, resolved, .{}) catch return false;
    file.close(io);
    return true;
}

/// Refuse an invented path under a blocked prefix. A file that actually
/// exists still reads.
pub fn stopGuess(io: Io, gpa: Allocator, path: []const u8, resolved: []const u8) ?[]u8 {
    if (!blocked(path)) return null;
    if (exists(io, resolved)) return null;
    return message(gpa, path) catch null;
}

/// On a not-found, record the miss and replace the error once the prefix stops.
pub fn decorateMiss(gpa: Allocator, path: []const u8, err: anyerror, text: []u8) []u8 {
    if (err != error.FileNotFound and err != error.NotDir) return text;
    if (!noteMiss(path)) return text;
    const stop = message(gpa, path) catch return text;
    gpa.free(text);
    return stop;
}

test "dirOf and leadingNumber: ADR-shaped guesses" {
    try std.testing.expectEqualStrings("docs/adr", dirOf("docs/adr/0365-foo.md"));
    try std.testing.expectEqualStrings("docs/adr", dirOf("docs/adr/0397-bar.md"));
    try std.testing.expectEqualStrings(".", dirOf("README.md"));
    try std.testing.expectEqual(@as(?u32, 365), leadingNumber("0365-foo.md"));
    try std.testing.expectEqual(@as(?u32, 397), leadingNumber("0397-bar.md"));
    try std.testing.expectEqual(@as(?u32, null), leadingNumber("README.md"));
}

test "#1116: three same-prefix misses stop further invented names" {
    resetTurn();
    defer resetForTest();
    try std.testing.expect(!noteMiss("docs/adr/0365-alpha.md"));
    try std.testing.expect(!noteMiss("docs/adr/0366-beta.md"));
    try std.testing.expect(noteMiss("docs/adr/0367-gamma.md"));
    try std.testing.expect(blocked("docs/adr/0368-delta.md"));
    try std.testing.expect(!blocked("src/main.zig"));
    const gpa = std.testing.allocator;
    const text = try message(gpa, "docs/adr/0368-delta.md");
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "docs/adr/") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "codedb list_dir") != null);
}

test "#1116: a hit on the prefix clears the stop; another directory is independent" {
    resetTurn();
    defer resetForTest();
    _ = noteMiss("tmp/a.txt");
    _ = noteMiss("tmp/b.txt");
    try std.testing.expect(!blocked("tmp/c.txt"));
    noteHit("tmp/real.txt");
    try std.testing.expect(!noteMiss("tmp/again.txt"));
    try std.testing.expect(!noteMiss("other/x.txt"));
    try std.testing.expect(!noteMiss("other/y.txt"));
    try std.testing.expect(noteMiss("other/z.txt"));
    try std.testing.expect(blocked("other/w.txt"));
    try std.testing.expect(!blocked("tmp/again.txt"));
}

test "#1116: incrementing numbered names under one prefix are a storm" {
    resetTurn();
    defer resetForTest();
    try std.testing.expect(!noteMiss("docs/adr/0365-one.md"));
    try std.testing.expect(!noteMiss("docs/adr/0366-two.md"));
    try std.testing.expect(noteMiss("docs/adr/0397-reshuffle.md"));
    try std.testing.expect(blocked("docs/adr/0398-next.md"));
}

test "#1116: unarmed tracker does not record misses" {
    resetForTest();
    try std.testing.expect(!noteMiss("docs/adr/0365-alpha.md"));
    try std.testing.expect(!noteMiss("docs/adr/0366-beta.md"));
    try std.testing.expect(!noteMiss("docs/adr/0367-gamma.md"));
    try std.testing.expect(!blocked("docs/adr/0368-delta.md"));
}
