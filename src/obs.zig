//! Content-free session observability, shaped after Grok Build's
//! `grok_code.*` metrics/events (user-guide 24-monitoring-usage).
//!
//! Always on in-process: `/debug` and `/usage` read this even when OTLP
//! export is off. Nothing here stores prompts, file paths, bash text, tool
//! arguments, or error bodies. MCP tools collapse to `mcp_tool`.
//!
//! Not a second collector: export stays `telemetry.zig` (opt-in OTLP/HTTP
//! JSON at session end). This module is the named vocabulary and the HUD.

const std = @import("std");
const Io = std.Io;

const engine_events = @import("engine_events.zig");
const pricing = @import("pricing.zig");
const util = @import("util.zig");

pub const schema_version = "v1";
pub const service_name = "graff";

pub const EventName = enum {
    session_start,
    session_end,
    user_prompt,
    turn_completed,
    api_request,
    api_error,
    tool_result,
    tool_decision,
    model_switched,
};

pub const Outcome = enum { none, completed, cancelled, failed, success };
pub const Decision = enum { none, allow, deny, cancelled };

pub const Record = struct {
    name: EventName = .session_start,
    t_ms: i64 = 0,
    model: [48]u8 = undefined,
    model_len: u8 = 0,
    tool: [32]u8 = undefined,
    tool_len: u8 = 0,
    outcome: Outcome = .none,
    decision: Decision = .none,
    duration_ms: i64 = 0,
    tokens_in: u64 = 0,
    tokens_cached: u64 = 0,
    prompt_len: u32 = 0,

    pub fn modelSlice(self: *const Record) []const u8 {
        return self.model[0..self.model_len];
    }
    pub fn toolSlice(self: *const Record) []const u8 {
        return self.tool[0..self.tool_len];
    }
};

pub const Snapshot = struct {
    sessions: u64 = 0,
    turns: u64 = 0,
    turns_completed: u64 = 0,
    turns_cancelled: u64 = 0,
    turns_failed: u64 = 0,
    api_calls: u64 = 0,
    api_errors: u64 = 0,
    tool_calls: u64 = 0,
    tool_errors: u64 = 0,
    decisions_allow: u64 = 0,
    decisions_deny: u64 = 0,
    decisions_cancelled: u64 = 0,
    tokens_in: u64 = 0,
    tokens_cached: u64 = 0,
    events: u64 = 0,
};

const ring_cap = 16;

// Spin-lock: this module has no Io handle (HUD + tracer hooks fire from
// threads that may not own one), and the critical section is a small copy.
var lock: std.atomic.Value(bool) = .init(false);
var snap: Snapshot = .{};
var ring: [ring_cap]Record = undefined;
var ring_head: usize = 0;
var ring_len: usize = 0;
var start_ms: i64 = 0;
var g_io: ?Io = null;
pub var export_endpoint: []const u8 = "";

fn acquire() void {
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}
fn release() void {
    lock.store(false, .release);
}

pub fn attach(io: Io) void {
    acquire();
    defer release();
    g_io = io;
}

pub fn reset() void {
    acquire();
    defer release();
    snap = .{};
    ring_head = 0;
    ring_len = 0;
    start_ms = 0;
    export_endpoint = "";
    g_io = null;
}

pub fn snapshot() Snapshot {
    acquire();
    defer release();
    return snap;
}

pub fn recent(out: []Record) usize {
    acquire();
    defer release();
    const n = @min(out.len, ring_len);
    if (n == 0) return 0;
    const start = (ring_head + ring_cap - ring_len) % ring_cap;
    var i: usize = 0;
    while (i < n) : (i += 1) out[i] = ring[(start + i) % ring_cap];
    return n;
}

/// Built-in names pass through; MCP (`mcp__server__tool`) collapses.
pub fn collapseTool(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "mcp__")) return "mcp_tool";
    return name;
}

pub fn note(ev: engine_events.EngineEvent) void {
    switch (ev) {
        .session_banner => record(.{ .name = .session_start }),
        .run_finished => record(.{ .name = .session_end }),
        .tool_call_started => |t| record(.{
            .name = .tool_decision,
            .tool = collapseTool(t.name),
            .decision = .allow,
        }),
        .tool_rejected => |t| record(.{
            .name = .tool_decision,
            .tool = collapseTool(t.name),
            .decision = .deny,
        }),
        .tool_call_finished => |t| record(.{
            .name = .tool_result,
            .tool = collapseTool(t.name),
            .outcome = if (t.cancelled) .cancelled else if (t.is_error) .failed else .success,
            .duration_ms = t.ms,
            .decision = if (t.cancelled) .cancelled else .none,
        }),
        .provider_fallback => |p| record(.{
            .name = .model_switched,
            .model = p.to_model,
        }),
        else => {},
    }
}

pub fn api(model: []const u8, ms: i64, tokens_in: u64, tokens_cached: u64, is_error: bool) void {
    record(.{
        .name = if (is_error) .api_error else .api_request,
        .model = model,
        .outcome = if (is_error) .failed else .success,
        .duration_ms = ms,
        .tokens_in = tokens_in,
        .tokens_cached = tokens_cached,
    });
}

pub fn tool(name: []const u8, ms: i64, is_error: bool) void {
    record(.{
        .name = .tool_result,
        .tool = collapseTool(name),
        .outcome = if (is_error) .failed else .success,
        .duration_ms = ms,
    });
}

pub fn turn(outcome: Outcome) void {
    record(.{ .name = .turn_completed, .outcome = outcome });
}

pub fn fail(kind: []const u8) void {
    record(.{
        .name = .api_error,
        .model = kind,
        .outcome = .failed,
        .skip_counts = true,
    });
}

/// Length only — never the prompt text.
pub fn prompt(len: u32, model: []const u8) void {
    record(.{ .name = .user_prompt, .model = model, .prompt_len = len });
}

pub fn modelSwitch(to: []const u8) void {
    record(.{ .name = .model_switched, .model = to });
}

pub fn ensureSession() void {
    if (snapshot().sessions == 0) record(.{ .name = .session_start });
}

pub fn eventName(n: EventName) []const u8 {
    return switch (n) {
        .session_start => "graff.session_start",
        .session_end => "graff.session_end",
        .user_prompt => "graff.user_prompt",
        .turn_completed => "graff.turn_completed",
        .api_request => "graff.api_request",
        .api_error => "graff.api_error",
        .tool_result => "graff.tool_result",
        .tool_decision => "graff.tool_decision",
        .model_switched => "graff.model_switched",
    };
}

const Draft = struct {
    name: EventName,
    model: []const u8 = "",
    tool: []const u8 = "",
    outcome: Outcome = .none,
    decision: Decision = .none,
    duration_ms: i64 = 0,
    tokens_in: u64 = 0,
    tokens_cached: u64 = 0,
    prompt_len: u32 = 0,
    skip_counts: bool = false,
};

fn elapsedMsLocked() i64 {
    if (g_io) |io| {
        const now = util.unixMs(io);
        if (start_ms == 0) start_ms = now;
        return now - start_ms;
    }
    return @intCast(snap.events);
}

fn record(d: Draft) void {
    acquire();
    defer release();
    var rec: Record = .{
        .name = d.name,
        .t_ms = elapsedMsLocked(),
        .outcome = d.outcome,
        .decision = d.decision,
        .duration_ms = d.duration_ms,
        .tokens_in = d.tokens_in,
        .tokens_cached = d.tokens_cached,
        .prompt_len = d.prompt_len,
    };
    rec.model_len = copyInto(&rec.model, d.model);
    rec.tool_len = copyInto(&rec.tool, d.tool);

    ring[ring_head] = rec;
    ring_head = (ring_head + 1) % ring_cap;
    if (ring_len < ring_cap) ring_len += 1;
    snap.events += 1;
    if (d.skip_counts) return;

    switch (d.name) {
        .session_start => snap.sessions += 1,
        .turn_completed => {
            snap.turns += 1;
            switch (d.outcome) {
                .cancelled => snap.turns_cancelled += 1,
                .failed => snap.turns_failed += 1,
                else => snap.turns_completed += 1,
            }
        },
        .api_request => {
            snap.api_calls += 1;
            snap.tokens_in += d.tokens_in;
            snap.tokens_cached += d.tokens_cached;
        },
        .api_error => {
            snap.api_calls += 1;
            snap.api_errors += 1;
        },
        .tool_result => {
            snap.tool_calls += 1;
            if (d.outcome == .failed) snap.tool_errors += 1;
            if (d.decision == .cancelled) snap.decisions_cancelled += 1;
        },
        .tool_decision => switch (d.decision) {
            .allow => snap.decisions_allow += 1,
            .deny => snap.decisions_deny += 1,
            .cancelled => snap.decisions_cancelled += 1,
            .none => {},
        },
        else => {},
    }
}

fn copyInto(dst: []u8, src: []const u8) u8 {
    const n = @min(dst.len, src.len);
    if (n > 0) @memcpy(dst[0..n], src[0..n]);
    return @intCast(n);
}

pub fn renderHud(w: *Io.Writer) !void {
    const s = snapshot();
    try w.print("observability  {s}.schema {s}  content-free\n", .{ service_name, schema_version });
    if (export_endpoint.len > 0) {
        try w.print("  export     otlp  {s}\n", .{export_endpoint});
    } else {
        try w.print("  export     off  (OTEL_EXPORTER_OTLP_ENDPOINT)\n", .{});
    }
    try w.print("  sessions   {d}\n", .{s.sessions});
    try w.print("  turns      {d}  ({d} completed · {d} cancelled · {d} failed)\n", .{
        s.turns, s.turns_completed, s.turns_cancelled, s.turns_failed,
    });
    try w.print("  api        {d} calls · {d} errors\n", .{ s.api_calls, s.api_errors });
    try w.print("  tools      {d} calls · {d} errors\n", .{ s.tool_calls, s.tool_errors });
    try w.print("  decisions  allow {d} · deny {d} · cancelled {d}\n", .{
        s.decisions_allow, s.decisions_deny, s.decisions_cancelled,
    });
    // Money/tokens come from the session cost tally — the same renderer /cost
    // uses — never from the event ring (which has no output tokens or USD).
    if (g_io) |io| {
        const c = pricing.g_cost.snap(io);
        if (c.api_calls > 0) {
            try w.writeAll("  usage      ");
            try pricing.CostTally.render(c, w);
            try w.writeByte('\n');
        }
    }
    try w.writeAll("  last events\n");
    var recs: [ring_cap]Record = undefined;
    const n = recent(&recs);
    if (n == 0) {
        try w.writeAll("    (none yet)\n");
        return;
    }
    for (recs[0..n]) |r| try writeRecord(w, r);
}

pub fn renderUsage(w: *Io.Writer) !void {
    if (g_io) |io| {
        const c = pricing.g_cost.snap(io);
        if (c.api_calls == 0) {
            try w.writeAll("no API calls yet this session\n");
            return;
        }
        try pricing.CostTally.render(c, w);
        try w.writeByte('\n');
        return;
    }
    try w.writeAll("no API calls yet this session\n");
}

fn writeRecord(w: *Io.Writer, r: Record) !void {
    try w.print("    {s}", .{@tagName(r.name)});
    if (r.model_len > 0) try w.print("  {s}", .{r.modelSlice()});
    if (r.tool_len > 0) try w.print("  {s}", .{r.toolSlice()});
    if (r.decision != .none) try w.print("  {s}", .{@tagName(r.decision)});
    if (r.outcome != .none) try w.print("  {s}", .{@tagName(r.outcome)});
    if (r.duration_ms > 0) try w.print("  {d}ms", .{r.duration_ms});
    if (r.prompt_len > 0) try w.print("  {d}ch", .{r.prompt_len});
    try w.writeByte('\n');
}

const AttrVal = union(enum) { str: []const u8, int: i64 };

fn otlpAttr(s: *std.json.Stringify, key: []const u8, v: AttrVal) !void {
    try s.beginObject();
    try s.objectField("key");
    try s.write(key);
    try s.objectField("value");
    try s.beginObject();
    switch (v) {
        .str => |x| {
            try s.objectField("stringValue");
            try s.write(x);
        },
        .int => |x| {
            var b: [24]u8 = undefined;
            try s.objectField("intValue");
            try s.write(std.fmt.bufPrint(&b, "{d}", .{x}) catch unreachable);
        },
    }
    try s.endObject();
    try s.endObject();
}

/// Extra OTLP log records for the existing session-end JSON export.
/// Content-free; same attribute vocabulary as Grok's `grok_code.*` events.
pub fn writeOtlp(s: *std.json.Stringify, start_unix_ms: i64) !void {
    var recs: [ring_cap]Record = undefined;
    const n = recent(&recs);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r = recs[i];
        try s.beginObject();
        var tb: [32]u8 = undefined;
        try s.objectField("timeUnixNano");
        try s.write(std.fmt.bufPrint(&tb, "{d}", .{(start_unix_ms + r.t_ms) * 1_000_000}) catch unreachable);
        try s.objectField("severityText");
        try s.write(if (r.name == .api_error or r.outcome == .failed) "ERROR" else "INFO");
        try s.objectField("body");
        try s.beginObject();
        try s.objectField("stringValue");
        try s.write(eventName(r.name));
        try s.endObject();
        try s.objectField("attributes");
        try s.beginArray();
        try otlpAttr(s, "event.name", .{ .str = eventName(r.name) });
        try otlpAttr(s, "graff.schema.version", .{ .str = schema_version });
        if (r.model_len > 0) try otlpAttr(s, "model", .{ .str = r.modelSlice() });
        if (r.tool_len > 0) try otlpAttr(s, "tool_name", .{ .str = r.toolSlice() });
        if (r.decision != .none) try otlpAttr(s, "decision", .{ .str = @tagName(r.decision) });
        if (r.outcome != .none) try otlpAttr(s, "outcome", .{ .str = @tagName(r.outcome) });
        if (r.duration_ms > 0) try otlpAttr(s, "duration_ms", .{ .int = r.duration_ms });
        if (r.prompt_len > 0) try otlpAttr(s, "prompt_length", .{ .int = r.prompt_len });
        if (r.tokens_in > 0) try otlpAttr(s, "input_tokens", .{ .int = @intCast(r.tokens_in) });
        if (r.tokens_cached > 0) try otlpAttr(s, "cache_read_tokens", .{ .int = @intCast(r.tokens_cached) });
        try s.endArray();
        try s.endObject();
    }
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "collapseTool: mcp prefix only" {
    try std.testing.expectEqualStrings("bash", collapseTool("bash"));
    try std.testing.expectEqualStrings("mcp_tool", collapseTool("mcp__codedb__search"));
    try std.testing.expectEqualStrings("read_file", collapseTool("read_file"));
}

test "note: session and prompt never store paths or prompt text" {
    reset();
    note(.{ .session_banner = .{ .cwd = "/Users/secret/repo", .trace_path = "/Users/secret/.graff/traces/x.jsonl" } });
    // Status-line prompt_ready is not a user submission.
    note(.{ .prompt_ready = .{
        .model = "grok-4",
        .provider_id = "xai",
        .cwd = "/Users/secret/repo",
        .privacy_label = "local",
        .privacy = .local,
    } });
    prompt(7, "grok-4");
    var recs: [ring_cap]Record = undefined;
    const n = recent(&recs);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(EventName.session_start, recs[0].name);
    try std.testing.expectEqual(EventName.user_prompt, recs[1].name);
    try std.testing.expectEqualStrings("grok-4", recs[1].modelSlice());
    try std.testing.expectEqual(@as(u32, 7), recs[1].prompt_len);
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try renderHud(&w);
    const text = w.buffered();
    try std.testing.expect(!contains(text, "/Users/secret"));
    try std.testing.expect(!contains(text, "traces/x"));
    try std.testing.expect(contains(text, "session_start"));
}

test "note: tool decision and result stay content-free" {
    reset();
    note(.{ .tool_call_started = .{ .name = "bash", .input = .null } });
    note(.{ .tool_rejected = .{
        .name = "mcp__github__create_issue",
        .input = .null,
        .reason = "denied",
        .message = "sk-live-secret /Users/me/key",
    } });
    note(.{ .tool_call_finished = .{
        .name = "bash",
        .text = "cat /etc/passwd && echo secret",
        .is_error = false,
        .ms = 12,
    } });
    var recs: [8]Record = undefined;
    const n = recent(&recs);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(Decision.allow, recs[0].decision);
    try std.testing.expectEqualStrings("mcp_tool", recs[1].toolSlice());
    try std.testing.expectEqual(Decision.deny, recs[1].decision);
    try std.testing.expectEqualStrings("bash", recs[2].toolSlice());
    try std.testing.expectEqual(Outcome.success, recs[2].outcome);
    const s = snapshot();
    try std.testing.expectEqual(@as(u64, 1), s.decisions_allow);
    try std.testing.expectEqual(@as(u64, 1), s.decisions_deny);
    try std.testing.expectEqual(@as(u64, 1), s.tool_calls);
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try renderHud(&w);
    const text = w.buffered();
    try std.testing.expect(!contains(text, "sk-live"));
    try std.testing.expect(!contains(text, "/etc/passwd"));
    try std.testing.expect(!contains(text, "create_issue"));
}

test "api/turn counters work with no OTEL sink" {
    reset();
    api("grok-4", 40, 100, 20, false);
    api("grok-4", 8, 0, 0, true);
    turn(.completed);
    turn(.cancelled);
    const s = snapshot();
    try std.testing.expectEqual(@as(u64, 2), s.api_calls);
    try std.testing.expectEqual(@as(u64, 1), s.api_errors);
    try std.testing.expectEqual(@as(u64, 100), s.tokens_in);
    try std.testing.expectEqual(@as(u64, 20), s.tokens_cached);
    try std.testing.expectEqual(@as(u64, 2), s.turns);
    try std.testing.expectEqual(@as(u64, 1), s.turns_completed);
    try std.testing.expectEqual(@as(u64, 1), s.turns_cancelled);
}

test "ring keeps the last 16 events" {
    reset();
    var i: usize = 0;
    while (i < 20) : (i += 1) turn(.completed);
    var recs: [ring_cap]Record = undefined;
    try std.testing.expectEqual(@as(usize, ring_cap), recent(&recs));
    try std.testing.expectEqual(@as(u64, 20), snapshot().turns);
}

test "renderUsage: empty session" {
    reset();
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try renderUsage(&w);
    try std.testing.expect(contains(w.buffered(), "no API calls"));
}

test {
    _ = @import("obs_cost_test.zig");
}

test "prompt stores length only; writeOtlp stays content-free" {
    reset();
    prompt(42, "grok-4");
    ensureSession();
    turn(.completed);
    var recs: [ring_cap]Record = undefined;
    const n = recent(&recs);
    try std.testing.expect(n >= 2);
    try std.testing.expectEqual(@as(u32, 42), recs[0].prompt_len);
    try std.testing.expectEqual(EventName.user_prompt, recs[0].name);
    try std.testing.expectEqual(@as(u64, 1), snapshot().sessions);
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    var s: std.json.Stringify = .{ .writer = &w };
    try s.beginArray();
    try writeOtlp(&s, 0);
    try s.endArray();
    const text = w.buffered();
    try std.testing.expect(contains(text, "graff.user_prompt"));
    try std.testing.expect(contains(text, "graff.turn_completed"));
    try std.testing.expect(contains(text, "prompt_length"));
    try std.testing.expect(!contains(text, "secret prompt text"));
}
