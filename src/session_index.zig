//! The session INDEX: everything `/sessions` and the `/resume` picker need to
//! list saved conversations without parsing them. Split out of session.zig,
//! which sits at the 600-line cap (#330 needed room there for the protocol
//! sequence high-water mark). session.zig re-exports every name here, so
//! callers keep importing `session.listSavedSessions` and friends.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const util = @import("util.zig");
const Agent = agent_mod.Agent;
const unixMs = util.unixMs;

pub const session_ext = ".session.json";
/// Title-named session files live here (resume reads this).
pub const sessions_dir = ".graff/sessions";

/// #441: the append-only transcript beside each session file, and the one
/// rotated generation behind it. The suffixes live here, with the session
/// suffix, because BOTH the writer (session_transcript.zig) and the sweep that
/// reclaims them with their session (tool_spill.zig) have to agree on them.
pub const transcript_ext = ".transcript.jsonl";
pub const transcript_rotated_ext = ".transcript.1.jsonl";

/// Path to a session file: .graff/sessions/<name>.session.json.
pub fn sessionPath(arena: Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ sessions_dir, name, session_ext });
}

/// Session-list metadata peeked from a session file WITHOUT parsing the
/// (potentially multi-MB) messages array: saveSession writes "title" and
/// "updated_ms" before "messages", so parsing the header slice alone is
/// enough. Zero-value fields when the file predates them or the header
/// can't be read — callers fall back to the raw session name (#109).
pub const SessionMeta = struct { title: ?[]const u8 = null, updated_ms: i64 = 0 };

pub fn sessionMetaFromBytes(arena: Allocator, data: []const u8) SessionMeta {
    // Embedded quotes inside string values are escaped in the file, so the
    // raw needle can only match the real top-level "messages" key.
    const idx = std.mem.indexOf(u8, data, "\"messages\":") orelse return .{};
    const header = std.mem.trimEnd(u8, data[0..idx], " \t\r\n");
    if (header.len < 2 or header[header.len - 1] != ',') return .{};
    const hjson = std.fmt.allocPrint(arena, "{s}}}", .{header[0 .. header.len - 1]}) catch return .{};
    const parsed = std.json.parseFromSliceLeaky(Value, arena, hjson, .{ .allocate = .alloc_always }) catch return .{};
    if (parsed != .object) return .{};
    return .{
        .title = if (parsed.object.get("title")) |v| (if (v == .string and v.string.len > 0) v.string else null) else null,
        .updated_ms = if (parsed.object.get("updated_ms")) |v| (if (v == .integer) v.integer else 0) else 0,
    };
}

pub fn sessionMeta(root: *Agent, arena: Allocator, base: []const u8) SessionMeta {
    const path = sessionPath(arena, base) catch return .{};
    const data = Io.Dir.cwd().readFileAlloc(root.io, path, arena, .limited(8 * 1024 * 1024)) catch return .{};
    return sessionMetaFromBytes(arena, data);
}

/// "3m ago"-style age for the session lists; "" when the timestamp is missing.
pub fn sessionAge(arena: Allocator, io: Io, then_ms: i64) []const u8 {
    if (then_ms <= 0) return "";
    const s = @divTrunc(unixMs(io) - then_ms, 1000);
    if (s < 60) return "just now";
    if (s < 3600) return std.fmt.allocPrint(arena, "{d}m ago", .{@divTrunc(s, 60)}) catch "";
    if (s < 86_400) return std.fmt.allocPrint(arena, "{d}h ago", .{@divTrunc(s, 3600)}) catch "";
    return std.fmt.allocPrint(arena, "{d}d ago", .{@divTrunc(s, 86_400)}) catch "";
}

/// One row per saved session for the /resume picker and /sessions list:
/// newest first, keyed (and resumed) by the file base name.
pub const SessionEntry = struct { base: []const u8, title: ?[]const u8 = null, updated_ms: i64 = 0 };

pub fn listSavedSessions(root: *Agent, arena: Allocator) std.ArrayList(SessionEntry) {
    var entries: std.ArrayList(SessionEntry) = .empty;
    var dir = Io.Dir.cwd().openDir(root.io, sessions_dir, .{ .iterate = true }) catch return entries;
    defer dir.close(root.io);
    var it = dir.iterate();
    while (it.next(root.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, session_ext)) continue;
        const base = arena.dupe(u8, entry.name[0 .. entry.name.len - session_ext.len]) catch continue;
        const meta = sessionMeta(root, arena, base);
        entries.append(arena, .{ .base = base, .title = meta.title, .updated_ms = meta.updated_ms }) catch {};
    }
    std.mem.sort(SessionEntry, entries.items, {}, struct {
        fn newerFirst(_: void, a: SessionEntry, b: SessionEntry) bool {
            return a.updated_ms > b.updated_ms;
        }
    }.newerFirst);
    return entries;
}

test "sessionMetaFromBytes reads title + updated_ms from the header only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const meta = sessionMetaFromBytes(arena,
        \\{"provider":"codegraff","model":"glm-5.2","strict":false,"ultracode_mode":false,"goal":null,"title":"Fix \"login\" bug","updated_ms":1782294417239,"messages":[{"role":"user","content":"hi"}]}
    );
    try std.testing.expectEqualStrings("Fix \"login\" bug", meta.title.?);
    try std.testing.expectEqual(@as(i64, 1782294417239), meta.updated_ms);
}

test "sessionMetaFromBytes falls back cleanly on legacy/invalid headers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const legacy = sessionMetaFromBytes(arena,
        \\{"provider":"kimi","model":"k3","strict":false,"messages":[]}
    );
    try std.testing.expect(legacy.title == null);
    try std.testing.expectEqual(@as(i64, 0), legacy.updated_ms);
    const tricky = sessionMetaFromBytes(arena,
        \\{"provider":"x","model":"y","goal":"say \"messages\": then stop","title":"T","updated_ms":5,"messages":[]}
    );
    try std.testing.expectEqualStrings("T", tricky.title.?);
    try std.testing.expectEqual(@as(i64, 5), tricky.updated_ms);
    try std.testing.expect(sessionMetaFromBytes(arena, "not json").title == null);
}
