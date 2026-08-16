//! The readouts backed by the ENGINE's meters (#551): /context and
//! /session-info.
//!
//! Both used to be answered from `chars_in`/`chars_out`, two counters the TUI
//! incremented with the length of the text it had drawn. That is not a context
//! window and never was: it missed the system prompt, the tool catalog and
//! every tool result, it counted characters where the provider counts tokens,
//! and it only grew — a compaction that halved the real context left the
//! "context" line climbing. The engine already computes ContextMeter and
//! CostMeter for its own status line; those now arrive as a typed event and
//! this file renders them.
//!
//! Split out of dispatch.zig for the 600-line cap.

const std = @import("std");

const app = @import("app.zig");
const engine = @import("engine.zig");
const Model = app.Model;

/// `/context`.
pub fn contextInfo(self: *Model) void {
    const st = self.status orelse {
        self.push(.system, "context: not measured yet — the meter fills in once a turn reports usage") catch {};
        return;
    };
    if (!st.has_context) {
        self.pushFmt(.system, "context: {s} has not reported usage yet", .{st.model}) catch {};
        return;
    }
    self.pushFmt(.system, "context: {d} / {d} tokens ({d}%) · compacts at {d} · {d} cached", .{
        st.tokens,
        st.window,
        st.percent(),
        st.compact_at,
        st.cache_read,
    }) catch {};
}

/// `/session-info` — mode, model and turn count from the Model; context and
/// spend from the engine.
pub fn sessionInfo(self: *Model) void {
    var buf: [64]u8 = undefined;
    const ctx: []const u8 = if (self.contextPercent()) |p|
        (std.fmt.bufPrint(&buf, "{d}% context", .{p}) catch "context ?")
    else
        "context not measured";
    const spend: []const u8 = if (self.status) |st| switch (st.cost) {
        .hidden => "",
        .subscription => " · subscription",
        .unpriced => " · unpriced",
        .usd => " · see /cost",
    } else "";
    self.pushFmt(.system, "{s} · {s} · {d} turn(s) · {s}{s} · {s}", .{
        self.modeLabel(),
        engine.g_model_name,
        self.turns,
        ctx,
        spend,
        engine.g_cwd,
    }) catch {};
}

const testing = std.testing;

test "/context reports the engine's tokens, never a character count (#551)" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();

    // Before any turn there is nothing measured, and the line says so rather
    // than printing a 0 that reads like an empty context.
    contextInfo(&m);
    try testing.expect(std.mem.indexOf(u8, m.history.items[0].text, "not measured") != null);

    m.setStatus(.{
        .model = "sonnet",
        .provider_id = "anthropic",
        .has_context = true,
        .tokens = 12_345,
        .window = 200_000,
        .compact_at = 160_000,
        .cache_read = 2048,
        .cost = .{ .usd = 0.42 },
    });
    contextInfo(&m);
    const line = m.history.items[m.history.items.len - 1].text;
    try testing.expect(std.mem.indexOf(u8, line, "12345") != null);
    try testing.expect(std.mem.indexOf(u8, line, "200000") != null);
    try testing.expect(std.mem.indexOf(u8, line, "6%") != null);
    try testing.expect(std.mem.indexOf(u8, line, "160000") != null);
    try testing.expect(std.mem.indexOf(u8, line, "2048") != null);
    try testing.expect(std.mem.indexOf(u8, line, "chars") == null);
}

test "/session-info shows context share, not characters" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    m.turns = 3;

    sessionInfo(&m);
    try testing.expect(std.mem.indexOf(u8, m.history.items[0].text, "context not measured") != null);

    m.setStatus(.{
        .model = "gpt-5.6",
        .provider_id = "codex",
        .has_context = true,
        .tokens = 100_000,
        .window = 200_000,
        .cost = .subscription,
    });
    sessionInfo(&m);
    const line = m.history.items[m.history.items.len - 1].text;
    try testing.expect(std.mem.indexOf(u8, line, "3 turn(s)") != null);
    try testing.expect(std.mem.indexOf(u8, line, "50% context") != null);
    try testing.expect(std.mem.indexOf(u8, line, "subscription") != null);
    try testing.expect(std.mem.indexOf(u8, line, " in / ") == null);
}

test "a status the engine has not measured yields no percent anywhere" {
    var m: Model = undefined;
    m.setup(testing.allocator);
    defer m.deinit();
    try testing.expect(m.contextPercent() == null);
    // A turn ran but the provider reported no usage: still nothing to show.
    m.setStatus(.{ .model = "local", .provider_id = "lmstudio" });
    try testing.expect(m.contextPercent() == null);
    // Measured: the share is the engine's, capped at 100.
    m.setStatus(.{ .model = "local", .provider_id = "lmstudio", .has_context = true, .tokens = 500, .window = 400 });
    try testing.expectEqual(@as(u64, 100), m.contextPercent().?);
    // Replacing the status frees the old strings — the leak checker owns this
    // assertion, but the identity is worth stating.
    try testing.expectEqualStrings("local", m.status.?.model);
}
