//! #557 tests for the LiteLLM price-database overlay. Split out of
//! pricing_db.zig to keep that file inside the 600-line cap; reached from the
//! test root through its `test { _ = @import(...) }` block.
//!
//! The overlay pointers in pricing.zig are process globals. Zig's test runner
//! executes tests sequentially in one process, so save-and-`defer`-restore is
//! sound here — but the restore must be unconditional, or one failing test
//! leaks a fake price sheet into every test that runs after it.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const pricing = @import("pricing.zig");
const db = @import("pricing_db.zig");

/// Hand-written in the upstream shape. Exercises, in order: the prose-valued
/// `sample_spec` row upstream really ships; a bare vendor row; a reseller row
/// that must LOSE to the bare key for the same model; that bare key; a row with
/// no cache rate (the per-field fallback); a namespaced key whose vendor IS the
/// model's vendor (trusted, banded); a reseller-ONLY model (window yes, price
/// no); a HALF band (one tier rate, which must not become a band); a matched
/// key whose value is not an object; and a model graff has never heard of.
const fixture =
    \\{
    \\  "sample_spec": {"input_cost_per_token": "0.0", "max_input_tokens": "max input tokens, if the provider specifies it"},
    \\  "grok-4.3": {"litellm_provider": "xai", "mode": "chat", "input_cost_per_token": 0.000003, "output_cost_per_token": 0.000015, "cache_read_input_token_cost": 0.0000003, "max_input_tokens": 300000, "supports_vision": true},
    \\  "openrouter/deepseek/deepseek-v4-flash": {"input_cost_per_token": 0.00000999, "output_cost_per_token": 0.00000999, "max_input_tokens": 111111},
    \\  "deepseek-v4-flash": {"input_cost_per_token": 0.0000005, "output_cost_per_token": 0.000001, "cache_read_input_token_cost": 0.0000001, "max_input_tokens": 700000},
    \\  "gpt-5.5": {"input_cost_per_token": 0.000002, "output_cost_per_token": 0.00001, "max_input_tokens": 900000},
    \\  "xai/grok-4.6": {"input_cost_per_token": 0.000002, "output_cost_per_token": 0.000006, "input_cost_per_token_above_200k_tokens": 0.000009, "output_cost_per_token_above_200k_tokens": 0.00002},
    \\  "openrouter/xiaomi/mimo-v2.5-pro": {"input_cost_per_token": 0.000001, "output_cost_per_token": 0.000003, "max_input_tokens": 1048576},
    \\  "glm-5.2": {"input_cost_per_token": 0.0000012, "output_cost_per_token": 0.000004, "cache_read_input_token_cost_above_200k_tokens": 0.0000005},
    \\  "kimi-k2.7": ["upstream typo: not an object"],
    \\  "some-model-graff-has-never-heard-of": {"input_cost_per_token": 0.001, "max_input_tokens": 5}
    \\}
;

const override_fixture =
    \\{"grok-4.3": {"input_cost_per_token": 0.000004, "output_cost_per_token": 0.00002, "max_input_tokens": 123000}}
;

/// Restores every global these tests touch, pass or fail.
const Guard = struct {
    prices: []const pricing.ModelPrice,
    contexts: []const pricing.ModelInfo,

    fn take() Guard {
        db.invalidate();
        return .{ .prices = pricing.price_overlay, .contexts = pricing.context_overlay };
    }
    fn release(self: Guard) void {
        pricing.price_overlay = self.prices;
        pricing.context_overlay = self.contexts;
        db.invalidate();
    }
};

fn hydrate(arena: std.mem.Allocator, dir: Io.Dir, paths: db.Paths) void {
    db.hydrateAt(std.testing.io, std.testing.allocator, arena, dir, paths, false);
}

test "price db: per-token costs convert exactly to graff's per-1M units" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const guard = Guard.take();
    defer guard.release();

    const rows = db.scan(std.testing.allocator, arena, fixture) orelse return error.NoRows;
    db.apply(arena, rows);

    const p = pricing.priceFor("grok-4.3") orelse return error.MissingOverlayRow;
    // 0.000003 USD/token is exactly 3.0 USD per 1M tokens, and both endpoints
    // are representable, so this is an equality — not an approx — on purpose.
    try std.testing.expectEqual(@as(f64, 3.0), p.in);
    try std.testing.expectEqual(@as(f64, 15.0), p.out);
    try std.testing.expectEqual(@as(f64, 0.3), p.cache);
    // usdFor reads the same row: 1M uncached in + 1M out at those rates.
    try std.testing.expectEqual(@as(f64, 18.0), pricing.usdFor(p, 1_000_000, 0, 1_000_000));
}

test "price db: the overlay wins, and the baked table survives where it is silent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const guard = Guard.take();
    defer guard.release();

    // Baked, before anything is applied.
    try std.testing.expectEqual(@as(f64, 1.25), (pricing.priceFor("grok-4.3") orelse return error.MissingBakedRow).in);

    const rows = db.scan(std.testing.allocator, arena, fixture) orelse return error.NoRows;
    db.apply(arena, rows);

    // Covered by the database → the fresh number answers.
    try std.testing.expectEqual(@as(f64, 3.0), (pricing.priceFor("grok-4.3") orelse return error.MissingOverlayRow).in);
    // kimi-k2.7's fixture value is an ARRAY. One malformed row must not cost
    // the other six their prices, so it is skipped and the baked row answers.
    const kimi = pricing.priceFor("kimi-k2.7") orelse return error.MissingBakedRow;
    try std.testing.expectEqual(@as(f64, 0.95), kimi.in);
    try std.testing.expectEqual(@as(f64, 4.0), kimi.out);
    // A model graff does not carry is never added: the overlay is a price sheet
    // for OUR catalog, not a copy of a 3000-row database.
    try std.testing.expect(pricing.priceFor("some-model-graff-has-never-heard-of") == null);
}

test "price db: a field the database omits keeps the baked value, never 0" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const guard = Guard.take();
    defer guard.release();

    const rows = db.scan(std.testing.allocator, arena, fixture) orelse return error.NoRows;
    db.apply(arena, rows);

    // gpt-5.5's fixture row has no cache_read rate. Zeroing it would bill every
    // cached prompt token at $0 — the baked 0.5 stands in instead.
    const p = pricing.priceFor("gpt-5.5") orelse return error.MissingOverlayRow;
    try std.testing.expectEqual(@as(f64, 2.0), p.in);
    try std.testing.expectEqual(@as(f64, 10.0), p.out);
    try std.testing.expectEqual(@as(f64, 0.5), p.cache);

    // glm-5.2's fixture row tiers ONLY the cache read. Adopting a band from
    // that would leave high_in at the flat row's 0 and make input free past
    // 200k, so the band is refused while the fresh base rates are taken.
    const half = pricing.priceFor("glm-5.2") orelse return error.MissingOverlayRow;
    try std.testing.expectEqual(@as(u64, 0), half.high_at);
    try std.testing.expectEqual(@as(f64, 1.2), half.in);
    try std.testing.expectEqual(@as(f64, 4.0), half.out);

    // grok-4.6 IS banded upstream, so the band comes across whole.
    const banded = pricing.priceFor("grok-4.6") orelse return error.MissingOverlayRow;
    try std.testing.expectEqual(@as(u64, 200_000), banded.high_at);
    try std.testing.expectEqual(@as(f64, 9.0), banded.high_in);
    try std.testing.expectEqual(@as(f64, 20.0), banded.high_out);
    // A 200k prompt bills at the high band, exactly as the baked row used to.
    try std.testing.expectEqual(@as(f64, 1.8), pricing.usdFor(banded, 200_000, 0, 0));
}

test "price db: a reseller may set the window but never the price" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const guard = Guard.take();
    defer guard.release();

    const rows = db.scan(std.testing.allocator, arena, fixture) orelse return error.NoRows;
    db.apply(arena, rows);

    // mimo-v2.5-pro exists upstream ONLY as `openrouter/xiaomi/...`, at 2.3x
    // Xiaomi's own rate. The window is a property of the weights and is taken;
    // the markup is not, so graff's direct-seat price stands.
    const p = pricing.priceFor("mimo-v2.5-pro") orelse return error.MissingBakedRow;
    try std.testing.expectEqual(@as(f64, 0.435), p.in);
    try std.testing.expectEqual(@as(f64, 0.87), p.out);
    try std.testing.expectEqual(@as(u64, 1_048_576), pricing.contextFor("nope", "mimo-v2.5-pro"));

    // A namespaced key whose leading segment IS the vendor is trusted in full.
    const grok = pricing.priceFor("grok-4.6") orelse return error.MissingOverlayRow;
    try std.testing.expectEqual(@as(f64, 2.0), grok.in);
    try std.testing.expectEqual(@as(f64, 6.0), grok.out);
}

test "price db: a vendor's own key beats a reseller's namespaced copy" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const guard = Guard.take();
    defer guard.release();

    const rows = db.scan(std.testing.allocator, arena, fixture) orelse return error.NoRows;
    db.apply(arena, rows);

    // The reseller row sits FIRST in the fixture and quotes 20x the price.
    const p = pricing.priceFor("deepseek-v4-flash") orelse return error.MissingOverlayRow;
    try std.testing.expectEqual(@as(f64, 0.5), p.in);
    try std.testing.expectEqual(@as(u64, 700_000), pricing.contextFor("nope", "deepseek-v4-flash"));
}

test "price db: context comes from max_input_tokens, and the codex cap still applies" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const guard = Guard.take();
    defer guard.release();

    const rows = db.scan(std.testing.allocator, arena, fixture) orelse return error.NoRows;
    db.apply(arena, rows);

    // Name-only overlay row, for a provider with no baked row of its own.
    try std.testing.expectEqual(@as(u64, 300_000), pricing.contextFor("nope", "grok-4.3"));
    // A baked PROVIDER-specific row still wins: the gateway's 1M gpt-5.5 window
    // is deliberate configuration, not a stale number the database may correct.
    try std.testing.expectEqual(@as(u64, 1_050_000), pricing.contextFor("openai", "gpt-5.5"));
    // And no upstream number can lift the codex cap — 300k clamps to 270k.
    try std.testing.expectEqual(pricing.codex_context_window, pricing.contextFor("codex", "grok-4.3"));
}

test "price db: malformed or oversized input falls back silently" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const guard = Guard.take();
    defer guard.release();

    const before = pricing.price_overlay;
    for ([_][]const u8{ "", "{not json", "[]", "\"a string\"", "{\"grok-4.3\": 7}" }) |bad|
        try std.testing.expect(db.scan(std.testing.allocator, arena, bad) == null);
    // Nothing was applied, so the effective price is still the baked one.
    try std.testing.expectEqual(before.len, pricing.price_overlay.len);
    try std.testing.expectEqual(@as(f64, 1.25), (pricing.priceFor("grok-4.3") orelse return error.MissingBakedRow).in);
}

test "price db: GRAFF_PRICES_PATH wins over a fresh on-disk cache" {
    if (builtin.os.tag == .windows) return;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const guard = Guard.take();
    defer guard.release();

    try tmp.dir.writeFile(io, .{ .sub_path = "prices.json", .data = fixture });
    try tmp.dir.writeFile(io, .{ .sub_path = "override.json", .data = override_fixture });
    hydrate(arena, tmp.dir, .{ .override = "override.json", .cache = "prices.json" });

    try std.testing.expectEqual(@as(f64, 4.0), (pricing.priceFor("grok-4.3") orelse return error.MissingOverlayRow).in);
    try std.testing.expectEqual(@as(u64, 123_000), pricing.contextFor("nope", "grok-4.3"));
    try std.testing.expect(std.mem.startsWith(u8, db.source, "GRAFF_PRICES_PATH"));
}

test "price db: a cache younger than the TTL is used; a stale one is labelled" {
    if (builtin.os.tag == .windows) return;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const guard = Guard.take();
    defer guard.release();

    try tmp.dir.writeFile(io, .{ .sub_path = "prices.json", .data = fixture });
    hydrate(arena, tmp.dir, .{ .cache = "prices.json" });
    try std.testing.expectEqual(@as(f64, 3.0), (pricing.priceFor("grok-4.3") orelse return error.MissingOverlayRow).in);
    try std.testing.expect(std.mem.startsWith(u8, db.source, "litellm cache ·"));

    // Backdate the file past the TTL. Offline, a stale sheet is still better
    // than a release-old baked table — but it says so.
    db.invalidate();
    pricing.price_overlay = guard.prices;
    pricing.context_overlay = guard.contexts;
    const stale_ns = Io.Timestamp.now(io, .real).nanoseconds - @as(i96, db.ttl_ms + 60_000) * std.time.ns_per_ms;
    try tmp.dir.setTimestamps(io, "prices.json", .{ .modify_timestamp = .{ .new = .{ .nanoseconds = stale_ns } } });
    hydrate(arena, tmp.dir, .{ .cache = "prices.json" });
    try std.testing.expectEqual(@as(f64, 3.0), (pricing.priceFor("grok-4.3") orelse return error.MissingOverlayRow).in);
    try std.testing.expect(std.mem.startsWith(u8, db.source, "litellm cache (stale)"));
}

test "price db: no cache and no network leaves the baked table untouched" {
    if (builtin.os.tag == .windows) return;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const guard = Guard.take();
    defer guard.release();

    const before = pricing.price_overlay;
    hydrate(arena, tmp.dir, .{ .cache = "prices.json", .flat = "flat-prices.json" });
    try std.testing.expectEqual(before.len, pricing.price_overlay.len);
    try std.testing.expectEqualStrings("", db.source);
    try std.testing.expectEqual(@as(f64, 1.25), (pricing.priceFor("grok-4.3") orelse return error.MissingBakedRow).in);
}

test "price db: the trimmed cache we write reloads to the same numbers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const guard = Guard.take();
    defer guard.release();

    const rows = db.scan(std.testing.allocator, arena, fixture) orelse return error.NoRows;
    const bytes = db.serialize(arena, rows) orelse return error.NotSerialized;
    // A round trip through our own writer must be lossless: the cache is what
    // every later session reads instead of the 1.8 MB upstream file.
    const reloaded = db.scan(std.testing.allocator, arena, bytes) orelse return error.NoRows;
    try std.testing.expectEqual(rows.len, reloaded.len);
    db.apply(arena, reloaded);
    const p = pricing.priceFor("grok-4.3") orelse return error.MissingOverlayRow;
    try std.testing.expectEqual(@as(f64, 3.0), p.in);
    try std.testing.expectEqual(@as(f64, 0.3), p.cache);
    try std.testing.expectEqual(@as(u64, 300_000), pricing.contextFor("nope", "grok-4.3"));
    // The trimmed sheet is a rounding error next to upstream's ~1.8 MB.
    try std.testing.expect(bytes.len < 2048);
}
