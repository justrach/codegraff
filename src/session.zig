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
const subagent_ledger = @import("subagent_ledger.zig"); // #753: persist background-agent handles
const shutdown_trace = @import("shutdown_trace.zig"); // #364: teardown phase stamps
const protocol_seq = @import("protocol_seq.zig"); // #330: the --json event sequence survives a resume
const http_headers = @import("http_headers.zig"); // the k3/codex prompt-cache key survives one too
const session_transcript = @import("session_transcript.zig"); // #441: the append-only history this file's rewrites discard
const session_peer = @import("session_peer.zig"); // ADR 0014: room cursor + inbox ride the session file
const tool_call_args = @import("tool_call_args.zig"); // #752: quarantine truncated tool-call arguments on resume
const Agent = agent_mod.Agent;
const Keys = provider_mod.Keys;
const unixMs = util.unixMs;
const utf8Prefix = util.utf8Prefix;

// The session INDEX (paths + the /sessions listing) lives in session_index.zig
// so this file stays under the 600-line cap. Re-exported: callers keep using
// `session.sessionPath`, `session.listSavedSessions`, and friends.
const session_index = @import("session_index.zig");
pub const session_ext = session_index.session_ext;
pub const sessions_dir = session_index.sessions_dir;
pub const sessionPath = session_index.sessionPath;
pub const validSessionName = session_index.validSessionName;
pub const sessionExists = session_index.sessionExists;
pub const SessionMeta = session_index.SessionMeta;
pub const sessionMetaFromBytes = session_index.sessionMetaFromBytes;
pub const sessionMeta = session_index.sessionMeta;
pub const sessionAge = session_index.sessionAge;
pub const SessionEntry = session_index.SessionEntry;
pub const listSavedSessions = session_index.listSavedSessions;
pub const listSavedSessionsAll = @import("session_discovery.zig").listAll;
pub const homeSessionPath = session_index.homeSessionPath;
pub const displayWorkspace = session_index.displayWorkspace;

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
    const next_name = arena.dupe(u8, name) catch return;
    @import("compaction_checkpoint.zig").rename(root, old_name, next_name) catch return;
    root.session_name = next_name;
    @import("subagent_interactive.zig").rename(root.io, old_name, root.session_name);
    saveSession(root, arena, root.session_name) catch {};
    if (sessionPath(arena, old_name)) |op| (Io.Dir.cwd().deleteFile(root.io, op) catch {}) else |_| {}
}

pub fn sessionTitle(root: *Agent) []const u8 {
    if (root.session_title) |title| return title;
    for (root.messages.items) |m| {
        if (m != .object) continue;
        if (!session_peer.isHumanUserTurn(m)) continue;
        if (m.object.get("content")) |c| switch (c) {
            .string => |text| {
                const trimmed = std.mem.trim(u8, text, " \t\r\n");
                if (trimmed.len > 0) return utf8Prefix(trimmed, 80);
            },
            .array => |arr| for (arr.items) |part| {
                if (part == .object) {
                    const typ = if (part.object.get("type")) |v| (if (v == .string) v.string else "") else "";
                    if (std.mem.eql(u8, typ, "text") or std.mem.eql(u8, typ, "input_text")) {
                        if (part.object.get("text")) |tv| if (tv == .string) {
                            const trimmed = std.mem.trim(u8, tv.string, " \t\r\n");
                            if (trimmed.len > 0) return utf8Prefix(trimmed, 80);
                        };
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
///   - a non-empty todo list,
///   - recorded tool activity this session, or
///   - a server compaction blob. In-stream compaction prunes every prompt
///     before the blob, so a text-only turn that compacted has no user
///     message left; the blob carries it.
/// A truly blank draft (no user turn, no goal, no todos, no tools) is NOT
/// meaningful, so saveSession skips it rather than leaving an "Untitled
/// session" file on disk (#184). Callers that only want to avoid the blank-draft
/// write get this for free by going through saveSession.
pub fn hasMeaningfulState(root: *Agent) bool {
    if (root.goal != null) return true;
    if (root.todos.items.len > 0) return true;
    if (root.tools_used.entries.items.len > 0) return true;
    if (@import("compaction_window.zig").latestBlob(root.messages.items) != null) return true;
    for (root.messages.items) |m| {
        if (m != .object) continue;
        if (session_peer.isHumanUserTurn(m)) return true;
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
        f.text(t.reason); // #1520
    }
    if (root.session_parent) |parent| f.text(parent) else f.flag(false);
    f.text(root.session_title orelse sessionTitle(root));
    // The persisted meter's two inputs. Its third (system prompt + tool schema
    // size) shifts `context_tokens` and `context_local_tokens` together, and
    // resume only keeps their difference, so it cannot change what a resume
    // restores and is deliberately left out.
    f.num(root.last_context_tokens);
    f.num(root.context_local_tokens);
    f.num(protocol_seq.current());
    f.json(Value{ .array = root.messages });
    @import("session_catalog.zig").mixFingerprint(root, &f);
    f.text(@import("session_prompt.zig").snapshot(root) orelse "");
    session_peer.mixFingerprint(&f);
    subagent_ledger.mixFingerprint(&f);
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
    var scratch_state = std.heap.ArenaAllocator.init(root.gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const base = try dir.realPathFileAlloc(root.io, ".", scratch);
    @import("session_workspaces.zig").remember(root.io, arena, root.home, base);
    const rel = try sessionPath(scratch, name);
    const path = try std.fmt.allocPrint(root.gpa, "{s}/{s}", .{ std.mem.trimEnd(u8, base, "/\\"), rel });
    errdefer root.gpa.free(path);
    // #273: nothing has changed since the last successful write of this session
    // AND that write is still what the file holds (a second graff, an editor or
    // an rm all invalidate it — the skip is never taken on trust).
    const fp = fingerprint(root, name);
    if (session_writer.alreadySaved(root.io, dir, path, fp)) {
        root.gpa.free(path);
        return 0;
    }
    // #441: the same observation point, one line per new message, appended to a
    // file this function's in-place rewrite of `messages` can never reach.
    session_transcript.record(root, dir, name);
    const saved_msgs = try session_peer.messagesForSave(scratch, root.messages.items);
    var snapshot = try @import("session_snapshot.zig").prepare(root.gpa, saved_msgs.items);
    errdefer snapshot.deinit();
    const metadata = try @import("session_serialize.zig").metadata(root, scratch, saved_msgs, snapshot.message_bytes, sessionTitle(root));
    const marker = std.mem.indexOf(u8, metadata, "\"messages\":[]") orelse unreachable;
    snapshot.setMetadata(metadata, marker + "\"messages\":".len);
    return session_writer.submitSnapshot(root.gpa, root.io, dir, path, snapshot, fp, root.home);
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
        const content = if (item.object.get("content")) |c| (if (c == .string) try arena.dupe(u8, c.string) else continue) else continue;
        const status = if (item.object.get("status")) |s| (if (s == .string) try arena.dupe(u8, s.string) else "pending") else "pending";
        const epoch: u64 = if (item.object.get("epoch")) |e| (if (e == .integer and e.integer >= 0) @intCast(e.integer) else 0) else 0;
        // Absent in sessions written before #394: those items are live, and the
        // first new ask retires them if they turn out to be a finished list.
        const retired = if (item.object.get("retired")) |r| (r == .bool and r.bool) else false;
        const reason = if (item.object.get("reason")) |r| (if (r == .string and r.string.len > 0) try arena.dupe(u8, r.string) else "") else "";
        try todos.append(arena, .{ .content = content, .status = status, .epoch = epoch, .retired = retired, .reason = reason });
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

/// Git-root prompt-cache partition. Absent on pre-idle-park saves.
pub fn promptCacheKeyFromSession(obj: std.json.ObjectMap) ?[]const u8 {
    const v = obj.get("prompt_cache_key") orelse return null;
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

/// Restore a saved session: parse the file in a scoped scratch arena (#1858),
/// rebuild the provider, and replace the live history without retaining the raw
/// file bytes or JSON parse tree in `arena`.
pub fn loadSession(root: *Agent, keys: *Keys, arena: Allocator, name: []const u8) !void {
    flushSaves(); // #273: a session switch never leaves the outgoing one queued
    var load_scratch = std.heap.ArenaAllocator.init(root.gpa);
    defer load_scratch.deinit();
    const scratch = load_scratch.allocator();
    const found = @import("session_discovery.zig").locate(root, scratch, name) orelse return error.FileNotFound;
    try @import("session_store.zig").recover(root.io, root.gpa, .cwd(), found.path);
    const data = Io.Dir.cwd().readFileAlloc(root.io, found.path, scratch, .limited(session_index.max_session_bytes)) catch |err|
        return if (err == error.StreamTooLong) error.SessionTooLarge else error.FileNotFound;
    const parsed = try std.json.parseFromSliceLeaky(Value, scratch, data, .{ .allocate = .alloc_always });
    if (parsed != .object) return error.BadSession;
    var obj = parsed.object;
    try @import("session_version.zig").upgrade(scratch, &obj); // ADR 0319: a newer format is refused before any state changes
    const pid = if (obj.get("provider")) |v| (if (v == .string) try arena.dupe(u8, v.string) else return error.BadSession) else return error.BadSession;
    const model = if (obj.get("model")) |v| (if (v == .string) try arena.dupe(u8, v.string) else return error.BadSession) else return error.BadSession;
    var msgs = if (obj.get("messages")) |v| (if (v == .array) v.array else return error.BadSession) else return error.BadSession;
    const claude_import = if (obj.get("imported_from")) |v| v == .string and std.mem.eql(u8, v.string, "claude") else false;
    const strict = if (obj.get("strict")) |v| (v == .bool and v.bool) else false;
    const ultracode_mode = if (obj.get("ultracode_mode")) |v| (v == .bool and v.bool) else false;
    var goal: ?agent_mod.Goal = if (obj.get("goal")) |v| goalFromValue(v, unixMs(root.io)) else null;
    if (goal) |*g| g.objective = try arena.dupe(u8, g.objective);
    const parent = if (obj.get("parent")) |v| (if (v == .string and v.string.len > 0) try arena.dupe(u8, v.string) else null) else null;
    // Older builds missed Responses input_text and persisted the placeholder.
    const title = if (obj.get("title")) |v| (if (v == .string and v.string.len > 0 and !std.mem.eql(u8, v.string, "Untitled session")) try arena.dupe(u8, v.string) else null) else null;
    // Optional for backward compatibility with sessions written before context
    // metering was persisted. JSON integers are signed; ignore negative/wrong-type
    // values instead of turning a corrupt session into an enormous unsigned count.
    const saved_context_tokens = contextTokensFromSession(obj);
    const saved_local_tokens = contextLocalTokensFromSession(obj);
    // #330: continue the protocol sequence rather than restarting at 1. restore()
    // only ever raises the counter, so a legacy session (no field) or a corrupt
    // negative value simply leaves this process's numbering alone.
    protocol_seq.restore(eventSeqFromSession(obj));
    if (cacheKeyFromSession(obj)) |k| http_headers.restoreSessionId(k);
    if (promptCacheKeyFromSession(obj)) |k| http_headers.restoreProjectRootId(k);

    // #1556: an explicit cross-provider --model launch skipped this plan login.
    if (!claude_import) @import("credential_failover.zig").preferPlanFor(root.io, root.gpa, root.arena, root.home, keys, pid);
    if (keys.get(pid) == null) root.ensureStoredKeys(keys);
    if (!claude_import) {
        if (std.mem.eql(u8, pid, "codex")) root.ensureModelCatalog(keys.*);
        root.provider = try keys.providerById(pid, model);
    } else {
        // The source route is metadata. Import history into the configured
        // graff provider without resolving any credentials for Claude Code.
        msgs = try @import("adopt_conversation.zig").forProvider(scratch, msgs, root.provider.kind);
    }
    // A resumed session may use a different wire format than the startup
    // default. Materialize that catalog before rebasing its saved context
    // meter, and keep every still-unused format lazy.
    try @import("session_prompt.zig").restore(root, obj);
    try @import("session_catalog.zig").restore(root, obj);
    try root.ensureRootTools(root.provider.kind);
    const compaction_window = try @import("compaction_window.zig").State.restore(scratch, obj, msgs.items);
    root.messages = msgs;
    root.compaction_window = compaction_window;
    @import("history_wire.zig").prepare(scratch, root.provider.kind, &root.messages);
    // #752: truncated `function.arguments` strings 400 every later request.
    tool_call_args.repairHistory(root.gpa, scratch, root.messages.items);
    if (@import("main.zig").g_session_arena != null and !root.sub) {
        root.reclaimMessages();
    } else {
        var cloned = try std.json.Array.initCapacity(arena, root.messages.items.len);
        for (root.messages.items) |m| cloned.appendAssumeCapacity(try util.dupeJsonValue(arena, m));
        root.messages = cloned;
    }
    root.strict = strict;
    root.ultracode_mode = ultracode_mode;
    root.goal = goal;
    root.todos.clearRetainingCapacity(); // never inherit another conversation's checklist (#318)
    if (obj.get("todos")) |tv| try appendTodosFromValue(arena, &root.todos, tv);
    root.todos_dirty = false; // restored todos are persisted state, never this-process completion evidence (#318)
    // The completion double-check is per-PROCESS state (#318): a leftover arm
    // short-circuited the resumed session's first attempt_completion.
    root.completion_gate_armed = false;
    root.completion_refused = false;
    // #318: retire a restored-active goal whose checklist is already finished.
    if (goal_state.reconcileRestored(root)) if (root.tracer) |t| t.note("goal", "reconciled-complete");
    // Steering gate state belongs to the previous conversation (#318): drop any
    // queued one-shot note and force a full goal-note re-statement next turn.
    root.pending_goal_note = null;
    root.goal_note_fp = 0;
    root.goal_note_age = 0;
    root.session_parent = parent;
    root.session_title = title;
    // #1686: reapply the saved count of this exact compaction state first, so
    // the rebased meter does not fall back to bytes/16 in a new process.
    @import("opaque_state_persist.zig").restore(root.provider, .{ .array = root.messages }, obj);
    // Rebase the saved server-only delta onto today's prompt/tool-schema input.
    restoreContextMeter(root, saved_context_tokens, saved_local_tokens);
    root.cap_new = false; // per-provider (like sox/effort below); relearn on rejection
    root.sox_json_object = false; // #543
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
    session_peer.restore(root, obj);
    subagent_ledger.restore(root.gpa, root.io, obj.get("background_agents"));
    const subagent = @import("subagent.zig");
    if (subagent_ledger.nextId() > subagent.g_agent_jobs.next_id)
        subagent.g_agent_jobs.next_id = subagent_ledger.nextId();
    // ADR 0218: background jobs that outlived the last graff come back.
    @import("job_recover.zig").onLoad(root.gpa, root.io, name);
}
