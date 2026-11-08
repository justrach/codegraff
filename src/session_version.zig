//! The on-disk session format version (ADR 0319). session.zig writes
//! `format_version` into every `<name>.session.json`; every reader runs the
//! parsed object through `upgrade` before it looks at any other field.
//!
//! - absent field: a legacy save, written before versioning. Its shape is the
//!   v1 shape, so it is read as version 1.
//! - 1 .. current: an older or current save. Each step in `steps` lifts the
//!   object one version, in place, until it is `current`.
//! - above current: written by a newer graff. Refused with
//!   `error.SessionFormatTooNew`, never read as if it were this version.
//!
//! Adding a version: bump `current`, append a `fn (Allocator, *ObjectMap)
//! !void` to `steps` that turns a v(N) object into v(N+1), and add a test that
//! a v(N) fixture loads. The writer always writes `current`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ObjectMap = std.json.ObjectMap;

/// The JSON key. First in the object, before the large `messages` array.
pub const field = "format_version";

/// The version this build writes and the newest it can read.
pub const current: u32 = 1;

/// What an unversioned (pre-0319) save is read as.
pub const legacy: u32 = 1;

pub const Error = error{
    /// The save names a version this build does not know. Update graff.
    SessionFormatTooNew,
    /// `format_version` is present but not a positive integer.
    BadSession,
};

const Step = *const fn (Allocator, *ObjectMap) (Error || Allocator.Error)!void;

/// `steps[i]` migrates version `i + 1` to `i + 2`. Empty while `current` is 1:
/// v1 is both the legacy shape and the current one.
const steps = [_]Step{};

comptime {
    if (steps.len != current - 1) @compileError("session_version: one migration step per version below current");
}

/// The text a surface shows when a save is refused for being too new.
pub const too_new_text = "Saved session was written by a newer graff (session format newer than v" ++ std.fmt.comptimePrint("{d}", .{current}) ++ "); update graff to load it";

/// The version the object declares. Missing means legacy.
pub fn of(obj: ObjectMap) Error!u32 {
    const v = obj.get(field) orelse return legacy;
    if (v != .integer or v.integer < 1) return error.BadSession;
    if (v.integer > current) return error.SessionFormatTooNew;
    return @intCast(v.integer);
}

/// Validate `obj`'s version and migrate it in place to `current`. Refuses a
/// newer version before anything has been read or changed.
pub fn upgrade(arena: Allocator, obj: *ObjectMap) (Error || Allocator.Error)!void {
    const version = try of(obj.*);
    for (steps[version - 1 ..]) |step| try step(arena, obj);
    try obj.put(arena, field, .{ .integer = current });
}

/// Write the field into an open object. session.zig calls it first.
pub fn write(s: *std.json.Stringify) !void {
    try s.objectField(field);
    try s.write(current);
}

fn parse(arena: Allocator, text: []const u8) !ObjectMap {
    return (try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{})).object;
}

test "session format version: legacy save without the field reads as v1" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var obj = try parse(a, "{\"provider\":\"anthropic\",\"model\":\"sonnet\",\"messages\":[]}");
    try std.testing.expectEqual(legacy, try of(obj));
    try upgrade(a, &obj);
    try std.testing.expectEqual(@as(i64, current), obj.get(field).?.integer);
    try std.testing.expectEqualStrings("anthropic", obj.get("provider").?.string);
}

test "session format version: current and future versions" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    var now = try parse(a, "{\"format_version\":1,\"messages\":[]}");
    try upgrade(a, &now);
    try std.testing.expectEqual(current, try of(now));
    var future = try parse(a, "{\"format_version\":99,\"messages\":[]}");
    try std.testing.expectError(error.SessionFormatTooNew, upgrade(a, &future));
    try std.testing.expectEqual(@as(i64, 99), future.get(field).?.integer); // untouched
    try std.testing.expectError(error.BadSession, of(try parse(a, "{\"format_version\":0}")));
    try std.testing.expectError(error.BadSession, of(try parse(a, "{\"format_version\":\"1\"}")));
    try std.testing.expect(std.mem.indexOf(u8, too_new_text, "newer graff") != null);
}
