//! Task-scope enforcement for cross-session inspection vs recruitment (#1807)
//! and verified user-facing session/chat locator reporting (#1755).

const std = @import("std");
const Allocator = std.mem.Allocator;
const tools = @import("tools.zig");
const ToolCtx = tools.ToolCtx;
const ToolCall = tools.ToolCall;
const ToolOutput = tools.ToolOutput;
const util = @import("util.zig");

pub const refusal_text =
    "peer scope (#1807): the current request is a read-only trajectory/session inspection " ++
    "and does not authorize waking, steering, or recruiting an independent chat as a worker. " ++
    "Inspect available transcripts, traces, and tool results locally in this session, or ask " ++
    "the user before expanding scope to message that chat.";

/// True when `ask` is an inspection/analysis/review/lookup request targeting a
/// recorded chat, session, trajectory, or transcript without explicit permission
/// to message, wake, steer, or delegate work to that chat (#1807).
pub fn isReadOnlySessionInspection(ask: []const u8) bool {
    if (ask.len == 0) return false;
    const targets = [_][]const u8{
        "trajectory",   "trajectories",  "transcript", "transcripts",
        "session",      "sessions",      "chat",       "chats",
        "conversation", "conversations",
    };
    var has_target = false;
    for (targets) |t| {
        if (util.indexOfIgnoreCase(ask, t) != null) {
            has_target = true;
            break;
        }
    }
    if (!has_target) return false;

    const inspect_terms = [_][]const u8{
        "inspect",       "analyze",   "analyse",    "analysis",
        "review",        "diagnose",  "diagnostic", "investigate",
        "read-only",     "read only", "root cause", "root-cause",
        "find evidence", "locate",    "look at",    "examine",
    };
    var has_inspect = false;
    for (inspect_terms) |term| {
        if (util.indexOfIgnoreCase(ask, term) != null) {
            has_inspect = true;
            break;
        }
    }
    if (!has_inspect) return false;

    const auth_terms = [_][]const u8{
        "send_message", "peer_message", "/tell",     "/daddy",
        "message ",     "ping ",        "wake ",     "steer ",
        "direct ",      "delegate to",  "delegate ", "coordinate with",
        "hand off",     "handoff",      "ask chat",  "ask session",
        "tell chat",    "tell session", "recruit ",  "collaborate with",
    };
    for (auth_terms) |auth| {
        if (util.indexOfIgnoreCase(ask, auth) != null) return false;
    }
    return true;
}

pub fn checkPeerSend(ask: []const u8, fyi: bool) ?[]const u8 {
    if (fyi) return null;
    if (isReadOnlySessionInspection(ask)) return refusal_text;
    return null;
}

pub fn isMcpPeerWriteTool(name: []const u8) bool {
    const bare = if (std.mem.lastIndexOf(u8, name, "__")) |idx| name[idx + 2 ..] else name;
    return std.mem.eql(u8, bare, "send_message") or
        std.mem.eql(u8, bare, "steer_chat") or
        std.mem.eql(u8, bare, "queue_message") or
        std.mem.eql(u8, bare, "direct_chat");
}

pub fn gateExec(ctx: ToolCtx, call: ToolCall) ?ToolOutput {
    if (!isMcpPeerWriteTool(call.name)) return null;
    const raw = @import("shapes.zig").rawAsk();
    if (!isReadOnlySessionInspection(raw)) return null;
    const text = ctx.gpa.dupe(u8, refusal_text) catch return .{ .text = &.{}, .is_error = true };
    return .{ .text = text, .is_error = true };
}

// ── #1755: Verified user-facing chat/session locator resolution ────────────

pub const ChatCandidate = struct {
    chat_id: []const u8,
    title: []const u8,
    archived: bool = false,
    latest_preview: []const u8 = "",
    transcript_body: []const u8 = "",
    engine_session_id: ?[]const u8 = null,
};

pub const LocatorResolution = union(enum) {
    resolved: struct {
        chat_id: []const u8,
        title: []const u8,
        archived: bool,
    },
    unresolved_engine_id: []const u8,
    not_found,
};

/// Resolve a conversation locator from candidate chats (#1755).
/// Never returns a bare internal engine-session ID as a usable chat locator,
/// and inspects full transcript bodies when listing metadata (generic title /
/// unrelated latest preview) does not match.
pub fn resolveConversationLocator(
    candidates: []const ChatCandidate,
    query_needle: []const u8,
    engine_id_hint: ?[]const u8,
) LocatorResolution {
    // 1. Check if any candidate matches by engine_id_hint AND has a real chat_id + title.
    if (engine_id_hint) |eng_id| {
        for (candidates) |c| {
            if (c.engine_session_id) |cid| {
                if (std.mem.eql(u8, cid, eng_id) and c.chat_id.len > 0 and c.title.len > 0) {
                    if (query_needle.len == 0 or
                        util.indexOfIgnoreCase(c.title, query_needle) != null or
                        util.indexOfIgnoreCase(c.latest_preview, query_needle) != null or
                        util.indexOfIgnoreCase(c.transcript_body, query_needle) != null)
                    {
                        return .{ .resolved = .{
                            .chat_id = c.chat_id,
                            .title = c.title,
                            .archived = c.archived,
                        } };
                    }
                }
            }
        }
    }
    // 2. Search candidate titles, previews, and full transcript bodies.
    if (query_needle.len > 0) {
        for (candidates) |c| {
            if (c.chat_id.len == 0 or c.title.len == 0) continue;
            if (util.indexOfIgnoreCase(c.title, query_needle) != null or
                util.indexOfIgnoreCase(c.latest_preview, query_needle) != null or
                util.indexOfIgnoreCase(c.transcript_body, query_needle) != null)
            {
                return .{ .resolved = .{
                    .chat_id = c.chat_id,
                    .title = c.title,
                    .archived = c.archived,
                } };
            }
        }
    }
    if (engine_id_hint) |eng_id| {
        if (eng_id.len > 0) return .{ .unresolved_engine_id = eng_id };
    }
    return .not_found;
}

pub fn formatLocatorResult(arena: Allocator, res: LocatorResolution) ![]u8 {
    return switch (res) {
        .resolved => |r| std.fmt.allocPrint(
            arena,
            "chat \"{s}\" (id: {s}{s})",
            .{ r.title, r.chat_id, if (r.archived) ", archived" else "" },
        ),
        .unresolved_engine_id => |eng_id| std.fmt.allocPrint(
            arena,
            "mapping unresolved for internal engine session \"{s}\": open candidate chats with get_chat/read_chat to verify the user-facing chat ID and title rather than presenting the engine ID alone or claiming the title is unrecoverable",
            .{eng_id},
        ),
        .not_found => arena.dupe(u8, "no matching chat found in inspected listings or transcripts"),
    };
}

test "#1807 read-only trajectory analysis refuses recruiting an independent chat while preserving explicit collaboration" {
    const ro_ask = "Inspect the recorded trajectory of chat B and find concrete root-cause evidence for the tool-selection problem.";
    try std.testing.expect(isReadOnlySessionInspection(ro_ask));
    try std.testing.expect(checkPeerSend(ro_ask, false) != null);
    try std.testing.expect(checkPeerSend(ro_ask, true) == null);

    const collab_ask = "Inspect chat B's trajectory and message chat B to run a local diagnostic check.";
    try std.testing.expect(!isReadOnlySessionInspection(collab_ask));
    try std.testing.expect(checkPeerSend(collab_ask, false) == null);

    try std.testing.expect(isMcpPeerWriteTool("send_message"));
    try std.testing.expect(isMcpPeerWriteTool("mcp__harness__send_message"));
    try std.testing.expect(!isMcpPeerWriteTool("get_chat"));
    try std.testing.expect(!isMcpPeerWriteTool("read_chat"));
}

test "#1755 archived chat with generic title and unrelated preview resolves from transcript body and never returns bare engine session ID" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const candidates = [_]ChatCandidate{
        .{
            .chat_id = "chat-unrelated-1",
            .title = "Refactor parser",
            .archived = false,
            .latest_preview = "all parser unit tests green",
            .transcript_body = "user: refactor parser.zig",
            .engine_session_id = "eng-sess-1111",
        },
        .{
            .chat_id = "chat-archived-target-42",
            .title = "New conversation",
            .archived = true,
            .latest_preview = "sounds good, thanks",
            .transcript_body = "user: implement incremental snapshot chunk reuse for #1859\nassistant: landed in session_snapshot.zig",
            .engine_session_id = "eng-sess-9f2a",
        },
    };

    // Resolving by topical work in earlier messages + PR ownership engine ID hint
    // returns the verified Harness chat title, chat ID, and archived status.
    const found = resolveConversationLocator(&candidates, "snapshot chunk reuse", "eng-sess-9f2a");
    const formatted = try formatLocatorResult(a, found);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "New conversation") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "chat-archived-target-42") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "archived") != null);

    // When only an unmapped internal engine ID is known, it reports the
    // unresolved mapping honestly rather than presenting the engine ID as a
    // chat locator or claiming the title cannot be recovered.
    const unmapped = resolveConversationLocator(&candidates, "nonexistent-topic-xyz", "eng-sess-unmapped");
    const unmapped_text = try formatLocatorResult(a, unmapped);
    try std.testing.expect(std.mem.indexOf(u8, unmapped_text, "mapping unresolved") != null);
    try std.testing.expect(std.mem.indexOf(u8, unmapped_text, "get_chat/read_chat") != null);
}
