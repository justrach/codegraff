//! Content-free prompt-cache posture: `/cache` and a one-line `/debug` row.
//!
//! Stores lengths, a prefix hash, and named bust reasons — never prompt text,
//! paths, or tool bodies. Codex's rule is still the product rule: the old
//! prompt must be an exact prefix of the new one. This module is how you see
//! whether this session is still earning that.

const std = @import("std");
const Io = std.Io;

const pricing = @import("pricing.zig");
const mcp_schema_gate = @import("mcp_schema_gate.zig");

pub const Bust = enum {
    none,
    start,
    goal,
    playbook,
    compact,
    transcript,
    persona,
    tools,
    mcp,
    mode,
    other,
};

pub const Snap = struct {
    prefix: u32 = 0,
    prev: u32 = 0,
    sys_bytes: u32 = 0,
    tools_bytes: u32 = 0,
    same: bool = true,
    requests: u32 = 0,
    busts: u32 = 0,
    last_bust: Bust = .none,
    last_read: u64 = 0,
    last_write: u64 = 0,
};

var lock: std.atomic.Value(bool) = .init(false);
var snap: Snap = .{};
var pending: Bust = .none;
var g_io: ?Io = null;
var g_aff: [64]u8 = undefined;
var g_aff_len: usize = 0;
var g_xai: bool = false;
var g_responses: bool = false;

fn acquire() void {
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}
fn release() void {
    lock.store(false, .release);
}

pub fn reset() void {
    acquire();
    defer release();
    snap = .{};
    pending = .none;
    g_io = null;
    g_aff_len = 0;
    g_xai = false;
    g_responses = false;
}

pub fn snapshot() Snap {
    acquire();
    defer release();
    return snap;
}

/// Hash of the bytes the provider prefixes. First 32 bits of SHA-256 — enough
/// to see a change, not enough to recover the prompt.
pub fn prefixHash(system: []const u8, tools: []const u8) u32 {
    var digest: [32]u8 = undefined;
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(system);
    h.update("\x1e");
    h.update(tools);
    h.final(&digest);
    return std.mem.readInt(u32, digest[0..4], .big);
}

/// Startup compose is not a bust. After the first request, a named reason
/// waits for the next `noteRequest` and only counts if the hash actually moved.
pub fn noteBust(reason: Bust) void {
    acquire();
    defer release();
    if (snap.requests == 0) return;
    pending = reason;
}

pub fn noteUsage(read: u64, write: u64) void {
    acquire();
    defer release();
    snap.last_read = read;
    snap.last_write = write;
}

pub fn noteRequest(io: Io, system: []const u8, tools: []const u8) void {
    const hash = prefixHash(system, tools);
    acquire();
    defer release();
    g_io = io;
    const prev = snap.prefix;
    const had = snap.requests > 0;
    const changed = had and hash != prev;
    if (changed) {
        snap.busts += 1;
        snap.last_bust = if (pending != .none) pending else .other;
    } else if (!had) {
        snap.last_bust = .start;
    }
    pending = .none;
    snap.prev = prev;
    snap.prefix = hash;
    snap.sys_bytes = std.math.cast(u32, system.len) orelse std.math.maxInt(u32);
    snap.tools_bytes = std.math.cast(u32, tools.len) orelse std.math.maxInt(u32);
    snap.same = !changed;
    snap.requests += 1;
}

/// Content-free xAI routing id (`x-grok-conv-id` / `prompt_cache_key`).
/// Official docs: same value on Chat header and Responses body.
pub fn noteAffinity(key: []const u8, xai: bool, responses: bool) void {
    acquire();
    defer release();
    g_xai = xai;
    g_responses = responses;
    const n = @min(key.len, g_aff.len);
    @memcpy(g_aff[0..n], key[0..n]);
    g_aff_len = n;
}

pub fn bustLabel(b: Bust) []const u8 {
    return switch (b) {
        .none => "none",
        .start => "start",
        .goal => "goal",
        .playbook => "playbook",
        .compact => "compact",
        .transcript => "transcript",
        .persona => "persona",
        .tools => "tools",
        .mcp => "mcp",
        .mode => "mode",
        .other => "other",
    };
}

fn kib(n: u32) u32 {
    return n / 1024;
}

fn hitPct(cached: u64, billed_in: u64) u64 {
    const den = billed_in +| cached;
    if (den == 0) return 0;
    return @min((cached *| 100) / den, 100);
}

/// One row for `/debug`. Content-free.
pub fn renderLine(w: *Io.Writer) !void {
    const s = snapshot();
    if (s.requests == 0) {
        try w.writeAll("  cache      (no API call yet — /cache shows the remaining max levers)\n");
        return;
    }
    try w.print("  cache      {d}% hit · prefix {s} · {d} bust{s}", .{
        sessionHitPct(),
        if (s.same) "same" else "changed",
        s.busts,
        if (s.busts == 1) "" else "s",
    });
    if (s.busts > 0) try w.print(" ({s})", .{bustLabel(s.last_bust)});
    try w.writeByte('\n');
}

/// The `/cache` HUD: current posture plus the remaining product levers.
pub fn render(w: *Io.Writer) !void {
    const s = snapshot();
    try w.writeAll("prompt cache\n");
    if (s.requests == 0) {
        try w.writeAll("  prefix     (no request yet)\n");
    } else {
        try w.print("  prefix     {x:0>8}  (sys {d}kB · tools {d}kB)  {s}\n", .{
            s.prefix,
            kib(s.sys_bytes),
            kib(s.tools_bytes),
            if (s.same) "same" else "changed",
        });
        try w.print("  last       {d} read · {d} write\n", .{ s.last_read, s.last_write });
        try w.print("  session    {d}% hit", .{sessionHitPct()});
        if (g_io) |io| {
            const c = pricing.g_cost.snap(io);
            try w.print("  ({d} cached / {d} in) · {d} writes", .{
                c.cache_tokens, c.in_tokens +| c.cache_tokens, c.cache_write_tokens,
            });
        }
        try w.writeByte('\n');
        try w.print("  busts      {d}  last: {s}\n", .{ s.busts, bustLabel(s.last_bust) });
    }
    try w.print("  catalog    {s}\n", .{if (mcp_schema_gate.g_stable_catalog) "stable (loads append tail only)" else "mutating (a load rewrites tools JSON)"});
    if (g_xai and g_aff_len > 0) {
        try w.print("  xAI        {s}  (automatic prefix cache)\n", .{if (g_responses) "responses" else "chat"});
        try w.print("  affinity   {s}\n", .{g_aff[0..g_aff_len]});
        try w.writeAll("             x-grok-conv-id + x-grok-session-id + prompt_cache_key\n");
    } else {
        try w.writeAll("  xAI        x-grok-conv-id + x-grok-session-id + prompt_cache_key\n");
    }
    try w.writeAll(
        \\  remaining max
        \\    GRAFF_STABLE_CATALOG=1  opt-in: keep tools JSON byte-identical after load
        \\    /goal /never /strict    each prefix rewrite is one miss; compaction already pays one
        \\    leave skill bodies      and file: paths out of the prefix (already the default)
        \\    append-only messages    official xAI prefix; edit/remove/reorder is a miss
        \\    replay reasoning        Chat reasoning_content · Responses encrypted_content
        \\    Z.AI                    implicit prefix (cached_tokens); thinking.clear_thinking=false
        \\    /btw                    parent tools + system + cache key; note is the user message
        \\
    );
}

fn sessionHitPct() u64 {
    const io = g_io orelse return 0;
    const c = pricing.g_cost.snap(io);
    return hitPct(c.cache_tokens, c.in_tokens);
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "first prefix is start, not a bust" {
    reset();
    defer reset();
    noteRequest(std.testing.io, "system", "[]");
    const s = snapshot();
    try std.testing.expectEqual(@as(u32, 1), s.requests);
    try std.testing.expectEqual(@as(u32, 0), s.busts);
    try std.testing.expectEqual(Bust.start, s.last_bust);
    try std.testing.expect(s.same);
}

test "identical prefix stays same" {
    reset();
    defer reset();
    noteRequest(std.testing.io, "system", "[]");
    const first = snapshot().prefix;
    noteRequest(std.testing.io, "system", "[]");
    const s = snapshot();
    try std.testing.expectEqual(first, s.prefix);
    try std.testing.expectEqual(@as(u32, 0), s.busts);
    try std.testing.expect(s.same);
}

test "changed prefix without a named reason is other" {
    reset();
    defer reset();
    noteRequest(std.testing.io, "system", "[]");
    noteRequest(std.testing.io, "system-b", "[]");
    const s = snapshot();
    try std.testing.expectEqual(@as(u32, 1), s.busts);
    try std.testing.expectEqual(Bust.other, s.last_bust);
    try std.testing.expect(!s.same);
}

test "named bust waits for a real hash change" {
    reset();
    defer reset();
    noteRequest(std.testing.io, "system", "[]");
    noteBust(.goal);
    noteRequest(std.testing.io, "system", "[]");
    try std.testing.expectEqual(@as(u32, 0), snapshot().busts);
    noteBust(.playbook);
    noteRequest(std.testing.io, "system-2", "[]");
    const s = snapshot();
    try std.testing.expectEqual(@as(u32, 1), s.busts);
    try std.testing.expectEqual(Bust.playbook, s.last_bust);
}

test "startup noteBust is ignored" {
    reset();
    defer reset();
    noteBust(.persona);
    noteRequest(std.testing.io, "system", "[]");
    try std.testing.expectEqual(@as(u32, 0), snapshot().busts);
    try std.testing.expectEqual(Bust.start, snapshot().last_bust);
}

test "render stays content-free and names remaining levers" {
    reset();
    defer reset();
    noteRequest(std.testing.io, "SECRET-PROMPT /Users/me/repo", "[{\"name\":\"bash\"}]");
    noteUsage(6002, 0);
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try render(&w);
    const text = w.buffered();
    try std.testing.expect(contains(text, "prompt cache"));
    try std.testing.expect(contains(text, "prefix"));
    try std.testing.expect(contains(text, "GRAFF_STABLE_CATALOG"));
    try std.testing.expect(contains(text, "clear_thinking"));
    try std.testing.expect(contains(text, "/goal"));
    try std.testing.expect(contains(text, "x-grok-conv-id"));
    try std.testing.expect(contains(text, "append-only"));
    try std.testing.expect(!contains(text, "SECRET-PROMPT"));
    try std.testing.expect(!contains(text, "/Users/me"));
    try std.testing.expect(!contains(text, "bash"));
}

test "render shows xAI affinity without prompt text" {
    reset();
    defer reset();
    noteRequest(std.testing.io, "SECRET-PROMPT", "[]");
    noteAffinity("b79ad29b-b3f9-463c-bca6-041d5058d366", true, true);
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try render(&w);
    const text = w.buffered();
    try std.testing.expect(contains(text, "responses"));
    try std.testing.expect(contains(text, "b79ad29b-b3f9-463c-bca6-041d5058d366"));
    try std.testing.expect(contains(text, "prompt_cache_key"));
    try std.testing.expect(!contains(text, "SECRET-PROMPT"));
}

test "renderLine is one content-free row" {
    reset();
    defer reset();
    var empty_buf: [256]u8 = undefined;
    var empty_w: Io.Writer = .fixed(&empty_buf);
    try renderLine(&empty_w);
    try std.testing.expect(contains(empty_w.buffered(), "no API call"));

    noteRequest(std.testing.io, "system", "[]");
    noteRequest(std.testing.io, "system-2", "[]");
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try renderLine(&w);
    const text = w.buffered();
    try std.testing.expect(contains(text, "cache"));
    try std.testing.expect(contains(text, "changed"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "\n"));
}

test "hitPct saturates and handles zero" {
    try std.testing.expectEqual(@as(u64, 0), hitPct(0, 0));
    try std.testing.expectEqual(@as(u64, 50), hitPct(50, 50));
    try std.testing.expectEqual(@as(u64, 100), hitPct(200, 0));
}

test "bustLabel covers every tag" {
    try std.testing.expectEqualStrings("goal", bustLabel(.goal));
    try std.testing.expectEqualStrings("tools", bustLabel(.tools));
    try std.testing.expectEqualStrings("start", bustLabel(.start));
}
