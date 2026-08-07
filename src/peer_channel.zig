//! The #469 channel half: what co-resident root sessions SAY to each other,
//! on top of what presence.zig knows (WHO is out there, liveness-probed).
//!
//! Four surfaces, one inbox primitive:
//!   - peer_message: the model-facing tool, so a session can coordinate the
//!     way a parent steers a subagent — "I'm restructuring gui/src, hold" —
//!     except sideways, between roots. Queued, one-way, never synchronous.
//!   - /tell <session> <text>: the user's own line into a peer's inbox.
//!   - /sessions: the saved-session list gains a "live now" section.
//!   - deliverInbound: drains our inbox at the turn boundary (agent.runTurn)
//!     so a peer's message lands in context as a first-class note — durable in
//!     history, visible to the user as an event, never mid-turn (#430's
//!     input-inversion path can move it mid-turn later).

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
pub const tool_desc = "Send a message to another live graff session working in this same folder (a co-resident peer you learned about from the startup co-owner warning or a shared-tree checkpoint). The message lands in their context at their next turn boundary, stamped with your session name and current goal. Use it to coordinate the way you would steer a subagent, but sideways: announce what you are restructuring, ask them to hold off a directory, or split the work. `session` selects the peer by name substring; omit it when exactly one peer is live. Delivery is queued and one-way — the tool result only confirms the send, never a reply.";
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
    const target = switch (resolvePeer(peers, want)) {
        .one => |p| p,
        .none => return .{
            .text = try std.fmt.allocPrint(self.arena, "no live peer matches \"{s}\" — live now: {s}", .{ want, peerListText(self.arena, peers) }),
            .is_error = true,
        },
        .ambiguous => return .{
            .text = try std.fmt.allocPrint(self.arena, "more than one live peer — name one with `session`: {s}", .{peerListText(self.arena, peers)}),
            .is_error = true,
        },
    };
    if (!presence.postTo(self.io, self.arena, target, text)) return .{
        .text = "delivery failed — the presence registry is unavailable (this session may never have announced itself)",
        .is_error = true,
    };
    return .{
        .text = try std.fmt.allocPrint(self.arena, "queued for \"{s}\" (pid {d}) — it lands at their next turn boundary. Delivery is one-way: their answer, if any, arrives the same way.", .{ target.session_id, target.pid }),
        .is_error = false,
    };
}

/// The receiving half, called once at the top of a root agent's turn: every
/// queued peer message becomes one durable user-role note in history plus a
/// user-visible event. Never fails a turn — delivery trouble is silence, not
/// an error, because a peer's inbox must never break our session.
pub fn deliverInbound(root: *Agent) void {
    if (root.sub) return;
    const msgs = presence.drainInbox(root.io, root.arena);
    if (msgs.len == 0) return;
    const sink = engine_sink.forAgent(root);
    var buf: std.ArrayList(u8) = .empty;
    for (msgs) |m| {
        const goal = if (m.from_goal.len > 0) std.fmt.allocPrint(root.arena, " (goal: {s})", .{m.from_goal}) catch "" else "";
        const line = std.fmt.allocPrint(root.arena, "[peer message from {s}{s} — #469 channel]: {s}", .{ m.from_session, goal, m.text }) catch continue;
        buf.appendSlice(root.arena, line) catch {};
        buf.append(root.arena, '\n') catch {};
        sink.emit(root.io, .{ .session_notice = .{ .text = line, .tone = .plain } });
    }
    if (buf.items.len == 0) return;
    buf.appendSlice(root.arena, "(reply with the peer_message tool — queued, one-way)") catch {};
    var obj: std.json.ObjectMap = .empty;
    obj.put(root.arena, "role", .{ .string = "user" }) catch return;
    obj.put(root.arena, "content", .{ .string = buf.items }) catch return;
    root.messages.append(.{ .object = obj }) catch {};
}

/// /tell <session> <text…>: the user's line into a peer's inbox.
pub fn tellCommand(root: *Agent, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    const rest = std.mem.trim(u8, line["/tell".len..], " \t");
    const peers = presence.liveTreePeers(root.io, arena);
    const split = std.mem.indexOfAny(u8, rest, " \t");
    const target = if (split) |i| rest[0..i] else "";
    const text = if (split) |i| std.mem.trim(u8, rest[i + 1 ..], " \t") else "";
    if (target.len == 0 or text.len == 0) {
        try out.writeAll("usage: /tell <session> <text> — message a live co-resident graff session\n");
        if (peers.len == 0) try out.writeAll("  (no live peers in this worktree right now)\n") else try out.print("  live now: {s}\n", .{peerListText(arena, peers)});
        try out.flush();
        return true;
    }
    const peer = switch (resolvePeer(peers, target)) {
        .one => |p| p,
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
    if (presence.postTo(root.io, arena, peer, text))
        try out.print("⇢ queued for {s} (pid {d}) — lands at their next turn boundary\n", .{ peer.session_id, peer.pid })
    else
        try out.writeAll("delivery failed — presence registry unavailable\n");
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
