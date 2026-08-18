//! The #469 channel half: what co-resident root sessions SAY to each other,
//! on top of what presence.zig knows (WHO is out there, liveness-probed).
//!
//! Four surfaces, one inbox primitive:
//!   - peer_message: the model-facing tool, so a session can coordinate the
//!     way a parent steers a subagent — "I'm restructuring gui/src, hold" —
//!     except sideways, between roots. Queued, one-way, never synchronous.
//!   - /tell <session> <text>: the user's own line into a peer's inbox.
//!   - /sessions: the saved-session list gains a "live now" section.
//!   - deliverInbound: drains the channel at every step boundary of the turn
//!     loop (agent.runTurn), so a peer's message lands mid-task — between tool
//!     batches — as a first-class note, durable in history and visible to the
//!     user as an event. True mid-request injection (interrupting a streamed
//!     response) remains #430 territory; step boundaries are the safe seams.

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const tools_mod = @import("tools.zig");
const engine_sink = @import("engine_sink.zig");
const presence = @import("presence.zig");
const presence_chan = @import("presence_chan.zig");
const worktree_lease = @import("worktree_lease.zig");
const repl = @import("repl.zig");
const peer_context = @import("peer_context.zig");

const Agent = agent_mod.Agent;
const ToolCall = tools_mod.ToolCall;
const ExecResult = tools_mod.ExecResult;
const Owner = worktree_lease.Owner;

pub const tool_name = "peer_message";
pub const tool_desc = "Post a message to the shared graff channel: live graff sessions hear it at their next step boundary, stamped with your session name and current goal. Use it to coordinate the way you would steer a subagent, but sideways: announce what you are restructuring, ask the others to hold off a directory, or split the work. Hearing is folder-scoped: bare posts go to this folder's room and every session in it hears them; `session` names one intended recipient (name substring, possibly in another folder) — a cross-folder post is delivered to the addressed session only, never broadcast. Device-wide broadcast is the user's /tell all, not this tool. Delivery is queued and one-way — the tool result only confirms the post, never a reply.";
pub const tool_schema =
    \\{"type": "object", "properties": {"session": {"type": "string", "description": "peer session name substring (omit for this folder's room). A name in another folder is a DM via the device room, delivered to that session only. Not \"all\" — device-wide broadcast is the user's /tell all"}, "text": {"type": "string", "description": "one or two sentences of coordination intent"}}, "required": ["text"]}
;

/// Resolve the one peer a message is for. `want` is a session-name substring
/// or a decimal pid; empty wants exactly one live peer.
fn resolvePeer(peers: []const Owner, want: []const u8) union(enum) { one: Owner, none, ambiguous } {
    if (want.len == 0) return if (peers.len == 1) .{ .one = peers[0] } else if (peers.len == 0) .none else .ambiguous;
    var found: ?Owner = null;
    var count: usize = 0;
    for (peers) |p| {
        const pid_match = std.fmt.parseInt(i32, want, 10) catch null;
        const named = std.mem.indexOf(u8, p.session_id, want) != null;
        if (named or (pid_match != null and pid_match.? == p.pid)) {
            found = p;
            count += 1;
        }
    }
    if (count == 1) return .{ .one = found.? };
    return if (count == 0) .none else .ambiguous;
}

/// Whether the named session sits in MY worktree (routes the post: worktree
/// room when local, device room when not).
fn isLocal(peers: []const Owner, session_id: []const u8, my_identity: []const u8) bool {
    for (peers) |p| {
        if (std.mem.eql(u8, p.session_id, session_id)) return std.mem.eql(u8, p.identity, my_identity);
    }
    return true;
}

fn peerListText(arena: Allocator, peers: []const Owner) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (peers) |p| {
        const line = std.fmt.allocPrint(arena, "\"{s}\" (pid {d}, goal: {s})", .{ p.session_id, p.pid, if (p.goal.len > 0) p.goal else "?" }) catch continue;
        buf.appendSlice(arena, line) catch {};
        buf.appendSlice(arena, ", ") catch {};
    }
    const items = buf.items;
    return if (items.len >= 2) items[0 .. items.len - 2] else items;
}

pub fn handleMessage(self: *Agent, call: ToolCall) !ExecResult {
    const obj = tools_mod.json_args.object(call.input) orelse return .{
        .text = "peer_message needs an object input with a text field",
        .is_error = true,
    };
    const text = tools_mod.json_args.str(obj, "text") orelse "";
    if (text.len == 0) return .{ .text = "peer_message: empty text — say what you want the peer to know", .is_error = true };
    const want = tools_mod.json_args.str(obj, "session") orelse "";
    const local = presence.liveTreePeers(self.io, self.arena);
    if (want.len == 0 and local.len == 0) return .{
        .text = "no live co-resident graff sessions in this worktree — the presence registry says you are alone here (a peer shows up via the startup warning when one starts)",
        .is_error = true,
    };
    // Routing: bare posts stay in the worktree room; a named target in
    // another folder rides the device room, delivered to the addressed
    // session only. Model broadcasts are rejected: unaddressed "all" posts
    // flooded every folder on the device with another room's coordination —
    // device-wide broadcast is the user's channel (/tell all).
    if (std.mem.eql(u8, want, "all")) return .{
        .text = "\"all\" is retired for sessions — hearing is folder-scoped now. Post bare for this folder's room, or name one session (possibly in another folder) to reach it directly.",
        .is_error = true,
    };
    // `session` is validated so a mistyped target errors usefully, but every
    // peer hears the post either way — the channel is a room, not a DM.
    const to: []const u8 = if (want.len == 0) "" else switch (resolvePeer(presence.liveAllPeers(self.io, self.arena), want)) {
        .one => |p| p.session_id,
        .none => return .{
            .text = try std.fmt.allocPrint(self.arena, "no live peer matches \"{s}\" — live here: {s}", .{ want, peerListText(self.arena, local) }),
            .is_error = true,
        },
        .ambiguous => return .{
            .text = try std.fmt.allocPrint(self.arena, "more than one live peer matches — name one with `session`: {s}", .{peerListText(self.arena, presence.liveAllPeers(self.io, self.arena))}),
            .is_error = true,
        },
    };
    const cross_folder = to.len > 0 and !isLocal(presence.liveAllPeers(self.io, self.arena), to, presence.ownIdentity());
    const posted = if (cross_folder)
        presence.postToDevice(self.io, self.arena, text, to, false)
    else
        presence.postTo(self.io, self.arena, text, to);
    if (!posted) return .{
        .text = "delivery failed — the presence registry is unavailable (this session may never have announced itself)",
        .is_error = true,
    };
    const addressed = if (to.len > 0) try std.fmt.allocPrint(self.arena, " (for \"{s}\")", .{to}) else "";
    const room: []const u8 = if (cross_folder) "device room, delivered to the addressed session only" else "worktree channel";
    return .{
        .text = try std.fmt.allocPrint(self.arena, "posted to the {s}{s} — live peer(s) hear it at their next step boundary. Delivery is one-way: any answer arrives the same way.", .{ room, addressed }),
        .is_error = false,
    };
}

var g_peer_fp: u64 = 0; // fingerprint of the last-injected awareness note
var g_peer_note_rewrites: u64 = 0; // history_rewrites when it was injected

/// The proactive half of #469: the model can only auto-decide to coordinate
/// with sessions it KNOWS about — this renders the live peer set (who, where,
/// what goal) as a context note. Returned only when the set changed since the
/// last injection, or a history rewrite may have compacted the note away, so
/// a steady peer set costs zero tokens. Null while the device has no peers at
/// all and none were ever announced — solo sessions never hear about this.
fn peerNoteIfChanged(root: *Agent) ?[]const u8 {
    const peers = presence.liveAllPeers(root.io, root.arena);
    if (peers.len == 0 and g_peer_fp == 0) return null;
    var buf: std.ArrayList(u8) = .empty;
    if (peers.len == 0) {
        buf.appendSlice(root.arena, "[presence] the other live graff sessions are gone — the shared tree is yours alone now.") catch return null;
    } else {
        const mine = presence.ownIdentity();
        buf.appendSlice(root.arena, std.fmt.allocPrint(root.arena, "[presence] {d} other live graff session(s):", .{peers.len}) catch return null) catch return null;
        for (peers) |p| {
            const where: []const u8 = if (std.mem.eql(u8, p.identity, mine)) "this folder" else p.identity;
            const goal = peer_context.clip(if (p.goal.len > 0) p.goal else "?", 40);
            buf.appendSlice(root.arena, std.fmt.allocPrint(root.arena, " {s} ({s}, {s});", .{ p.session_id, goal, where }) catch break) catch break;
        }
        buf.appendSlice(root.arena, " Coordinate with peer_message before touching shared files — bare post = this folder's room; name a session to address them.") catch {};
    }
    const text = buf.items;
    const fp = std.hash.Wyhash.hash(0, text);
    if (fp == g_peer_fp and root.history_rewrites == g_peer_note_rewrites) return null;
    g_peer_fp = fp;
    g_peer_note_rewrites = root.history_rewrites;
    return text;
}

/// The receiving half, called at every step boundary of a root agent's turn:
/// queued peer messages plus the peer-awareness note become one durable
/// user-role note in history plus user-visible events. Never fails a turn —
/// delivery trouble is silence, not an error, because a peer must never break
/// our session.
/// The room tail a late joiner hears in full; anything older collapses into
/// one "N omitted" marker instead of flooding the first history note.
pub const backlog_tail_max = 10;
var g_backlog_tail_cut = false;

/// Of a first-drain backlog the REPL prints only this many trailing lines;
/// the rest still lands in history (the model coordinates from it) behind a
/// "delivered to context" marker. Live drains are unaffected.
pub const backlog_repl_show = 2;

const DisplayWindow = struct { start: usize, hidden: usize };

fn displayWindow(is_backlog: bool, count: usize) DisplayWindow {
    if (!is_backlog or count <= backlog_repl_show) return .{ .start = 0, .hidden = 0 };
    return .{ .start = count - backlog_repl_show, .hidden = count - backlog_repl_show };
}

/// Device-room hearing is addressed-only: the line names this session and it
/// arrives whoever posted it. Unaddressed lines cross folders only when the
/// USER broadcast them (/tell all) — a /tell to one named graff is a DM, and
/// a session's unaddressed device line is dropped.
pub fn deviceHears(m: presence.Message, own: []const u8) bool {
    if (m.to.len > 0 and own.len > 0 and
        (std.mem.indexOf(u8, m.to, own) != null or std.mem.indexOf(u8, own, m.to) != null)) return true;
    return m.from_user and m.to.len == 0;
}

pub fn deliverInbound(root: *Agent) void {
    if (root.sub) return;
    const note = peerNoteIfChanged(root);
    var local_msgs = presence.drainChannel(root.io, root.arena);
    var device_msgs = presence.drainDevice(root.io, root.arena);
    // Only the process's FIRST drain carries the rooms' whole backlog; later
    // drains are incremental and must never be capped — those are live.
    var omitted: usize = 0;
    const is_backlog_drain = !g_backlog_tail_cut;
    if (is_backlog_drain) {
        g_backlog_tail_cut = true;
        const dl = presence_chan.backlogDrop(local_msgs.len, backlog_tail_max);
        const dd = presence_chan.backlogDrop(device_msgs.len, backlog_tail_max);
        omitted = dl + dd;
        local_msgs = local_msgs[dl..];
        device_msgs = device_msgs[dd..];
    }
    if (note == null and local_msgs.len == 0 and device_msgs.len == 0 and omitted == 0) return;
    const sink = engine_sink.forAgent(root);
    const own = presence.ownSession();
    // Device room is folder-scoped: hear what names this session or what the
    // user posted; everything else collapses into one marker below.
    var heard: std.ArrayList(presence.Message) = .empty;
    var skipped: usize = 0;
    for (device_msgs) |m| {
        if (deviceHears(m, own)) heard.append(root.arena, m) catch break else skipped += 1;
    }
    device_msgs = heard.items;
    // The visible block gets one blank line of air on either side: peer lines
    // land mid-stream at a step boundary and used to butt straight against
    // the assistant text above and whatever follows below — one clump.
    const window = displayWindow(is_backlog_drain, local_msgs.len + device_msgs.len);
    const any_visible = local_msgs.len + device_msgs.len > window.start or
        (repl.g_debug and (note != null or omitted > 0 or skipped > 0 or window.hidden > 0));
    var buf: std.ArrayList(u8) = .empty;
    // Debug-only notices ride inside the block's bracket, in drain order.
    var markers: std.ArrayList([]const u8) = .empty;
    if (note) |n| {
        buf.appendSlice(root.arena, n) catch {};
        buf.append(root.arena, '\n') catch {};
        if (repl.g_debug) markers.append(root.arena, n) catch {};
    }
    if (omitted > 0) {
        const marker = std.fmt.allocPrint(root.arena, "[peer channel: {d} older message(s) predating this session omitted]", .{omitted}) catch "";
        if (marker.len > 0) {
            buf.appendSlice(root.arena, marker) catch {};
            buf.append(root.arena, '\n') catch {};
            if (repl.g_debug) markers.append(root.arena, marker) catch {};
        }
    }
    if (skipped > 0) {
        const marker = std.fmt.allocPrint(root.arena, "[peer channel: {d} message(s) not addressed to this session skipped — folder-scoped hearing]", .{skipped}) catch "";
        if (marker.len > 0) {
            buf.appendSlice(root.arena, marker) catch {};
            buf.append(root.arena, '\n') catch {};
            if (repl.g_debug) markers.append(root.arena, marker) catch {};
        }
    }
    var lines: std.ArrayList([]const u8) = .empty;
    const hist = peer_context.historyWindow(is_backlog_drain, local_msgs.len + device_msgs.len);
    if (hist.hidden > 0) {
        const marker = std.fmt.allocPrint(root.arena, "[peer channel: {d} backlog message(s) omitted from context — keeping last {d}]", .{ hist.hidden, peer_context.history_tail_max }) catch "";
        if (marker.len > 0) {
            buf.appendSlice(root.arena, marker) catch {};
            buf.append(root.arena, '\n') catch {};
        }
    }
    var line_i: usize = 0;
    for ([2][]const presence.Message{ local_msgs, device_msgs }, [2][]const u8{ "", " · device" }) |msgs, scope| {
        for (msgs) |m| {
            const goal = if (m.from_goal.len > 0) std.fmt.allocPrint(root.arena, " (goal: {s})", .{peer_context.clip(m.from_goal, 40)}) catch "" else "";
            // Addressing is rendered, not enforced: everyone hears the line,
            // and the marker says who it was meant for.
            const to = if (m.to.len == 0) "" else if (std.mem.indexOf(u8, m.to, own) != null or std.mem.indexOf(u8, own, m.to) != null) " → you" else std.fmt.allocPrint(root.arena, " → {s}", .{m.to}) catch "";
            const line = std.fmt.allocPrint(root.arena, "[peer message from {s}{s}{s}{s}]: {s}", .{ m.from_session, goal, to, scope, peer_context.clip(m.text, peer_context.line_clip) }) catch continue;
            if (line_i >= hist.start) {
                buf.appendSlice(root.arena, line) catch {};
                buf.append(root.arena, '\n') catch {};
            }
            lines.append(root.arena, line) catch {};
            line_i += 1;
        }
    }
    // History gets the working-set tail (ADR 0004); the REPL prints only the
    // last backlog_repl_show of a first-drain so a resume is not a wall.
    if (window.hidden > 0) {
        const marker = std.fmt.allocPrint(root.arena, "[peer channel: {d} backlog message(s) delivered to context — showing last {d}]", .{ window.hidden, backlog_repl_show }) catch "";
        if (marker.len > 0 and repl.g_debug) markers.append(root.arena, marker) catch {};
    }
    renderPeerBlock(sink, root.io, any_visible, markers.items, lines.items[window.start..]);
    if (buf.items.len == 0) return;
    buf.appendSlice(root.arena, "(reply with the peer_message tool — queued, one-way; everyone here hears it)") catch {};
    var obj: std.json.ObjectMap = .empty;
    obj.put(root.arena, "role", .{ .string = "user" }) catch return;
    obj.put(root.arena, "content", .{ .string = peer_context.capInject(buf.items) }) catch return;
    root.messages.append(.{ .object = obj }) catch {};
}

/// Emit the drain's visible half as one bracketed unit: a blank notice, the
/// debug markers and peer lines in drain order, a closing blank. Nothing at
/// all when nothing is visible — a drain that only refreshed history must not
/// paint. Pure aside from the sink, so the bracketing is unit-testable
/// without a live presence registry (a PTY transcript can't tell the fix's
/// blanks apart from a neighbor's, the event sequence can).
fn renderPeerBlock(sink: engine_sink.EngineSink, io: Io, any_visible: bool, markers: []const []const u8, lines: []const []const u8) void {
    if (!any_visible) return;
    sink.emit(io, .{ .session_notice = .{ .text = "", .tone = .plain } });
    for (markers) |m| sink.emit(io, .{ .session_notice = .{ .text = m, .tone = .plain } });
    for (lines) |l| sink.emit(io, .{ .session_notice = .{ .text = l, .tone = .plain } });
    sink.emit(io, .{ .session_notice = .{ .text = "", .tone = .plain } });
}

/// /tell <session|all> <text…>: the user's line into the channel. `all` (or a
/// target in another folder) rides the device-wide room — every live session
/// hears it; a local target stays on the worktree room.
pub fn tellCommand(root: *Agent, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    const rest = std.mem.trim(u8, line["/tell".len..], " \t");
    const everyone = presence.liveAllPeers(root.io, arena);
    const split = std.mem.indexOfAny(u8, rest, " \t");
    const target = if (split) |i| rest[0..i] else "";
    const text = if (split) |i| std.mem.trim(u8, rest[i + 1 ..], " \t") else "";
    if (target.len == 0 or text.len == 0) {
        try out.writeAll("usage: /tell <session|all> <text> — all reaches every live session on this device, any folder\n");
        if (everyone.len == 0) try out.writeAll("  (no live peers right now)\n") else try out.print("  live now: {s}\n", .{peerListText(arena, everyone)});
        try out.flush();
        return true;
    }
    const broadcast = std.mem.eql(u8, target, "all");
    const to: []const u8 = if (broadcast) "" else switch (resolvePeer(everyone, target)) {
        .one => |p| p.session_id,
        .none => {
            try out.print("no live peer matches \"{s}\"\n", .{target});
            try out.flush();
            return true;
        },
        .ambiguous => {
            try out.print("more than one live peer matches — live now: {s}\n", .{peerListText(arena, everyone)});
            try out.flush();
            return true;
        },
    };
    const device_wide = broadcast or !isLocal(everyone, to, presence.ownIdentity());
    const posted = if (device_wide)
        presence.postToDevice(root.io, arena, text, to, true) // the user's line crosses folders; a session's does not
    else
        presence.postTo(root.io, arena, text, to);
    if (posted) {
        const addressed = if (to.len > 0) try std.fmt.allocPrint(arena, " (for {s})", .{to}) else "";
        const room: []const u8 = if (device_wide) "device-wide room" else "worktree channel";
        try out.print("⇢ posted to the {s}{s}\n", .{ room, addressed });
    } else try out.writeAll("delivery failed — presence registry unavailable\n");
    try out.flush();
    return true;
}

/// What a peeked session is up to, summarized from its transcript tail.
pub const PeekSummary = struct {
    last_prompt: []const u8 = "",
    last_said: []const u8 = "",
    last_tool: []const u8 = "",
    messages: usize = 0,
};

/// Pure: parse complete transcript lines (one serialized message each, #441)
/// and pull the last user text, last assistant text, and last tool name. A
/// torn first line (we read a tail window) or last line (writer mid-append)
/// is skipped — the next peek catches up.
pub fn summarizeTranscript(arena: Allocator, text: []const u8) PeekSummary {
    var out: PeekSummary = .{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const msg = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{ .ignore_unknown_fields = true }) catch continue;
        if (msg != .object) continue;
        const role = if (msg.object.get("role")) |r| (if (r == .string) r.string else "") else "";
        out.messages += 1;
        if (std.mem.eql(u8, role, "user")) {
            if (firstText(msg.object)) |t| out.last_prompt = t;
        } else if (std.mem.eql(u8, role, "assistant")) {
            if (firstText(msg.object)) |t| {
                out.last_said = t;
            } else if (msg.object.get("tool_calls")) |tc| {
                if (tc == .array and tc.array.items.len > 0) {
                    const call = tc.array.items[0];
                    if (call == .object) {
                        if (call.object.get("function")) |f| {
                            if (f == .object) {
                                if (f.object.get("name")) |n| {
                                    if (n == .string) out.last_tool = n.string;
                                }
                            }
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, role, "tool")) {
            if (msg.object.get("name")) |n| {
                if (n == .string) out.last_tool = n.string;
            }
        }
    }
    return out;
}

/// First readable text of a message's content, whether it's a plain string or
/// content blocks. Peer-channel lines we inject are skipped: they quote the
/// peer's doings, they aren't the peer's doings.
fn firstText(obj: std.json.ObjectMap) ?[]const u8 {
    const content = obj.get("content") orelse return null;
    switch (content) {
        .string => |s| return if (s.len > 0 and !peer_context.isPeerInjectContent(s)) s else null,
        .array => |arr| {
            for (arr.items) |blk| {
                if (blk != .object) continue;
                const t = blk.object.get("type") orelse continue;
                if (t == .string and std.mem.eql(u8, t.string, "text")) {
                    if (blk.object.get("text")) |v| {
                        if (v == .string and v.string.len > 0) {
                            if (peer_context.isPeerInjectContent(v.string)) continue;
                            return v.string;
                        }
                    }
                }
            }
            return null;
        },
        else => return null,
    }
}

fn transcriptPath(arena: Allocator, peer: Owner) []const u8 {
    const mine = presence.ownIdentity();
    const base = if (std.mem.eql(u8, peer.identity, mine))
        "."
    else if (std.mem.endsWith(u8, peer.identity, "/.git"))
        peer.identity[0 .. peer.identity.len - "/.git".len]
    else
        peer.identity;
    return std.fmt.allocPrint(arena, "{s}/.graff/sessions/{s}.transcript.jsonl", .{ base, peer.session_id }) catch "";
}

/// /peek <session>: what is the other live session DOING right now — the tail
/// of its append-only transcript, not just its registry goal.
pub fn peekCommand(root: *Agent, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    const target = std.mem.trim(u8, line["/peek".len..], " \t");
    const everyone = presence.liveAllPeers(root.io, arena);
    if (target.len == 0) {
        try out.writeAll("usage: /peek <session> — what a live session is doing right now\n");
        if (everyone.len == 0) try out.writeAll("  (no live peers right now)\n") else try out.print("  live now: {s}\n", .{peerListText(arena, everyone)});
        try out.flush();
        return true;
    }
    const peer = switch (resolvePeer(everyone, target)) {
        .one => |p| p,
        .none => {
            try out.print("no live peer matches \"{s}\"\n", .{target});
            try out.flush();
            return true;
        },
        .ambiguous => {
            try out.print("more than one live peer matches — live now: {s}\n", .{peerListText(arena, everyone)});
            try out.flush();
            return true;
        },
    };
    const path = transcriptPath(arena, peer);
    const text = Io.Dir.cwd().readFileAlloc(root.io, path, arena, .limited(1024 * 1024)) catch {
        try out.print("{s} · pid {d} · goal: {s}\n  transcript not reachable from here ({s})\n", .{ peer.session_id, peer.pid, if (peer.goal.len > 0) peer.goal else "?", peer.identity });
        try out.flush();
        return true;
    };
    // Keep the tail: a long transcript's beginning is ancient history.
    const window = if (text.len > 64 * 1024) blk: {
        const tail = text[text.len - 64 * 1024 ..];
        const first_nl = std.mem.indexOfScalar(u8, tail, '\n') orelse 0;
        break :blk tail[first_nl + 1 ..];
    } else text;
    const sum = summarizeTranscript(arena, window);
    const goal = if (peer.goal.len > 0) peer.goal else "?";
    try out.print("⚡ {s} · pid {d} · goal: {s}\n", .{ peer.session_id, peer.pid, goal });
    if (sum.last_prompt.len > 0) try out.print("  last prompt: {s}\n", .{peer_context.clip(sum.last_prompt, 120)});
    if (sum.last_said.len > 0) try out.print("  last said: {s}\n", .{peer_context.clip(sum.last_said, 120)});
    if (sum.last_tool.len > 0) try out.print("  last tool: {s}", .{sum.last_tool});
    if (sum.messages > 0)
        try out.print("{s}{d} transcript messages\n", .{ if (sum.last_tool.len > 0) " · " else "  ", sum.messages })
    else if (sum.last_tool.len > 0)
        try out.writeAll("\n");
    if (sum.messages == 0) try out.writeAll("  (transcript is empty — it just started)\n");
    try out.flush();
    return true;
}

/// The "live now" section /sessions appends under the saved-session list:
/// this worktree first, then the rest of the device.
pub fn writeLiveSection(root: *Agent, arena: Allocator, out: *Io.Writer) !void {
    const everyone = presence.liveAllPeers(root.io, arena);
    if (everyone.len == 0) return;
    const mine = presence.ownIdentity();
    var wrote_local = false;
    var wrote_remote = false;
    for (everyone) |p| {
        const local = std.mem.eql(u8, p.identity, mine);
        if (local and !wrote_local) {
            try out.writeAll("  live now in this worktree:\n");
            wrote_local = true;
        }
        if (!local and !wrote_remote) {
            try out.writeAll("  live elsewhere on this device:\n");
            wrote_remote = true;
        }
        const goal = if (p.goal.len > 0) p.goal else "?";
        if (local)
            try out.print("  ⚡ {s} · pid {d} · goal: {s}\n", .{ p.session_id, p.pid, goal })
        else
            try out.print("  ⚡ {s} · pid {d} · {s} · goal: {s}\n", .{ p.session_id, p.pid, p.identity, goal });
    }
}

test "summarizeTranscript: last prompt, last words, last tool, from complete lines only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\{"role":"user","content":"refactor the digest job"}
    ++ "\n" ++
        \\{"role":"assistant","content":null,"tool_calls":[{"function":{"name":"edit_file"}}]}
    ++ "\n" ++
        \\{"role":"tool","name":"edit_file","content":"ok"}
    ++ "\n" ++
        \\{"role":"assistant","content":[{"type":"text","text":"switched the query to display_name"}]}
    ++ "\n" ++
        \\{"role":"user","content":"[peer message from s-2]: hold off"}
    ++ "\n" ++ "{\"role\":\"user\",\"content\":\"a torn last line";
    const sum = summarizeTranscript(arena, text);
    try std.testing.expectEqualStrings("refactor the digest job", sum.last_prompt); // peer-channel quotes are not the peer's doings
    try std.testing.expectEqualStrings("switched the query to display_name", sum.last_said);
    try std.testing.expectEqualStrings("edit_file", sum.last_tool);
    try std.testing.expectEqual(5, sum.messages); // the torn tail is skipped
}

test "deviceHears: addressed lines and the user's /tell cross folders; broadcasts do not" {
    const own = "session-111-us";
    // A cross-folder post naming this session arrives (substring, either way).
    try std.testing.expect(deviceHears(.{ .to = "session-111" }, own));
    try std.testing.expect(deviceHears(.{ .to = own }, "session-111"));
    // The user's /tell all crosses folders (unaddressed broadcast) — but a
    // /tell naming one graff is a DM: only the target hears it.
    try std.testing.expect(deviceHears(.{ .from_user = true }, own));
    try std.testing.expect(!deviceHears(.{ .from_user = true, .to = "session-999-them" }, own));
    try std.testing.expect(deviceHears(.{ .from_user = true, .to = "session-111" }, own));
    // Another folder's addressed work and bare/broadcast lines stay out.
    try std.testing.expect(!deviceHears(.{ .to = "session-999-them" }, own));
    try std.testing.expect(!deviceHears(.{}, own));
    try std.testing.expect(!deviceHears(.{ .to = "session-111" }, ""));
}

test "displayWindow: only a backlog drain is windowed, to its trailing lines" {
    // Live incremental drains render every line, however many.
    try std.testing.expectEqualDeep(DisplayWindow{ .start = 0, .hidden = 0 }, displayWindow(false, 25));
    // A backlog at or under the show-count renders in full — no marker noise.
    try std.testing.expectEqualDeep(DisplayWindow{ .start = 0, .hidden = 0 }, displayWindow(true, backlog_repl_show));
    // A longer backlog prints only the tail; the rest is context-only.
    try std.testing.expectEqualDeep(DisplayWindow{ .start = 8, .hidden = 8 }, displayWindow(true, 10));
}

fn recordNoticeText(ctx: *anyopaque, ev: engine_sink.Stamped) void {
    const rec: *std.ArrayList([]const u8) = @ptrCast(@alignCast(ctx));
    if (ev.event == .session_notice)
        rec.append(std.testing.allocator, ev.event.session_notice.text) catch {};
}

test "renderPeerBlock: blank notices bracket the block; silence when nothing is visible" {
    // emit(undefined, ...) is sound only while json_mode is false (no lock
    // taken): pin it so a leaky earlier test can never turn this into UB.
    const main_mod = @import("main.zig");
    const protocol_seq = @import("protocol_seq.zig");
    const saved_json = main_mod.json_mode;
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    protocol_seq.resetForTest();
    defer protocol_seq.resetForTest();
    var rec: std.ArrayList([]const u8) = .empty;
    defer rec.deinit(std.testing.allocator);
    const vt: engine_sink.VTable = .{ .emit = recordNoticeText, .durable = false };
    const sink: engine_sink.EngineSink = .{ .ctx = &rec, .vt = &vt };
    const markers = [_][]const u8{"[presence] 1 other live session"};
    const lines = [_][]const u8{ "[peer message from a]: one", "[peer message from b]: two" };
    renderPeerBlock(sink, undefined, true, &markers, &lines);
    try std.testing.expectEqualDeep(&[_][]const u8{
        "", "[presence] 1 other live session", lines[0], lines[1], "",
    }, rec.items);
    // A history-only drain paints nothing — no stray blank pair.
    rec.clearRetainingCapacity();
    renderPeerBlock(sink, undefined, false, &markers, &lines);
    try std.testing.expectEqual(@as(usize, 0), rec.items.len);
}
