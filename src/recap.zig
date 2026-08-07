//! Session recaps (#419): a one-line "what is this session doing" summary plus
//! a coarse status, emitted harness-side as the `session_recap` wire event so
//! the GUI agent overview (and any other --json/serve client) can show every
//! session's state without watching its stream.
//!
//! Two sources, one event shape:
//! - heuristic: derived synchronously at turn end from the final text (free,
//!   zero-latency) — the always-available floor, and the ONLY source when no
//!   cheap model is reachable (no ladder rung, no key, call failed).
//! - model: a detached cheap-tier call over a strictly bounded digest of the
//!   recent history (last 8 messages, 600 chars each, tool calls by name
//!   only), scheduled at turn end and debounced by mainloop_recap.zig so a
//!   streaming turn never thrashes it.
//!
//! The model reply contract is two lines — `STATUS: <NEEDS_INPUT|COMPLETED|
//! FAILED>` and `RECAP: <one line>` — parsed by parseModelReply; anything
//! unparseable is dropped (null), never emitted.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const agent_mod = @import("agent.zig");
const messages = @import("messages.zig");
const providers = @import("providers.zig");
const provider_mod = @import("provider.zig");
const title_mod = @import("title.zig");

const Agent = agent_mod.Agent;
const Provider = provider_mod.Provider;
const Value = std.json.Value;

/// Coarse session state for the overview chip. `working` is deliberately
/// absent: recaps are computed at turn end, and mid-turn liveness is the
/// client's own streaming signals, not a recap.
pub const Status = enum {
    needs_input,
    completed,
    failed,

    pub fn parse(s: []const u8) ?Status {
        if (std.ascii.eqlIgnoreCase(s, "needs_input")) return .needs_input;
        if (std.ascii.eqlIgnoreCase(s, "completed")) return .completed;
        if (std.ascii.eqlIgnoreCase(s, "failed")) return .failed;
        return null;
    }
};

pub const Recap = struct {
    status: Status,
    text: []const u8,
};

// Strict input bounds (#419): cheap means the digest can never grow with the
// session — last N messages, each capped, tool calls named but never quoted.
pub const max_messages = 8;
pub const max_message_chars = 600;
/// Cap on the emitted one-liner, codepoints, word-boundaried like titles.
pub const max_recap_codepoints = 120;

/// First non-empty line of `s`, trimmed and capped at `max_codepoints`
/// codepoints on a word boundary (titleFromPrompt's convention). Empty when
/// nothing usable remains.
fn firstLine(s: []const u8, max_codepoints: usize) []const u8 {
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var end: usize = 0;
        var codepoints: usize = 0;
        while (end < trimmed.len and codepoints < max_codepoints) {
            const cp_len = std.unicode.utf8ByteSequenceLength(trimmed[end]) catch 1;
            end += cp_len;
            codepoints += 1;
        }
        var out = std.mem.trim(u8, trimmed[0..@min(end, trimmed.len)], " \t\r");
        if (codepoints >= max_codepoints and end < trimmed.len) {
            if (std.mem.lastIndexOfScalar(u8, out, ' ')) |sp| {
                if (sp >= 12) out = std.mem.trim(u8, out[0..sp], " ");
            }
        }
        return out;
    }
    return "";
}

/// The no-model recap: the turn's own closing line is the summary, and a
/// closing question reads as waiting on the human. `errored` marks the
/// stall/drop/api-failure paths so the chip says failed, not completed.
pub fn heuristic(final_text: []const u8, errored: bool) Recap {
    if (errored) return .{ .status = .failed, .text = "Turn ended on an error" };
    const line = firstLine(final_text, max_recap_codepoints);
    if (line.len == 0) return .{ .status = .completed, .text = "Turn complete" };
    const status: Status = if (line[line.len - 1] == '?') .needs_input else .completed;
    return .{ .status = status, .text = line };
}

/// One digest line for a history message: a role/type label, tool calls by
/// name only, and text capped at max_message_chars. Returns "" for messages
/// with neither text nor tool names (images, control envelopes).
fn digestLine(arena: Allocator, m: Value) ![]const u8 {
    if (m != .object) return "";
    const obj = m.object;
    const label: []const u8 = blk: {
        if (obj.get("role")) |r| if (r == .string) break :blk r.string;
        if (obj.get("type")) |t| if (t == .string) break :blk t.string;
        break :blk "message";
    };
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(arena, label);
    // Tool calls by name only: openai tool_calls[], anthropic tool_use
    // blocks, responses function_call items — never their arguments.
    var named: usize = 0;
    if (obj.get("tool_calls")) |tc| if (tc == .array) {
        for (tc.array.items) |call| {
            if (call != .object) continue;
            const name_value = if (call.object.get("function")) |f| blk: {
                if (f != .object) break :blk null;
                break :blk f.object.get("name");
            } else call.object.get("name");
            if (name_value) |n| if (n == .string) {
                try b.appendSlice(arena, if (named == 0) " called " else ", ");
                try b.appendSlice(arena, n.string);
                named += 1;
            };
        }
    };
    if (obj.get("content")) |c| if (c == .array) {
        for (c.array.items) |blk_item| {
            if (blk_item != .object) continue;
            const bt = if (blk_item.object.get("type")) |t| (if (t == .string) t.string else "") else "";
            if (std.mem.eql(u8, bt, "tool_use") or std.mem.eql(u8, bt, "function_call"))
                if (blk_item.object.get("name")) |n| if (n == .string) {
                    try b.appendSlice(arena, if (named == 0) " called " else ", ");
                    try b.appendSlice(arena, n.string);
                    named += 1;
                };
        }
    };
    // Text: providers.extractText covers string content and text-block
    // arrays; responses function_call_output carries its result in "output".
    var text = providers.extractText(arena, m);
    if (text.len == 0)
        if (obj.get("output")) |o| if (o == .string) {
            text = o.string;
        };
    const line = firstLine(text, max_message_chars);
    if (line.len > 0) {
        try b.appendSlice(arena, ": ");
        try b.appendSlice(arena, line);
    }
    if (named == 0 and line.len == 0) return "";
    return b.items;
}

/// The bounded recap digest handed to the cheap model: the last
/// max_messages history messages, one line each. Arena-owned.
pub fn buildDigest(arena: Allocator, history: []const Value) ![]const u8 {
    const start = if (history.len > max_messages) history.len - max_messages else 0;
    var b: std.ArrayList(u8) = .empty;
    for (history[start..]) |m| {
        const line = digestLine(arena, m) catch continue;
        if (line.len == 0) continue;
        try b.appendSlice(arena, line);
        try b.append(arena, '\n');
    }
    return b.items;
}

/// Parse the cheap model's two-line reply. Lenient about ordering, blank
/// lines and case; strict about the RECAP line existing — without it the
/// reply is not a recap and the caller keeps the heuristic one.
pub fn parseModelReply(reply: []const u8) ?Recap {
    var status: Status = .completed;
    var text: []const u8 = "";
    var it = std.mem.splitScalar(u8, reply, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.ascii.startsWithIgnoreCase(line, "status:")) {
            if (Status.parse(std.mem.trim(u8, line["status:".len..], " \t"))) |s| status = s;
        } else if (std.ascii.startsWithIgnoreCase(line, "recap:")) {
            text = firstLine(line["recap:".len..], max_recap_codepoints);
        }
    }
    if (text.len == 0) return null;
    return .{ .status = status, .text = text };
}

/// Detached cheap-model recap over the bounded digest — titleTask's shape:
/// its own arena, a throwaway one-message sub-Agent, a tiny output cap, null
/// on any failure (no auth, transport, unparseable reply) so the caller
/// silently keeps the heuristic recap. `input` must be gpa/stable-owned: the
/// task reads it off-thread. Result text is gpa-owned; caller frees.
pub fn recapTask(gpa: Allocator, io: Io, client: *std.http.Client, provider: Provider, input: []const u8, run_budget: ?*@import("run_budget.zig").RunBudget, tracer: ?*@import("trace.zig").Tracer) ?Recap {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var agent: Agent = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .client = client,
        .provider = provider,
        .messages = std.json.Array.init(arena),
        .sub = true, // pool thread: never touches stdout or the main agent's state
        .label = "recap",
        .out = null,
        .tracer = tracer,
        .run_budget = run_budget,
        .call_kind = .recap,
        .responses_output_limit = 128,
        .sys_override = "You write one-line status recaps of coding sessions for a multi-session dashboard. Reply with EXACTLY two lines:\nSTATUS: <NEEDS_INPUT|COMPLETED|FAILED>\nRECAP: <one line, present tense, at most 120 characters — what the agent just did or is waiting on>\nNEEDS_INPUT means the session is waiting on the human (a question, an approval); COMPLETED means the last task finished; FAILED means it ended on an error.",
    };
    defer agent.tools_used.deinit(gpa);
    const instr = std.fmt.allocPrint(arena, "Recent session activity (latest last; tool calls shown by name only):\n{s}", .{input}) catch return null;
    agent.messages.append(messages.textMessage(arena, "user", instr) catch return null) catch return null;
    const root = agent.request(null) catch return null;
    const recap = parseModelReply(title_mod.assistantText(provider.kind, root)) orelse return null;
    return .{ .status = recap.status, .text = gpa.dupe(u8, recap.text) catch return null };
}

test "heuristic: closing line is the recap, a trailing question means needs_input" {
    const done = heuristic("Fixed the parser and added tests.", false);
    try std.testing.expectEqual(Status.completed, done.status);
    try std.testing.expectEqualStrings("Fixed the parser and added tests.", done.text);
    const asking = heuristic("I can do either. Which one do you want?", false);
    try std.testing.expectEqual(Status.needs_input, asking.status);
    const empty = heuristic("  \n ", false);
    try std.testing.expectEqual(Status.completed, empty.status);
    try std.testing.expect(empty.text.len > 0); // never an empty chip
    const err = heuristic("partial", true);
    try std.testing.expectEqual(Status.failed, err.status);
}

test "heuristic: multi-line replies recap to their first line, capped on a word boundary" {
    const line = heuristic("First line says it all.\nSecond line is detail.", false);
    try std.testing.expectEqualStrings("First line says it all.", line.text);
    var long: [400]u8 = undefined;
    @memset(&long, 'x');
    // spaces every 10 chars so the word-boundary backoff has somewhere to go
    var i: usize = 10;
    while (i < long.len) : (i += 11) long[i] = ' ';
    const capped = heuristic(&long, false);
    try std.testing.expect(capped.text.len <= max_recap_codepoints);
    try std.testing.expect(capped.text.len >= 12); // backoff never strands a stub
}

test "buildDigest: bounds history to the last 8 messages and caps each line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var history: std.ArrayList(Value) = .empty;
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const text = try std.fmt.allocPrint(arena, "message number {d}", .{i});
        try history.append(arena, try messages.textMessage(arena, "user", text));
    }
    const digest = try buildDigest(arena, history.items);
    try std.testing.expect(std.mem.indexOf(u8, digest, "message number 3") == null); // older than the window
    try std.testing.expect(std.mem.indexOf(u8, digest, "message number 11") != null);
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, digest, "\n"), '\n');
    while (it.next()) |_| lines += 1;
    try std.testing.expectEqual(@as(usize, max_messages), lines);
}

test "buildDigest: tool calls appear by name only, never with arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var msg: std.json.ObjectMap = .empty;
    try msg.put(arena, "role", .{ .string = "assistant" });
    var call: std.json.ObjectMap = .empty;
    var function: std.json.ObjectMap = .empty;
    try function.put(arena, "name", .{ .string = "bash" });
    try function.put(arena, "arguments", .{ .string = "{\"command\":\"rm -rf /\"}" });
    try call.put(arena, "function", .{ .object = function });
    var calls: std.json.Array = .init(arena);
    try calls.append(.{ .object = call });
    try msg.put(arena, "tool_calls", .{ .array = calls });
    var history = std.json.Array.init(arena);
    try history.append(.{ .object = msg });
    const digest = try buildDigest(arena, history.items);
    try std.testing.expect(std.mem.indexOf(u8, digest, "bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, digest, "rm -rf") == null); // arguments never quoted
}

test "parseModelReply: two-line contract, case- and order-lenient, strict on RECAP" {
    const recap = parseModelReply("STATUS: NEEDS_INPUT\nRECAP: Waiting on the user to pick a layout").?;
    try std.testing.expectEqual(Status.needs_input, recap.status);
    try std.testing.expectEqualStrings("Waiting on the user to pick a layout", recap.text);
    const swapped = parseModelReply("recap: shipped the fix\nstatus: completed").?;
    try std.testing.expectEqual(Status.completed, swapped.status);
    // unknown status degrades to completed rather than failing the recap
    try std.testing.expectEqual(Status.completed, parseModelReply("STATUS: BORED\nRECAP: still going").?.status);
    // no RECAP line → not a recap at all
    try std.testing.expect(parseModelReply("STATUS: COMPLETED") == null);
    try std.testing.expect(parseModelReply("just some prose") == null);
    try std.testing.expect(parseModelReply("") == null);
}
