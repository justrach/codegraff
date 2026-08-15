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
//!
//! #273: `saveSession` is still synchronous and still reports its failures;
//! the interactive TURN path calls `saveSessionAsync`, which skips an unchanged
//! conversation outright and queues the write (session_writer.zig). This file's
//! unit tests live in session_tests.zig — the 600-line cap.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const provider_mod = @import("provider.zig");
const util = @import("util.zig");
const goal_state = @import("goal_state.zig");
const session_writer = @import("session_writer.zig"); // #273: the fingerprint + the background write
const shutdown_trace = @import("shutdown_trace.zig"); // #364: teardown phase stamps
const protocol_seq = @import("protocol_seq.zig"); // #330: the --json event sequence survives a resume
const http_headers = @import("http_headers.zig"); // the k3/codex prompt-cache key survives one too
const session_transcript = @import("session_transcript.zig"); // #441: the append-only history this file's rewrites discard
const prompts = @import("prompts.zig");
const Agent = agent_mod.Agent;
const Keys = provider_mod.Keys;
const unixMs = util.unixMs;
const utf8Prefix = util.utf8Prefix;

// The session INDEX (paths + the /sessions listing) lives in session_index.zig
// so this file stays under the 600-line cap. Re-exported: callers keep using
// `session.sessionPath`, `session.listSavedSessions`, and friends.
const session_index = @import("session_index.zig");
pub const session_ext = session_index.session_ext;
pub const sessionPath = session_index.sessionPath;
pub const SessionMeta = session_index.SessionMeta;
pub const sessionMetaFromBytes = session_index.sessionMetaFromBytes;
pub const sessionMeta = session_index.sessionMeta;
pub const sessionAge = session_index.sessionAge;
pub const SessionEntry = session_index.SessionEntry;
pub const listSavedSessions = session_index.listSavedSessions;

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
    prompts.rearmAfterRename(arena, root.session_name);
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

/// #273: a digest of every field saveSession persists, EXCEPT `updated_ms`
/// (a clock reading, not conversation state). Equal to the last successfully
/// written one means the file on disk is already this exact session, so the
/// whole save — serialize, lock, write — is skipped.
fn fingerprint(root: *Agent, name: []const u8) u64 {
    var f: session_writer.Fingerprint = .init();
    f.text(name);
    f.text(root.provider.id);
    f.text(root.provider.model);
    f.flag(root.strict);
    f.flag(root.ultracode_mode);
    if (root.goal) |g| {
        f.text(g.objective);
        f.text(@tagName(g.status));
        f.num(g.epoch);
        f.flag(g.standing);
        f.signed(g.created_ms);
        f.signed(g.updated_ms);
    } else f.flag(false);
    f.num(root.todos.items.len);
    for (root.todos.items) |t| {
        f.text(t.content);
        f.text(t.status);
        f.num(t.epoch);
        f.flag(t.retired); // #394: retiring a finished checklist is a real state change, so it must reach disk
    }
    f.text(root.session_title orelse sessionTitle(root));
    // The persisted meter's two inputs. Its third (system prompt + tool schema
    // size) shifts `context_tokens` and `context_local_tokens` together, and
    // resume only keeps their difference, so it cannot change what a resume
    // restores and is deliberately left out.
    f.num(root.last_context_tokens);
    f.num(root.context_local_tokens);
    f.num(protocol_seq.current());
    f.json(Value{ .array = root.messages });
    return f.final();
}

/// Save the conversation (messages + provider id/model + strict flag) to
/// <name>.session.json in the cwd. The JSON message array is already the
/// provider-native wire shape, so resume is a verbatim restore.
///
/// Synchronous, exactly like the pre-#273 save: the bytes are on disk (and any
/// failure is reported) by the time this returns. The TURN path uses
/// saveSessionAsync instead — see that function.
pub fn saveSession(root: *Agent, arena: Allocator, name: []const u8) !void {
    const ticket = queueSave(root, arena, .cwd(), name) catch |err| {
        flushSaves();
        return err;
    };
    // Unconditional, so /clear, /new, /save and the exit save all drain even
    // when this session had nothing new of its own to write.
    flushSaves();
    // Only THIS save's outcome: a background autosave that failed two turns ago
    // is not /save's failure, and reporting it as one made /save print "save
    // failed" (and skip the rename) for a file it had just written correctly.
    if (session_writer.errorFor(ticket)) |err| return err;
}

/// #273: the interactive turn path's save. Skips entirely when nothing changed,
/// serializes here (root.messages is live, unlocked agent state and must not be
/// read from another thread), and leaves only the disk write in the background.
///
/// Callers MUST guarantee a drain before the process can exit — mainloop.run
/// defers flushSaves(), and every other saver in the harness is the synchronous
/// saveSession above.
pub fn saveSessionAsync(root: *Agent, arena: Allocator, name: []const u8) !void {
    _ = try queueSave(root, arena, .cwd(), name);
}

/// Wait for any queued save to reach disk. The exit/quit/switch bound on how
/// long a background write may lag the conversation.
pub fn flushSaves() void {
    session_writer.drain();
}

/// The same drain, named for the one caller that is a TEARDOWN step: the defer
/// mainloop.run registers, and therefore the first thing the quit path does.
/// Separate from `flushSaves` only so the #364 phase stamp marks that drain and
/// not the dozen mid-session ones `saveSession` performs (a teardown log that
/// also fires during the conversation cannot answer "did the loop exit?").
pub fn flushSavesAtExit() void {
    shutdown_trace.mark("loop-exit: draining queued autosaves");
    flushSaves();
}

/// The save itself, against an explicit base directory. Production always
/// passes the cwd (through saveSessionAsync/saveSession); the parameter exists
/// so the tests can exercise the real path against a tmp dir.
pub fn saveSessionTo(root: *Agent, arena: Allocator, dir: Io.Dir, name: []const u8) !void {
    _ = try queueSave(root, arena, dir, name);
}

/// `saveSessionTo` plus the writer ticket for the save it queued — 0 when
/// nothing needed writing. A synchronous caller keeps the ticket so it can ask
/// `session_writer.errorFor` about ITS OWN write and not about someone else's.
fn queueSave(root: *Agent, arena: Allocator, dir: Io.Dir, name: []const u8) !u64 {
    // #184: delay durable session creation until the conversation has meaningful
    // state — never leave a blank draft as an "Untitled session" on disk. Existing
    // files are untouched (we skip the write, we do not delete).
    if (!hasMeaningfulState(root)) return 0;
    // #273: nothing has changed since the last successful write of this session
    // AND that write is still what the file holds (a second graff, an editor or
    // an rm all invalidate it — the skip is never taken on trust).
    const fp = fingerprint(root, name);
    const rel = try sessionPath(arena, name);
    if (session_writer.alreadySaved(root.io, dir, rel, fp)) return 0;
    // #441: the same observation point, one line per new message, appended to a
    // file this function's in-place rewrite of `messages` can never reach.
    session_transcript.record(root, dir, name);
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
        try s.objectField("standing"); // a --goal objective resumes as one: the model still cannot retire it (#318)
        try s.write(g.standing);
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
        // #394: only when set, so a session with no retired history is written
        // exactly as before and older builds read it back unchanged.
        if (t.retired) {
            try s.objectField("retired");
            try s.write(true);
        }
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
    // #330: the --json protocol sequence high-water mark. A REPLACEMENT graff
    // resuming this session continues the numbering from here instead of
    // reissuing ids the supervisor has already read off the event log.
    try s.objectField("event_seq");
    try s.write(@min(protocol_seq.current(), @as(u64, std.math.maxInt(i64))));
    // kimi-code/codex key cache affinity on the durable conversation id; persisting ours keeps /resume warm.
    try s.objectField("cache_key");
    try s.write(http_headers.sessionId(root.io));
    try s.endObject();

    // #289: two graffs in one workspace share this file — the writer makes the
    // parent dirs and takes an exclusive advisory lock, so the loser reports.
    // #273: it does that on its own thread, and owns these bytes from here.
    const path = try root.gpa.dupe(u8, rel);
    errdefer root.gpa.free(path); // only reachable if toOwnedSlice fails: submit owns both
    return session_writer.submit(root.gpa, root.io, dir, path, try aw.toOwnedSlice(), fp);
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
        const standing = if (go.get("standing")) |b| (b == .bool and b.bool) else false; // absent in legacy sessions: a /goal objective the model may retire (#318)
        return .{ .objective = objective, .status = st, .epoch = ep, .standing = standing, .created_ms = cms, .updated_ms = ums };
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
        // Absent in sessions written before #394: those items are live, and the
        // first new ask retires them if they turn out to be a finished list.
        const retired = if (item.object.get("retired")) |r| (r == .bool and r.bool) else false;
        try todos.append(arena, .{ .content = content, .status = status, .epoch = epoch, .retired = retired });
    }
}

pub fn contextTokensFromSession(obj: std.json.ObjectMap) u64 {
    const v = obj.get("context_tokens") orelse return 0;
    if (v != .integer or v.integer <= 0) return 0;
    return @intCast(v.integer);
}

/// The persisted prompt-cache key; absent/malformed in pre-cache sessions, whose resume mints a fresh one as before.
pub fn cacheKeyFromSession(obj: std.json.ObjectMap) ?[]const u8 {
    const v = obj.get("cache_key") orelse return null;
    return if (v == .string and v.string.len == 36) v.string else null;
}
/// The persisted --json sequence high-water mark (#330); 0 for sessions saved
/// before it existed, so a resume of one starts the numbering fresh.
pub fn eventSeqFromSession(obj: std.json.ObjectMap) u64 {
    const v = obj.get("event_seq") orelse return 0;
    if (v != .integer or v.integer <= 0) return 0;
    return @intCast(v.integer);
}

pub fn contextLocalTokensFromSession(obj: std.json.ObjectMap) ?u64 {
    const v = obj.get("context_local_tokens") orelse return null;
    if (v != .integer or v.integer < 0) return null;
    return @intCast(v.integer);
}

pub fn restoreContextMeter(root: *Agent, saved_context_tokens: u64, saved_local_tokens: ?u64) void {
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
    flushSaves(); // #273: a session switch never leaves the outgoing one queued
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
    // #330: continue the protocol sequence rather than restarting at 1. restore()
    // only ever raises the counter, so a legacy session (no field) or a corrupt
    // negative value simply leaves this process's numbering alone.
    protocol_seq.restore(eventSeqFromSession(obj));
    if (cacheKeyFromSession(obj)) |k| http_headers.adoptSessionId(k);

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
    // The completion double-check is per-PROCESS state and leaked across /resume
    // (#318): an arm left by a refusal in the previous session short-circuited the
    // first attempt_completion of the resumed one, closing its goal unchecked.
    root.completion_gate_armed = false;
    root.completion_refused = false;
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
    // A restored history is a DIFFERENT conversation, not an extension, and
    // codex_chain.usable detects no identity swap - it would chain onto the old one.
    root.closeCodexWs();
    root.compact_transport_failures = 0;
    root.last_usage_includes_output = false;
    root.last_request_context_overflow = false;
    root.last_request_write_failed = false;
    root.fallback_active = false;
    root.fallback_blocked = false;
}
