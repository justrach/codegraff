//! OpenAI Platform prompt-cache TTL for GPT-5.6+ Responses.
//!
//! ADR 0009 already marks the stable prefix. This module adds the Oct 2026
//! 12-hour lifetime on that breakpoint and keeps the request default at 30
//! minutes for session context. Chat Completions and older models must not
//! receive these fields: 12h is a 400 there.

const std = @import("std");
const Io = std.Io;
const Agent = @import("agent.zig").Agent;
const Provider = @import("provider.zig").Provider;

pub const env_name = "GRAFF_OPENAI_CACHE_TTL";
pub const settings_key = "openai_cache_ttl";

pub const Ttl = enum {
    off,
    thirty_m,
    twelve_h,

    pub fn label(self: Ttl) []const u8 {
        return switch (self) {
            .off => "off",
            .thirty_m => "30m",
            .twelve_h => "12h",
        };
    }
};

pub const default_ttl: Ttl = .twelve_h;

threadlocal var override_ttl: ?Ttl = null;
var saved_ttl: ?Ttl = null;

pub fn parse(text: []const u8) ?Ttl {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return null;
    if (eqlAny(t, &.{ "off", "0", "false", "none", "disable" })) return .off;
    if (eqlAny(t, &.{ "30m", "30", "30-min", "30min" })) return .thirty_m;
    if (eqlAny(t, &.{ "12h", "12", "12-hour", "12hour" })) return .twelve_h;
    return null;
}

pub fn setOverride(ttl: Ttl) void {
    override_ttl = ttl;
}

pub fn clearOverride() void {
    override_ttl = null;
}

pub fn current() Ttl {
    if (override_ttl) |ttl| return ttl;
    if (envTtl()) |ttl| return ttl;
    return saved_ttl orelse default_ttl;
}

pub fn applyStartup(io: Io, arena: std.mem.Allocator) void {
    saved_ttl = loadSaved(io, arena);
}

/// Direct OpenAI Responses on GPT-5.6 and later. Codex rejected these fields;
/// Chat Completions and older models 400 on `ttl: "12h"`.
pub fn supported(provider_id: []const u8, kind: Provider.Kind, model: []const u8) bool {
    return std.mem.eql(u8, provider_id, "openai") and
        kind == .responses and
        @import("provider_codegraff.zig").openaiGptFamily(model);
}

pub fn active(self: *const Agent) bool {
    return supported(self.provider.id, self.provider.kind, self.provider.model) and current() != .off;
}

pub fn writeOptions(s: *std.json.Stringify, explicit_only: bool) !void {
    try s.objectField("prompt_cache_options");
    try s.beginObject();
    try s.objectField("mode");
    try s.write(if (explicit_only) "explicit" else "implicit");
    try s.objectField("ttl");
    try s.write("30m");
    try s.endObject();
}

/// Stable developer anchor after top-level instructions. Tools are part of
/// the rendered prefix; the current user turn is never marked.
pub fn writeAnchor(s: *std.json.Stringify) !void {
    try s.beginObject();
    try s.objectField("type");
    try s.write("message");
    try s.objectField("role");
    try s.write("developer");
    try s.objectField("content");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("type");
    try s.write("input_text");
    try s.objectField("text");
    try s.write("The preceding instructions and available tools are the stable operating context for this session.");
    try s.objectField("prompt_cache_breakpoint");
    try s.beginObject();
    try s.objectField("mode");
    try s.write("explicit");
    if (current() == .twelve_h) {
        try s.objectField("ttl");
        try s.write("12h");
    }
    try s.endObject();
    try s.endObject();
    try s.endArray();
    try s.endObject();
}

pub const Usage = struct {
    cached: i64 = 0,
    written: i64 = 0,
    write_30m: i64 = 0,
    write_12h: i64 = 0,
};

pub fn readResponsesUsage(usage: std.json.ObjectMap) Usage {
    return readDetails(usage, "input_tokens_details", 0);
}

pub fn readChatUsage(usage: std.json.ObjectMap) Usage {
    return readDetails(usage, "prompt_tokens_details", usageInt(usage, "prompt_cache_hit_tokens"));
}

pub fn billTwelveHour(self: *Agent, usage: Usage) void {
    if (usage.write_12h > 0) {
        @import("prompt_cache_hud.zig").noteWriteSplit(@intCast(usage.write_12h), @intCast(@max(usage.write_30m, 0)));
        @import("usage_trace.zig").noteWriteSplit(usage.write_12h, usage.write_30m);
    }
    if (usage.write_12h <= 0 or @import("billing.zig").forProvider(self.provider) != .priced) return;
    const p = @import("pricing.zig").priceForProvider(self.provider.id, self.provider.model) orelse return;
    const extra = @import("pricing_cache.zig").twelveHourWriteExtraUsd(p, self.provider.model, usage.write_12h);
    if (extra == 0) return;
    const pricing = @import("pricing.zig");
    pricing.g_cost.mutex.lockUncancelable(self.io);
    defer pricing.g_cost.mutex.unlock(self.io);
    pricing.g_cost.usd += extra;
}

fn readDetails(usage: std.json.ObjectMap, field: []const u8, cached_in: i64) Usage {
    var out: Usage = .{ .cached = cached_in };
    const details = usage.get(field) orelse return out;
    if (details != .object) return out;
    if (out.cached == 0) out.cached = usageInt(details.object, "cached_tokens");
    out.written = usageInt(details.object, "cache_write_tokens");
    if (details.object.get("cache_write_tokens_details")) |split| if (split == .object) {
        out.write_30m = usageInt(split.object, "ttl_30m_tokens");
        out.write_12h = usageInt(split.object, "ttl_12h_tokens");
    };
    return out;
}

fn usageInt(obj: std.json.ObjectMap, name: []const u8) i64 {
    if (obj.get(name)) |v| if (v == .integer and v.integer > 0) return v.integer;
    return 0;
}

fn envTtl() ?Ttl {
    const raw = std.c.getenv(env_name) orelse return null;
    return parse(std.mem.span(raw));
}

fn loadSaved(io: Io, arena: std.mem.Allocator) ?Ttl {
    const data = Io.Dir.cwd().readFileAlloc(io, @import("harness_policy.zig").settings_path, arena, .limited(1 << 20)) catch return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{ .allocate = .alloc_always }) catch return null;
    if (v != .object) return null;
    const saved = v.object.get(settings_key) orelse return null;
    if (saved != .string) return null;
    return parse(saved.string);
}

fn eqlAny(text: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.ascii.eqlIgnoreCase(text, n)) return true;
    return false;
}

test "TTL parse accepts the documented knobs" {
    try std.testing.expectEqual(Ttl.off, parse("off").?);
    try std.testing.expectEqual(Ttl.thirty_m, parse("30m").?);
    try std.testing.expectEqual(Ttl.twelve_h, parse("12h").?);
    try std.testing.expect(parse("tomorrow") == null);
}

test "12h is Responses GPT-5.6+ on the OpenAI provider only" {
    const Kind = Provider.Kind;
    try std.testing.expect(supported("openai", .responses, "gpt-5.6"));
    try std.testing.expect(supported("openai", .responses, "gpt-5.6-luna"));
    try std.testing.expect(supported("openai", .responses, "gpt-6-astra"));
    try std.testing.expect(supported("openai", .responses, "gpt-6.1-sol"));
    try std.testing.expect(!supported("openai", .responses, "gpt-5.5"));
    try std.testing.expect(!supported("openai", .responses, "gpt-4o"));
    try std.testing.expect(!supported("openai", .openai, "gpt-5.6"));
    try std.testing.expect(!supported("openai", .openai, "gpt-6-sol"));
    try std.testing.expect(!supported("codex", .responses, "gpt-5.6-sol"));
    try std.testing.expect(!supported("chatgpt-new", .responses, "gpt-6.1-sol"));
    try std.testing.expect(!supported("xai", .responses, "grok-4.6"));
    try std.testing.expect(!supported("codegraff", .responses, "gpt-5.6"));
    _ = Kind;
}

test "usage details expose cached_tokens and both write lifetimes" {
    const gpa = std.testing.allocator;
    const body =
        \\{"input_tokens":12000,"input_tokens_details":{"cached_tokens":4000,"cache_write_tokens":7000,
        \\ "cache_write_tokens_details":{"ttl_30m_tokens":3000,"ttl_12h_tokens":4000}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const u = readResponsesUsage(parsed.value.object);
    try std.testing.expectEqual(@as(i64, 4000), u.cached);
    try std.testing.expectEqual(@as(i64, 7000), u.written);
    try std.testing.expectEqual(@as(i64, 3000), u.write_30m);
    try std.testing.expectEqual(@as(i64, 4000), u.write_12h);
}

test {
    _ = @import("openai_cache_retention.zig");
}
