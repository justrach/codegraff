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
const main_mod = @import("main.zig");
const util = @import("util.zig");
const Agent = agent_mod.Agent;
const unixMs = util.unixMs;

pub const session_ext = ".session.json";
/// Title-named session files live here (resume reads this).
pub const sessions_dir = ".graff/sessions";

/// INVARIANT: every `.graff/` path this harness builds is FORWARD-SLASHED on
/// every platform, including Windows. Not an accident of `allocPrint` — a
/// choice, and callers may rely on it:
///
///   - Windows accepts '/' in the paths reaching Io.Dir (sliceToPrefixedFileW
///     normalizes them), so nothing is lost by not using the platform join.
///   - These strings are SHOWN TO THE MODEL. The #410 system-prompt line names
///     the session file, #409's cap marker cites an artifact, and #441's
///     transcript path travels into #411's post-compaction note. A path whose
///     shape changes per platform makes those prompts, and the goldens that
///     pin them, harder to reason about for no gain.
///
/// The corollary is for TESTS: assert on the basename, or on a path built
/// through these helpers — never by matching a separator by hand against
/// something the OS produced. A path that came back OUT of the OS
/// (realPathFile and friends, as in #409's spill marker) is the platform's
/// shape, not ours, and ee28d8c is the commit that learned it.
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

pub fn validSessionName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfAny(u8, name, "/\\\r\n\x00") == null;
}

/// Session-list metadata peeked from a session file WITHOUT parsing the
/// (potentially multi-MB) messages array: saveSession writes "title" and
/// "updated_ms" before "messages", so parsing the header slice alone is
/// enough. Zero-value fields when the file predates them or the header
/// can't be read — callers fall back to the raw session name (#109).
pub const SessionMeta = struct { title: ?[]const u8 = null, parent: ?[]const u8 = null, updated_ms: i64 = 0, workspace: ?[]const u8 = null };

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
        .parent = if (parsed.object.get("parent")) |v| (if (v == .string and v.string.len > 0) v.string else null) else null,
        .updated_ms = if (parsed.object.get("updated_ms")) |v| (if (v == .integer) v.integer else 0) else 0,
        .workspace = if (parsed.object.get("workspace")) |v| (if (v == .string and v.string.len > 0) v.string else null) else null,
    };
}

pub fn sessionMeta(root: *Agent, arena: Allocator, base: []const u8) SessionMeta {
    const path = sessionPath(arena, base) catch return .{};
    const data = Io.Dir.cwd().readFileAlloc(root.io, path, arena, .limited(8 * 1024 * 1024)) catch return .{};
    return sessionMetaFromBytes(arena, data);
}

pub fn sessionExists(root: *Agent, arena: Allocator, base: []const u8) bool {
    const path = sessionPath(arena, base) catch return false;
    if ((Io.Dir.cwd().statFile(root.io, path, .{}) catch null) != null) return true;
    const legacy = std.fmt.allocPrint(arena, "{s}{s}", .{ base, session_ext }) catch return false;
    return (Io.Dir.cwd().statFile(root.io, legacy, .{}) catch null) != null;
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
pub const SessionEntry = struct {
    base: []const u8,
    title: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    updated_ms: i64 = 0,
    workspace: []const u8 = "",
    local: bool = true,
};

fn sameWorkspace(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, a, "/"), std.mem.trimEnd(u8, b, "/"));
}

fn listFromDir(io: Io, arena: Allocator, dir: Io.Dir, workspace: []const u8, local: bool) std.ArrayList(SessionEntry) {
    var entries: std.ArrayList(SessionEntry) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, session_ext)) continue;
        const base = arena.dupe(u8, entry.name[0 .. entry.name.len - session_ext.len]) catch continue;
        const data = dir.readFileAlloc(io, entry.name, arena, .limited(8 * 1024 * 1024)) catch continue;
        const meta = sessionMetaFromBytes(arena, data);
        entries.append(arena, .{
            .base = base,
            .title = meta.title,
            .parent = meta.parent,
            .updated_ms = meta.updated_ms,
            .workspace = meta.workspace orelse workspace,
            .local = local,
        }) catch {};
    }
    return entries;
}

fn newerFirst(_: void, a: SessionEntry, b: SessionEntry) bool {
    if (a.local != b.local) return a.local;
    return a.updated_ms > b.updated_ms;
}

pub fn listSavedSessions(root: *Agent, arena: Allocator) std.ArrayList(SessionEntry) {
    var dir = Io.Dir.cwd().openDir(root.io, sessions_dir, .{ .iterate = true }) catch return .empty;
    defer dir.close(root.io);
    const cwd = if (main_mod.g_cwd_display.len > 0) main_mod.g_cwd_display else ".";
    const entries = listFromDir(root.io, arena, dir, cwd, true);
    std.mem.sort(SessionEntry, entries.items, {}, newerFirst);
    return entries;
}

/// Cwd saves first, then `~/.graff/sessions` when that tree is a different
/// workspace. Cwd wins on the same base name. #712.
pub fn listSavedSessionsAll(root: *Agent, arena: Allocator) std.ArrayList(SessionEntry) {
    var entries = listSavedSessions(root, arena);
    const home = root.home;
    const cwd = if (main_mod.g_cwd_display.len > 0) main_mod.g_cwd_display else ".";
    if (home.len == 0 or sameWorkspace(home, cwd)) return entries;
    var home_root = Io.Dir.cwd().openDir(root.io, home, .{}) catch return entries;
    defer home_root.close(root.io);
    var home_sess = home_root.openDir(root.io, sessions_dir, .{ .iterate = true }) catch return entries;
    defer home_sess.close(root.io);
    const extra = listFromDir(root.io, arena, home_sess, home, false);
    for (extra.items) |e| {
        var seen = false;
        for (entries.items) |c| {
            if (std.mem.eql(u8, c.base, e.base) and c.local) {
                seen = true;
                break;
            }
        }
        if (!seen) entries.append(arena, e) catch {};
    }
    std.mem.sort(SessionEntry, entries.items, {}, newerFirst);
    return entries;
}

pub fn homeSessionPath(arena: Allocator, home: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}/{s}{s}", .{ home, sessions_dir, name, session_ext });
}

/// `~/…` when `path` is under home; otherwise the path as-is.
pub fn displayWorkspace(arena: Allocator, path: []const u8, home: []const u8) []const u8 {
    if (home.len > 0 and (std.mem.eql(u8, path, home) or std.mem.startsWith(u8, path, home) and path.len > home.len and path[home.len] == '/')) {
        return std.fmt.allocPrint(arena, "~{s}", .{path[home.len..]}) catch path;
    }
    return path;
}

/// Count `.session.json` files without parsing them — startup's banner hint.
pub fn countSavedSessions(io: Io) usize {
    var n: usize = 0;
    var dir = Io.Dir.cwd().openDir(io, sessions_dir, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, session_ext)) n += 1;
    }
    return n;
}

pub fn savedSessionsHint(n: usize, buf: []u8) []const u8 {
    if (n == 0) return "";
    return std.fmt.bufPrint(buf, "{d} saved session{s} · /resume to continue", .{
        n,
        if (n == 1) "" else "s",
    }) catch "";
}

test "sessionMetaFromBytes reads title + updated_ms from the header only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const meta = sessionMetaFromBytes(arena,
        \\{"provider":"codegraff","model":"glm-5.2","strict":false,"ultracode_mode":false,"goal":null,"parent":"baseline","title":"Fix \"login\" bug","updated_ms":1782294417239,"messages":[{"role":"user","content":"hi"}]}
    );
    try std.testing.expectEqualStrings("Fix \"login\" bug", meta.title.?);
    try std.testing.expectEqualStrings("baseline", meta.parent.?);
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

test "savedSessionsHint is silent at zero and pluralizes" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("", savedSessionsHint(0, &buf));
    try std.testing.expectEqualStrings("1 saved session · /resume to continue", savedSessionsHint(1, &buf));
    try std.testing.expectEqualStrings("3 saved sessions · /resume to continue", savedSessionsHint(3, &buf));
}

test "sessionMetaFromBytes reads workspace (#712)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const meta = sessionMetaFromBytes(arena,
        \\{"provider":"x","model":"y","title":"Home chat","updated_ms":9,"workspace":"/Users/me","messages":[]}
    );
    try std.testing.expectEqualStrings("Home chat", meta.title.?);
    try std.testing.expectEqualStrings("/Users/me", meta.workspace.?);
    const legacy = sessionMetaFromBytes(arena,
        \\{"provider":"x","model":"y","title":"Old","updated_ms":1,"messages":[]}
    );
    try std.testing.expect(legacy.workspace == null);
}

test "listFromDir finds a session and infers workspace (#712)" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "home-test.session.json",
        .data = "{\"provider\":\"x\",\"model\":\"y\",\"title\":\"Home chat\",\"updated_ms\":9,\"messages\":[]}",
    });
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = listFromDir(std.testing.io, arena, tmp.dir, "/Users/me", false);
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expectEqualStrings("home-test", entries.items[0].base);
    try std.testing.expectEqualStrings("Home chat", entries.items[0].title.?);
    try std.testing.expectEqualStrings("/Users/me", entries.items[0].workspace);
    try std.testing.expect(!entries.items[0].local);
}

test "homeSessionPath and sameWorkspace (#712)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("/Users/me/.graff/sessions/home-test.session.json", try homeSessionPath(arena, "/Users/me", "home-test"));
    try std.testing.expect(sameWorkspace("/Users/me", "/Users/me/"));
    try std.testing.expect(!sameWorkspace("/Users/me", "/tmp/proj"));
}
