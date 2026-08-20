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

fn firstLine(s: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, s, '\n') orelse s.len;
    return std.mem.trim(u8, s[0..end], " \t\r");
}

fn newlineCount(s: []const u8) usize {
    if (s.len == 0) return 0;
    var n: usize = 1;
    for (s) |c| {
        if (c == '\n') n += 1;
    }
    if (s[s.len - 1] == '\n') n -= 1;
    return n;
}

/// MCP and unknown tools still get a one-liner when a common field is present.
const fallback_fields = [_][]const u8{ "command", "path", "query", "url", "pattern", "file", "prompt", "uri", "text" };

fn namedDetailField(name: []const u8, input: std.json.Value) ?[]const u8 {
    if (std.mem.eql(u8, name, "bash") or std.mem.eql(u8, name, "codedb")) return "command";
    if (std.mem.eql(u8, name, "read_file") or
        std.mem.eql(u8, name, "write_file") or
        std.mem.eql(u8, name, "edit_file")) return "path";
    if (std.mem.eql(u8, name, "webfetch")) return "url";
    if (std.mem.eql(u8, name, "subagent")) return "description";
    if (std.mem.eql(u8, name, "imagegen")) return "prompt";
    if (std.mem.eql(u8, name, "peer_message")) {
        if (stringField(input, "action")) |act| {
            if (act.len > 0 and !std.mem.eql(u8, act, "send")) return "action";
        }
        return "text";
    }
    if (std.mem.eql(u8, name, "workspace")) {
        if (stringField(input, "path")) |p| if (p.len > 0) return "path";
        return "action";
    }
    return null;
}

fn fallbackDetail(input: std.json.Value) []const u8 {
    for (fallback_fields) |field| {
        const raw = stringField(input, field) orelse continue;
        const shown = firstLine(raw);
        if (shown.len > 0) return shown;
    }
    return "";
}

fn addSpanDelta(old: []const u8, new: []const u8, plus: *usize, minus: *usize, spans: *usize) void {
    plus.* += newlineCount(new);
    minus.* += newlineCount(old);
    spans.* += 1;
}

fn editDelta(input: std.json.Value, path: []const u8, buf: []u8) []const u8 {
    var plus: usize = 0;
    var minus: usize = 0;
    var spans: usize = 0;
    if (stringField(input, "old_string")) |old| {
        if (stringField(input, "new_string")) |new| addSpanDelta(old, new, &plus, &minus, &spans);
    }
    if (input == .object) if (input.object.get("edits")) |v| if (v == .array) {
        for (v.array.items) |item| {
            const old = stringField(item, "old_string") orelse continue;
            const new = stringField(item, "new_string") orelse continue;
            addSpanDelta(old, new, &plus, &minus, &spans);
        }
    };
    if (spans == 0) return path;
    if (spans == 1)
        return std.fmt.bufPrint(buf, "{s} · +{d}/-{d}", .{ path, plus, minus }) catch path;
    return std.fmt.bufPrint(buf, "{s} · {d} spans · +{d}/-{d}", .{ path, spans, plus, minus }) catch path;
}

/// One human-readable field (or an edit +N/-N). Never the raw argument object.
fn toolDetail(t: ToolInvocation, buf: []u8) []const u8 {
    if (std.mem.eql(u8, t.name, "edit_file")) {
        const path = stringField(t.input, "path") orelse return "";
        return editDelta(t.input, firstLine(path), buf);
    }
    if (namedDetailField(t.name, t.input)) |field| {
        const raw = stringField(t.input, field) orelse return "";
        return firstLine(raw);
    }
    return fallbackDetail(t.input);
}

/// A terse activity line: always show ordinary tool calls, but never their raw
/// argument object. Suppress only user-facing prose that already streamed live.
pub fn toolUseLine(a: *Agent, t: ToolInvocation) void {
    if (t.arg_streamed) return;
    var dbuf: [128]u8 = undefined;
    const detail = toolDetail(t, &dbuf);
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

fn lastNonEmptyLine(text: []const u8) []const u8 {
    const rest = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.lastIndexOfScalar(u8, rest, '\n')) |nl|
        return std.mem.trim(u8, rest[nl + 1 ..], " \t\r");
    return rest;
}

const Preview = struct { text: []const u8, clipped: bool };

/// First useful line — or a short summary. Handle markers stay off the line;
/// the badge already said the result spilled.
fn resultPreview(name: []const u8, all: []const u8, buf: []u8) Preview {
    if (handleBadge(all) != null) return .{ .text = "", .clipped = false };
    if (std.mem.startsWith(u8, all, handle_marker) or std.mem.startsWith(u8, all, truncated_marker))
        return .{ .text = "", .clipped = false };
    const lines = newlineCount(all);
    if (std.mem.eql(u8, name, "read_file") and lines > 1) {
        const text = std.fmt.bufPrint(buf, "{d} lines", .{lines}) catch all;
        return .{ .text = text, .clipped = false };
    }
    const raw = if (std.mem.eql(u8, name, "bash") and lines > 1) lastNonEmptyLine(all) else firstLine(all);
    if (raw.len > result_preview_bytes) return .{ .text = raw[0..result_preview_bytes], .clipped = true };
    return .{ .text = raw, .clipped = false };
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
    var pbuf: [32]u8 = undefined;
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
    const line = std.fmt.bufPrint(&buf, "  {s}↯ {d} in parallel{s}\n", .{ style.dim, count, style.reset }) catch return;
    sayText(a, line);
}

pub fn parallelBatchFinished(a: *Agent, o: BatchOutcome) void {
    var buf: [notice_buf_bytes]u8 = undefined;
    const total = o.done + o.failed + o.cancelled;
    const line = if (o.failed == 0 and o.cancelled == 0)
        std.fmt.bufPrint(&buf, "  {s}↯ {d}/{d} done{s}\n", .{ style.dim, o.done, total, style.reset })
    else if (o.cancelled == 0)
        std.fmt.bufPrint(&buf, "  {s}↯ {d} done · {d} failed{s}\n", .{ style.dim, o.done, o.failed, style.reset })
    else if (o.failed == 0)
        std.fmt.bufPrint(&buf, "  {s}↯ {d} done · {d} cancelled{s}\n", .{ style.dim, o.done, o.cancelled, style.reset })
    else
        std.fmt.bufPrint(&buf, "  {s}↯ {d} done · {d} failed · {d} cancelled{s}\n", .{ style.dim, o.done, o.failed, o.cancelled, style.reset });
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

    // Unknown tools stay visible; a common field becomes the one-liner, never JSON.
    aw.clearRetainingCapacity();
    toolUseLine(&a, .{ .name = "todo_write", .input = input });
    try std.testing.expectEqualStrings("⚙ todo_write · fixture.txt\n", aw.writer.buffered());

    aw.clearRetainingCapacity();
    const opaque_input = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), "{\"foo\":1}", .{});
    toolUseLine(&a, .{ .name = "mystery_tool", .input = opaque_input });
    try std.testing.expectEqualStrings("⚙ mystery_tool\n", aw.writer.buffered());

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
    try std.testing.expectEqualStrings("  ✓ read_file · 2 lines\n", aw.writer.buffered());

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
    try std.testing.expectEqualStrings("  ↯ 3 in parallel\n", aw.writer.buffered());

    aw.clearRetainingCapacity();
    parallelBatchFinished(&a, .{ .done = 2, .failed = 0, .cancelled = 0 });
    try std.testing.expectEqualStrings("  ↯ 2/2 done\n", aw.writer.buffered());

    aw.clearRetainingCapacity();
    parallelBatchFinished(&a, .{ .done = 2, .failed = 1, .cancelled = 0 });
    try std.testing.expectEqualStrings("  ↯ 2 done · 1 failed\n", aw.writer.buffered());

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

    const q = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), "{\"query\":\"standing line\"}", .{});
    toolUseLine(&a, .{ .name = "mcp_search", .input = q });
    try std.testing.expectEqualStrings("⚙ mcp_search · standing line\n", aw.writer.buffered());
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
    toolUseLine(&a, .{ .name = "edit_file", .input = one });
    try std.testing.expectEqualStrings("⚙ edit_file · src/a.zig · +3/-2\n", aw.writer.buffered());

    aw.clearRetainingCapacity();
    const batch = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(),
        \\{"path":"src/a.zig","edits":[{"old_string":"x","new_string":"x\ny"},{"old_string":"z\nz","new_string":"z"}]}
    , .{});
    toolUseLine(&a, .{ .name = "edit_file", .input = batch });
    try std.testing.expectEqualStrings("⚙ edit_file · src/a.zig · 2 spans · +3/-3\n", aw.writer.buffered());
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
    try std.testing.expectEqualStrings("  ✓ bash · All 1475 tests passed\n", aw.writer.buffered());
}
