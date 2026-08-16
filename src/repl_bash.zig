//! `!cmd` — the user's own shell line, run through the ENGINE (#551).
//!
//! It used to call process_runner.runCapped directly from the TUI glue, which
//! skipped every rail the same command gets when the model asks for it: no
//! approval gate, no plan-mode denial, no hooks, no tracer, no tool
//! accounting. `/plan` then `!rm -rf build` ran the rm. And because the output
//! went straight to a system row, the model never saw what the user had just
//! run, so the next question about it landed with no context.
//!
//! Now it builds the same ToolCall the model's `bash` tool produces, sends it
//! through Agent.gateTool and exec.execTool, and folds the command and its
//! output into the session conversation. Esc still lands: process_runner polls
//! Agent.esc_cancel, which is what the frontend's cancel callback sets.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const approvals_mod = @import("approvals.zig");
const Approvals = approvals_mod.Approvals;
const exec = @import("exec.zig");
const tools_mod = @import("tools.zig");
const ToolCall = tools_mod.ToolCall;
const repl = @import("repl.zig");
const repl_glue = @import("repl_glue.zig");
const repl_turn = @import("repl_turn.zig");
const ReplCtx = repl_glue.ReplCtx;

/// How much of a `!` command's output the model is shown. The transcript row
/// is already tailed for display; this bound is about the request body, where
/// a 200 KB build log would evict the rest of the conversation.
pub const note_cap: usize = 4000;

/// Run `cmd` exactly as the bash TOOL runs it. Returns the combined output
/// (gpa-owned, the frontend frees it) or the gate's refusal text; null only
/// when the harness could not produce either.
pub fn replBashCb(ctx_ptr: ?*anyopaque, gpa: Allocator, cmd: []const u8, params: repl.Params) ?[]const u8 {
    const c: *ReplCtx = @ptrCast(@alignCast(ctx_ptr orelse return null));
    // A cancel that ended the PREVIOUS op must not kill this one before it
    // starts: esc_cancel is a process-wide latch and a turn clears it the same
    // way at its own start.
    Agent.esc_cancel.store(false, .release);
    var scratch_state = std.heap.ArenaAllocator.init(gpa);
    defer scratch_state.deinit();
    const arena = scratch_state.allocator();
    var discard_buf: [256]u8 = undefined;
    var discarding: Io.Writer.Discarding = .init(&discard_buf);

    const policy = repl_turn.Policy.from(params);
    const plan_saved = main_mod.plan_mode;
    main_mod.plan_mode = policy.plan;
    defer main_mod.plan_mode = plan_saved;
    var approvals: Approvals = .{ .yolo = policy.yolo };
    var agent = repl_turn.turnAgent(c, gpa, arena, params, &discarding.writer, &approvals) catch return null;
    defer agent.tools_used.deinit(gpa);

    var input: std.json.ObjectMap = .empty;
    input.put(arena, "command", .{ .string = cmd }) catch return null;
    const call: ToolCall = .{ .id = "tui-bang", .name = "bash", .input = .{ .object = input } };

    if (agent.gateTool(call)) |maybe_denied| {
        if (maybe_denied) |denied| {
            // The refusal is the user's answer AND the model's: it explains why
            // nothing ran, and the next prompt is usually about that.
            noteToModel(c, gpa, cmd, denied.text);
            return gpa.dupe(u8, denied.text) catch null;
        }
    } else |_| return null;

    const result = exec.execTool(.{
        .gpa = gpa,
        .io = c.io,
        .client = c.client,
        .provider = c.provider,
        .registry = c.registry,
        .from_sub = false,
        .approvals = &approvals,
        .tracer = c.tracer,
        .run_budget = c.run_budget,
        .tools_used = &agent.tools_used,
    }, call);
    noteToModel(c, gpa, cmd, result.text);
    return result.text; // gpa-owned, exactly what BashFn promises
}

/// Put the command and what it printed into the conversation, so the model can
/// answer "why did that fail?" without being told the whole thing again.
fn noteToModel(c: *ReplCtx, gpa: Allocator, cmd: []const u8, output: []const u8) void {
    const cv = c.convo orelse return;
    const shown = capped(output, note_cap);
    const line = std.fmt.allocPrint(
        gpa,
        "I ran a shell command myself:\n$ {s}\n\n{s}{s}",
        .{ cmd, shown, if (shown.len < output.len) "\n[output truncated]" else "" },
    ) catch return;
    defer gpa.free(line);
    cv.note(line) catch {};
}

/// Head of `text`, at most `cap` bytes and never splitting a UTF-8 sequence —
/// half a codepoint here would be half a codepoint on the wire.
pub fn capped(text: []const u8, cap: usize) []const u8 {
    if (text.len <= cap) return text;
    var end = cap;
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return text[0..end];
}

const testing = std.testing;

fn lastNote(convo: *repl_glue.Conversation) []const u8 {
    const items = convo.list().items;
    if (items.len == 0) return "";
    return items[items.len - 1].object.get("content").?.string;
}

test "!cmd runs through the engine's gate, and plan mode refuses it (#551)" {
    const gpa = testing.allocator;
    var client: std.http.Client = undefined;
    var c = repl_turn.testCtx(&client);
    var convo = repl_glue.Conversation.init(gpa);
    defer convo.deinit();
    c.convo = &convo;
    const saved_plan = main_mod.plan_mode;
    defer main_mod.plan_mode = saved_plan;

    // Plan mode: the command never runs, so its output never appears.
    const refused = replBashCb(&c, gpa, "printf bang-sentinel", .{ .mode = .plan }) orelse
        return error.NoResult;
    defer gpa.free(refused);
    try testing.expect(std.mem.indexOf(u8, refused, "plan mode") != null);
    try testing.expect(std.mem.indexOf(u8, refused, "bang-sentinel") == null);
    // …and the refusal is in the conversation, because the next prompt is
    // usually "why didn't that work?".
    try testing.expect(std.mem.indexOf(u8, lastNote(&convo), "plan mode") != null);
    const after_refusal = convo.len();

    // The same command outside plan mode runs and produces its output.
    const ran = replBashCb(&c, gpa, "printf bang-sentinel", .{ .mode = .always_approve }) orelse
        return error.NoResult;
    defer gpa.free(ran);
    try testing.expect(std.mem.indexOf(u8, ran, "bang-sentinel") != null);

    // The model sees the command AND what it printed — the old `!` path put
    // the output on a system row the conversation never carried.
    try testing.expectEqual(after_refusal + 1, convo.len());
    const note = lastNote(&convo);
    try testing.expect(std.mem.indexOf(u8, note, "$ printf bang-sentinel") != null);
    try testing.expect(std.mem.indexOf(u8, note, "bang-sentinel") != null);
    // plan_mode is a process global: the op restores whatever it found.
    try testing.expectEqual(saved_plan, main_mod.plan_mode);
}

test "a session with no conversation still runs !cmd and keeps no note" {
    const gpa = testing.allocator;
    var client: std.http.Client = undefined;
    var c = repl_turn.testCtx(&client);
    const out = replBashCb(&c, gpa, "printf no-convo", .{ .mode = .always_approve }) orelse
        return error.NoResult;
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "no-convo") != null);
}

test "capped never splits a multi-byte character" {
    try testing.expectEqualStrings("abc", capped("abc", 8));
    // "…" is three bytes; a cap landing inside it must drop the whole glyph.
    try testing.expectEqualStrings("ab", capped("ab…cd", 3));
    try testing.expectEqualStrings("ab…", capped("ab…cd", 5));
    try testing.expect(std.unicode.utf8ValidateSlice(capped("ab…cd", 4)));
}
