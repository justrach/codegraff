//! ADR 0319 through the real save/load path: an unversioned save still loads,
//! a fresh save carries `format_version` and loads back, and a save from a
//! newer format is refused without touching the live conversation.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const provider_mod = @import("provider.zig");
const session = @import("session.zig");
const session_version = @import("session_version.zig");
const writer = @import("session_writer.zig");
const transcript = @import("session_transcript.zig");

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    client: std.http.Client,
    keys: provider_mod.Keys,
    home_buf: [std.fs.max_path_bytes]u8 = undefined,

    fn init(self: *Fixture) !void {
        writer.resetForTest();
        transcript.resetForTest();
        self.arena_state = .init(std.testing.allocator);
        self.tmp = std.testing.tmpDir(.{});
        self.client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
        self.keys = .{ .values = @splat(null) };
        for (provider_mod.provider_specs, &self.keys.values, &self.keys.sources) |spec, *value, *source| {
            if (!std.mem.eql(u8, spec.id, "anthropic")) continue;
            value.* = "launch-key";
            source.* = .environment;
        }
        try self.tmp.dir.createDirPath(std.testing.io, ".graff/sessions");
    }

    fn deinit(self: *Fixture) void {
        session.flushSaves();
        self.client.deinit();
        self.tmp.cleanup();
        self.arena_state.deinit();
        transcript.resetForTest();
        writer.resetForTest();
    }

    fn agent(self: *Fixture, first_message: []const u8) !Agent {
        const arena = self.arena_state.allocator();
        const json = try std.fmt.allocPrint(arena, "[{{\"role\":\"user\",\"content\":\"{s}\"}}]", .{first_message});
        return .{
            .gpa = std.testing.allocator,
            .arena = arena,
            .io = std.testing.io,
            .client = &self.client,
            .provider = try self.keys.providerById("anthropic", "sonnet"),
            .messages = (try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{})).array,
            .sub = false,
            .label = "root",
            .out = null,
            .home = self.home_buf[0..try self.tmp.dir.realPath(std.testing.io, &self.home_buf)],
            .stored_keys_loaded = true,
        };
    }

    fn put(self: *Fixture, name: []const u8, data: []const u8) !void {
        const path = try std.fmt.allocPrint(self.arena_state.allocator(), ".graff/sessions/{s}.session.json", .{name});
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
    }
};

test "session format version: legacy unversioned save loads through loadSession" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var root = try fx.agent("live");
    try fx.put("legacy-0319",
        \\{"provider":"anthropic","model":"sonnet","title":"Old chat","messages":[{"role":"user","content":"from before versioning"},{"role":"assistant","content":"ok"}]}
    );
    try session.loadSession(&root, &fx.keys, fx.arena_state.allocator(), "legacy-0319");
    try std.testing.expectEqual(@as(usize, 2), root.messages.items.len);
    try std.testing.expectEqualStrings("Old chat", root.session_title.?);
}

test "session format version: a fresh save carries the current version and round-trips" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const arena = fx.arena_state.allocator();
    var root = try fx.agent("round trip 0319");
    try session.saveSessionTo(&root, arena, fx.tmp.dir, "current-0319");
    session.flushSaves();
    const bytes = try fx.tmp.dir.readFileAlloc(std.testing.io, ".graff/sessions/current-0319.session.json", arena, .unlimited);
    const prefix = std.fmt.comptimePrint("{{\"{s}\":{d},", .{ session_version.field, session_version.current });
    try std.testing.expect(std.mem.startsWith(u8, bytes, prefix)); // first, ahead of `messages`
    try std.testing.expectEqualStrings("round trip 0319", session.sessionMetaFromBytes(arena, bytes).title.?);
    var other = try fx.agent("something else");
    try session.loadSession(&other, &fx.keys, arena, "current-0319");
    try std.testing.expectEqual(@as(usize, 1), other.messages.items.len);
    try std.testing.expectEqualStrings("round trip 0319", other.messages.items[0].object.get("content").?.string);
}

test "session format version: a newer format is refused and leaves the live session alone" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var root = try fx.agent("keep me");
    try fx.put("future-0319",
        \\{"format_version":99,"provider":"anthropic","model":"sonnet","messages":[{"role":"user","content":"from the future"},{"role":"assistant","content":"?"}]}
    );
    try std.testing.expectError(error.SessionFormatTooNew, session.loadSession(&root, &fx.keys, fx.arena_state.allocator(), "future-0319"));
    try std.testing.expectEqual(@as(usize, 1), root.messages.items.len);
    try std.testing.expectEqualStrings("keep me", root.messages.items[0].object.get("content").?.string);
}
