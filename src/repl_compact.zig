//! TUI /compact glue — run Agent.manualCompact() on a throwaway quiet agent built
//! from the same history the next turn would send, then hand back the
//! rewritten turns. Split from repl_glue.zig for the 600-line cap.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const approvals_mod = @import("approvals.zig");
const Approvals = approvals_mod.Approvals;
const messages_mod = @import("messages.zig");
const textMessage = messages_mod.textMessage;
const prompts = @import("prompts.zig");
const repl = @import("repl.zig");
const repl_glue = @import("repl_glue.zig");
const ReplCtx = repl_glue.ReplCtx;

pub const CompactOut = struct {
    note: []const u8 = "",
    turns: []repl.Turn = &.{},
};

pub fn replCompactCb(ctx_ptr: ?*anyopaque, gpa: Allocator, history: []const repl.Turn, out: *CompactOut) bool {
    const c: *ReplCtx = @ptrCast(@alignCast(ctx_ptr orelse {
        out.note = gpa.dupe(u8, "compaction needs a live session") catch "";
        return false;
    }));
    // With a session conversation the engine's own history is what gets
    // compacted — `history` is only the frontend's projection of it, and
    // summarizing that would throw away the tool blocks compaction exists to
    // fold up (#551).
    if (history.len == 0 and (c.convo == null or c.convo.?.len() == 0)) {
        out.note = gpa.dupe(u8, "nothing to compact") catch "";
        return false;
    }
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const arena = if (c.convo) |cv| cv.alloc() else scratch_state.allocator();
    var discard_buf: [256]u8 = undefined;
    var discarding: Io.Writer.Discarding = .init(&discard_buf);
    var approvals: Approvals = .{ .yolo = true };
    var agent: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = c.io,
        .client = c.client,
        .provider = c.provider,
        .messages = std.json.Array.init(arena),
        .sub = false,
        .label = "repl",
        .out = &discarding.writer,
        .in = null,
        .stream_quiet = true,
        .registry = c.registry,
        .tracer = c.tracer,
        .run_budget = c.run_budget,
        .approvals = &approvals,
        .tools_anthropic = c.tools_anthropic,
        .tools_openai = c.tools_openai,
        .tools_responses = c.tools_responses,
        .fallback_allow = c.fallback_allow,
        .fallback_active = c.fallback_active,
        .fallback_blocked = c.fallback_blocked,
    };
    prompts.setSystemPrompts(&agent, c.sys_normal, arena) catch {
        out.note = gpa.dupe(u8, "compaction failed: could not build prompts") catch "";
        return false;
    };
    defer agent.tools_used.deinit(gpa);
    if (c.convo) |cv| {
        agent.scratch_arena = &scratch_state;
        agent.messages = cv.list().*;
    } else for (history) |t| {
        const role = switch (t.role) {
            .user => "user",
            .assistant => "assistant",
        };
        agent.messages.append(textMessage(arena, role, t.text) catch {
            out.note = gpa.dupe(u8, "compaction failed: out of memory") catch "";
            return false;
        }) catch {
            out.note = gpa.dupe(u8, "compaction failed: out of memory") catch "";
            return false;
        };
    }
    // Whatever manualCompact() did to the borrowed list — rewrite, or nothing at all
    // on a failure that leaves history untouched — is the session's state now.
    defer if (c.convo) |cv| {
        cv.list().* = agent.messages;
    };
    const n = agent.manualCompact() catch |err| {
        out.note = (switch (err) {
            error.EmptySummary => gpa.dupe(u8, "compaction failed: empty summary, history unchanged"),
            error.IncompleteSummary => gpa.dupe(u8, "compaction failed: incomplete summary, history unchanged"),
            error.ApiError => gpa.dupe(u8, "compaction failed: provider error, history unchanged"),
            else => gpa.dupe(u8, "compaction failed, history unchanged"),
        }) catch "";
        return false;
    };
    if (n == 0) {
        out.note = gpa.dupe(u8, "nothing to compact") catch "";
        return false;
    }
    var turns = std.array_list.Managed(repl.Turn).init(gpa);
    errdefer {
        for (turns.items) |t| gpa.free(t.text);
        turns.deinit();
    }
    for (agent.messages.items) |m| {
        if (m != .object) continue;
        const role_v = m.object.get("role") orelse continue;
        if (role_v != .string) continue;
        const role: repl.Turn.Role = if (std.mem.eql(u8, role_v.string, "user"))
            .user
        else if (std.mem.eql(u8, role_v.string, "assistant"))
            .assistant
        else
            continue;
        const c_v = m.object.get("content") orelse continue;
        if (c_v != .string) continue;
        const text = gpa.dupe(u8, c_v.string) catch continue;
        turns.append(.{ .role = role, .text = text }) catch gpa.free(text);
    }
    out.turns = turns.toOwnedSlice() catch &.{};
    out.note = std.fmt.allocPrint(gpa, "history compacted to a {d}-char summary", .{n}) catch "";
    return true;
}
