//! Impl half of TerminalModes: the LIVE enable/restore constants (run.zig
//! enable_seq, restore.zig seq) are parsed into mode ops and folded with a
//! mirror of the model; the fixture pins both the byte strings and the
//! folded outcomes, so drift in either the constants or the model trips.

const std = @import("std");
const Value = std.json.Value;
const run = @import("run.zig");
const restore = @import("restore.zig");

const fixtures_json = @embedFile("spec_terminal_modes");

const default_on = [_]u32{ 7, 25 };

const Fold = struct {
    // mode -> final op (true = h). Tiny domains; linear scan is fine.
    modes: [16]struct { n: u32, v: bool } = undefined,
    len: usize = 0,
    depth: u32 = 0,

    fn setFinal(self: *@This(), n: u32, v: bool) void {
        for (self.modes[0..self.len]) |*m| if (m.n == n) {
            m.v = v;
            return;
        };
        self.modes[self.len] = .{ .n = n, .v = v };
        self.len += 1;
    }

    fn isDefaultOn(n: u32) bool {
        for (default_on) |d| if (d == n) return true;
        return false;
    }

    fn deviations(self: *const @This(), out: []u32) []u32 {
        var k: usize = 0;
        for (self.modes[0..self.len]) |m| if (m.v != isDefaultOn(m.n)) {
            out[k] = m.n;
            k += 1;
        };
        std.mem.sort(u32, out[0..k], {}, std.sort.asc(u32));
        return out[0..k];
    }
};

/// Scan a byte stream for DEC private-mode ops and kitty push/pop, in order.
fn fold(stream: []const u8) Fold {
    var f: Fold = .{};
    var i: usize = 0;
    while (i + 2 < stream.len) : (i += 1) {
        if (stream[i] != 0x1b or stream[i + 1] != '[') continue;
        var j = i + 2;
        if (stream[j] == '?') {
            j += 1;
            while (j < stream.len and ((stream[j] >= '0' and stream[j] <= '9') or stream[j] == ';')) j += 1;
            if (j < stream.len and (stream[j] == 'h' or stream[j] == 'l')) {
                // Apply the final h/l to every ';'-separated parameter.
                const v = stream[j] == 'h';
                var k = i + 3;
                var m: u32 = 0;
                while (k <= j) : (k += 1) {
                    const c = stream[k];
                    if (c >= '0' and c <= '9') {
                        m = m * 10 + (c - '0');
                    } else {
                        f.setFinal(m, v);
                        m = 0;
                    }
                }
                i = j;
            }
        } else if (stream[j] == '>' or stream[j] == '<') {
            const open = stream[j];
            j += 1;
            while (j < stream.len and ((stream[j] >= '0' and stream[j] <= '9') or stream[j] == ';')) j += 1;
            if (j < stream.len and stream[j] == 'u') {
                if (open == '>') f.depth += 1 else f.depth -|= 1;
                i = j;
            }
        }
    }
    return f;
}

test "spec/terminal_modes: the live constants equal the fixture's byte strings" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(Value, gpa, fixtures_json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(parsed.value.object.get("graff_enable").?.string, run.enable_seq);
    try std.testing.expectEqualStrings(parsed.value.object.get("graff_restore").?.string, restore.seq);
}

test "spec/terminal_modes: every fixture stream folds to its recorded outcome" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(Value, gpa, fixtures_json, .{});
    defer parsed.deinit();
    const cells = parsed.value.object.get("cells").?.array.items;
    try std.testing.expectEqual(@as(usize, 14), cells.len);
    for (cells) |cell_v| {
        const cell = cell_v.object;
        const name = cell.get("name").?.string;
        var f = fold(cell.get("stream").?.string);
        var buf: [16]u32 = undefined;
        const devs = f.deviations(&buf);
        const want_devs = cell.get("deviations").?.array.items;
        const want_depth: u32 = @intCast(cell.get("depth").?.integer);
        const want_balanced = cell.get("balanced").?.bool;
        const balanced = devs.len == 0 and f.depth == 0;
        var match = devs.len == want_devs.len and f.depth == want_depth and balanced == want_balanced;
        if (match) for (devs, want_devs) |g, w| {
            if (g != @as(u32, @intCast(w.integer))) match = false;
        };
        if (!match) {
            std.debug.print("\ncounterexample {s}: depth {}/{} devs {any}\n", .{ name, want_depth, f.depth, devs });
            return error.CatalogMismatch;
        }
    }
}

test "spec/terminal_modes: graff's lifecycle balances and its restore leaves the alt-screen last" {
    var enable_then_restore = std.ArrayList(u8).empty;
    defer enable_then_restore.deinit(std.testing.allocator);
    try enable_then_restore.appendSlice(std.testing.allocator, run.enable_seq);
    try enable_then_restore.appendSlice(std.testing.allocator, restore.seq);
    var f = fold(enable_then_restore.items);
    var buf: [16]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), f.deviations(&buf).len);
    try std.testing.expectEqual(@as(u32, 0), f.depth);
    try std.testing.expect(std.mem.endsWith(u8, restore.seq, "\x1b[?1049l"));
}
