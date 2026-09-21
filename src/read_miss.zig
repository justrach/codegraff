//! Consecutive `read_file` miss storm (#1116).
//!
//! After N not-found reads under the same directory prefix, or an incrementing
//! numbered filename pattern, further guessed reads this turn are refused and
//! pointed at `codedb list_dir`. Catalog dispatch and RLM host calls share one
//! Tracker so REPL / TUI / GUI behave the same. ADR 0065 covers prose only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const json_args = @import("json_args.zig");

pub const miss_limit: u8 = 3;
pub const max_prefix_len: usize = 255;

pub const Wave = enum { run, hold, refuse };

const PrefixSlot = struct {
    buf: [max_prefix_len]u8 = undefined,
    len: u8 = 0,
    misses: u8 = 0,
    last_number: ?u64 = null,
    incrementing: u8 = 0,
    latched: bool = false,

    fn prefix(self: *const PrefixSlot) []const u8 {
        return self.buf[0..self.len];
    }

    fn setPrefix(self: *PrefixSlot, p: []const u8) void {
        const n = @min(p.len, max_prefix_len);
        @memcpy(self.buf[0..n], p[0..n]);
        self.len = @intCast(n);
    }

    fn matches(self: *const PrefixSlot, p: []const u8) bool {
        return self.len > 0 and std.mem.eql(u8, self.prefix(), p);
    }

    fn reset(self: *PrefixSlot) void {
        self.* = .{};
    }
};

/// Turn-scoped miss state. Fixed slots; no heap. Reset at `runTurn`.
pub const Tracker = struct {
    slots: [8]PrefixSlot = @splat(.{}),

    pub fn reset(self: *Tracker) void {
        self.* = .{};
    }

    fn slotFor(self: *Tracker, prefix: []const u8) *PrefixSlot {
        for (&self.slots) |*s| {
            if (s.matches(prefix)) return s;
        }
        for (&self.slots) |*s| {
            if (s.len == 0) {
                s.setPrefix(prefix);
                return s;
            }
        }
        var best = &self.slots[0];
        for (self.slots[1..]) |*s| {
            if (s.misses < best.misses) best = s;
        }
        best.reset();
        best.setPrefix(prefix);
        return best;
    }

    fn find(self: *const Tracker, prefix: []const u8) ?*const PrefixSlot {
        for (&self.slots) |*s| {
            if (s.matches(prefix)) return s;
        }
        return null;
    }

    pub fn shouldRefuse(self: *const Tracker, path: []const u8) bool {
        const slot = self.find(dirPrefix(path)) orelse return false;
        return slot.latched;
    }

    pub fn remaining(self: *const Tracker, path: []const u8) u8 {
        const slot = self.find(dirPrefix(path)) orelse return miss_limit;
        if (slot.latched) return 0;
        if (slot.misses >= miss_limit) return 0;
        return miss_limit - slot.misses;
    }

    pub fn noteResult(self: *Tracker, path: []const u8, missed: bool) void {
        const prefix = dirPrefix(path);
        const slot = self.slotFor(prefix);
        if (!missed) {
            slot.reset();
            return;
        }
        slot.misses +|= 1;
        if (fileNumber(path)) |n| {
            if (slot.last_number) |prev| {
                if (n == prev + 1) slot.incrementing +|= 1 else slot.incrementing = 1;
            } else slot.incrementing = 1;
            slot.last_number = n;
        } else {
            slot.last_number = null;
            slot.incrementing = 0;
        }
        if (slot.misses >= miss_limit or slot.incrementing >= miss_limit) slot.latched = true;
    }

    pub fn noteOutput(self: *Tracker, name: []const u8, input: Value, text: []const u8, is_error: bool) void {
        if (!std.mem.eql(u8, name, "read_file")) return;
        const path = callPath(input) orelse return;
        self.noteResult(path, is_error and isMissText(text));
    }
};

pub fn callPath(input: Value) ?[]const u8 {
    const obj = json_args.object(input) orelse return null;
    const p = json_args.str(obj, "path") orelse return null;
    const t = std.mem.trim(u8, p, " \t");
    return if (t.len == 0) null else t;
}

pub fn pathFromArgsJson(args_json: []const u8) ?[]const u8 {
    const key = "\"path\"";
    const start = std.mem.indexOf(u8, args_json, key) orelse return null;
    var i = start + key.len;
    while (i < args_json.len and (args_json[i] == ' ' or args_json[i] == ':')) i += 1;
    if (i >= args_json.len or args_json[i] != '"') return null;
    i += 1;
    const from = i;
    while (i < args_json.len and args_json[i] != '"') i += 1;
    if (i >= args_json.len) return null;
    const t = std.mem.trim(u8, args_json[from..i], " \t");
    return if (t.len == 0) null else t;
}

pub fn dirPrefix(path: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, path, " \t");
    if (trimmed.len == 0) return ".";
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return ".";
    if (slash == 0) return "/";
    return trimmed[0..slash];
}

/// First run of digits in the basename (`0365-foo.md` → 365).
pub fn fileNumber(path: []const u8) ?u64 {
    const name = basename(path);
    var i: usize = 0;
    while (i < name.len and !std.ascii.isDigit(name[i])) i += 1;
    if (i == name.len) return null;
    var n: u64 = 0;
    var digits: u8 = 0;
    while (i < name.len and std.ascii.isDigit(name[i])) : (i += 1) {
        n = n * 10 + (name[i] - '0');
        digits += 1;
        if (digits > 18) break;
    }
    return if (digits == 0) null else n;
}

fn basename(path: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, path, " \t");
    if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |slash| return trimmed[slash + 1 ..];
    return trimmed;
}

pub fn isMissText(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "does not exist") != null;
}

pub fn refusalText(gpa: Allocator, path: []const u8) ![]u8 {
    const prefix = dirPrefix(path);
    return std.fmt.allocPrint(
        gpa,
        "read_file: refused further guesses under {s}/ after {d} not-found reads this turn — list the directory with codedb list_dir {s} instead of inventing paths",
        .{ prefix, miss_limit, prefix },
    );
}

/// True when `paths` in call order are same-prefix and lockstep-numbered.
pub fn incrementingGroup(paths: []const []const u8) bool {
    if (paths.len < miss_limit) return false;
    const prefix = dirPrefix(paths[0]);
    var prev = fileNumber(paths[0]) orelse return false;
    for (paths[1..]) |p| {
        if (!std.mem.eql(u8, dirPrefix(p), prefix)) return false;
        const n = fileNumber(p) orelse return false;
        if (n != prev + 1) return false;
        prev = n;
    }
    return true;
}

const BatchQueued = struct {
    prefix: [max_prefix_len]u8 = undefined,
    len: u8 = 0,
    n: u8 = 0,

    fn matches(self: *const BatchQueued, p: []const u8) bool {
        return self.len > 0 and std.mem.eql(u8, self.prefix[0..self.len], p);
    }
};

/// Per-batch cap so a parallel storm does not execute every invented path.
pub const Batch = struct {
    queued: [8]BatchQueued = @splat(.{}),
    used: u8 = 0,
    incrementing: bool = false,

    pub fn init(paths: []const []const u8) Batch {
        return .{ .incrementing = incrementingGroup(paths) };
    }

    fn queuedFor(self: *Batch, prefix: []const u8) *BatchQueued {
        for (self.queued[0..self.used]) |*q| {
            if (q.matches(prefix)) return q;
        }
        if (self.used == self.queued.len) return &self.queued[0];
        const q = &self.queued[self.used];
        self.used += 1;
        const n = @min(prefix.len, max_prefix_len);
        @memcpy(q.prefix[0..n], prefix[0..n]);
        q.len = @intCast(n);
        q.n = 0;
        return q;
    }

    pub fn classify(self: *Batch, tracker: *const Tracker, path: []const u8) Wave {
        if (tracker.shouldRefuse(path)) return .refuse;
        const left = tracker.remaining(path);
        if (left == 0) return .refuse;
        // Non-incrementing first-wave reads stay uncapped so a real multi-file
        // read in one directory is not split. Incrementing names, or a prefix
        // that already missed this turn, are capped at `left`.
        const cap: u8 = if (self.incrementing or left < miss_limit) left else 255;
        const q = self.queuedFor(dirPrefix(path));
        if (q.n >= cap) return .hold;
        q.n += 1;
        return .run;
    }
};

pub fn classifyPath(tracker: *const Tracker, batch: *Batch, path: []const u8) Wave {
    return batch.classify(tracker, path);
}

test "dirPrefix and fileNumber parse ADR-style guesses" {
    try std.testing.expectEqualStrings("docs/adr", dirPrefix("docs/adr/0365-foo.md"));
    try std.testing.expectEqualStrings(".", dirPrefix("0365-foo.md"));
    try std.testing.expectEqualStrings("/", dirPrefix("/abs/0365-foo.md")[0..1]);
    try std.testing.expectEqual(@as(?u64, 365), fileNumber("docs/adr/0365-foo.md"));
    try std.testing.expectEqual(@as(?u64, 397), fileNumber("docs/adr/0397-reshuffled-slug.md"));
    try std.testing.expectEqual(@as(?u64, null), fileNumber("docs/adr/README.md"));
}

test "same-prefix misses latch after miss_limit and refuse further guesses" {
    var t: Tracker = .{};
    t.noteResult("docs/adr/0365-a.md", true);
    t.noteResult("docs/adr/0366-b.md", true);
    try std.testing.expect(!t.shouldRefuse("docs/adr/0367-c.md"));
    t.noteResult("docs/adr/0367-c.md", true);
    try std.testing.expect(t.shouldRefuse("docs/adr/0368-d.md"));
    try std.testing.expect(t.shouldRefuse("docs/adr/README.md"));
    try std.testing.expect(!t.shouldRefuse("src/main.zig"));
}

test "a hit clears the prefix so a later real read is not blocked" {
    var t: Tracker = .{};
    t.noteResult("docs/adr/0365-a.md", true);
    t.noteResult("docs/adr/0366-b.md", true);
    t.noteResult("docs/adr/0367-c.md", true);
    try std.testing.expect(t.shouldRefuse("docs/adr/0368-d.md"));
    t.noteResult("docs/adr/0001-structured-outputs.md", false);
    try std.testing.expect(!t.shouldRefuse("docs/adr/0002-xai-defaults.md"));
}

test "a different prefix does not inherit the latch" {
    var t: Tracker = .{};
    t.noteResult("docs/adr/0365-a.md", true);
    t.noteResult("docs/adr/0366-b.md", true);
    t.noteResult("docs/adr/0367-c.md", true);
    t.noteResult("src/missing.zig", true);
    try std.testing.expect(t.shouldRefuse("docs/adr/0368-d.md"));
    try std.testing.expect(!t.shouldRefuse("src/other.zig"));
}

test "incrementingGroup detects lockstep numbered names" {
    const storm = [_][]const u8{
        "docs/adr/0365-foo.md",
        "docs/adr/0366-bar.md",
        "docs/adr/0367-baz.md",
        "docs/adr/0368-qux.md",
    };
    try std.testing.expect(incrementingGroup(&storm));
    const mixed = [_][]const u8{ "docs/adr/0365-foo.md", "src/0366.zig", "docs/adr/0367-baz.md" };
    try std.testing.expect(!incrementingGroup(&mixed));
    const two = [_][]const u8{ "docs/adr/0365-foo.md", "docs/adr/0366-bar.md" };
    try std.testing.expect(!incrementingGroup(&two));
}

test "batch holds incrementing overflow until the first misses latch" {
    const paths = [_][]const u8{
        "docs/adr/0365-a.md",
        "docs/adr/0366-b.md",
        "docs/adr/0367-c.md",
        "docs/adr/0368-d.md",
        "docs/adr/0369-e.md",
        "docs/adr/0370-f.md",
    };
    var t: Tracker = .{};
    var batch = Batch.init(&paths);
    var waves: [6]Wave = undefined;
    for (paths, 0..) |p, i| waves[i] = batch.classify(&t, p);
    try std.testing.expectEqual(Wave.run, waves[0]);
    try std.testing.expectEqual(Wave.run, waves[1]);
    try std.testing.expectEqual(Wave.run, waves[2]);
    try std.testing.expectEqual(Wave.hold, waves[3]);
    try std.testing.expectEqual(Wave.hold, waves[4]);
    try std.testing.expectEqual(Wave.hold, waves[5]);

    t.noteResult(paths[0], true);
    t.noteResult(paths[1], true);
    t.noteResult(paths[2], true);
    try std.testing.expect(t.shouldRefuse(paths[3]));
    const held = paths[3..];
    var refuse_batch = Batch.init(held);
    try std.testing.expectEqual(Wave.refuse, refuse_batch.classify(&t, paths[3]));
}

test "batch of existing incrementing files is not refused after a hit" {
    const paths = [_][]const u8{
        "shots/001.png",
        "shots/002.png",
        "shots/003.png",
        "shots/004.png",
    };
    var t: Tracker = .{};
    var batch = Batch.init(&paths);
    try std.testing.expectEqual(Wave.run, batch.classify(&t, paths[0]));
    try std.testing.expectEqual(Wave.run, batch.classify(&t, paths[1]));
    try std.testing.expectEqual(Wave.run, batch.classify(&t, paths[2]));
    try std.testing.expectEqual(Wave.hold, batch.classify(&t, paths[3]));
    t.noteResult(paths[0], false);
    t.noteResult(paths[1], false);
    t.noteResult(paths[2], false);
    try std.testing.expect(!t.shouldRefuse(paths[3]));
    const rest = paths[3..];
    var hit_batch = Batch.init(rest);
    try std.testing.expectEqual(Wave.run, hit_batch.classify(&t, paths[3]));
}

test "non-incrementing same-prefix reads stay uncapped until misses accrue" {
    const paths = [_][]const u8{ "src/a.zig", "src/b.zig", "src/c.zig", "src/d.zig" };
    var t: Tracker = .{};
    var batch = Batch.init(&paths);
    try std.testing.expect(!batch.incrementing);
    for (paths) |p| try std.testing.expectEqual(Wave.run, batch.classify(&t, p));
}

test "refusalText names codedb list_dir and the prefix" {
    const gpa = std.testing.allocator;
    const msg = try refusalText(gpa, "docs/adr/0365-foo.md");
    defer gpa.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "codedb list_dir docs/adr") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "refused") != null);
    try std.testing.expect(isMissText("read_file: docs/adr/0365-foo.md does not exist (paths are relative"));
    try std.testing.expect(!isMissText("permission denied"));
}

test "callPath and pathFromArgsJson read the path field" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try std.json.parseFromSliceLeaky(Value, a, "{\"path\":\"docs/adr/0365-a.md\"}", .{});
    try std.testing.expectEqualStrings("docs/adr/0365-a.md", callPath(v).?);
    try std.testing.expectEqualStrings("docs/adr/0365-a.md", pathFromArgsJson("{\"path\":\"docs/adr/0365-a.md\"}").?);
    try std.testing.expect(callPath(.{ .object = .empty }) == null);
}

test "noteOutput ignores non-read tools and non-miss errors" {
    var t: Tracker = .{};
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const input = try std.json.parseFromSliceLeaky(Value, a, "{\"path\":\"docs/adr/0365-a.md\"}", .{});
    t.noteOutput("edit_file", input, "does not exist", true);
    try std.testing.expect(!t.shouldRefuse("docs/adr/0366-b.md"));
    t.noteOutput("read_file", input, "permission denied", true);
    try std.testing.expect(!t.shouldRefuse("docs/adr/0366-b.md"));
    t.noteOutput("read_file", input, "read_file: docs/adr/0365-a.md does not exist", true);
    t.noteOutput("read_file", input, "read_file: docs/adr/0365-a.md does not exist", true);
    t.noteOutput("read_file", input, "read_file: docs/adr/0365-a.md does not exist", true);
    try std.testing.expect(t.shouldRefuse("docs/adr/0368-d.md"));
}
