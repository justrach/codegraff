//! What the user allows, and what agents did. Stopped refuses everything;
//! input (clicks, keys, launching) is refused until the user turns it on;
//! the whole screen (the real pointer and keyboard, pictures of the display)
//! is refused until they turn that on too, so by default agents stay inside
//! one app; nanocua's own windows are never acted on (an agent can't press
//! its own Resume). Input belongs to one agent's work: the connection that
//! first acts once it's on holds it, nobody else may act, and it turns off
//! when that connection closes (ADR 0354). Every call is logged: what, with
//! what, and how it went.
const std = @import("std");
const tools = @import("tools.zig");

pub const input_off = "Input is off in nanocua: you may look (list_apps, get_ui_tree, screenshot) but not act. Ask the user to turn on \"Allow input\" in nanocua's window; it lasts until your session's connection to nanocua ends.";
pub const input_held = "Input in nanocua belongs to another agent's work until that work's connection ends: you may look (list_apps, get_ui_tree, screenshot) but not act. Tell the user once; to give input to your work instead, they turn \"Allow input\" off and on again in nanocua's window.";

pub const Policy = struct {
    /// The kill switch: nothing runs until the user resumes.
    stopped: bool = false,
    /// Clicks, keys, scrolling, launching apps: a person turned it on.
    allow_input: bool = false,
    /// The connection whose work input belongs to: the first whose acting
    /// call got through once input was on. Null while nobody has acted yet.
    input_holder: ?u64 = null,
    /// The real pointer and keyboard, and pictures of the whole display.
    allow_whole_screen: bool = false,

    /// Why `tool` may not run now for connection `conn`, or null if it may.
    /// `whole_screen`: the call asked for more than one app.
    pub fn denial(p: Policy, tool: tools.Tool, whole_screen: bool, conn: u64) ?[]const u8 {
        if (p.stopped) return "nanocua is stopped: the user pressed Stop. Wait for them to resume it.";
        if (tool.kind() == .act) {
            if (!p.allow_input) return input_off;
            if (p.input_holder) |holder| if (holder != conn) return input_held;
        }
        if (whole_screen and !p.allow_whole_screen and tool != .list_apps and tool != .get_ui_tree)
            return "The whole screen is off in nanocua: work inside one app (leave out whole_screen). If that can't work, ask the user to turn on \"Allow whole screen\".";
        return null;
    }

    /// `conn`'s call to `tool` got through: if it acts and nobody holds
    /// input yet, its work does from now on.
    pub fn admit(p: *Policy, tool: tools.Tool, conn: u64) void {
        if (tool.kind() == .act and p.allow_input and p.input_holder == null) p.input_holder = conn;
    }

    /// The switch. Off ends whoever held input; on opens it for the next work
    /// that acts. Turning on what's already on changes nothing.
    pub fn setInput(p: *Policy, on: bool) void {
        if (on and p.allow_input) return;
        p.allow_input = on;
        p.input_holder = null;
    }

    /// Connection `conn` closed. If its work held input, input ends with it
    /// and stays off until a person turns it on again. True if it did.
    pub fn closed(p: *Policy, conn: u64) bool {
        const holder = p.input_holder orelse return false;
        if (holder != conn) return false;
        p.setInput(false);
        return true;
    }

    /// Who may act, for the backend's queue: 0 when nobody (connections
    /// start at 1), including while input is on but nobody has acted.
    pub fn actor(p: Policy) u64 {
        if (!p.allow_input) return 0;
        return p.input_holder orelse 0;
    }
};

pub const Status = enum { running, ok, failed, denied };

pub const Entry = struct {
    seq: u64,
    tool: tools.Tool,
    status: Status = .running,
    /// When it started, by the hub's clock; how long it took.
    at: f64,
    ms: f32 = 0,
    summary_buf: [96]u8 = undefined,
    summary_len: u8 = 0,
    detail_buf: [120]u8 = undefined,
    detail_len: u8 = 0,

    pub fn summary(e: *const Entry) []const u8 {
        return e.summary_buf[0..e.summary_len];
    }

    pub fn detail(e: *const Entry) []const u8 {
        return e.detail_buf[0..e.detail_len];
    }
};

/// The last `capacity` calls, newest last.
pub const Log = struct {
    pub const capacity = 200;
    entries: [capacity]Entry = undefined,
    len: usize = 0,
    /// Where the oldest entry is once the ring is full.
    head: usize = 0,
    next_seq: u64 = 1,
    /// Counts since launch.
    calls: u64 = 0,
    denied: u64 = 0,

    pub fn add(l: *Log, tool: tools.Tool, summary: []const u8, at: f64) u64 {
        const e: Entry = .{ .seq = l.next_seq, .tool = tool, .at = at };
        l.next_seq += 1;
        l.calls += 1;
        const slot = if (l.len < capacity) blk: {
            l.len += 1;
            break :blk l.len - 1;
        } else blk: {
            const s = l.head;
            l.head = (l.head + 1) % capacity;
            break :blk s;
        };
        l.entries[slot] = e;
        const n = clip(&l.entries[slot].summary_buf, summary);
        l.entries[slot].summary_len = @intCast(n);
        return e.seq;
    }

    pub fn finish(l: *Log, seq: u64, status: Status, detail: []const u8, now: f64) void {
        const e = l.find(seq) orelse return;
        e.status = status;
        if (status == .denied) l.denied += 1;
        e.ms = @floatCast(@max(0, (now - e.at) * 1000));
        e.detail_len = @intCast(clip(&e.detail_buf, detail));
    }

    pub fn find(l: *Log, seq: u64) ?*Entry {
        for (l.entries[0..l.len]) |*e| if (e.seq == seq) return e;
        return null;
    }

    /// The `i`th newest entry (0 is the newest).
    pub fn newest(l: *Log, i: usize) ?*const Entry {
        if (i >= l.len) return null;
        const oldest_first = l.len - 1 - i;
        return &l.entries[(l.head + oldest_first) % l.len];
    }

    pub fn clear(l: *Log) void {
        l.len = 0;
        l.head = 0;
    }
};

/// Copies `s` into `buf`, cut at a character's start with "…" when long,
/// on one line.
fn clip(buf: []u8, s: []const u8) usize {
    const ell = "…";
    var n = s.len;
    var cut = false;
    if (n > buf.len) {
        n = buf.len - ell.len;
        while (n > 0 and (s[n] & 0xc0) == 0x80) n -= 1;
        cut = true;
    }
    for (s[0..n], 0..) |ch, i| buf[i] = if (ch == '\n' or ch == '\r' or ch == '\t') ' ' else ch;
    if (cut) {
        @memcpy(buf[n..][0..ell.len], ell);
        n += ell.len;
    }
    return n;
}

test "stopped refuses everything; input waits for the user" {
    var p: Policy = .{};
    try std.testing.expect(p.denial(.get_ui_tree, false, 1) == null);
    try std.testing.expect(p.denial(.click, false, 1) != null);
    p.allow_input = true;
    try std.testing.expect(p.denial(.click, false, 1) == null);
    p.stopped = true;
    try std.testing.expect(p.denial(.screenshot, false, 1) != null);
    try std.testing.expect(p.denial(.click, false, 1) != null);
}

test "the whole screen waits for the user, one app doesn't" {
    var p: Policy = .{ .allow_input = true };
    try std.testing.expect(p.denial(.screenshot, false, 1) == null);
    try std.testing.expect(p.denial(.click, false, 1) == null);
    try std.testing.expect(p.denial(.screenshot, true, 1) != null);
    try std.testing.expect(p.denial(.click, true, 1) != null);
    try std.testing.expect(p.denial(.press_key, true, 1) != null);
    try std.testing.expect(p.denial(.get_ui_tree, true, 1) == null); // reading an app is one app anyway
    p.allow_whole_screen = true;
    try std.testing.expect(p.denial(.screenshot, true, 1) == null);
    try std.testing.expect(p.denial(.click, true, 1) == null);
    p.allow_input = false;
    try std.testing.expect(p.denial(.click, true, 1) != null); // input stays its own switch
}

test "input belongs to the first connection that acts, and ends with it (#1931)" {
    var p: Policy = .{};
    // Off: nobody acts, and nobody holds it by trying.
    p.admit(.click, 2);
    try std.testing.expect(p.input_holder == null and p.actor() == 0);

    // On, nobody holding: any connection may act; looking claims nothing.
    p.setInput(true);
    try std.testing.expect(p.denial(.click, false, 3) == null);
    p.admit(.get_ui_tree, 3);
    try std.testing.expect(p.input_holder == null and p.actor() == 0);
    p.admit(.click, 2);
    try std.testing.expectEqual(@as(u64, 2), p.actor());

    // Held: only its connection acts; everyone may still look.
    try std.testing.expect(p.denial(.click, false, 2) == null);
    try std.testing.expectEqualStrings(input_held, p.denial(.type_text, false, 3).?);
    try std.testing.expect(p.denial(.screenshot, false, 3) == null);
    p.admit(.click, 3); // a later admit never moves it
    try std.testing.expectEqual(@as(u64, 2), p.actor());
    p.setInput(true); // already on: changes nothing
    try std.testing.expectEqual(@as(u64, 2), p.actor());

    // Another connection closing leaves it; its own closing ends input.
    try std.testing.expect(!p.closed(3));
    try std.testing.expectEqual(@as(u64, 2), p.actor());
    try std.testing.expect(p.closed(2));
    try std.testing.expect(!p.allow_input and p.input_holder == null and p.actor() == 0);
    try std.testing.expectEqualStrings(input_off, p.denial(.click, false, 4).?);

    // Off and on again: a fresh grant, for whichever work acts next.
    p.setInput(true);
    p.admit(.click, 4);
    p.setInput(false);
    try std.testing.expect(p.input_holder == null);
    p.setInput(true);
    p.admit(.scroll, 5);
    try std.testing.expectEqual(@as(u64, 5), p.actor());
    try std.testing.expect(p.denial(.click, false, 4) != null);

    // Stop refuses the holder too, and leaves the grant where it was.
    p.stopped = true;
    try std.testing.expect(p.denial(.click, false, 5) != null);
    p.stopped = false;
    try std.testing.expect(p.denial(.click, false, 5) == null);
    try std.testing.expect(p.denial(.click, false, 4) != null);
}

test "the log keeps the newest calls, clipped to a line" {
    var l: Log = .{};
    const first = l.add(.click, "a\nb", 1);
    l.finish(first, .ok, "pressed", 1.25);
    try std.testing.expectEqualStrings("a b", l.newest(0).?.summary());
    try std.testing.expectEqual(@as(f32, 250), l.newest(0).?.ms);
    const long: [200]u8 = @splat('x');
    for (0..Log.capacity + 5) |i| _ = l.add(.scroll, &long, @floatFromInt(i));
    try std.testing.expectEqual(@as(usize, Log.capacity), l.len);
    try std.testing.expect(l.find(first) == null);
    const e = l.newest(0).?;
    try std.testing.expectEqual(l.next_seq - 1, e.seq);
    try std.testing.expect(std.mem.endsWith(u8, e.summary(), "…"));
    try std.testing.expect(e.summary().len <= 96);
    try std.testing.expectEqual(l.next_seq - Log.capacity, l.newest(Log.capacity - 1).?.seq);
}
