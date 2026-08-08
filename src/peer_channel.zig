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
pub const tool_desc = "Post a message to this folder's shared graff channel: every OTHER live graff session working here hears it at its next turn boundary, stamped with your session name and current goal. Use it to coordinate the way you would steer a subagent, but sideways: announce what you are restructuring, ask the others to hold off a directory, or split the work. `session` names the intended recipient (name substring) when the message is meant for one peer — they all still hear it. Delivery is queued and one-way — the tool result only confirms the post, never a reply.";
pub const tool_schema =
    \\{"type": "object", "properties": {"session": {"type": "string", "description": "peer session name substring (omit when only one peer is live)"}, "text": {"type": "string", "description": "one or two sentences of coordination intent"}}, "required": ["text"]}
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
    const peers = presence.liveTreePeers(self.io, self.arena);
    if (peers.len == 0) return .{
        .text = "no live co-resident graff sessions in this worktree — the presence registry says you are alone here (a peer shows up via the startup warning when one starts)",
        .is_error = true,
    };
    // `session` is validated so a mistyped target errors usefully, but every
    // peer hears the post either way — the channel is a room, not a DM.
    const to: []const u8 = if (want.len == 0) "" else switch (resolvePeer(peers, want)) {
        .one => |p| p.session_id,
        .none => return .{
            .text = try std.fmt.allocPrint(self.arena, "no live peer matches \"{s}\" — live now: {s}", .{ want, peerListText(self.arena, peers) }),
            .is_error = true,
        },
        .ambiguous => return .{
            .text = try std.fmt.allocPrint(self.arena, "more than one live peer matches — name one with `session`: {s}", .{peerListText(self.arena, peers)}),
            .is_error = true,
        },
    };
    if (!presence.postTo(self.io, self.arena, text, to)) return .{
        .text = "delivery failed — the presence registry is unavailable (this session may never have announced itself)",
        .is_error = true,
    };
    const addressed = if (to.len > 0) try std.fmt.allocPrint(self.arena, " (for \"{s}\")", .{to}) else "";
    return .{
        .text = try std.fmt.allocPrint(self.arena, "posted to the worktree channel{s} — {d} live peer(s) hear it at their next turn boundary. Delivery is one-way: any answer arrives the same way.", .{ addressed, peers.len }),
        .is_error = false,
    };
}

/// The receiving half, called once at the top of a root agent's turn: every
/// queued peer message becomes one durable user-role note in history plus a
/// user-visible event. Never fails a turn — delivery trouble is silence, not
/// an error, because a peer's inbox must never break our session.
pub fn deliverInbound(root: *Agent) void {
    if (root.sub) return;
    const msgs = presence.drainChannel(root.io, root.arena);
    if (msgs.len == 0) return;
    const sink = engine_sink.forAgent(root);
    const own = presence.ownSession();
    var buf: std.ArrayList(u8) = .empty;
    for (msgs) |m| {
        const goal = if (m.from_goal.len > 0) std.fmt.allocPrint(root.arena, " (goal: {s})", .{m.from_goal}) catch "" else "";
        // Addressing is rendered, not enforced: everyone hears the line, and
        // the marker says who it was meant for.
        const to = if (m.to.len == 0) "" else if (std.mem.indexOf(u8, m.to, own) != null or std.mem.indexOf(u8, own, m.to) != null) " → you" else std.fmt.allocPrint(root.arena, " → {s}", .{m.to}) catch "";
        const line = std.fmt.allocPrint(root.arena, "[peer message from {s}{s}{s} — #469 channel]: {s}", .{ m.from_session, goal, to, m.text }) catch continue;
        buf.appendSlice(root.arena, line) catch {};
        buf.append(root.arena, '\n') catch {};
        sink.emit(root.io, .{ .session_notice = .{ .text = line, .tone = .plain } });
    }
    if (buf.items.len == 0) return;
    buf.appendSlice(root.arena, "(reply with the peer_message tool — queued, one-way; everyone here hears it)") catch {};
    var obj: std.json.ObjectMap = .empty;
    obj.put(root.arena, "role", .{ .string = "user" }) catch return;
    obj.put(root.arena, "content", .{ .string = buf.items }) catch return;
    root.messages.append(.{ .object = obj }) catch {};
}

/// /tell <session|all> <text…>: the user's line into the shared channel.
/// Every co-resident session hears it; the target only marks who it's FOR.
pub fn tellCommand(root: *Agent, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    const rest = std.mem.trim(u8, line["/tell".len..], " \t");
    const peers = presence.liveTreePeers(root.io, arena);
    const split = std.mem.indexOfAny(u8, rest, " \t");
    const target = if (split) |i| rest[0..i] else "";
    const text = if (split) |i| std.mem.trim(u8, rest[i + 1 ..], " \t") else "";
    if (target.len == 0 or text.len == 0) {
        try out.writeAll("usage: /tell <session|all> <text> — post to this worktree's shared graff channel\n");
        if (peers.len == 0) try out.writeAll("  (no live peers in this worktree right now)\n") else try out.print("  live now: {s}\n", .{peerListText(arena, peers)});
        try out.flush();
        return true;
    }
    const to: []const u8 = if (std.mem.eql(u8, target, "all")) "" else switch (resolvePeer(peers, target)) {
        .one => |p| p.session_id,
        .none => {
            try out.print("no live peer matches \"{s}\"\n", .{target});
            try out.flush();
            return true;
        },
        .ambiguous => {
            try out.print("more than one live peer matches — live now: {s}\n", .{peerListText(arena, peers)});
            try out.flush();
            return true;
        },
    };
    if (presence.postTo(root.io, arena, text, to)) {
        const addressed = if (to.len > 0) try std.fmt.allocPrint(arena, " (for {s})", .{to}) else "";
        try out.print("⇢ posted to the worktree channel{s} — {d} live peer(s) hear it at their next turn boundary\n", .{ addressed, peers.len });
    } else try out.writeAll("delivery failed — presence registry unavailable\n");
    try out.flush();
    return true;
}

/// The "live now" section /sessions appends under the saved-session list.
pub fn writeLiveSection(root: *Agent, arena: Allocator, out: *Io.Writer) !void {
    const peers = presence.liveTreePeers(root.io, arena);
    if (peers.len == 0) return;
    try out.writeAll("  live now in this worktree:\n");
    for (peers) |p| {
        const goal = if (p.goal.len > 0) p.goal else "?";
        try out.print("  ⚡ {s} · pid {d} · goal: {s}\n", .{ p.session_id, p.pid, goal });
    }
}
