//! Per-user on/off choices for MCP servers: `graff mcp enable|disable <name>`
//! and the desktop app's MCP servers page.
//!
//! `~/.codegraff/mcp-state.json` holds `{"disabled":[…], "enabled":[…]}`. It
//! is separate from the server configs on purpose: entries imported from other
//! clients' files (plugins.zig) can be switched off without rewriting a file
//! graff does not own. `disabled` keeps a server from starting anywhere;
//! `enabled` opts in a server that is off by default (deepwiki, mobbin — see
//! tool_surface.skipOptionalServer), alongside the existing env opt-ins.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const credential_store = @import("credential_store.zig");

pub const rel_path = ".codegraff/mcp-state.json";

pub const State = struct {
    disabled: []const []const u8 = &.{},
    enabled: []const []const u8 = &.{},

    pub fn isDisabled(s: State, name: []const u8) bool {
        return contains(s.disabled, name);
    }

    pub fn isEnabled(s: State, name: []const u8) bool {
        return contains(s.enabled, name);
    }
};

/// Why a configured server does not start with the session, if it does not.
pub const Skip = enum { none, off, opt_in };

/// The boot rule every reader shares (mcp_boot.init, /mcp trust, status rows):
/// switched off by the user, switched off in the entry itself, or an optional
/// server nobody opted in to. An explicit `graff mcp enable` beats the entry.
pub fn skipReason(state: State, name: []const u8, cfg: ?std.json.ObjectMap, environ_map: anytype, global_only: bool) Skip {
    if (state.isDisabled(name)) return .off;
    if (state.isEnabled(name)) return .none;
    if (cfg) |c| if (offInConfig(c)) return .off;
    if (@import("tool_surface.zig").skipOptionalAtBoot(name, environ_map, global_only)) return .opt_in;
    return .none;
}

/// `"enabled": false` (Codex plugin manifests) or `"disabled": true` (Claude
/// and Cursor configs): the file that declares the server has it off, so
/// graff must not start it either.
pub fn offInConfig(cfg: std.json.ObjectMap) bool {
    if (cfg.get("enabled")) |v| if (v == .bool and !v.bool) return true;
    if (cfg.get("disabled")) |v| if (v == .bool and v.bool) return true;
    return false;
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn path(arena: Allocator, home: []const u8) ?[]const u8 {
    if (home.len == 0) return null;
    return std.fmt.allocPrint(arena, "{s}/" ++ rel_path, .{home}) catch null;
}

fn names(arena: Allocator, obj: std.json.ObjectMap, field: []const u8) []const []const u8 {
    const v = obj.get(field) orelse return &.{};
    if (v != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (v.array.items) |item| if (item == .string and item.string.len > 0) out.append(arena, item.string) catch break;
    return out.items;
}

/// Best-effort: a missing or malformed file is "no choices made".
pub fn load(io: Io, arena: Allocator, home: []const u8) State {
    const p = path(arena, home) orelse return .{};
    const text = Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(1 << 20)) catch return .{};
    const parsed = std.json.parseFromSliceLeaky(Value, arena, text, .{ .allocate = .alloc_always }) catch return .{};
    if (parsed != .object) return .{};
    return .{ .disabled = names(arena, parsed.object, "disabled"), .enabled = names(arena, parsed.object, "enabled") };
}

/// Switch `name` on or off and persist it. On removes it from `disabled` and
/// records the opt-in; off does the reverse.
pub fn set(io: Io, arena: Allocator, home: []const u8, name: []const u8, on: bool) !void {
    const p = path(arena, home) orelse return error.NoHomeDirectory;
    const current = load(io, arena, home);
    var disabled: std.ArrayList([]const u8) = .empty;
    var enabled: std.ArrayList([]const u8) = .empty;
    for (current.disabled) |n| if (!std.mem.eql(u8, n, name)) try disabled.append(arena, n);
    for (current.enabled) |n| if (!std.mem.eql(u8, n, name)) try enabled.append(arena, n);
    try (if (on) &enabled else &disabled).append(arena, name);
    var aw: Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{ .disabled = disabled.items, .enabled = enabled.items }, .{ .whitespace = .indent_2 }, &aw.writer);
    try aw.writer.writeByte('\n');
    if (std.fs.path.dirname(p)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
    try credential_store.replaceFile(io, Io.Dir.cwd(), p, aw.writer.buffered(), .default_file);
}

const NoEnv = struct {
    pub fn get(_: NoEnv, _: []const u8) ?[]const u8 {
        return null;
    }
};

test "mcp state: off wins, on opts in an optional server, choices persist" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const home = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    var state = load(io, a, home);
    try std.testing.expectEqual(Skip.none, skipReason(state, "github", null, NoEnv{}, true));
    try std.testing.expectEqual(Skip.opt_in, skipReason(state, "deepwiki", null, NoEnv{}, true));
    // A project that lists the optional server opts it in on its own.
    try std.testing.expectEqual(Skip.none, skipReason(state, "deepwiki", null, NoEnv{}, false));

    try set(io, a, home, "github", false);
    try set(io, a, home, "deepwiki", true);
    state = load(io, a, home);
    try std.testing.expectEqual(Skip.off, skipReason(state, "github", null, NoEnv{}, true));
    try std.testing.expectEqual(Skip.off, skipReason(state, "github", null, NoEnv{}, false));
    try std.testing.expectEqual(Skip.none, skipReason(state, "deepwiki", null, NoEnv{}, true));

    // An entry its own file switched off stays off until enabled here.
    const off_cfg = (try std.json.parseFromSliceLeaky(Value, a, "{\"command\":\"x\",\"enabled\":false}", .{})).object;
    try std.testing.expectEqual(Skip.off, skipReason(state, "plugin", off_cfg, NoEnv{}, true));
    const disabled_cfg = (try std.json.parseFromSliceLeaky(Value, a, "{\"command\":\"x\",\"disabled\":true}", .{})).object;
    try std.testing.expectEqual(Skip.off, skipReason(state, "plugin", disabled_cfg, NoEnv{}, true));
    try set(io, a, home, "plugin", true);
    try std.testing.expectEqual(Skip.none, skipReason(load(io, a, home), "plugin", off_cfg, NoEnv{}, true));

    // Switching back on clears the off and is idempotent.
    try set(io, a, home, "github", true);
    try set(io, a, home, "github", true);
    state = load(io, a, home);
    try std.testing.expectEqual(Skip.none, skipReason(state, "github", null, NoEnv{}, true));
    try std.testing.expectEqual(@as(usize, 0), state.disabled.len);
    try std.testing.expectEqual(@as(usize, 3), state.enabled.len);
}
