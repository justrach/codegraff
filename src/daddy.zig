//! Supervisor ("daddy") directives: explicit control of sibling sessions
//! and a slash/tool surface shared by REPL, TUI, and GUI (`graff acp`).
//!
//! Ambient peer mail stays a parked mailbox (ADR 0004 / #1137). A daddy
//! directive is a named DM whose body is prefixed `[daddy]`. Idle roots
//! may start a turn on that prefix even after `attempt_completion`; busy
//! roots still only see it at the next step (same as `/tell`).
//!
//! Children inside one process stay on `agent_message`. This module is
//! the cross-session supervisor path.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const peer_inbox = @import("peer_inbox.zig");
const peer_target = @import("peer_target.zig");
const presence = @import("presence.zig");
const tools_mod = @import("tools.zig");
const Owner = @import("worktree_lease.zig").Owner;

const Agent = agent_mod.Agent;
const ExecResult = tools_mod.ExecResult;

pub const prefix = "[daddy] ";

pub fn isDirective(s: []const u8) bool {
    const t = std.mem.trimStart(u8, s, " \t\r\n");
    return std.mem.startsWith(u8, t, "[daddy]");
}

pub fn formatBody(arena: Allocator, text: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return error.EmptyDirective;
    if (isDirective(t)) return t;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, t });
}

pub fn stripPrefix(s: []const u8) []const u8 {
    const t = std.mem.trimStart(u8, s, " \t\r\n");
    if (std.mem.startsWith(u8, t, prefix)) return std.mem.trim(u8, t[prefix.len..], " \t\r\n");
    if (std.mem.startsWith(u8, t, "[daddy]")) return std.mem.trim(u8, t["[daddy]".len..], " \t\r\n");
    return t;
}

pub fn parkedDirectives() bool {
    return peer_inbox.anyTextPrefixed("[daddy]");
}

pub fn formatSteer(arena: Allocator, text: []const u8) []const u8 {
    const body = stripPrefix(text);
    return std.fmt.allocPrint(arena, "[daddy] directive — {s}", .{body}) catch "[daddy] directive waiting — peer_message action=inbox";
}

pub const Slash = struct { target: []const u8, text: []const u8 };

pub fn parseSlash(line: []const u8) ?Slash {
    if (!std.mem.startsWith(u8, line, "/daddy")) return null;
    if (line.len > 6 and line[6] != ' ' and line[6] != '\t') return null;
    const rest = std.mem.trim(u8, line["/daddy".len..], " \t");
    const split = std.mem.indexOfAny(u8, rest, " \t") orelse return null;
    const target = rest[0..split];
    const text = std.mem.trim(u8, rest[split + 1 ..], " \t");
    if (target.len == 0 or text.len == 0) return null;
    return .{ .target = target, .text = text };
}

fn peerListText(arena: Allocator, peers: []const Owner) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (peers) |p| {
        const line = std.fmt.allocPrint(arena, "\"{s}\" (pid {d})", .{ p.session_id, p.pid }) catch continue;
        buf.appendSlice(arena, line) catch {};
        buf.appendSlice(arena, ", ") catch {};
    }
    const items = buf.items;
    return if (items.len >= 2) items[0 .. items.len - 2] else items;
}

fn isLocal(peers: []const Owner, session_id: []const u8, my_identity: []const u8) bool {
    for (peers) |p| {
        if (std.mem.eql(u8, p.session_id, session_id)) return std.mem.eql(u8, p.identity, my_identity);
    }
    return true;
}

fn postDirect(io: Io, arena: Allocator, text: []const u8, to: []const u8, everyone: []const Owner) bool {
    const cross_folder = to.len > 0 and !isLocal(everyone, to, presence.ownIdentity());
    if (cross_folder) return presence.postToDevice(io, arena, text, to, false);
    return presence.postTo(io, arena, text, to);
}

pub fn send(self: *Agent, session: []const u8, text: []const u8) !ExecResult {
    const body = formatBody(self.arena, text) catch return .{
        .text = "daddy: empty text — say what the other agent should do",
        .is_error = true,
    };
    const everyone = presence.liveAllPeers(self.io, self.arena);
    if (session.len == 0) return .{
        .text = "daddy: name the session to direct (title, saved-session base, id, or pid). Not a room broadcast.",
        .is_error = true,
    };
    if (std.mem.eql(u8, session, "all")) return .{
        .text = "daddy: \"all\" is not a control target — name one session. Ambient room posts stay on peer_message action=send.",
        .is_error = true,
    };
    const to: []const u8 = switch (peer_target.resolvePeer(everyone, session)) {
        .one => |p| p.session_id,
        .none => return .{
            .text = try std.fmt.allocPrint(self.arena, "daddy: no live peer matches \"{s}\" — live now: {s}", .{ session, peerListText(self.arena, everyone) }),
            .is_error = true,
        },
        .ambiguous => return .{
            .text = try std.fmt.allocPrint(self.arena, "daddy: more than one live peer matches — name one: {s}", .{peerListText(self.arena, everyone)}),
            .is_error = true,
        },
    };
    if (!postDirect(self.io, self.arena, body, to, everyone)) return .{
        .text = "daddy: delivery failed — the presence registry is unavailable",
        .is_error = true,
    };
    return .{
        .text = try std.fmt.allocPrint(self.arena, "directed \"{s}\" — they read this as supervisor control at their next step (or an idle root starts a turn). Re-direct with session=\"{s}\".", .{ to, to }),
        .is_error = false,
    };
}

/// /daddy <session> <text>: user-facing supervisor control, same post as
/// `peer_message action=direct`.
pub fn slashCommand(root: *Agent, arena: Allocator, line: []const u8, out: *Io.Writer) !bool {
    if (!std.mem.startsWith(u8, line, "/daddy")) return false;
    if (line.len > 6 and line[6] != ' ' and line[6] != '\t') return false;
    const parsed = parseSlash(line);
    if (parsed == null) {
        try out.writeAll("usage: /daddy <session> <text> — direct one live graff (title, base, id, or pid). Not a room broadcast.\n");
        const everyone = presence.liveAllPeers(root.io, arena);
        if (everyone.len == 0) try out.writeAll("  (no live peers right now)\n") else try out.print("  live now: {s}\n", .{peerListText(arena, everyone)});
        try out.flush();
        return true;
    }
    const result = try send(root, parsed.?.target, parsed.?.text);
    try out.print("{s}\n", .{result.text});
    try out.flush();
    return true;
}

/// Idle wake text when a directive is parked — allowed after completion.
pub fn takeIdleText(arena: Allocator, buf: []u8) ?[]const u8 {
    if (!parkedDirectives()) return null;
    const wake = formatSteer(arena, "waiting");
    const copy = @min(wake.len, buf.len);
    @memcpy(buf[0..copy], wake[0..copy]);
    return buf[0..copy];
}

test "isDirective: prefix only" {
    try std.testing.expect(isDirective("[daddy] stop the publish"));
    try std.testing.expect(isDirective("  [daddy] hold"));
    try std.testing.expect(!isDirective("[peer] 1 unread"));
    try std.testing.expect(!isDirective("please finish"));
}

test "formatBody: prefixes once and rejects empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("[daddy] hold gui/src", try formatBody(a, "hold gui/src"));
    try std.testing.expectEqualStrings("[daddy] already", try formatBody(a, "[daddy] already"));
    try std.testing.expectError(error.EmptyDirective, formatBody(a, "   "));
}

test "parseSlash: target and text; usage is null" {
    const ok = parseSlash("/daddy reviewer pause the PR") orelse return error.ExpectedSlash;
    try std.testing.expectEqualStrings("reviewer", ok.target);
    try std.testing.expectEqualStrings("pause the PR", ok.text);
    try std.testing.expect(parseSlash("/daddy") == null);
    try std.testing.expect(parseSlash("/daddyonly x") == null);
    try std.testing.expect(parseSlash("/tell reviewer hi") == null);
}

test "stripPrefix and formatSteer stay one line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("pause the PR", stripPrefix("[daddy] pause the PR"));
    const steer = formatSteer(a, "[daddy] pause the PR");
    try std.testing.expect(std.mem.startsWith(u8, steer, "[daddy]"));
    try std.testing.expect(std.mem.indexOf(u8, steer, "pause the PR") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, steer, '\n') == null);
}

test "send refuses empty, all, and a missing session" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var root: Agent = undefined;
    root.arena = arena_state.allocator();
    root.io = std.testing.io;
    const empty = try send(&root, "reviewer", "  ");
    try std.testing.expect(empty.is_error);
    const all = try send(&root, "all", "stop");
    try std.testing.expect(all.is_error);
    try std.testing.expect(std.mem.indexOf(u8, all.text, "all") != null);
    const missing = try send(&root, "no-such-peer", "stop");
    try std.testing.expect(missing.is_error);
}

test "parkedDirectives sees a [daddy] body and takeIdleText fires after completion" {
    peer_inbox.resetForTest();
    @import("peer_idle.zig").resetForTest();
    defer {
        peer_inbox.resetForTest();
        @import("peer_idle.zig").resetForTest();
    }
    @import("peer_idle.zig").noteCompletion();
    try std.testing.expect(@import("peer_idle.zig").idleWakeSuppressed());
    try std.testing.expect(!parkedDirectives());
    _ = peer_inbox.parkHeard(&.{.{ .from_session = "s-dad", .text = "[daddy] switch to the tests" }}, &.{});
    try std.testing.expect(parkedDirectives());
    var buf: [128]u8 = undefined;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const idle = takeIdleText(arena_state.allocator(), &buf) orelse return error.ExpectedDaddyIdle;
    try std.testing.expect(std.mem.indexOf(u8, idle, "[daddy]") != null);
}
