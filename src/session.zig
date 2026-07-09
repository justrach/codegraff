//! Session persistence: save/load the conversation (messages + provider id/
//! model + strict/goal/title flags) to `.graff/sessions/<name>.session.json`,
//! plus the list/rename/age helpers behind `/sessions`, `/resume`, and the
//! AI-title auto-rename. Split out of main.zig (600-line goal, #123).
//!
//! Every function here takes `*main_mod.Agent` (several params are named
//! `root`, so the back-import is aliased `main_mod`, not `root`, to avoid
//! shadowing). saveSession/loadSession/listSavedSessions/sessionAge/
//! session_ext stay pub — commands_session.zig, commands_misc.zig, and
//! readline.zig already back-import them as `main_mod.saveSession` etc.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const Agent = main_mod.Agent;
const Keys = main_mod.Keys;
const unixMs = main_mod.unixMs;
const utf8Prefix = main_mod.utf8Prefix;

pub const session_ext = ".session.json";
const sessions_dir = ".graff/sessions"; // title-named session files live here (resume reads this)

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
        \\{"provider":"kimi","model":"kimi-k2.7","strict":false,"messages":[]}
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

/// Filesystem-safe slug of an AI title: lowercase alnum, any other run collapses
/// to one '-', trimmed, capped at 60. "Fixing the login bug" -> "fixing-the-login-bug".
/// Returns "" for an empty/symbol-only title.
pub fn slugifyTitle(arena: Allocator, title: []const u8) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var last_dash = true; // suppress a leading '-'
    for (title) |c| {
        if (buf.items.len >= 60) break;
        const lc = std.ascii.toLower(c);
        if ((lc >= 'a' and lc <= 'z') or (lc >= '0' and lc <= '9')) {
            buf.append(arena, lc) catch break;
            last_dash = false;
        } else if (!last_dash) {
            buf.append(arena, '-') catch break;
            last_dash = true;
        }
    }
    var s = buf.items;
    while (s.len > 0 and s[s.len - 1] == '-') s = s[0 .. s.len - 1];
    return s;
}

/// Rename an as-yet-untitled (session-<ts>) session to a slug of its AI title:
/// point session_name at a free <slug>[-N], write it there, and remove the old
/// file. Best-effort; only fires for the default timestamp name, so a manual
/// /rename or a resumed session keeps its name.
pub fn renameSession(root: *Agent, arena: Allocator, slug: []const u8) void {
    if (slug.len == 0) return;
    if (!std.mem.startsWith(u8, root.session_name, "session-")) return; // already titled
    if (std.mem.eql(u8, slug, root.session_name)) return;
    var name = slug;
    var n: usize = 2;
    while (n < 100) : (n += 1) {
        const p = sessionPath(arena, name) catch return;
        if (Io.Dir.cwd().statFile(root.io, p, .{})) |_| {
            name = std.fmt.allocPrint(arena, "{s}-{d}", .{ slug, n }) catch return;
        } else |_| break; // free
    }
    const old_name = root.session_name;
    root.session_name = arena.dupe(u8, name) catch return;
    saveSession(root, arena, root.session_name) catch {};
    if (sessionPath(arena, old_name)) |op| (Io.Dir.cwd().deleteFile(root.io, op) catch {}) else |_| {}
}

pub fn sessionTitle(root: *Agent) []const u8 {
    if (root.session_title) |title| return title;
    for (root.messages.items) |m| {
        if (m != .object) continue;
        const role = if (m.object.get("role")) |v| (if (v == .string) v.string else "") else "";
        if (!std.mem.eql(u8, role, "user")) continue;
        if (m.object.get("content")) |c| switch (c) {
            .string => |text| return utf8Prefix(std.mem.trim(u8, text, " \t\r\n"), 80),
            .array => |arr| for (arr.items) |part| {
                if (part == .object) {
                    const typ = if (part.object.get("type")) |v| (if (v == .string) v.string else "") else "";
                    if (std.mem.eql(u8, typ, "text")) {
                        if (part.object.get("text")) |tv| if (tv == .string) return utf8Prefix(std.mem.trim(u8, tv.string, " \t\r\n"), 80);
                    }
                }
            },
            else => {},
        };
    }
    return "Untitled session";
}

/// Save the conversation (messages + provider id/model + strict flag) to
/// <name>.session.json in the cwd. The JSON message array is already the
/// provider-native wire shape, so resume is a verbatim restore.
pub fn saveSession(root: *Agent, arena: Allocator, name: []const u8) !void {
    var aw: Io.Writer.Allocating = .init(root.gpa);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try s.beginObject();
    try s.objectField("provider");
    try s.write(root.provider.id);
    try s.objectField("model");
    try s.write(root.provider.model);
    try s.objectField("strict");
    try s.write(root.strict);
    try s.objectField("ultracode_mode");
    try s.write(root.ultracode_mode);
    try s.objectField("goal");
    if (root.goal) |goal| try s.write(goal) else try s.write(null);
    try s.objectField("title");
    if (root.session_title) |title| try s.write(title) else try s.write(sessionTitle(root));
    try s.objectField("updated_ms");
    try s.write(unixMs(root.io));
    try s.objectField("messages");
    try s.write(Value{ .array = root.messages });
    try s.endObject();

    Io.Dir.cwd().createDir(root.io, ".graff", .default_dir) catch {};
    Io.Dir.cwd().createDir(root.io, sessions_dir, .default_dir) catch {};
    const path = try sessionPath(arena, name);
    try Io.Dir.cwd().writeFile(root.io, .{ .sub_path = path, .data = aw.writer.buffered() });
}

/// Restore a saved session: parse the file (arena-owned), rebuild the
/// provider, and replace the live history. The wire format must still match
/// the restored provider's kind — same provider id guarantees it.
pub fn loadSession(root: *Agent, keys: Keys, arena: Allocator, name: []const u8) !void {
    const path = try sessionPath(arena, name);
    const data = Io.Dir.cwd().readFileAlloc(root.io, path, arena, .limited(8 * 1024 * 1024)) catch blk: {
        // backward-compat: older builds wrote <name>.session.json in cwd.
        const legacy = try std.fmt.allocPrint(arena, "{s}{s}", .{ name, session_ext });
        break :blk try Io.Dir.cwd().readFileAlloc(root.io, legacy, arena, .limited(8 * 1024 * 1024));
    };
    const parsed = try std.json.parseFromSliceLeaky(Value, arena, data, .{ .allocate = .alloc_always });
    if (parsed != .object) return error.BadSession;
    const obj = parsed.object;
    const pid = if (obj.get("provider")) |v| v.string else return error.BadSession;
    const model = if (obj.get("model")) |v| v.string else return error.BadSession;
    const msgs = if (obj.get("messages")) |v| (if (v == .array) v.array else return error.BadSession) else return error.BadSession;
    const strict = if (obj.get("strict")) |v| (v == .bool and v.bool) else false;
    const ultracode_mode = if (obj.get("ultracode_mode")) |v| (v == .bool and v.bool) else false;
    const goal = if (obj.get("goal")) |v| (if (v == .string and v.string.len > 0) v.string else null) else null;
    const title = if (obj.get("title")) |v| (if (v == .string and v.string.len > 0) v.string else null) else null;

    root.provider = try keys.providerById(pid, model);
    root.messages = msgs;
    // Repair histories written by older builds where a Responses
    // `function_call_output.output` was persisted as a byte array instead of a
    // string. The Responses API rejects that ("input[N].output[0]: expected an
    // object, got an integer instead"), and we restore messages verbatim — so a
    // poisoned last.session.json would otherwise re-break every resume.
    for (root.messages.items) |*m| {
        if (m.* != .object) continue;
        const mtype = if (m.object.get("type")) |t| (if (t == .string) t.string else "") else "";
        if (!std.mem.eql(u8, mtype, "function_call_output")) continue;
        const out = m.object.get("output") orelse continue;
        if (out == .string) continue; // already correct
        var repaired: std.ArrayList(u8) = .empty;
        if (out == .array) {
            for (out.array.items) |el| {
                if (el == .integer and el.integer >= 0 and el.integer <= 255) {
                    try repaired.append(arena, @intCast(el.integer));
                }
            }
        }
        try m.object.put(arena, "output", .{ .string = repaired.items });
    }
    root.strict = strict;
    root.ultracode_mode = ultracode_mode;
    root.goal = goal;
    root.session_title = title;
    root.last_context_tokens = 0;
    root.cap_new = false; // per-provider; relearn on rejection
    root.effort_rejected = false;
}

test "slugifyTitle makes a filesystem-safe slug from an AI title" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("fixing-the-login-bug", slugifyTitle(a, "Fixing the login bug"));
    try std.testing.expectEqualStrings("add-dark-mode", slugifyTitle(a, "Add dark mode!!"));
    try std.testing.expectEqualStrings("planning-v2", slugifyTitle(a, "  Planning — v2  ")); // trim + collapse
    try std.testing.expectEqualStrings("", slugifyTitle(a, "🎉 ✨")); // symbol-only → "" (keeps the session-<ts> name)
}
