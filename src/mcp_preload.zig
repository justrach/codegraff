//! Load the schemas of an MCP server the user names before the turn's first
//! request (ADR 0231). A message that says "the linear server" is going to call
//! it, and a deferred schema makes the model spend a whole round trip on
//! `load_tool_schemas` before the first call. The named server's deferred
//! tools load here, after the request path has joined the servers that
//! finished connecting, and `additional_tools.sync` announces them on the same
//! request. Servers the message does not name stay deferred, and one whose
//! schemas exceed `budget_bytes` waits for an explicit load, so naming a large
//! server in passing does not put all of its schemas in front of the model.
//! Loading a schema grants nothing: every call still goes through the gate.
//! A message that asks for subagents loads the folded `subagent` and
//! `agent_output` natives the same way.

const std = @import("std");
const Agent = @import("agent.zig").Agent;
const mcp = @import("mcp.zig");
const gate = @import("mcp_schema_gate.zig");

/// Total description + schema bytes a named server may load without asking.
pub const budget_bytes: usize = 16 * 1024;

/// On the root's first request of a turn, load every deferred tool of each
/// server the latest user message names. True when anything loaded, so the
/// caller rebuilds the catalog as it does when a server joins.
pub fn namedServers(self: *Agent) bool {
    if (self.sub or self.model_calls_this_turn > 1) return false;
    const text = @import("messages.zig").latestUserText(self.messages.items);
    if (text.len == 0) return false;
    const reg_tools: []const mcp.Tool = if (self.registry) |reg| reg.tools else &.{};
    var loaded: std.ArrayList(u8) = .empty;
    for (reg_tools, 0..) |tool, i| {
        const server = tool.serverName();
        if (!firstOfServer(reg_tools[0..i], server) or !names(text, server)) continue;
        if (gate.serverCost(reg_tools, server) > budget_bytes) continue;
        for (reg_tools) |t| if (std.mem.eql(u8, t.serverName(), server) and gate.blocked(reg_tools, t.qualified_name)) {
            gate.autoLoad(self.arena, reg_tools, t.qualified_name);
            loaded.print(self.arena, "{s}{s}", .{ if (loaded.items.len == 0) "" else ", ", t.qualified_name }) catch {};
        };
    }
    const mcp_loaded = loaded.items.len > 0;
    namedNatives(self.arena, text, &loaded);
    if (loaded.items.len == 0) return false;
    note(self, loaded.items, mcp_loaded);
    return true;
}

/// Folded natives a message asks for outright. A request to split work across
/// subagents spawns them and waits on what they return, so both load with the
/// request instead of one load call each. A peer wake says "peer_message
/// action=inbox": the turn it starts reads the inbox first, and on Claude
/// Agent a call to the unloaded tool is refused by Claude Code itself
/// ("No such tool available"), which also costs a fresh session (ADR 0311).
const named_natives = [_]struct { words: []const []const u8, tools: []const []const u8 }{
    .{ .words = &.{ "subagent", "subagents", "sub-agent", "sub-agents" }, .tools = &.{ "subagent", "agent_output" } },
    .{ .words = &.{"peer_message"}, .tools = &.{"peer_message"} },
};

fn namedNatives(arena: std.mem.Allocator, text: []const u8, loaded: *std.ArrayList(u8)) void {
    const fold = @import("native_fold.zig");
    for (named_natives) |entry| {
        const asked = for (entry.words) |w| {
            if (names(text, w)) break true;
        } else false;
        if (!asked) continue;
        for (entry.tools) |tool| if (fold.blocked(tool)) {
            fold.markLoaded(tool);
            loaded.print(arena, "{s}{s}", .{ if (loaded.items.len == 0) "" else ", ", tool }) catch {};
        };
    }
}

/// Tell the model the load already happened. A prompt that says "load its
/// schemas" otherwise still gets a load_tool_schemas call, and with it the
/// round trip the preload exists to save. The note carries what that call's
/// result would have said about result shapes (ADR 0225): without it the
/// model coded against full rows, met slimmed ones, and spent calls finding
/// the real shape.
fn note(self: *Agent, tools: []const u8, mcp_loaded: bool) void {
    const head = std.fmt.allocPrint(self.arena, "Already loaded for this turn: {s}. Their schemas are attached and the tools are callable now; load_tool_schemas is not needed for them.", .{tools}) catch return;
    const shaped = if (mcp_loaded) @import("mcp_shapes.zig").annotate(self.gpa, self.arena, self.io, self.agent_cwd, head) catch head else head;
    // A fetch-then-write task is one rlm step: each() makes the calls, write_file
    // saves the binds, and bash() builds the file from them.
    const text = if (mcp_loaded and @import("rlm.zig").available) std.fmt.allocPrint(self.arena, "{s}\n{s}", .{ shaped, rlm_hint }) catch shaped else shaped;
    var msg = @import("named_work.zig").userNudge(self.arena, self.provider.kind, text) catch return;
    if (msg != .object) return;
    msg.object.put(self.arena, @import("session_wake.zig").origin_key, .{ .string = "notification" }) catch return;
    self.messages.append(msg) catch {};
}

const rlm_hint = "To fetch from these tools and write a file from the results, one rlm script can do it in one step: each() makes the calls, write_file saves the binds, and bash() builds the file from the saved results.";

fn firstOfServer(before: []const mcp.Tool, server: []const u8) bool {
    for (before) |t| if (std.mem.eql(u8, t.serverName(), server)) return false;
    return true;
}

/// Whether `text` names `server` as a whole word, ignoring case. Words are
/// runs of letters, digits, `-` and `_`, the characters server names use.
pub fn names(text: []const u8, server: []const u8) bool {
    if (server.len == 0) return false;
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and !wordChar(text[i])) i += 1;
        const start = i;
        while (i < text.len and wordChar(text[i])) i += 1;
        if (i > start and std.ascii.eqlIgnoreCase(text[start..i], server)) return true;
    }
    return false;
}

fn wordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
}

test "asking for subagents loads subagent and agent_output with the request (ADR 0231)" {
    const fold = @import("native_fold.zig");
    fold.clearLoadedSession();
    defer fold.clearLoadedSession();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var loaded: std.ArrayList(u8) = .empty;
    namedNatives(arena_state.allocator(), "Fix the parser and run the tests.", &loaded);
    try std.testing.expectEqual(@as(usize, 0), loaded.items.len);
    namedNatives(arena_state.allocator(), "Split the 8 issues across two sibling subagents.", &loaded);
    if (fold.enabled) {
        try std.testing.expectEqualStrings("subagent, agent_output", loaded.items);
        try std.testing.expect(fold.isLoaded("subagent") and fold.isLoaded("agent_output"));
    }
}

test "a peer wake loads peer_message with the turn it starts (ADR 0311)" {
    const fold = @import("native_fold.zig");
    fold.clearLoadedSession();
    defer fold.clearLoadedSession();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var loaded: std.ArrayList(u8) = .empty;
    namedNatives(arena_state.allocator(), "Message the peer when you are done.", &loaded);
    try std.testing.expectEqual(@as(usize, 0), loaded.items.len);
    namedNatives(arena_state.allocator(), "[peer] 1 unread from lead \u{2014} parked; peer_message action=inbox when relevant", &loaded);
    if (fold.enabled) {
        try std.testing.expectEqualStrings("peer_message", loaded.items);
        try std.testing.expect(fold.isLoaded("peer_message"));
    }
}

test "a server is named only as a whole word, in any case" {
    try std.testing.expect(names("This workspace has a Linear-shaped MCP server named linear (stdio).", "linear"));
    try std.testing.expect(names("check LINEAR for open bugs", "linear"));
    try std.testing.expect(names("use codedb-pro to search", "codedb-pro"));
    try std.testing.expect(!names("the linearity of the fit", "linear"));
    try std.testing.expect(!names("codedb-pro-extra", "codedb-pro"));
    try std.testing.expect(!names("", "linear"));
}
