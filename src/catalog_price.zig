//! Prices a router publishes in its own /models list.
//!
//! The hosted gateway lists each model with OpenRouter's `pricing` object (USD
//! per token as decimal strings) plus an optional `long_context` tier. Reading
//! them from the catalog means a model the gateway adds, or a price it changes,
//! is billed correctly without a graff release; pricing_gateway.zig stays the
//! offline fallback. The catalog cache stores the same object, so a cached
//! catalog keeps its prices.

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;
const pricing = @import("pricing.zig");

/// USD per 1M tokens: the catalog's per-token rate × 1e6. Null when either the
/// prompt or completion rate is missing or not a finite non-negative number.
pub fn parse(obj: std.json.ObjectMap) ?pricing.CatalogPrice {
    const p = obj.get("pricing") orelse return null;
    if (p != .object) return null;
    // Vercel AI Gateway names the same per-token rates input/output.
    const in = perMillion(p.object.get("prompt") orelse p.object.get("input")) orelse return null;
    const out = perMillion(p.object.get("completion") orelse p.object.get("output")) orelse return null;
    var price: pricing.CatalogPrice = .{ .in = in, .out = out, .cache = perMillion(p.object.get("input_cache_read")) orelse in };
    if (p.object.get("long_context")) |lc| if (lc == .object) {
        const at = lc.object.get("threshold") orelse return price;
        if (at != .integer or at.integer <= 0) return price;
        const lin = perMillion(lc.object.get("prompt")) orelse return price;
        const lout = perMillion(lc.object.get("completion")) orelse return price;
        price.high_at = @intCast(at.integer);
        price.high_in = lin;
        price.high_out = lout;
        price.high_cache = perMillion(lc.object.get("input_cache_read")) orelse lin;
    };
    return price;
}

fn perMillion(v: ?Value) ?f64 {
    const rate: f64 = switch (v orelse return null) {
        .string => |s| std.fmt.parseFloat(f64, s) catch return null,
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => return null,
    };
    if (!std.math.isFinite(rate) or rate < 0) return null;
    // Per-token decimals don't survive ×1e6 exactly (0.000000825 → 0.8250000000000001); keep 6 places.
    return @round(rate * 1_000_000 * 1_000_000) / 1_000_000;
}

/// The rest of one cached model object after its name: context, reasoning flag,
/// the price when known, and the closing brace.
pub fn writeCacheTail(w: *Io.Writer, m: pricing.ModelInfo) !void {
    try w.print(",\"context\":{d},\"supports_reasoning\":{}", .{ m.context, m.supports_reasoning });
    if (m.price) |p| {
        try w.print(",\"pricing\":{{\"prompt\":{d},\"completion\":{d},\"input_cache_read\":{d}", .{ p.in / 1_000_000, p.out / 1_000_000, p.cache / 1_000_000 });
        if (p.high_at > 0) try w.print(",\"long_context\":{{\"threshold\":{d},\"prompt\":{d},\"completion\":{d},\"input_cache_read\":{d}}}", .{ p.high_at, p.high_in / 1_000_000, p.high_out / 1_000_000, p.high_cache / 1_000_000 });
        try w.writeByte('}');
    }
    try w.writeByte('}');
}

/// A catalog price as the session meter's row.
pub fn asModelPrice(name: []const u8, p: pricing.CatalogPrice) pricing.ModelPrice {
    return .{ .name = name, .in = p.in, .out = p.out, .cache = p.cache, .cache_write_multiplier = 1, .high_at = p.high_at, .high_in = p.high_in, .high_out = p.high_out, .high_cache = p.high_cache };
}

fn approx(a: f64, b: f64) bool {
    return @abs(a - b) < 1e-9;
}

test "parse reads OpenRouter-style per-token strings as USD per 1M" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(Value, a,
        \\{"id":"gemini-4-argon","pricing":{"prompt":"0.0000022","completion":"0.000011","input_cache_read":"0.00000011","free_credit":false}}
    , .{});
    defer parsed.deinit();
    const p = parse(parsed.value.object).?;
    try std.testing.expect(approx(p.in, 2.2) and approx(p.out, 11) and approx(p.cache, 0.11));
    try std.testing.expectEqual(@as(u64, 0), p.high_at);
    // Rounded to 6 places, so listings print 0.825, not 0.8250000000000001.
    const flash = try std.json.parseFromSlice(Value, a,
        \\{"pricing":{"prompt":"0.000000825","completion":"0.000004125"}}
    , .{});
    defer flash.deinit();
    try std.testing.expectEqual(@as(f64, 0.825), parse(flash.value.object).?.in);
}

test "parse reads Vercel AI Gateway input/output rates" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(Value, a,
        \\{"id":"moonshotai/kimi-k3.1-pro","pricing":{"input":"0.000002","output":"0.00001","input_cache_read":"0.0000002","input_cache_write":"0.000002"}}
    , .{});
    defer parsed.deinit();
    const p = parse(parsed.value.object).?;
    try std.testing.expect(approx(p.in, 2) and approx(p.out, 10) and approx(p.cache, 0.2));
}

test "parse keeps a long-context tier, and rejects a row without both rates" {
    const a = std.testing.allocator;
    const tiered = try std.json.parseFromSlice(Value, a,
        \\{"pricing":{"prompt":4e-6,"completion":"0.00002","long_context":{"threshold":272000,"prompt":"0.000008","completion":"0.00003"}}}
    , .{});
    defer tiered.deinit();
    const p = parse(tiered.value.object).?;
    try std.testing.expect(approx(p.in, 4) and approx(p.cache, 4));
    try std.testing.expectEqual(@as(u64, 272000), p.high_at);
    try std.testing.expect(approx(p.high_in, 8) and approx(p.high_out, 30) and approx(p.high_cache, 8));

    for ([_][]const u8{
        \\{"pricing":{"prompt":"0.000001"}}
        ,
        \\{"pricing":{"prompt":"-1","completion":"0.000001"}}
        ,
        \\{"pricing":{"prompt":"free","completion":"0.000001"}}
        ,
        \\{"context_length":1000}
    }) |doc| {
        const v = try std.json.parseFromSlice(Value, a, doc, .{});
        defer v.deinit();
        try std.testing.expect(parse(v.value.object) == null);
    }
}

test "a cached price reads back the same" {
    const a = std.testing.allocator;
    var aw: Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const m: pricing.ModelInfo = .{ .provider = "codegraff", .name = "x", .context = 1000, .price = .{ .in = 2.2, .out = 11, .cache = 0.11, .high_at = 200001, .high_in = 4.4, .high_out = 22, .high_cache = 0.22 } };
    try aw.writer.writeAll("{\"name\":\"x\"");
    try writeCacheTail(&aw.writer, m);
    const v = try std.json.parseFromSlice(Value, a, aw.written(), .{});
    defer v.deinit();
    const p = parse(v.value.object).?;
    try std.testing.expect(approx(p.in, 2.2) and approx(p.out, 11) and approx(p.cache, 0.11));
    try std.testing.expectEqual(@as(u64, 200001), p.high_at);
    try std.testing.expect(approx(p.high_out, 22));
}

test "a gateway catalog price wins over the baked snapshot; other providers are untouched" {
    const saved = pricing.active_model_table;
    defer pricing.active_model_table = saved;
    pricing.active_model_table = &.{
        .{ .provider = "codegraff", .name = "gemini-3.8-flash", .context = 1_048_576, .price = .{ .in = 1, .out = 2, .cache = 0.1 } },
        .{ .provider = "codegraff", .name = "gpt-6-sol", .context = 1_050_000 },
        .{ .provider = "vercel", .name = "moonshotai/kimi-k3.1-pro", .context = 1_048_576, .price = .{ .in = 2, .out = 10, .cache = 0.2 } },
    };
    const vercel = pricing.priceForProvider("vercel", "moonshotai/kimi-k3.1-pro").?;
    try std.testing.expect(approx(vercel.in, 2) and approx(vercel.cache, 0.2));
    const live = pricing.priceForProvider("codegraff", "gemini-3.8-flash").?;
    try std.testing.expect(approx(live.in, 1) and approx(live.out, 2));
    // No catalog price: the baked gateway row still answers.
    const baked = pricing.priceForProvider("codegraff", "gpt-6-sol").?;
    try std.testing.expect(approx(baked.in, 2.2));
    // A direct provider never reads the gateway's catalog.
    try std.testing.expect(pricing.priceForProvider("google", "gemini-3.8-flash") == null or !approx(pricing.priceForProvider("google", "gemini-3.8-flash").?.in, 1));
}
