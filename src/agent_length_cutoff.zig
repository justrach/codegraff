//! A mid-task reply that runs out of output budget without calling a tool.
//!
//! After tool work, a model can deliberate in visible text (or, where the
//! provider streams reasoning summaries, in reasoning) until the output cap
//! stops it: minutes of "wait, let me re-check the spec" with no tool call,
//! after which the turn ended as if that text were the answer. Two stops,
//! both rewinding the reply and asking for the next action:
//!   * `handle`: the provider already cut the reply at its output limit;
//!   * `ReplySize` + `recoverRunaway`: the reply passed `runaway_bytes` of text
//!     (or of summary reasoning) before any tool call, so the stream is
//!     stopped early instead of waiting for the cap.
//! A turn gets `max_rewinds` rewinds; a runaway after that still stops the
//! stream, and the turn ends like a model loop (agent_model_loop.finishError)
//! instead of streaming to the output cap.
//! The cut reply is never the answer, and keeping it would re-bill its tokens
//! as input on every later call. A turn with no tool call yet is left alone:
//! a long first answer stays as written.

const std = @import("std");
const Value = std.json.Value;
const Agent = @import("agent.zig").Agent;
const Kind = @import("provider.zig").Provider.Kind;
const messages = @import("messages.zig");

pub const note = "Your previous reply ran long without a tool call and was cut off. Do not repeat or continue it. If work remains, make the next tool call now; if the task is done, finish with a short summary.";

/// Text (or summary reasoning) before the first tool call that ends a reply
/// early. Completed text replies this long are very rare; replies cut at the
/// output cap with no tool call are far more common, and reasoning summaries
/// that end in a tool call stay well under it.
pub const runaway_bytes: usize = 24 * 1024;

/// Rewinds per turn. Argon can run away again after a rewind (a second
/// runaway in one turn streamed 180 KB for 145 s to the output cap).
pub const max_rewinds: u8 = 2;

/// The provider stopped because it ran out of output budget, in any of the
/// response shapes graff reads: chat finish_reason, Anthropic stop_reason,
/// Responses incomplete_details, Interactions status.
pub fn cutAtLimit(root: std.json.ObjectMap) bool {
    if (root.get("choices")) |choices| if (choices == .array and choices.array.items.len > 0) {
        const c0 = choices.array.items[0];
        if (c0 == .object) if (c0.object.get("finish_reason")) |fr|
            if (fr == .string and std.mem.eql(u8, fr.string, "length")) return true;
    };
    if (strIn(root, "stop_reason")) |s| if (std.mem.eql(u8, s, "max_tokens")) return true;
    if (root.get("incomplete_details")) |d| if (d == .object) if (strIn(d.object, "reason")) |r|
        if (std.mem.eql(u8, r, "max_output_tokens")) return true;
    if (strIn(root, "status")) |s| if (std.mem.eql(u8, s, "incomplete")) return true;
    return false;
}

/// Mid-task: the turn has used tools, outside compaction and schema replies.
fn midTask(self: *const Agent) bool {
    return self.tool_calls_this_turn > 0 and !self.compaction_request and self.output_schema == null;
}

/// Mid-task with a rewind left this turn.
fn armed(self: *const Agent) bool {
    return self.length_cutoffs < max_rewinds and midTask(self);
}

/// Rewind a mid-task reply the provider cut at its output limit and add the
/// note. False leaves the reply to the normal path.
pub fn handle(self: *Agent, root: std.json.ObjectMap, hist_len: usize) !bool {
    if (!armed(self) or !cutAtLimit(root)) return false;
    return rewind(self, hist_len, "[reply hit the output limit before any tool call — dropped it and asked for the next step]\n");
}

/// The stream stopped itself (`error.ReplyRunaway`): rewind the same way.
/// False with no rewind left: finishError ends the turn.
pub fn recoverRunaway(self: *Agent, err: anyerror, hist_len: usize) !bool {
    if (err != error.ReplyRunaway or self.length_cutoffs >= max_rewinds) return false;
    self.partial_text.clearRetainingCapacity();
    if (self.streamed_text) if (self.out) |w| {
        w.writeAll("\n") catch {};
        w.flush() catch {};
    };
    self.streamed_text = false;
    self.streamed_args = .none;
    return rewind(self, hist_len, "[reply ran long without a tool call — stopped it and asked for the next step]\n");
}

fn rewind(self: *Agent, hist_len: usize, line: []const u8) !bool {
    if (!@import("agent_empty_completion.zig").PendingWork.canRequest(self)) return false;
    self.length_cutoffs += 1;
    const keep = @min(hist_len, self.messages.items.len);
    self.closeCodexWs();
    self.messages.shrinkRetainingCapacity(keep);
    try self.messages.append(try messages.userNote(self.arena, self.provider.kind, note));
    try self.say("{s}", .{line});
    if (self.tracer) |tr| tr.note("length_cutoff", "mid-task reply ran out of budget without a tool call; rewound once");
    return true;
}

/// One streamed reply's text and reasoning bytes until its first tool call.
pub const ReplySize = struct {
    text: usize = 0,
    reasoning: usize = 0,
    tool_seen: bool = false,

    /// True once the reply should be stopped as a runaway.
    pub fn feed(self: *ReplySize, agent: *const Agent, event: Value, text_len: usize) bool {
        if (self.tool_seen) return false;
        const kind = agent.provider.kind;
        if (startsTool(kind, event)) {
            self.tool_seen = true;
            return false;
        }
        self.text += text_len;
        self.reasoning += reasoningDelta(kind, event).len;
        if (!midTask(agent)) return false;
        return self.text > runaway_bytes or (summaryReasoning(agent.provider.model) and self.reasoning > runaway_bytes);
    }
};

/// Providers that stream reasoning summaries (gemini-*): a long summary is a
/// runaway. Raw-reasoning models often pass the limit before a good tool
/// call, so only their visible text counts.
fn summaryReasoning(model: []const u8) bool {
    const leaf = if (std.mem.lastIndexOfScalar(u8, model, '/')) |i| model[i + 1 ..] else model;
    return std.mem.startsWith(u8, leaf, "gemini");
}

fn startsTool(kind: Kind, v: Value) bool {
    switch (kind) {
        .openai => {
            const d = chatDelta(v) orelse return false;
            return get(d, "tool_calls") != null or get(d, "function_call") != null;
        },
        .anthropic => {
            if (!std.mem.eql(u8, str(get(v, "type")), "content_block_start")) return false;
            return std.mem.eql(u8, str(get(get(v, "content_block") orelse return false, "type")), "tool_use");
        },
        .responses => {
            const ty = str(get(v, "type"));
            if (std.mem.eql(u8, ty, "response.function_call_arguments.delta")) return true;
            if (!std.mem.eql(u8, ty, "response.output_item.added")) return false;
            return std.mem.eql(u8, str(get(get(v, "item") orelse return false, "type")), "function_call");
        },
        .interactions => {
            if (get(v, "delta")) |d| {
                const ty = str(get(d, "type"));
                if (std.mem.eql(u8, ty, "function_call") or std.mem.eql(u8, ty, "arguments_delta")) return true;
            }
            if (get(v, "step")) |s| return std.mem.eql(u8, str(get(s, "type")), "function_call");
            return false;
        },
    }
}

fn reasoningDelta(kind: Kind, v: Value) []const u8 {
    switch (kind) {
        .openai => {
            const d = chatDelta(v) orelse return "";
            const r = str(get(d, "reasoning_content"));
            return if (r.len > 0) r else str(get(d, "reasoning"));
        },
        .anthropic => {
            if (!std.mem.eql(u8, str(get(v, "type")), "content_block_delta")) return "";
            const d = get(v, "delta") orelse return "";
            return if (std.mem.eql(u8, str(get(d, "type")), "thinking_delta")) str(get(d, "thinking")) else "";
        },
        .responses => return if (std.mem.eql(u8, str(get(v, "type")), "response.reasoning_summary_text.delta")) str(get(v, "delta")) else "",
        .interactions => {
            const d = get(v, "delta") orelse return "";
            if (!std.mem.eql(u8, str(get(d, "type")), "thought_summary")) return "";
            const content = str(get(get(d, "content") orelse return str(get(d, "text")), "text"));
            return if (content.len > 0) content else str(get(d, "text"));
        },
    }
}

fn chatDelta(v: Value) ?Value {
    const choices = get(v, "choices") orelse return null;
    if (choices != .array or choices.array.items.len == 0) return null;
    return get(choices.array.items[0], "delta");
}

fn get(v: Value, key: []const u8) ?Value {
    return if (v == .object) v.object.get(key) else null;
}

fn str(v: ?Value) []const u8 {
    const x = v orelse return "";
    return if (x == .string) x.string else "";
}

fn strIn(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = obj.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn parse(arena: std.mem.Allocator, raw: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, raw, .{});
}

test "cutAtLimit: chat, Anthropic, Responses and Interactions limit stops; normal stops are not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for ([_][]const u8{
        \\{"choices":[{"index":0,"message":{"role":"assistant","content":"wait..."},"finish_reason":"length"}]}
        ,
        \\{"type":"message","stop_reason":"max_tokens","content":[{"type":"text","text":"wait..."}]}
        ,
        \\{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}
        ,
        \\{"status":"incomplete","outputs":[]}
    }) |raw| try std.testing.expect(cutAtLimit((try parse(a, raw)).object));
    for ([_][]const u8{
        \\{"choices":[{"index":0,"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}]}
        ,
        \\{"choices":[]}
        ,
        \\{"type":"message","stop_reason":"end_turn","content":[]}
        ,
        \\{"status":"completed","output":[]}
    }) |raw| try std.testing.expect(!cutAtLimit((try parse(a, raw)).object));
}

test "ReplySize: text past the limit stops a mid-task reply; a tool call, an unarmed turn, or raw reasoning does not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var agent: Agent = undefined;
    agent.provider.kind = .openai;
    agent.provider.model = "codegraff/gemini-4-argon";
    agent.length_cutoffs = 0;
    agent.tool_calls_this_turn = 1;
    agent.compaction_request = false;
    agent.output_schema = null;

    const text_ev = try parse(a, "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"wait\"}}]}");
    var size: ReplySize = .{};
    try std.testing.expect(!size.feed(&agent, text_ev, runaway_bytes));
    try std.testing.expect(size.feed(&agent, text_ev, 1));

    // A tool call that started first ends the count for this reply.
    const tool_ev = try parse(a, "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0}]}}]}");
    var with_tool: ReplySize = .{};
    try std.testing.expect(!with_tool.feed(&agent, tool_ev, 0));
    try std.testing.expect(!with_tool.feed(&agent, text_ev, runaway_bytes * 2));

    // No tool call yet this turn: never stopped.
    agent.tool_calls_this_turn = 0;
    var first: ReplySize = .{};
    try std.testing.expect(!first.feed(&agent, text_ev, runaway_bytes * 2));
    agent.tool_calls_this_turn = 1;

    // Rewinds spent: still stopped (the turn then ends instead of rewinding).
    agent.length_cutoffs = max_rewinds;
    var spent: ReplySize = .{};
    try std.testing.expect(spent.feed(&agent, text_ev, runaway_bytes * 2));
    try std.testing.expect(!try recoverRunaway(&agent, error.ReplyRunaway, 0));
    agent.length_cutoffs = 0;

    // Reasoning counts only for summary-reasoning (Gemini) models.
    var big: std.ArrayList(u8) = .empty;
    try big.appendNTimes(a, 'x', runaway_bytes + 1);
    const reason_raw = try std.fmt.allocPrint(a, "{{\"choices\":[{{\"index\":0,\"delta\":{{\"reasoning_content\":\"{s}\"}}}}]}}", .{big.items});
    const reason_ev = try parse(a, reason_raw);
    var gem: ReplySize = .{};
    try std.testing.expect(gem.feed(&agent, reason_ev, 0));
    agent.provider.model = "codegraff/deepseek-flash";
    var raw: ReplySize = .{};
    try std.testing.expect(!raw.feed(&agent, reason_ev, 0));
}
