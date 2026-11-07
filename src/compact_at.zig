//! Where automatic compaction starts, as a percent of the model's context
//! window (default 80, capped at 300k tokens on Gemini; `Provider.compactAt`).
//! A set percentage applies as is. The first one set wins:
//!
//!   1. `--compact-at N` on the command line (the SDK's `compactAt` option)
//!   2. `GRAFF_COMPACT_PCT=N` (how Harness passes its setting)
//!   3. `compact_pct` in `.harness/settings.json`, written by `/compact-at`
//!
//! `/compact-at N` also applies to the running session at once: compactAt
//! reads the override on every check, including the server-side directive.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const provider_mod = @import("provider.zig");
const policy = @import("harness_policy.zig");
const Agent = @import("agent.zig").Agent;

pub const default_pct: u8 = 80;
/// Below 10% a session compacts on its own standing prompt; at 95% the
/// emergency trim (`Provider.nearContextLimit`) would fire first.
pub const min_pct: u8 = 10;
pub const max_pct: u8 = 95;

/// Set by `--compact-at`; applied over every other source at startup.
pub var g_cli: ?u8 = null;

/// "70" or "70%", within min_pct..max_pct.
pub fn parse(text: []const u8) ?u8 {
    const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, text, " \t"), "%");
    const pct = std.fmt.parseInt(u8, std.mem.trim(u8, trimmed, " \t"), 10) catch return null;
    return if (pct >= min_pct and pct <= max_pct) pct else null;
}

/// Startup, after the env knobs: the flag beats the env, which beats the
/// saved setting.
pub fn applyStartup(io: Io, arena: Allocator) void {
    if (g_cli) |pct| {
        provider_mod.g_compact_pct_override = pct;
        return;
    }
    if (provider_mod.g_compact_pct_override != null) return;
    if (loadSaved(io, arena)) |pct| provider_mod.g_compact_pct_override = pct;
}

fn loadSaved(io: Io, arena: Allocator) ?u8 {
    const data = Io.Dir.cwd().readFileAlloc(io, policy.settings_path, arena, .limited(1 << 20)) catch return null;
    const v = std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    const saved = v.object.get("compact_pct") orelse return null;
    if (saved != .integer or saved.integer < min_pct or saved.integer > max_pct) return null;
    return @intCast(saved.integer);
}

/// Write `compact_pct` (null removes it), keeping every other key.
fn save(io: Io, gpa: Allocator, pct: ?u8) bool {
    Io.Dir.cwd().createDir(io, policy.settings_dir, .default_dir) catch {};
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var root_obj: std.json.ObjectMap = .empty;
    if (Io.Dir.cwd().readFileAlloc(io, policy.settings_path, a, .limited(1 << 20))) |data| {
        if (std.json.parseFromSliceLeaky(Value, a, data, .{ .allocate = .alloc_always })) |v| {
            if (v == .object) root_obj = v.object;
        } else |_| {}
    } else |_| {}
    if (pct) |p| {
        root_obj.put(a, "compact_pct", .{ .integer = p }) catch return false;
    } else _ = root_obj.orderedRemove("compact_pct");
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer, .options = .{ .whitespace = .indent_2 } };
    s.write(Value{ .object = root_obj }) catch return false;
    const f = Io.Dir.cwd().createFile(io, policy.settings_path, .{}) catch return false;
    defer f.close(io);
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(io, &wbuf);
    fw.interface.writeAll(aw.writer.buffered()) catch return false;
    fw.interface.writeAll("\n") catch return false;
    fw.interface.flush() catch return false;
    return true;
}

pub fn current() u8 {
    return if (provider_mod.g_compact_pct_override) |p| @min(p, 100) else default_pct;
}

/// The percent the threshold actually sits at: the default is capped in
/// tokens on some models (Provider.gemini_compact_tokens).
fn shownPct(p: provider_mod.Provider) u64 {
    if (p.context == 0) return current();
    return (p.compactAt() * 100 + p.context / 2) / p.context;
}

/// `/compact-at` shows the point, `/compact-at N` sets it (and persists it
/// for this workspace), `/compact-at default` goes back to 80%.
pub fn handle(root: *Agent, line: []const u8, out: *Io.Writer) !bool {
    const name = "/compact-at";
    if (!std.mem.startsWith(u8, line, name)) return false;
    if (line.len > name.len and line[name.len] != ' ' and line[name.len] != '\t') return false;
    const arg = std.mem.trim(u8, line[name.len..], " \t");
    if (arg.len == 0) {
        try out.print("compaction starts at {d}% of the context window ({d}k of {d}k tokens){s}\n", .{
            shownPct(root.provider),
            root.provider.compactAt() / 1000,
            root.provider.context / 1000,
            if (provider_mod.g_compact_pct_override == null) " · default" else "",
        });
    } else if (std.ascii.eqlIgnoreCase(arg, "default") or std.ascii.eqlIgnoreCase(arg, "reset")) {
        provider_mod.g_compact_pct_override = null;
        const saved = save(root.io, root.gpa, null);
        try out.print("compaction starts at the default {d}% of the context window ({d}k of {d}k tokens){s}\n", .{
            shownPct(root.provider),
            root.provider.compactAt() / 1000,
            root.provider.context / 1000,
            if (saved) "" else " (not persisted)",
        });
    } else if (parse(arg)) |pct| {
        provider_mod.g_compact_pct_override = pct;
        const saved = save(root.io, root.gpa, pct);
        try out.print("compaction starts at {d}% of the context window ({d}k of {d}k tokens){s}\n", .{
            pct,
            root.provider.compactAt() / 1000,
            root.provider.context / 1000,
            if (saved) "" else " (not persisted)",
        });
    } else {
        try out.print("usage: /compact-at <{d}-{d}>[%] | default\n", .{ min_pct, max_pct });
    }
    try out.flush();
    return true;
}

test "parse accepts a bare or percent-suffixed value inside the safe range" {
    try std.testing.expectEqual(@as(?u8, 70), parse("70"));
    try std.testing.expectEqual(@as(?u8, 70), parse(" 70% "));
    try std.testing.expectEqual(@as(?u8, 10), parse("10"));
    try std.testing.expectEqual(@as(?u8, 95), parse("95%"));
    for ([_][]const u8{ "9", "96", "100", "0", "-5", "seventy", "", "%", "70.5" }) |bad|
        try std.testing.expectEqual(@as(?u8, null), parse(bad));
}

test "the flag beats the env, and the env beats nothing" {
    const saved_override = provider_mod.g_compact_pct_override;
    const saved_cli = g_cli;
    defer provider_mod.g_compact_pct_override = saved_override;
    defer g_cli = saved_cli;
    provider_mod.g_compact_pct_override = 55; // GRAFF_COMPACT_PCT
    g_cli = 70;
    applyStartup(std.testing.io, std.testing.allocator);
    try std.testing.expectEqual(@as(?u8, 70), provider_mod.g_compact_pct_override);
    g_cli = null;
    provider_mod.g_compact_pct_override = 55;
    applyStartup(std.testing.io, std.testing.allocator);
    try std.testing.expectEqual(@as(?u8, 55), provider_mod.g_compact_pct_override);
}

test "the threshold follows the setting in both directions" {
    const saved_override = provider_mod.g_compact_pct_override;
    defer provider_mod.g_compact_pct_override = saved_override;
    const p: provider_mod.Provider = .{ .id = "t", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "t", .context = 200_000 };
    provider_mod.g_compact_pct_override = null;
    try std.testing.expectEqual(@as(u64, 160_000), p.compactAt());
    provider_mod.g_compact_pct_override = parse("60%");
    try std.testing.expectEqual(@as(u64, 120_000), p.compactAt());
    provider_mod.g_compact_pct_override = parse("90");
    try std.testing.expectEqual(@as(u64, 180_000), p.compactAt());
}

test "Gemini's default stops at 300k tokens; a set percentage still applies" {
    const saved_override = provider_mod.g_compact_pct_override;
    defer provider_mod.g_compact_pct_override = saved_override;
    provider_mod.g_compact_pct_override = null;
    for ([_][]const u8{ "gemini-3.8-flash", "google/gemini-3.8-flash" }) |model| {
        const p: provider_mod.Provider = .{ .id = "t", .kind = .interactions, .auth = .goog_api_key, .url = "", .api_key = "", .model = model, .context = 1_048_576 };
        try std.testing.expectEqual(@as(u64, 300_000), p.compactAt());
        try std.testing.expectEqual(@as(u64, 29), shownPct(p));
    }
    const small: provider_mod.Provider = .{ .id = "t", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "gemini-small", .context = 200_000 };
    try std.testing.expectEqual(@as(u64, 160_000), small.compactAt()); // 80% is already under the cap
    const other: provider_mod.Provider = .{ .id = "t", .kind = .openai, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-6", .context = 1_000_000 };
    try std.testing.expectEqual(@as(u64, 800_000), other.compactAt());
    provider_mod.g_compact_pct_override = 80;
    const g: provider_mod.Provider = .{ .id = "t", .kind = .interactions, .auth = .goog_api_key, .url = "", .api_key = "", .model = "gemini-3.8-flash", .context = 1_000_000 };
    try std.testing.expectEqual(@as(u64, 800_000), g.compactAt());
}
