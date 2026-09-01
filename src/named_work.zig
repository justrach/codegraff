//! One bounded nudge when the user named a source file and the model
//! answered without touching the tree. The in-house 5/6 miss was this shape:
//! one call, "I'll read SPEC.md…", no edit, tests still fail.
//!
//! Shared by `-p` and the REPL (no oneshot-only skip). At most one extra
//! model call, and only when tools_used is still empty.

const std = @import("std");
const Value = std.json.Value;

const Agent = @import("agent.zig").Agent;
const messages_mod = @import("messages.zig");

pub const max_nudges: u8 = 1;

pub const nudge_text =
    "You named a source file and have not used a tool. Read the named path " ++
    "and edit it before answering — do not describe a fix you have not applied.";

/// Test-only fallback. Production copies onto the Agent so a scout's
/// arena cannot leave a dangling pointer for the parent's handle (#714).
var remembered_task: []const u8 = "";

const source_needles = [_][]const u8{ ".py", ".zig", ".jsx", ".js", ".tsx", ".ts", "SPEC.md" };

fn copyOnto(self: *Agent, text: []const u8) []const u8 {
    return self.arena.dupe(u8, text) catch "";
}

fn taskOf(self: *const Agent) []const u8 {
    return if (self.named_work_task.len > 0) self.named_work_task else remembered_task;
}

pub fn remember(text: []const u8) void {
    remembered_task = text;
}

pub fn rememberOn(self: *Agent, text: []const u8) void {
    self.named_work_task = copyOnto(self, text);
}

pub fn resetForTest() void {
    remembered_task = "";
}

fn lastUserText(self: *Agent) []const u8 {
    return messages_mod.latestUserText(self.messages.items);
}

/// Snapshot the user prompt at turn start, while `role=user` still exists.
/// Does not clear a `-p` remember() if history has no user string yet.
pub fn rememberFrom(self: *Agent) void {
    const t = lastUserText(self);
    if (t.len > 0) {
        rememberOn(self, t);
        return;
    }
    if (remembered_task.len > 0 and self.named_work_task.len == 0) rememberOn(self, remembered_task);
}

pub fn beginTurn(self: *Agent) void {
    rememberFrom(self);
    if (!std.mem.eql(u8, taskOf(self), self.named_work_settled)) self.named_work_nudges = 0;
}

/// True when `text` names a source path (not a greeting.txt-style data file).
pub fn hasNamedSource(text: []const u8) bool {
    if (text.len == 0) return false;
    for (source_needles) |needle| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, text, from, needle)) |at| {
            const end = at + needle.len;
            if (end == text.len or (!std.ascii.isAlphanumeric(text[end]) and text[end] != '_')) return true;
            from = end;
        }
    }
    return false;
}

pub fn shouldNudge(tools_used: u64, nudges: u8, prompt: []const u8) bool {
    if (nudges >= max_nudges) return false;
    if (tools_used != 0) return false;
    return hasNamedSource(prompt);
}

fn valueNamesSource(v: Value) bool {
    switch (v) {
        .string => |s| return hasNamedSource(s),
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                if (valueNamesSource(e.value_ptr.*)) return true;
            }
            return false;
        },
        .array => |a| {
            for (a.items) |item| {
                if (valueNamesSource(item)) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Walk every string in history. Responses items often have no `role=user`
/// / `content` string, so looking at only the last user message misses the
/// named path and the nudge never fires.
pub fn conversationNamesSource(messages: []const Value) bool {
    for (messages) |m| {
        if (valueNamesSource(m)) return true;
    }
    return false;
}

/// Responses `input` item. A Chat `{role, content: string}` after a
/// `function_call` / `output_text` item is dropped or 400s on the
/// `previous_response_id` delta (and on a full resend mixed with those items).
pub fn responsesUserMessage(arena: std.mem.Allocator, text: []const u8) !Value {
    var block: std.json.ObjectMap = .empty;
    try block.put(arena, "type", .{ .string = "input_text" });
    try block.put(arena, "text", .{ .string = try arena.dupe(u8, text) });
    var content: std.json.Array = .init(arena);
    try content.append(.{ .object = block });
    var msg: std.json.ObjectMap = .empty;
    try msg.put(arena, "type", .{ .string = "message" });
    try msg.put(arena, "role", .{ .string = "user" });
    try msg.put(arena, "content", .{ .array = content });
    return .{ .object = msg };
}

pub fn userNudge(arena: std.mem.Allocator, kind: @import("provider.zig").Provider.Kind, text: []const u8) !Value {
    return switch (kind) {
        .responses => responsesUserMessage(arena, text),
        .openai, .anthropic => messages_mod.textMessage(arena, "user", text),
    };
}

const isResponsesInputText = messages_mod.isResponsesInputText;

/// Append the nudge and ask the caller to `continue` the turn loop.
/// Re-anchor the Responses chain so the new item is not a dropped delta.
pub fn handle(self: *Agent, _: []const u8) !bool {
    if (self.named_work_nudges >= max_nudges) return false;
    const task = taskOf(self);
    if (self.tools_used.count() != 0) {
        if (hasNamedSource(task)) self.named_work_settled = copyOnto(self, task);
        return false;
    }
    // Per unanswered mention (#714): this turn's user text only. Walking
    // all history re-fired after a successful read because SPEC.md stayed
    // in an earlier message.
    if (!hasNamedSource(task)) return false;
    if (std.mem.eql(u8, task, self.named_work_settled)) return false;
    if (std.mem.eql(u8, lastUserText(self), nudge_text)) return false;
    self.named_work_nudges += 1;
    self.named_work_settled = copyOnto(self, task);
    self.closeCodexWs();
    try self.messages.append(try userNudge(self.arena, self.provider.kind, nudge_text));
    return true;
}

test "hasNamedSource sees source suffixes without confusing JSON for JavaScript" {
    try std.testing.expect(hasNamedSource("Read SPEC.md and affinity.py"));
    try std.testing.expect(hasNamedSource("Fix fib.py"));
    try std.testing.expect(hasNamedSource("edit view.tsx and helper.jsx"));
    try std.testing.expect(!hasNamedSource("resume .graff/sessions/task.session.json"));
    try std.testing.expect(!hasNamedSource("read task.transcript.jsonl"));
    try std.testing.expect(!hasNamedSource("Reply with exactly: pong"));
    try std.testing.expect(!hasNamedSource("Create hello.txt then rename it"));
}

test "shouldNudge is once, and only when no tools have run" {
    try std.testing.expect(shouldNudge(0, 0, "Fix fib.py"));
    try std.testing.expect(!shouldNudge(1, 0, "Fix fib.py"));
    try std.testing.expect(!shouldNudge(0, 1, "Fix fib.py"));
    try std.testing.expect(!shouldNudge(0, 0, "Reply with exactly: pong"));
}

test "remembered task is enough to shouldNudge even without history walk" {
    remember("Fix stall_notice.py");
    defer resetForTest();
    try std.testing.expect(hasNamedSource(remembered_task));
    remember("Reply with exactly: pong");
    try std.testing.expect(!hasNamedSource(remembered_task));
}

test "conversationNamesSource sees Responses input_text, not role=user" {
    const raw =
        \\{"type":"message","content":[{"type":"input_text","text":"Fix atomic_write.py"}]}
    ;
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const msgs = [_]Value{parsed.value};
    try std.testing.expect(conversationNamesSource(&msgs));
    const pong = try std.json.parseFromSlice(Value, std.testing.allocator, "{\"role\":\"user\",\"content\":\"pong\"}", .{});
    defer pong.deinit();
    const pongs = [_]Value{pong.value};
    try std.testing.expect(!conversationNamesSource(&pongs));
}

test "userNudge is input_text on Responses and a content string on chat" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const responses = try userNudge(a, .responses, nudge_text);
    try std.testing.expect(isResponsesInputText(responses, nudge_text));
    const chat = try userNudge(a, .openai, nudge_text);
    try std.testing.expectEqualStrings("user", chat.object.get("role").?.string);
    try std.testing.expectEqualStrings(nudge_text, chat.object.get("content").?.string);
    try std.testing.expect(chat.object.get("type") == null);
}

test "handle appends Responses input_text once and re-anchors the chain" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    try msgs.append(try messages_mod.textMessage(a, "user", "Fix atomic_write.py"));
    var agent: Agent = .{
        .gpa = std.testing.allocator,
        .arena = a,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{
            .id = "xai",
            .kind = .responses,
            .auth = .bearer,
            .url = "",
            .api_key = "k",
            .model = "grok-4.6",
            .context = 100_000,
        },
        .messages = msgs,
        .sub = false,
        .label = "test",
        .out = null,
        .codex_prev_id = try std.testing.allocator.dupe(u8, "resp_drop_me"),
        .codex_sent_upto = 1,
    };
    defer if (agent.codex_prev_id) |p| std.testing.allocator.free(p);
    remember("Fix atomic_write.py");
    defer resetForTest();
    try std.testing.expect(try handle(&agent, "I'll read SPEC.md"));
    try std.testing.expect(agent.codex_prev_id == null);
    try std.testing.expectEqual(@as(usize, 0), agent.codex_sent_upto);
    try std.testing.expect(isResponsesInputText(agent.messages.items[agent.messages.items.len - 1], nudge_text));
    messages_mod.normalizeResponsesHistory(a, &agent.messages);
    try std.testing.expect(isResponsesInputText(agent.messages.items[0], "Fix atomic_write.py"));
    try std.testing.expect(isResponsesInputText(agent.messages.items[agent.messages.items.len - 1], nudge_text));
    try std.testing.expect(!try handle(&agent, "I'll read SPEC.md"));
}

fn testAgent(arena: std.mem.Allocator, msgs: std.json.Array) Agent {
    return .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .io = std.testing.io,
        .client = undefined,
        .provider = .{
            .id = "xai",
            .kind = .openai,
            .auth = .bearer,
            .url = "",
            .api_key = "k",
            .model = "grok-4.6",
            .context = 100_000,
        },
        .messages = msgs,
        .sub = false,
        .label = "test",
        .out = null,
    };
}

test "#714: a later greeting does not re-fire because history still names SPEC.md" {
    resetForTest();
    defer resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    try msgs.append(try messages_mod.textMessage(a, "user", "Read SPEC.md and explain affinity"));
    try msgs.append(try messages_mod.textMessage(a, "assistant", "affinity is keyed on the git root"));
    try msgs.append(try messages_mod.textMessage(a, "user", "thanks"));
    var agent = testAgent(a, msgs);
    rememberFrom(&agent);
    try std.testing.expectEqualStrings("thanks", agent.named_work_task);
    try std.testing.expect(conversationNamesSource(agent.messages.items));
    try std.testing.expect(!try handle(&agent, "you're welcome"));
}

test "#714: tools on a named path settle the gate for that mention" {
    resetForTest();
    defer resetForTest();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    try msgs.append(try messages_mod.textMessage(a, "user", "Fix fib.py"));
    var agent = testAgent(a, msgs);
    remember("Fix fib.py");
    agent.tools_used.add(agent.io, a, "read_file", false);
    try std.testing.expect(!try handle(&agent, "I read fib.py"));
    agent.tools_used.clear(agent.io);
    agent.named_work_nudges = 0;
    try std.testing.expect(!try handle(&agent, "still fib.py"));
}

test "#714: handle reads the Agent copy, not a process-global leftover" {
    resetForTest();
    defer resetForTest();
    remember("Fix scout_worker.py"); // what a finished child's arena used to leave behind
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var msgs = std.json.Array.init(a);
    try msgs.append(try messages_mod.textMessage(a, "user", "thanks"));
    var agent = testAgent(a, msgs);
    rememberOn(&agent, "thanks");
    try std.testing.expect(!try handle(&agent, "you're welcome"));
}
