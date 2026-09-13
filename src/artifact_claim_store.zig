const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const claims = @import("artifact_claim.zig");
const Ledger = claims.Ledger;
const kindFrom = claims.kindFrom;
const max_claims = 32;

pub fn persistJson(arena: Allocator, ledger: *const Ledger) ![]const u8 {
    var aw: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginArray();
    for (ledger.slice()) |c| {
        try s.beginObject();
        try s.objectField("kind");
        try s.write(@tagName(c.kind));
        try s.objectField("key");
        try s.write(c.key);
        try s.objectField("session");
        try s.write(c.owner.session);
        try s.objectField("pid");
        try s.write(c.owner.pid);
        try s.objectField("start_id");
        try s.write(c.owner.start_id);
        try s.endObject();
    }
    try s.endArray();
    return aw.writer.buffered();
}

pub fn loadJson(arena: Allocator, ledger: *Ledger, text: []const u8) !void {
    ledger.len = 0;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return error.InvalidClaimLedger;
    if (parsed != .array) return error.InvalidClaimLedger;
    for (parsed.array.items) |item| {
        if (item != .object) return error.InvalidClaimLedger;
        const kind_s = if (item.object.get("kind")) |v| (if (v == .string) v.string else return error.InvalidClaimLedger) else return error.InvalidClaimLedger;
        const kind = kindFrom(kind_s) orelse return error.InvalidClaimLedger;
        const key = if (item.object.get("key")) |v| (if (v == .string) v.string else return error.InvalidClaimLedger) else return error.InvalidClaimLedger;
        const session = if (item.object.get("session")) |v| (if (v == .string) v.string else return error.InvalidClaimLedger) else return error.InvalidClaimLedger;
        const pid: i32 = if (item.object.get("pid")) |v| (if (v == .integer and v.integer >= 0 and v.integer <= std.math.maxInt(i32)) @intCast(v.integer) else return error.InvalidClaimLedger) else 0;
        const start_id: u64 = if (item.object.get("start_id")) |v| (if (v == .integer and v.integer >= 0) @intCast(v.integer) else return error.InvalidClaimLedger) else 0;
        if (ledger.len >= max_claims) return error.InvalidClaimLedger;
        for (ledger.slice()) |c| {
            if (c.kind == kind and std.mem.eql(u8, c.key, key)) return error.InvalidClaimLedger;
        }
        ledger.items[ledger.len] = .{
            .kind = kind,
            .key = try arena.dupe(u8, key),
            .owner = .{ .session = try arena.dupe(u8, session), .pid = pid, .start_id = start_id },
        };
        ledger.len += 1;
    }
}
