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
const worktree_lease = @import("worktree_lease.zig");

const Agent = agent_mod.Agent;
const ToolCall = tools_mod.ToolCall;
const ExecResult = tools_mod.ExecResult;
const Owner = worktree_lease.Owner;

pub const tool_name = "peer_message";
pub const tool_desc = "Post a message to the shared graff channel: live graff sessions hear it at their next step boundary, stamped with your session name and current goal. Use it to coordinate the way you would steer a subagent, but sideways: announce what you are restructuring, ask the others to hold off a directory, or split the work. Bare posts go to this folder's room; `session` names an intended recipient (name substring, possibly in another folder) or \"all\" to reach every live session on this device — everyone hears the post either way, the name only marks who it's for. Delivery is queued and one-way — the tool result only confirms the post, never a reply.";
pub const tool_schema =
    \\{"type": "object", "properties": {"session": {"type": "string", "description": "peer session name substring (omit for this folder's room), \"all\" for every live session on this device, or a session name in another folder"}, "text": {"type": "string", "description": "one or two sentences of coordination intent"}}, "required": ["text"]}
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
    // Routing: bare posts stay in the worktree room; "all" broadcasts to every
    // live session on the device; a named target in another folder rides the
    // device room with the address as metadata — everyone still hears it.
    if (std.mem.eql(u8, want, "all")) {
        const everyone = presence.liveAllPeers(self.io, self.arena);
        if (everyone.len == 0) return .{ .text = "no live graff sessions on this device at all", .is_error = true };
        if (!presence.postToDevice(self.io, self.arena, text, "")) return .{ .text = "delivery failed — the presence registry is unavailable", .is_error = true };
        return .{
            .text = try std.fmt.allocPrint(self.arena, "posted to the device-wide room — {d} live session(s) across all folders hear it at their next step boundary", .{everyone.len}),
            .is_error = false,
        };
    }
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
        presence.postToDevice(self.io, self.arena, text, to)
    else
        presence.postTo(self.io, self.arena, text, to);
    if (!posted) return .{
        .text = "delivery failed — the presence registry is unavailable (this session may never have announced itself)",
        .is_error = true,
    };
    const addressed = if (to.len > 0) try std.fmt.allocPrint(self.arena, " (for \"{s}\")", .{to}) else "";
    const room: []const u8 = if (cross_folder) "device-wide room" else "worktree channel";
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
        buf.appendSlice(root.arena, "[#469 presence] the other live graff sessions are gone — the shared tree is yours alone now.") catch return null;
    } else {
        const mine = presence.ownIdentity();
        buf.appendSlice(root.arena, std.fmt.allocPrint(root.arena, "[#469 presence] {d} other live graff session(s):", .{peers.len}) catch return null) catch return null;
        for (peers) |p| {
            const where: []const u8 = if (std.mem.eql(u8, p.identity, mine)) "this folder" else p.identity;
            buf.appendSlice(root.arena, std.fmt.allocPrint(root.arena, " {s} (goal: {s}, {s});", .{ p.session_id, if (p.goal.len > 0) p.goal else "?", where }) catch break) catch break;
        }
        buf.appendSlice(root.arena, " Coordinate with the peer_message tool before restructuring shared files — bare posts stay in this folder, \"all\" or a name in another folder reaches every session on this device.") catch {};
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
pub fn deliverInbound(root: *Agent) void {
    if (root.sub) return;
    const note = peerNoteIfChanged(root);
    const local_msgs = presence.drainChannel(root.io, root.arena);
    const device_msgs = presence.drainDevice(root.io, root.arena);
    if (note == null and local_msgs.len == 0 and device_msgs.len == 0) return;
    const sink = engine_sink.forAgent(root);
    const own = presence.ownSession();
    var buf: std.ArrayList(u8) = .empty;
    if (note) |n| {
        buf.appendSlice(root.arena, n) catch {};
        buf.append(root.arena, '\n') catch {};
        sink.emit(root.io, .{ .session_notice = .{ .text = n, .tone = .plain } });
    }
    for ([2][]const presence.Message{ local_msgs, device_msgs }, [2][]const u8{ "", " · device" }) |msgs, scope| {
        for (msgs) |m| {
            const goal = if (m.from_goal.len > 0) std.fmt.allocPrint(root.arena, " (goal: {s})", .{m.from_goal}) catch "" else "";
            // Addressing is rendered, not enforced: everyone hears the line,
            // and the marker says who it was meant for.
            const to = if (m.to.len == 0) "" else if (std.mem.indexOf(u8, m.to, own) != null or std.mem.indexOf(u8, own, m.to) != null) " → you" else std.fmt.allocPrint(root.arena, " → {s}", .{m.to}) catch "";
            const line = std.fmt.allocPrint(root.arena, "[peer message from {s}{s}{s}{s} — #469 channel]: {s}", .{ m.from_session, goal, to, scope, m.text }) catch continue;
            buf.appendSlice(root.arena, line) catch {};
            buf.append(root.arena, '\n') catch {};
            sink.emit(root.io, .{ .session_notice = .{ .text = line, .tone = .plain } });
        }
    }
    if (buf.items.len == 0) return;
    buf.appendSlice(root.arena, "(reply with the peer_message tool — queued, one-way; everyone here hears it)") catch {};
    var obj: std.json.ObjectMap = .empty;
    obj.put(root.arena, "role", .{ .string = "user" }) catch return;
    obj.put(root.arena, "content", .{ .string = buf.items }) catch return;
    root.messages.append(.{ .object = obj }) catch {};
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
        presence.postToDevice(root.io, arena, text, to)
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
