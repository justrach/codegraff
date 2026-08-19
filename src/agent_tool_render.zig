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
//!
//! WHO may announce a moment stays engine policy: the `!self.sub` gates on the
//! batch tallies and the meta notices remain at their emit sites, so nothing
//! here back-reads Agent policy to decide whether to draw. The only Agent
//! reads below are drawing handles — the writer and the allocator.

const std = @import("std");
const Io = std.Io;

const main_mod = @import("main.zig");
const repl = @import("repl.zig"); // g_debug gate for the spill notice
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;
const agent_output = @import("agent_output.zig");
const sayText = agent_output.sayText;
const util = @import("util.zig"); // tests only: repeatBytes for the two cap cases

const ansi = @import("ansi.zig");
const style = &ansi.style;

const engine_events = @import("engine_events.zig");
const ToolInvocation = engine_events.ToolInvocation;
const ToolOutcome = engine_events.ToolOutcome;
const BatchOutcome = engine_events.BatchOutcome;

/// Keep tool activity useful without dumping model-facing JSON into the REPL.
const detail_preview_bytes: usize = 96;
/// How much of a result's first line the ✓ line shows.
const result_preview_bytes: usize = 100;

fn stringField(input: std.json.Value, field: []const u8) ?[]const u8 {
    if (input != .object) return null;
    const value = input.object.get(field) orelse return null;
    return if (value == .string) value.string else null;
}

/// Pick one human-readable field for tools whose intent is obvious from a path,
/// command, URL, or short label. Unknown tools still get a name-only line.
fn toolDetail(t: ToolInvocation) []const u8 {
    const field = if (std.mem.eql(u8, t.name, "bash"))
        "command"
    else if (std.mem.eql(u8, t.name, "read_file") or
        std.mem.eql(u8, t.name, "edit_file") or
        std.mem.eql(u8, t.name, "write_file"))
        "path"
    else if (std.mem.eql(u8, t.name, "webfetch"))
        "url"
    else if (std.mem.eql(u8, t.name, "codedb"))
        "command"
    else if (std.mem.eql(u8, t.name, "subagent"))
        "description"
    else if (std.mem.eql(u8, t.name, "imagegen"))
        "prompt"
    else if (std.mem.eql(u8, t.name, "peer_message")) blk: {
        if (stringField(t.input, "action")) |act| {
            if (act.len > 0 and !std.mem.eql(u8, act, "send")) break :blk "action";
        }
        break :blk "text";
    } else if (std.mem.eql(u8, t.name, "workspace")) blk: {
        if (stringField(t.input, "path")) |p| if (p.len > 0) break :blk "path";
        break :blk "action";
    } else return "";
    const detail = stringField(t.input, field) orelse return "";
    const end = std.mem.indexOfScalar(u8, detail, '\n') orelse detail.len;
    return std.mem.trim(u8, detail[0..end], " \t\r");
}

/// A terse activity line: always show ordinary tool calls, but never their raw
/// argument object. Suppress only user-facing prose that already streamed live.
pub fn toolUseLine(a: *Agent, t: ToolInvocation) void {
    if (t.arg_streamed) return;
    const detail = toolDetail(t);
    const shown = if (detail.len > detail_preview_bytes) detail[0..detail_preview_bytes] else detail;
    var line: Io.Writer.Allocating = .init(a.gpa);
    defer line.deinit();
    line.writer.print("{s}⚙{s} {s}{s}{s}", .{ style.dim, style.reset, style.accent, t.name, style.reset }) catch return;
    if (shown.len > 0) line.writer.print("{s} · {s}{s}{s}", .{
        style.dim,
        shown,
        if (shown.len < detail.len) "…" else "",
        style.reset,
    }) catch return;
    line.writer.writeByte('\n') catch return;
    sayText(a, line.writer.buffered());
}

/// Normal-mode announcement: name only. The JSON preview stays behind
/// GRAFF_REPL_DEBUG so the default session is not a dump.
pub fn toolCompactUse(a: *Agent, name: []const u8) void {
    var buf: [160]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}⚙{s} {s}\n", .{ style.dim, style.reset, name }) catch return;
    sayText(a, line);
}

/// Normal-mode result: mark + name. The one-line preview stays in debug.
pub fn toolCompactResult(a: *Agent, r: ToolOutcome) void {
    if (r.meta) return;
    const w = a.out orelse return;
    const mark = if (r.cancelled) "⊘" else if (r.is_error) "✗" else "✓";
    const mc = if (r.cancelled) style.yellow else if (r.is_error) style.red else style.green;
    w.print("  {s}{s}{s} {s}\n", .{ mc, mark, style.reset, r.name }) catch return;
    w.flush() catch {};
}

/// The #440 marker prefixes forResult tags oversized results with. Detected
/// off the result text itself, so the badge needs no new field on the event
/// vocabulary (and no SDK schema change).
const handle_marker = "[tool result handle: ";
const truncated_marker = "[tool result truncated to ";

const HandleBadge = struct { bytes: usize, truncated: bool };

/// Parse the spill size out of a #440 marker line, null for ordinary results.
fn handleBadge(text: []const u8) ?HandleBadge {
    if (std.mem.startsWith(u8, text, handle_marker)) {
        const rest = text[handle_marker.len..];
        const end = std.mem.indexOf(u8, rest, " bytes") orelse return null;
        const n = std.fmt.parseInt(usize, rest[0..end], 10) catch return null;
        return .{ .bytes = n, .truncated = false };
    }
    // "[tool result truncated to {shown} bytes: {total} bytes total, …"
    if (std.mem.startsWith(u8, text, truncated_marker)) {
        const rest = text[truncated_marker.len..];
        const cut = std.mem.indexOf(u8, rest, " bytes: ") orelse return null;
        const rest2 = rest[cut + " bytes: ".len ..];
        const end = std.mem.indexOf(u8, rest2, " bytes total") orelse return null;
        const n = std.fmt.parseInt(usize, rest2[0..end], 10) catch return null;
        return .{ .bytes = n, .truncated = true };
    }
    return null;
}

/// Compact result feedback for one finished tool call: a green ✓ / red ✗ /
/// yellow ⊘ and a one-line preview of what it returned. A result that spilled
/// to a #440 handle (or was truncated without one) also badges the spill size —
/// the handle costs the model a follow-up read round-trip, and that cost
/// should be visible to the human, not silent. Root only (subagents have no
/// writer); meta tools render their own UX, so skip them. This one
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
    // Badge colors are self-contained; ordinary result lines stay byte-identical.
    var bbuf: [48]u8 = undefined;
    const badge = if (handleBadge(all)) |h| blk: {
        const kib = @as(f64, @floatFromInt(h.bytes)) / 1024.0;
        break :blk if (h.truncated)
            std.fmt.bufPrint(&bbuf, "{s}⇠ {d:.1} KiB lost{s}", .{ style.yellow, kib, style.reset }) catch ""
        else
            std.fmt.bufPrint(&bbuf, "{s}⇢ {d:.1} KiB handle{s}", .{ style.accent, kib, style.reset }) catch "";
    } else "";
    w.print("  {s}{s}{s} {s}{s}{s}{s}{s}{s}{s}{s}", .{
        mc,          mark,                           style.reset, style.accent, r.name, style.reset, style.dim, timing,
        style.reset, if (badge.len > 0) " " else "", badge,
    }) catch return;
    if (shown.len > 0) w.print(" · {s}{s}", .{ shown, if (truncated) "…" else "" }) catch return;
    w.print("{s}\n", .{style.reset}) catch return;
    w.flush() catch return;
}

/// Normal-mode spill notice (#440): the one tool-result moment the terminal
/// draws outside debug mode. A spilled result costs the model a follow-up
/// read round-trip, and that cost should be visible rather than silent —
/// debug mode already shows it as the badge on the full ✓ line, so this
/// stays quiet there (and in --json, where the wire event carries it).
pub fn handleSpillLine(a: *Agent, bytes: usize, has_handle: bool) void {
    if (main_mod.json_mode) return;
    if (repl.g_debug) return;
    const w = a.out orelse return;
    const kib = @as(f64, @floatFromInt(bytes)) / 1024.0;
    var buf: [72]u8 = undefined;
    const line = if (has_handle)
        std.fmt.bufPrint(&buf, "  {s}⇢ {d:.1} KiB handle{s}\n", .{ style.accent, kib, style.reset }) catch return
    else
        std.fmt.bufPrint(&buf, "  {s}⇠ {d:.1} KiB lost{s}\n", .{ style.yellow, kib, style.reset }) catch return;
    w.writeAll(line) catch return;
    w.flush() catch return;
}

/// Turn-start note when effort routing (effort_route.zig) moved a
/// lookup-shaped turn to low effort: the prompt line was drawn before the
/// prompt existed, so it still shows the session knob — this one dim line is
/// what the turn actually ran at. Normal mode only; debug and --json already
/// carry the truth (the request's thinking.effort / the event stream).
pub fn routedEffortLine(a: *Agent) void {
    if (main_mod.json_mode) return;
    if (repl.g_debug) return;
    const w = a.out orelse return;
    var buf: [80]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "  {s}⇣ lookup turn — routed to effort low for this turn{s}\n", .{ style.dim, style.reset }) catch return;
    w.writeAll(line) catch return;
    w.flush() catch return;
}

// The batch tallies fit a fixed slot with room to spare: the widest line is
// three usize decimals plus ~50 bytes of wording and two short style runs.
const notice_buf_bytes: usize = 192;

pub fn parallelBatchStarted(a: *Agent, count: usize) void {
    var buf: [notice_buf_bytes]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "  {s}↯ running {d} tools in parallel{s}\n", .{ style.dim, count, style.reset }) catch return;
    sayText(a, line);
}

pub fn parallelBatchFinished(a: *Agent, o: BatchOutcome) void {
    var buf: [notice_buf_bytes]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "  {s}↯ parallel tools finished: {d} completed, {d} failed, {d} cancelled{s}\n", .{ style.dim, o.done, o.failed, o.cancelled, style.reset }) catch return;
    sayText(a, line);
}

/// #318: the checklist isn't settled, so the completion parks. The escapes are
/// the literal bytes the old call site spelled out (⏸, 🎯 below).
pub fn completionDeferred(a: *Agent) void {
    sayText(a, "\xe2\x8f\xb8 completion deferred \xe2\x80\x94 the standing goal's checklist isn't settled\n");
}

pub fn goalCompleted(a: *Agent) void {
    sayText(a, "\xf0\x9f\x8e\xaf standing goal complete\n");
}

/// A meta tool's own user-facing text, one line, exactly as it came.
pub fn toolTextLine(a: *Agent, text: []const u8) void {
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
    try std.testing.expectEqualStrings("⚙ read_file · fixture.txt\n", aw.writer.buffered());

    // Prose that already streamed live is not announced a second time.
    aw.clearRetainingCapacity();
    toolUseLine(&a, .{ .name = "attempt_completion", .input = input, .arg_streamed = true });
    try std.testing.expectEqualStrings("", aw.writer.buffered());

    // Unknown tools remain visible without leaking arbitrary argument JSON.
    aw.clearRetainingCapacity();
    toolUseLine(&a, .{ .name = "todo_write", .input = input });
    try std.testing.expectEqualStrings("⚙ todo_write\n", aw.writer.buffered());

    // Long readable details are capped to one terse line.
    aw.clearRetainingCapacity();
    const long = try std.fmt.allocPrint(arena_state.allocator(), "{{\"command\":\"{s}\"}}", .{&util.repeatBytes("x", 400)});
    const long_input = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), long, .{});
    toolUseLine(&a, .{ .name = "bash", .input = long_input });
    const line = aw.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, line, "⚙ bash · xxx"));
    try std.testing.expect(std.mem.endsWith(u8, line, "…\n"));
    try std.testing.expectEqual(@as(usize, 96), line.len - "⚙ bash · ".len - "…\n".len);
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
    try std.testing.expectEqualStrings("  ✓ read_file · line one…\n", aw.writer.buffered());

    aw.clearRetainingCapacity();
    toolResultLine(&a, .{ .name = "bash", .text = "boom", .is_error = true });
    try std.testing.expectEqualStrings("  ✗ bash · boom\n", aw.writer.buffered());

    aw.clearRetainingCapacity();
    toolResultLine(&a, .{ .name = "bash", .text = "stopped", .is_error = true, .cancelled = true });
    try std.testing.expectEqualStrings("  ⊘ bash · stopped\n", aw.writer.buffered());

    // Meta tools draw their own UX; the ✓ line stays out of their way.
    aw.clearRetainingCapacity();
    toolResultLine(&a, .{ .name = "todo_write", .text = "todos", .is_error = false, .meta = true });
    try std.testing.expectEqualStrings("", aw.writer.buffered());

    // Over the cap: exactly 100 bytes of the first line, then the ellipsis —
    // the literal the pre-#422 inline path spelled out, not result_preview_bytes.
    aw.clearRetainingCapacity();
    const long = util.repeatBytes("z", 250);
    toolResultLine(&a, .{ .name = "bash", .text = &long, .is_error = false });
    const rline = aw.writer.buffered();
    try std.testing.expect(std.mem.endsWith(u8, rline, "…\n"));
    try std.testing.expectEqual(@as(usize, 100), rline.len - "  ✓ bash · ".len - "…\n".len);

    // --timing adds the measured duration between the mark and the preview.
    aw.clearRetainingCapacity();
    main_mod.show_timing = true;
    toolResultLine(&a, .{ .name = "bash", .text = "ok", .is_error = false, .ms = 42 });
    try std.testing.expectEqualStrings("  ✓ bash (42ms) · ok\n", aw.writer.buffered());

    // A #440 handle spill badges its size after the tool name while the preview
    // still leads with the marker, so the handle path stays visible.
    aw.clearRetainingCapacity();
    main_mod.show_timing = false;
    toolResultLine(&a, .{ .name = "bash", .text = "[tool result handle: 44690 bytes, JSON object — the COMPLETE result is at /tmp/h-0.txt. Slice what you need out of that file (read_file with start_line/end_line, a grep-style bash command, codedb) instead of re-running the tool (#440).]", .is_error = false });
    const hline = aw.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, hline, "  ✓ bash ⇢ 43.6 KiB handle · [tool result handle: 44690 bytes"));

    // The no-handle truncation variant badges the loss instead.
    aw.clearRetainingCapacity();
    toolResultLine(&a, .{ .name = "bash", .text = "[tool result truncated to 16384 bytes: 90000 bytes total, JSON object. No handle could be written, so the rest is gone — narrow the command and run it again (#440).]", .is_error = false });
    try std.testing.expect(std.mem.startsWith(u8, aw.writer.buffered(), "  ✓ bash ⇠ 87.9 KiB lost · [tool result truncated"));
}

test "the spill notice draws in normal mode and stays quiet in debug mode" {
    const saved = ansi.style;
    ansi.style = .{};
    defer ansi.style = saved;
    const saved_json = main_mod.json_mode;
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    const saved_debug = repl.g_debug;
    repl.g_debug = false;
    defer repl.g_debug = saved_debug;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);

    handleSpillLine(&a, 44690, true);
    try std.testing.expectEqualStrings("  ⇢ 43.6 KiB handle\n", aw.writer.buffered());

    aw.clearRetainingCapacity();
    handleSpillLine(&a, 90000, false);
    try std.testing.expectEqualStrings("  ⇠ 87.9 KiB lost\n", aw.writer.buffered());

    // Debug mode already draws the badge on the full ✓ line — no double draw.
    aw.clearRetainingCapacity();
    repl.g_debug = true;
    handleSpillLine(&a, 44690, true);
    try std.testing.expectEqualStrings("", aw.writer.buffered());

    // The effort-routing note follows the same gates: normal mode only.
    repl.g_debug = false;
    aw.clearRetainingCapacity();
    routedEffortLine(&a);
    try std.testing.expectEqualStrings("  ⇣ lookup turn — routed to effort low for this turn\n", aw.writer.buffered());
    aw.clearRetainingCapacity();
    repl.g_debug = true;
    routedEffortLine(&a);
    try std.testing.expectEqualStrings("", aw.writer.buffered());
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

    // Who may announce these is engine policy, not a drawing decision: the
    // `!self.sub` gates live at the emit sites (agent_tools.runTools /
    // handleMeta), so a subagent never produces the moment at all and this
    // file needs no read into the Agent to suppress it.
}
