//! Resolve the newest published beta for the newest numeric release branch.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const branches_url = "https://api.github.com/repos/justrach/codegraff/git/matching-refs/heads/release/v";
pub const releases_url = "https://api.github.com/repos/justrach/codegraff/releases?per_page=100";

pub fn releaseCount(body: []const u8, gpa: Allocator) ?usize {
    var parsed = std.json.parseFromSlice(Value, gpa, body, .{}) catch return null;
    defer parsed.deinit();
    return if (parsed.value == .array) parsed.value.array.items.len else null;
}

const Version = struct {
    parts: [4]u32,
    fn order(a: Version, b: Version) std.math.Order {
        for (a.parts, b.parts) |x, y| if (x != y) return std.math.order(x, y);
        return .eq;
    }
};

fn version(s: []const u8) ?Version {
    var parts: [4]u32 = .{ 0, 0, 0, 0 };
    var it = std.mem.splitScalar(u8, s, '.');
    var n: usize = 0;
    while (it.next()) |p| {
        if (n == 4 or p.len == 0) return null;
        parts[n] = std.fmt.parseInt(u32, p, 10) catch return null;
        n += 1;
    }
    if (n < 3) return null;
    return .{ .parts = parts };
}

pub fn newestBranch(body: []const u8, gpa: Allocator) ?[]u8 {
    var parsed = std.json.parseFromSlice(Value, gpa, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .array) return null;
    var best: ?Version = null;
    var name: ?[]const u8 = null;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const ref = item.object.get("ref") orelse continue;
        if (ref != .string) continue;
        const prefix = "refs/heads/release/v";
        if (!std.mem.startsWith(u8, ref.string, prefix)) continue;
        const suffix = ref.string[prefix.len..];
        const v = version(suffix) orelse continue;
        if (best == null or v.order(best.?) == .gt) {
            best = v;
            name = suffix;
        }
    }
    return gpa.dupe(u8, name orelse return null) catch null;
}

fn betaRun(tag: []const u8, branch: []const u8) ?[2]u64 {
    var prefix_buf: [96]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "v{s}-beta.", .{branch}) catch return null;
    const actual = if (std.mem.startsWith(u8, tag, "v")) tag else tag;
    const expected = if (std.mem.startsWith(u8, tag, "v")) prefix else prefix[1..];
    if (!std.mem.startsWith(u8, actual, expected)) return null;
    var it = std.mem.splitScalar(u8, actual[expected.len..], '.');
    const run = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    const attempt = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    if (it.next() != null or run == 0 or attempt == 0) return null;
    return .{ run, attempt };
}

/// Numeric ordering for two beta tags, including run and attempt. Returns
/// null for any non-beta version so stable ordering stays separate.
pub fn compareTags(a_raw: []const u8, b_raw: []const u8) ?std.math.Order {
    const a = if (std.mem.startsWith(u8, a_raw, "v")) a_raw[1..] else a_raw;
    const b = if (std.mem.startsWith(u8, b_raw, "v")) b_raw[1..] else b_raw;
    const a_sep = std.mem.indexOf(u8, a, "-beta.") orelse return null;
    const b_sep = std.mem.indexOf(u8, b, "-beta.") orelse return null;
    const av = version(a[0..a_sep]) orelse return null;
    const bv = version(b[0..b_sep]) orelse return null;
    const ar = betaRun(a_raw, a[0..a_sep]) orelse return null;
    const br = betaRun(b_raw, b[0..b_sep]) orelse return null;
    const base = av.order(bv);
    if (base != .eq) return base;
    if (ar[0] != br[0]) return std.math.order(ar[0], br[0]);
    return std.math.order(ar[1], br[1]);
}

pub fn newestRelease(body: []const u8, branch: []const u8, gpa: Allocator) ?[]u8 {
    var parsed = std.json.parseFromSlice(Value, gpa, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .array) return null;
    var best: ?[2]u64 = null;
    var name: ?[]const u8 = null;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const tag = item.object.get("tag_name") orelse continue;
        const draft = item.object.get("draft") orelse continue;
        const pre = item.object.get("prerelease") orelse continue;
        if (tag != .string or draft != .bool or pre != .bool or draft.bool or !pre.bool) continue;
        const run = betaRun(tag.string, branch) orelse continue;
        if (best == null or run[0] > best.?[0] or (run[0] == best.?[0] and run[1] > best.?[1])) {
            best = run;
            name = tag.string;
        }
    }
    return gpa.dupe(u8, name orelse return null) catch null;
}

test "numeric branch and published prerelease selection" {
    const gpa = std.testing.allocator;
    const branches =
        \\[{"ref":"refs/heads/release/v0.0.302.9"},{"ref":"refs/heads/release/v0.0.302.10"},{"ref":"refs/heads/release/v0.0.303-beta"}]
    ;
    const branch = newestBranch(branches, gpa).?;
    defer gpa.free(branch);
    try std.testing.expectEqualStrings("0.0.302.10", branch);
    const releases =
        \\[{"tag_name":"v0.0.302.9-beta.999.1","draft":false,"prerelease":true},{"tag_name":"v0.0.302.10-beta.26.1","draft":false,"prerelease":true},{"tag_name":"v0.0.302.10-beta.26.2","draft":true,"prerelease":true},{"tag_name":"v0.0.302.10-beta.27.1","draft":false,"prerelease":true}]
    ;
    const tag = newestRelease(releases, branch, gpa).?;
    defer gpa.free(tag);
    try std.testing.expectEqualStrings("v0.0.302.10-beta.27.1", tag);
    try std.testing.expect(newestRelease(releases, "0.0.303", gpa) == null);
    try std.testing.expectEqual(std.math.Order.gt, compareTags("0.0.302.10-beta.27.2", "v0.0.302.10-beta.27.1").?);
}
