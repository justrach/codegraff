//! Provenance for canonical /responses/compact windows (#804).
//! Keep every returned item until a NEW in-stream blob supersedes the window.
//! Persist only a fingerprint, never another copy of the opaque payload.
const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub fn latestBlob(items: []const Value) ?usize {
    var latest: ?usize = null;
    for (items, 0..) |item, i| {
        if (item != .object) continue;
        const kind = item.object.get("type") orelse continue;
        if (kind != .string) continue;
        if (std.mem.eql(u8, kind.string, "compaction") or std.mem.eql(u8, kind.string, "compaction_summary")) latest = i;
    }
    return latest;
}

fn fingerprint(a: Allocator, item: Value) ![32]u8 {
    const bytes = try std.json.Stringify.valueAlloc(a, item, .{});
    defer a.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

pub const State = struct {
    canonical_blob: ?[32]u8 = null,

    pub fn canonical(a: Allocator, items: []const Value) !State {
        const k = latestBlob(items) orelse return error.MissingCompactionItem;
        return .{ .canonical_blob = try fingerprint(a, items[k]) };
    }

    pub fn protects(self: State, a: Allocator, blob: Value) bool {
        const saved = self.canonical_blob orelse return false;
        // Allocation failure must never turn a protected window into a cut.
        const current = fingerprint(a, blob) catch return true;
        return std.mem.eql(u8, &saved, &current);
    }

    pub fn write(self: State, s: *std.json.Stringify) !void {
        try s.objectField("canonical_compaction");
        if (self.canonical_blob) |digest| {
            const hex = std.fmt.bytesToHex(digest, .lower);
            try s.write(@as([]const u8, &hex));
        } else try s.write(null);
    }

    pub fn restore(a: Allocator, obj: std.json.ObjectMap, items: []const Value) !State {
        if (obj.get("canonical_compaction")) |value| {
            if (value == .null) return .{};
            if (value == .string and value.string.len == 64) {
                var digest: [32]u8 = undefined;
                if (std.fmt.hexToBytes(&digest, value.string)) |_| {
                    return .{ .canonical_blob = digest };
                } else |_| {}
            }
        }
        // Older saves lack provenance. Keep their existing window conservatively;
        // a newly returned automatic blob can still supersede it normally.
        if (latestBlob(items) == null) return .{};
        return canonical(a, items);
    }
};
