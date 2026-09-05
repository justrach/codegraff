//! Bounded lexical guard, not an answer-completeness or relevance classifier.
//! Only short plain-prose lines/sentences qualify. Code, data, indentation,
//! digits, long units and fenced blocks break the evidence chain.
const std = @import("std");

pub const Detector = struct {
    unit: [256]u8 = undefined,
    len: usize = 0,
    overflow: bool = false,
    fence: u8 = 0,
    fence_len: usize = 0,
    blocked_line: bool = false,
    hashes: [4]u64 = @splat(0),
    streak: [4]usize = @splat(0),
    count: usize = 0,
    repeated_bytes: [4]usize = @splat(0),
    stopped: bool = false,

    /// Returns the accepted prefix length; stopped latches until reset.
    pub fn feed(self: *Detector, text: []const u8) usize {
        if (self.stopped) return 0;
        for (text, 0..) |c, i| {
            if (c == '\n' or c == '.' or c == '!' or c == '?') {
                self.endUnit(c == '\n');
                if (self.stopped) return i + 1;
            } else if (self.len < self.unit.len) {
                self.unit[self.len] = c;
                self.len += 1;
            } else self.overflow = true;
        }
        return text.len;
    }

    pub fn finish(self: *Detector) void {
        if (!self.stopped) self.endUnit(true);
    }

    fn resetEvidence(self: *Detector) void {
        self.count = 0;
        self.streak = @splat(0);
        self.repeated_bytes = @splat(0);
    }

    fn endUnit(self: *Detector, newline: bool) void {
        const raw = self.unit[0..self.len];
        defer {
            self.len = 0;
            self.overflow = false;
            if (newline) self.blocked_line = false;
        }
        const text = std.mem.trim(u8, raw, " \t\r");
        if (newline and (std.mem.startsWith(u8, text, "```") or std.mem.startsWith(u8, text, "~~~"))) {
            var n: usize = 0;
            while (n < text.len and text[n] == text[0]) : (n += 1) {}
            if (self.fence == 0) {
                self.fence = text[0];
                self.fence_len = n;
            } else if (self.fence == text[0] and n >= self.fence_len and std.mem.trim(u8, text[n..], " \t\r").len == 0) {
                self.fence = 0;
            }
            self.resetEvidence();
            return;
        }
        // A newline after sentence punctuation is empty, not novel evidence.
        if (text.len == 0 and !self.overflow) return;
        if (self.fence != 0 or self.blocked_line or self.overflow or !prose(raw, text)) {
            self.blocked_line = true;
            self.resetEvidence();
            return;
        }
        const hash = std.hash.Wyhash.hash(0, text);
        for (0..4) |p| {
            const period = p + 1;
            if (self.count >= period and self.hashes[(self.count - period) % 4] == hash) {
                self.streak[p] += 1;
                self.repeated_bytes[p] += text.len;
            } else {
                self.streak[p] = 0;
                self.repeated_bytes[p] = 0;
            }
            if (self.streak[p] >= 12 and self.repeated_bytes[p] >= 192) self.stopped = true;
        }
        self.hashes[self.count % 4] = hash;
        self.count += 1;
    }
};

fn prose(raw: []const u8, text: []const u8) bool {
    if (text.len < 6 or text.len > 160) return false;
    if (std.mem.startsWith(u8, raw, "    ") or std.mem.startsWith(u8, raw, "\t")) return false;
    var words: usize = 0;
    var in_word = false;
    for (text) |c| {
        if (std.ascii.isAlphabetic(c)) {
            if (!in_word) words += 1;
            in_word = true;
        } else {
            if (c != ' ' and c != '\r' and c != '\'' and c != ',' and c != '-') return false;
            in_word = false;
        }
    }
    return words >= 2 and words <= 24;
}

fn repeat(comptime text: []const u8, comptime n: usize) *const [text.len * n:0]u8 {
    @setEvalBranchQuota(1000000);
    const result = comptime blk: {
        var bytes: [text.len * n:0]u8 = undefined;
        for (0..n) |i| @memcpy(bytes[i * text.len ..][0..text.len], text);
        bytes[bytes.len] = 0;
        break :blk bytes;
    };
    return &result;
}

test "model loop bounds repeated prose independently of chunk boundaries" {
    const input = "The useful answer is preserved.\n" ++ repeat("I will wait for your reply.\n", 1000);
    var whole: Detector = .{};
    const accepted = whole.feed(input);
    try std.testing.expect(whole.stopped);
    try std.testing.expect(accepted < 600);
    var split: Detector = .{};
    var n: usize = 0;
    for (input) |c| {
        n += split.feed(&.{c});
        if (split.stopped) break;
    }
    try std.testing.expectEqual(accepted, n);
    try std.testing.expectEqual(@as(usize, 0), split.feed("more"));
}

test "model loop catches alternating sentences without newlines" {
    var d: Detector = .{};
    _ = d.feed(repeat("I will wait for your reply. Please choose an option. ", 100));
    try std.testing.expect(d.stopped);
}

test "model loop permits fenced code tables numeric data indentation and long lines" {
    for ([_][]const u8{
        "```text\n" ++ repeat("I will wait for your reply.\n", 100) ++ "```\n",
        "~~~\n" ++ repeat("I will wait for your reply\n", 100) ++ "~~~\n",
        "````\n```\n~~~\n" ++ repeat("I will wait for your reply.\n", 100) ++ "````\n",
        repeat("    repeated data goes here\n", 100),
        repeat("| repeated data | repeated data |\n", 100),
        repeat("count is 1234\n", 100),
        repeat("const value = repeat();\n", 100),
        repeat("x", 500) ++ "\n",
    }) |text| {
        var d: Detector = .{};
        try std.testing.expectEqual(text.len, d.feed(text));
        d.finish();
        try std.testing.expect(!d.stopped);
    }
}

test "model loop novel prose breaks evidence and short repeats are allowed" {
    var d: Detector = .{};
    _ = d.feed(repeat("I will wait for your reply.\n", 8));
    _ = d.feed("A genuinely different conclusion follows here.\n");
    _ = d.feed(repeat("I will wait for your reply.\n", 8));
    try std.testing.expect(!d.stopped);
}

test "model loop oversized input never grows detector state" {
    var d: Detector = .{};
    _ = d.feed(repeat("x", 100000));
    try std.testing.expect(d.overflow);
    try std.testing.expectEqual(@as(usize, 256), d.len);
    _ = d.feed(repeat("\nI will wait for your reply.\n", 30));
    try std.testing.expect(d.stopped);
}
