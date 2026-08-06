//! TuiSink's half of the tool-execution cluster (#422 slice 1c): the terminal
//! rendering for the tool events engine_events.zig defines — the ⚙ call line,
//! the compact ✓/✗/⊘ result line, the parallel-batch tallies, and the
//! meta-tool notices. Frontend territory, like agent_stream_render.zig: this
//! is the ONLY file in the tool cluster that reaches the terminal palette, and
//! engine_sink.zig is its only caller.
//!
//! Every function here is the old inline agent_tools.zig code path, gate for
//! gate and byte for byte, with two deliberate mechanical differences:
//! - text is rendered whole and handed to agent_output.sayText, which is
//!   say()'s runtime-string sibling (same routing, same worker-line framing);
//! - write errors are swallowed rather than propagated, because a sink's emit
//!   path returns void. A caller that used to abort its batch on a broken
//!   stdout now continues into the next failing write instead.

const std = @import("std");
const Io = std.Io;

const main_mod = @import("main.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const agent_output = @import("agent_output.zig");
const sayText = agent_output.sayText;
const util = @import("util.zig"); // tests only: repeatBytes for the arg-cap case

const ansi = @import("ansi.zig");
const style = &ansi.style;

const engine_events = @import("engine_events.zig");
const ToolInvocation = engine_events.ToolInvocation;
const ToolOutcome = engine_events.ToolOutcome;
const BatchOutcome = engine_events.BatchOutcome;

/// How much of a call's JSON arguments the ⚙ line shows. A byte cap, not a
/// character one: the cut may split a UTF-8 sequence, exactly as before.
const arg_preview_bytes: usize = 160;
/// How much of a result's first line the ✓ line shows.
const result_preview_bytes: usize = 100;

/// The ⚙ announcement line. Suppressed when the call's prose already streamed
/// live out of its arguments — the line would just repeat what was read.
pub fn toolUseLine(a: *Agent, t: ToolInvocation) void {
    if (t.arg_streamed) return;
    var args: Io.Writer.Allocating = .init(a.gpa);
    defer args.deinit();
    var s: std.json.Stringify = .{ .writer = &args.writer };
    s.write(t.input) catch return;
    const full = args.writer.buffered();
    const shown = if (full.len > arg_preview_bytes) full[0..arg_preview_bytes] else full;
    var line: Io.Writer.Allocating = .init(a.gpa);
    defer line.deinit();
    line.writer.print("{s}⚙{s} {s}{s} {s}{s}{s}{s}\n", .{
        style.dim,   style.reset, style.accent, t.name,
        style.dim,   shown,
        if (full.len > arg_preview_bytes) "…" else "",
        style.reset,
    }) catch return;
    sayText(a, line.writer.buffered());
}

/// Compact result feedback for one finished tool call: a green ✓ / red ✗ /
/// yellow ⊘ and a one-line preview of what it returned. Root only (subagents
/// have no writer); meta tools render their own UX, so skip them. This one
/// writes straight to the writer — it never ended a tick-gate row.
pub fn toolResultLine(a: *Agent, r: ToolOutcome) void {
    const w = a.out orelse return;
    if (r.meta) return;
    const all = std.mem.trim(u8, r.text, " \t\r\n");
    var preview = all;
    if (std.mem.indexOfScalar(u8, preview, '\n')) |nl| preview = preview[0..nl];
    preview = std.mem.trim(u8, preview, " \t\r");
    const shown = if (preview.len > result_preview_bytes) preview[0..result_preview_bytes] else preview;
    const truncated = shown.len < all.len; // more content (extra lines or >100 chars)
    const mark = if (r.cancelled) "⊘" else if (r.is_error) "✗" else "✓";
    const mc = if (r.cancelled) style.yellow else if (r.is_error) style.red else style.green;
    var tbuf: [24]u8 = undefined;
    const timing = if (main_mod.show_timing and r.ms > 0)
        (std.fmt.bufPrint(&tbuf, " ({d}ms)", .{r.ms}) catch "")
    else
        "";
    w.print("  {s}{s}{s}{s}{s}{s} {s}{s}{s}{s}\n", .{
        mc,          mark,  style.reset, style.dim, timing, style.reset,
        style.dim,   shown,
        if (truncated) "…" else "",
        style.reset,
    }) catch return;
    w.flush() catch return;
}

// The batch tallies fit a fixed slot with room to spare: the widest line is
// three usize decimals plus ~50 bytes of wording and two short style runs.
const notice_buf_bytes: usize = 192;

pub fn parallelBatchStarted(a: *Agent, count: usize) void {
    if (a.sub) return; // a child's fan-out is the root's line to draw, not its own
    var buf: [notice_buf_bytes]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "  {s}↯ running {d} tools in parallel{s}\n", .{ style.dim, count, style.reset }) catch return;
    sayText(a, line);
}

pub fn parallelBatchFinished(a: *Agent, o: BatchOutcome) void {
    if (a.sub) return;
    var buf: [notice_buf_bytes]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "  {s}↯ parallel tools finished: {d} completed, {d} failed, {d} cancelled{s}\n", .{ style.dim, o.done, o.failed, o.cancelled, style.reset }) catch return;
    sayText(a, line);
}

/// #318: the checklist isn't settled, so the completion parks. The escapes are
/// the literal bytes the old call site spelled out (⏸, 🎯 below).
pub fn completionDeferred(a: *Agent) void {
    if (a.sub) return;
    sayText(a, "\xe2\x8f\xb8 completion deferred \xe2\x80\x94 the standing goal's checklist isn't settled\n");
}

pub fn goalCompleted(a: *Agent) void {
    sayText(a, "\xf0\x9f\x8e\xaf standing goal complete\n");
}

/// A meta tool's own user-facing text, one line, exactly as it came.
pub fn toolTextLine(a: *Agent, text: []const u8) void {
    if (a.sub) return;
    var line: Io.Writer.Allocating = .init(a.gpa);
    defer line.deinit();
    line.writer.print("{s}\n", .{text}) catch return;
    sayText(a, line.writer.buffered());
}

fn testAgent(w: *Io.Writer) Agent {
    return .{
        .gpa = std.testing.allocator,
        .arena = std.testing.allocator,
        .io = undefined,
        .client = undefined,
        .provider = undefined,
        .messages = undefined,
        .sub = false,
        .label = "test",
        .out = w,
    };
}

test "the ⚙ line reproduces the old inline announcement, cap and ellipsis included" {
    const saved = ansi.style;
    ansi.style = .{}; // no color: assert the text, not the palette
    defer ansi.style = saved;
    const saved_json = main_mod.json_mode; // sayText's root gate reads it
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);

    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), "{\"path\":\"fixture.txt\"}", .{});
    toolUseLine(&a, .{ .name = "read_file", .input = input });
    try std.testing.expectEqualStrings("⚙ read_file {\"path\":\"fixture.txt\"}\n", aw.writer.buffered());

    // Prose that already streamed live is not announced a second time.
    aw.clearRetainingCapacity();
    toolUseLine(&a, .{ .name = "attempt_completion", .input = input, .arg_streamed = true });
    try std.testing.expectEqualStrings("", aw.writer.buffered());

    // Over the cap: exactly arg_preview_bytes of JSON, then the ellipsis.
    aw.clearRetainingCapacity();
    const long = try std.fmt.allocPrint(arena_state.allocator(), "{{\"q\":\"{s}\"}}", .{&util.repeatBytes("x", 400)});
    const long_input = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), long, .{});
    toolUseLine(&a, .{ .name = "codedb", .input = long_input });
    const line = aw.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, line, "⚙ codedb {\"q\":\"xxx"));
    try std.testing.expect(std.mem.endsWith(u8, line, "…\n"));
    try std.testing.expectEqual(arg_preview_bytes, line.len - "⚙ codedb ".len - "…\n".len);
}

test "the result line marks success, failure and cancellation and previews one line" {
    const saved = ansi.style;
    ansi.style = .{};
    defer ansi.style = saved;
    const saved_timing = main_mod.show_timing;
    main_mod.show_timing = false;
    defer main_mod.show_timing = saved_timing;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);

    toolResultLine(&a, .{ .name = "read_file", .text = "line one\nline two\n", .is_error = false });
    try std.testing.expectEqualStrings("  ✓ line one…\n", aw.writer.buffered());

    aw.clearRetainingCapacity();
    toolResultLine(&a, .{ .name = "bash", .text = "boom", .is_error = true });
    try std.testing.expectEqualStrings("  ✗ boom\n", aw.writer.buffered());

    aw.clearRetainingCapacity();
    toolResultLine(&a, .{ .name = "bash", .text = "stopped", .is_error = true, .cancelled = true });
    try std.testing.expectEqualStrings("  ⊘ stopped\n", aw.writer.buffered());

    // Meta tools draw their own UX; the ✓ line stays out of their way.
    aw.clearRetainingCapacity();
    toolResultLine(&a, .{ .name = "todo_write", .text = "todos", .is_error = false, .meta = true });
    try std.testing.expectEqualStrings("", aw.writer.buffered());

    // --timing adds the measured duration between the mark and the preview.
    aw.clearRetainingCapacity();
    main_mod.show_timing = true;
    toolResultLine(&a, .{ .name = "bash", .text = "ok", .is_error = false, .ms = 42 });
    try std.testing.expectEqualStrings("  ✓ (42ms) ok\n", aw.writer.buffered());
}

test "batch tallies and meta notices render the old wording verbatim" {
    const saved = ansi.style;
    ansi.style = .{};
    defer ansi.style = saved;
    const saved_json = main_mod.json_mode; // sayText's root gate reads it
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);

    parallelBatchStarted(&a, 3);
    try std.testing.expectEqualStrings("  ↯ running 3 tools in parallel\n", aw.writer.buffered());

    aw.clearRetainingCapacity();
    parallelBatchFinished(&a, .{ .done = 2, .failed = 1, .cancelled = 0 });
    try std.testing.expectEqualStrings("  ↯ parallel tools finished: 2 completed, 1 failed, 0 cancelled\n", aw.writer.buffered());

    aw.clearRetainingCapacity();
    completionDeferred(&a);
    try std.testing.expectEqualStrings("⏸ completion deferred — the standing goal's checklist isn't settled\n", aw.writer.buffered());

    aw.clearRetainingCapacity();
    goalCompleted(&a);
    try std.testing.expectEqualStrings("🎯 standing goal complete\n", aw.writer.buffered());

    aw.clearRetainingCapacity();
    toolTextLine(&a, "completion recorded");
    try std.testing.expectEqualStrings("completion recorded\n", aw.writer.buffered());

    // A subagent announces none of the root's batch/goal lines.
    aw.clearRetainingCapacity();
    a.sub = true;
    parallelBatchStarted(&a, 3);
    parallelBatchFinished(&a, .{ .done = 1, .failed = 0, .cancelled = 0 });
    completionDeferred(&a);
    toolTextLine(&a, "x");
    try std.testing.expectEqualStrings("", aw.writer.buffered());
}
