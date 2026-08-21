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
const label = @import("agent_tool_label.zig");

/// How many sibling tools are still outstanding in the current parallel batch.
/// 0 = sequential (no tree). The layout, not a "↯ N in parallel" line, is
/// what shows fan-out (variation 4).
var batch_left: usize = 0;

fn treePrefix() []const u8 {
    if (batch_left == 0) return "  ";
    const last = batch_left == 1;
    batch_left -= 1;
    return if (last) "  └─ " else "  ├─ ";
}

/// Remember the call so the ✓ line can say `test` / `edit` instead of `bash`.
/// Default session is result-only — announce lines doubled the visual weight.
pub fn toolUseLine(a: *Agent, t: ToolInvocation) void {
    _ = a;
    if (t.arg_streamed) return;
    var vbuf: [16]u8 = undefined;
    var dbuf: [128]u8 = undefined;
    const v = label.verb(t.name, t.input, &vbuf);
    const d = label.detail(t, &dbuf);
    const shown = if (d.len > label.detail_preview_bytes) d[0..label.detail_preview_bytes] else d;
    label.remember(t.name, v, shown);
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

const Preview = struct { text: []const u8, clipped: bool };

/// First useful line — or a short summary. Handle markers stay off the line;
/// the badge already said the result spilled.
fn resultPreview(name: []const u8, all: []const u8, buf: []u8) Preview {
    if (handleBadge(all) != null) return .{ .text = "", .clipped = false };
    if (std.mem.startsWith(u8, all, handle_marker) or std.mem.startsWith(u8, all, truncated_marker))
        return .{ .text = "", .clipped = false };
    const raw = label.interpret(name, all, buf);
    if (raw.len > label.result_preview_bytes) return .{ .text = raw[0..label.result_preview_bytes], .clipped = true };
    return .{ .text = raw, .clipped = false };
}

/// Same family of transport death already named this turn. The transcript
/// says it once; later rows are inspectable in /debug, not conversational.
var infra_fam: []const u8 = "";
var infra_count: usize = 0;

pub fn resetInfra() void {
    infra_fam = "";
    infra_count = 0;
}

/// Live bash bytes belong in /debug (and the TUI fold), not the line REPL.
pub fn liveOutput(a: *Agent, text: []const u8) void {
    if (!repl.g_debug) return;
    const w = a.out orelse return;
    w.writeAll(text) catch return;
    w.flush() catch return;
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
    if (label.skipLineRepl(r.name)) return;
    const all = std.mem.trim(u8, r.text, " \t\r\n");
    if (r.is_error) {
        if (label.infraFamily(r.name, all)) |fam| {
            _ = treePrefix();
            infra_count += 1;
            if (infra_fam.len > 0 and std.mem.eql(u8, infra_fam, fam)) return;
            infra_fam = fam;
            w.print("  {s}! {s} unavailable{s}\n", .{ style.yellow, fam, style.reset }) catch return;
            w.flush() catch return;
            return;
        }
    }
    var pbuf: [48]u8 = undefined;
    const preview = resultPreview(r.name, all, &pbuf);
    const shown = preview.text;
    const truncated = preview.clipped;
    const mark = if (r.cancelled) "⊘" else if (r.is_error) "✗" else "✓";
    const mc = if (r.cancelled) style.yellow else if (r.is_error) style.red else style.green;
    var tbuf: [24]u8 = undefined;
    const timing = if (main_mod.show_timing and r.ms > 0)
        (std.fmt.bufPrint(&tbuf, " ({d}ms)", .{r.ms}) catch "")
    else
        "";
    var bbuf: [48]u8 = undefined;
    const badge = if (handleBadge(all)) |h| blk: {
        const kib = @as(f64, @floatFromInt(h.bytes)) / 1024.0;
        break :blk if (h.truncated)
            std.fmt.bufPrint(&bbuf, "{s}⇠ {d:.1} KiB lost{s}", .{ style.yellow, kib, style.reset }) catch ""
        else
            std.fmt.bufPrint(&bbuf, "{s}⇢ {d:.1} KiB handle{s}", .{ style.accent, kib, style.reset }) catch "";
    } else "";
    const remembered = label.take(r.name);
    const verb = if (remembered) |mem| mem.verb else r.name;
    const detail = if (remembered) |mem| mem.detail else "";
    const shown_final = label.usefulPreview(r.name, detail, shown);
    const prefix = treePrefix();
    w.print("{s}{s}{s}{s} {s}", .{ prefix, mc, mark, style.reset, verb }) catch return;
    if (detail.len > 0) w.print("  {s}", .{detail}) catch return;
    w.print("{s}{s}{s}", .{ style.dim, timing, style.reset }) catch return;
    if (badge.len > 0) w.print(" {s}", .{badge}) catch return;
    if (shown_final.len > 0) w.print("  {s}{s}{s}{s}", .{ style.dim, shown_final, if (truncated) "…" else "", style.reset }) catch return;
    w.writeAll("\n") catch return;
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
    _ = a;
    batch_left = if (count >= 2) count else 0;
}

pub fn parallelBatchFinished(a: *Agent, o: BatchOutcome) void {
    batch_left = 0;
    const infra_only = infra_count > 0 and o.failed == infra_count;
    if (infra_only) {
        resetInfra();
        return;
    }
    resetInfra();
    if (o.failed == 0 and o.cancelled == 0) return;
    var buf: [notice_buf_bytes]u8 = undefined;
    const line = if (o.cancelled == 0)
        std.fmt.bufPrint(&buf, "  {s}↯ {d} failed{s}\n", .{ style.dim, o.failed, style.reset })
    else if (o.failed == 0)
        std.fmt.bufPrint(&buf, "  {s}↯ {d} cancelled{s}\n", .{ style.dim, o.cancelled, style.reset })
    else
        std.fmt.bufPrint(&buf, "  {s}↯ {d} failed · {d} cancelled{s}\n", .{ style.dim, o.failed, o.cancelled, style.reset });
    sayText(a, line catch return);
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
    batch_left = 0;
    label.resetPending();
    resetInfra();
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

test "announce is silent and the ✓ line uses the remembered verb" {
    const saved = ansi.style;
    ansi.style = .{};
    defer ansi.style = saved;
    const saved_json = main_mod.json_mode;
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    label.resetPending();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);

    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), "{\"path\":\"fixture.txt\"}", .{});
    toolUseLine(&a, .{ .name = "read_file", .input = input });
    try std.testing.expectEqualStrings("", aw.writer.buffered());
    toolResultLine(&a, .{ .name = "read_file", .text = "line one\nline two\n", .is_error = false });
    try std.testing.expectEqualStrings("  ✓ read  fixture.txt  2 lines\n", aw.writer.buffered());

    aw.clearRetainingCapacity();
    toolUseLine(&a, .{ .name = "attempt_completion", .input = input, .arg_streamed = true });
    try std.testing.expectEqualStrings("", aw.writer.buffered());
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

    label.resetPending();
    toolResultLine(&a, .{ .name = "read_file", .text = "line one\nline two\n", .is_error = false });
    try std.testing.expectEqualStrings("  ✓ read_file  2 lines\n", aw.writer.buffered());

    aw.clearRetainingCapacity();
    toolResultLine(&a, .{ .name = "bash", .text = "boom", .is_error = true });
    try std.testing.expectEqualStrings("  ✗ bash  boom\n", aw.writer.buffered());

    aw.clearRetainingCapacity();
    toolResultLine(&a, .{ .name = "bash", .text = "stopped", .is_error = true, .cancelled = true });
    try std.testing.expectEqualStrings("  ⊘ bash  stopped\n", aw.writer.buffered());

    // Meta tools draw their own UX; the ✓ line stays out of their way.
    aw.clearRetainingCapacity();
    toolResultLine(&a, .{ .name = "todo_write", .text = "todos", .is_error = false, .meta = true });
    try std.testing.expectEqualStrings("", aw.writer.buffered());

    // ADR 0021: skill load and spilled-result paging are not conversational.
    aw.clearRetainingCapacity();
    toolResultLine(&a, .{ .name = "skill", .text = "# skill: deploy (plugin)\n", .is_error = false });
    try std.testing.expectEqualStrings("", aw.writer.buffered());
    toolResultLine(&a, .{ .name = "read_tool_result", .text = "hit 1 at byte 17378:\n", .is_error = false });
    try std.testing.expectEqualStrings("", aw.writer.buffered());

    // Over the cap: exactly 100 bytes of the first line, then the ellipsis —
    // the literal the pre-#422 inline path spelled out, not result_preview_bytes.
    aw.clearRetainingCapacity();
    const long = util.repeatBytes("z", 250);
    toolResultLine(&a, .{ .name = "bash", .text = &long, .is_error = false });
    const rline = aw.writer.buffered();
    try std.testing.expect(std.mem.endsWith(u8, rline, "…\n"));
    try std.testing.expectEqual(@as(usize, 100), rline.len - "  ✓ bash  ".len - "…\n".len);

    aw.clearRetainingCapacity();
    main_mod.show_timing = true;
    toolResultLine(&a, .{ .name = "bash", .text = "ok", .is_error = false, .ms = 42 });
    try std.testing.expectEqualStrings("  ✓ bash (42ms)  ok\n", aw.writer.buffered());

    // A #440 handle spill badges its size; the marker text stays off the line.
    aw.clearRetainingCapacity();
    main_mod.show_timing = false;
    toolResultLine(&a, .{ .name = "bash", .text = "[tool result handle: 44690 bytes, JSON object — the COMPLETE result is at /tmp/h-0.txt. Slice what you need out of that file (read_file with start_line/end_line, a grep-style bash command, codedb) instead of re-running the tool (#440).]", .is_error = false });
    try std.testing.expectEqualStrings("  ✓ bash ⇢ 43.6 KiB handle\n", aw.writer.buffered());

    // The no-handle truncation variant badges the loss instead.
    aw.clearRetainingCapacity();
    toolResultLine(&a, .{ .name = "bash", .text = "[tool result truncated to 16384 bytes: 90000 bytes total, JSON object. No handle could be written, so the rest is gone — narrow the command and run it again (#440).]", .is_error = false });
    try std.testing.expectEqualStrings("  ✓ bash ⇠ 87.9 KiB lost\n", aw.writer.buffered());
}

test "the effort-routing note draws in normal mode and stays quiet in debug mode" {
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
    try std.testing.expectEqualStrings("", aw.writer.buffered());
    label.resetPending();
    toolResultLine(&a, .{ .name = "read_file", .text = "a\nb\n", .is_error = false });
    try std.testing.expectEqualStrings("  ├─ ✓ read_file  2 lines\n", aw.writer.buffered());
    aw.clearRetainingCapacity();
    toolResultLine(&a, .{ .name = "read_file", .text = "a\nb\n", .is_error = false });
    try std.testing.expectEqualStrings("  ├─ ✓ read_file  2 lines\n", aw.writer.buffered());
    aw.clearRetainingCapacity();
    toolResultLine(&a, .{ .name = "read_file", .text = "a\nb\n", .is_error = false });
    try std.testing.expectEqualStrings("  └─ ✓ read_file  2 lines\n", aw.writer.buffered());

    aw.clearRetainingCapacity();
    parallelBatchFinished(&a, .{ .done = 2, .failed = 0, .cancelled = 0 });
    try std.testing.expectEqualStrings("", aw.writer.buffered());

    aw.clearRetainingCapacity();
    parallelBatchFinished(&a, .{ .done = 2, .failed = 1, .cancelled = 0 });
    try std.testing.expectEqualStrings("  ↯ 1 failed\n", aw.writer.buffered());

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

test "unknown tools pick a readable field instead of staying name-only" {
    const saved = ansi.style;
    ansi.style = .{};
    defer ansi.style = saved;
    const saved_json = main_mod.json_mode;
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);

    label.resetPending();
    const q = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), "{\"query\":\"standing line\"}", .{});
    toolUseLine(&a, .{ .name = "mcp_search", .input = q });
    toolResultLine(&a, .{ .name = "mcp_search", .text = "4 matches", .is_error = false });
    try std.testing.expectEqualStrings("  ✓ search  standing line  4 matches\n", aw.writer.buffered());
}

test "edit_file one-liner includes a +N/-N delta" {
    const saved = ansi.style;
    ansi.style = .{};
    defer ansi.style = saved;
    const saved_json = main_mod.json_mode;
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);

    const one = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(),
        \\{"path":"src/a.zig","old_string":"a\nb","new_string":"a\nb\nc"}
    , .{});
    label.resetPending();
    toolUseLine(&a, .{ .name = "edit_file", .input = one });
    toolResultLine(&a, .{ .name = "edit_file", .text = "applied 1 edit span(s) to src/a.zig (each verified)", .is_error = false });
    try std.testing.expectEqualStrings("  ✓ edit  src/a.zig · +3/-2\n", aw.writer.buffered());
}

test "bash result prefers the last line of a multi-line run" {
    const saved = ansi.style;
    ansi.style = .{};
    defer ansi.style = saved;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);

    toolResultLine(&a, .{
        .name = "bash",
        .text = "[1/3] a...\n[2/3] b...\nAll 1475 tests passed\n",
        .is_error = false,
    });
    try std.testing.expectEqualStrings("  ✓ bash  1475 passed\n", aw.writer.buffered());
}

test "bash git log is a count, never the command" {
    const saved = ansi.style;
    ansi.style = .{};
    defer ansi.style = saved;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);
    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), "{\"command\":\"git log --oneline v0.0.267..HEAD\"}", .{});
    toolUseLine(&a, .{ .name = "bash", .input = input });
    toolResultLine(&a, .{
        .name = "bash",
        .text = "d022479 feat(ui): cache\n8f75b5b fix(tui): chips\n4ba84b3 feat(models): seats\n",
        .is_error = false,
    });
    try std.testing.expectEqualStrings("  ✓ git  3 commits\n", aw.writer.buffered());
}

test "repeated McpClosed collapses to one notice and skips the batch tally" {
    const saved = ansi.style;
    ansi.style = .{};
    defer ansi.style = saved;
    const saved_json = main_mod.json_mode;
    main_mod.json_mode = false;
    defer main_mod.json_mode = saved_json;
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);

    parallelBatchStarted(&a, 3);
    toolResultLine(&a, .{ .name = "mcp__codedbpro__read", .text = "McpClosed", .is_error = true });
    toolResultLine(&a, .{ .name = "mcp__codedbpro__read", .text = "McpClosed", .is_error = true });
    toolResultLine(&a, .{ .name = "mcp__codedbpro__faster_search", .text = "McpClosed", .is_error = true });
    try std.testing.expectEqualStrings("  ! codedb unavailable\n", aw.writer.buffered());
    aw.clearRetainingCapacity();
    parallelBatchFinished(&a, .{ .done = 0, .failed = 3, .cancelled = 0 });
    try std.testing.expectEqualStrings("", aw.writer.buffered());
}

test "codedb JSON read is basename plus mode, not the envelope" {
    const saved = ansi.style;
    ansi.style = .{};
    defer ansi.style = saved;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var a = testAgent(&aw.writer);
    const input = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), "{\"file\":\"/Users/rachpradhan/codedb/docs/architecture.md\",\"mode\":\"section\"}", .{});
    toolUseLine(&a, .{ .name = "mcp__codedbpro__read", .input = input });
    toolResultLine(&a, .{
        .name = "mcp__codedbpro__read",
        .text = "{\"ok\":true,\"file\":\"/Users/rachpradhan/codedb/docs/architecture.md\",\"mode\":\"section\",\"content\":\"a\\nb\\nc\"}",
        .is_error = false,
    });
    try std.testing.expectEqualStrings("  ✓ read  architecture.md  section · 3 lines\n", aw.writer.buffered());
}
