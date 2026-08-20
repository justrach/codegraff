//! The #469 channel half: what co-resident root sessions SAY to each other,
//! on top of what presence.zig knows (WHO is out there, liveness-probed).
//!
//! Claude-style pull (token-maxxing): history does not eat the room. Bodies
//! park in peer_inbox.zig; the model reads them with `action=inbox` and
//! discovers who is live with `action=list`. deliverInbound injects a
//! one-line `[peer]` wake and still paints the full lines for the human.
//!
//! Surfaces:
//!   - peer_message: send (default), list, inbox. Queued, one-way.
//!   - /tell <session> <text>: the user's own line into a peer's inbox.
//!   - /sessions: the saved-session list gains a "live now" section.
//!   - deliverInbound: drain + park at every root step boundary.

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
const peer_inbox = @import("peer_inbox.zig");
const peer_target = @import("peer_target.zig");

const Agent = agent_mod.Agent;
const ToolCall = tools_mod.ToolCall;
const ExecResult = tools_mod.ExecResult;
const Owner = worktree_lease.Owner;

pub const tool_name = "peer_message";
pub const tool_desc = "Ping a co-resident session, list who is live, or read parked inbound. action=list | inbox | send (default). session is a DM (id/pid/name/goal); omit for this folder's room. Not \"all\".";
pub const tool_schema =
    \\{"type": "object", "properties": {"action": {"type": "string", "enum": ["send", "list", "inbox"], "description": "send (default): ping a peer. list: who is live. inbox: read+clear parked inbound."}, "session": {"type": "string", "description": "who to ping: exact session name, pid, unique name fragment, or unique goal fragment (omit = this folder's room). Named targets are DMs. Not \"all\"."}, "text": {"type": "string", "description": "one or two sentences of coordination intent (required for send)"}}}
;

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
        .text = "peer_message needs an object input",
        .is_error = true,
    };
    const action = tools_mod.json_args.str(obj, "action") orelse "send";
    if (std.mem.eql(u8, action, "list")) {
        const everyone = presence.liveAllPeers(self.io, self.arena);
        return .{ .text = peer_inbox.formatList(self.arena, everyone, presence.ownIdentity()), .is_error = false };
    }
    if (std.mem.eql(u8, action, "inbox")) {
        return .{ .text = peer_inbox.takeAll(self.arena), .is_error = false };
    }
    if (!std.mem.eql(u8, action, "send")) return .{
        .text = "peer_message action must be send, list, or inbox",
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
    // Named `session` is a DM: only that peer hears it. Bare posts stay a
    // room. Cross-folder names ride the device room. Model "all" is retired.
    if (std.mem.eql(u8, want, "all")) return .{
        .text = "\"all\" is retired for sessions — hearing is folder-scoped now. Post bare for this folder's room, or name one session (possibly in another folder) to reach it directly.",
        .is_error = true,
    };
    const to: []const u8 = if (want.len == 0) "" else switch (peer_target.resolvePeer(presence.liveAllPeers(self.io, self.arena), want)) {
        .one => |p| p.session_id,
        .none => return .{
            .text = try std.fmt.allocPrint(self.arena, "no live peer matches \"{s}\" — live here: {s}", .{ want, peerListText(self.arena, local) }),
            .is_error = true,
        },
        .ambiguous => return .{
            .text = try std.fmt.allocPrint(self.arena, "more than one live peer matches — name one with `session` (id, pid, or a unique goal fragment): {s}", .{peerListText(self.arena, presence.liveAllPeers(self.io, self.arena))}),
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
    if (to.len == 0) return .{
        .text = "posted to this folder's room — every live session here hears it at their next step boundary. Set session to DM one peer instead.",
        .is_error = false,
    };
    const via: []const u8 = if (cross_folder) "device room" else "this folder";
    return .{
        .text = try std.fmt.allocPrint(self.arena, "DM to \"{s}\" via the {s} — only they hear it, at their next step boundary. Re-ping with session=\"{s}\".", .{ to, via, to }),
        .is_error = false,
    };
}

/// The receiving half, called at every step boundary of a root agent's turn:
/// drain the rooms, park heard bodies, paint them for the human, and inject
/// at most a one-line `[peer]` wake. Never fails a turn — delivery trouble
/// is silence, not an error, because a peer must never break our session.
/// The room tail a late joiner parks; anything older is seek-skipped.
pub const backlog_tail_max = 10;
var g_backlog_tail_cut = false;

/// Resume already restored the room cursor — the next drain is incremental,
/// never a first-join backlog replay.
pub fn markCaughtUp() void {
    g_backlog_tail_cut = true;
}

/// Of a first-drain backlog the REPL prints only this many trailing lines;
/// the rest still lands in history (the model coordinates from it) behind a
/// "delivered to context" marker. Live drains are unaffected.
pub const backlog_repl_show = 2;

const DisplayWindow = struct { start: usize, hidden: usize };

fn displayWindow(is_backlog: bool, count: usize) DisplayWindow {
    if (!is_backlog or count <= backlog_repl_show) return .{ .start = 0, .hidden = 0 };
    return .{ .start = count - backlog_repl_show, .hidden = count - backlog_repl_show };
}

pub fn deliverInbound(root: *Agent) void {
    if (root.sub) return;
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
    const own = presence.ownSession();
    // Named worktree posts are DMs; the JSONL still has the line.
    var tree_heard: std.ArrayList(presence.Message) = .empty;
    var skipped: usize = 0;
    for (local_msgs) |m| {
        if (peer_target.treeHears(m, own)) tree_heard.append(root.arena, m) catch break else skipped += 1;
    }
    local_msgs = tree_heard.items;
    var heard: std.ArrayList(presence.Message) = .empty;
    for (device_msgs) |m| {
        if (peer_target.deviceHears(m, own)) heard.append(root.arena, m) catch break else skipped += 1;
    }
    device_msgs = heard.items;
    if (local_msgs.len == 0 and device_msgs.len == 0 and omitted == 0 and skipped == 0) return;
    const sink = engine_sink.forAgent(root);
    // The visible block gets one blank line of air on either side: peer lines
    // land mid-stream at a step boundary and used to butt straight against
    // the assistant text above and whatever follows below — one clump.
    const window = displayWindow(is_backlog_drain, local_msgs.len + device_msgs.len);
    const any_visible = local_msgs.len + device_msgs.len > window.start or
        (repl.g_debug and (omitted > 0 or skipped > 0 or window.hidden > 0));
    var markers: std.ArrayList([]const u8) = .empty;
    if (omitted > 0 and repl.g_debug) {
        const marker = std.fmt.allocPrint(root.arena, "[peer channel: {d} older message(s) predating this session omitted]", .{omitted}) catch "";
        if (marker.len > 0) markers.append(root.arena, marker) catch {};
    }
    if (skipped > 0 and repl.g_debug) {
        const marker = std.fmt.allocPrint(root.arena, "[peer channel: {d} message(s) not addressed to this session skipped — folder-scoped hearing]", .{skipped}) catch "";
        if (marker.len > 0) markers.append(root.arena, marker) catch {};
    }
    if (window.hidden > 0 and repl.g_debug) {
        const marker = std.fmt.allocPrint(root.arena, "[peer channel: {d} backlog message(s) showing last {d}]", .{ window.hidden, backlog_repl_show }) catch "";
        if (marker.len > 0) markers.append(root.arena, marker) catch {};
    }
    var lines: std.ArrayList([]const u8) = .empty;
    for ([2][]const presence.Message{ local_msgs, device_msgs }, [2][]const u8{ "", " · device" }) |msgs, scope| {
        for (msgs) |m| {
            const goal = if (m.from_goal.len > 0) std.fmt.allocPrint(root.arena, " (goal: {s})", .{peer_context.clip(m.from_goal, 40)}) catch "" else "";
            const to = if (m.to.len == 0) "" else if (peer_target.addressedTo(m.to, own)) " → you" else std.fmt.allocPrint(root.arena, " → {s}", .{m.to}) catch "";
            const line = std.fmt.allocPrint(root.arena, "[peer message from {s}{s}{s}{s}]: {s}", .{ m.from_session, goal, to, scope, peer_context.clip(m.text, peer_context.line_clip) }) catch continue;
            lines.append(root.arena, line) catch {};
        }
    }
    renderPeerBlock(sink, root.io, any_visible, markers.items, lines.items[window.start..]);
    if (peer_inbox.parkHeard(local_msgs, device_msgs) == 0) return;
    // History gets the wake only (ADR 0004). Bodies wait in the ring.
    var obj: std.json.ObjectMap = .empty;
    obj.put(root.arena, "role", .{ .string = "user" }) catch return;
    obj.put(root.arena, "content", .{ .string = peer_context.capInject(peer_inbox.formatWake(root.arena)) }) catch return;
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
    const to: []const u8 = if (broadcast) "" else switch (peer_target.resolvePeer(everyone, target)) {
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
        const addressed = if (to.len > 0) try std.fmt.allocPrint(arena, " (DM to {s})", .{to}) else "";
        const room: []const u8 = if (device_wide) "device-wide room" else if (to.len > 0) "this folder" else "worktree room";
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
    const peer = switch (peer_target.resolvePeer(everyone, target)) {
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
