//! Session persistence: save/load the conversation (messages + provider id/
//! model + strict/goal/title flags) to `.graff/sessions/<name>.session.json`,
//! plus the list/rename/age helpers behind `/sessions`, `/resume`, and the
//! AI-title auto-rename. Split out of main.zig (600-line goal, #123).
//!
//! Every function here takes `*agent_mod.Agent` (several params are named
//! `root`, matching the harness-wide root-agent convention). saveSession/
//! loadSession/listSavedSessions/sessionAge/session_ext stay pub —
//! commands_session.zig, commands_misc.zig, and readline.zig import them
//! directly as `session.saveSession` etc.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const util = @import("util.zig");
const goal_state = @import("goal_state.zig");
const Agent = agent_mod.Agent;
const Keys = provider_mod.Keys;
const unixMs = util.unixMs;
const utf8Prefix = util.utf8Prefix;

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

/// A conversation is "meaningful" — worth persisting to disk — once it holds any
/// durable state a resume would want back. Concretely, at least one of:
///   - a user message (>= 1 message with role "user"),
///   - a non-null standing goal (/goal steering),
///   - a non-empty todo list, or
///   - recorded tool activity this session.
/// A truly blank draft (no user turn, no goal, no todos, no tools) is NOT
/// meaningful, so saveSession skips it rather than leaving an "Untitled
/// session" file on disk (#184). Callers that only want to avoid the blank-draft
/// write get this for free by going through saveSession.
pub fn hasMeaningfulState(root: *Agent) bool {
    if (root.goal != null) return true;
    if (root.todos.items.len > 0) return true;
    if (root.tools_used.entries.items.len > 0) return true;
    for (root.messages.items) |m| {
        if (m != .object) continue;
        const role = if (m.object.get("role")) |v| (if (v == .string) v.string else "") else "";
        if (std.mem.eql(u8, role, "user")) return true;
    }
    return false;
}

/// Save the conversation (messages + provider id/model + strict flag) to
/// <name>.session.json in the cwd. The JSON message array is already the
/// provider-native wire shape, so resume is a verbatim restore.
pub fn saveSession(root: *Agent, arena: Allocator, name: []const u8) !void {
    // #184: delay durable session creation until the conversation has meaningful
    // state — never leave a blank draft as an "Untitled session" on disk. Existing
    // files are untouched (we skip the write, we do not delete).
    if (!hasMeaningfulState(root)) return;
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
    if (root.goal) |g| {
        try s.beginObject();
        try s.objectField("objective");
        try s.write(g.objective);
        try s.objectField("status");
        try s.write(@tagName(g.status));
        try s.objectField("epoch");
        try s.write(g.epoch);
        try s.objectField("created_ms");
        try s.write(g.created_ms);
        try s.objectField("updated_ms");
        try s.write(g.updated_ms);
        try s.endObject();
    } else try s.write(null);
    // #318: the checklist is durable, goal-scoped state - persist it with the
    // epoch that authored each item so resume cannot mix goals and checklists.
    try s.objectField("todos");
    try s.beginArray();
    for (root.todos.items) |t| {
        try s.beginObject();
        try s.objectField("content");
        try s.write(t.content);
        try s.objectField("status");
        try s.write(t.status);
        try s.objectField("epoch");
        try s.write(t.epoch);
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("title");
    if (root.session_title) |title| try s.write(title) else try s.write(sessionTitle(root));
    try s.objectField("updated_ms");
    try s.write(unixMs(root.io));
    try s.objectField("messages");
    const messages_start = aw.writer.buffered().len;
    try s.write(Value{ .array = root.messages });
    const messages_bytes = aw.writer.buffered().len - messages_start;
    const context_estimate = root.contextEstimateFromInputBytes(messages_bytes);
    // Preserve the last authoritative provider reading across resume. Responses
    // histories can contain compact encrypted-reasoning handles whose serialized
    // byte size substantially underestimates their server-side token cost; without
    // this floor a resumed near-limit session can miss pre-send compaction.
    try s.objectField("context_tokens");
    // std.json.Value represents parsed integers as i64, so keep the persisted
    // value inside the range loadSession can round-trip even if a malformed
    // provider once reported an extreme unsigned count.
    try s.write(@min(context_estimate.effective, @as(u64, std.math.maxInt(i64))));
    // Pair the provider reading with the locally measurable request component.
    // On resume we can preserve only their hidden-token delta while replacing
    // this component with today's prompt/tool-schema estimate.
    try s.objectField("context_local_tokens");
    try s.write(@min(context_estimate.local, @as(u64, std.math.maxInt(i64))));
    try s.endObject();

    Io.Dir.cwd().createDir(root.io, ".graff", .default_dir) catch {};
    Io.Dir.cwd().createDir(root.io, sessions_dir, .default_dir) catch {};
    const path = try sessionPath(arena, name);
    try Io.Dir.cwd().writeFile(root.io, .{ .sub_path = path, .data = aw.writer.buffered() });
}

/// Parse the persisted `goal` field into a structured Goal (#223). A bare string
/// is a legacy session -> load as .active stamped with `now_ms`; an object carries
/// objective + status + created/updated timestamps (an unknown/missing status
/// falls back to .active). Pure (no Io) so it round-trips in unit tests. Returns
/// null for an empty/absent objective.
pub fn goalFromValue(v: Value, now_ms: i64) ?agent_mod.Goal {
    if (v == .string) {
        if (v.string.len == 0) return null;
        return .{ .objective = v.string, .status = .active, .created_ms = now_ms, .updated_ms = now_ms };
    }
    if (v == .object) {
        const go = v.object;
        const txt = if (go.get("objective")) |o| (if (o == .string and o.string.len > 0) o.string else null) else null;
        const objective = txt orelse return null;
        const st: agent_mod.GoalStatus = if (go.get("status")) |s| (if (s == .string) (std.meta.stringToEnum(agent_mod.GoalStatus, s.string) orelse .active) else .active) else .active;
        const ep: u64 = if (go.get("epoch")) |e| (if (e == .integer and e.integer >= 0) @intCast(e.integer) else 0) else 0;
        const cms: i64 = if (go.get("created_ms")) |c| (if (c == .integer) c.integer else 0) else 0;
        const ums: i64 = if (go.get("updated_ms")) |u| (if (u == .integer) u.integer else 0) else 0;
        return .{ .objective = objective, .status = st, .epoch = ep, .created_ms = cms, .updated_ms = ums };
    }
    return null;
}

/// Parse the persisted `todos` array (#318). The caller clears the list first
/// so nothing from a previous conversation survives a resume. Pure (no Io) so
/// it round-trips in unit tests.
pub fn appendTodosFromValue(arena: Allocator, todos: *std.ArrayList(agent_mod.TodoItem), v: Value) !void {
    if (v != .array) return;
    for (v.array.items) |item| {
        if (item != .object) continue;
        const content = if (item.object.get("content")) |c| (if (c == .string) c.string else continue) else continue;
        const status = if (item.object.get("status")) |s| (if (s == .string) s.string else "pending") else "pending";
        const epoch: u64 = if (item.object.get("epoch")) |e| (if (e == .integer and e.integer >= 0) @intCast(e.integer) else 0) else 0;
        try todos.append(arena, .{ .content = content, .status = status, .epoch = epoch });
    }
}

test "todos round-trip: appendTodosFromValue parses content/status/epoch, skips junk (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const parsed = try std.json.parseFromSliceLeaky(Value, a,
        \\[{"content":"wire epochs","status":"completed","epoch":2},
        \\ {"content":"add test","status":"pending","epoch":2},
        \\ {"status":"orphan, no content"}, 17]
    , .{});
    var todos: std.ArrayList(agent_mod.TodoItem) = .empty;
    try appendTodosFromValue(a, &todos, parsed);
    try std.testing.expectEqual(@as(usize, 2), todos.items.len);
    try std.testing.expectEqualStrings("wire epochs", todos.items[0].content);
    try std.testing.expectEqual(@as(u64, 2), todos.items[1].epoch);
    // Legacy sessions (no todos field / wrong type): nothing appended.
    try appendTodosFromValue(a, &todos, .null);
    try std.testing.expectEqual(@as(usize, 2), todos.items.len);
}

test "goalFromValue: epoch round-trips; legacy goals default to epoch 0 (#318)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const v = try std.json.parseFromSliceLeaky(Value, a, "{\"objective\":\"x\",\"status\":\"active\",\"epoch\":3}", .{});
    try std.testing.expectEqual(@as(u64, 3), goalFromValue(v, 1).?.epoch);
    const legacy = try std.json.parseFromSliceLeaky(Value, a, "\"just a string\"", .{});
    try std.testing.expectEqual(@as(u64, 0), goalFromValue(legacy, 1).?.epoch);
}

test "goalFromValue: legacy string -> active; object round-trips; paused stays paused (#223)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Legacy bare string -> active, stamped with now_ms (backward compat).
    const legacy = try std.json.parseFromSliceLeaky(Value, a, "\"ship 0.0.202\"", .{ .allocate = .alloc_always });
    const g1 = goalFromValue(legacy, 4242).?;
    try std.testing.expectEqualStrings("ship 0.0.202", g1.objective);
    try std.testing.expectEqual(agent_mod.GoalStatus.active, g1.status);
    try std.testing.expectEqual(@as(i64, 4242), g1.created_ms);

    // New object with a paused status round-trips as paused (survives resume).
    const paused = try std.json.parseFromSliceLeaky(Value, a, "{\"objective\":\"land #223\",\"status\":\"paused\",\"created_ms\":10,\"updated_ms\":20}", .{ .allocate = .alloc_always });
    const g2 = goalFromValue(paused, 999).?;
    try std.testing.expectEqualStrings("land #223", g2.objective);
    try std.testing.expectEqual(agent_mod.GoalStatus.paused, g2.status);
    try std.testing.expectEqual(@as(i64, 10), g2.created_ms);
    try std.testing.expectEqual(@as(i64, 20), g2.updated_ms);

    // Empty string -> null (no goal).
    const empty = try std.json.parseFromSliceLeaky(Value, a, "\"\"", .{ .allocate = .alloc_always });
    try std.testing.expect(goalFromValue(empty, 1) == null);

    // An unknown status string falls back to active (forward-compat with future variants).
    const unknown = try std.json.parseFromSliceLeaky(Value, a, "{\"objective\":\"x\",\"status\":\"zzz\"}", .{ .allocate = .alloc_always });
    try std.testing.expectEqual(agent_mod.GoalStatus.active, goalFromValue(unknown, 1).?.status);
}

fn contextTokensFromSession(obj: std.json.ObjectMap) u64 {
    const v = obj.get("context_tokens") orelse return 0;
    if (v != .integer or v.integer <= 0) return 0;
    return @intCast(v.integer);
}

fn contextLocalTokensFromSession(obj: std.json.ObjectMap) ?u64 {
    const v = obj.get("context_local_tokens") orelse return null;
    if (v != .integer or v.integer < 0) return null;
    return @intCast(v.integer);
}

fn restoreContextMeter(root: *Agent, saved_context_tokens: u64, saved_local_tokens: ?u64) void {
    const current_local = root.fullRequestEstimateTokens();
    // A provider reading is meaningful across resume only after separating its
    // locally measurable component. Preserve the server-only delta (encrypted
    // reasoning, tokenizer differences, output usage), but replace the old
    // prompt/tool-schema estimate with the current one. Files predating this
    // paired field safely re-estimate instead of trusting an ungrounded meter.
    const hidden_delta = if (saved_local_tokens) |saved_local|
        saved_context_tokens -| saved_local
    else
        0;
    root.last_context_tokens = current_local +| hidden_delta;
    root.context_local_tokens = current_local;
    root.last_cache_read = 0;
}

/// Restore a saved session: parse the file (arena-owned), rebuild the
/// provider, and replace the live history. The wire format must still match
/// the restored provider's kind — same provider id guarantees it.
pub fn loadSession(root: *Agent, keys: *Keys, arena: Allocator, name: []const u8) !void {
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
    const goal: ?agent_mod.Goal = if (obj.get("goal")) |v| goalFromValue(v, unixMs(root.io)) else null;
    const title = if (obj.get("title")) |v| (if (v == .string and v.string.len > 0) v.string else null) else null;
    // Optional for backward compatibility with sessions written before context
    // metering was persisted. JSON integers are signed; ignore negative/wrong-type
    // values instead of turning a corrupt session into an enormous unsigned count.
    const saved_context_tokens = contextTokensFromSession(obj);
    const saved_local_tokens = contextLocalTokensFromSession(obj);

    root.ensureStoredKeys(keys);
    if (std.mem.eql(u8, pid, "codex")) root.ensureModelCatalog(keys.*);
    root.provider = try keys.providerById(pid, model);
    // A resumed session may use a different wire format than the startup
    // default. Materialize that catalog before rebasing its saved context
    // meter, and keep every still-unused format lazy.
    try root.ensureRootTools(root.provider.kind);
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
    root.todos.clearRetainingCapacity(); // never inherit another conversation's checklist (#318)
    if (obj.get("todos")) |tv| try appendTodosFromValue(arena, &root.todos, tv);
    root.todos_dirty = false; // restored todos are persisted state, never this-process completion evidence (#318)
    // #318: retire a restored-active goal whose checklist is already finished.
    if (goal_state.reconcileRestored(root)) if (root.tracer) |t| t.note("goal", "reconciled-complete");
    // Steering gate state belongs to the previous conversation (#318): drop any
    // queued one-shot note and force a full goal-note re-statement next turn.
    root.pending_goal_note = null;
    root.goal_note_fp = 0;
    root.goal_note_age = 0;
    root.session_title = title;
    // Rebase the saved server-only delta onto today's prompt/tool-schema input.
    restoreContextMeter(root, saved_context_tokens, saved_local_tokens);
    root.cap_new = false; // per-provider; relearn on rejection
    root.effort_rejected = false;
    root.ws_off = false; // transport failures belong to the prior live session
    root.ws_transport_failures = 0;
    root.compact_transport_failures = 0;
    root.last_usage_includes_output = false;
    root.last_request_context_overflow = false;
    root.last_request_write_failed = false;
    root.fallback_active = false;
    root.fallback_blocked = false;
}

test "session context meter restores hidden delta and legacy sessions re-estimate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const current = try std.json.parseFromSliceLeaky(Value, a, "{\"context_tokens\":90000,\"context_local_tokens\":20000}", .{});
    try std.testing.expectEqual(@as(u64, 90_000), contextTokensFromSession(current.object));
    try std.testing.expectEqual(@as(u64, 20_000), contextLocalTokensFromSession(current.object).?);
    const legacy = try std.json.parseFromSliceLeaky(Value, a, "{}", .{});
    try std.testing.expectEqual(@as(u64, 0), contextTokensFromSession(legacy.object));
    try std.testing.expect(contextLocalTokensFromSession(legacy.object) == null);
    const invalid = try std.json.parseFromSliceLeaky(Value, a, "{\"context_tokens\":-1}", .{});
    try std.testing.expectEqual(@as(u64, 0), contextTokensFromSession(invalid.object));
    const invalid_local = try std.json.parseFromSliceLeaky(Value, a, "{\"context_local_tokens\":-1}", .{});
    try std.testing.expect(contextLocalTokensFromSession(invalid_local.object) == null);

    // Model a resumed Responses history whose compact encrypted-reasoning handle
    // serializes much smaller than the authoritative server token reading.
    var msgs = std.json.Array.init(a);
    const reasoning = "{\"type\":\"reasoning\",\"encrypted_content\":\"" ++ util.repeatBytes("x", 8192) ++ "\"}";
    try msgs.append(try std.json.parseFromSliceLeaky(Value, a, reasoning, .{}));
    var root: Agent = undefined;
    root.provider = .{ .id = "codex", .kind = .responses, .auth = .bearer, .url = "", .api_key = "", .model = "gpt-5", .context = 100_000 };
    root.messages = msgs;
    root.sub = false;
    root.strict = false;
    root.sys_normal = "";
    root.sys_strict = "";
    root.tools_responses = "";
    root.last_cache_read = 12_345;

    const local_estimate = root.fullRequestEstimateTokens();
    try std.testing.expect(local_estimate < 90_000);
    restoreContextMeter(&root, contextTokensFromSession(current.object), contextLocalTokensFromSession(current.object));
    try std.testing.expectEqual(local_estimate + 70_000, root.last_context_tokens);
    try std.testing.expectEqual(@as(u64, 0), root.last_cache_read);
    try std.testing.expect(root.last_context_tokens > local_estimate);

    // A legitimate over-window reading remains evidence when its paired local
    // estimate matches the current request.
    restoreContextMeter(&root, 150_000, local_estimate);
    try std.testing.expectEqual(@as(u64, 150_000), root.last_context_tokens);

    // An unknown window still preserves the paired hidden delta; no clamping is
    // needed or safe.
    root.provider.context = 0;
    restoreContextMeter(&root, 90_000, local_estimate);
    try std.testing.expectEqual(root.fullRequestEstimateTokens() + (90_000 - local_estimate), root.last_context_tokens);
    root.provider.context = 100_000;

    // A legacy session has no saved meter, but non-empty restored history must
    // still produce a live local reading rather than resetting to zero.
    root.last_cache_read = 99;
    restoreContextMeter(&root, contextTokensFromSession(legacy.object), contextLocalTokensFromSession(legacy.object));
    try std.testing.expectEqual(local_estimate, root.last_context_tokens);
    try std.testing.expectEqual(@as(u64, 0), root.last_cache_read);

    // A meter from an intermediate build without the paired local component is
    // also ungrounded and must not force destructive recovery after resume.
    const unpaired = try std.json.parseFromSliceLeaky(Value, a, "{\"context_tokens\":99000}", .{});
    restoreContextMeter(&root, contextTokensFromSession(unpaired.object), contextLocalTokensFromSession(unpaired.object));
    try std.testing.expectEqual(local_estimate, root.last_context_tokens);
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

test "hasMeaningfulState gates the blank-draft write (#184)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Only the fields hasMeaningfulState reads are set; the rest stay untouched.
    var root: Agent = undefined;
    root.goal = null;
    root.todos = .empty;
    root.tools_used = .{};
    root.messages = std.json.Array.init(arena);

    // Truly blank: no user turn, no goal, no todos, no tools → not persisted.
    try std.testing.expect(!hasMeaningfulState(&root));

    // A standing /goal alone is meaningful (goal-only sessions are still saved).
    root.goal = .{ .objective = "ship the release" };
    try std.testing.expect(hasMeaningfulState(&root));

    // One user message alone is meaningful.
    root.goal = null;
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "role", .{ .string = "user" });
    try obj.put(arena, "content", .{ .string = "hi" });
    try root.messages.append(.{ .object = obj });
    try std.testing.expect(hasMeaningfulState(&root));
}
