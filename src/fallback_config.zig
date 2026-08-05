//! Per-workspace automatic cross-provider fallback allowlist. Empty is the
//! safe default: same-provider model replacement is allowed, but sending a
//! prompt to another vendor requires an explicit `/fallback allow <provider>`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const credential_store = @import("credential_store.zig");

const settings_dir = ".harness";
const settings_path = ".harness/settings.json";
const field = "fallback_providers";

pub fn contains(providers: []const []const u8, id: []const u8) bool {
    for (providers) |provider| if (std.mem.eql(u8, provider, id)) return true;
    return false;
}

pub fn load(io: Io, arena: Allocator) []const []const u8 {
    const data = Io.Dir.cwd().readFileAlloc(io, settings_path, arena, .limited(1 << 20)) catch return &.{};
    const parsed = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return &.{};
    if (parsed != .object) return &.{};
    const raw = parsed.object.get(field) orelse return &.{};
    if (raw != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (raw.array.items) |item| {
        if (item != .string or item.string.len == 0 or contains(out.items, item.string)) continue;
        out.append(arena, item.string) catch return out.items;
    }
    return out.toOwnedSlice(arena) catch out.items;
}

pub fn save(io: Io, gpa: Allocator, providers: []const []const u8) bool {
    Io.Dir.cwd().createDir(io, settings_dir, .default_dir) catch {};
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: std.json.ObjectMap = .empty;
    if (Io.Dir.cwd().readFileAlloc(io, settings_path, arena, .limited(1 << 20))) |data| {
        if (std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always })) |parsed| {
            if (parsed == .object) root = parsed.object;
        } else |_| {}
    } else |_| {}
    if (providers.len == 0) {
        _ = root.orderedRemove(field);
    } else {
        var array = std.json.Array.init(arena);
        for (providers) |provider| array.append(.{ .string = provider }) catch return false;
        root.put(arena, field, .{ .array = array }) catch return false;
    }
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var stringify: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    stringify.write(Value{ .object = root }) catch return false;
    aw.writer.writeByte('\n') catch return false;
    credential_store.replaceFile(io, Io.Dir.cwd(), settings_path, aw.writer.buffered(), .default_file) catch return false;
    return true;
}

test "contains: exact provider ids only" {
    const providers = [_][]const u8{ "codex", "anthropic" };
    try std.testing.expect(contains(&providers, "codex"));
    try std.testing.expect(!contains(&providers, "openai"));
    try std.testing.expect(!contains(&providers, "code"));
}
